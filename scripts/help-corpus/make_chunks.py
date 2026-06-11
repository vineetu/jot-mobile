#!/usr/bin/env python3
"""Structural chunking of the help sections.

Usage: make_chunks.py <sections.json> <out_chunks.json>

One chunk per §N.M subsection (text = "Title. body", §id kept only as metadata);
any subsection over ~512 tokens is recursively split on sentence boundaries with
15% overlap. Structural chunking was chosen by an offline retrieval experiment —
it beat LLM- and embedding-based semantic chunking on this corpus (see
docs/ask-product-help/design.md).
"""
import json
import re
import sys

CHARS_PER_TOK = 4
TARGET_TOK = 512
OVERLAP = 0.15


def recursive_split(text, target_chars, overlap):
    if len(text) <= target_chars:
        return [text]
    parts = re.split(r"(?<=[.!?])\s+", text)
    spans, cursor = [], 0
    for p in parts:
        idx = text.find(p, cursor)
        idx = idx if idx >= 0 else cursor
        spans.append((idx, idx + len(p)))
        cursor = idx + len(p)
    chunks, i, n = [], 0, len(parts)
    overlap_chars = int(target_chars * overlap)
    while i < n:
        start_i, acc, j = i, 0, i
        while j < n and (acc + len(parts[j]) <= target_chars or j == i):
            acc += len(parts[j]) + 1
            j += 1
        chunks.append(text[spans[start_i][0]:spans[j - 1][1]])
        if j >= n:
            break
        back, bacc = j - 1, 0
        while back > start_i and bacc < overlap_chars:
            bacc += len(parts[back]); back -= 1
        i = max(back + 1, start_i + 1)
    return chunks


def main():
    sections = json.load(open(sys.argv[1]))
    target_chars = TARGET_TOK * CHARS_PER_TOK
    out, cid = [], 0
    for s in sections:
        body = f"{s['title']}. {s['body']}"
        for seg in recursive_split(body, target_chars, OVERLAP):
            out.append({"chunk_id": cid, "id": s["id"], "title": s["title"],
                        "anchor": s["anchor"], "text": seg, "sources": [s["id"]]})
            cid += 1
    json.dump(out, open(sys.argv[2], "w"), indent=2)
    sizes = [round(len(c["text"]) / CHARS_PER_TOK) for c in out]
    print(f"  {len(out)} chunks (mean {round(sum(sizes) / len(sizes))} tok, "
          f"max {max(sizes)})")


if __name__ == "__main__":
    main()
