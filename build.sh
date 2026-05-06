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

# XcodeGen 2.44.1 has a bug with local-path Swift packages: the generated
# pbxproj omits the `package = <ref>;` back-reference inside the
# XCSwiftPackageProductDependency block. Command-line `xcodebuild` tolerates
# it, but the Xcode IDE rejects it with "Missing package product 'X'".
# The patch script below injects the missing line idempotently — running it
# on an already-patched pbxproj is a no-op.
PROJECT_PBXPROJ="$JOT_DIR/Jot.xcodeproj/project.pbxproj"
if [[ -f "$PROJECT_PBXPROJ" ]]; then
  echo "→ Patching XcodeGen local-package back-refs"
  python3 "$REPO_ROOT/scripts/patch_xcodegen_local_pkg.py" "$JOT_DIR/Jot.xcodeproj"
fi

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
