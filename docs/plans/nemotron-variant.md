# Plan: Nemotron 0.6B Speech Variant (tested + ripped — too slow on iPhone)

> **Status:** Tested in 1.0.2 (22–26) and ripped in (27) on 2026-05-26. Nemotron 0.6B was integrated and dictation worked end-to-end on the bench, but on-device real-time-factor on iPhone was 3–5× slower than real-time, producing a 10–15 second tail after stop. Smaller chunk sizes helped (560ms ≈ 2× faster than 1120ms with negligible accuracy delta — 2.12% vs 1.99% WER per FluidAudio's M2 LibriSpeech bench), but the underlying problem is that Nemotron 0.6B's int8 encoder is too heavy for iPhone's Neural Engine to run faster than mic audio arrives. Build 27 removed the variant and added a one-shot cleanup sweep (`TranscriptionService.sweepNemotronAppSupportWeights`) to reclaim the ~600 MB – 1.1 GB of stale weights from users who downloaded during the TestFlight cycle.
>
> **What we'd revisit this for:** a smaller Nemotron variant (the 0.6B is the only size FluidAudio ships today), a different RNNT-streaming model with iPhone-friendlier inference cost, or a future iPhone generation with materially faster ANE for large encoders. Not blocking on any of these.
>
> **Implementation notes still worth keeping below** for the next attempt: scope estimate was wrong (we thought 1–2 days, it was actually ~half a day because `StreamingTranscriptionEngine` already takes `any StreamingAsrManager`), Settings download UX patterns, the AppGroup allowlist trap (legacy guard rewrites `nemotron0_6b` to default — must add to allowlist when re-introducing), and the Nemotron disk-existence check (must verify all 6 required files, not just the encoder directory).

---

## Intent

Let the user pick **NVIDIA Nemotron 0.6B** as the speech model variant alongside Parakeet TDT-CTC 110M and Parakeet 0.6B v2. Nemotron is FluidAudio-supported as a *streaming-only* model — no batch counterpart exists. This makes it a fundamentally different shape from the existing Parakeet variants and requires a real refactor, not just an enum case.

Why we want to test it:
- Nemotron is a different architecture (cache-aware streaming encoder), may produce noticeably different transcription quality on Vineet's voice.
- If it's good enough end-to-end, we drop the batch step entirely for Nemotron users — simpler dictation pipeline, no "preview vs final" mismatch.
- Future variant of the on-device personalization plan may want a smaller-footprint speech model; understanding Nemotron's quality envelope feeds that decision.

## What's in FluidAudio today

`StreamingModelVariant` enum in
`SourcePackages/checkouts/FluidAudio/Sources/FluidAudio/ASR/Parakeet/Streaming/ParakeetModelVariant.swift`
already declares the relevant cases:

- `nemotron560ms = "nemotron-560ms"` — Nemotron 0.6B @ 560 ms chunks (balanced).
- `nemotron1120ms = "nemotron-1120ms"` — Nemotron 0.6B @ 1120 ms chunks (best accuracy).
- (Parakeet EOU variants live in the same enum but already wired through `StreamingEouAsrManager`.)

The Nemotron-specific manager lives at
`SourcePackages/.../FluidAudio/ASR/Parakeet/Streaming/Nemotron/StreamingNemotronAsrManager.swift`.
Surface:

- `init(configuration: MLModelConfiguration, requestedChunkSize: NemotronChunkSize?)` — different shape from `StreamingEouAsrManager.init`.
- `loadModels(modelDir: URL) async throws` — same pattern but downloads from a different HuggingFace repo if no directory is passed (auto-download is wired into `loadModels()` overload, not `loadModels(from:)`).
- `setPartialCallback(_ callback: @escaping NemotronPartialCallback)` — `NemotronPartialCallback = @Sendable (String) -> Void`, structurally compatible with the Parakeet callback type but a distinct typealias.
- Lifecycle: same `cleanup()` story as `StreamingEouAsrManager`.

**Critical:** Nemotron weights are NOT bundled in the IPA. Like Parakeet 0.6B v2, they need a HuggingFace download on first use (~600 MB). Without that download UX, picking the variant fails silently.

## What needs to change in Jot

### 1. `SpeechModelVariant` enum

Add `case nemotron0_6b = "nemotron0_6b"`. Update `displayName` to return `"Nemotron 0.6B"`. Update legacy-tag-fallback doc.

### 2. Streaming engine abstraction

`StreamingTranscriptionEngine` is currently hardcoded to `StreamingEouAsrManager`. Needs to support both manager types. Two viable shapes:

- **Protocol over both managers**: define `StreamingAsrManagerProtocol` covering `loadModels(from:)`, `setPartialCallback`, audio-buffer ingest, `cleanup()`. Both `StreamingEouAsrManager` and `StreamingNemotronAsrManager` adopt. Engine generic over the protocol. Risk: FluidAudio types may change between SDK versions, brittle vs library updates.
- **Parallel engine class**: `StreamingNemotronTranscriptionEngine` mirrors `StreamingTranscriptionEngine` but wraps the Nemotron manager. Branch at `StreamingTranscriptionService.beginSession`. Cost: ~80% code duplication but no protocol churn.

Recommendation: **protocol approach** if the API surface is small enough to keep stable (4 methods); parallel class if not.

### 3. `StreamingTranscriptionService.beginSession`

Branches on `SpeechModelVariant.current()`. For `.nemotron0_6b`:
- Resolve / download the Nemotron model directory (see §5).
- Instantiate `StreamingNemotronAsrManager(configuration: ..., requestedChunkSize: .ms1120)`.
- Wrap in the appropriate engine type per §2.

### 4. Skip the batch step on Nemotron variant

The dictation pipeline's batch-transcribe sites (`TranscriptionService.shared.transcribe(samples:)`) live in:
- `JotApp.swift` (in-app record path)
- `DictateIntent.swift` (Action Button / Shortcuts entry, 2 call sites)
- `TranscribeAudioFileIntent.swift` (file-based Shortcuts entry — keeps Parakeet since Nemotron is streaming-only)

For the dictation paths (NOT the file path), branch on variant:
- If `.tdtCtc110m` or `.parakeetV2`: run batch as today.
- If `.nemotron0_6b`: skip the batch call. Pull the streaming engine's accumulated transcript as the final via a new `StreamingTranscriptionEngine.finalTranscript()` accessor (the engine already has the data — currently it just emits a final partial via callback at `engine.finish()`).

For `TranscribeAudioFileIntent.swift`: keep Parakeet always (the user can't pre-stream a file). Document this — picking the Nemotron variant doesn't apply to file transcription.

### 5. Nemotron model download UX

The Parakeet 0.6B v2 download flow lives in `Jot/App/Settings/SettingsView.swift`'s `SpeechModelVariantPicker` (and its associated download sheet). For Nemotron:

- Add a "Download · ~600 MB" CTA in the variant picker when Nemotron is selected.
- Wire to `FluidAudio` download via `StreamingModelVariant.nemotron1120ms.createManager().loadModels()` (parameterless overload triggers HF download).
- Progress reporting: mirror the Parakeet 600M v2 progress pattern.
- Backup exclusion: Nemotron weights will land under `Library/Application Support/FluidAudio/Models/` like Parakeet 600M v2. The existing `BackupExclusion.excludeFluidAudioModels()` already covers the parent directory, so this is automatic.

### 6. Settings picker (`SpeechModelVariantPicker`)

Add a third row for Nemotron 0.6B. Surface state: not-downloaded (CTA), downloading (progress bar), downloaded (selectable).

### 7. Telemetry / diagnostics

Add `DiagnosticsCategory` cases for Nemotron-specific events if useful (model load, model-download failure). Lower priority — `os.log` is enough for v1.

### 8. features.md

Update §6.1 (Speech Model Management), §6.3 (variant picker), §13.4 (iCloud Backup behavior — confirm Nemotron weights are covered by existing exclusion).

## Open questions

1. **Chunk size choice — 560 ms vs 1120 ms?** Trade-off: 1120 ms is more accurate per FluidAudio's marketing, but adds half a second of latency before partials show. For a "type-as-you-speak" feel, 560 ms may be preferable. Default unclear — would need on-device A/B.

2. **Quality vs Parakeet 0.6B v2?** Both are similar parameter count. Real test is whether Nemotron's cache-aware streaming architecture produces materially different transcripts. The throwaway-build (Option Z from the user conversation) would answer this in 3–4 hours of work.

3. **Does the batch-skip path produce trustable transcripts?** Streaming output is incrementally finalized as the user speaks; the batch model re-runs on the full audio for higher accuracy. Skipping batch is faster but may regress quality vs the streaming-output-as-final assumption. Needs eyeball comparison on real dictations.

4. **Should we offer Nemotron variant via the existing variant picker (where it competes with Parakeet for the default-selected slot) OR as a separate Lab toggle?** Picker is the right home long-term; Lab toggle is the right home if we're still testing reliability.

## Sequence to build

1. Write the protocol + plumb both managers through the engine (§2).
2. Add the variant enum case + Settings picker row (§1, §6).
3. Wire the download flow (§5).
4. Branch in `beginSession` (§3).
5. Add streaming-engine `finalTranscript()` + branch in transcribe call sites (§4).
6. Telemetry (§7) + features.md (§8).
7. Manual on-device test — record a few dictations on Nemotron, eyeball quality vs Parakeet.
8. Adversarial review on the engine abstraction (protocol design is where the bugs hide).
9. Ship as a build.

## What we'll throw away if we drop Nemotron later

- The protocol abstraction (§2) is the only piece that's hard to remove cleanly — if we revert it back to Parakeet-only, the unwinding is ~1 hour. Everything else is additive (new enum case, new download row, new branch).

## Related plans / cross-links

- `docs/plans/transcript-classifier.md` — also runs heavy ML; sets the precedent for "Lab toggle" gating of experimental features.
- `Jot/features.md §6.1` (Speech Model Management).
- `Jot/CLAUDE.md` "Schema discipline" — N/A here, Nemotron doesn't touch SwiftData.

## Decision context

Original ask: "add nemotron 600m along with the parakeet ones." Originally estimated 6–8 hours; after digging into `StreamingTranscriptionService` + `StreamingTranscriptionEngine` + the batch-skip wiring, real estimate is 1–2 days. The user opted to park (Option Y) rather than ship a throwaway (Option Z). Re-evaluate when classifier work stabilizes and we have bandwidth for a focused integration PR.
