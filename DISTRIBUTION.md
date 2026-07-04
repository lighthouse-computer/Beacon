# Distribution & Publishing

How Beacon gets from a git tag to a `brew install`. For an unsandboxed menu-bar utility the working path is:

1. **GitHub Releases** — primary download, source of truth.
2. **Homebrew Cask** — most-discovered install method on macOS.
3. **(Optional) Notarization with Apple** — removes the "unidentified developer" warning, requires a $99/yr Apple Developer account.

What **doesn't** work for this app:

- **Mac App Store.** Requires the App Sandbox. Beacon needs `/usr/bin/nettop` and `/Applications` metadata via `NSWorkspace` — both blocked. No workaround short of a fundamentally different (worse) implementation.

---

## Step 1 — GitHub Releases (free, required)

`Scripts/build_app.sh` produces an ad-hoc-signed `Beacon.app`. For releases it must be **zipped** so macOS keeps the bundle structure intact on download.

### Automated (recommended)

`.github/workflows/release.yml` runs on any `v*` tag: it builds, zips `Beacon.app`, writes a `.sha256` sidecar, and publishes a GitHub Release with both attached.

```bash
git tag v1.0.0
git push origin v1.0.0
```

The tag drives the bundle version (the leading `v` is stripped). Keep the tag in sync with `Scripts/Info.plist` and `CHANGELOG.md`.

### Manual (equivalent)

```bash
./Scripts/build_app.sh
cd build
ditto -c -k --keepParent Beacon.app Beacon.app.zip
shasum -a 256 Beacon.app.zip > Beacon.app.zip.sha256   # publish this alongside the zip
```

Then draft a GitHub Release, tag it `v1.0.0`, and attach `Beacon.app.zip` + `Beacon.app.zip.sha256`.

---

## Step 2 — Code signing & notarization (optional, recommended)

Without notarization, first-time users hit a Gatekeeper warning. They can right-click → **Open** to bypass it, but a sizable fraction will assume the app is broken and leave.

Notarization requires an [Apple Developer Program](https://developer.apple.com/programs/) membership ($99/yr), a "Developer ID Application" certificate in your keychain, and notarytool credentials.

**`Scripts/build_release.sh` does the whole signed + notarized + stapled `.dmg` pipeline.** Point it at your identity and credentials via environment variables — it never hardcodes a signing identity:

```bash
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_KEYCHAIN_PROFILE="Beacon-Notary" \
  ./Scripts/build_release.sh
```

It signs with the hardened runtime + secure timestamp, notarizes both the app and the DMG container (the container's staple is what clears Gatekeeper on *download*), staples, and emits a `.sha256` sidecar. With no notary credentials it still produces a **signed but un-notarized** DMG and warns.

To notarize in CI instead, uncomment the signing/notarization block in `.github/workflows/release.yml` and add these repo secrets: `APPLE_CERT_P12_BASE64`, `APPLE_CERT_PASSWORD`, `APPLE_SIGNING_IDENTITY`, `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_SPECIFIC_PASSWORD`.

---

## Step 3 — Homebrew Cask

`Distribution/beacon.rb` is a **seed** cask. The live copy lives in a separate `homebrew-tap` repo at `Casks/beacon.rb` and is kept current automatically by `Distribution/tap-autobump.yml` (copied into that tap repo): it polls this repo's latest release hourly, verifies the download's sha256 against the release's `.sha256` sidecar, and direct-commits the version + hash bump. You never hand-edit the tap copy.

### Bootstrap a self-hosted tap (fastest path)

```bash
# 1. Create a repo named `homebrew-tap` under the lighthouse-computer org.
# 2. Add Distribution/beacon.rb as Casks/beacon.rb, and tap-autobump.yml as
#    .github/workflows/tap-autobump.yml, in that repo.
# 3. Users install with:
brew install --cask lighthouse-computer/tap/beacon
```

For **instant** cask updates (instead of the hourly poll), create a fine-grained PAT with `actions: write` on the tap repo, store it as the `TAP_DISPATCH_TOKEN` secret here, and uncomment the "Trigger tap autobump" step in `release.yml`.

### Official homebrew-cask submission (optional)

Once the release cadence is stable, you can submit to [homebrew/homebrew-cask](https://github.com/Homebrew/homebrew-cask): add `Casks/b/beacon.rb`, run `brew style --fix --cask beacon` and `brew audit --new --cask beacon`, and open a PR. It wants a stable download-URL pattern (the workflow produces exactly `…/releases/download/v#{version}/Beacon.app.zip`), a `livecheck` block, and an app that launches and exits cleanly on a clean macOS.

---

## Step 4 — Sparkle in-app updates (optional)

For auto-updates, integrate [Sparkle](https://sparkle-project.org/) — the de-facto Mac updater, fine with unsandboxed apps. It needs a Sparkle ed25519 key pair (separate from your Developer ID) and a publicly-hosted `appcast.xml`. Not required for a first release; add it once the cadence stabilises.

---

## Versioning

[SemVer](https://semver.org/):

- `MAJOR` — breaks the on-disk data format (e.g. `lifetime.json` schema).
- `MINOR` — new feature, no migration required.
- `PATCH` — bug fix, no behaviour change.

Update `CHANGELOG.md` in the same PR that introduces a change — don't let it drift.
