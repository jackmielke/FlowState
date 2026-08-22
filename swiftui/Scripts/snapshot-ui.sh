#!/bin/bash
# Renders every Settings tab and every moving backdrop to PNG, offscreen.
#
# For looking at a layout change without a screenshot: no window has to be visible, the
# display can be asleep, and nothing needs a Screen Recording grant. The app renders the
# views, writes the files and quits.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-/tmp/flowstate-ui}"
APP="VibeVoice.app"

[ -d "$APP" ] || { echo "build it first: ./build.sh"; exit 1; }

rm -rf "$OUT"
FLOWSTATE_SNAPSHOT="$OUT" "$APP/Contents/MacOS/VibeVoice"

echo
ls -la "$OUT"
