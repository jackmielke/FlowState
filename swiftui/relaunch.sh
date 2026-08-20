#!/usr/bin/env bash
# Build, install and relaunch Vantage — without touching anything else.
#
# WHY THIS SCRIPT EXISTS
# The obvious command is wrong and quietly harmful:
#
#     pkill -f "Flow.app/Contents/MacOS"     # DO NOT
#
# `pkill -f` matches a substring of the whole command line, and
# "/Applications/Wispr Flow.app/Contents/MacOS/Wispr Flow" *contains*
# "Flow.app/Contents/MacOS". So that pattern killed Wispr Flow — an unrelated app
# the user depends on for dictation — on every single rebuild, silently.
#
# `pkill -x` matches the executable NAME exactly, and this app's binary is VibeVoice,
# so it can only ever match this app. Never reintroduce a -f pattern here.
set -euo pipefail
cd "$(dirname "$0")"

APP_BINARY="VibeVoice"                 # executable name inside the bundle
INSTALLED="/Applications/Vantage.app"
SIGN_ID="Vibe Voice Dev"
SIGN_KC="$HOME/Library/Keychains/vibevoice.keychain-db"

echo "==> checking what would be stopped"
if pgrep -x "$APP_BINARY" >/dev/null; then
  pgrep -x "$APP_BINARY" | while read -r pid; do
    echo "    stopping pid $pid ($(ps -o comm= -p "$pid"))"
  done
  pkill -x "$APP_BINARY" || true
  sleep 1
else
  echo "    nothing running"
fi

# Belt and braces: prove no unrelated app was caught by the above.
if pgrep -f "Wispr Flow" >/dev/null; then
  echo "    Wispr Flow still running (as it should be)"
fi

echo "==> build"
./build.sh >/dev/null

echo "==> install to $INSTALLED"
rm -rf "$INSTALLED"
cp -R VibeVoice.app "$INSTALLED"

if [ -f "$SIGN_KC" ] && [ -f "$HOME/.config/vibe-voice/signing/kc.pass" ]; then
  security unlock-keychain -p "$(cat "$HOME/.config/vibe-voice/signing/kc.pass")" "$SIGN_KC" 2>/dev/null
  codesign --force --deep --sign "$SIGN_ID" --keychain "$SIGN_KC" --timestamp=none "$INSTALLED" 2>&1 | sed 's/^/    /'
fi
echo "    designated => $(codesign -d -r- "$INSTALLED" 2>&1 | sed -n 's/^designated => //p')"

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$INSTALLED"

echo "==> launch"
open "$INSTALLED"
sleep 2
echo "    running: $(pgrep -x "$APP_BINARY" | tr '\n' ' ')"
