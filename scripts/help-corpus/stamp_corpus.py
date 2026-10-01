#!/usr/bin/env python3
"""Write Jot/Resources/help-corpus.json from the structural chunks.

Usage: stamp_corpus.py <chunks_structural.json> <features.md> <help-corpus.json>

The app retrieves from this corpus lexically (BM25 in `HelpCorpusIndex`), so
each chunk carries only its text + metadata — no vectors, no embedder. The
bundle stamps `features.md`'s sha256 as `sourceHash` so
`scripts/check-help-corpus-fresh.sh` can detect a stale corpus.
"""
import hashlib, json, sys

chunks_path, features_path, out_path = sys.argv[1:4]
chunks = json.load(open(chunks_path))
source_hash = hashlib.sha256(open(features_path, "rb").read()).hexdigest()
out = {
    "sourceHash": source_hash,
    "chunks": [
        {"id": c["id"], "title": c["title"], "anchor": c["anchor"], "text": c["text"]}
        for c in chunks
    ],
}
with open(out_path, "w") as f:
    json.dump(out, f, ensure_ascii=False, indent=1)
    f.write("\n")
print(f"  {len(out['chunks'])} chunks, sourceHash={source_hash[:12]}…")
