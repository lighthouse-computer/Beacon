#!/usr/bin/env bash
#
# build_app.sh — compile, package, sign, and (optionally) launch Beacon.app
#
# Outputs:
#   ./build/Beacon.app   — a runnable, ad-hoc-signed .app bundle
#
# Usage:
#   ./Scripts/build_app.sh                 # build only
#   ./Scripts/build_app.sh --run           # build then launch
#   ./Scripts/build_app.sh --install       # build then copy to /Applications and launch
#   ./Scripts/build_app.sh --debug         # debug config (faster, larger binary)
#
# Designed to be re-run safely; everything inside ./build is regenerated.

set -euo pipefail

# --- Resolve paths ---------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

APP_NAME="Beacon"
BUNDLE_ID="computer.lighthouse.beacon"
BUILD_DIR="$PROJECT_DIR/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
INFO_PLIST_SRC="$SCRIPT_DIR/Info.plist"
ENTITLEMENTS="$SCRIPT_DIR/$APP_NAME.entitlements"

# --- Parse args ------------------------------------------------------------
CONFIG="release"
DO_RUN=0
DO_INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --debug)   CONFIG="debug" ;;
        --run)     DO_RUN=1 ;;
        --install) DO_INSTALL=1; DO_RUN=1 ;;
        --help|-h)
            sed -n '2,18p' "$0"
            exit 0
            ;;
        *)
            echo "Unknown arg: $arg" >&2
            exit 1
            ;;
    esac
done

# --- Sanity checks ---------------------------------------------------------
if [[ "$(uname)" != "Darwin" ]]; then
    echo "This script must run on macOS." >&2
    exit 1
fi

if ! command -v swift >/dev/null 2>&1; then
    echo "swift not found. Install Xcode or Xcode Command Line Tools." >&2
    exit 1
fi

if ! command -v codesign >/dev/null 2>&1; then
    echo "codesign not found — install Xcode Command Line Tools." >&2
    exit 1
fi

# --- Compile ---------------------------------------------------------------
echo "==> Building ($CONFIG)…"
swift build -c "$CONFIG"

# Locate the produced binary. swift gives us a stable accessor for this.
BINARY_PATH="$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"

if [[ ! -x "$BINARY_PATH" ]]; then
    echo "Build succeeded but binary not found at $BINARY_PATH" >&2
    exit 1
fi

# --- Assemble bundle -------------------------------------------------------
echo "==> Assembling $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BINARY_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$INFO_PLIST_SRC" "$APP_BUNDLE/Contents/Info.plist"

# Stamp the real version into the bundled plist. Without this the committed
# Info.plist value ships unchanged, so every release reported a stale version in
# Finder / "About" regardless of the tag. VERSION comes from the release
# workflow (the git tag, leading "v" already stripped above); falls back to the
# plist's existing value for plain local builds.
PLIST="$APP_BUNDLE/Contents/Info.plist"
# The release workflow passes the git tag (e.g. "v1.4.8"); strip the leading
# "v" so the bundle version is a clean numeric-dotted string (CFBundleVersion
# rejects a leading letter).
VERSION="${VERSION#v}"
if [[ -n "${VERSION:-}" && "$VERSION" != "1.0.0" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$PLIST"
    # CFBundleVersion must be digits-and-dots only; reuse the same value.
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$PLIST" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $VERSION" "$PLIST"
fi

# Optional icon — only copy if the user has dropped one in Scripts/AppIcon.icns
if [[ -f "$SCRIPT_DIR/AppIcon.icns" ]]; then
    cp "$SCRIPT_DIR/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" \
        "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true
fi

# --- Sign ------------------------------------------------------------------
# Ad-hoc signing ("-" identity) is enough for local SMAppService and to keep
# Gatekeeper from blocking the launch. The hardened runtime is recommended
# so the bundle survives macOS notarization rules if you later distribute it.
echo "==> Code-signing (ad-hoc)…"
codesign --force \
    --sign - \
    --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --timestamp=none \
    "$APP_BUNDLE"

# Verify the signature is valid (will fail loudly if something is off).
codesign --verify --verbose=2 "$APP_BUNDLE" 2>&1 | sed 's/^/   /'

echo "==> Built $APP_BUNDLE"

# --- Install (optional) ----------------------------------------------------
if [[ "$DO_INSTALL" -eq 1 ]]; then
    DEST="/Applications/$APP_NAME.app"
    echo "==> Installing to $DEST"
    # Kill any running instance so we can overwrite without 'in use' errors.
    pkill -f "$APP_NAME" 2>/dev/null || true
    sleep 0.5
    rm -rf "$DEST"
    cp -R "$APP_BUNDLE" "$DEST"
    APP_BUNDLE="$DEST"
fi

# --- Launch (optional) -----------------------------------------------------
if [[ "$DO_RUN" -eq 1 ]]; then
    echo "==> Launching…"
    # `open -a` resolves by bundle id; `open <path>` always launches that path.
    open "$APP_BUNDLE"
    echo
    echo "Look for ↓ / ↑ in your menu bar (top-right). If you don't see it,"
    echo "check Console.app for 'Beacon' logs."
else
    echo
    echo "Done. To run:"
    echo "  open \"$APP_BUNDLE\""
fi
