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

# Compile the moving backdrops into Contents/Resources/default.metallib.
#
# SwiftPM does not build .metal files for an executable target, and SwiftUI's
# `ShaderLibrary.default` looks for exactly one path — a `default.metallib` in the main
# bundle — so it is compiled here by hand. The Metal compiler ships with Xcode's Metal
# Toolchain component, not with the Command Line Tools, so a Mac without it must still
# produce a working app: the step is skipped with a warning and MotionLibrary falls back
# to the drawn Canvas version at runtime. Do not make this fatal.
if xcrun -sdk macosx metal -v >/dev/null 2>&1; then
  echo "==> compiling shaders -> default.metallib"
  AIR="$(mktemp -d)/Motion.air"
  xcrun -sdk macosx metal -O -c Resources/Shaders/Motion.metal -o "$AIR"
  xcrun -sdk macosx metallib "$AIR" -o "$APP/Contents/Resources/default.metallib"
  rm -rf "$(dirname "$AIR")"
else
  echo "==> NO Metal compiler — moving backdrops will use the drawn fallback"
  echo "    install it with: xcodebuild -downloadComponent MetalToolchain"
fi

# Video loops for the moving backdrops, if this build ships any. None do today — the
# bundle is two megabytes and video is not — but a build that drops files in here gets
# them found without a code change. User-installed loops live outside the bundle, under
# Application Support, and are preferred over these.
if [ -d Resources/Motion ]; then
  echo "==> bundling motion loops"
  cp -R Resources/Motion "$APP/Contents/Resources/Motion"
fi

# Sign with a STABLE identity so macOS privacy permissions survive a rebuild.
#
# Ad-hoc signing (`--sign -`) makes the designated requirement a raw cdhash — the hash
# of the binary itself. Every rebuild therefore looks like a brand-new app to TCC and
# silently voids the Screen Recording and Microphone grants, which is maddening to
# debug because the toggle stays visibly ON in System Settings.
#
# Signing with a self-signed cert instead yields
#     identifier "com.jackmielke.vibevoice" and certificate leaf = H"…"
# which does not change when the binary does. Create it with Scripts/make-signing-id.sh.
SIGN_KC="$HOME/Library/Keychains/vibevoice.keychain-db"
SIGN_ID="Vibe Voice Dev"

if [ -f "$SIGN_KC" ] && [ -f "$HOME/.config/vibe-voice/signing/kc.pass" ]; then
  echo "==> codesign with stable identity ($SIGN_ID)"
  security unlock-keychain -p "$(cat "$HOME/.config/vibe-voice/signing/kc.pass")" "$SIGN_KC" 2>/dev/null
  codesign --force --deep --sign "$SIGN_ID" --keychain "$SIGN_KC" --timestamp=none "$APP" 2>&1 | sed 's/^/    /'
else
  echo "==> ad-hoc codesign (NO stable identity — permissions will reset on every build)"
  echo "    run Scripts/make-signing-id.sh once to fix that"
  codesign --force --deep --sign - --timestamp=none "$APP" 2>&1 | sed 's/^/    /'
fi
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /'
echo "    designated => $(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')"

echo "==> done: $(pwd)/$APP"
cat <<'NOTE'

    NOTE: this is an ad-hoc signature, so the bundle's cdhash just changed.
    TCC pins Screen Recording (and Microphone) grants to that hash, so an
    existing grant may now be stale — the toggle still looks ON while macOS
    denies the new binary. If the app reports "Screen Recording is off" after
    this build, reset it and grant once more:

        tccutil reset ScreenCapture com.jackmielke.vibevoice

NOTE
