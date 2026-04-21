#!/usr/bin/env bash
# Build Jot for iPhone and sideload it via devicectl.
#
# Usage:
#   export JOT_DEVICE_ID=<Identifier from `xcrun devicectl list devices`>
#   ./dev.sh
#
# Requires: xcodegen, xcbeautify, Xcode 26.3+, iOS 26.2 platform runtime.
# See TESTING.md → "Installing on your iPhone" for the full context.

set -euo pipefail

cd "$(dirname "$0")"

BUNDLE_ID="com.jot.mobile.Jot"
BUILD_LOG_DIR="build-logs"

if [[ -z "${JOT_DEVICE_ID:-}" ]]; then
  echo "error: JOT_DEVICE_ID is not set."
  echo
  echo "  xcrun devicectl list devices"
  echo "  export JOT_DEVICE_ID=<Identifier column value>"
  exit 1
fi

for bin in xcodegen xcbeautify xcodebuild; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "error: $bin not found on PATH. Install with 'brew install xcodegen xcbeautify' or Xcode."
    exit 1
  fi
done

mkdir -p "$BUILD_LOG_DIR"
BUILD_LOG="$BUILD_LOG_DIR/dev-$(date +%Y%m%d-%H%M%S).log"

echo "==> xcodegen"
xcodegen generate --spec Jot/project.yml --project Jot

echo "==> xcodebuild (log: $BUILD_LOG)"
set +e
xcodebuild \
  -project Jot/Jot.xcodeproj \
  -target Jot \
  -sdk iphoneos \
  -configuration Debug \
  build 2>&1 | tee "$BUILD_LOG" | xcbeautify
BUILD_STATUS=${PIPESTATUS[0]}
set -e
if [[ "$BUILD_STATUS" -ne 0 ]]; then
  echo "error: xcodebuild failed. Full log: $BUILD_LOG"
  exit "$BUILD_STATUS"
fi

APP_PATH=$(find "$HOME/Library/Developer/Xcode/DerivedData" \
  -type d -name 'Jot.app' -path '*/Debug-iphoneos/*' -print -quit 2>/dev/null || true)
if [[ -z "$APP_PATH" ]]; then
  echo "error: could not locate Jot.app under DerivedData."
  exit 1
fi
echo "==> product: $APP_PATH"

echo "==> devicectl install ($JOT_DEVICE_ID)"
xcrun devicectl device install app --device "$JOT_DEVICE_ID" "$APP_PATH"

echo "==> devicectl launch $BUNDLE_ID"
xcrun devicectl device process launch --device "$JOT_DEVICE_ID" "$BUNDLE_ID"

cat <<EOF

done. Tail logs in Console.app (select iPhone, filter process = Jot) or:
  idevicesyslog | grep -iE 'Jot(|Keyboard|Widget)'
EOF
