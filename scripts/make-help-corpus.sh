#!/bin/bash
# Regenerate Jot/Resources/help-corpus.json from Jot/features.md.
#
# Pipeline (see scripts/help-corpus/ + docs/ask-product-help/design.md):
#   1. parse_corpus.py  — features.md → structural §N.M sections (clean markdown,
#                         drop caveat/bug entries §5.10/§7.3/§7.11).
#   2. make_chunks.py   — sections → structural chunks (recursive-512 fallback for
#                         oversized subsections). Chunking choice was settled by an
#                         offline retrieval experiment (structural beat LLM- and
#                         embedding-based semantic chunking on this corpus).
#   3. stamp_corpus.py  — write the text-only bundle + sourceHash(features.md).
#                         The app retrieves lexically (BM25) via the Ask model's
#                         `JotHelpSearchTool`; there is no embedder any more.
#
# Run from anywhere. Requires python3 only.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GEN="$ROOT/scripts/help-corpus"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "→ parsing features.md…"
python3 "$GEN/parse_corpus.py" "$ROOT/Jot/features.md" "$WORK/corpus_sections.json"

echo "→ structural chunking…"
python3 "$GEN/make_chunks.py" "$WORK/corpus_sections.json" "$WORK/chunks_structural.json"

echo "→ stamping…"
python3 "$GEN/stamp_corpus.py" \
    "$WORK/chunks_structural.json" \
    "$ROOT/Jot/features.md" \
    "$ROOT/Jot/Resources/help-corpus.json"

echo "✓ wrote Jot/Resources/help-corpus.json"
"$ROOT/scripts/check-help-corpus-fresh.sh"
