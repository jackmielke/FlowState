#!/usr/bin/env bash
#
# The fast loop: edit -> running app, in about ten seconds.
#
# `relaunch.sh` builds -c release, which whole-module-optimises the entire app on every
# run. Measured on this machine, after changing a single line:
#
#     release build   23.2s
#     debug build      2.5s
#     the 585 tests    1.3s
#
# The tests were never the expensive part, which is worth saying out loud because they
# look like the expensive part — they are the thing that scrolls past. Release
# optimisation is the cost, and nothing about trying a hotkey needs it.
#
# So this is the same relaunch with CONFIG=debug, and the tests kept, because at 1.3s
# they are cheaper than finding out by hand that the build was broken.
#
# Use relaunch.sh for anything you intend to keep or ship — the release binary is what
# gets signed, notarised and handed to somebody else, and it is the only one whose
# performance means anything.
set -euo pipefail
cd "$(dirname "$0")"

start=$(python3 -c 'import time; print(time.time())')

if [ "${SKIP_TESTS:-0}" != "1" ]; then
  echo "==> tests"
  if ! swift test 2>&1 | grep -E "Executed .* tests" | tail -1; then
    echo "    tests failed — not installing" >&2
    exit 1
  fi
fi

CONFIG=debug ./relaunch.sh

python3 -c "import time; print(f'==> {time.time() - $start:.1f}s, edit to running')"
