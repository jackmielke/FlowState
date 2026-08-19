#!/bin/bash
# Assembles a real VibeVoice.app bundle. A bare SPM binary is NOT an app bundle
# and macOS TCC will silently refuse it mic + screen-recording access, so the
# bundle (with Info.plist + a stable ad-hoc signature) is mandatory, not cosmetic.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${CONFIG:-release}"
APP="VibeVoice.app"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/VibeVoice"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/VibeVoice"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> ad-hoc codesign (stable identity for TCC)"
codesign --force --deep --sign - --timestamp=none "$APP" 2>&1 | sed 's/^/    /'
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

echo "==> done: $(pwd)/$APP"
