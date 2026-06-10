# Jot — ARCHITECTURE

## Orientation

Fresh-session read order: the auto-loaded agent working-rules (your global rules + this repo's project rules) → auto-memory `MEMORY.md` (hard-won facts + feedback) → `Jot/known-bugs-and-plans.md` (registry of bugs + `docs/plans/*`) → `Jot/features.md` (the WHAT — exhaustive feature behaviour) → **this file** (the WHERE — coarse code map) → the code.

This is a stable, coarse code map at subsystem granularity: a bird's-eye view, where each subsystem lives, the boundaries/invariants that reading code won't reveal, and searchable starting symbols. It is **not** a feature spec — it deliberately does not restate feature prose; it links `features.md §` sections instead. It is sized to survive refactors, so it names subsystems and contracts, not individual functions or line numbers.

## Bird's-eye view

Jot ships **four runtime processes** — main app, keyboard, watch app, and watch widgets — but only **two share the App Group**: the main app and the keyboard. (The watch app + widgets are separate watchOS targets that couple to the phone over WCSession, NOT the App Group — they carry no `application-groups` entitlement.) The three subsystems below are the App-Group / WCSession handoff path:

- **Main app** (`Jot` target; app-only code is gated `#if JOT_APP_HOST`) — owns the single SwiftUI scene, the SwiftData store, every service singleton, and all on-device model inference (Parakeet/EOU ASR, EmbeddingGemma, Qwen MLX, Apple Foundation Models).
- **JotKeyboard extension** — a separate process with a **~60 MB memory ceiling**. It **must not link MLX, FoundationModels, or FluidAudio**, and **must never open SwiftData**. It is dictation-only (no QWERTY): it drives recording in the main app by remote-control and inserts finished text into the host field.
- **watchOS app** (+ widgets) — records audio locally and ships it to the phone for transcription; receives a read-only top-10 list back.

The **only cross-process channel is the App Group** (`group.com.vineetu.jot.mobile.shared`): UserDefaults keys + JSON projections/mirrors for state, and **Darwin notifications as signals only** (they say "re-read the projection", never carry truth). The keyboard reads transcript history from a JSON **mirror**, never SwiftData. The watch couples over **WCSession**, then merges into the same shared store on the phone.

The **SwiftData store lives inside the App Group container** (`JotTranscripts`, `cloudKitDatabase: .none`), on a **frozen versioned schema** (V1→V7) with a Flyway-style migration plan. The store and its container are main-app-only even though the schema files compile into both targets.

Speech-model **weights** live under `Library/Application Support/<vendor>/` (sticky — survives memory pressure, NOT Caches) and are recursively flagged `isExcludedFromBackup` via `BackupExclusion` (run in `JotApp.init`) so the ~2GB re-downloadable weights stay out of iCloud Device Backup. The SwiftData transcript store is a separate residency (App Group container, above).

The sole off-device transmission is the **user-initiated feedback POST** (plus a read-only donations GET); everything else is fully on-device.

## Code map

| Subsystem | Where | Entry points | features.md § |
|---|---|---|---|
| App entry & lifecycle | `App/JotApp.swift`, `App/ContentView.swift`, `Shared/{CrossProcessNotification,PipelinePhaseProjection,AppGroup}.swift` | `triggerAutoStart`, `onOpenURL`, `handleSceneActive`, `presentExternalKeyboardHeroIfPending`, `CrossProcessRecordingStopCoordinator.handleStopRequested` | §2, §4, §5, §10, §12, §14 |
| Recording & capture | `App/Recording/{RecordingService,RecordingHeroView,InlineDictationSession,FocusedFieldInsert,WarmHoldNudgeView}.swift`, `App/Transcription/ModelLoadTimekeeper.swift`, `Shared/RecordingPipelineDispatch.swift` | `RecordingService.shared/.start()/.stop()`, `AudioTapRouter.beginSlice`, `RecordingHeroView (HeroPhase)` | §2.1–2.9, §2.12, §2.14, §13.2 |
| Transcription & ASR models | `App/Transcription/{TranscriptionService,StreamingTranscriptionService,StreamingPartial,SpeechModelVariant,ModelLoadTimekeeper,ParagraphSegmenter,FillerWordCleaner,NumberNormalizer,SimulatorStandIn}.swift`, `Shared/BackupExclusion.swift` | `TranscriptionService.shared/.transcribe(samples:)`, `StreamingTranscriptionService.beginSession`, `SpeechModelVariant.current()`, `sessionLoadState` | §2.3, §2.8, §2.14, §5.3, §6.1 |
| Dictation pipeline & Intents | `App/Intents/{DictationPipeline,DictateIntent,RecordAndTranscribeIntent,TranscribeAudioFileIntent,DictationPostProcessingCoordinator,JotAppShortcuts}.swift`, `App/Recording/FocusedFieldInsert.swift`, `Shared/{RecordingPipelineDispatch,CrossProcessNotification}.swift` | `DictationPipeline.completeEndOfRecording`, `DictationController.stopAndTranscribe`, `DictateIntent.perform`, `FocusedFieldInsert.insertIntoFocusedField` | §2.5, §2.10, §2.11, §5.4, §5.12, §10.1–10.3, §13.1 |
| Keyboard extension | `Keyboard/*`, `Shared/{CrossProcessNotification,PipelinePhaseProjection,TranscriptHistoryMirror,ClipboardHandoff,AppGroup}.swift`, `Resources/Keyboard-Info.plist`, `Resources/Keyboard.entitlements` | `JotKeyboardViewController`, `flushPendingAutoPasteIfPossible`, `decideMicTap`, `refreshPipelinePhase`, `deadAppWatchdogTask` | §5.0–5.12 |
| Cross-process plumbing | `Shared/{AppGroup,AppGroup+Rewrite,CrossProcessNotification,PipelinePhaseProjection,AmplitudeProjection,PendingPasteSession,ClipboardHandoff,TerminalSessionLog,TranscriptHistoryMirror,TranscriptHistoryMirror+SwiftData}.swift` | `AppGroup.defaults`, `CrossProcessNotification.post`, `PipelinePhaseProjection.write`, `ClipboardHandoff.publish`, `TranscriptHistoryMirror.refresh` | §2.10, §2.13, §5.12, §13.1, §13.2, §13.4, §13.6 |
| SwiftData schema & store | `Shared/Schema/JotSchemaV1..V7.swift`, `Shared/Schema/JotMigrationPlan.swift`, `Shared/{Transcript,TranscriptStore}.swift`, `Shared/DerivedData/ChunkStore.swift`, `scripts/check-schema-frozen.sh`, `docs/schema-migrations.md` | `JotModelContainer.shared`, `JotMigrationPlan.stages`, `JotSchemaV7`, `TranscriptStore.append`, `typealias Transcript` | §13.4, §13.1, §13.5, §13.6, §14.4 |
| Ask & RAG | `App/Ask/*`, `App/Embeddings/*`, `App/Search/SemanticSearchController.swift`, `Shared/DerivedData/ChunkStore.swift`, `Shared/Schema/JotSchemaV7.swift` | `AskController.runPipeline/.retrieveTopK`, `TranscriptIndexer.index`, `RRFFusion.fuse`, `EmbeddingGemmaService.encode`, `IntentRouter.route` | §1.12, §14.1–14.6 |
| Transcript Detail & Editing | `App/{TranscriptDetailView,InlineEditTextView}.swift`, `App/Recording/FocusedFieldInsert.swift` | `TranscriptDetailView` (tab segment, action bar), `InlineEditTextView`, in-field dictation insert | §3.1–3.8, §13.5 |
| AI Rewrite & LLM | `App/LLM/*`, `App/Rewrite/*`, `App/Cleanup/CleanupService.swift`, `Shared/LLM/LLMClient.swift`, `Shared/{SavedPrompt,SavedPromptStore,KeyboardRewriteRouter,PendingRewriteRequest,KeyboardPendingRewriteState,AppGroup+Rewrite,ChainedFollowUp,CleanupSettings,FollowUpDiscoveryState}.swift`, `Shared/Intents/{RewriteWithPromptIntent,RewriteNotifications}.swift`, `App/Settings/{AIRewriteSettingsView,EditPromptWithTestSheet}.swift` | `RewriteRequestDispatcher.dispatch`, `LLMClientFactory.client`, `Qwen35Client.rewrite`, `SavedPromptStore.all`, `RewriteCancelPolling.observe` | §3.1, §3.4, §3.6, §3.8, §7.1–7.12, §9.3, §12.3–12.4, §13.5, §2.11 |
| Setup Wizard | `App/SetupWizard/{SetupWizardView,SetupState}.swift`, `App/SetupWizard/Components/WizardChrome.swift`, `App/SetupWizard/Steps/*` | `SetupWizardView`, `SetupStep`, `SetupCompletion.markCompleted`, `SettingsRerunTrigger`, `closeAndComplete`, `WizardPanel`, `HowItWorksScene` (W4 scene, shared with Help §9.2) | §4.1–4.10, §13.2–13.3, §5.0, §6.1, §6.4, §7.1, §9.2 |
| Settings | `App/Settings/*` (AI Rewrite cites `App/Settings/{AIRewriteSettingsView,EditPromptWithTestSheet}.swift`) | `SettingsView`, `SpeechModelVariantPicker`, `VocabularySettingsView`, `EmbeddingsPanelView`, `DiagnosticsView` (About → Diagnostics), `LLMClientUIAdapter` | §6.1–6.7, §7.5, §7.7–7.9, §7.12 |
| Apple Watch & Connectivity | `Watch/*`, `WatchWidgets/JotWatchWidgets.swift`, `App/WatchConnectivity/{PhoneSideWCSession,DiagnosticsWatchView}.swift` | `PhoneSideWCSession`, `WatchConnectivityClient`, `WatchSyncQueue`, `WatchRecorder`, `WatchTranscriptStore` | §2.13, §1.2, §4.7 |
| Warm Hold | `App/Recording/{RecordingService,WarmHoldNudgeView}.swift`, `Keyboard/{WarmHoldNudgeStrip,JotKeyboardViewController}.swift`, `Shared/{AppGroup,CrossProcessNotification}.swift`, `App/{JotApp,ContentView}.swift`, `App/SetupWizard/Steps/WarmHoldStep.swift`, `App/Ask/AskView.swift` | `enterWarmHold`, `exitWarmHold/releaseWarmHold`, `detectWarmHoldSwitchingNudge`, `qualifyingReturnStreak`, `handleMicCTATap` | §13.2, §4.6, §2.1, §2.4, §2.9, §5.3, §6.4, §13.3 |
| Design system | `App/Design/JotDesign.swift`, `App/Design/Components/*`, `App/Design/InteractivePopGestureModifier.swift`, `Shared/JotDesignWatchSafe.swift`, `Resources/Fonts/*` | `JotDesign.Surface`, `JotType`, `Color.jotAccent`, `GlassCard`, `WallpaperBackground`, `JotDesignWatchSafe` | §1.13, §13 |
| Vocabulary & Correction | `App/Vocabulary/{VocabularyStore,VocabularyRescorerHolder,VocabTerm,CtcModelCache}.swift`, `App/Settings/VocabularySettingsView.swift` | `VocabularyRescorerHolder.rescore/.prepare`, `VocabularyStore.shared`, `rebuildVocabulary` | §8.1–8.7, §6.1–6.2 |
| Supporting Surfaces | `App/Help/{HelpView,HelpRows,HowJotWorksPage,SeeForYourselfPage}.swift`, `App/Settings/DiagnosticsView.swift` (Diagnostics relocated here from Help), `App/Feedback/*`, `App/Donation/*`, `App/Recents/*`, `App/Diagnostics/MemoryProbe.swift`, `Shared/DiagnosticsLog.swift` | `FeedbackClient.submit`, `DonationsService.fetchSummary`, `DiagnosticsLog.record`, `HelpView`, `RecentsListCard` | §6.5, §6.7, §9.1–9.7, §1.2, §1.7–1.8, §13.6 |

## Subsystem notes

### App entry & lifecycle
**Role.** Process startup, the single SwiftUI scene, URL-scheme routing, scenePhase-driven lifecycle (foreground heartbeat, model warm-up, BG task submission), and the capture-first auto-start state machine that turns a keyboard's `jot://` bounce into a live recording.
**Entry points.** `triggerAutoStart`, `onOpenURL`, `handleSceneActive`, `startForegroundHeartbeat`, `presentExternalKeyboardHeroIfPending`, `updateDictateTapObserver`, `CrossProcessRecordingStopCoordinator.handleStopRequested`.
**Invariants.**
- `JotApp.init()` does **no blocking I/O** — only constructs service singletons and posts non-blocking warm-up Tasks; warm-up / mirror refresh happen in the scene `.task` on first activation.
- `RecordingService` / `TranscriptionService` / `StreamingTranscriptionService` are process-wide singletons (`.shared`) injected via `@State`+`@environment`; headless intents reuse the SAME `.shared` — never construct second instances (audio-session prior-state leak before v10).
- Auto-start is **once-per-session**: `triggerAutoStart` consumes `autoStartConsumed` FIRST, even on every bail, so a resume-from-background never silently retries; only an explicit `jot://` open or the deferred `.onChange` retries re-fire it.
- **Capture-first cold start**: if the model isn't ready, kick `warmUp()` but start the mic NOW so nothing said during the ~30s cold load is lost; the model is awaited at stop time, not start.
- scenePhase teardown (heartbeat clear) happens ONLY on `.background`, never `.inactive` (a Jot keyboard/banner/Control Center briefly makes Jot `.inactive` while effectively foreground).
- **NEVER forceStop on `.background`** — `audio` background mode keeps the mic live so swipe-back-to-host recordings survive.
- Foreground heartbeat ticks faster (1s) than `AppGroup.isJotAppForeground()`'s 2.5s window, with one synchronous write at start so the first keyboard read isn't stale.
- Save/no-save is decided at the STOP site: `stopAndPublish` gates on `applicationState == .active` SPECIFICALLY (not `!= .background`).
- `PipelinePhaseProjection` is the SINGLE cross-process source of truth for recording state; `JotApp.init` must reset it (and clear `warmHoldExpiresAt`) on launch.
- Ask is the SOLE remaining user of `InlineDictationSession`/`ownsActiveRecording`; every other start path must defensively clear `ownsActiveRecording=false` before `start()`.
- `onOpenURL` branches on `url.host`: rewrite/history/transcript are handled-and-returned WITHOUT auto-start; only the dictate/plain fall-through calls `triggerAutoStart`.
- Hero presents from exactly 3 triggers (FAB, cold `jot://dictate`, return pill); nothing adopts `isRecording`. In-Jot `keyboardDictateTapped` starts a background capture and presents NO hero.
- Use `.modelContainer(JotModelContainer.shared)` — NOT `.modelContainer(for:)` (headless intents write without a scene).
**Blast radius.** Sits above everything: the only scene + SwiftData container, the service singletons every surface reads via `@environment`, and the URL/Darwin front door. A regression here (init I/O, wrong scenePhase gate, stale projection) breaks cold-launch dictation, cross-process keyboard handoff, and auto-paste app-wide.

### Recording & capture
**Role.** The microphone lifecycle — start/stop/pause/resume/cancel, the live streaming tap, warm-hold mic retention, and the full-screen recording hero UI with its cold-start model-loading affordances — feeding audio into the transcription pipeline.
**Entry points.** `RecordingService.shared/.start()/.stop()`, `AudioTapRouter.beginSlice`, `RecordingHeroView (HeroPhase)`, `ModelLoadTimekeeper.estimatedSeconds`.
**Invariants.**
- `RecordingService.shared` is a process-wide `@MainActor` singleton — exactly one `AVAudioSession` per process; never construct a second instance for real capture.
- `streamingQueue` MUST be allocated BEFORE `installTap` (closures capture it); teardown always nils `streamingQueue` LAST.
- Never `forceStop()`/`discard()` to release the mic — use `stop()`/`stopGently()` so Warm Hold is honoured (W5 wizard teardown is the one sanctioned forceStop).
- Pause is a sub-state of an active recording: `isRecording` stays true while `isPaused`; cannot pause while warm-held (warm-hold is a post-stop idle state).
- "End the transcription" and "release the mic / warm-hold" are SEPARATE axes; a transcript saves only when stopped OUTSIDE Jot or from the hero.
- Cold-start capture begins buffering the instant the user taps, BEFORE the speech model loads (`HeroPhase.preparing`).
- Hero presentation is **source-based** (FAB / cold `jot://dictate` / return pill); the "adopt-unless-vetoed" model was deleted.
- `ModelLoadTimekeeper`'s bar is NOT a byte percentage — it's paced against this device's prior measured load duration and eases-then-waits past the estimate.
- Warm-hold publishes via AppGroup (`warmHoldExpiresAt` + ~1s `warmHoldHeartbeat`); a stale heartbeat reads as expired; publication defers until `markPipelineFinished` if a pipeline is in flight.
- `InlineDictationSession` is the ONLY sanctioned inline path and is now Ask-exclusive.
**Blast radius.** Upstream callers: ContentView (in-Jot tap), JotApp (warm-resume + auto-start), RecordingHeroView (FAB), DictateIntent, SetupWizardView (W5), Ask. Downstream: feeds `StreamingBufferQueue → StreamingTranscriptionService` (live) and `TranscriptionService`/`DictationPipeline` (final); publishes phase via `RecordingPipelineDispatch`/`PipelinePhaseProjection` + `pipelinePhaseChanged`. The `PipelinePhase` enum lives in `Shared/`, not here.

### Transcription & ASR models
**Role.** On-device speech-to-text: a fast FluidAudio streaming model produces the live partial during recording; a stronger Parakeet TDT-CTC batch model finalizes on stop; both selected by `SpeechModelVariant` and post-processed into clean paragraphs.
**Entry points.** `TranscriptionService.shared/.transcribe(samples:)`, `StreamingTranscriptionService.beginSession`, `ensurePreparing`, `SpeechModelVariant.current()`, `sessionLoadState`.
**Invariants.**
- Two services, two roles: `StreamingTranscriptionService` is live/partial (`StreamingEouAsrManager`, EOU 320ms); `TranscriptionService` is the post-stop batch finalizer (`AsrManager`). Both `@MainActor` singletons, one FluidAudio manager each.
- Streaming is **cleanup-on-every-stop**: a fresh `StreamingEouAsrManager` per `beginSession`, fully released in `endSession(engine:)`; `applyFinalSnapshot` deliberately bypasses the session-token guard. The teardown step order is load-bearing but lives as a maintained doc-comment beside the code (`StreamingTranscriptionService.beginSession`/`endSession`) — that is the canonical source; don't copy it here.
- Two state axes: `modelState` = weights-on-disk; `sessionLoadState` = per-session ANE load window. The "Loading [variant]…" overlay renders off `sessionLoadState==.loading`, NOT `modelState`.
- `beginSession` calls `loadModels(from: bundledDir)` — never the protocol's parameterless `loadModels()` (routes through HuggingFace download, breaks App Review 4.2.3 no-first-launch-network). All weights ship in the IPA.
- `SpeechModelVariant` is the single routing source of truth; unknown/legacy tags (incl. ripped `nemotron0_6b`) fall back to `.tdtCtc110m`.
- No real load progress exists; `ModelLoadTimekeeper` paces a calibrated bar that never reaches 100% until the real `.ready` transition.
- `sessionLoadState.didSet` mirrors to AppGroup (`streamingLoadingVariantLabel`, etc.) + posts a Darwin notification so the keyboard renders the placeholder WITHOUT linking SpeechModelVariant/ModelLoadTimekeeper/FluidAudio.
- Post-processing order is fixed: `ParagraphSegmenter.segment` BEFORE `FillerWordCleaner.clean`; `NumberNormalizer` is a separate pass. All pure enums.
- Simulator builds skip real model load on both paths (`SimulatorStandIn` / streaming bypass to `.ready`).
- Weights live under `Library/Application Support/<vendor>/` (sticky — NOT Caches, which the OS evicts under memory pressure and would break dictation) and are recursively `isExcludedFromBackup` via `BackupExclusion.excludeFluidAudioModels()` (called in `JotApp.init`, idempotent, no-op if no variant downloaded) so the ~2GB re-downloadable weights don't bloat iCloud backup. Don't move weights to Caches (breaks sticky retention) or drop the exclusion (bloats backups).
**Blast radius.** Driven by `RecordingService` (tap → buffer queue → `beginSession`/`endSession`, and `transcribe(samples:)` on stop). Other batch callers: JotApp warmUp, ContentView, DictateIntent, TranscribeAudioFileIntent, PhoneSideWCSession (watch). SettingsView §6.1 picker calls `handleVariantChange()`+`warmUp()`. Cross-process: AppGroup `speechModelVariant` + `streamingLoading*` feed the keyboard's loading strip. `ModelNames.ParakeetEOU.requiredModels` defines the on-disk file contract.

### Dictation pipeline & Intents
**Role.** The end-of-recording tail and the AppIntents entry points: after the mic stops, one shared pipeline classifies the utterance (fresh vs follow-up), publishes to clipboard, optionally persists a transcript, and drives the terminal pipeline-phase transition — identically across every entry point. (No Live Activity / Dynamic Island path exists — it was removed; see `DictationActivityCoordinator` in the blast radius.)
**Entry points.** `DictationPipeline.completeEndOfRecording`, `DictationIntentBridge.shared.controller`, `DictationController.stopAndTranscribe`, `DictateIntent.perform`, `RecordAndTranscribeIntent.perform`, `FocusedFieldInsert.insertIntoFocusedField`.
**Invariants.**
- **Publish-first contract**: derive text, publish to clipboard FIRST, then append to ledger best-effort. A ledger/persistence throw must NEVER gate the publish; both branches degrade to publishing RAW transcript on any cleanup/persistence error.
- `transcriptReady` is posted BEFORE the SwiftData append + mirror write — it signals "published", not "persisted". Listeners needing latest rows must NOT key off it.
- **No code-path divergence**: every dictation entry intent + hero + in-app callers route their tail through `completeEndOfRecording`. `TranscribeAudioFileIntent` is the deliberate exception (composable Shortcuts step, `.result(value:)`, headless, no follow-up classification).
- `transient=true` (in-Jot keyboard stop): run the full publish + terminal-phase path but persist NOTHING (no row, no supersession, no stats).
- On transient, `ClipboardHandoff.clearPendingPasteSession()` runs BEFORE publish so the keyboard's flush no-ops, leaving `FocusedFieldInsert` (public UIKit only) the SOLE deliverer.
- Command branch ordering: `markSuperseded(priorID)` MUST run BEFORE `append(child)` — a cross-file contract with `TranscriptHistoryMirror`+SwiftData's `supersededAt == nil` predicate.
- Each intent owns its preamble (controller lookup, idempotency guard, snapshot `recordingStartedAt`) but must NOT drive the terminal phase transition itself — the pipeline owns it via `DictationActivityCoordinator`'s follow-up-window handoff.
- `DictateIntent` uses `openAppWhenRun=true` + plain `AppIntent` (NOT `AudioRecordingIntent`); all metadata statics `static let`, type/perform non-public. `RecordAndTranscribeIntent` uses `openAppWhenRun=false`, shares phase via the same bridge.
- The session-token-guarded defer publishes `.failed` ONLY if `currentSessionID` still matches.
- Every recording-start site logs `RECORDING START FROM: <site>` — preserve these.
**Blast radius.** Downstream of `RecordingService`/`stopAndTranscribe`; upstream of `ClipboardHandoff`, `TranscriptStore`, `DictationActivityCoordinator` (now a follow-up-window + recording-start-timestamp coordinator only — defined in `App/Intents/DictateIntent.swift`, not a standalone file; the ActivityKit/JotWidget path is removed, see the `DictationActivityCoordinator` doc-comment in `App/Intents/DictateIntent.swift` — the "Dynamic Island ghost-pill fix" note), `DictationStats`, and the keyboard. Callers: the four Intents, RecordingHeroView, JotApp warm-resume, `RecordingPipelineDispatch`, PhoneSideWCSession. Changing publish/append ordering, the transient contract, or supersession ordering ripples into keyboard auto-paste correctness and history-mirror visibility.

### Keyboard extension
**Role.** A dictation-only custom keyboard (separate process, ~60 MB ceiling, no MLX/Apple-FM) that drives recording in the main app via Darwin notifications + App Group state, then inserts the finished transcript into the host field.
**Entry points.** `JotKeyboardViewController`, `flushPendingAutoPasteIfPossible`, `decideMicTap`, `refreshPipelinePhase`, `deadAppWatchdogTask`.
**Invariants.**
- **60 MB ceiling**: MUST NOT link MLX or Apple FM. Rewrite/cleanup runs in the main app; the keyboard bounces via deep link + Darwin notification.
- Dictation-only by design (no QWERTY), surfaced in onboarding (W6).
- **Never open SwiftData**: Recents read ONLY from `TranscriptHistoryMirror` (App Group JSON).
- All typing goes through `textDocumentProxy` (safe without Full Access). Paste, mirror reads, and App Group writes require Full Access — guard every AppGroup path behind `hasFullAccess`.
- Reload recents on `historyMirrorUpdated`, NOT `transcriptReady` (publish-first means transcriptReady fires before the mirror write → stale recents).
- Height pin (`heightConstraint` 200pt, priority 999) MUST equal `KeyboardView`'s `.frame(minHeight:)` or controls clip off-screen.
- Auto-paste must not double-insert: gate with `isAutoPasteInsertInFlight` + `autoPasteAttempted` + payload session-ID match; after proxy re-sync, verify the insert LANDED before consuming the payload.
- The keyboard can't detect a jetsammed app directly; arm `deadAppWatchdogTask` (5s) on each control tap and tombstone the frozen `.recording` session (`recoveredZombieFreeze`).
- Foreground routing uses a LIVE `keyboardForegroundPing`/`appForegroundPong` handshake (120ms), not the stale `isJotAppForeground()` flag.
- Don't mirror `hasFullAccess` to the App Group — iOS gates App Group writes itself; a mirror can't be trusted.
**Blast radius.** Couples to the main app entirely through `Shared/` infra: `CrossProcessNotification` (stop/pause/resume/cancel, ping/pong, pipelinePhaseChanged, historyMirrorUpdated, warmHoldNudgeChanged, streaming partial/loading), `PipelinePhaseProjection`, `TranscriptHistoryMirror`, `ClipboardHandoff`, AppGroup keys. App-side responders: `ContentView.updateDictateTapObserver`, RecordingService, DictationPipeline, StreamingTranscriptionService, SetupWizardView W5, WarmHoldNudgeView. Changing Darwin names, AppGroup keys, or the projection/mirror schema breaks the contract on both sides.

### Cross-process plumbing
**Role.** The shared App-Group state layer (UserDefaults keys, Darwin notifications, JSON projections/mirrors) that lets the app, keyboard, and watch observe and hand off dictation state without sharing a process or opening SwiftData.
**Entry points.** `AppGroup.defaults`, `CrossProcessNotification.post`, `PipelinePhaseProjection.write`, `ClipboardHandoff.publish`, `TranscriptHistoryMirror.refresh`.
**Invariants.**
- The App Group ID must be listed under `application-groups` for every PROCESS that touches shared state — only the **main app and the keyboard** (the two targets wired to entitlements files in `project.yml`) — or `AppGroup.defaults` fatalErrors and `containerURL` returns nil. The watch app/widgets (WCSession, not App Group) and the unit-test bundle correctly carry no App Group; don't try to enforce it on them.
- **Membership trap — verify from project.yml, not the entitlements files.** `Resources/Watch.entitlements` and `Resources/WatchWidgets.entitlements` DO exist and DO list the App Group, but they are ORPHAN files: in `project.yml` only the `Jot` and `JotKeyboard` targets carry an `entitlements:` key — the `JotWatch`/`JotWatchWidgets` target blocks have none (their comments note "No entitlements file"), so the watch app/widgets build WITHOUT the App Group regardless of those on-disk files. Confirm membership from each target's `entitlements:` key in `project.yml`, NOT from `grep -rl application-groups Resources/*.entitlements` (which falsely returns all four). The two orphan files are deletion candidates.
- **Darwin notifications are signals only, never truth**: a notification just tells a reader to RE-READ the projection. Correctness comes from projection state + `lastUpdatedAt` heartbeat.
- UserDefaults is atomic per-key but NOT across keys — any multi-field handoff must be one JSON blob under one key (`ClipboardHandoff.FreshDictation`, `PendingPasteSession`) so the keyboard can't observe a torn write.
- **Writer/reader roles are fixed**: the MAIN APP writes projections; the KEYBOARD only reads. `read()` may synthesize a `.failed` view in-memory for a stale heartbeat but never writes it back.
- The keyboard NEVER opens a ModelContainer — reads history via `TranscriptHistoryMirror.load()` (pure JSON). `+SwiftData.refresh(from:)` compiles into the keyboard but must only ever be invoked from main-app paths.
- ~60 MB ceiling ⇒ projection values are pre-resolved primitives (e.g. `streamingLoadingVariantLabel` stores a display string, not the enum).
- Each projection carries its own staleness window and they are deliberately different — do not unify. The exact thresholds live as constants beside each projection type.
- `AmplitudeProjection` encodes its timestamp as milliseconds-Double, NOT iso8601 (ISO8601 truncates subsecond precision). Don't "normalize" it.
- Default-ON vs default-OFF is encoded per accessor: `isEmbeddingsEnabled` (missing ⇒ true) vs `warmHoldEnabled` (missing ⇒ false). Reusing the wrong pattern flips a default.
- The `speechModelVariant` getter silently rewrites unknown/legacy values (incl. ripped `nemotron0_6b`) to the bundled default on read — the upgrade auto-migration path. `aiRewriteProvider` does NOT: its getter returns the stored string verbatim and only defaults when the key is missing; the legacy coercion (`phi4`/`gemma`/`appleIntelligence` → `qwen35`) lives downstream in `LLMClientFactory`.
- Cross-process shared state the keyboard reads is not just the projection families (ClipboardHandoff / PendingPasteSession / PipelinePhase / Amplitude / TranscriptHistoryMirror): the rewrite/cleanup config keys are also App-Group contracts — `AppGroup+Rewrite` slots (rewrite handoff) plus `cleanupEnabled`/`cleanupInstructions` (cleanup config). Treat them as part of the App-Group key inventory the keyboard observes.
**Blast radius.** Written by main-app dictation (RecordingService, DictationPipeline, StreamingTranscriptionService, JotApp, TranscriptStore); read by the keyboard + watch bridge. Adding a cross-process feature almost always means a new `AppGroup.Keys` entry + a `CrossProcessNotification.Name` + (often) a projection struct; changing a key name silently desyncs whichever process wasn't recompiled in lockstep.

### SwiftData schema & store
**Role.** On-device transcript persistence: the frozen versioned schema (`@Model` shapes), its Flyway-style migration plan, and the singleton ModelContainer + typed store wrappers every read/write goes through.
**Entry points.** `JotModelContainer.shared`, `JotMigrationPlan.stages`, `JotSchemaV7`, `TranscriptStore.append`, `typealias Transcript`.
**Invariants.**
- **FROZEN RULE**: once a `JotSchemaVN.swift` ships, never edit it. Add a field by copying to `V(N+1)`, appending a `MigrationStage`, and bumping the `Transcript` typealias + `Schema(versionedSchema:)`. `scripts/check-schema-frozen.sh` blocks PRs touching a non-max VN.
- Every new VN MUST bump `versionIdentifier` or SwiftData can't distinguish versions and corrupts the store.
- Additive fields use `.lightweight`; renames/removes/type-changes require `.custom`. All 6 shipped stages (V1→V7) are lightweight.
- `JotModelContainer`/`TranscriptStore` are MAIN-APP-ONLY (`#if JOT_APP_HOST`); the keyboard reads via `TranscriptHistoryMirror` JSON only. Source location in `Shared/` does not relax this — it's a runtime invariant.
- Store lives in the App Group container (`groupContainer: .identifier`), name `JotTranscripts`, `cloudKitDatabase: .none`.
- `JotModelContainer.shared` is a `@MainActor` singleton (not the scene modifier) because headless intents append without foregrounding. `ModelContext` is not Sendable — fresh context per call on `@MainActor`.
- If versioned init fails, a fallback constructs a non-versioned container, logs `[SCHEMA-FALLBACK]`, sets `jot.schema.fallbackActiveSince_v1`. Watch Console for it on real-device upgrade tests.
- `category` is DEAD-DATA from V6; `TranscriptCategory` DORMANT, `TranscriptEmbedding` DEPRECATED — retained so V6→V7 stays additive.
- `ledgerIndex` comes from `jot.ledger.nextIndex` (survives deletes ⇒ stable `#NNNN`; per-device, not synced).
- `TranscriptChunk.createdAt/durationSeconds/source` are denormalized copies of the parent, stamped at index time — keep in sync.
- Transcript↔Embedding/Category/Chunk joins are LOGICAL (via `transcriptID` UUID), NOT `@Relationship` — derived rows are rebuildable.
- After creating a new VN file, run `xcodegen` from `Jot/` so the `Shared/` glob compiles it into both targets.
**Blast radius.** `TranscriptStore.append` is the single write path; on save it fans out `TranscriptHistoryMirror.refresh`, `historyMirrorUpdated`, and `TranscriptIndexer.index`. Readers: ContentView, EditPromptWithTestSheet, EmbeddingBackfillTask, TranscriptIndexer, AskController, PhoneSideWCSession. `TranscriptChunk` is the substrate for the whole Ask RAG pipeline. Any `@Model` change ripples to the migration plan, the frozen-check script, the typealias, both init paths, and `docs/schema-migrations.md`.

### Ask & RAG
**Role.** On-device retrieval-augmented Q&A over the user's own transcript library: chunk + embed every note, hybrid (dense + lexical) retrieve, then stream a cited answer from an on-board LLM — all local, no network.
**Entry points.** `AskController.runPipeline/.retrieveTopK`, `TranscriptIndexer.index`, `RRFFusion.fuse`, `EmbeddingGemmaService.encode`, `IntentRouter.route`.
**Invariants.**
- **Lexical FLOOR over RAW transcript text always runs first** in `retrieveTopK`, so EVERY note is findable whether or not the indexer has reached it. Embeddings only RE-RANK; they are never a findability gate.
- Indexing chunks to ~110 tokens (`targetTokens: 110`), NOT the chunker's 256 default — bundled EmbeddingGemma has `max_seq_len=128` and silently truncates.
- EmbeddingGemma is asymmetric: stored chunks `role:.document`, query `role:.query`. Mismatching degrades recall.
- `EmbeddingGemmaService.modelVersion` (`embeddinggemma-300m-256`) stamps every chunk and is the filter key; bump it when swapping model/dim; never read chunks across versions.
- Model is bundled out-of-band under `Resources/Models/EmbeddingGemma/` (gitignored, like Parakeet); a fresh checkout has no weights and load throws `modelNotBundled`.
- RRF fuses on RANK not raw score — don't normalize cosine vs BM25 magnitudes.
- Ask supports two backends behind the `AnswerBackend` enum — Apple Intelligence (default, no download) and on-board Qwen — chosen by `AppGroup.askBackend` (default `"appleIntelligence"`); each falls back to the other if its preferred backend is unavailable. Retrieval k and prompt char budgets are sized per backend up front — larger for on-board Qwen, tighter for Apple Intelligence (exact values are constants in `AskController`).
- Date scope is a hard FILTER on the candidate set, then the SAME hybrid ranking runs inside the window (half-open `[start, end)`); empty in-window vectors fall back to `retrieveByDate`.
- `IntentRouter` biases toward `.lookup` on ambiguity (a wrong summarize confabulates across loosely-related notes).
- `TranscriptChunk` is a SwiftData `@Model` — schema changes follow the frozen discipline. Join key `(transcriptID, modelVersion)` is deliberately NOT `@Attribute(.unique)`.
- `TranscriptIndexer` is the SINGLE chunk-embedding entry point (capture, watch sync, BG backfill, manual Rebuild). Whole pipeline gated on `isEmbeddingsEnabled` (default ON).
- BM25 index is in-memory, rebuilt per query (SwiftData hides the SQLite handle). Tokeniser is v1: lowercase + split on non-alphanumeric, NO stemming/stopwords (would mangle codenames/jargon).
- Capture-time indexing runs on `Task.detached(.utility)`, OFF the MainActor; failure is logged + swallowed (BG backfill + manual rebuild are the backstops).
- All Ask/RAG files are `#if JOT_APP_HOST` — app-target only, never the keyboard.
**Blast radius.** Reads the Transcript store, owns `TranscriptChunk` (V7) + `ChunkStore`. Indexing triggered from capture, watch sync, the `BGAppRefreshTask` (`EmbeddingBackfillTask`), and the Settings Rebuild button. Depends on the CoreMLLLM package (EmbeddingGemma) and the on-board Qwen LLM via `LLMClientFactory`. `SemanticSearchController` shares the chunk store + embedder. Changing embedder/model version, chunk size, or schema invalidates the entire chunk corpus and requires a full re-index.

### Transcript Detail & Editing
**Role.** The full-screen detail surface for a saved transcript: Original/Rewrite tab segment, metadata subline, selectable text, the bottom action bar (Delete / Edit / Articulate / Copy), rewrite progress+cancel, rewrite feedback, and in-place editing of either tab — including dictating straight into the field being edited.
**Entry points.** `TranscriptDetailView` (tab segment + action bar), `InlineEditTextView`, `FocusedFieldInsert.insertIntoFocusedField` (in-field dictation insert path).
**Invariants.**
- Edit fate differs by tab and is load-bearing (see features.md §3.7 / §13.5): Original-tab edits OVERWRITE in place (no retained original); Rewrite-tab edits preserve the model output as the training-pair "before". Never collapse these two paths into one.
- `InlineEditTextView` assumes every edit it can produce (type / backspace / paste / select-replace / dictation insert-on-stop) is a **SINGLE CONTIGUOUS replacement**, and recovers the changed range by common-prefix/common-suffix delta in UTF-16 space — deliberately NO LCS/fuzzy diffing (which would mis-mark repeated dictation words) and NO multi-range edits. Adding either requires revisiting this delta logic.
- The italic "changed this session" styling is a session-only cue: the bound `text` is always plain `String`, so Save is flatten-on-save (no styling persisted); `sessionToken` re-baselines the whole text as "original".
- In-field dictation flows through the SAME `InlineEditTextView` delta path and persists no separate transcript (cursor-insert / Cancel-Save-disabled behaviour is features.md §3.7).
**Blast radius.** Reads/writes the Transcript store for in-place edits; the Articulate action drives the AI Rewrite & LLM subsystem (in-app rewrite trigger, routes to AI Rewrite settings as a sheet when the model isn't ready); the rewrite-edit "before/after" pair feeds §13.5 training data. Shares `FocusedFieldInsert` with the keyboard/dictation insert path. Changing the single-contiguous-replacement assumption or the Original-vs-Rewrite edit fate ripples into the changed-range cue, the dictation-insert path, and the training-pair contract.

### AI Rewrite & LLM
**Role.** On-device text generation: Qwen 3.5 4B (MLX) drives grammar-constrained "rewrite" and streaming "ask"; Apple Foundation Models drives "cleanup"/chained-command resolution; user-editable SavedPrompts feed the rewrite, dispatched cross-process from the keyboard via a URL bounce + App Group state machine.
**Entry points.** `RewriteRequestDispatcher.dispatch`, `LLMClientFactory.client`, `Qwen35Client.rewrite`, `SavedPromptStore.all`, `RewriteCancelPolling.observe`.
**Invariants.**
- Two distinct backends, never conflate: Qwen/MLX does rewrite+ask (`App/LLM/`); Apple FM does cleanup + chained-command (`CleanupService`). Different lifecycles, different status enums.
- Cleanup config is App-Group-backed (`CleanupSettings` reads/writes `AppGroup.Keys.cleanupEnabled`/`cleanupInstructions`) and is therefore a cross-process main-app↔keyboard contract, like the rewrite slots. `FollowUpDiscoveryState`, by contrast, is `UserDefaults.standard` (NOT the App Group) — main-app-local, it never crosses the keyboard boundary.
- The keyboard MUST NOT link MLX/FoundationModels. It hands rewrite off via `jot://rewrite?session=<uuid>` + a `PendingRewriteRequest` stash; inference runs only in the main app. `RewriteWithPromptIntent.perform()` is dead code (kept for a future Shortcuts surface).
- The terminal-slot write ORDER is load-bearing and the keyboard reads it in reverse; the exact sequence lives as a maintained file-doc in `RewriteRequestDispatcher` — that is the canonical source, don't copy it here. `rewriteResultSessionID` holds the URL session UUID (`PendingRewriteRequest.id`), NOT the dispatcher's `jobID` — two different UUIDs.
- Job-ID guard: every terminal write is gated on `rewriteJobID == jobID`; an older in-flight job resolving late must drop its result.
- MLX/Metal crashes from a backgrounded process; the dispatcher calls `waitUntilForeground(timeout:10)` before any rewrite.
- Qwen 3.5 emits a `<think>` block by default; suppression is ONLY via `additionalContext: ["enable_thinking": false]` (pre-fills an empty think block in the PROMPT). `rewrite()` is grammar-constrained; `ask()` is NOT and emits `[cite: <uuid>]` markers.
- SavedPrompt defaults have hardcoded stable UUIDs; `DefaultKind` keys on them so a rename keeps its kind. `seedIfNeeded()` only seeds an EMPTY list; the Articulate/AI-prompt migrators run unconditionally every launch (pre-launch, no flag).
- `LLMProvider` is a deliberately single-case enum (`.qwen35`); legacy values (incl. `"phi4"`) resolve to it; Phi-4 weights purged once via `Phi4WeightsPurge`.
- Cancellation flows ONLY through `rewriteCancelRequested`, polled at 50ms, written as the `"Cancelled"` sentinel (keyboard suppresses the toast on exact match). Reset the flag at job start.
- `SavedPromptStore` is App-Group-UserDefaults backed; `all()` never auto-seeds; `save()` normalizes `sortOrder` to `0..<count`.
**Blast radius.** Driven from the keyboard (URL bounce, `rewriteSelectionLength`), `JotApp.onOpenURL` (routes `jot://rewrite`), TranscriptDetailView (in-app trigger), the prompt sheets, AIRewriteSettingsView, and the dictation pipeline (`CleanupService.resolveUtterance`/`ChainedFollowUp`). Shares the `AppGroup.rewrite*` slots across processes. The Qwen `ask()` path is consumed by Ask. `RewriteNotifications` uses its own Darwin namespace, separate from `CrossProcessNotification`.

### Setup Wizard
**Role.** A 7-panel (W1–W7) first-run flow presented full-screen: mic permission, keyboard install + Full Access, how-it-works, a live end-to-end keyboard dictation test, warm-hold opt-in, and completion — then marks setup done.
**Entry points.** `SetupWizardView`, `SetupStep`, `SetupCompletion.markCompleted`, `closeAndComplete`, `WizardPanel`.
**Invariants.**
- Any recording started inside the wizard (W5) MUST be force-stopped before dismissal or a zombie leaks into Home. Teardown lives in `closeAndComplete()` AND `TryKeyboardStep.onDisappear` (which watches ~2s for a late `isRecording` flip).
- The wizard is exactly W1–W7. The old "Download speech model" step and the AI-offer follow-on are removed; W7 is terminal. Don't re-add steps without updating the 7-case `SetupStep` enum AND `wizardCoreStepCount=7` together.
- `handleKeyboardDictateTapped` only acts when `step == .tryKeyboard`; before `start()` it defensively clears `ownsActiveRecording`.
- W5 advance is driven by polling `ClipboardHandoff.readFresh()` for a handoff newer than the step's `enteredAt` — NOT by the dictate-tap handler.
- Full Access cannot be detected; W3 detects keyboard INSTALL via `UITextInputMode.activeInputModes` only and treats Full Access as a manual attestation.
- Going back never undoes permission grants or AppGroup writes; previous steps re-render from observed service state. W1 has nil `onBack`.
- `SetupCompletion` (`jot.setup.completed` in STANDARD UserDefaults, not App Group) is the sole re-presentation source; re-run goes through `SettingsRerunTrigger.requestRerun()` → `SetupCompletion.reset()`.
- The left-edge swipe-back is a hand-rolled `DragGesture` (no UINavigationController in a `.fullScreenCover`), layered last in the ZStack to win the 22pt hit-test.
**Blast radius.** Presented by JotApp via `.fullScreenCover($showSetupWizard)`, gated on `SetupCompletion.isCompleted`. W2 requests mic permission; W3 reads input modes; W6 writes `warmHoldEnabled`; W5 drives production RecordingService/StreamingTranscriptionService and consumes ClipboardHandoff + the keyboard's `keyboardDictateTapped`. Touching the step enum, the 7-dot count, or the teardown contract ripples into all of these.

### Settings
**Role.** The in-app Settings sheet: an editorial scroll of glass cards surfacing speech-model variant, vocabulary, AI rewrite + prompts, the Ask answer-model toggle, privacy/full-access, embeddings indexing, and about/support rows.
**Entry points.** `SettingsView`, `SpeechModelVariantPicker`, `AIRewriteSettingsView`, `VocabularySettingsView`, `EmbeddingsPanelView`, `LLMClientUIAdapter`.
**Invariants.**
- SettingsView is pure UI/state-mirror: reads/writes persisted state through AppGroup accessors and delegates all real work to services. Don't add business logic here.
- "Model installed" is a 3-way AND probe (`modelsExistOnDiskForSelectedVariant && StreamingTranscriptionService.modelsExistOnDisk && CtcModelCache.shared.isCached`) — NOT `modelState==.ready`. Duplicated in `speechModelInstalled` and `SpeechModelVariantPicker`; keep in sync.
- The bundled 110M (`tdtCtc110m`) lives in the read-only IPA: never show a Download/Re-download CTA for it. Only the opt-in 600M (`parakeetV2`) gets the CTA; Re-download requires the confirmationDialog, first Download does not.
- Re-run setup must NOT present the wizard while the sheet is up (dual-modal crash): latch via `onRerunRequested` then `dismiss()`; the host fires `SettingsRerunTrigger` in `onDismiss` — never `DispatchQueue.main.async`.
- `clientAdapter` is created on appear, stopped on disappear, so LLM weights aren't pinned by a glance at Settings.
- Ask backend is selected by the "Use on-board Qwen for Ask" toggle on the MAIN page (`askBackend = 'qwen' | 'appleIntelligence'`), NOT inside the AI Rewrite sub-screen.
- `EmbeddingsPanelView` is `#if JOT_APP_HOST` (imports SwiftData).
- Full Access has no status pill (no API); the row is a deep-link with a breadcrumb subline.
**Blast radius.** A leaf consumer of nearly every subsystem: TranscriptionService/StreamingTranscriptionService/CtcModelCache, VocabularyStore + rescorer, LLMClientFactory/UIAdapter + SavedPromptStore, EmbeddingBackfillTask, DictationStats, the watch diagnostics view. It writes AppGroup keys read cross-process (warm-hold, speech variant, ask backend). Presented from ContentView/JotApp; its re-run path drives the SetupWizard. It owns no persistence or models — only mirrors and triggers them.

### Apple Watch & Connectivity
**Role.** A standalone watchOS app that records audio locally, queues it, and transfers it to the paired iPhone over WCSession for on-device transcription, while receiving the iPhone's top-10 list back for a read-only recent view.
**Entry points.** `PhoneSideWCSession`, `WatchConnectivityClient`, `WatchSyncQueue`, `WatchRecorder`, `WatchTranscriptStore`.
**Invariants.**
- WCSession messages are an untyped string-keyed protocol with `schemaVersion:1` — watch sends `file` + `helloFresh`; phone sends `topTranscripts`/`ack`/`transcribing` (all `transferUserInfo`, FIFO + guaranteed delivery). Add new types to BOTH switch statements; `dict[key] as? T` silently parses an Any-wrapped Optional as nil — encode `source` as String or omit.
- In `session(_:didReceive:)` the file MUST be copied to staging SYNCHRONOUSLY (`stageFileSync`) before the delegate returns — iOS reclaims `file.fileURL` the instant it returns. Never move the copy into the async hop.
- A received audio UUID is added to `recentlyReceivedUUIDs` ONLY after transcribe+save succeeds — early-marking poisons the retry path.
- The sync queue is fail-closed at 50 pending (`maxPendingCount`) — new captures BLOCKED with an alert, never drop-oldest; cap enforced at the UI layer, but `enqueue()` itself always accepts to avoid losing captured audio mid-race.
- Watch audio is AAC 16kHz mono to match Parakeet (no resampling on phone). Capture `currentTime`/`duration` BEFORE `recorder.stop()`.
- Recording uses `WKExtendedRuntimeSession(.audioRecording)`; on invalidation DO NOT call `recorder.stop()` (truncates the m4a). `stopAndSave` has a disk-recovery fallback scanning `Pending/`.
- `WatchTranscriptStore` is READ-ONLY on the watch; all editing is on the phone. Phone re-pushes top-10 on every library change via `historyMirrorUpdated` (250ms debounced).
- Watch-originated transcripts save with `source='watch'` + `watchOriginUUID`; SwiftData dedup keys on it. The save path MUST mirror `TranscriptStore.append` (refresh mirror + post + index).
- Phone/watch acks are independently deduped, both bounded to 100, oldest-first. `resetSync()` re-activation is the documented WCSession-daemon-stall workaround.
- The `transcribing` placeholder store is keyed by AUDIO FILE UUID (cleared by the ack), NOT by `topTranscripts`'s `transcript.id`. The two UUID spaces never match.
**Blast radius.** Activated phone-side from `JotApp` (`PhoneSideWCSession.shared.activate()`). Writes into the shared SwiftData store (`source='watch'`), so it depends on the schema/migration system and feeds Home, keyboard Recents (mirror + notification), Ask indexing, and TranscriptionService. Watch app + widgets are separate watchOS targets. Deep-link `jot-watch://record` launches RootView into recording. Diagnostics surface on-watch (`DiagnosticsView`) and on-phone (`DiagnosticsWatchView`).

### Warm Hold
**Role.** Keeps the audio session alive for a configurable cooldown after a recording stops so the next keyboard dictation starts instantly, and — via a cross-process streak-detection nudge — invites app-bouncing users to enable it.
**Entry points.** `enterWarmHold`, `exitWarmHold`/`releaseWarmHold`, `detectWarmHoldSwitchingNudge`, `qualifyingReturnStreak`, `handleMicCTATap`.
**Invariants.**
- Two independent axes: "end the transcription" and "release the mic / warm-hold" are SEPARATE. Warm hold is orthogonal to dictation routing and must NOT change WHERE a dictation goes.
- Warm hold is ONLY a start-faster optimisation. A keyboard Dictate tap inside the warm window while Jot is FOREGROUND must route inline (insert at cursor, no save); only when Jot is NOT foreground does `handleMicCTATap` take the warm-resume background-capture path. (Taking warm-resume while foreground was the "in-app dictation wrongly saved" root cause.)
- Never forceStop/discard to release a warm-held mic; use `exitWarmHold()`/`releaseWarmHold()`.
- Liveness is gated on TWO signals together: `warmHoldExpiresAt` in the future AND `warmHoldHeartbeat` fresh (<4s). A stale heartbeat ⇒ clear ghost keys and fall through to cold-launch URL.
- The keyboard CANNOT run the streak math. The APP owns it: appends to `captureStopRing`, computes `qualifyingReturnStreak`, sets the `warmHoldNudgeShouldShow` boolean, posts `warmHoldNudgeChanged`. Keyboard/hero render off the boolean and write back only the two terminal actions.
- Streak detection fires after several consecutive qualifying returns inside a bounded window (thresholds are constants in `RecordingService`); the ring is capped. `detectWarmHoldSwitchingNudge` is called ONLY from the clean `stop()` site and dedupes on sessionID.
- The nudge is an OFF-state affordance: never show when `warmHoldEnabled` or `warmHoldNudgeSuppressed`. Passive ignore (~6s auto-hide) ≠ permanent suppression.
- Auto-hide is owned by the APP side only; the keyboard strip has no timer.
- `enterWarmHold` snapshots the duration ONCE at entry; later Settings changes must not resize an in-flight window. If a pipeline is in flight, publication defers (`pendingWarmHoldPublish`).
- Warm hold is mutually exclusive with Pause; `exitWarmHold` clears pause state defensively.
**Blast radius.** Producer is RecordingService (+ the JotApp foreground heartbeat for host-detection). Consumers: `JotKeyboardViewController.handleMicCTATap` (+ nudge observer), KeyboardView/WarmHoldNudgeStrip, ContentView/WarmHoldNudgeView. State flows through `jot.warmHold.*` keys + two Darwin posts (`warmResumeRequested`, `warmHoldNudgeChanged`). `AskView.releaseWarmHold` gently exits on sheet close. Settings/Privacy + W6 own the inputs. Touching duration clamping, heartbeat threshold, or the foreground/background branch can resurface the "in-app dictation saved" or "ghost-trapped Dictate tap" regressions.

### Design system
**Role.** The central design-language layer (JotDesign tokens, JotType fonts, palette, glass-surface tiers, and a small reusable-component kit) shared across the main app, keyboard, and a watch-safe subset.
**Entry points.** `JotDesign.Surface`, `JotType`, `Color.jotAccent`, `GlassCard`, `WallpaperBackground`, `JotDesignWatchSafe`.
**Invariants.**
- `JotDesign.swift` compiles into BOTH the main app AND the keyboard. It must not pull in app-only types: `activeRewriteModelDisplayName`/`Size` are `JOT_APP_HOST`-gated with a static fallback in the keyboard. Don't add unguarded references to app-only singletons.
- `Surface.key` is THE single chrome-control token for every back/close/pause/trash control (dark = solid system grey, light = white-opacity glass). Never substitute ad-hoc `.ultraThinMaterial` circles. Fix the token, not the call site.
- `Surface.regular`/`.heavy` use the real iOS 26 `.glassEffect`; `Surface.key`/`.keyDim` are HAND-ROLLED gradients on purpose (sub-44pt glass blurs to mush). Never migrate key tiers to `.glassEffect`.
- Font PostScript names in code differ from bundled filenames in `UIAppFonts` — both required, must stay aligned. Fraunces ships no Medium(500)/no 14pt opsz static; the SemiBold(600) cut is exposed as `frauncesSemiBold`; 19pt body italic uses the 9pt cut.
- `JotDesignWatchSafe.swift` is a deliberate UIKit-free MIRROR of a narrow color subset (no dynamic providers). NOT a fork: any color change must be made identically in both. Omits keyboard-blue + semantic-icon palette by design.
- `jotAccent` (#1A8CFF) is the single brand accent; coral survives only on Settings/AI surfaces; `jotRecord` (red) is reserved for recording state and must stay visually distinct.
- Page backgrounds go through `WallpaperBackground`; cards through `GlassCard`/`LiquidGlassCard`, not raw `.glassEffect` at call sites.
**Blast radius.** Touched by essentially every SwiftUI surface in the app and keyboard. Changing a token or the `Surface.key` modifier cascades app-wide. The watch targets depend on `JotDesignWatchSafe`. Font config + the keyboard-vs-app compilation split are coupling points; adding app-only symbols here breaks the keyboard build.

### Vocabulary & Correction
**Role.** On-device vocabulary biasing: a user-curated term list (file-backed) that best-effort rescores finished Parakeet transcripts via a bundled FluidAudio CTC keyword-spotter, so domain words/proper nouns are recognized correctly.
**Entry points.** `VocabularyRescorerHolder.rescore/.prepare`, `VocabularyStore.shared`, `rebuildVocabulary`.
**Invariants.**
- Rescore is best-effort, NEVER a correctness gate: `rescore()` returns nil and the caller treats nil + any thrown error identically by falling back to the raw TDT transcript (`TranscriptionService`).
- Two-class split is deliberate: `VocabularyStore` (`@MainActor @Observable`) owns the term list + on-disk file; `VocabularyRescorerHolder` (actor) owns the live CoreML/FluidAudio handles. Don't merge them.
- Persistence is the plain-text "simple format" (one term/line, colon-then-comma aliases, `#` comments) because `CustomVocabularyContext.loadFromSimpleFormat` consumes that exact file. Don't change the format.
- The vocab file lives in the MAIN APP's `Application Support/Vocabulary/vocabulary.txt`, NOT the App Group; the keyboard never reads it.
- `rebuildVocabulary` uses a monotonic `generation` token to guard actor reentrancy — a stale rebuild discards its result after `await`.
- The CTC 110M boost model (~100 MB) ships BUNDLED in the IPA and loads via `CtcModels.loadDirect`; there is NO download/retry/progress path (`removeCache()` is a no-op). On a healthy install status is always `ready`.
- `VocabTerm` still carries `aliases` (desktop round-trip + alias-substitution fallback) but the iOS UI exposes term text only; the data model/file format keep aliases regardless.
- Master toggle (`jot.vocabulary.enabled`) only controls whether biasing is APPLIED; the list/file is always preserved. Off ⇒ `unload()`, on ⇒ `prepare()`.
**Blast radius.** Consumed by `TranscriptionService.swift` (batch-finalize, after TDT inference and before `ParagraphSegmenter` — so every batch caller gets biasing). Driven by `VocabularySettingsView`. Shares the bundled Parakeet directory but loads the CTC aux bundle independently. Does NOT touch SwiftData/schema, the keyboard, or any off-device transmission.

### Supporting Surfaces
**Role.** The non-core utility screens around dictation — Help, Feedback, Donations, the Recents transcript-list card, and the cross-process diagnostics log — including Jot's single outbound network POST (feedback) and a read-only donations GET.
**Entry points.** `FeedbackClient.submit`, `DonationsService.fetchSummary`, `DiagnosticsLog.record`, `HelpView`, `RecentsListCard`.
**Invariants.**
- Feedback POST to `jot-donations.ideaflow.page/feedback` is Jot's ONLY off-device outbound transmission and is user-initiated — keep "only feedback leaves" synced across privacy copy + `features.md §13.6`. Donations is a READ-ONLY GET of `/summary`.
- Diagnostic logs attach to feedback ONLY on opt-in (toggle default OFF); the slice is anonymous app events — never transcripts or PII. Don't widen `DiagnosticsLog`.
- `DiagnosticsLog` lives in `Shared/` and ships in BOTH targets — keep it Foundation-only; it writes to `AppGroup.defaults` so keyboard skip-branch events surface in the main-app Help UI with no IPC. Ring buffer bounded at `maxEntries=100`.
- `FeedbackPayload` omits `images` entirely when empty so the text-only request shape stays byte-identical to pre-screenshot server builds — keep it Optional, don't send `[]`. Screenshots capped (`FeedbackImageEncoder.maxImages`, base64 data URIs).
- The Recents row-swipe reveal must stay a nested horizontal ScrollView (`SwipeRevealRow`), never a DragGesture; row content must not use `containerRelativeFrame`.
- `MemoryProbe` is a dev/Lab diagnostic (jetsam correlation), not production telemetry; don't wire it into hot paths.
**Blast radius.** Help and Feedback are presented from both SettingsView and ContentView. `RecentsListCard` is hosted by ContentView and reads SwiftData Transcript models. `DiagnosticsLog.record` callers span JotApp, the three transcription services, and the keyboard — so this log schema is shared with the recording/keyboard pipelines. Both network surfaces hit the same `jot-donations.ideaflow.page` host.

## Cross-process boundaries & invariants

These are the immutable structural rules. Violating one is a class of bug, not a one-off.

1. **Frozen versioned schema.** Never edit a shipped `JotSchemaVN.swift`; add `V(N+1)` + a `MigrationStage` + bump `versionIdentifier` and the `Transcript` typealias. `scripts/check-schema-frozen.sh` enforces it. Logical (not `@Relationship`) joins keep derived rows rebuildable.
2. **Keyboard 60 MB / no-MLX.** The JotKeyboard target must not link MLX, FoundationModels, or FluidAudio, and must never open a ModelContainer. All inference and all SwiftData access live in the main app; the keyboard remote-controls via deep link + Darwin notification and reads history from a JSON mirror.
3. **App-Group / Darwin contract.** The App Group is the only cross-process channel. UserDefaults is atomic per-key only ⇒ multi-field handoffs are single JSON blobs. Darwin notifications are signals ("re-read"), never truth ⇒ correctness comes from projection state + a freshness heartbeat. Writer = main app, reader = keyboard/watch; readers never write back. Each projection has its own deliberately-different staleness window.
4. **Only feedback leaves.** The user-initiated feedback POST is the sole outbound transmission (donations is a read-only GET). Everything else — transcription, rewrite, Ask, embeddings, warm-hold buffer — is on-device. Keep the caveat synced across privacy copy.
5. **Warm-hold orthogonality.** Warm hold is a start-faster optimisation only; it must never change WHERE a dictation goes. Foreground + warm window ⇒ inline insert (no save); only not-foreground takes the warm-resume capture path. Liveness needs both `warmHoldExpiresAt` future AND a fresh heartbeat.
6. **Source-based hero routing.** The recording hero presents from exactly three triggers (FAB, cold `jot://dictate`, return pill); nothing adopts `isRecording`. In-Jot keyboard taps start a background capture and present no hero.
7. **Capture-first cold start.** When the speech model isn't loaded, start the mic immediately and await the model at stop time — nothing said during the ~30s cold load is lost.
8. **Save/no-save decided at the STOP site.** Fate is not stamped at recording birth: stop outside Jot / from the hero ⇒ persist; in-Jot field stop ⇒ `transient` publish without persisting. Gated on `applicationState == .active`.
9. **Publish-first pipeline.** Derive text → publish to clipboard → append to ledger best-effort. A persistence throw must never gate the publish. `transcriptReady` means "published", not "persisted" — reload off `historyMirrorUpdated`.
10. **Single shared singletons.** `RecordingService`/`TranscriptionService`/`StreamingTranscriptionService` are process-wide `.shared`; headless intents reuse them. `JotApp.init` does no blocking I/O and resets `PipelinePhaseProjection` on launch.

## Searchable anchors

Grep breadcrumbs that pin a behaviour to its code. Deduped across subsystems.

- `RECORDING START FROM:` — every recording-start site (zombie/double-start debugging anchor; preserve on edits).
- `AUTOSTART: guard=` / `appForegroundHeartbeat` / `warmResumeObserver` / `pendingExternalKeyboardHero` — app-lifecycle auto-start + heartbeat + external-keyboard hero.
- `jot://dictate` / `jot://rewrite?session=` / `jot-watch://record` / `keyboardDictateTapped` — URL-bounce + deep-link entry points.
- `[SCHEMA-FALLBACK]` / `jot.schema.fallbackActiveSince_v1` / `versionIdentifier` / `JotTranscripts` / `jot.ledger.nextIndex` — schema/store init + migration health.
- `[WARM-HOLD-DEBUG]` / `[WARM-HOLD-NUDGE]` / `warmHoldHeartbeat` / `stale heartbeat` / `warmResumeRequested` / `warmHoldNudgeChanged` — warm-hold liveness + nudge.
- `group.com.vineetu.jot.mobile.shared` / `jot.pipeline.phase` / `pipeline-phase-changed` / `transcript-history.json` / `keyboard-foreground-ping` — cross-process App-Group + Darwin contract.
- `pipelinePhaseChanged` / `historyMirrorUpdated` / `stopRequested` / `appForegroundPong` / `transcriptReady` / `pipeline-unwound-before-publish` — pipeline + keyboard signalling (note: reload off `historyMirrorUpdated`, not `transcriptReady`).
- `Parakeet inference begin`/`end` / `Streaming session begun` / `streamingLoadingChanged` / `Transcription begin — source=` — ASR model lifecycle.
- `BackupExclusion` / `excludeFluidAudioModels` / `isExcludedFromBackup` / `Application Support/FluidAudio` — speech-model weights residency + iCloud-backup exclusion.
- `ask-controller` / `transcript-indexer` / `gemma-embedding` / `bm25-index` / `embeddinggemma-300m-256` / `[cite:` / `backfill-embeddings` — Ask/RAG pipeline.
- `rewrite SUCCESS jobID=` / `enable_thinking` / `rewriteResultSessionID` / `jot.rewrite.jobID` / `Phi4WeightsPurge` / `Cancelled` — rewrite cross-process correlation + Qwen.
- `TranscriptDetailView` / `InlineEditTextView` / `FocusedFieldInsert` / `sessionToken` — transcript detail surface + in-place edit (single-contiguous-replacement delta) + in-field dictation insert.
- `VocabularyRescorerHolder` / `jot.vocabulary.enabled` / `parakeet-ctc-110m-coreml` / `loadFromSimpleFormat` — vocabulary biasing.
- `jot.setup.completed` / `wizardCoreStepCount` / `UITextInputMode.activeInputModes` — setup wizard completion + install detection.
- `jot.speech.modelVariant` / `jot.ask.backend` / `speechModelInstalled` / `Rebuild search index` — Settings state mirrors.
- `transferQueuedFiles` / `pushTopTranscripts` / `watchOriginUUID` / `stageFileSync` / `helloFresh` / `watch.pendingQueue.v1` — watch connectivity.
- `JotDesign.Surface.key` / `frauncesSemiBold` / `Fraunces72pt-Regular` / `WallpaperBackground` — design tokens + fonts.
- `FeedbackClient.shared` / `jot-donations.ideaflow.page/feedback` / `jot.diagnostics.entries` / `DiagnosticsLog.record` — supporting surfaces + the single outbound POST.
- `com.apple.keyboard-service` / `RequestsOpenAccess` — keyboard extension Info.plist identity.

## Keeping this current

- Update this file on **subsystem or boundary changes only** — a new subsystem, a moved boundary, a changed cross-process contract, a new invariant. Do **not** churn it on ordinary file edits; it is intentionally coarse so it survives refactors.
- Treat **drift as broken**: a row pointing at a moved file or a stale invariant is worse than no map. If you split/merge/rename a subsystem, fix the Code map table, the Subsystem note, and any Searchable anchor in the same change.
- This is the WHERE companion to `features.md` (the WHAT). When a change alters behaviour, **pair the edit**: update the relevant `features.md §` and the matching row/note here together, and re-check the `features.md §` links still resolve.
- The Cross-process boundaries section is the highest-value, slowest-changing part — review it whenever you touch the App Group keys, Darwin notification names, the schema, the keyboard link list, or the warm-hold/hero/save-fate routing.
