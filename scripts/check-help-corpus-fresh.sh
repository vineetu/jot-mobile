#!/bin/bash
# Guard: fail if the bundled Ask help corpus is stale vs features.md.
#
# The help lane (App/Ask/HelpCorpus.swift) answers "how do I use Jot" questions
# from Jot/Resources/help-corpus.json, which is distilled + pre-embedded from
# Jot/features.md at build time. If features.md changes but the corpus isn't
# regenerated, Ask would answer product questions from stale docs — invisibly.
# This mirrors scripts/check-schema-frozen.sh's freeze discipline.
#
# Regenerate with: scripts/make-help-corpus.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FEATURES="$ROOT/Jot/features.md"
CORPUS="$ROOT/Jot/Resources/help-corpus.json"

if [ ! -f "$CORPUS" ]; then
  echo "ERROR: $CORPUS missing — run scripts/make-help-corpus.sh" >&2
  exit 1
fi

have="$(shasum -a 256 "$FEATURES" | awk '{print $1}')"
want="$(python3 -c "import json; print(json.load(open('$CORPUS'))['sourceHash'])")"

if [ "$have" != "$want" ]; then
  echo "ERROR: help-corpus.json is STALE vs features.md." >&2
  echo "  features.md sha256: $have" >&2
  echo "  corpus sourceHash:  $want" >&2
  echo "  Regenerate: scripts/make-help-corpus.sh" >&2
  exit 1
fi
echo "help-corpus.json is fresh (sourceHash matches features.md)."
