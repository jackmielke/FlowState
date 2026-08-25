#!/usr/bin/env bash
# Build, install and relaunch FlowState — without touching anything else.
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
INSTALLED="/Applications/FlowState.app"
SIGN_ID="Vibe Voice Dev"
SIGN_KC="$HOME/Library/Keychains/vibevoice.keychain-db"

echo "==> checking what would be stopped"
if pgrep -x "$APP_BINARY" >/dev/null; then
  pgrep -x "$APP_BINARY" | while read -r pid; do
    echo "    stopping pid $pid ($(ps -o comm= -p "$pid"))"
  done
  # Ask first, kill second.
  #
  # `pkill` sends SIGTERM and a Cocoa app does not turn that into a normal quit, so
  # for months every rebuild killed the app with its voice-processing audio unit
  # still attached to the shared output device — orphaning it inside coreaudiod.
  # Enough of those and EVERY app on the Mac crackles, which is a strange thing to
  # trace back to a build script. The app now tears down on SIGTERM too, but a real
  # quit is still the polite path and runs the same cleanup with no race.
  osascript -e 'tell application "FlowState" to quit' >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8; do
    pgrep -x "$APP_BINARY" >/dev/null || break
    sleep 0.25
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
