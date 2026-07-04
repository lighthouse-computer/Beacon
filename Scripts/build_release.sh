#!/usr/bin/env bash
#
# build_release.sh — Developer-ID release pipeline for Beacon.
#
# Produces a signed + notarized + stapled .dmg of Beacon.app.
#
# Beacon is a plain SwiftPM executable with no helpers or nested code, so the
# bundle is assembled by hand (as in build_app.sh) and Developer-ID signed as a
# single unit. No xcodebuild archive is needed.
#
# Pipeline:
#   1. swift build -c release           compile the executable
#   2. assemble Beacon.app binary + Info.plist + optional icon
#   3. codesign                         Developer ID · hardened runtime · secure timestamp
#   4. notarytool submit --wait         notarize the .app, then stapler staple
#   5. hdiutil                          package the .app into a .dmg
#   6. codesign + notarytool + staple   sign, notarize, and staple the DMG container
#   7. sha256 sidecar
#
# Both the app AND the DMG are notarized on purpose: the app's staple lets it
# launch offline once copied out; the DMG's staple is what clears Gatekeeper on
# DOWNLOAD (an un-notarized container is quarantined even when the app inside is
# fine).
#
# Environment (all optional; sensible defaults):
#   VERSION                   marketing version for the bundle/DMG name
#                             (default: Scripts/Info.plist CFBundleShortVersionString)
#   SIGNING_IDENTITY          codesign identity (default: the pinned Developer ID SHA-1 below)
#   NOTARY_KEYCHAIN_PROFILE   notarytool stored-credentials profile (e.g. "Beacon-Notary")
#     — or NOTARY_APPLE_ID + NOTARY_TEAM_ID + NOTARY_PASSWORD (app-specific password)
#     — or NOTARY_KEY_ID + NOTARY_KEY_ISSUER + NOTARY_KEY_PATH (App Store Connect .p8)
#   With no notary creds the script still emits a SIGNED (un-notarized) DMG + warns.
#
# Notary keychain gotcha: notarytool reads its profile from the session-gated
# data-protection keychain, so it fails with "No Keychain password item found for
# profile" whenever the Mac's screen is LOCKED. Run this while the session is
# unlocked. Earlier stages (build/sign) are unaffected.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

APP_NAME="Beacon"
BUILD_DIR="$PROJECT_DIR/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
INFO_PLIST_SRC="$SCRIPT_DIR/Info.plist"
ENTITLEMENTS="$SCRIPT_DIR/$APP_NAME.entitlements"

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf '\n!!  %s\n' "$*" >&2; }
die()  { printf '\nerror: %s\n' "$*" >&2; exit 1; }

[[ "$(uname)" == "Darwin" ]] || die "must run on macOS"
command -v swift    >/dev/null || die "swift not found (install Xcode)"
command -v codesign >/dev/null || die "codesign not found"
[[ -f "$ENTITLEMENTS" ]] || die "entitlements not found at $ENTITLEMENTS"

# Version: explicit VERSION wins; else read the committed Info.plist. A leading
# "v" (git tag) is stripped, and any pre-release suffix (e.g. 1.5.1-rc.1) is kept
# in the DMG name but dropped from the CFBundle* fields (which must be numeric
# dot-separated, max 3 parts).
VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST_SRC")}"
VERSION="${VERSION#v}"
BUNDLE_VERSION="${VERSION%%-*}"
log "Building $APP_NAME $VERSION (bundle $BUNDLE_VERSION)"

# Developer ID signing identity. Set SIGNING_IDENTITY to your certificate's name
# ("Developer ID Application: Your Name (TEAMID)") or its SHA-1 hash. If your
# keychain holds two same-named certs, signing by NAME is ambiguous ("matches
# multiple identities") — pass the SHA-1 instead. Defaults to matching any
# installed "Developer ID Application" cert by prefix.
SIGN_ID="${SIGNING_IDENTITY:-Developer ID Application}"

# --- 1. Compile -----------------------------------------------------------
log "swift build -c release"
swift build -c release
BINARY_PATH="$(swift build -c release --show-bin-path)/$APP_NAME"
[[ -x "$BINARY_PATH" ]] || die "build succeeded but binary not found at $BINARY_PATH"

# --- 2. Assemble the bundle -----------------------------------------------
log "Assembling $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BINARY_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$INFO_PLIST_SRC" "$APP_BUNDLE/Contents/Info.plist"
PLIST="$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $BUNDLE_VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUNDLE_VERSION" "$PLIST"
if [[ -f "$SCRIPT_DIR/AppIcon.icns" ]]; then
    cp "$SCRIPT_DIR/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$PLIST" 2>/dev/null || true
fi

# --- 3. Developer-ID sign (hardened runtime + secure timestamp) -----------
# Notarization REQUIRES the hardened runtime (--options runtime) and a secure
# timestamp (--timestamp) — the opposite of build_app.sh's ad-hoc, timestamp-less
# local build. A single codesign covers the whole bundle: no nested helpers.
log "Code-signing (Developer ID: $SIGN_ID)"
codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGN_ID" \
    "$APP_BUNDLE" || die "codesign failed (identity '$SIGN_ID' present? try SIGNING_IDENTITY=<sha1>)"
codesign --verify --strict --verbose=2 "$APP_BUNDLE" 2>&1 | sed 's/^/   /' || die "codesign verify failed"

# --- Notary setup ---------------------------------------------------------
NOTARY_TIMEOUT="${NOTARY_TIMEOUT:-30m}"
notary_args=()
if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
    notary_args=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
elif [[ -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_KEY_ISSUER:-}" && -n "${NOTARY_KEY_PATH:-}" ]]; then
    notary_args=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_KEY_ISSUER")
elif [[ -n "${NOTARY_APPLE_ID:-}" && -n "${NOTARY_TEAM_ID:-}" && -n "${NOTARY_PASSWORD:-}" ]]; then
    notary_args=(--apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD")
fi

# notarize_and_staple <label> <submit_path> <staple_path>
# Uploads <submit_path> (bounded --wait) and, on Accepted, staples <staple_path>.
# For the app the upload is a .zip and the staple target is the .app; for the DMG
# both are the .dmg. Aborts the release on any non-Accepted result and dumps the
# notarytool log so the reason isn't opaque.
notarize_and_staple() {
    local label="$1" submit_path="$2" staple_path="$3"
    local submit_json="$BUILD_DIR/notary-$label.json"
    local submit_err="$BUILD_DIR/notary-$label.err"
    log "Notarizing $label (notarytool submit --wait, timeout ${NOTARY_TIMEOUT})"
    set +e
    xcrun notarytool submit "$submit_path" "${notary_args[@]}" \
        --wait --timeout "$NOTARY_TIMEOUT" --output-format json >"$submit_json" 2>"$submit_err"
    local rc=$?
    set -e
    [[ -s "$submit_err" ]] && sed 's/^/   /' "$submit_err" >&2
    local sid status
    sid="$(/usr/bin/plutil -extract id raw -o - "$submit_json" 2>/dev/null || true)"
    [[ -z "$sid" ]] && sid="$(grep -o '"id":"[^"]*"' "$submit_json" 2>/dev/null | head -1 | cut -d'"' -f4)"
    status="$(/usr/bin/plutil -extract status raw -o - "$submit_json" 2>/dev/null || true)"
    if [[ "$status" != "Accepted" ]]; then
        warn "notarization of $label not Accepted (status='${status:-unknown}', rc=${rc}, id='${sid:-unknown}')"
        if [[ -n "$sid" ]]; then
            warn "fetching notarytool log for the rejection reason:"
            xcrun notarytool log "$sid" "${notary_args[@]}" 2>&1 | sed 's/^/   /' || true
        fi
        die "notarization of $label did not complete. Re-poll without re-uploading: \
xcrun notarytool info ${sid:-<id>} ${notary_args[*]}  (or  notarytool log ${sid:-<id>} ...)."
    fi
    log "Notarization of $label Accepted (id ${sid}) — stapling"
    xcrun stapler staple "$staple_path" || die "stapler failed on $staple_path (notarized but not stapled)"
}

# --- 4. Notarize the app --------------------------------------------------
notarized=0
if [[ ${#notary_args[@]} -gt 0 ]]; then
    NOTARIZE_ZIP="$BUILD_DIR/$APP_NAME-notarize.zip"
    ditto -c -k --keepParent "$APP_BUNDLE" "$NOTARIZE_ZIP"
    notarize_and_staple "app" "$NOTARIZE_ZIP" "$APP_BUNDLE"
    rm -f "$NOTARIZE_ZIP"
    notarized=1
else
    warn "No notarytool credentials (NOTARY_KEYCHAIN_PROFILE / NOTARY_APPLE_ID… / NOTARY_KEY_…) — \
producing a SIGNED but UN-NOTARIZED DMG. End users will see a Gatekeeper warning."
fi

# --- 5. Package the DMG ---------------------------------------------------
log "Packaging DMG"
DMG="$BUILD_DIR/$APP_NAME-$VERSION.dmg"
rm -f "$DMG"
STAGING="$BUILD_DIR/dmg-staging"
rm -rf "$STAGING"; mkdir -p "$STAGING"
cp -R "$APP_BUNDLE" "$STAGING/"
ln -s /Applications "$STAGING/Applications"   # drag-to-install affordance
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"

# Sign the DMG container with the same Developer ID so it's trusted, then notarize
# + staple it below. Both layers matter (see header).
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
    codesign --force --sign "$SIGN_ID" --timestamp "$DMG" 2>&1 | sed 's/^/   /' || warn "DMG signing failed"
else
    warn "No Developer ID Application identity in keychain — DMG is unsigned."
fi

# --- 6. Notarize the DMG container ----------------------------------------
# Stapling mutates the DMG, so this MUST run before the sha256 below.
if [[ "$notarized" == "1" ]]; then
    notarize_and_staple "dmg" "$DMG" "$DMG"
    xcrun stapler validate "$DMG" >/dev/null 2>&1 \
        && log "DMG staple validated (Gatekeeper-ready)" \
        || warn "stapler validate on the DMG reported issues"
fi

# --- 7. Hash + summary ----------------------------------------------------
# Compute the sidecar from inside BUILD_DIR so it records just the DMG's basename,
# not the absolute build path (the .sha256 is published, and an absolute path would
# leak the home dir and break `shasum -c` in the user's cwd).
( cd "$BUILD_DIR" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256" )
log "Done: $DMG"
[[ "$notarized" == "1" ]] && echo "    app: signed + notarized + stapled · DMG: signed + notarized + stapled" \
                          || echo "    app: signed (NOT notarized) · DMG: signed"
cat "$DMG.sha256"
