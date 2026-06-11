#!/usr/bin/env python3
"""features.md -> structural §N.M help sections (JSON).

Usage: parse_corpus.py <features.md> <out_sections.json>

Each ### N.M subsection becomes one record {id,title,section,anchor,body,tokens}.
Markdown cross-links / bold / code spans are flattened to plain prose, and the
caveat/bug-documenting entries (features.md deliberately keeps these to describe
NON-working or buggy UI) are excluded so they never become help answers.
"""
import json
import re
import sys

# Caveat / bug entries — must NOT become user-facing help (see CLAUDE.md rules).
CAVEAT_IDS = {"5.10", "7.3", "7.11"}


def clean_md(s: str) -> str:
    s = re.sub(r"\[([^\]]+)\]\(#[^)]*\)", r"\1", s)   # [label](#anchor) -> label
    s = re.sub(r"\*\*([^*]+)\*\*", r"\1", s)            # **bold** -> bold
    s = re.sub(r"`([^`]+)`", r"\1", s)                  # `code` -> code
    return s


def approx_tokens(s: str) -> int:
    return max(1, round(len(s) / 4))  # ~4 chars/token (matches app's chunker)


def anchor_for(num: str, title: str) -> str:
    base = f"{num} {title}".lower().replace("&", "")
    base = re.sub(r"[^a-z0-9 .-]", "", base).replace(".", "-").replace(" ", "-")
    return re.sub(r"-+", "-", base).strip("-")


def main():
    src, out = sys.argv[1], sys.argv[2]
    lines = open(src).readlines()
    start = next((i for i, ln in enumerate(lines) if re.match(r"^## 1\. ", ln)), 0)

    sections, cur_section, cur, body = [], None, None, []

    def flush():
        nonlocal cur, body
        if cur is not None:
            cur["body"] = "".join(body).strip()
            sections.append(cur)
        cur, body = None, []

    for ln in lines[start:]:
        m_sec = re.match(r"^## (\d+)\. (.+?)\s*$", ln)
        m_sub = re.match(r"^### (\d+\.\d+)\s+(.+?)\s*$", ln)
        if m_sec:
            flush(); cur_section = f"{m_sec.group(1)}. {m_sec.group(2)}"; continue
        if m_sub:
            flush()
            num, title = m_sub.group(1), m_sub.group(2)
            cur = {"id": num, "title": title, "section": cur_section or "",
                   "anchor": anchor_for(num, title)}
            continue
        if ln.startswith("---"):
            continue
        if cur is not None:
            body.append(ln)
    flush()

    sections = [s for s in sections if s.get("body") and s["id"] not in CAVEAT_IDS]
    for s in sections:
        s["body"] = clean_md(s["body"]).strip()
        s["tokens"] = approx_tokens(s["body"])

    json.dump(sections, open(out, "w"), indent=2)
    print(f"  {len(sections)} sections "
          f"(mean {round(sum(s['tokens'] for s in sections) / len(sections))} tok)")


if __name__ == "__main__":
    main()
