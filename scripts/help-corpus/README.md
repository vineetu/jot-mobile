# Ask help corpus — generator

Builds `Jot/Resources/help-corpus.json`, the bundled, pre-embedded product-help
corpus that powers Ask's "how do I use Jot" lane (`Jot/App/Ask/HelpCorpus.swift`).
Design + the chunking experiment that picked this approach:
`docs/ask-product-help/design.md`.

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
3. `embedder/` (Swift) — embeds each chunk with the **same** bundled
   EmbeddingGemma the app uses (CoreML-LLM `1.9.0`, 256-d), and stamps
   `modelVersion` + `sourceHash`. The `modelVersion` must equal
   `EmbeddingGemmaService.modelVersion`; the app disables the help lane on a
   mismatch rather than scoring against incomparable vectors.

## Requirements

macOS with the bundled EmbeddingGemma model present at
`Jot/Resources/Models/EmbeddingGemma/` (same out-of-band model the app ships).
`embedder/` resolves CoreML-LLM on first `swift run` (network).

> Keep the `CoreML-LLM` pin in `embedder/Package.swift` in sync with
> `Jot/project.yml`. If the app's embedder model/dim ever changes, bump
> `MODEL_VERSION` in `embedder/Sources/embed/main.swift` to match and regenerate.
