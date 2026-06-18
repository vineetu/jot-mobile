# Parakeet V3 Multilingual — Research for Jot Non-English Support

Research date: 2026-06-12. Scope: whether/how to add non-English dictation to Jot (currently English-only, Parakeet TDT-CTC 110M bundled + Parakeet TDT 0.6B v2 opt-in, via FluidAudio CoreML on ANE).

Confidence tags: **Confirmed** = directly observed in model card / source / maintainer comment. **Likely** = strong inference from evidence. **Unverified** = plausible but not directly confirmed.

---

## VERDICT on the owner's belief: "v3 does NOT do a good job on non-English unless the language is explicitly selected"

**Partially confirmed, with an important twist — the truth is worse than the belief in one way and better in another.**

- **The belief is directionally right**: v3's per-language quality is uneven, and short/ambiguous utterances suffer "language contamination" (wrong-language / wrong-script tokens). NeMo users report Slavic/Cyrillic mix-ups and Danish words decoded as Swedish/English. (Confirmed — NeMo issues #14799, #15097.)
- **The twist (the worse part)**: the underlying NVIDIA model **cannot be told the language at all**. The NeMo maintainer states plainly: *"parakeet-v3 model doesn't receive or output language id"* and *"It is not supported by the model to output language."* There is **no working language-forcing knob in the model itself** — the `decoding_cfg.language` trick floated by a user was tested and **does not work**. So "explicitly selecting the language" is not natively possible. (Confirmed — [NeMo #14799](https://github.com/NVIDIA-NeMo/NeMo/issues/14799#issuecomment-3634425420), [NeMo #15097](https://github.com/NVIDIA-NeMo/NeMo/issues/15097).)
- **The twist (the better part)**: FluidAudio has built a **partial workaround on top** — a `TokenLanguageFilter` that takes a caller-supplied `language:` on the transcribe call and suppresses wrong-*script* tokens (e.g. blocks Cyrillic leaking into Polish). This materially helps cross-script confusion **but does NOT disambiguate languages that share a script** (it cannot force English over French, or Polish over Czech — all Latin). (Confirmed — FluidAudio `TokenLanguageFilter.swift` + `Documentation/ASR/TokenLanguageFilter.md`.)

**Net for Jot**: You cannot rely on a true "pick your language" guarantee from v3. You CAN pass a `language:` hint to FluidAudio that meaningfully reduces wrong-script garbage for non-Latin scripts. For same-script languages you are at the mercy of the model's (decent but imperfect) implicit detection. CJK / Arabic / Hindi are **not covered at all** by v3.

---

## Q1. What is Parakeet TDT 0.6B v3, and how does it differ from v2?

- **v3 = multilingual extension of v2.** Same 600M-param FastConformer-TDT architecture, SentencePiece 8,192-token vocab, trained on NVIDIA's Granary dataset (~670k hours). v3 expands coverage from English-only to 25 European languages with implicit (automatic) language handling — no prompting in the public API. (Confirmed — [HF nvidia/parakeet-tdt-0.6b-v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3).)
- **v2 is English-only.** The v2 card explicitly markets v3 as the "Multilingual" successor and lists no other languages for v2. (Confirmed — [HF nvidia/parakeet-tdt-0.6b-v2](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2).)
- **FluidAudio variants** both exist as converted CoreML repos: `FluidInference/parakeet-tdt-0.6b-v2-coreml` (English) and `FluidInference/parakeet-tdt-0.6b-v3-coreml` (multilingual). FluidAudio's own docs describe v3 as *"Batch speech-to-text, 25 European languages (0.6B params). Default ASR model"* and v2 as English. (Confirmed — FluidAudio `Documentation/Models.md`.)

## Q2. Which languages does v3 support — and what are the GAPS?

**Supported (25, all European):** Bulgarian, Croatian, Czech, Danish, Dutch, English, Estonian, Finnish, French, German, Greek, Hungarian, Italian, Latvian, Lithuanian, Maltese, Polish, Portuguese, Romanian, Slovak, Slovenian, Spanish, Swedish, Russian, Ukrainian. (Confirmed — [HF v3 card](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) and [FluidInference v3-coreml card](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml).)

**NOT covered (major gaps):**
- **Chinese, Japanese, Korean — NO.** (Confirmed by absence from list.)
- **Arabic — NO. Hindi — NO. Turkish — NO. Vietnamese, Thai, Indonesian — NO.** (Confirmed by absence.)
- The FluidInference card explicitly warns: *"Primary coverage is European languages; performance may degrade for non-European languages."* (Confirmed.)

**If Jot needs CJK / Arabic / Hindi, v3 is the wrong model.** Within FluidAudio there are *separate* models for those: a dedicated **Parakeet TDT Japanese** (Japanese-only, 6.85% CER on JSUT), **Paraformer-large (zh)** for Mandarin, **SenseVoiceSmall** (50+ languages incl. zh/yue/ja/ko, auto-detected), and **Cohere Transcribe** (14 langs incl. ar/ja/zh/ko/vi, language passed explicitly). These are different model families with their own footprints and APIs — a larger integration effort than just swapping Parakeet versions. (Confirmed — FluidAudio `Documentation/Models.md`.)

## Q3. Language selection behavior — the crux

- **The NVIDIA model auto-detects implicitly and exposes NO language parameter and NO detected-language output.** Maintainer (nithinraok): *"parakeet-v3 model doesn't receive or output language id."* The community `decoding_cfg.language="pt-BR"` workaround was tested by two users and **does not work** (the key doesn't even exist). For language ID, NVIDIA's own recommendation is to run a separate model (`langid_ambernet`) in parallel. (Confirmed — [NeMo #14799](https://github.com/NVIDIA-NeMo/NeMo/issues/14799), [NeMo #15097](https://github.com/NVIDIA-NeMo/NeMo/issues/15097), both Closed.)
- **Accuracy when unspecified is materially worse on hard cases.** Real-user reports: *"parakeet v3 really mixes up Slavic languages, some of which use the Cyrillic alphabet"*; *"language contamination in smaller languages like Danish where it sees some words as Swedish or even English"*; FluidAudio's own long-transcription doc notes *"wrong-language insertions"* and *"wrong-script bursts on multilingual v3 audio"* after attention boundaries. (Confirmed — NeMo #14799/#15097; FluidAudio `Documentation/ASR/LongTranscription.md`.)
- **FluidAudio DOES expose a `language:` hint — at the transcribe call, not in `ASRConfig`.** The Parakeet TDT manager's transcribe entry points take `language: Language? = nil` (defaults to nil = filtering off). Setting it activates the `TokenLanguageFilter`. (Confirmed — `AsrManager+Transcription.swift` / `+Pipeline.swift`: `func transcribe(..., language: Language? = nil)`.)
- **BUT the hint only filters by Unicode SCRIPT (Latin / Cyrillic / Greek), not by language.** It picks the highest-logit top-K candidate whose alphabet matches the requested language's script, suppressing cross-script leakage (the Polish-getting-Cyrillic case, issue #512). Its own docs state the limitation explicitly: *"The filter currently partitions by Unicode script only. Per-language token allowlists (e.g. distinguishing Polish from Czech within the Latin script)"* are future work. So it **cannot** force English over French/German/Spanish (all Latin) — it only stops a Latin-script language from emitting Cyrillic/Greek bursts and vice-versa. (Confirmed — `TokenLanguageFilter.swift`, `Documentation/ASR/TokenLanguageFilter.md`.)
- The `Language` enum FluidAudio recognizes for the filter (30 codes, grouped Latin/Cyrillic/Greek): en, es, fr, de, it, pt, ro, nl, da, sv, fi, hu, et, lv, lt, mt, pl, cs, sk, sl, hr, bs / ru, uk, be, bg, sr / el. (Confirmed — `TokenLanguageFilter.swift`.)
- **The FluidAudio feature request for a fuller language hint + `detectedLanguage` output (issue #303) was Closed without implementation** — the reporter closed it himself, pointing at the NeMo limitation (#14799). So there is no detected-language readback, and no per-language (within-script) forcing in FluidAudio today. (Confirmed — [FluidAudio #303](https://github.com/FluidInference/FluidAudio/issues/303), state closed/completed, single comment links to the NeMo issue.)

## Q4. English accuracy & footprint: v3 vs v2

- **English gets slightly WORSE on v3.** FluidAudio's benchmarks: average WER v2 = 2.1% vs v3 = 2.6%; FLEURS English(US) v3 = 5.4% WER. The docs advise: *"Use v2 if you only need English, it is a bit more accurate."* On the NVIDIA Open ASR Leaderboard, v2 averages 6.05% (LS test-clean 1.69 / test-other 3.19) vs v3 6.34% (test-clean 1.93 / test-other 3.59). (Confirmed — FluidAudio `Documentation/Benchmarks.md`; [HF v2](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2) / [v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) cards.)
- **Multilingual quality is very uneven.** FLEURS WER per language ranges from Italian 4.0% / Spanish 4.5% / French 5.9% / German 5.9% (good) to Greek 36.9%, Slovenian 27.4%, Latvian 27.1% (poor). 24-language average 14.7% WER. (Confirmed — `Documentation/Benchmarks.md`.)
- **Footprint vs the 6GB-RAM wall:** The v3 CoreML HF repo totals **2.99 GB on disk across 84 files, but that is misleading** — it ships duplicate `.mlmodelc` + `.mlpackage` copies and multiple variants. The distinct heavy weights are Encoder 445MB, MelEncoder 595MB, EncoderInt4 297MB, ParakeetEncoder_15s 445MB (streaming), plus small decoders/joints (~12–37MB each). The runtime working set is a subset (~1–1.5GB of weights for one encoder path), not 3GB. v2's repo is 2.58GB and similarly carries variants (its big ParakeetEncoder is 1.18GB fp + 591MB v2 + 305MB 4bit). **Exact loaded-RAM delta v3-vs-v2 on a 6GB device is Unverified — must be measured on-device**, but v3's per-path encoder (445MB) is not obviously heavier than v2's, so the RAM wall is likely tolerable for one model loaded at a time. Do not assume; profile. (Confirmed file sizes — HF API for both repos. RAM behavior — Unverified.)
- **Download size per language is NOT per-language** — v3 is one ~monolithic bundle covering all 25 langs; you download the whole v3 model regardless of which language(s) the user picks. There is no per-language pack for Parakeet. (Confirmed — single repo, no language sharding in `AsrModels.swift` / `Models.md`.)

## Q5. FluidAudio support status for v3

- **v3 is fully available and converted in FluidAudio today** (CoreML), is in fact the package's *default* ASR version (`AsrModelVersion` enum has `.v2` and `.v3`; multiple helpers default to `.v3`). Loaded via `AsrModels.downloadAndLoad(version: .v3)`. (Confirmed — `Sources/.../TDT/AsrModels.swift`: `case v2 / case v3`, `version: AsrModelVersion = .v3`.)
- **Known issues / limitations actively documented**: wrong-script bursts on short/ambiguous and post-boundary audio (#512, addressed partially by `TokenLanguageFilter`); no language-ID output; uneven per-language WER. (Confirmed — FluidAudio `TokenLanguageFilter.md`, `LongTranscription.md`.)
- A FLEURS regression benchmark across all 24 v3 languages exists (`Scripts/fleurs_parakeet_sub_benchmark.sh`), so the maintainers track multilingual quality. (Confirmed.)

## Q6. Practical recommendation for "ask language → download model"

1. **Keep English on v2** (English-optimized, ~0.5pt lower WER, English is the no-choice default). Don't move English users to v3. (Confirmed rationale — Q4.)
2. **For the 24 other European languages, use v3.** Map the user's chosen language to the v3 model + **always pass the FluidAudio `language:` hint** matching their selection. This is free insurance against cross-script leakage and is the only language control available. There is no downside to setting it. (Confirmed mechanism — Q3.)
3. **Set realistic expectations in the UI for weak languages** (Greek, Baltic, several Slavic) — WER can be 25–37%. Consider only surfacing the strong-tier languages (es/it/fr/de/pt/nl + English) as "supported well," and gating the rest behind a "beta / experimental" label, or omitting them. (Confirmed WER spread — Q4.)
4. **Do NOT promise same-script disambiguation.** The `language:` hint will not stop French bleeding into an English transcript or vice-versa; that is implicit-detection territory and imperfect. If users frequently code-switch within Latin scripts, expect occasional wrong-language words. (Confirmed limitation — Q3.)
5. **CJK / Arabic / Hindi are out of scope for v3.** If the owner wants those, it is a separate, larger project using a different FluidAudio model family (SenseVoice for zh/ja/ko broad coverage, dedicated Parakeet-Japanese, Paraformer-zh, or Cohere Transcribe for ar/ja/zh/ko/vi with explicit language). Each is its own download + API + footprint. Flag as a distinct decision, not a v3 setting. (Confirmed — Q2.)
6. **Download story:** one ~v3 bundle (not per-language) is downloaded when the user opts into any non-English European language; English stays on v2 (already an opt-in download in Jot today) or the bundled 110M. Two model families max on-device; load one at a time to respect the 6GB wall — **measure peak RAM on a 12 Pro before shipping** (footprint delta is Unverified). (Confirmed structure; RAM Unverified.)
7. **No detected-language readback exists** — if Jot ever wants to auto-route by language or auto-pick a model, you must run a separate language-ID step (NVIDIA suggests `langid_ambernet`; FluidAudio offers no built-in LID for Parakeet). For an "ask the user" design this is fine — the user tells you the language, you set the hint. (Confirmed — Q3.)

---

### Sources
- NVIDIA model cards: https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3 , https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2
- FluidInference CoreML cards: https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml , .../parakeet-tdt-0.6b-v2-coreml
- NeMo issues (language forcing / detection): https://github.com/NVIDIA-NeMo/NeMo/issues/14799 , https://github.com/NVIDIA-NeMo/NeMo/issues/15097
- FluidAudio issue #303 (closed, not implemented): https://github.com/FluidInference/FluidAudio/issues/303
- FluidAudio source/docs (main branch): `Sources/FluidAudio/Shared/TokenLanguageFilter.swift`, `Sources/FluidAudio/ASR/Parakeet/SlidingWindow/TDT/{AsrModels.swift,AsrManager+Transcription.swift,AsrManager+Pipeline.swift}`, `Documentation/ASR/{TokenLanguageFilter.md,GettingStarted.md,LongTranscription.md}`, `Documentation/Models.md`, `Documentation/Benchmarks.md` — https://github.com/FluidInference/FluidAudio
- HF file-size API: https://huggingface.co/api/models/FluidInference/parakeet-tdt-0.6b-v3-coreml?blobs=true
