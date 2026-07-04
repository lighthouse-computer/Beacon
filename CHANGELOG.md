# Changelog

All notable changes to Beacon are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Beacon uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.0.0] — 2026-07-04

First public release of Beacon by Lighthouse Computer — a native macOS menu-bar
utility for live, per-app network monitoring. Everything runs on-device; no
accounts, no telemetry, no outbound connections.

### Added
- **Live menu-bar speed** — total ↓/↑ throughput refreshed every second.
- **Per-app popover list** — one row per app (PIDs grouped by bundle identifier),
  sorted by cross-session all-time bytes, with code-signature trust,
  System/User/Other classification, live-activity dots, and an active-count
  filter badge.
- **Search** across app names, PIDs, ports, and services, grouped into
  collapsible sections with match-type chips.
- **Per-app chart panel** — history graph with a Live/5m/15m/1h/24h/7d/30d range
  picker, a hover crosshair reading ↓/↑ off the y-axis, and a port/service
  breakdown that expands to the distinct remote IPs behind each port. Up to three
  panels can be pinned side by side.
- **Kill Process** from a row — graceful quit for GUI apps, `SIGTERM`→`SIGKILL`
  escalation for background processes, with a PID-listing confirmation and a
  re-check of process identity before escalation so a recycled PID is never hit.
- **Hide / multi-select hide** and **Reset All-Time Data**.
- **Launch at Login** via `SMAppService`.
- **Tiered speed history** persisted on disk: 1 Hz for the last hour, per-minute
  for 24 hours, per-hour for 30 days.

### Notes
- Requires macOS 13 Ventura or later. Not sandboxed (needs `nettop` and
  `NSWorkspace`), so it is distributed via GitHub Releases and Homebrew rather
  than the Mac App Store.
- On first launch, usage history from the pre-release build is migrated in place.

[Unreleased]: https://github.com/lighthouse-computer/beacon/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/lighthouse-computer/beacon/releases/tag/v1.0.0
