#!/usr/bin/env bash
# Launch exactly ONE of the three implementations at a time.
#
#   ./try.sh swift | electron | tauri
#   ./try.sh stop            kill whatever is running
#   ./try.sh status          what's running right now
#
# Running two at once makes them talk to each other through your speakers, so this
# always kills the others first. That is the whole point of the script.
set -uo pipefail
cd "$(dirname "$0")"

kill_all() {
  pkill -f "VibeVoice.app/Contents/MacOS/VibeVoice"      2>/dev/null
  pkill -f "vibe-voice/electron/node_modules/electron"   2>/dev/null
  pkill -f "vibe-voice/tauri/node_modules/.bin/tauri"    2>/dev/null
  pkill -f "target/debug/vibe-voice"                     2>/dev/null
  pkill -f "target/debug/tauri"                          2>/dev/null
  sleep 1
}

running() {
  pgrep -fl "VibeVoice.app/Contents/MacOS|vibe-voice/electron/node_modules/electron|vibe-voice/tauri" 2>/dev/null \
    | grep -v pgrep || true
}

case "${1:-}" in
  stop)
    kill_all; echo "stopped."; exit 0 ;;
  status)
    r="$(running)"
    [ -z "$r" ] && echo "nothing running." || echo "$r"
    exit 0 ;;
  swift)
    kill_all
    [ -d swiftui/VibeVoice.app ] || { echo "not built — run: (cd swiftui && ./build.sh)"; exit 1; }
    echo "==> SwiftUI (native).  Echo cancellation: ON"
    open swiftui/VibeVoice.app ;;
  electron)
    kill_all
    [ -d electron/node_modules ] || { echo "installing deps..."; (cd electron && npm install --silent); }
    echo "==> Electron.  Echo cancellation: ON (Chromium)"
    (cd electron && npm start >/tmp/vv-electron.log 2>&1 &)
    echo "    logs: /tmp/vv-electron.log" ;;
  tauri)
    kill_all
    [ -d tauri/node_modules ] || { echo "installing deps..."; (cd tauri && npm install --silent); }
    echo "==> Tauri.  Echo cancellation: ON (WKWebView)"
    echo "    first run compiles Rust — can take several minutes"
    (cd tauri && source "$HOME/.cargo/env" 2>/dev/null; npm run tauri dev >/tmp/vv-tauri.log 2>&1 &)
    echo "    logs: /tmp/vv-tauri.log" ;;
  *)
    sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
    echo ""
    echo "currently running:"
    r="$(running)"; [ -z "$r" ] && echo "  nothing" || echo "$r"
    exit 1 ;;
esac

sleep 3
echo ""
echo "Test checklist — same for all three, so results are comparable:"
echo "  1. Click Connect. It should go live within ~2s."
echo "  2. Say 'hey, can you hear me?' — watch the transcript."
echo "  3. SPEAKERS ON, no headphones. Let it reply. It must NOT answer itself."
echo "  4. Interrupt it mid-sentence. It should stop immediately."
echo "  5. Hit the screenshot button (or Cmd-Shift-2), ask 'what's on my screen?'"
echo "  6. Settings -> Continuous screen mode. Confirm the WATCHING badge appears."
echo ""
echo "When done:  ./try.sh stop"
