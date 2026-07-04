# Beacon

A native macOS menu-bar utility that tells you, second by second, **which apps are using your bandwidth and how much** — and lets you act on it. No accounts, no telemetry, no background services beyond the menu-bar app itself. All data stays on your machine.

![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange)
![License](https://img.shields.io/badge/License-MIT-green)

*Beacon is developed by [Lighthouse Computer](https://beacon.lighthouse.computer).*

---

## What you get

### Menu bar
- **Live total speed** — `↓ 1.2 MB/s  ↑ 305 KB/s`, refreshed every second.
- Left-click opens the popover. Right-click brings up Launch-at-Login + Quit.

### Popover — the per-app list
- **One row per app**, sorted by cross-session all-time bytes. Each row reads as three lines per side:
  - **Left:** name + code-signature trust icon · System/User/Other chip + PIDs · last-active time
  - **Right:** all-time bytes · ↓ in / ↑ out · current speed (when transmitting)
- **Live green dot** before any app currently moving data.
- **Active-count badge** doubles as a filter — click to show only active apps, click again for all.
- **Search** (always visible) across **app names, PIDs, ports, and services**, grouped into four collapsible sections with colored match-type chips. Just start typing anywhere in the popover — the first keystroke jumps you into search.
- **Right-click a row:**
  - **Kill Process** — end an app straight from its row. GUI apps get a graceful quit so they can run their own save flow; background processes get `SIGTERM`, escalating to `SIGKILL` after a short grace. A confirmation dialog lists the exact PIDs. Safe by design: system processes are never offered the action, history-only rows can't be killed, the app never targets itself, and the escalation re-checks process identity so a recycled PID is never hit.
  - **Hide from List** / **Select Multiple to Hide…** — single or multi-select hiding (toggle rows, then *Hide Selected*).
  - **Reset All-Time Data** — wipes the persistent lifetime store.
- **Gear menu:** restore ignored apps, close all chart windows, reset all-time data, quit.

### Chart panel — click any row
A floating panel opens beside the popover with a per-app history graph and a port/service breakdown.

- **Date-range picker:** Live (1 min) / 5 min / 15 min / 1 hour / 24 hours / 7 days / 30 days.
- **Trading-chart crosshair on hover** — dashed vertical at the snapped time + two horizontal guides (blue ↓, green ↑) reading off the y-axis, plus a floating value box.
- **Port / service breakdown** under the chart: every service the app talks to (443 → https, 53 → dns, …) with ↓/↑ totals. Click a port to expand the distinct remote IPs behind it.
- **Resizable** graph / port-service split with a draggable divider, and a **movable, resizable window**.
- **Pin to keep it open** — up to **3 pinned panels** at once for comparing apps live. Unpinned charts auto-close when you click back in the popover.

---

## How it works (one minute)

Beacon spawns `/usr/bin/nettop -n -L 1` once per second (in the `C` locale for stable parsing), reads the CSV snapshot, and computes per-PID byte deltas. PIDs are grouped by bundle identifier so multi-process apps (Chrome helpers, Electron renderers) collapse to a single row, and the per-connection sub-rows `nettop` emits drive the port/service breakdown.

Why per-cycle and not one long-lived `nettop`? In interactive mode `nettop` emits ncurses escape codes, not CSV; and when its stdout is a pipe it **block-buffers** and only flushes on exit — so a long-lived process delivers nothing for ~60 seconds. `-L 1` produces one snapshot and exits in ~60 ms, and we pace the loop ourselves at ~1 Hz. Idle CPU stays near 0%.

Code signatures are validated once per bundle path via `SecStaticCodeCheckValidity` and cached. All-time byte counts live in `~/Library/Application Support/Beacon/lifetime.json` (saved every 30 s and on quit). Speed history is tiered: 1 Hz samples for the last hour in memory, per-minute averages for 24 hours, and per-hour averages for 30 days — the averaged tiers persisted to `speed-history.json`.

---

## Requirements

| | |
|---|---|
| **macOS** | 13 Ventura or later (Swift Charts) |
| **CPU** | Intel or Apple Silicon |
| **Toolchain (to build)** | Swift 5.9+ (Xcode 15 or Command Line Tools) |

No external Swift packages. Beacon is **not sandboxed** — it needs to invoke `nettop` and read installed-app metadata via `NSWorkspace`, both blocked by the App Sandbox. That's why it can't ship on the Mac App Store; install from Homebrew or GitHub Releases instead.

---

## Install

### Homebrew Cask

```bash
brew install --cask lighthouse-computer/tap/beacon
```

### Pre-built download

Grab `Beacon.app.zip` from the [Releases page](../../releases), unzip, and drag `Beacon.app` into `/Applications`. First launch: right-click the app → **Open** → confirm (standard Gatekeeper prompt for ad-hoc-signed builds; the Homebrew cask clears this for you).

### Build from source

```bash
git clone https://github.com/lighthouse-computer/beacon.git
cd beacon
./Scripts/build_app.sh --run        # builds + launches
# or
./Scripts/build_app.sh --install    # builds + copies to /Applications + launches
```

The script handles compilation, bundle assembly, ad-hoc signing, and (optionally) installation.

---

## Keyboard & mouse cheat sheet

| Action | Result |
|---|---|
| Left-click menu bar | Open / close popover |
| Right-click menu bar | Launch-at-Login + Quit menu |
| Type anywhere in popover | Auto-enter search; characters seed the field |
| Click row | Open chart for that app |
| Click same row again | Close that chart |
| Right-click row → Kill Process | End the app (with confirmation) |
| Right-click row → Select Multiple to Hide… | Enter multi-select mode |
| Pin button in chart header | Promote chart to a standalone window |
| Drag chart body / edges / divider | Move / resize / re-split the panel |
| Hover plot | Crosshair with ↓ / ↑ / time at the snapped sample |

---

## Project layout

```
beacon/
├── Package.swift
├── README.md  CHANGELOG.md  CONTRIBUTING.md  DISTRIBUTION.md  LICENSE  CLAUDE.md
├── Scripts/
│   ├── build_app.sh                 # build + sign + (optional) install/run
│   ├── build_release.sh             # Developer-ID signed + notarized .dmg
│   ├── Info.plist                   # bundle metadata (version stamped from the tag)
│   └── Beacon.entitlements
├── Distribution/
│   ├── beacon.rb                    # Homebrew cask seed
│   └── tap-autobump.yml             # auto-bumps the live tap on each release
├── Sources/Beacon/
│   ├── BeaconApp.swift              # @main + AppDelegate + popover/menu plumbing
│   ├── Managers/                    # nettop spawner, parser, trackers, stores, …
│   ├── Models/
│   ├── Utilities/
│   └── Views/                       # PopoverRootView + GraphPanel
└── Tests/BeaconTests/
```

> **Building & testing:** CI gates on `swift build`. The test target needs `XCTest`, so run `swift test` with Xcode's toolchain selected (`xcode-select -p` should point at `Xcode.app`, not the Command Line Tools).

---

## Known limits

- **Downsampled long-range history.** Raw 1 Hz for the last hour, per-minute for 24 h, per-hour for 30 days — a 30-day view shows hourly means, not raw samples.
- **No retroactive counters.** macOS doesn't expose per-process bytes counted before the app launched, so All-Time totals only include traffic observed *while Beacon was running*.
- **Cold-start cost.** The first snapshot validates each running binary's signature — expect a brief ~0.3–1 s CPU blip, then idle.
- **Not in the Mac App Store.** The sandbox blocks `nettop`; see [Requirements](#requirements).

---

## Contributing

Bug reports, fixes, and feature ideas are welcome. Open an issue first for anything larger than a small fix so we can sort scope. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Distribution

Maintainers (and anyone forking to ship): [DISTRIBUTION.md](DISTRIBUTION.md) covers Developer ID signing, notarization, GitHub Releases automation, and the Homebrew Cask.

## License

MIT — © 2026 Lighthouse Computer. See [LICENSE](LICENSE).
