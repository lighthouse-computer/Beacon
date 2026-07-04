# Contributing to Beacon

Thanks for considering a contribution. Keep it small, keep it tested.

## Reporting bugs

Open an issue with:
- macOS version (e.g. `Sonoma 14.5`)
- Apple Silicon or Intel
- Steps to reproduce
- Expected vs. actual behaviour
- Any output from `log show --process Beacon --last 1m`

## Submitting a change

1. Fork, branch from `main`.
2. `swift build` must succeed.
3. `swift test` must succeed for any code you touched. The test target imports `XCTest`, so select Xcode's full toolchain (`xcode-select -p` → `Xcode.app`, not the Command Line Tools). After a target/module rename, `rm -rf .build` before rebuilding.
4. Keep the existing terse comment style: comments explain *why*, not *what*.
5. Open a PR with a one-paragraph description plus a screenshot if the change is visible.

## Architectural ground rules

These are product invariants, not preferences — a change that breaks one will be declined regardless of how good it is otherwise:

- **Privacy first.** Beacon must never make an outbound network connection. Any feature that would need one is out of scope.
- **Stay out of the sandbox.** Beacon needs `/usr/bin/nettop` and `NSWorkspace`; the App Sandbox blocks both. Don't add features that would force sandboxing, and don't add entitlements beyond what those two need.
- **No telemetry, no phone-home.** Opt-in updaters (e.g. Sparkle) are fine because the user chooses; analytics are not.
- **Idle CPU stays under ~1%.** If a feature needs continuous work, gate it behind `LiveUIGate` or a user action.

## Code style

- Swift API design guidelines.
- Comments explain *why*, not *what*. The code already shows what.
- Prefer `private` until something needs wider visibility.
- New persistent files go under `~/Library/Application Support/Beacon/`.

## Releases

Maintainers: see [DISTRIBUTION.md](DISTRIBUTION.md) for the release workflow (signing, notarization, Homebrew Cask).
