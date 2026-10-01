#!/usr/bin/env bash
#
# Capture the persona-independent iPhone screens that are reached by tapping
# the home header icons:
#   01-settings.png  — gear icon
#   02-help.png      — "?" icon
#
# Seeds a persona first (default: journalist) so the blurred backdrop behind
# each sheet shows real content. Output: docs/screens/gallery/_app/
#
# Tap coordinates are calibrated for the iPhone Simulator window pinned at
# WIN_X/WIN_Y. If you move/resize the window or use a different device, re-run
# the calibration in scripts/screenshots/README.md.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
OUT="$REPO/docs/screens/gallery/_app"
BUNDLE="com.vineetu.jot.mobile.Jot"
PERSONA="${1:-journalist}"
mkdir -p "$OUT"

UUID_RE='[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}'
UDID="$(xcrun simctl list devices booted | grep iPhone | grep -oE "$UUID_RE" | head -1)"
[ -n "$UDID" ] || { echo "No booted iPhone simulator." >&2; exit 1; }

WIN_X=40; WIN_Y=50
GEAR_TAP="382,181"   # home header gear  -> Settings
HELP_TAP="324,181"   # home header "?"   -> Help

position_window() {
  osascript >/dev/null 2>&1 <<EOF || true
tell application "Simulator" to activate
tell application "System Events" to tell process "Simulator"
  set ip to (first window whose name contains "iPhone")
  set position of ip to {$WIN_X, $WIN_Y}
  perform action "AXRaise" of ip
end tell
EOF
}

launch_home() {
  xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
  sleep 1
  xcrun simctl launch "$UDID" "$BUNDLE" >/dev/null
  sleep 4
}

tap() { osascript -e 'tell application "Simulator" to activate' >/dev/null 2>&1; sleep 0.4; cliclick "c:$1"; }

position_window
xcrun simctl spawn "$UDID" defaults write "$BUNDLE" jot.setup.completed -bool true
python3 "$HERE/seed_persona.py" "$HERE/personas/$PERSONA.json" --udid "$UDID" >/dev/null

launch_home
tap "$GEAR_TAP"; sleep 2
xcrun simctl io "$UDID" screenshot --type=png "$OUT/01-settings.png" >/dev/null 2>&1
echo "    01-settings.png"

launch_home
tap "$HELP_TAP"; sleep 2
xcrun simctl io "$UDID" screenshot --type=png "$OUT/02-help.png" >/dev/null 2>&1
echo "    02-help.png"
echo "==> done: $OUT"
