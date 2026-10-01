# Ask help corpus — generator

Builds `Jot/Resources/help-corpus.json`, the bundled product-help corpus that
powers Ask's "how do I use Jot" lane (`Jot/App/Ask/HelpCorpus.swift`). The Ask
model reaches it through `JotHelpSearchTool`, which retrieves lexically (BM25)
over the chunk text — no embedder, no model download. Design + the chunking
experiment that picked this approach: `docs/ask-product-help/design.md`.

## Regenerate

```sh
scripts/make-help-corpus.sh
```

Run it whenever `Jot/features.md` changes. `scripts/check-help-corpus-fresh.sh`
fails if the bundled corpus is stale vs `features.md` (compares a sha256 stamped
into the JSON), so a forgotten regenerate is caught rather than silently shipping
stale help.

## Pipeline

1. `parse_corpus.py` — `features.md` → structural `§N.M` sections. Flattens
   markdown, drops the caveat/bug entries (§5.10/§7.3/§7.11) so non-working UI
   never becomes a help answer.
2. `make_chunks.py` — sections → structural chunks (one per `§N.M`,
   recursive-512 fallback for oversized subsections).
3. `stamp_corpus.py` — writes the text-only bundle and stamps `sourceHash`.

## Requirements

python3 only.
