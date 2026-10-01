#!/usr/bin/env bash
#
# Capture persona-specific Jot screenshots from a booted iPhone simulator.
#
# For the given persona it:
#   1. terminates the app and skips the setup wizard
#   2. seeds the persona's transcripts into the Core Data store
#   3. cold-launches at the Recents home and screenshots it
#   4. deep-links each "feature" transcript and screenshots the detail
#
# Output: docs/screens/gallery/<persona>/NN-*.png
#
# Usage: ./capture.sh <persona>            # persona = basename of personas/<x>.json
#        ./capture.sh all                  # every persona JSON
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
PERSONA_DIR="$HERE/personas"
OUT_ROOT="$REPO/docs/screens/gallery"
BUNDLE="com.vineetu.jot.mobile.Jot"

# Resolve the booted iPhone UDID.
UUID_RE='[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}'
UDID="$(xcrun simctl list devices booted | grep iPhone | grep -oE "$UUID_RE" | head -1)"
[ -n "$UDID" ] || { echo "No booted iPhone simulator." >&2; exit 1; }

# Pin the iPhone Simulator window to a fixed on-screen position so the
# calibrated cliclick tap on the "Open in Jot?" deep-link confirmation lands.
# (simctl openurl always routes custom schemes through that system alert; the
# alert is centered and content-independent, so one calibrated tap suffices.)
WIN_X=40; WIN_Y=50
OPEN_TAP="277,541"   # screen pts of the alert's blue "Open" button at WIN_X/Y

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

# Tap the "Open" button of the deep-link confirmation alert.
tap_open() {
  osascript -e 'tell application "Simulator" to activate' >/dev/null 2>&1 || true
  sleep 0.4
  cliclick "c:$OPEN_TAP"
}

settle() { sleep "${1:-4}"; }

capture_one() {
  local persona="$1"
  local json="$PERSONA_DIR/$persona.json"
  [ -f "$json" ] || { echo "No persona file: $json" >&2; return 1; }
  local out="$OUT_ROOT/$persona"
  mkdir -p "$out"

  echo "==> $persona  (sim $UDID)"
  position_window
  xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
  xcrun simctl spawn "$UDID" defaults write "$BUNDLE" jot.setup.completed -bool true

  # Seed; capture the feature id<TAB>label lines.
  local features
  features="$(python3 "$HERE/seed_persona.py" "$json" --udid "$UDID")"

  # Recents home (cold launch, no deep link).
  xcrun simctl launch "$UDID" "$BUNDLE" >/dev/null
  settle 5
  xcrun simctl io "$UDID" screenshot --type=png "$out/01-recents-home.png" >/dev/null
  echo "    01-recents-home.png"

  # One detail screenshot per feature transcript.
  local n=1
  while IFS=$'\t' read -r id label; do
    [ -n "$id" ] || continue
    n=$((n + 1))
    # Relaunch to a clean home, THEN deep-link while running. openurl on a
    # terminated app springboards the "Open in Jot?" system prompt; openurl
    # on the running, frontmost app routes straight through onOpenURL.
    xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
    sleep 1
    xcrun simctl launch "$UDID" "$BUNDLE" >/dev/null
    settle 4
    xcrun simctl openurl "$UDID" "jot://transcript?id=$id" >/dev/null
    sleep 2
    tap_open          # confirm the "Open in Jot?" alert
    settle 3
    printf -v file "%02d-detail.png" "$n"
    xcrun simctl io "$UDID" screenshot --type=png "$out/$file" >/dev/null
    echo "    $file  ($label)"
  done <<< "$features"

  echo "==> done: $out"
}

if [ "${1:-}" = "all" ]; then
  for f in "$PERSONA_DIR"/*.json; do
    capture_one "$(basename "$f" .json)"
  done
else
  capture_one "${1:?usage: capture.sh <persona|all>}"
fi
