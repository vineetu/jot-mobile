# iOS 27 — Apple Intelligence everywhere (Qwen out, Private Cloud Compute in)

Status: **BUILT and SHIPPED TO TESTFLIGHT 2026-09-14 as 2.0.2 (301); owner confirmed rewrite, proofread and the update path on device; 302 adds Automatic cleanup (§7.14). Post-302 (unshipped, on the branch): the post-stop UX pass (held keyboard strip, named stages everywhere, hero stage line, finishing return pill, cleaning badges, AI-cleanup card restyle, rewrite provenance attribution, 20 s paste-wait cap) (shipped as 303), then 304 = the keyboard actions-pane **Cleanup** toggle (replaces Redo; flips `cleanupEnabled` from the keyboard; app mirrors `aiCleanupAvailable`), and the Private Cloud Compute gate — `PrivateCloudComputeAccess.isEntitled = false` hides Ask and disables the cloud rewrite fallback until Apple grants the managed entitlement, because the framework reports PCC available without it and then fails every request (ModelManagerError 1046).** Owner-directed the same day. (299 already existed on App Store Connect; 300 was uploaded but bounced by ITMS-90626 because the Ask intent description said "Apple's Private Cloud Compute" — intent descriptions may contain neither "Siri" nor "Apple"; the upload also surfaced ITMS-90771 — the `processing` background mode with no task identifiers — fixed by dropping the mode.)
Supersedes the "Remove Jot's own AI rewrite" entry (owner-directed 2026-08-30) with one
deliberate variation — see *Decision record*.

## Problem

Jot shipped its own 2.5 GB rewrite model (Qwen 3.5 4B on MLX) plus a 330 MB EmbeddingGemma
retrieval model for Ask. Both were heavy to download, heavy to keep resident (the memory
entitlement rationale), and carried a third-party inference stack (MLX, Hugging Face packages,
a vendored `mlx-swift-structured` fork, CoreML-LLM) that Xcode 27 now refuses to build from the
command line without plug-in validation. Apple Intelligence on iOS 27 — the third-generation
on-device models plus Private Cloud Compute (PCC) with a 32K context — makes all of that
unnecessary: no download, no weights, no third-party inference, and stronger models than the
ones Jot bundled.

## Goal

1. Remove every Jot-owned language / embedding model and its download, carry-forward, purge and
   Settings UX.
2. Run **rewrites** on Apple Foundation Models: on-device first, PCC as the iOS 27 fallback for
   transcripts that don't fit the on-device context.
3. Run **Ask** on PCC (iOS 27) with retrieval through Apple's Spotlight search tool over a
   Core Spotlight projection of every note; keep the product-help lane as a tool the model calls.
4. Add **Proofread** — the iOS 27 system grammar checker — to the transcript editor.
5. Keep the deployment target at iOS 26 and gate every iOS 27 feature with availability checks.
6. Update the privacy story everywhere it is stated.

## Non-Goals (deferred)

- Siri App Intents entities / app schemas (`IndexedEntity`, `.notes` domain, view annotations)
  — needs Xcode schema validation on-device and its own review; Ask-from-Siri already works
  through `AskJotIntent`.
- Adopting `LongRunningIntent` / `IntentResponseStream` for the record-and-transcribe and
  file-transcribe intents.
- Core AI for Parakeet / the CTC scorer; Speech `AnalysisContext.contextualStrings` for the
  Apple dictation engine; the Evaluations framework for prompt regressions. All noted in the
  session's initial assessment as later work.
- Dropping the dormant `TranscriptEmbedding` / `TranscriptCategory` / `TranscriptChunk`
  entities from the frozen schema (needs a `.custom` V9→V10 stage; harmless meanwhile).
- Bumping the deployment target to iOS 27.

## Design

### Rewrite — `RewriteClient` (App/LLM)
- `SystemLanguageModel(guardrails: .permissiveContentTransformations)` + the existing
  `@Generable Rewrite` schema, prompt in `instructions`, transcript in the user turn.
- iOS 27: `tokenCount(for:)` / `contextSize` budget up front (`2 × input + instructions + 256`);
  too long, or an on-device failure, → `PrivateCloudComputeLanguageModel`, same schema.
- `RewriteMode` keeps two cases: `.jotAI` (Jot's prompts on Apple's model, **default**) and
  `.appleIntelligence` (system Writing Tools). Both need Apple Intelligence; no fallback engine.
- `RewriteClient.availability` (same reasons as `CleanupService`) drives the Settings AI row,
  the AI screen's engine strip, and the detail view's Rewrite routing.
- `LegacyModelPurge` deletes the Qwen / Phi-4 HF-cache snapshots and the EmbeddingGemma
  CoreMLLLM tree once per install (flag-before-delete, as the old Phi-4 purge did).

### Ask — `AskPipeline` (App/Ask), iOS 27 only
- Availability: iOS 27 ∧ PCC `.available` ∧ `!quotaUsage.isLimitReached`. Below iOS 27 the
  Ask pill is hidden; in-sheet states cover Apple Intelligence off, ineligible device, quota
  reached (with Apple's `limitIncreaseSuggestion.show()`), and offline errors.
- Two question shapes. **Pure date window** (no topic): local chronological fetch
  (`retrieveByDate`, k = 50, 40 000-char turn) + the existing numbered `[cite: N]` contract.
  **Everything else**: a PCC session with `SpotlightSearchTool` (Core Spotlight source with
  `TranscriptSpotlightIndex` as hydration delegate) and `JotHelpSearchTool` (BM25 over the
  bundled help chunks). The notes the tool returns (`searchResults`) become the sources footer;
  no numbered citations in this shape.
- `AskEngine` (Siri / Shortcuts) is a thin wrapper over the same pipeline.
- `HelpCorpusIndex` is text-only now (no vectors, no `modelVersion`); the generator's Swift
  embedder was replaced by `stamp_corpus.py`.

### Core Spotlight projection — `TranscriptSpotlightIndex`
- One `CSSearchableItem` per transcript: `uniqueIdentifier` = UUID, domain
  `com.vineetu.jot.mobile.transcripts`, `textContent` = `displayText`, title = first line,
  creation date, never expires. Written by every `TranscriptStore` mutation, deleted on delete,
  fully re-projected at launch when `indexVersion` changes, and on Spotlight's own reindex
  requests (`CSSearchableIndexDelegate`, set in `JotApp`).
- Doubles as system Spotlight search; a tapped result opens the note through the keyboard's
  open-transcript router (`.onContinueUserActivity(CSSearchableItemActionType)`).

### Proofread — `GrammarCheckService` + `ProofreadSheet` (App/Cleanup), iOS 27 only
- `UITextChecker.requestGrammarChecking(of:range:waitForAllResults:)` → `GrammarIssue`s
  (grammar details + spelling corrections). Edit-bar button → underlines
  (`InlineEditTextView.highlightRanges`) + an accept / ignore sheet. Never applied silently;
  any edit clears the underlines; accepting re-checks.

### Removed
`Qwen35Client`, `LLMClientFactory`, `LLMClientUIAdapter`, `RewriteRequestDispatcher`,
`RewriteCancelPolling`, `LLMClient`, the whole `App/Embeddings/` group, `ChunkStore`,
`SemanticSearchController`, `RRFFusion`, `IntentRouter`, `EmbeddingsPanelView`,
`PendingRewriteRequest`, `KeyboardPendingRewriteState`, `RewriteNotifications`,
`RewriteWithPromptIntent`, `AppGroup+Rewrite` (only `lastDictationStatusMessage` survived, moved
into `AppGroup`), `Vendor/mlx-swift-structured`, the help-corpus embedder, the
`backfill-embeddings` BGTask, and the MLX / Hugging Face / CoreML-LLM package dependencies.
The only third-party package left is FluidAudio.

## Implementation outline (what landed)

1. Deletions above; `project.yml` packages / dependencies / BG identifiers; `.gitignore`
   exception; NOTICE; scripts (`check-backup-attributes.sh`, `strip-models.sh`,
   `testflight.sh`, `make-help-corpus.sh`, new `stamp_corpus.py`).
2. `RewriteClient`, `RewriteMode`, `AIRewriteSettingsView` (engine picker + engine strip),
   `SettingsView` AI row, `TranscriptDetailView` rewrite routing, `EditPromptWithTestSheet`.
3. `TranscriptSpotlightIndex` + `TranscriptStore` hooks + `JotApp` deep link / reindex.
4. `AskPipeline`, `AskController` (state + availability), `AskEngine`, `AskJotIntent` copy,
   `AskView` (banners removed, unavailable copy, attribution), `JotHelpSearchTool`,
   text-only `HelpCorpus`.
5. `GrammarCheckService`, `ProofreadSheet`, `InlineEditTextView.highlightRanges`, edit-bar button.
5b. (302) **Automatic cleanup** — `CleanupSettings` gains `promptID` + `pasteCleanedText`; the Settings → AI card exposes the pre-existing hidden `cleanupEnabled` pipeline path, now routed through `RewriteClient`; `DictationPipeline.cleanUpInBackground` is the paste-raw-now variant. features.md §7.14.
6. Xcode 27 / Swift 6.4 compile fixes unrelated to the feature: `Mutex<Bool>` captures in the
   `AVAudioConverter` input blocks → `OSAllocatedUnfairLock` (compiler bug "copy of noncopyable
   typed value").
7. Docs: `features.md` (§1.3, §1.12, §3.7, §3.9, §6.3, §6.4, §7.2–7.10, §9.4, §12.2–12.4,
   §13.1, §13.4–13.6a, §14.1–14.7), `ARCHITECTURE.md`, `CLAUDE.md`, `AGENTS.md`, App Store
   copy, Settings.bundle, in-app privacy copy, atlas fragments + manifest, help corpus.

## Decision record

- **Prompts stay.** The 2026-08-30 note said "remove the whole Jot AI thing" including the
  Rewrite tab and prompts. On 2026-09-14 the owner asked for "Private Cloud Compute for Ask and
  rewrite". Reconciled as: Jot-owned *model* gone, Jot's *prompts* kept and run on Apple's
  models (the differentiated one-tap rewrite), with system Writing Tools as the other engine.
  Default engine is now Jot's prompts. **Owner confirmed on device 2026-09-14/15; the Writing
  Tools engine was then retired (next entry).**
- **2026-09-15 — Writing Tools engine retired; every AI affordance acts directly.** After the
  keyboard learned to rewrite (§7.15) and translate (§7.16) a selection in place, the owner asked
  that nothing in Jot "tell you to select and do that" any more. So: the Settings → AI engine
  picker (`RewriteMode`) and its Writing Tools how-to card are gone (one engine: the user's
  prompts on Apple Intelligence); the detail's read-only selection mode, the one-time
  `AppleIntelligenceRewriteGuide` sheet and the "Tap the selection, then ✎ Writing Tools" hint
  are gone; the edit bar's AI button rewrites the draft in place with the Cleanup prompt (session
  edit, italic, Save keeps / Cancel discards); the keyboard recents-row button (now a
  wand-and-stars glyph) opens the note and runs the Cleanup prompt at once (`autoRewrite`); the
  keyboard's Rewrite tile no longer has a guide fallback (washed + banner when Apple Intelligence
  is off). iOS's own Writing Tools remain reachable on any selected text; Jot simply never
  depends on them. Surfaces touched: features.md §3.3, §3.5, §3.7, §5.2, §5.6, §6.3, §7.2,
  §7.10, §7.15, §12.3; atlas `ai-engine-apple` / `rewrite-apple-intelligence` /
  `kb-rewrite-guide` deleted.
- **Rewrite on-device first, PCC only as fallback**; **Ask PCC-first** (32K context, reasoning).
- **Ask becomes iOS 27-only**; iOS 26 keeps rewrite (on-device) and loses nothing it had except
  the retired downloadable Ask.
- **Deployment target stays iOS 26**; iOS 27 APIs gated with `#available`.

## Edge cases

- PCC quota reached mid-session → Ask `.unavailable(.quotaReached)` with "See options".
- Offline → PCC `networkFailure` → user copy "You're offline…"; on-device rewrite unaffected.
- Long transcript on iOS 26 → on-device context error surfaces as a rewrite error (no PCC).
- Spotlight index empty on first iOS-27 launch after update → `reindexAllIfNeeded` runs once
  (version 1); Ask before it finishes may see fewer notes for a few seconds.
- A note edited while the proofread sheet is open → underlines cleared, sheet keeps stale
  ranges until the next check (accept re-checks; `apply` verifies the original text first).
- Existing installs: `LegacyModelPurge` frees ~2.5 GB + 330 MB; retired UserDefaults keys and
  BG task requests are removed at launch.

## Test plan (TestFlight, iPhone with Apple Intelligence on iOS 27)

1. Fresh update from build 298: launch, confirm no crash, Settings → AI shows "Apple
   Intelligence · Ready", disk usage drops (Settings → General → iPhone Storage → Jot).
2. Rewrite a short transcript with each default prompt (on-device); rewrite a very long one
   (expect PCC — Console: `rewrite via private-cloud-compute`).
3. Switch engine to Writing Tools; Rewrite → selection mode + guide as before.
4. Ask: "what did I say about X" (tool shape, sources appear), "summarize yesterday" (date
   shape, citation chips), "how do I pause a recording" (help label). Turn off Wi-Fi → offline
   copy. Check the Ask pill is hidden on an iOS 26 device.
5. Home Screen Spotlight: search a phrase from a note → result → opens the note in Jot.
6. Edit a transcript → Proofread: underlines + sheet; accept one fix (italic), ignore one.
7. Shortcuts "Ask your notes" still answers; Action Button "Jot down" still binds and records
   (provider re-verify rule).
8. Privacy copy: Settings caption/footer, iOS Settings → Jot footer, Help → See for yourself.

## Open questions

- Private Cloud Compute developer access must be applied for on the Apple Developer site; until
  approval PCC reports unavailable and Ask stays hidden.
- Whether to bump the deployment target to iOS 27 once adoption allows (removes the gates).
- Siri entities (deferred above) — worth a plan of its own.

## Cross-links

- `features.md` §7, §13.1, §14 · `ARCHITECTURE.md` "Ask (Private Cloud Compute + Spotlight)",
  "AI Rewrite, Cleanup & Proofread" · `docs/ask-product-help/design.md` (help lane; the cosine
  router paragraphs are historical) · `docs/plans/ask-retrieval-architecture.md` (superseded
  retrieval design; kept for the reasoning record).
