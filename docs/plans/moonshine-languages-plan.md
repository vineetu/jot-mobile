# Plan: Moonshine as Jot's third on-device engine (Arabic, Vietnamese, Tagalog)

**Status:** PLAN ONLY (2026-09-27). Nothing built. Follows the owner decision in
`docs/research/new-languages-arabic-vietnamese.md` ("use Moonshine for Arabic and the other languages Jot
doesn't support, because it runs on the phone"). Nothing gets turned on until the Phase 0 measurement is done.

## Summary

1. **Scope.** Add Moonshine (`moonshine-swift` 0.1.5, product `MoonshineVoice`, ONNX Runtime linked
   statically, CPU-only) as a third engine family beside Apple and Parakeet. It covers exactly three
   languages that neither Parakeet nor Apple SpeechTranscriber does: Arabic, Vietnamese and Tagalog. Each
   uses a Tiny Streaming model (34M parameters, MIT, about 32 MB), downloaded when the user picks the language.
2. **Integration.** One new `StreamingSession` conformer that gives both the live preview and the finished
   transcript (the D2 promote), a one-shot fallback for everything else, and a fourth routing branch in
   `TranscriptionService`. The keyboard, Watch and Share extension never link it.
3. **Post-processing.** Paragraphs run (Moonshine gives word timings). Filler, number, punctuation and
   vocabulary passes are all off. Automatic cleanup and rewrite go through Apple Intelligence, which supports
   Vietnamese but not Arabic or Tagalog, so they need a per-language gate that does not exist today. Arabic
   also needs right-to-left fixes.
4. **Gate.** Before enabling anything, run a paired on-device comparison on real native-speaker recordings:
   Moonshine vs Apple `DictationTranscriber` (ar-SA, vi-VN). The pass rule is relative to Apple and is fixed
   before any data comes in. If Apple wins for a language, that language routes to Apple instead.
5. **Order.** Phase 0 measurement, then Vietnamese, then Arabic (with RTL), then Tagalog only once its model
   finishes training. About 3–4 engineering weeks in total, plus 1–2 calendar weeks to collect recordings.

Claim markers: **[V]** means read in a primary source, which is cited. **[I]** means inferred and still
needs checking. Repo facts were read in the code on 2026-09-27.

---

## 0. Verified facts about Moonshine (as of 2026-09-27)

| Fact | Status / source |
|---|---|
| Latest release is 0.1.5 (2026-08-24). Streaming models for every language are MIT; only the older non-streaming non-English models are under the Moonshine Community License (free below US$1M revenue) | [V] `CHANGELOGS.md`, `LICENSE`, `docs/license.md` (github.com/moonshine-ai/moonshine) |
| Arabic: Tiny Streaming, 34M, int8 WER 15.5% (Common Voice + FLEURS macro; FLEURS 12.56 / CV 17.91 on float) | [V] `docs/models/available-models.md`, HF `moonshine-ai/moonshine-streaming-tiny-ar` |
| Vietnamese: Tiny Streaming, 34M, int8 WER 9.4% (FLEURS 10.98 / LSVSC 7.63) | [V] same, HF `…-tiny-vi` |
| Tagalog: Tiny Streaming, 34M, int8 WER 14.9% (FLEURS only). "A snapshot of a Stage A run that had not finished training", "the one most likely to move" | [V] `core/moonshine-model-catalog.cpp`, `docs/models/accuracy.md`, HF `…-tiny-tl` |
| On disk per language, about 32.3–32.4 MB: `decoder_kv.ort` 19.7, `encoder.ort` 7.8, `frontend.weights.ort` 2.1, `adapter.ort` 1.3, `cross_kv.ort` 1.3, tokenizer 91–136 KB | [V] HTTP HEAD against download.moonshine.ai |
| CDN path: `https://download.moonshine.ai/model/tiny-streaming-{ar,vi,tl}/quantized_26_08_24/…` (the version is date-stamped). Format is `.ort` only; `.onnx` has been rejected since 0.1.1 | [V] `moonshine-model-catalog.cpp`, `CHANGELOGS.md` |
| Arabic dialect coverage: "FLEURS panel is Egyptian Arabic; Common Voice is broader … MSA and the regional dialects are not measured separately." Labels come from Whisper-teacher pseudo-labelling (about 90k hours for ar), so the model inherits the teacher's errors | [V] HF model card (ar) |
| Arabic, ja, ko, zh, uk should set `max_tokens_per_second = 13` to avoid truncation | [V] `available-models.md` / `accuracy.md` |
| Known failure mode: repetition loops on short or noisy clips | [V] HF model cards |
| Swift package: `github.com/moonshine-ai/moonshine-swift`, tag 0.1.5, product `MoonshineVoice` (static) over binary `Moonshine.xcframework`; swift-tools 6.1; **iOS 15+ / macOS 13+**; slices for ios-arm64, simulator and macOS | [V] moonshine-swift `Package.swift`, xcframework contents. The README inside the main repo (`language-bindings/swift`) is stale (says v0.0.8, `import Moonshine`), so ignore it |
| API: `Transcriber(modelPath:modelArch:.tinyStreaming, options:[TranscriberOption])` → `createStream(updateInterval:)` → `addListener` → `start()` / `addAudio([Float], sampleRate:)` / `stop()`. Events: `LineStarted`, `LineUpdated`, `LineTextChanged`, `LineCompleted`, `LineSpeakersChanged`, `TranscriptError`. `TranscriptLine` carries `text, startTime, duration, lineId, isComplete`, word timings and speaker spans. Also `transcribeWithoutStreaming`, `setKeyterms([String])` (streaming models only) and `setContext` | [V] moonshine-swift `Transcriber.swift` / `Stream.swift` |
| `modelArch` defaults to `.base`, so `.tinyStreaming` must be passed explicitly | [V] code |
| `stop()` "will process any remaining audio and emit final events" | [V] code |
| Audio input is float PCM in [-1, 1] at any sample rate, resampled internally to 16 kHz. 16 kHz is recommended | [V] C header. Mono is [I] |
| Threading: `Transcriber` and `Stream` are plain non-Sendable classes. Listeners fire synchronously on whichever thread calls `addAudio`, and inference runs inline inside `addAudio` once the update interval has elapsed. `MicTranscriber` runs its own `AVAudioEngine` on a private queue | [V] code. That `MicTranscriber` would fight Jot's session is [I], which is why this plan never uses it |
| Models download through `AssetDownloader.ensureModelPresent` (a foreground session, `.part` files, Range resume) into Application Support/MoonshineModels, or can be bundled | [V] `docs/using/downloading-models.md`, `ModelCache.swift` |
| ONNX Runtime is linked statically inside `libmoonshine.a` (`OrtGetApiBase` present). The ios-arm64 archive is 35.9 MB unstripped. The changelog gives "iOS linked binary ~30.6 MB → ~22.4 MB" after 0.1.1 | [V] `nm`, `CHANGELOGS.md` 0.1.1 |
| **CPU only, no Neural Engine.** "iOS builds without CoreML … ORT 1.23's CoreML provider does not compile in a minimal build" | [V] `docs/execution-providers.md` |
| Speed: Tiny Streaming answers 37 ms after speech ends on an A16 iPad (English). Each full pass costs about 102 ms of startup plus 269 ms per second of audio (tiny, speaker-ID on) | [V] `docs/moonshine-vs-whisper.md`, `Stream.swift` comment. That non-English Tiny runs at the same speed is [I] |
| Memory: `.ort` files are memory-mapped. A leak of about 83 MB per `Transcriber` (#216) was fixed in 0.1.5. No published iOS RAM figures | [V] `available-models.md`, issue #216. iOS footprint is [I], so it is measured in Phase 0 |
| Open issue #223: Android crash on `close()` while transcribing | [V]. Whether it also affects iOS is [I] |

### Coverage check: are other Moonshine languages missing from Jot?

Moonshine currently ships **en, ar, vi, tl, de, es, ja, zh (streaming) and ko, uk (non-streaming, Community
license)** [V, `available-models.md`]. Jot already covers en, de, es (Parakeet or Apple), ja, zh, ko (Apple
SpeechTranscriber) and uk (Parakeet) [V, `LanguageChoice.swift`]. **Only ar, vi and tl are uncovered.**
Moonshine's Korean and Ukrainian models are Community-licensed as well, so there is a second reason never
to route those two to Moonshine.

### Apple-side facts that shape the plan

- Apple Intelligence on iOS 27 supports **Vietnamese**. It does **not** support Arabic or Tagalog [V,
  support.apple.com/en-us/121115]. This decides whether automatic cleanup, rewrite and Ask can run on these
  notes.
- Apple Translation covers Arabic and Vietnamese. Tagalog does not appear in the list [I, from the Translate
  language list; confirm with `LanguageAvailability` on device].
- Apple `DictationTranscriber` has ar and vi. `SpeechTranscriber` did not in the macOS 26 probe [V, research
  doc]. **That probe has not been rerun on iOS 27.** Phase 0 step 1 reruns it.
- Jot's vocabulary corrector refuses Arabic by name: `case "hr", "ar": "no common-word list ships — the
  common-word brake would be ABSENT"`. vi and tl fall through to "not measured — fail closed" [V,
  `jot-shared/Sources/JotVocabCore/VocabularyCorrector.swift:123`].

### Tension to flag to the owner (not a blocker)

On 2026-09-14 the owner ruled "no third-party models; FluidAudio is the only package left" (memory
`project-ios27-adoption`). The 2026-09-27 Moonshine decision overrides that for these languages. It adds a
second third-party binary package and about 22 MB of ONNX Runtime to the app. The plan assumes the newer
decision stands.

---

## 1. Engine integration

### 1.1 Routing: `LanguageChoice` gets an engine axis

`Jot/App/Transcription/LanguageChoice.swift`:
- Add the cases `arabic`, `vietnamese`, `tagalog`. The raw values are stable strings: they persist into
  `AppGroup.transcriptionLanguage`, `Transcript.language` and the MRU recents. **No schema change**, because
  `Transcript.language` is already a free string.
- Add `enum DictationEngineFamily { case apple, parakeet, moonshine }` and a `var engineFamily`. Add
  `var isMoonshineOnly: Bool` (true for the three new cases) and `var moonshineLanguageCode: String?`
  ("ar", "vi", "tl").
- Every exhaustive switch needs the new cases filled in:
  - `commonWordsResource`: nil
  - `fillerLanguageCode`: nil
  - `punctuationLanguageCode`: nil
  - `isVocabEligible`: false (see §3)
  - `appleLocaleIdentifier`: nil. This keeps `isAppleSupported` false, so `activeLanguageUsesApple` stays
    false without any change.
  - `fluidAudioLanguage`: nil
  - `isoCode`: "ar" / "vi" / "tl"
  - names: `("Arabic","العربية")`, `("Vietnamese","Tiếng Việt")`, `("Tagalog","Tagalog")`. Decide whether
    the row reads "Filipino".
  - `fromLanguageCode`: add "ar", "vi", "tl", "fil".
- Add `var isRightToLeft: Bool` (Arabic only). Its keyboard-safe twin lives in Shared (§3.4).

`TranscriptionService.swift`:
- Add `nonisolated static var activeLanguageUsesMoonshine: Bool { LanguageChoice.current.isMoonshineOnly }`.
  It is read once per pass, like `activeLanguageUsesApple`.
- **`stopPassTranscribe`** (currently :956): add a Moonshine branch **before** `fluidAudioStopPass`.
  Otherwise, since the three languages have no Apple locale, they fall through to the Parakeet branch and
  run Parakeet Ultra on Arabic audio. The branch calls `moonshineStopPass(samples:)`:
  - Do the D2 promote, identical to `appleStopPass`: exact `sourceSampleCount` match and less than 60 s
    since the artifact was deposited.
  - Otherwise run `MoonshineOneShotEngine.transcribe(samples:)`.
  - No cross-engine fallback (owner directive 2026-07-06).
- **`makeStreamingSession`** (:1543): add a Moonshine branch after the Unified check and before the
  `useAppleEngine` guard. It builds `MoonshineStreamingSession`, or returns `NoPreviewSession()` on failure
  (never `PreviewScheduler`, which would be the wrong engine).
- **Parakeet warm and download paths must skip Moonshine languages.** `selectedVersion`, `modelDirectory()`,
  `warmUp()`, `warmIfNeeded()`, `modelsExistOnDiskForSelectedVariant()`, `allDeviceModelTargets()` and
  `ensureModelIsDownloadedOrThrow()` all treat "not English" as Parakeet Ultra. Without a guard, picking
  Arabic → `handleLanguageChange()` → `warmUp()` → `loadOrFail` would start the **632 MB Ultra download**.
  This is the most dangerous change point in the plan. Add `guard !LanguageChoice.current.isMoonshineOnly`
  at each of these sites, or better, have `selectedVersion` return nil and handle that.
- **`handleLanguageChange`**: also call `MoonshineModel.syncWithRouting()`, the same shape as
  `UnifiedEnglishModel.syncWithRouting()`.
- **`runInference`**: nothing changes beyond the gates. Vocabulary is off through `isVocabEligible`, and
  filler/number/punctuation are off through nil codes. `ParagraphSegmenter` runs if timings are present
  (§3.1). Also replace the error string "Parakeet needs at least 1 s of audio" with an engine-neutral one;
  it is user-visible for these languages too.

`DictationLanguageAvailability.swift`:
- `isAvailable`: Moonshine languages come first and are **available on every device** (CPU-only, 34M
  parameters, not gated on `parakeetUsable`).
- `usesParakeetDownload`: must return false for them. Today it would return true on a SpeechTranscriber
  device, because "ar" is not in `appleCodes`. On a DictationTranscriber-only device "ar" IS in
  `appleCodes`, which is harmless for availability but must not route to Apple.
- Add `usesMoonshineDownload(_:)`.

### 1.2 New files (`Jot/App/Transcription/Moonshine/`)

- **`MoonshineModel.swift`**: `@MainActor` singleton holder modelled on `UnifiedEnglishModel`.
  - `State { notDownloaded, downloading(fraction), loading, ready, failed }`.
  - Owns one `Transcriber` for the active language, built with `modelArch: .tinyStreaming` and
    `max_tokens_per_second=13` for ar (the exact option syntax is [I], so verify it). Turn off Moonshine's
    speaker identification if an option exists, because Jot has its own diarizer and speaker ID is part of
    the 269 ms/s cost [I].
  - `syncWithRouting()` is the single gate: eligible means `resumeIfPending` + `prepare()`; not eligible
    means `unload()` only when `.ready`. It copies the Unified pattern that avoids stranding a parked
    prepare.
  - Unload on memory warning.
  - `makeSession(queue:presenter:sessionID:)` and `transcribeOneShot(samples:)`.
  - `Transcriber` is not Sendable, so it is held in `@unchecked Sendable` boxes confined to a dedicated
    serial executor. Use `@preconcurrency import MoonshineVoice`.
- **`MoonshineStreamingSession.swift`**: `actor … : StreamingSession`, shaped like
  `UnifiedStreamingSession`.
  - `drain()` pops `StreamingBufferQueue` chunks, which are already 16 kHz mono `[Float]` from the tap, so
    no converter is needed. It calls `stream.addAudio(chunk, sampleRate: 16000)` and adds to
    `consumedSampleCount`.
  - A listener collects `LineTextChanged`/`LineCompleted` into `[lineId: text]`. The ordered join goes to
    `presenter.update(text:isFinal:false,sessionID:)` on the MainActor.
  - `quiesce()` calls `stream.stop()` (the flush) and then publishes `isFinal:true`.
  - `stopArtifact()` is non-nil only when nothing failed and the text is non-empty. It carries the word
    timings mapped to `TokenTiming`.
  - `usesBatchModel = false`.
  - `addAudio` runs inference **inline**, so the actor must not run on the MainActor. Put it on a custom
    serial executor or a dedicated thread, because a 30–100 ms decode on the cooperative pool can starve
    other work. Measure this in Phase 0.
  - **Teardown order:** `stop()`, then release, never release while `addAudio` is in flight (issue #223).
- **`MoonshineOneShotEngine.swift`**: for the stop-pass when there is no promotable artifact. That covers
  pause/resume slice seams, live text off, queue drops, audio-file and Share imports, Watch takes and
  re-transcribe.
  - Default is to feed the full samples through a fresh `Stream` in 0.5 s chunks rather than using
    `transcribeWithoutStreaming`, because streaming models do their own line segmentation over long audio.
    Whether `transcribeWithoutStreaming` handles 10-minute files is [I]; Phase 0 benchmarks both on a
    5-minute and a 30-minute file.
- **`MoonshineModelFetcher.swift`**: see §2.

### 1.3 Capture, warm hold and the live-text gate

- **Warm hold is safe by construction** as long as Moonshine is pure `[Float]`-in compute. **Never use
  `MicTranscriber`**, which runs its own `AVAudioEngine`. Add the invariant to ARCHITECTURE.md: zero
  `AVAudioSession` or `AVAudioEngine` references under `Moonshine/`. `RecordingService` stays the only
  owner of the mic.
- The capture format already matches: the tap gives 16 kHz mono Float32 [V, UnifiedStreamingSession
  `makeBuffer` comment]. Moonshine expects float in [-1, 1] at 16 kHz [V].
- **Live text off** (`RecordingService.kickOffStreamingSession` :472): today the queue is closed and the
  stop-pass re-transcribes the whole file. For Moonshine that means about 0.27 s per second of audio on CPU
  after stop [V baseline], so a 2-minute dictation would wait roughly 30 s [I]. Option A (recommended): for
  Moonshine languages, run the streaming session even when live text is off and suppress
  `presenter.update`. Stopping stays instant, and the extra CPU is the same work the stop-pass would do
  anyway. That requires an exemption in the gate at :472, a documented change to the ARCHITECTURE
  "Preview-on gate" invariant. Decide on the Phase 0 numbers (stop latency and energy for both options).
- **Cold load**: `.ort` files are memory-mapped, so load should take well under a second [I]. If Phase 0
  shows more than about 1 s, mirror the load state to the keyboard through the existing
  `streamingLoadingVariantLabel` AppGroup path, as `beginBatchLoadLabelMirror` does.
- **Concurrency**: Moonshine is CPU-only while Parakeet and the diarizer are CoreML/ANE. There is no shared
  graph, but check `TranscriptionService.isBusy` before re-transcribe.
- The `RECORDING START FROM:` log lines are untouched, since no new capture sites are added.

---

## 2. Downloading a model when the user picks the language

- **Size** is about 32.4 MB per language [V HEAD]. The download is triggered **only by an explicit
  selection** (Settings picker, wizard W2, detail-view re-transcribe, Watch picker). It never happens at
  launch (App Review guideline 4.2.3(ii)), matching `warmIfNeeded`'s on-disk gate.
  `MoonshineModel.syncWithRouting()` at launch only resumes a download the user already started.
- **Fetcher:** `MoonshineModelFetcher`, a copy of the `UnifiedModelFetcher` / `PunctuationModelFetcher`
  pattern (background `URLSession`, per-file staging, pinned manifest, atomic install). Do **not** use
  Moonshine's `AssetDownloader`, which uses a foreground session, the same failure class that
  `UnifiedModelFetcher`'s header documents.
  - Manifest: six files per language, with the exact byte sizes from the HEAD requests, plus a SHA-256 that
    we compute once and pin. The sizes alone cannot catch a same-size replacement on a CDN path that is
    date-stamped.
  - Session identifier `com.vineetu.jot.mobile.Jot.moonshine-fetch`, routed in `JotAppDelegate`
    (`JotApp.swift:25`, new `case`).
  - **Not discretionary, and cellular allowed.** The user is waiting to dictate right after picking, and
    32 MB is small, unlike the 582 MB Unified fetch, which is discretionary and Wi-Fi-only. Owner to
    confirm.
  - Install directory: `Application Support/Models/moonshine/<lang>/quantized_26_08_24/`, excluded from
    backup through `BackupExclusion` (add a call next to `excludeFluidAudioModels()`).
- **Mirror option:** the MIT license allows self-hosting. The alternative to pinning download.moonshine.ai
  is mirroring to Jot's own storage. Recommend pinning plus checksum for v1 and mirroring if the CDN path
  ever changes.
- **Progress UI:**
  - `SettingsView.languageStatusRow` (around :436–505): add a Moonshine branch that reads
    `MoonshineModel.shared.state`. Copy: "Downloading Arabic model — 42%" / "Ready". The row caption reads
    "Downloads ~33 MB" before download, like the "~632 MB" copy.
  - `SetupWizard/Steps/LanguageStep.swift` (:216–262): same status line, and Continue is gated on `.ready`
    the same way the Ultra download is.
- **Disk cleanup:** at 32 MB, keep models for any language still in `LanguageChoice.recentLanguages` (at
  most 5) so switching back is instant. Delete a language's directory when it drops out of the recents,
  and sweep on launch (`MoonshineModelFetcher.sweepUnused()`, next to `sweepOrphanedPurgingDirs`). The
  maximum footprint is about 100 MB for three languages. Settings → Storage could show a "Remove" action
  later; not needed for v1.
- **Failure:** "Couldn't download the Arabic model — check your connection" with a retry, routed through
  the §12.2 "Model Download Failure" copy. Dictating while the model is missing captures audio, then fails
  honestly with that message, the same as the no-fallback rule.

---

## 3. Post-processing by language

| Step | ar | vi | tl | Where |
|---|---|---|---|---|
| ParagraphSegmenter (pause-based) | yes, if word timings are mapped | yes | yes | `runInference`; timings come from `TranscriptLine` word timings [V exist; quality is [I]] |
| FillerWordCleaner | off (no list) | off | off | `fillerLanguageCode` nil |
| NumberNormalizer | off (English-only) | off | off | same |
| Punctuation model (`PunctuationRestorer`) | off (English-only, evidence gate) | off | off | `punctuationLanguageCode` nil. Moonshine emits its own punctuation [I, Whisper-teacher labels]; check in Phase 0 outputs |
| CTC vocab spot/merge | **off** (Latin CTC scorer, Arabic script) | off | off | `isVocabEligible` false |
| jot-shared `VocabularyCorrector` | **refused by name** ("no common-word list") | fail-closed (unmeasured) | fail-closed | `VocabularyCorrector.swift:123`. Enabling one needs a frequency list plus the jot-shared measurement protocol; separate work |
| Moonshine in-engine `setKeyterms` | candidate | candidate | candidate | [V API exists for streaming models]. Follow-up: feed Vocabulary terms and measure false insertions the same way jot-shared does. Not in v1 |
| Automatic cleanup / rewrite / keyboard Rewrite (Apple FM) | **off**, unsupported locale | on (iOS 27) | **off** | No locale gate exists today (grep for `supportsLocale` finds nothing). Add `LanguageSupport.appleIntelligenceSupports(lang)` using `SystemLanguageModel.default.supportsLocale(_:)`, checked in `CleanupService`, `DictationPipeline` automatic cleanup, `RewriteClient` and `KeyboardRewriter` (read from the AppGroup language string). Otherwise Arabic notes hit an FM `unsupportedLanguageOrLocale` error. Same gate for Ask (PCC) answering over these notes [I on PCC] |
| Translate | source ar ok | vi ok | hide the action, or allow `tl` only if `LanguageAvailability` says so | `TranslateSheet` |
| Search / Spotlight | Core Spotlight tokenises Arabic and Vietnamese [I] | | | Check in Phase 2 |

### 3.4 Right-to-left (Arabic)

No RTL handling exists in the app today (grep for `rightToLeft`/`writingDirection` finds nothing). SwiftUI
`Text` orders the glyphs correctly, but **alignment follows the UI's layout direction, not the text**, so
Arabic lines sit left-aligned in an English UI. Change points:
- `Shared/DictationScript.swift` (new, Foundation-only, safe for the keyboard):
  `isRightToLeft(rawLanguage:)` plus a per-string check (first strong character, via
  `NSLinguisticTagger`/`Locale.Language.characterDirection`) for mixed libraries.
- `Keyboard/StreamingStrip.swift`: the caption uses `.multilineTextAlignment(.leading)` and tail-follows
  the latest text. For RTL, set `.environment(\.layoutDirection, .rightToLeft)` on the caption only, so the
  newest words appear on the reading edge. VoiceOver's `suffix(200)` is character-based and bidi-safe.
- In-app `TranscribingText` (home), `RecordingHeroView`, `FeaturedLatestRow`/`AliveRow` (recents),
  `TranscriptDetailView` body, and `InlineEditTextView` (`UITextView`: `textAlignment = .natural` follows
  the UI language, so set the paragraph style's `baseWritingDirection = .natural` or pick it per
  transcript). Decide the direction **per transcript** from `Transcript.language`, not from the current
  selection.
- Paste: `textDocumentProxy.insertText` inserts logical-order Unicode and the host app decides direction.
  Insert **no** bidi control marks. Check DictationPipeline's smart-spacing/leading-space logic with Arabic
  (no case; Arabic punctuation "،" "؟"). Vietnamese and Tagalog are Latin script, so only NFC matters:
  make sure the pipeline never NFD-splits Vietnamese stacked diacritics (compare bytes of the pasted text
  in Phase 1).
- Mixed Arabic/Latin lines (brand names) are the bidi edge case. Test in Notes, Messages, WhatsApp and
  Slack.

---

## 4. Keyboard, Watch, Shortcuts, Share import

- **Keyboard (`JotKeyboard`)**: runs no inference and must **not** link MoonshineVoice. List the package
  in `project.yml` under the `Jot` target only; after `xcodegen`, confirm the JotKeyboard, ShareExtension
  and Watch link phases do not contain it. The keyboard only needs RTL display (§3.4) and the
  loading-label mirror if cold load is slow. The Rewrite tile is gated per §3.
- **Watch**: `Shared/WatchLanguage.swift` needs three new cases. Its `code` must equal
  `LanguageChoice.rawValue`, which is the existing contract. Update `WatchLanguagePickerView`, which comes
  from `presentationOrder`. On the phone side:
  - `PhoneSideWCSession.applyWatchLanguage` (:333) calls `handleLanguageChange(eagerWarm: onDisk)`. Extend
    `onDisk` to Moonshine models.
  - If a watch take arrives for a language whose model is missing, start the fetch (picking a language on
    the watch counts as the user's choice), keep the take queued, and transcribe once the model is ready.
    Do not fail it. Check how the drain retries today.
  - Note that the watch list today omits the Apple-only CJK languages; the Moonshine ones are
    phone-transcribed, so they are safe to add.
- **Shortcuts**: `TranscribeAudioFileIntent` goes through `ensureModelIsDownloadedOrThrow()` (:596/:673),
  which checks the **Parakeet** directory. Make that check engine-aware, so a Moonshine language with its
  model present passes and one without fails fast: "Open Jot and pick Arabic once to download its model."
  The intent has a budget of about 30 s. `DictateIntent` and the Action Button use the normal pipeline and
  need nothing extra. `AskJotIntent` is gated per §3.
- **Share import** (`PendingShareDrainer` → `transcribe(audioFileURL:)`): same one-shot path, so the
  long-file check from §1.2 applies. Auto-diarize on import: the diarizer is language-independent, but
  aligning speaker turns to text uses token timings, so check that Moonshine word timings produce sane
  turns (Phase 2).
- **Re-transcribe** (`TranscriptDetailView` :714/:743): the list shows every `LanguageChoice`. Picking a
  Moonshine language that is not downloaded must show the download state before running. It currently sets
  the AppGroup language and calls `handleLanguageChange()`, which would trigger the fetch; show progress
  there.

---

## 5. Measurement before anything is enabled (Phase 0)

Owner rule: measure with the real model on the phone, show the outputs, and fix the thresholds in advance.
The comparison is **relative to Apple's engine on the same clips**, which is the alternative the user
would otherwise get.

### 5.1 Step 1: probe on iOS 27 (half a day)

Add a small DEBUG-only Diagnostics action that logs `SpeechTranscriber.supportedLocales` and
`DictationTranscriber.supportedLocales` on the owner's iOS 27 iPhone, filtered to ar* / vi* / tl* / fil*.
Record every Arabic locale DictationTranscriber offers (ar-SA, ar-AE, ar-EG …). If **SpeechTranscriber**
gained ar or vi in 27, add it as a third contender for that language. It streams, is already wired, and
costs zero bytes.

### 5.2 Harness (2–3 days)

- In-app "ASR bench" screen, hidden in `DiagnosticsView` or DEBUG only. It needs to run on the phone,
  because CPU speed, memory and Apple's on-device assets differ from the Mac. The package gets linked
  **only** in this phase's internal build.
- Input: a folder of 16 kHz WAV files plus `refs.jsonl` (`{id, lang, speaker, dialect, text}`), imported
  through Files or the Share sheet.
- For each clip it runs:
  - (a) Moonshine streaming, fed in real-time-sized 0.1 s chunks
  - (b) the Moonshine one-shot
  - (c) Apple `DictationTranscriber` with the probed locale, **forced** even on SpeechTranscriber
    hardware. Today `appleEngineIsSpeechTranscriber` picks DictationTranscriber only on old devices, so
    the harness calls a locale-parameterised copy of `DictationOneShotEngine`.
  - (d) SpeechTranscriber, if step 1 found the locale.
- Output JSON per clip: hypothesis text, load ms, time to first partial, stop-to-final ms, real-time
  factor, peak `phys_footprint`, and whether repetition occurred (flagged in the output, never filtered).
- Energy: one 10-minute continuous Moonshine session and one Apple session, measured with Xcode's energy
  gauge and MetricKit.
- Scoring happens on the Mac with a small script (`scripts/asr-bench/score.py`, new). It writes a report
  that shows **every clip's reference and all hypotheses side by side**, so the owner reads outputs, not
  just numbers.

### 5.3 Data

- **Real Jot-style dictation (the part that decides).** Per language, at least **5 native speakers × 20
  clips = 100 clips**, 10–60 s each (about 50–60 minutes). Content is what Jot users dictate: messages,
  to-dos, a note with a number, a date and a name, a question. Speakers use their natural register; do
  not ask for formal speech. Record with the Jot capture path (iPhone mic, quiet room plus one noisy
  setting per speaker) so the audio matches production.
  - **Arabic:** label each speaker's dialect. Cover at least MSA-leaning read speech plus Egyptian,
    Levantine and Gulf (Maghrebi if possible), with 2 or more speakers where available.
  - References are typed by the speaker and checked by a second native speaker.
  - Recruiting: friends and family or paid transcribers. This takes the most calendar time.
- **Anchor sets (harness sanity check).** 100 FLEURS test clips per language (ar is Egyptian there;
  vi; tl) plus 100 Common Voice ar. Moonshine's numbers must land near the published figures (ar about
  12.6 FLEURS / 17.9 CV float; vi about 11.0 FLEURS). A large gap means the harness is wrong. These sets
  do not decide shipping.

### 5.4 Metrics

- **Arabic:** WER plus CER after normalisation:
  - strip tashkeel and tatweel
  - unify alef variants (أ إ آ → ا), ى → ي, ة → ه
  - remove punctuation (including ، ؟ ؛)
  - map Arabic-Indic digits to Western
  - CER is reported because WER punishes Arabic clitic attachment.
- **Vietnamese:** syllable WER after NFC and lowercase, with punctuation stripped. **Keep tone and vowel
  diacritics**, which carry meaning. Also report the rate of wrong or missing diacritics, since it is a
  common failure.
- **Tagalog:** WER with lowercase and punctuation stripped. Code-switched English words count as normal
  tokens.
- Report per clip, per speaker and per dialect. Pooled WER comes with a **paired bootstrap 95% CI on the
  WER difference (Moonshine − Apple)**, resampled by speaker.
- **Catastrophic-clip rate:** empty output, repetition loop, or clip WER > 50%, counted per engine.
- Latency and cost: stop-to-final p50/p95, RTF, peak memory, energy per 10 minutes.

### 5.5 Pass rule (fixed before data collection; relative, not guessed)

Moonshine ships for language L only if all four hold on the **real-dictation set**:
1. The upper bound of the paired-bootstrap 95% CI on (WER_moonshine − WER_apple) is ≤ 0, meaning it is not
   worse than Apple. For Arabic, use CER when WER and CER disagree.
2. Moonshine's catastrophic-clip rate is ≤ Apple's.
3. No Arabic dialect group is worse on Moonshine than on Apple by a CI that excludes 0. If one is, ship
   with copy naming the dialects it handles, or hold.
4. The owner reads the side-by-side outputs and agrees.

If Apple wins for L, **route L to Apple `DictationTranscriber` instead.** That work is a per-language
engine override (use DictationTranscriber even where SpeechTranscriber exists) plus the locale added to
`appleLocaleIdentifier`. `DictationStreamingSession` and `DictationOneShotEngine` already exist, so it is
cheaper than Moonshine. **Tagalog has no Apple baseline** [I; confirm in step 1]. It ships only after
Moonshine publishes a finished-training tl model. Then run the same 100-clip set, have 2 native reviewers
blind-judge each clip as "usable with light edits / not usable", and let the owner decide on the outputs.

---

## 6. Risks and unknowns

| Risk | Notes and mitigation |
|---|---|
| Accuracy ceiling of a 34M model | The owner's earlier preference was best quality, and the research ranks Nemotron 3.5 and NVIDIA ar FastConformer ahead. Moonshine was chosen because it runs. Phase 0 is the honest check. If both engines are poor on dialect speech, the copy must say so ("works best with Modern Standard / Egyptian Arabic"), as the Apple-only plan already required for Arabic |
| Arabic dialects | Not measured separately by Moonshine [V]. Handled by per-dialect breakdown and rule 3 |
| App size | About +22 MB linked into the main app [V changelog] on top of about 40 MB stripped, even for users who never pick these languages. The SPM checkout pulls a 71.8 MB zip, which affects build time only. Not avoidable with a static library; on-demand resources cannot carry code |
| No ANE, CPU only | Battery and heat on long dictations. Measure energy per 10 minutes against Apple. Decide option A/B in §1.3 on the numbers |
| Keyboard memory | Not a risk if the plan is followed (never linked). Would be a real risk if anyone put inference in the extension (about 60 MB ceiling) |
| Swift 6 concurrency | Non-Sendable classes and synchronous listeners. Use a dedicated executor and `@preconcurrency`. Check Swift 6.4 strict mode early (see the `Mutex` gotcha in the iOS 27 notes) |
| Crash on release during transcription (#223 Android) | Enforce `stop()` → drain → release ordering. Add a stress test: switch language mid-dictation |
| Static-library symbol clashes (bundled protobuf/onnx) | FluidAudio is Swift/CoreML, so low risk [I]. Verify with a link of the full app in Phase 1 day 1 |
| CDN path churn (date-stamped) | Pinned URLs plus sizes plus SHA-256. Self-host mirror as a fallback |
| License drift | Re-check the license file and the model card on **every** model URL bump. Never pin non-streaming ar/vi/ko/uk (Community license). Add a comment above the manifest |
| Tagalog maturity | An unfinished snapshot [V]. Hold until the final model and re-measure. Behind the other two in any case |
| Parakeet routing leaking into Moonshine languages | The Ultra download, `usesParakeetDownload` and the upgrade nudge. Guards in §1.1; unit-test `LanguageChoice` routing for all three cases |
| Apple Intelligence features failing on ar/tl notes | Locale gate (§3). Today there is none, so this is also a latent bug for any unsupported language |
| iOS 27 SpeechTranscriber may already cover ar/vi | Step 5.1 could make Moonshine unnecessary for one or both. That is why the probe comes first |

---

## 7. Rollout order and effort

| Phase | Content | Effort |
|---|---|---|
| **0 Measure** | Probe (5.1), harness (5.2), package linked in an internal build only, data collection, scoring, owner review | 3–4 dev days + 1–2 calendar weeks for recordings |
| **1 Engine + Vietnamese** | `LanguageChoice` cases and routing guards; `MoonshineModel` / `StreamingSession` / `OneShot` / `Fetcher`; AppDelegate routing; Settings + wizard progress; storage sweep; the Apple Intelligence locale gate; Shortcuts preflight; re-transcribe; `project.yml` (Jot target only) + `xcodegen`; docs | 6–8 days |
| **2 Arabic** | RTL display (keyboard strip, hero, recents, detail, editor); paste tests across 4 hosts; dialect copy; `max_tokens_per_second`; diarization alignment check; Translate source | 3–4 days |
| **3 Watch** | `WatchLanguage` cases, phone-side missing-model queueing | 1–2 days |
| **4 Tagalog** | After Moonshine ships a finished-training tl model: bump the manifest, re-measure (§5.5), enable | 1 day + measurement |
| Later | `setKeyterms` vocabulary boost with measurement; per-language frequency lists for jot-shared | separate plans |

Vietnamese goes first because it is the lowest risk: the best published WER (9.4%), Latin script, cleanup
works on iOS 27, and no dialect question. It exercises the whole new engine before RTL work is added.
Arabic follows if it passes §5.5; otherwise Arabic takes the Apple `DictationTranscriber` override. Each
phase that builds clean goes to TestFlight (owner rule).

### Docs that must change with the build (CLAUDE.md pairing rule)

- `features.md`: §2.15 (a third engine, named in user terms), §4.8, §6.1 (the "~33 MB" download), §2.13
  (Watch languages), §3.2/§3.9 (language label, Translate), plus the §7 cleanup/rewrite unavailability for
  ar/tl.
- `ARCHITECTURE.md` Transcription section: the third family, the no-`AVAudioSession` invariant for
  `Moonshine/`, Parakeet-path guards, the new fetcher identifier, the live-text gate exemption if option A
  is chosen.
- `known-bugs-and-plans.md`: needs a registry entry linking this doc (not added here; planning-only task).
- Atlas: the language-picker screens.

### Schema impact

None. `Transcript.language` is a free string and the new raw values decode through `fromStored`. No
`@Model` change and no new `JotSchemaVN`.

## Owner English test (build 320, 2026-09-27)
Hidden switch Settings → (tap Version 5×) → "Moonshine v2 for English (test)" (`MoonshineEnglishTest`,
`AppGroup.Keys.moonshineEnglishTest`): English dictation's FINAL transcript comes from Moonshine Medium Streaming
(245M, 268 MB download to Application Support/MoonshineModels); live text stays Parakeet. Adds ~72 MB xcframework
(all slices) to the build.
Mac measurement on the owner's 18 English recordings (4,284 words), words differing from Jot-for-Mac's saved
Nemotron transcripts: Parakeet Unified 14.5 %, Parakeet Ultra 16.4 %, **Moonshine Medium 20.1 %**; Moonshine ran at
11× real time on M-series CPU (no ANE) vs Parakeet's 100×+. Sample: Unified "we are not yet ready there" vs Moonshine
"like we have not here for any day". Remove the switch, file and package if the test is dropped.
