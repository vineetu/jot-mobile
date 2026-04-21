#!/usr/bin/env bash
set -euo pipefail

# Generates the Xcode project from Jot/project.yml via XcodeGen.
# Usage:
#   ./build.sh          — generate project
#   ./build.sh --open   — generate project and open it in Xcode

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOT_DIR="$REPO_ROOT/Jot"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: xcodegen not found on PATH." >&2
  echo "install it with: brew install xcodegen" >&2
  exit 1
fi

if [[ ! -f "$JOT_DIR/project.yml" ]]; then
  echo "error: missing $JOT_DIR/project.yml" >&2
  exit 1
fi

pushd "$JOT_DIR" >/dev/null
echo "→ Running xcodegen in $JOT_DIR"
xcodegen
popd >/dev/null

if [[ "${1:-}" == "--open" ]]; then
  PROJECT="$JOT_DIR/Jot.xcodeproj"
  if [[ ! -d "$PROJECT" ]]; then
    echo "error: expected $PROJECT after generation, but it does not exist" >&2
    exit 1
  fi
  echo "→ Opening $PROJECT"
  open "$PROJECT"
fi

echo "✓ Done."
