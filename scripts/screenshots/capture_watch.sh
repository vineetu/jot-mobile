#!/usr/bin/env bash
#
# Capture Apple Watch Jot screenshots from a booted watchOS simulator.
#   01-watch-home.png       — the "Jot down" home
#   02-watch-recording.png  — the live recording screen (red dot + waveform)
#
# Output: docs/screens/gallery/_watch/
#
# Tapping is done with cliclick against the Simulator window pinned to a fixed
# position; the WIN_/TAP_ constants below are calibrated for an Apple Watch
# Ultra 3 (49mm) window. Re-calibrate if you use a different watch.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(cd "$HERE/../.." && pwd)/docs/screens/gallery/_watch"
WAPP="com.vineetu.jot.mobile.Jot.watch"
mkdir -p "$OUT"

UUID_RE='[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}'
WATCH="$(xcrun simctl list devices booted | grep -i watch | grep -oE "$UUID_RE" | head -1)"
[ -n "$WATCH" ] || { echo "No booted Apple Watch simulator." >&2; exit 1; }

WIN_X=800; WIN_Y=60
JOTDOWN_TAP="956,246"   # "Jot down" button
CANCEL_TAP="835,121"    # recording-screen "X" (cancel)

raise_watch() {
  osascript >/dev/null 2>&1 <<EOF || true
tell application "Simulator" to activate
tell application "System Events" to tell process "Simulator"
  set ww to (first window whose name contains "Watch" or name contains "Ultra")
  set position of ww to {$WIN_X, $WIN_Y}
  perform action "AXRaise" of ww
end tell
EOF
}

# Screenshot with a retry — the watch display can briefly dim/race simctl io.
shot() {
  local path="$1" i
  for i in 1 2 3; do
    if xcrun simctl io "$WATCH" screenshot --type=png "$path" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "    WARN: screenshot failed: $path" >&2
}

raise_watch
xcrun simctl launch "$WATCH" "$WAPP" >/dev/null 2>&1 || true
sleep 4
shot "$OUT/01-watch-home.png"
echo "    01-watch-home.png"

# Tap "Jot down" -> live recording, capture, then cancel back to home.
osascript -e 'tell application "Simulator" to activate' >/dev/null 2>&1; sleep 0.4
cliclick "c:$JOTDOWN_TAP"
sleep 5   # let the recording transition settle; simctl io races a shorter wait
shot "$OUT/02-watch-recording.png"
echo "    02-watch-recording.png"
osascript -e 'tell application "Simulator" to activate' >/dev/null 2>&1; sleep 0.3
cliclick "c:$CANCEL_TAP"
echo "==> done: $OUT"
