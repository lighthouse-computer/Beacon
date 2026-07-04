# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**Beacon** (by Lighthouse Computer) is a native macOS menu-bar utility that shows, second by second, which apps are using bandwidth and how much — and lets the user act on it (kill, hide, chart). Pure Swift, SwiftUI + AppKit, **no external Swift package dependencies**. Distributed outside the Mac App Store because it is intentionally **not sandboxed**.

## Commands

```bash
swift build                       # debug build
swift build -c release            # release build (what CI gates on)
swift test                        # run all tests — REQUIRES Xcode's toolchain (see below)
swift test --filter NettopLineParserTests            # one test class
swift test --filter NettopLineParserTests/testFoo    # one test method

./Scripts/build_app.sh            # build + assemble + ad-hoc-sign ./build/Beacon.app
./Scripts/build_app.sh --run      # + launch it
./Scripts/build_app.sh --install  # + copy to /Applications and launch
./Scripts/build_release.sh        # Developer-ID signed + notarized + stapled .dmg (maintainers)
```

- **`swift test` needs Xcode's full toolchain**, not the Command Line Tools — the test target imports `XCTest`. If you see `no such module 'XCTest'`, run `xcode-select -p` and point it at `Xcode.app`.
- **After a target rename or module-name change, `rm -rf .build`** — SwiftPM's cache pins the old path and fails a stale first build.
- The runnable product is a hand-assembled `.app` bundle (SwiftPM only emits the bare executable); `Scripts/build_app.sh` copies the binary + `Scripts/Info.plist`, ad-hoc-signs with `Scripts/Beacon.entitlements`, and stamps the version.

## Architecture — the load-bearing decisions

Understanding these three things explains most of the codebase; the rest is UI.

**1. The data source is a per-second `nettop` subprocess, not a long-lived one.**
`NetworkMonitor` spawns `/usr/bin/nettop -n -L 1` once per second in the `C` locale, reads one CSV snapshot, and exits. This is deliberate and easy to "optimize" wrongly: a *long-lived* `nettop` block-buffers on a pipe (delivers nothing for ~60 s) and emits ncurses escape codes in interactive mode, not CSV. `-L 1` returns one snapshot in ~60 ms; we pace the ~1 Hz loop ourselves so idle CPU stays near 0%. Do not replace this with a persistent process. `NettopLineParser` is a **pure** function (CSV row → struct) and is the most heavily tested unit — keep parsing logic there, not in the spawner.

**2. Rows are per-*bundle*, aggregated from per-PID samples.**
`nettop` reports per-PID (and per-connection sub-rows). `ProcessTracker` groups PIDs by bundle identifier so multi-process apps (Chrome helpers, Electron renderers) collapse to one row; the per-connection sub-rows drive the port/service breakdown in the chart. `ProcessClassifier` tags each bundle System/User/Other and validates its code signature once via `SecStaticCodeCheckValidity` (cached). `NetworkViewModel` is the `ObservableObject` the SwiftUI views bind to.

**3. Pure AppKit entry point — there is no SwiftUI `App`/`Scene`.**
`@main enum BeaconMain` (in `BeaconApp.swift`) builds an `NSApplication` with an `AppDelegate` and `.accessory` activation. This avoids the `@main struct: App { Settings { EmptyView() } }` pattern on purpose: under `.accessory`, an empty `Settings` scene can surface a stray blank preferences window. All UI is the status item + popover (`PopoverRootView`) + floating graph panel (`GraphPanel`), constructed by the delegate.

### Persistence & data layout

All state lives under `~/Library/Application Support/Beacon/`:
- `lifetime.json` — cross-session all-time per-app byte totals (`LifetimeUsageStore`, schema-versioned, saved every 30 s and on quit).
- `speed-history.json` — **tiered** history (`SpeedHistoryStore`): 1 Hz for the last hour (memory only), per-minute for 24 h, per-hour for 30 days (the averaged tiers persisted).

`LifetimeUsageStore` and `SpeedHistoryStore` each contain a **one-time migration** that moves the pre-rebrand `~/Library/Application Support/NetworkUsageMonitor/` folder to `Beacon/` on first launch. If you rename the app-support folder again, preserve/extend that shim or you silently orphan every user's accumulated history.

Bundle identifier is `computer.lighthouse.beacon`; UserDefaults keys, os_log subsystems, and dispatch-queue labels are all prefixed with it.

### Non-obvious managers

- `LiveUIGate` — pauses UI churn when no surface is visible (menu-bar-only), the main lever for the <1% idle-CPU budget. Gate expensive work behind it.
- `ProcessControl` — the row-level "Kill process": graceful quit for GUI apps, `SIGTERM`→`SIGKILL` escalation for background ones, and it **re-checks process identity** before escalating so a recycled PID is never hit. Never targets the app itself or system processes.
- `LatestSnapshotStore` — per-id live snapshot cache. `IgnoreListManager` — user-hidden apps. `ServiceDirectory` — port→service name. `LaunchAtLoginManager` — `SMAppService.mainApp` opt-in.

## Invariants — do not break these

These are product constraints, not style preferences:

- **Never make an outbound network connection.** Beacon is a privacy tool; any feature needing the network is out of scope. There is no telemetry and no phone-home.
- **Stay unsandboxed-but-minimal.** The app needs `/usr/bin/nettop` and `NSWorkspace` (both App-Sandbox-blocked) — that's why it can't ship on the Mac App Store. Don't add anything that would force sandboxing, and don't add entitlements beyond what those two require.
- **Idle CPU stays under ~1%.** New continuous work must be gated behind `LiveUIGate` or a user action.
- New persistent files go under `~/Library/Application Support/Beacon/`.

## Release flow

Push a `v*` tag → `.github/workflows/release.yml` builds, zips `Beacon.app`, publishes a GitHub Release with a `.sha256` sidecar. The Homebrew cask (`Distribution/beacon.rb` is a seed; the live copy is `Casks/beacon.rb` in the `lighthouse-computer/Homebrew-Taps` tap) is auto-bumped by that tap's `autobump.yml`, which verifies the sha256 against that sidecar. Version lives in `Scripts/Info.plist`; the tag drives the bundle version at build time. See `DISTRIBUTION.md` for signing/notarization.
