@preconcurrency import AVFoundation
@preconcurrency import CoreML
import FluidAudio
import Foundation
import UIKit
import os.log
import os.signpost

/// On-device transcription via FluidAudio's Parakeet TDT 0.6B v2 (Apple Neural Engine).
///
/// Two callers:
/// - `ContentView` (in-app record button) → `transcribe(samples: [Float])` after
///   `RecordingService` drains the tap buffer. Samples already arrive at 16 kHz
///   mono Float32, matching Parakeet's expected input exactly.
/// - `TranscribeAudioFileIntent` (Shortcuts entry point) → `transcribe(audioFileURL: URL)`
///   with whatever audio the Shortcut's prior action produced. We decode + resample
///   in-process and then fall into the same inference path.
///
/// Both paths share model loading + cache. Single-in-flight is enforced via
/// `isTranscribing`; `AsrManager` itself is an actor (per FluidAudio), so the
/// actor's mailbox is the underlying serialization primitive — our flag is a
/// short-circuit that produces a nicer error (`.busy`) instead of letting the
/// actor queue the call and return late.
///
/// See `docs/best-practices.md` §1 (concurrency) and §3 (FluidAudio specifics)
/// for the reasoning behind `@MainActor`, the `@unchecked Sendable` observer
/// pattern, and the Application Support cache location.
@MainActor
@Observable
final class TranscriptionService {
    enum ModelState: Equatable, Sendable {
        case notLoaded
        case downloading(Double)
        case loading
        case ready
        case failed(String)
    }

    enum TranscriptionError: LocalizedError {
        case busy
        case audioTooShort
        case loadFailed(String)
        case inferenceFailed(String)
        case audioFileUnreadable(String)
        case audioFileConversionFailed(String)

        var errorDescription: String? {
            switch self {
            case .busy: return "A transcription is already in progress."
            case .audioTooShort: return "Recording is under one second — Parakeet needs at least 1 s of audio."
            case .loadFailed(let summary): return "Model load failed: \(summary)"
            case .inferenceFailed(let summary): return "Transcription failed: \(summary)"
            case .audioFileUnreadable(let summary): return "Could not read the audio file: \(summary)"
            case .audioFileConversionFailed(let summary): return "Could not decode the audio file to 16 kHz mono: \(summary)"
            }
        }
    }

    /// Process-wide singleton.
    ///
    /// ## Why a singleton
    ///
    /// Two callers enter this file from different layers:
    /// - `JotApp` → injected via `.environment(...)` into SwiftUI
    /// - `TranscribeAudioFileIntent.runTranscription` → headless AppIntent
    ///
    /// Before this was a singleton, each caller held its own
    /// `TranscriptionService` instance, and therefore its own `AsrManager`.
    /// A 10-second Parakeet cold-load on the first in-app record could NOT
    /// be amortized by the main-app instance when a subsequent Shortcut run
    /// arrived in the same process — the intent would fault a fresh
    /// instance and pay the load again.
    ///
    /// Singleton collapses this: one instance → one `AsrManager` → one
    /// warm window. Both callers observe the same `modelState`, so an
    /// eager `warmUp()` on app launch is visible to every subsequent
    /// inference call in the process.
    ///
    /// ## Lifetime
    ///
    /// The shared instance lives for the lifetime of the process.
    /// `AsrManager`'s CoreML handle is process-ephemeral — iOS terminates
    /// the process on jetsam / user swipe-close, and `handleMemoryWarning`
    /// proactively evicts `manager` on `UIApplication.didReceiveMemoryWarning`.
    /// So the guarantee is "warmed at the last eviction boundary," not
    /// "warmed once ever." Subsequent `warmUp()` / `transcribe(...)` calls
    /// re-load as needed.
    ///
    /// ## Testing / preview access
    ///
    /// `init()` stays `internal` so SwiftUI `#Preview` blocks and unit tests
    /// can construct fresh instances without contaminating the shared one.
    @MainActor static let shared = TranscriptionService()

    private(set) var modelState: ModelState = .notLoaded
    var speechModelIdentifier: String { Self.selectedRepo.rawValue }

    private let log = Logger(subsystem: "com.vineetu.jot.mobile.Jot", category: "transcription")

    /// Hard upper bound on the concurrent CTC keyword-spot pass. If the
    /// rescorer hangs / is mid-prepare / is wedged (e.g. from a fast vocab
    /// off→on toggle race), the spot is abandoned past this and the plain
    /// TDT transcript publishes. Generous: a long dictation legitimately
    /// re-chunks at 15 s windows (measured CTC ≈ 5 s on a 5-min clip on
    /// Mac ANE; on-device iPhone ANE is slower, so headroom is intentional).
    nonisolated static let vocabSpotTimeoutSeconds: Double = 8.0
    /// Hard upper bound on the cheap post-spot merge (~14–20 ms CPU plus a
    /// couple of actor hops). Small; exists only so a wedged
    /// CorrectionStore/Provenance actor can never block the publish.
    nonisolated static let vocabMergeTimeoutSeconds: Double = 2.0
    private let signposter = OSSignposter(subsystem: "com.vineetu.jot.mobile.Jot", category: "transcription")

    /// The active dictation model — chosen by **device capability**, not by
    /// the user (there is no model picker). Capable devices (≥6 GB-class RAM,
    /// `DeviceCapability.is600MCapable`) run the bundled Parakeet 0.6B v2.
    /// Sub-6GB devices (iPhone 11 / 12·13 non-Pro / SE) cannot hold the 600M's
    /// ~2 GB resident footprint, so they fall back to the smaller Parakeet
    /// TDT-CTC 110M — which is NOT bundled (keeps the IPA small) and is fetched
    /// on first need via `AsrModels.download` into Application Support.
    ///
    /// NOTE: this is the *dictation* 110M (`parakeet-tdt-ctc-110m-coreml`,
    /// fused preprocessor+encoder), entirely separate from the *vocabulary*
    /// CTC subset (`parakeet-ctc-110m-coreml`) the rescorer uses — different
    /// FluidAudio repo, different on-disk directory.
    nonisolated private static var selectedVersion: AsrModelVersion {
        // English keeps the device-capability path (bundled v2 / 110M). Every
        // European language resolves to int8 Parakeet v3 — one shared
        // multilingual model, downloaded on first selection. FIRST PASS: v3 on
        // every device (no int4 / device-RAM gating yet — design doc §4).
        if LanguageChoice.current.isEnglish {
            return DeviceCapability.is600MCapable ? .v2 : .tdtCtc110m
        }
        return .v3
    }

    /// FluidAudio `Repo` paired with `selectedVersion`. Used for
    /// `MLModelConfigurationUtils.defaultModelsDirectory(for:)` and for
    /// the user-facing speech-model identifier.
    private static var selectedRepo: Repo {
        if LanguageChoice.current.isEnglish {
            return DeviceCapability.is600MCapable ? .parakeetV2 : .parakeetTdtCtc110m
        }
        return .parakeetV3
    }

    private let standIn: (any TranscriptionStandIn)?
    private var manager: AsrManager?

    private var prepareTask: Task<Void, Error>?
    private var prepareGeneration = 0

    private var isTranscribing: Bool = false

    // `deinit` is always nonisolated in Swift 6, so it can't touch
    // @MainActor state on this class. We exempt the observer token from
    // both observation tracking (nothing reads it from the UI) and actor
    // isolation. Invariant: written exactly once from `init` (MainActor),
    // read exactly once from `deinit`, never concurrently. The underlying
    // `NotificationCenter.removeObserver` is itself thread-safe.
    @ObservationIgnored
    private nonisolated(unsafe) var memoryWarningObserver: NSObjectProtocol?

    init(standIn: (any TranscriptionStandIn)? = TranscriptionStandInFactory.make()) {
        self.standIn = standIn
        subscribeMemoryWarnings()
    }

    deinit {
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
    }

    /// Eagerly kick off Parakeet model download + load, without running
    /// inference. The public "please be ready" hook for any code path that
    /// wants to pay the ~10 s cold-load cost up front rather than at the
    /// first user-visible record button press.
    ///
    /// ## Call sites
    ///
    /// Expected callers (in order of priority):
    /// 1. App launch (`JotApp.body`'s `.task { }`, or an early `onAppear`).
    ///    First-record-is-slow is the user pain this method exists for.
    /// 2. Scene foregrounding — cheap because of the coalescing guarantee
    ///    below. Useful defense-in-depth after a memory-warning eviction.
    /// 3. A first-run wizard or onboarding completion step, if we ever add
    ///    one — gives the user a "warming up Jot…" moment with visible
    ///    download progress via `modelState`.
    ///
    /// Not for: the record-button action. That path already awaits
    /// `ensurePreparing()` inside `transcribe(samples:)` before inference
    /// begins.
    ///
    /// ## Contract
    ///
    /// - **Idempotent + coalescing.** Every call routes through
    ///   `ensurePreparing()`, which returns the single in-flight
    ///   `Task<Void, Error>` if one is active. `N` concurrent `warmUp()`
    ///   calls produce one load, not `N`. A call after load completion
    ///   short-circuits inside `loadOrFail()` (`manager != nil` early
    ///   return) and costs ~nanoseconds.
    ///
    /// - **Non-throwing.** Any load failure surfaces later through
    ///   `modelState == .failed(...)` (observable) or a thrown
    ///   `TranscriptionError.loadFailed` from `transcribe(...)`. Warm-up
    ///   callers don't need to reason about failure modes — their only
    ///   responsibility is "kick the tyres, move on."
    ///
    /// - **Fire-and-forget.** We intentionally drop the returned `Task`.
    ///   The download + load run concurrently with whatever the caller
    ///   does next. Nobody needs to `await` this; if they care about
    ///   readiness they should observe `modelState` instead.
    ///
    /// ## Eviction semantics
    ///
    /// `handleMemoryWarning` may evict `manager` + `prepareTask` under
    /// memory pressure. After eviction, `warmUp()`'s prior effect is
    /// nullified; the next call re-loads. That's intentional — we'd
    /// rather pay the re-load cost than risk jetsam mid-session.
    func warmUp() {
        if standIn != nil {
            modelState = .ready
            log.info("Parakeet warmUp satisfied by simulator transcription stand-in")
            return
        }

        log.info("Parakeet warmUp requested — modelState=\(Self.describe(self.modelState), privacy: .public)")
        _ = ensurePreparing()
    }

    /// Single front door for "warm the model if it makes sense" — the ONE place
    /// the pre-warm gate lives. Every trigger (app launch, scene activation, the
    /// setup wizard) calls THIS instead of re-deriving its own gate, so there is
    /// exactly one predicate to reason about. Warms only when BOTH hold:
    ///
    /// - the **selected variant's files are on disk** — preserves the
    ///   no-silent-download-before-consent guarantee (Guideline 4.2.3(ii)): an
    ///   un-downloaded opt-in variant returns `false` here, so warming never
    ///   triggers a network fetch; the bundled default is always `true`.
    /// - the model is **`.notLoaded` or `.failed`** (genuinely cold). We never
    ///   re-kick `.downloading`/`.loading` (already in flight) or `.ready` (done).
    ///
    /// Idempotent regardless: `warmUp()` → `ensurePreparing()` coalesces
    /// concurrent callers, so overlapping triggers (launch + wizard) are safe.
    func warmIfNeeded() {
        guard Self.modelsExistOnDiskForSelectedVariant() else { return }
        switch modelState {
        case .notLoaded, .failed:
            warmUp()
        case .downloading, .loading, .ready:
            break
        }
    }

    /// Awaits the in-flight Parakeet load (kicking one if idle), so other heavy
    /// Neural-Engine model loads can be SERIALIZED behind it. Loading the vocab CTC
    /// model and the EmbeddingGemma model CONCURRENTLY with Parakeet makes Apple's
    /// ANE compiler service (a single shared system service) serialize all three,
    /// ~4×-ing the cold start: measured ~60s with the three contending vs ~16s for
    /// Parakeet alone (a standalone probe loads the identical model in ~16s). Task
    /// priority alone does NOT fix this — the contention is in the system compiler,
    /// not the scheduler — so the dependents must wait, not just yield. Returns
    /// promptly if the model is already loaded or failed.
    func awaitWarmSettled() async {
        switch modelState {
        case .ready, .failed: return
        default: break
        }
        if prepareTask == nil { warmIfNeeded() }
        if let task = prepareTask { _ = try? await task.value }
    }

    /// Called when the user flips Settings → Speech model variant.
    ///
    /// Invalidates the currently-loaded manager so the next
    /// `ensurePreparing()` rebuilds for the new variant. The previous
    /// variant's weights stay on disk so flipping back is a fast reload.
    ///
    /// modelState reflects the NEW variant's actual disk state:
    /// - On-disk → `.ready` (loads lazily on next call; UI shows Ready pill
    ///   instead of misleading "Not downloaded").
    /// - Not on-disk → `.notLoaded` (UI shows Download button; the explicit
    ///   tap is the sanctioned 4.2.3(ii) consent trigger).
    ///
    /// NOTE: TDT-CTC 110M's `CtcHead.mlmodelc` is opportunistically fetched
    /// during `AsrModels.load()` but custom-vocab biasing in this app is
    /// powered by FluidAudio's separate `VocabularyRescorer` +
    /// `CtcKeywordSpotter` stack (using its own `CtcModels.load`
    /// pipeline), wired separately under `Jot/App/Vocabulary/`. The two
    /// paths share the same on-disk CTC bundle but are otherwise
    /// independent — the variant picker affects only the primary
    /// transcribe model, not whether vocabulary biasing applies. See
    /// the Jot desktop app's `Sources/Vocabulary/` for the reference
    /// implementation we're tracking.
    func handleVariantChange() {
        prepareTask?.cancel()
        prepareTask = nil
        prepareGeneration += 1
        manager = nil
        if Self.modelsExistOnDiskForSelectedVariant() {
            modelState = .ready
        } else {
            modelState = .notLoaded
        }
        log.info(
            "Speech variant changed — variant=\(AppGroup.speechModelVariant, privacy: .public) modelState=\(Self.describe(self.modelState), privacy: .public)"
        )
    }

    /// React to a user picking a different dictation **language** in Settings.
    /// Evicts the currently-loaded model (its weights belong to the old
    /// language's `AsrModelVersion`), then re-prepares the new language's model —
    /// downloading it first if it isn't on disk yet (English is bundled, so that
    /// path is a fast no-download load; a European language downloads v3 once).
    ///
    /// Calling `warmUp()` here is a **deliberate, consented** user action, so it
    /// is allowed to trigger a network fetch (unlike the launch-time
    /// `warmIfNeeded()` gate, which never downloads silently). Download progress
    /// and readiness surface through `modelState`, which Settings observes.
    func handleLanguageChange() {
        prepareTask?.cancel()
        prepareTask = nil
        prepareGeneration += 1
        // Release the (possibly ANE-resident) AsrManager OFF the main thread.
        // Deallocating a loaded CoreML model blocks for ~1s, and this runs on
        // the MainActor from the Settings picker — so a plain `manager = nil`
        // hangs the UI on the FIRST language change after a dictation (when a
        // model is actually loaded). We clear the property synchronously (so the
        // subsequent `warmUp()` loads the NEW language's model instead of reusing
        // the old one), but hand the old instance to a utility task so its heavy
        // deinit happens off the main thread. `AsrManager` is a Sendable actor,
        // so this hand-off is safe.
        if let old = manager {
            manager = nil
            Task.detached(priority: .utility) { _ = old }
        }
        modelState = .notLoaded
        log.info(
            "Dictation language changed — language=\(AppGroup.transcriptionLanguage, privacy: .public)"
        )
        warmUp()
    }

    func purgeAndReload() async {
        // Dev/QA path retained for symmetry with the v2 cache-purge flow.
        // The TDT-CTC 110M weights now ship inside the IPA — the bundle is
        // read-only, so there's nothing to remove. We cancel any in-flight
        // prepare task and re-prime `modelState` from the bundle's presence
        // (effectively a no-op refresh that surfaces a clear .failed state
        // if iOS app thinning unexpectedly stripped the resources).
        // The single Parakeet 0.6B v2 model ships bundled inside the IPA —
        // the bundle is read-only, so there's nothing on-disk to purge. We
        // cancel any in-flight prepare and re-prime `modelState` from the
        // bundle's presence (effectively a no-op refresh that surfaces a
        // clear .failed state if iOS app thinning unexpectedly stripped the
        // resources).
        prepareTask?.cancel()
        prepareTask = nil
        prepareGeneration += 1
        manager = nil

        log.notice("purgeAndReload no-op — speech model weights are bundled and read-only")
        modelState = .notLoaded
        warmUp()
    }

    // MARK: - Sample-based inference (in-app record flow)

    func transcribe(samples: [Float]) async throws -> String {
        if let standIn {
            guard !isTranscribing else { throw TranscriptionError.busy }
            isTranscribing = true
            defer { isTranscribing = false }

            log.info("Simulator transcription stand-in begin — sampleCount=\(samples.count, privacy: .public)")
            let result = try await standIn.transcribe(samples: samples)
            log.info("Simulator transcription stand-in end — chars=\(result.count, privacy: .public)")
            return result
        }

        try Self.guardAudioLength(sampleCount: samples.count)
        guard !isTranscribing else { throw TranscriptionError.busy }

        isTranscribing = true
        defer { isTranscribing = false }

        let audioDurationSeconds = Self.audioDurationSeconds(sampleCount: samples.count)
        let startedAt = Date()
        let interval = signposter.beginInterval("transcribe-samples")
        log.info(
            "Transcription begin — source=samples startedAt=\(Self.timestamp(startedAt), privacy: .public) audioDurationS=\(audioDurationSeconds, privacy: .public) sampleCount=\(samples.count, privacy: .public)"
        )

        do {
            let result = try await runInference(
                on: samples,
                label: "samples",
                audioDurationSeconds: audioDurationSeconds
            )
            let endedAt = Date()
            let elapsedMS = Self.elapsedMilliseconds(from: startedAt, to: endedAt)
            let rtf = Self.realTimeFactor(elapsedMS: elapsedMS, audioDurationSeconds: audioDurationSeconds)
            log.info(
                "Transcription end — source=samples startedAt=\(Self.timestamp(startedAt), privacy: .public) endedAt=\(Self.timestamp(endedAt), privacy: .public) elapsedMS=\(elapsedMS, privacy: .public) audioDurationS=\(audioDurationSeconds, privacy: .public) rtf=\(rtf, privacy: .public) chars=\(result.count, privacy: .public)"
            )
            signposter.endInterval("transcribe-samples", interval)
            return result
        } catch {
            let endedAt = Date()
            let elapsedMS = Self.elapsedMilliseconds(from: startedAt, to: endedAt)
            let rtf = Self.realTimeFactor(elapsedMS: elapsedMS, audioDurationSeconds: audioDurationSeconds)
            log.error(
                "Transcription failed — source=samples startedAt=\(Self.timestamp(startedAt), privacy: .public) endedAt=\(Self.timestamp(endedAt), privacy: .public) elapsedMS=\(elapsedMS, privacy: .public) audioDurationS=\(audioDurationSeconds, privacy: .public) rtf=\(rtf, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            signposter.endInterval("transcribe-samples", interval)
            throw error
        }
    }

    // MARK: - File-based inference (Shortcuts entry point)

    /// Transcribe an audio file at `url`. Accepts any format `AVAudioFile` can
    /// decode — Shortcuts' built-in *Record Audio* action produces `.m4a`, but
    /// `.wav`, `.caf`, `.aiff`, and any Core Audio–supported format work.
    ///
    /// Flow: pre-flight model-on-disk check → decode → resample to 16 kHz mono
    /// Float32 → run Parakeet → return transcript. This is the entry point for
    /// `TranscribeAudioFileIntent`, which chains after a Shortcut's upstream
    /// file-producing action.
    ///
    /// Safe to call from non-MainActor contexts via standard `await`-hop
    /// semantics. `AsrManager` is an actor (FluidAudio), so the heavy inference
    /// does not block MainActor — MainActor is only held during the short
    /// synchronous file-decode pass.
    ///
    /// ### Observability
    ///
    /// Logs at each step via `os.log` subsystem `com.vineetu.jot.mobile.Jot`, category
    /// `transcription`. Pull with `log show --predicate 'subsystem == "com.vineetu.jot.mobile.Jot"'`
    /// or via Console.app to diagnose Shortcut-triggered failures where the
    /// bridged `NSError.code` loses the typed error's context.
    func transcribe(audioFileURL url: URL) async throws -> String {
        if let standIn {
            guard !isTranscribing else { throw TranscriptionError.busy }
            isTranscribing = true
            defer { isTranscribing = false }

            log.info("Simulator file transcription stand-in begin — file=\(url.lastPathComponent, privacy: .public)")
            let result = try await standIn.transcribe(samples: [])
            log.info("Simulator file transcription stand-in end — chars=\(result.count, privacy: .public)")
            return result
        }

        log.info(
            "transcribe(audioFileURL:) entry — path=\(url.lastPathComponent, privacy: .public) ext=\(url.pathExtension, privacy: .public) exists=\(FileManager.default.fileExists(atPath: url.path), privacy: .public)"
        )
        let transcriptionStartedAt = Date()

        // Pre-flight: the Parakeet model must already exist on disk. A headless
        // AppIntent run has a ~30 s total execution budget (research doc
        // `docs/research/shortcuts-transcribe-intent.md` §6 risk 2). The Parakeet
        // weights are ~1.25 GB — a cold download cannot complete inside that
        // budget on realistic cellular/Wi-Fi conditions. If the model isn't on
        // disk, fail fast with an actionable message instead of attempting a
        // download that will either exceed the budget (iOS kills the intent
        // process) or return an opaque network error.
        //
        // The main-app `transcribe(samples:)` path is NOT guarded this way
        // because in-app it's fine to run a progress-showing download on the
        // record-button press; `prepare()` in the intent would hit the same
        // wall. This guard exists specifically to produce a *user-actionable*
        // error on the Shortcut path.
        try ensureModelIsDownloadedOrThrow()

        guard !isTranscribing else { throw TranscriptionError.busy }

        let interval = signposter.beginInterval("transcribe-file")

        let decodeStartedAt = Date()
        let decodeInterval = signposter.beginInterval("transcribe-file-decode")
        var decodeIntervalEnded = false
        log.info("transcribe(audioFileURL:) — decode begin startedAt=\(Self.timestamp(decodeStartedAt), privacy: .public)")

        do {
            let samples = try Self.loadAndResample(
                url: url,
                targetSampleRate: Self.sampleRate,
                log: log
            )
            let decodeEndedAt = Date()
            let decodeElapsedMS = Self.elapsedMilliseconds(from: decodeStartedAt, to: decodeEndedAt)
            let audioDurationSeconds = Self.audioDurationSeconds(sampleCount: samples.count)
            signposter.endInterval("transcribe-file-decode", decodeInterval)
            decodeIntervalEnded = true
            log.info(
                "transcribe(audioFileURL:) — decode end startedAt=\(Self.timestamp(decodeStartedAt), privacy: .public) endedAt=\(Self.timestamp(decodeEndedAt), privacy: .public) elapsedMS=\(decodeElapsedMS, privacy: .public) audioDurationS=\(audioDurationSeconds, privacy: .public) sampleCount=\(samples.count, privacy: .public) file=\(url.lastPathComponent, privacy: .public)"
            )
            log.info("transcribe(audioFileURL:) — decoded \(samples.count, privacy: .public) samples @ \(Int(Self.sampleRate), privacy: .public)Hz")

            try Self.guardAudioLength(sampleCount: samples.count)

            let transcribeStartedAt = Date()
            log.info(
                "Transcription begin — source=file startedAt=\(Self.timestamp(transcribeStartedAt), privacy: .public) audioDurationS=\(audioDurationSeconds, privacy: .public) sampleCount=\(samples.count, privacy: .public) file=\(url.lastPathComponent, privacy: .public)"
            )

            isTranscribing = true
            defer { isTranscribing = false }

            log.info("transcribe(audioFileURL:) — running Parakeet inference")
            let result = try await runInference(
                on: samples,
                label: "file",
                audioDurationSeconds: audioDurationSeconds
            )
            log.info("transcribe(audioFileURL:) — inference returned \(result.count, privacy: .public) chars")

            let endedAt = Date()
            let elapsedMS = Self.elapsedMilliseconds(from: transcribeStartedAt, to: endedAt)
            let totalElapsedMS = Self.elapsedMilliseconds(from: transcriptionStartedAt, to: endedAt)
            let rtf = Self.realTimeFactor(elapsedMS: elapsedMS, audioDurationSeconds: audioDurationSeconds)
            let totalRTF = Self.realTimeFactor(elapsedMS: totalElapsedMS, audioDurationSeconds: audioDurationSeconds)
            log.info(
                "Transcription end — source=file startedAt=\(Self.timestamp(transcribeStartedAt), privacy: .public) endedAt=\(Self.timestamp(endedAt), privacy: .public) elapsedMS=\(elapsedMS, privacy: .public) totalElapsedMS=\(totalElapsedMS, privacy: .public) audioDurationS=\(audioDurationSeconds, privacy: .public) rtf=\(rtf, privacy: .public) totalRtf=\(totalRTF, privacy: .public) chars=\(result.count, privacy: .public) file=\(url.lastPathComponent, privacy: .public)"
            )
            signposter.endInterval("transcribe-file", interval)
            return result
        } catch {
            let endedAt = Date()
            let totalElapsedMS = Self.elapsedMilliseconds(from: transcriptionStartedAt, to: endedAt)
            if !decodeIntervalEnded {
                signposter.endInterval("transcribe-file-decode", decodeInterval)
            }
            signposter.endInterval("transcribe-file", interval)
            log.error(
                "Transcription failed — source=file startedAt=\(Self.timestamp(transcriptionStartedAt), privacy: .public) endedAt=\(Self.timestamp(endedAt), privacy: .public) totalElapsedMS=\(totalElapsedMS, privacy: .public) file=\(url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
    }

    /// Pre-flight for the Shortcut path. Checks whether the Parakeet weights
    /// have been fetched to Application Support; if not, throws a friendly
    /// `.loadFailed` pointing the user at the one-time main-app download.
    ///
    /// Does NOT block on ongoing downloads — if `prepare()` is mid-flight when
    /// the Shortcut runs, the file almost certainly isn't present yet either,
    /// and waiting would just chew through the headless budget. Fail fast; let
    /// the user retry once the main-app download finishes.
    private func ensureModelIsDownloadedOrThrow() throws {
        let exists = Self.modelsExistOnDiskForSelectedVariant()
        log.info("ensureModelIsDownloadedOrThrow — variant=\(AppGroup.speechModelVariant, privacy: .public) modelsExist=\(exists, privacy: .public)")
        if !exists {
            throw TranscriptionError.loadFailed(
                "The selected speech-recognition model hasn't been downloaded yet. Open Jot, go to Settings → Speech model and tap Download, then re-run your Shortcut."
            )
        }
    }

    // MARK: - Inference core

    private static func guardAudioLength(sampleCount: Int) throws {
        guard Double(sampleCount) >= Self.sampleRate else {
            throw TranscriptionError.audioTooShort
        }
    }

    /// Branch on the active variant.
    ///
    /// Runs the established batch pass through `AsrManager.transcribe`
    /// plus the full post-pipeline cleanup (vocabulary rescore +
    /// paragraph segmentation + filler-word cleanup + number
    /// normalization).
    private func runInference(on samples: [Float], label: String, audioDurationSeconds: Double) async throws -> String {
        // 4.2.3(ii) consent guard: do NOT silently download a model via
        // the record-then-transcribe path. The Settings "Download" button
        // is the only sanctioned download trigger. If the user flipped
        // variants and hasn't tapped Download yet, surface a friendly
        // error and exit. Simulator stand-in bypass: standIn is non-nil
        // in simulator and the in-app record path already short-circuits
        // earlier — we only reach this branch on real-device transcribe.
        //
        // Capability-gated model presence:
        // - English on a capable device runs the BUNDLED 600M — a missing model
        //   means iOS app thinning stripped the IPA resources; the only recovery
        //   is a reinstall, so throw rather than attempt a (nonexistent) download.
        // - Sub-6GB devices (110M) AND any EUROPEAN language (Parakeet v3) are
        //   download-on-first-need. A missing model is EXPECTED on first use: the
        //   user invoking dictation is the consent trigger, so we fall through to
        //   `ensurePreparing()` → `loadOrFail()`, whose download branch fetches
        //   the weights and surfaces `.downloading` progress. We do NOT throw.
        //   (European on a capable device is NOT bundled, so the "reinstall"
        //   error must not fire for it — only for the genuinely-bundled English
        //   case.)
        if standIn == nil
            && LanguageChoice.current.isEnglish
            && DeviceCapability.is600MCapable
            && !Self.modelsExistOnDiskForSelectedVariant() {
            throw TranscriptionError.loadFailed(
                "The bundled speech model couldn't be found. Reinstall Jot from the App Store."
            )
        }
        let inferenceStartedAt = Date()
        let prepareStartedAt = Date()
        try await ensurePreparing().value
        let prepareEndedAt = Date()
        let prepareElapsedMS = Self.elapsedMilliseconds(from: prepareStartedAt, to: prepareEndedAt)
        log.info(
            "Parakeet prepare wait end — source=\(label, privacy: .public) startedAt=\(Self.timestamp(prepareStartedAt), privacy: .public) endedAt=\(Self.timestamp(prepareEndedAt), privacy: .public) elapsedMS=\(prepareElapsedMS, privacy: .public) modelState=\(Self.describe(self.modelState), privacy: .public)"
        )
        guard let manager else {
            throw TranscriptionError.loadFailed("Model manager unavailable after load.")
        }

        let inferenceInterval = signposter.beginInterval("transcribe-inference")
        log.info(
            "Parakeet inference begin — source=\(label, privacy: .public) startedAt=\(Self.timestamp(inferenceStartedAt), privacy: .public) audioDurationS=\(audioDurationSeconds, privacy: .public) sampleCount=\(samples.count, privacy: .public)"
        )
        do {
            // FluidAudio 0.14.x dropped the `source:` overload in favor of
            // an `inout TdtDecoderState` carried by the caller. For a
            // one-shot batch transcribe of a complete recording we hand
            // the manager a fresh decoder state per call (no streaming
            // carry-over). Decoder-layer count is version-specific
            // (1 for `tdtCtc110m`, 2 for v2/v3/tdtJa) and
            // `AsrModelVersion.decoderLayers` is the SDK's source of
            // truth. Mirrors the Mac app's `Transcriber.swift`.
            var decoderState = TdtDecoderState.make(
                decoderLayers: Self.selectedVersion.decoderLayers
            )

            // ── Concurrency: overlap the expensive CTC keyword-spot pass
            // with the TDT transcribe. The spot consumes ONLY the audio
            // (not the TDT text/timings), so it can run on the separate
            // `CtcKeywordSpotter` while TDT decodes on the `AsrManager`
            // actor. Only the cheap merge (which needs the TDT timings)
            // runs after both finish. Measured 15–23% off the
            // rescore-inclusive post-stop wait (docs/plans/vocab-rescore-parallelization.md).
            //
            // Gating is byte-identical to the old serial path: the spot is
            // only kicked off when vocab is enabled (otherwise the rescore
            // would have been skipped entirely), and the merge still only
            // runs when `tokenTimings` is present. When vocab is disabled
            // the `async let` is never created → zero behavior change.
            //
            // The spot result is `Sendable` (CTC log-probs + frame
            // duration); the two tasks touch disjoint models with no shared
            // mutable state, so there is no data race under Swift 6 strict
            // concurrency.
            let vocabEnabledForThisRun = VocabularyStore.shared.isEnabled
            // Snapshot the audio into a `let` so the concurrently-running
            // spot task captures an immutable value (no aliasing with the
            // TDT pass, which reads `samples` by value as well).
            let audioForSpot = samples
            // BOUNDED + NON-FATAL: the spot runs under a hard timeout. If the
            // rescorer is unready, mid-prepare, errors, or hangs, `withTimeout`
            // returns nil and we publish the plain TDT transcript — the spot can
            // NEVER block the transcribe publish or the MainActor model pipeline.
            // SCALE the timeout to the audio length: the CTC spot re-chunks at
            // 15 s windows, so a long dictation legitimately takes longer than a
            // short one. Floor `vocabSpotTimeoutSeconds` for short clips; ~1.5×
            // the audio duration above that, so a LEGIT spot completes (vocab is
            // not falsely dropped on a long recording) while still bounding a
            // genuine hang. (The toggle-race that caused the wedge is fixed
            // separately; this timeout is the belt-and-suspenders safety valve.)
            let spotTimeoutSeconds = max(
                Self.vocabSpotTimeoutSeconds,
                Self.audioDurationSeconds(sampleCount: audioForSpot.count) * 1.5
            )
            async let spotResult: CtcKeywordSpotter.SpotKeywordsResult? = {
                guard vocabEnabledForThisRun else { return nil }
                // 191: the vocab CTC model loads DEFERRED (after Parakeet, to keep
                // the cold start fast). If a dictation stops before it finished,
                // WAIT for it here (bounded) so EVERY dictation gets custom
                // vocabulary instead of silently falling back to raw. Returns
                // immediately once ready, so warm/normal dictations pay nothing.
                _ = await VocabularyRescorerHolder.shared.awaitReady(timeoutSeconds: 20)
                let spot = await withTimeout(seconds: spotTimeoutSeconds) {
                    try await VocabularyRescorerHolder.shared.spot(
                        audioSamples: audioForSpot
                    )
                }
                // `withTimeout` returns `T?` where T is itself `…Result?`, so
                // a timeout (outer nil) and a not-ready spot (inner nil) both
                // collapse to "no rescore" — exactly the old fall-back.
                if spot == nil {
                    self.log.error(
                        "vocabulary spot skipped — not ready or timed out after \(spotTimeoutSeconds, privacy: .public)s; publishing raw transcript"
                    )
                }
                return spot ?? nil
            }()

            let result = try await manager.transcribe(
                samples,
                decoderState: &decoderState,
                language: LanguageChoice.current.fluidAudioLanguage
            )
            let inferenceEndedAt = Date()
            let wallClockMS = Self.elapsedMilliseconds(from: inferenceStartedAt, to: inferenceEndedAt)
            let wallClockRTF = Self.realTimeFactor(elapsedMS: wallClockMS, audioDurationSeconds: result.duration)
            let engineRTF = result.duration > 0 ? result.processingTime / result.duration : 0
            log.info(
                "Parakeet inference end — source=\(label, privacy: .public) startedAt=\(Self.timestamp(inferenceStartedAt), privacy: .public) endedAt=\(Self.timestamp(inferenceEndedAt), privacy: .public) wallClockMS=\(wallClockMS, privacy: .public) processingMS=\(result.processingTime * 1_000, privacy: .public) audioDurationS=\(result.duration, privacy: .public) wallClockRtf=\(wallClockRTF, privacy: .public) engineRtf=\(engineRTF, privacy: .public) chars=\(result.text.count, privacy: .public)"
            )
            signposter.endInterval("transcribe-inference", inferenceInterval)

            // Vocabulary boosting pass — best-effort. Any failure
            // (rescorer not ready, CTC bundle missing, model throws)
            // falls through to the raw TDT transcript so a broken
            // rescorer can never regress the user-visible result.
            // `tokenTimings` is required by the rescorer's public API;
            // if FluidAudio ever returns nil here the rescore is
            // skipped. Mirrors `jot/Sources/Transcription/Transcriber.swift:117`.
            var transcriptText = result.text
            // v1b — start every dictation with an empty correction-provenance
            // slot so a stale `pending` (from a no-proposal dictation, or from a
            // non-saving caller like Ask/watch/file-import) can never be committed
            // under this transcript's id.
            await CorrectionProvenance.shared.clearPending()
            // Diagnostic: does the batch+rescore path even run for THIS dictation,
            // and are its preconditions met? If this record never appears for a
            // keyboard/live dictation, that path uses streaming output (no vocab).
            DiagnosticsLog.record(
                source: "main-app",
                category: .vocabularyGate,
                message: "batch transcribe finished",
                metadata: [
                    "enabled": "\(VocabularyStore.shared.isEnabled)",
                    "hasTimings": "\(result.tokenTimings != nil)",
                    "chars": "\(result.text.count)",
                ]
            )
            // Join the concurrently-running CTC spot pass (kicked off
            // before `manager.transcribe` above). Awaiting unconditionally
            // here drains the structured task on every path; when vocab is
            // disabled the task body returned `nil` immediately, so this is
            // a no-op. The cheap merge (which needs the TDT `tokenTimings`)
            // runs only when both vocab is enabled AND timings are present —
            // byte-identical gating to the old serial `rescore` call.
            let resolvedSpot = await spotResult
            if VocabularyStore.shared.isEnabled,
                let timings = result.tokenTimings,
                resolvedSpot != nil {
                // The merge is cheap CPU (~14–20 ms) plus a couple of actor
                // hops, but it is still bounded + non-fatal: a hung
                // CorrectionStore/Provenance actor or a wedged rescorer can
                // never block the publish. On timeout/skip we keep the raw
                // TDT text — byte-identical to the old "rescore returned nil"
                // fall-back. (Skip entirely when the spot produced nothing.)
                let textForMerge = result.text
                let merged = await withTimeout(seconds: Self.vocabMergeTimeoutSeconds) {
                    await VocabularyRescorerHolder.shared.merge(
                        transcript: textForMerge,
                        tokenTimings: timings,
                        spotResult: resolvedSpot
                    )
                }
                // Outer nil = merge timed out; inner nil = rescorer not ready.
                if let merged, let rescored = merged {
                    transcriptText = rescored
                } else if merged == nil {
                    self.log.error(
                        "vocabulary merge timed out after \(Self.vocabMergeTimeoutSeconds, privacy: .public)s; publishing raw transcript"
                    )
                }
            }

            // Paragraph segmentation — runs after rescore so paragraph
            // breaks are applied to the user-visible (rescored) text.
            // The segmenter falls back to `transcriptText` unchanged on
            // any degenerate input (no timings, single word, word-count
            // drift from rescore), so this is always safe to call.
            // Single source of truth: every batch caller (hero, keyboard
            // URL-bounce, wizard W5, Shortcuts intent) goes through this
            // method, so they all get paragraph segmentation for free.
            if let timings = result.tokenTimings {
                transcriptText = ParagraphSegmenter.segment(
                    rescoredText: transcriptText,
                    tokenTimings: timings
                )
            }
            // English-only text cleanup. FillerWordCleaner (strips English
            // "um/uh") and NumberNormalizer (English-style inverse text
            // normalization) are English-oriented regex/lookup passes; running
            // them on a non-English v3 transcript would mangle it. The Mac app
            // likewise skips this chain for v3 (it emits clean cased/punctuated
            // text natively — `jot/features.md §30`). ParagraphSegmenter above is
            // language-agnostic (pause-based), so it stays for every language.
            if LanguageChoice.current.isEnglish {
                // Strip simple filler words AFTER paragraph segmentation so the
                // removed tokens don't change pause-measurement decisions.
                transcriptText = FillerWordCleaner.clean(transcriptText)
                // Normalize spelled numbers to digits (AP-style + idioms +
                // time-of-day). Runs LAST so it sees the cleaned, segmented text.
                transcriptText = NumberNormalizer.normalize(transcriptText)
            }
            return transcriptText
        } catch {
            let inferenceEndedAt = Date()
            let wallClockMS = Self.elapsedMilliseconds(from: inferenceStartedAt, to: inferenceEndedAt)
            let wallClockRTF = Self.realTimeFactor(elapsedMS: wallClockMS, audioDurationSeconds: audioDurationSeconds)
            log.error(
                "Parakeet inference failed — source=\(label, privacy: .public) startedAt=\(Self.timestamp(inferenceStartedAt), privacy: .public) endedAt=\(Self.timestamp(inferenceEndedAt), privacy: .public) wallClockMS=\(wallClockMS, privacy: .public) audioDurationS=\(audioDurationSeconds, privacy: .public) wallClockRtf=\(wallClockRTF, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            signposter.endInterval("transcribe-inference", inferenceInterval)
            throw TranscriptionError.inferenceFailed(error.localizedDescription)
        }
    }

    // MARK: - Preview inference (batch-only streaming, Phase 0)

    /// Lean inference path for the live-preview re-transcribe loop
    /// (`docs/plans/batch-only-streaming.md`). Deliberately NOT
    /// `transcribe(samples:)`:
    ///
    /// - **No `isTranscribing` gate.** Preview ticks coalesce in
    ///   `PreviewScheduler` (latest-wins) and must never make the saving
    ///   stop-pass throw `.busy`. Serialization happens naturally on the
    ///   `AsrManager` actor's mailbox — a stop-pass queues behind at most
    ///   one in-flight tick.
    /// - **No side effects.** Skips `CorrectionProvenance.clearPending()`
    ///   and `DiagnosticsLog` — those belong to the saving stop-pass only.
    /// - **NO vocabulary rescore** (adversarial review #2 F2):
    ///   `VocabularyRescorerHolder.rescore` is a second CoreML inference
    ///   (CTC spotter over the window's audio) and records correction
    ///   provenance *internally* — running it per tick doubles inference
    ///   cost and corrupts adaptive-vocab state. Consequence: vocab terms
    ///   may visibly correct when the stop-pass result lands. Accepted.
    /// - **Never loads or downloads.** Rides a manager the normal warm-up
    ///   already produced; returns `nil` when not ready.
    /// - **Returns `nil` instead of throwing** — a failed or too-short
    ///   (<1 s) tick is silently dropped by the scheduler.
    /// Whether `previewTranscribe(...)` can presently produce text, i.e. the
    /// model is loaded and ready (or the simulator stand-in is active).
    ///
    /// The `PreviewScheduler` reads this to implement **capture-first** across
    /// a COLD model load: on the first dictation after an install/update the
    /// 600M load can run 30-40s+, during which every `previewTranscribe` call
    /// returns `nil`. The scheduler must NOT tick or advance its window while
    /// not ready — otherwise the cap give-up valve discards the audio captured
    /// during the load and the first cold session's preview never recovers
    /// even after the model finishes (the warm 2nd session works because it
    /// starts already-ready). With this flag the scheduler holds all captured
    /// audio and, the instant the model is ready, drains it into the preview.
    var isPreviewModelReady: Bool {
        if standIn != nil { return true }
        return manager != nil && modelState == .ready
    }

    func previewTranscribe(samples: [Float]) async -> String? {
        if let standIn {
            // Simulator: exercise the preview pipeline with the stand-in
            // text so the scheduler/UI flow is testable without a model.
            return try? await standIn.transcribe(samples: samples)
        }
        guard let manager, modelState == .ready else { return nil }
        guard Double(samples.count) >= Self.sampleRate else { return nil }
        do {
            var decoderState = TdtDecoderState.make(
                decoderLayers: Self.selectedVersion.decoderLayers
            )
            let result = try await manager.transcribe(
                samples,
                decoderState: &decoderState,
                language: LanguageChoice.current.fluidAudioLanguage
            )
            var text = result.text
            // Text-only quality pipeline (cheap): paragraphs need token
            // timings; filler + number passes are regex/lookup. Vocab is
            // intentionally absent — see doc comment.
            if let timings = result.tokenTimings {
                text = ParagraphSegmenter.segment(rescoredText: text, tokenTimings: timings)
            }
            // English-only cleanup (see batch path) — these passes are
            // English-oriented and would mangle a non-English preview.
            if LanguageChoice.current.isEnglish {
                text = FillerWordCleaner.clean(text)
                text = NumberNormalizer.normalize(text)
            }
            return text
        } catch {
            log.debug("preview transcribe failed — \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Model lifecycle (best-practices §3.2, §3.3, §3.7)

    private func ensurePreparing() -> Task<Void, Error> {
        if let prepareTask {
            log.info("Parakeet prepare reuse — modelState=\(Self.describe(self.modelState), privacy: .public)")
            return prepareTask
        }

        let createdAt = Date()
        log.info(
            "Parakeet prepare task create — startedAt=\(Self.timestamp(createdAt), privacy: .public) modelState=\(Self.describe(self.modelState), privacy: .public)"
        )
        let generation = prepareGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            try await self.loadOrFail(generation: generation)
        }
        prepareTask = task
        return task
    }

    private func loadOrFail(generation: Int) async throws {
        #if targetEnvironment(simulator)
        try checkPrepareGeneration(generation)
        modelState = .ready
        log.info("Parakeet load bypassed on simulator")
        return
        #endif

        if manager != nil {
            modelState = .ready
            log.info("Parakeet load skip — manager already ready")
            return
        }

        try checkPrepareGeneration(generation)
        // Snapshot the variant once at the top of `loadOrFail` so the
        // download / load / cache-existence calls below all agree on a
        // single `AsrModelVersion`. A user flip in Settings between the
        // existence check and the load would otherwise route the load
        // against weights for a different version. Per the design comment
        // on the Settings picker, variant changes only take effect on the
        // next dictation start — this snapshot enforces that contract.
        let version = Self.selectedVersion
        let directory = Self.modelDirectory()
        let modelsOnDisk = AsrModels.modelsExist(at: directory, version: version)
        let prepareStartedAt = Date()
        let prepareInterval = signposter.beginInterval("parakeet-prepare")
        log.info(
            "Parakeet prepare begin — startedAt=\(Self.timestamp(prepareStartedAt), privacy: .public) modelsOnDisk=\(modelsOnDisk, privacy: .public) directory=\(directory.path, privacy: .public)"
        )
        do {
            try FileManager.default.createDirectory(
                at: directory.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            let summary = "Could not create model cache: \(error.localizedDescription)"
            modelState = .failed(summary)
            prepareTask = nil
            let prepareEndedAt = Date()
            let prepareElapsedMS = Self.elapsedMilliseconds(from: prepareStartedAt, to: prepareEndedAt)
            signposter.endInterval("parakeet-prepare", prepareInterval)
            log.error(
                "Parakeet prepare failed — startedAt=\(Self.timestamp(prepareStartedAt), privacy: .public) endedAt=\(Self.timestamp(prepareEndedAt), privacy: .public) elapsedMS=\(prepareElapsedMS, privacy: .public) downloadedThisCall=false error=\(summary, privacy: .public)"
            )
            throw TranscriptionError.loadFailed(summary)
        }

        var downloadedThisCall = false
        if !modelsOnDisk {
            modelState = .downloading(0)
            downloadedThisCall = true
            let progress: DownloadUtils.ProgressHandler = { [weak self, generation] snapshot in
                let fraction = max(0.0, min(1.0, snapshot.fractionCompleted))
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // Generation guard: a stale callback from a prior
                    // variant's download must NOT update the new
                    // variant's progress fraction after a rapid flip.
                    guard self.prepareGeneration == generation else { return }
                    if case .downloading = self.modelState {
                        self.modelState = .downloading(fraction)
                    }
                }
            }
            let downloadStartedAt = Date()
            let downloadInterval = signposter.beginInterval("parakeet-download")
            log.info(
                "Parakeet download begin — startedAt=\(Self.timestamp(downloadStartedAt), privacy: .public) directory=\(directory.path, privacy: .public)"
            )
            do {
                _ = try await AsrModels.download(
                    to: directory,
                    force: false,
                    version: version,
                    progressHandler: progress
                )
                try checkPrepareGeneration(generation)
                let downloadEndedAt = Date()
                let downloadElapsedMS = Self.elapsedMilliseconds(from: downloadStartedAt, to: downloadEndedAt)
                signposter.endInterval("parakeet-download", downloadInterval)
                log.info(
                    "Parakeet download end — startedAt=\(Self.timestamp(downloadStartedAt), privacy: .public) endedAt=\(Self.timestamp(downloadEndedAt), privacy: .public) elapsedMS=\(downloadElapsedMS, privacy: .public) directory=\(directory.path, privacy: .public)"
                )
            } catch is CancellationError {
                let downloadEndedAt = Date()
                let downloadElapsedMS = Self.elapsedMilliseconds(from: downloadStartedAt, to: downloadEndedAt)
                signposter.endInterval("parakeet-download", downloadInterval)
                if prepareGeneration == generation {
                    prepareTask = nil
                }
                if prepareGeneration == generation, manager == nil {
                    modelState = .notLoaded
                }
                log.notice(
                    "Parakeet download cancelled — startedAt=\(Self.timestamp(downloadStartedAt), privacy: .public) endedAt=\(Self.timestamp(downloadEndedAt), privacy: .public) elapsedMS=\(downloadElapsedMS, privacy: .public)"
                )
                throw CancellationError()
            } catch {
                let downloadEndedAt = Date()
                let downloadElapsedMS = Self.elapsedMilliseconds(from: downloadStartedAt, to: downloadEndedAt)
                signposter.endInterval("parakeet-download", downloadInterval)
                guard prepareGeneration == generation, !Task.isCancelled else {
                    if prepareGeneration == generation {
                        prepareTask = nil
                    }
                    if prepareGeneration == generation, manager == nil {
                        modelState = .notLoaded
                    }
                    log.notice(
                        "Parakeet download cancelled after error — startedAt=\(Self.timestamp(downloadStartedAt), privacy: .public) endedAt=\(Self.timestamp(downloadEndedAt), privacy: .public) elapsedMS=\(downloadElapsedMS, privacy: .public)"
                    )
                    throw CancellationError()
                }
                let summary = "Download failed: \(error.localizedDescription)"
                try? FileManager.default.removeItem(at: directory)
                modelState = .failed(summary)
                prepareTask = nil
                log.error(
                    "Parakeet download failed — startedAt=\(Self.timestamp(downloadStartedAt), privacy: .public) endedAt=\(Self.timestamp(downloadEndedAt), privacy: .public) elapsedMS=\(downloadElapsedMS, privacy: .public) error=\(summary, privacy: .public)"
                )
                throw TranscriptionError.loadFailed(summary)
            }
        }

        modelState = .loading
        let loadStartedAt = Date()
        let loadInterval = signposter.beginInterval("parakeet-load")
        let loadSource = downloadedThisCall ? "download-then-load" : "load-from-disk"
        log.info(
            "Parakeet load begin — startedAt=\(Self.timestamp(loadStartedAt), privacy: .public) source=\(loadSource, privacy: .public) directory=\(directory.path, privacy: .public)"
        )
        do {
            let models = try await AsrModels.load(from: directory, version: version)
            try checkPrepareGeneration(generation)
            let manager = AsrManager()
            try await manager.loadModels(models)
            try checkPrepareGeneration(generation)
            self.manager = manager
            modelState = .ready
            let loadEndedAt = Date()
            // Calibrate the "Loading …" bar's pacing for this device + variant.
            // First load of the process lifetime routes to the cold bucket
            // (post-update ANE recompile), later loads to warm — so a warm
            // process-restart paces against its real ~seconds duration rather
            // than the generous cold default. (Mirrors the EOU path, which
            // already records; the batch path previously did not.)
            ModelLoadTimekeeper.record(
                variant: AppGroup.speechModelVariant,
                seconds: loadEndedAt.timeIntervalSince(loadStartedAt)
            )
            // The model has now loaded at least once on this install, so any
            // FUTURE cold load uses the recurring (not first-ever) copy.
            ColdStartCopy.markLoadedOnce()
            let loadElapsedMS = Self.elapsedMilliseconds(from: loadStartedAt, to: loadEndedAt)
            // Copyable diagnostic: WHICH directory the model loaded from + how long.
            let loadSourceLabel: String = {
                if directory.path.hasPrefix(Bundle.main.bundleURL.path) { return "bundle" }
                return "download"
            }()
            DiagnosticsLog.record(
                source: "main-app",
                category: .modelLoad,
                message: "model loaded",
                metadata: [
                    "from": loadSourceLabel,
                    "loadMS": "\(loadElapsedMS)",
                    "downloadedThisCall": "\(downloadedThisCall)",
                ]
            )
            let prepareEndedAt = Date()
            let prepareElapsedMS = Self.elapsedMilliseconds(from: prepareStartedAt, to: prepareEndedAt)
            signposter.endInterval("parakeet-load", loadInterval)
            signposter.endInterval("parakeet-prepare", prepareInterval)
            log.info(
                "Parakeet load end — startedAt=\(Self.timestamp(loadStartedAt), privacy: .public) endedAt=\(Self.timestamp(loadEndedAt), privacy: .public) elapsedMS=\(loadElapsedMS, privacy: .public) source=\(loadSource, privacy: .public)"
            )
            log.info(
                "Parakeet prepare end — startedAt=\(Self.timestamp(prepareStartedAt), privacy: .public) endedAt=\(Self.timestamp(prepareEndedAt), privacy: .public) elapsedMS=\(prepareElapsedMS, privacy: .public) downloadedThisCall=\(downloadedThisCall, privacy: .public)"
            )
        } catch is CancellationError {
            if prepareGeneration == generation {
                prepareTask = nil
            }
            if prepareGeneration == generation, manager == nil {
                modelState = .notLoaded
            }
            let loadEndedAt = Date()
            let loadElapsedMS = Self.elapsedMilliseconds(from: loadStartedAt, to: loadEndedAt)
            let prepareEndedAt = Date()
            let prepareElapsedMS = Self.elapsedMilliseconds(from: prepareStartedAt, to: prepareEndedAt)
            signposter.endInterval("parakeet-load", loadInterval)
            signposter.endInterval("parakeet-prepare", prepareInterval)
            log.notice(
                "Parakeet load cancelled — startedAt=\(Self.timestamp(loadStartedAt), privacy: .public) endedAt=\(Self.timestamp(loadEndedAt), privacy: .public) elapsedMS=\(loadElapsedMS, privacy: .public) source=\(loadSource, privacy: .public)"
            )
            log.notice(
                "Parakeet prepare cancelled — startedAt=\(Self.timestamp(prepareStartedAt), privacy: .public) endedAt=\(Self.timestamp(prepareEndedAt), privacy: .public) elapsedMS=\(prepareElapsedMS, privacy: .public) downloadedThisCall=\(downloadedThisCall, privacy: .public)"
            )
            throw CancellationError()
        } catch {
            let summary = "Load failed: \(error.localizedDescription)"
            let loadEndedAt = Date()
            let loadElapsedMS = Self.elapsedMilliseconds(from: loadStartedAt, to: loadEndedAt)
            let prepareEndedAt = Date()
            let prepareElapsedMS = Self.elapsedMilliseconds(from: prepareStartedAt, to: prepareEndedAt)
            signposter.endInterval("parakeet-load", loadInterval)
            signposter.endInterval("parakeet-prepare", prepareInterval)
            guard prepareGeneration == generation, !Task.isCancelled else {
                if prepareGeneration == generation {
                    prepareTask = nil
                }
                if prepareGeneration == generation, manager == nil {
                    modelState = .notLoaded
                }
                log.notice(
                    "Parakeet load cancelled after error — startedAt=\(Self.timestamp(loadStartedAt), privacy: .public) endedAt=\(Self.timestamp(loadEndedAt), privacy: .public) elapsedMS=\(loadElapsedMS, privacy: .public) source=\(loadSource, privacy: .public)"
                )
                log.notice(
                    "Parakeet prepare cancelled after error — startedAt=\(Self.timestamp(prepareStartedAt), privacy: .public) endedAt=\(Self.timestamp(prepareEndedAt), privacy: .public) elapsedMS=\(prepareElapsedMS, privacy: .public) downloadedThisCall=\(downloadedThisCall, privacy: .public)"
                )
                throw CancellationError()
            }
            modelState = .failed(summary)
            prepareTask = nil
            log.error(
                "Parakeet load failed — startedAt=\(Self.timestamp(loadStartedAt), privacy: .public) endedAt=\(Self.timestamp(loadEndedAt), privacy: .public) elapsedMS=\(loadElapsedMS, privacy: .public) source=\(loadSource, privacy: .public) error=\(summary, privacy: .public)"
            )
            log.error(
                "Parakeet prepare failed — startedAt=\(Self.timestamp(prepareStartedAt), privacy: .public) endedAt=\(Self.timestamp(prepareEndedAt), privacy: .public) elapsedMS=\(prepareElapsedMS, privacy: .public) downloadedThisCall=\(downloadedThisCall, privacy: .public)"
            )
            throw TranscriptionError.loadFailed(summary)
        }
    }

    /// Resolve the bundled model directory for FluidAudio's
    /// `AsrModels.load(from:)`.
    ///
    /// Resolve the model directory for FluidAudio's `AsrModels.load(from:)`,
    /// branching on device capability:
    ///
    /// - **Capable devices** (`DeviceCapability.is600MCapable`) run the
    ///   bundled Parakeet 0.6B v2, vendored at
    ///   `Resources/Models/Parakeet/parakeet-tdt-0.6b-v2/` inside the app bundle.
    ///   First dictation is instant + offline, no download. Loaded straight from
    ///   the app bundle.
    /// - **Sub-6GB devices** run the smaller 110M, which is NOT bundled —
    ///   `MLModelConfigurationUtils.defaultModelsDirectory(for: .parakeetTdtCtc110m)`
    ///   points at FluidAudio's default Application Support cache (already a
    ///   stable, update-proof path), where `AsrModels.download` lands the weights
    ///   on first need.
    private static func modelDirectory() -> URL {
        // Only English on a capable device runs the bundled 600M (v2) straight
        // from the read-only app bundle. A European language resolves to v3,
        // which is NOT bundled — it downloads into FluidAudio's default
        // App-Support cache for `.parakeetV3` (via `selectedRepo`), exactly like
        // the sub-6GB 110M path.
        if LanguageChoice.current.isEnglish, DeviceCapability.is600MCapable {
            if let bundled = bundled600mDirectory() {
                return bundled
            }
        }
        return MLModelConfigurationUtils.defaultModelsDirectory(for: selectedRepo)
    }

    /// `<Bundle>/Models/Parakeet/parakeet-tdt-0.6b-v2/` if present, else nil.
    /// Resolved by composing `Bundle.main.bundleURL` directly against the
    /// `Models` folder reference declared in `project.yml`. We don't use
    /// `Bundle.main.url(forResource:withExtension:subdirectory:)` because that
    /// API doesn't reliably surface subpaths inside a folder reference — the
    /// `.mlmodelc` packages live under `parakeet-tdt-0.6b-v2`, but that
    /// directory itself is just a regular directory (not a typed resource), and
    /// the extension-resolution machinery doesn't always index intermediate
    /// directory names from folder references.
    ///
    /// The folder name MUST be `parakeet-tdt-0.6b-v2` (NO `-coreml`). This is
    /// load-bearing and was the root cause of build 142's "Download failed:
    /// permission denied in folder Parakeet" crash: FluidAudio's
    /// `Repo.parakeetV2.folderName` falls through the `folderName` switch's
    /// `default` (`name.replacingOccurrences(of: "-coreml", with: "")`) → it is
    /// `parakeet-tdt-0.6b-v2`, NOT the HF repo-id `parakeet-tdt-0.6b-v2-coreml`
    /// (ModelNames.swift). `AsrModels.modelsExist(at:)`/`download(to:)` resolve
    /// `repoPath(from: dir) = dir.deletingLastPathComponent() + folderName`, so
    /// the bundled leaf's last component must EQUAL `folderName` or `modelsExist`
    /// looks one dir over (`.../Parakeet/parakeet-tdt-0.6b-v2`), finds nothing,
    /// and tries to download into the read-only bundle. Keep this in sync with
    /// the vendored dir name under `Resources/Models/Parakeet/`.
    nonisolated static func bundled600mDirectory() -> URL? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("Parakeet", isDirectory: true)
            .appendingPathComponent("parakeet-tdt-0.6b-v2", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Whether the active dictation model's weights are available on disk.
    /// Used by the eager warm-up gate (`warmIfNeeded()` / `JotApp.task`) and
    /// any "models available" UI gate.
    ///
    /// - **Capable devices**: the 600M ships in the IPA, so this is `true` on
    ///   any healthy install (the `.mlmodelc` resources can't be evicted
    ///   without re-installing the app). Gating warm-up on this preserves the
    ///   no-silent-download guarantee trivially (always true → always warms).
    /// - **Sub-6GB devices**: the 110M is download-on-first-need, so this is
    ///   `false` until the first dictation has fetched it. That's intended —
    ///   it keeps `warmIfNeeded()` from silently downloading at launch (App
    ///   Review 4.2.3(ii)); the download is triggered by the user's first
    ///   dictation tap instead, where `.downloading` progress is surfaced.
    static func modelsExistOnDiskForSelectedVariant() -> Bool {
        AsrModels.modelsExist(at: modelDirectory(), version: selectedVersion)
    }

    /// The App-Support directory of the currently-ACTIVE downloaded dictation
    /// model, or `nil` when the active model is the bundled 600M (nothing is
    /// downloaded). This is the guard hook for an orphaned-download cleanup
    /// sweep: any such sweep that deletes unused App-Support model dirs MUST
    /// exclude this path, otherwise it would delete the 110M out from under a
    /// low-RAM device that depends on it. The sweep itself is NOT implemented
    /// here (see `docs/plans/single-model-600m-rip-eou.md`); this accessor
    /// exists so a future sweep has a single source of truth for "the dir in
    /// use." Returns `nil` on capable devices (no orphan risk — they download
    /// nothing).
    static func activeDownloadedModelDirectory() -> URL? {
        DeviceCapability.is600MCapable ? nil : modelDirectory()
    }

    /// Sweep stale `<modelDir>.purging-*` siblings left behind by interrupted
    /// purges (crash/jetsam/kill mid-`deletePurgedModelDirectory`). Best-effort,
    /// detached. Called once at app launch and again at the start of every
    /// `purgeAndReload()`. Each orphan can be ~1.25 GB so this is real disk.
    @discardableResult
    static func sweepOrphanedPurgingDirs() -> Int {
        let log = Logger(subsystem: "com.vineetu.jot.mobile.Jot", category: "transcription")
        let modelDir = Self.modelDirectory()
        let parent = modelDir.deletingLastPathComponent()
        let prefix = modelDir.lastPathComponent + ".purging-"
        let fm = FileManager.default
        guard fm.fileExists(atPath: parent.path),
              let entries = try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil) else {
            return 0
        }
        var count = 0
        for url in entries where url.lastPathComponent.hasPrefix(prefix) {
            count += 1
            let target = url
            Task.detached(priority: .utility) { @Sendable in
                let log = Logger(subsystem: "com.vineetu.jot.mobile.Jot", category: "transcription")
                do {
                    try FileManager.default.removeItem(at: target)
                    log.info("Swept orphaned purging dir at \(target.path, privacy: .public)")
                } catch {
                    log.error("Could not sweep purging dir — directory=\(target.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                }
            }
        }
        if count > 0 {
            log.notice("Found \(count, privacy: .public) orphaned .purging-* dir(s) under \(parent.path, privacy: .public); deletion dispatched")
        }
        return count
    }

    /// One-shot migration: reclaim Application Support disk for upgrading
    /// users from pre-bundle TestFlight builds (0.9.0 / 0.9.1) whose 110M
    /// weights were downloaded into `~/Library/Application Support/FluidAudio/Models/`.
    /// Now that the TDT-CTC 110M, EOU streaming, and CTC aux models all
    /// ship bundled inside the IPA, those Application Support copies are
    /// ~530 MB of dead weight that the per-variant `sweepOrphanedPurgingDirs`
    /// can't reach (its `parent` resolves to the read-only bundle path).
    ///
    /// Scope:
    /// - Removes the three legacy 110M-era directories AND any `.purging-*`
    ///   siblings of them
    /// - Does NOT touch `parakeet-tdt-0.6b-v2-coreml/` — that is the
    ///   active Parakeet 600M variant's cache; users who already
    ///   downloaded it should keep those weights so the variant is ready
    ///   immediately without re-downloading
    /// - Gated by `jot.didMigrateLegacyParakeetWeights` so it runs at most
    ///   once across the app's lifetime
    /// - Best-effort: log errors, never throw
    static func sweepLegacyAppSupportWeights() {
        let migrationKey = "jot.didMigrateLegacyParakeetWeights"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migrationKey) else { return }

        let log = Logger(subsystem: "com.vineetu.jot.mobile.Jot", category: "transcription")
        // The legacy default location used by FluidAudio before we moved
        // these models into the bundle. Resolves to
        // `~/Library/Application Support/FluidAudio/Models/`.
        let appSupportRoot = MLModelConfigurationUtils
            .defaultModelsDirectory(for: .parakeetTdtCtc110m)
            .deletingLastPathComponent()

        // Folder names match Repo.folderName for the corresponding repos:
        //   .parakeetTdtCtc110m → "parakeet-tdt-ctc-110m"
        //   .parakeetCtc110m    → "parakeet-ctc-110m-coreml"
        //   .parakeetEou320     → "parakeet-eou-streaming/320ms" (the
        //                         top-level `parakeet-eou-streaming` dir
        //                         catches every ms variant in one shot)
        // The Parakeet 600M (v2) cache is `parakeet-tdt-0.6b-v2-coreml` —
        // NOT in this allowlist; the variant is selectable in Settings
        // again and any cached weights should stay so the user doesn't
        // pay a fresh download to switch back.
        let legacyNames: Set<String> = [
            "parakeet-tdt-ctc-110m",
            "parakeet-ctc-110m-coreml",
            "parakeet-eou-streaming",
        ]

        let fm = FileManager.default
        guard fm.fileExists(atPath: appSupportRoot.path),
              let entries = try? fm.contentsOfDirectory(at: appSupportRoot, includingPropertiesForKeys: nil) else {
            // Nothing on disk — still flip the flag so we don't repeatedly
            // poll the filesystem on every cold launch.
            defaults.set(true, forKey: migrationKey)
            log.info("Legacy Parakeet weights migration: nothing on disk at \(appSupportRoot.path, privacy: .public); flag set")
            return
        }

        // Enumerate synchronously so the decision of WHAT to delete is made
        // on the calling thread (cheap directory listing), then dispatch the
        // actual `removeItem` loop to a detached utility task. On upgrading
        // TestFlight users there can be ~530 MB of weights to unlink and
        // doing it sync on `JotApp.init()` adds 1–3 s of cold-launch lag.
        var toRemove: [URL] = []
        for url in entries {
            let name = url.lastPathComponent
            // Drop exact-match legacy dirs and any `.purging-*` siblings of them.
            let isLegacyExact = legacyNames.contains(name)
            let isLegacyPurging = legacyNames.contains { legacy in
                name.hasPrefix(legacy + ".purging-")
            }
            guard isLegacyExact || isLegacyPurging else { continue }
            toRemove.append(url)
        }

        // Flip the gate flag synchronously BEFORE dispatching the delete.
        // If the detached task is still running on next cold launch, this
        // guard short-circuits and we never re-attempt the deletion.
        defaults.set(true, forKey: migrationKey)

        guard !toRemove.isEmpty else {
            log.info("Legacy Parakeet weights migration: no matching legacy dirs under \(appSupportRoot.path, privacy: .public); flag set")
            return
        }

        let parentPath = appSupportRoot.path
        let targets = toRemove
        Task.detached(priority: .utility) { @Sendable in
            let log = Logger(subsystem: "com.vineetu.jot.mobile.Jot", category: "transcription")
            let fm = FileManager.default
            var removedCount = 0
            for url in targets {
                do {
                    try fm.removeItem(at: url)
                    removedCount += 1
                    log.notice("Migration removed legacy Parakeet weight dir at \(url.path, privacy: .public)")
                } catch {
                    log.error(
                        "Migration could not remove legacy dir — directory=\(url.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            log.notice("Legacy Parakeet weights migration complete — removed=\(removedCount, privacy: .public) parent=\(parentPath, privacy: .public)")
        }
    }

    /// One-shot migration: reclaim Application Support disk for users who
    /// downloaded Nemotron weights during 1.0.2 (22–26). Nemotron 0.6B was
    /// on-device-tested and ripped because RTF on iPhone was 3–5x slower
    /// than real-time, producing 10–15s tails after stop. The weights
    /// (~564 MB encoder + smaller decoder/joint/preprocessor; ~600 MB for
    /// 560ms variant, plus another ~600 MB if the user also tried the
    /// 1120ms variant) sit under
    /// `Library/Application Support/FluidAudio/Models/nemotron-streaming/`.
    ///
    /// Gated by `jot.didCleanupNemotronWeights` so it runs at most once.
    /// Best-effort + detached so a 1+ GB removeItem doesn't stretch cold
    /// launch.
    static func sweepNemotronAppSupportWeights() {
        let migrationKey = "jot.didCleanupNemotronWeights"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migrationKey) else { return }

        let log = Logger(subsystem: "com.vineetu.jot.mobile.Jot", category: "transcription")
        let nemotronRoot = MLModelConfigurationUtils
            .defaultModelsDirectory(for: .parakeetTdtCtc110m)
            .deletingLastPathComponent()
            .appendingPathComponent("nemotron-streaming", isDirectory: true)

        defaults.set(true, forKey: migrationKey)

        guard FileManager.default.fileExists(atPath: nemotronRoot.path) else {
            log.info("Nemotron cleanup: nothing at \(nemotronRoot.path, privacy: .public); flag set")
            return
        }

        let target = nemotronRoot
        Task.detached(priority: .utility) { @Sendable in
            let log = Logger(subsystem: "com.vineetu.jot.mobile.Jot", category: "transcription")
            do {
                try FileManager.default.removeItem(at: target)
                log.notice("Nemotron cleanup: removed \(target.path, privacy: .public)")
            } catch {
                log.error("Nemotron cleanup: \(error.localizedDescription, privacy: .public) target=\(target.path, privacy: .public)")
            }
        }
    }

    private static func purgingModelDirectory(for modelDir: URL) -> URL {
        modelDir
            .deletingLastPathComponent()
            .appendingPathComponent(
                "\(modelDir.lastPathComponent).purging-\(UUID().uuidString)",
                isDirectory: true
            )
    }

    private static func deletePurgedModelDirectory(_ directory: URL) {
        Task.detached(priority: .utility) {
            let log = Logger(subsystem: "com.vineetu.jot.mobile.Jot", category: "transcription")
            do {
                if FileManager.default.fileExists(atPath: directory.path) {
                    try FileManager.default.removeItem(at: directory)
                    log.notice("Deleted purged Parakeet model cache at \(directory.path, privacy: .public)")
                }
            } catch {
                log.error(
                    "Could not delete purged Parakeet model cache — directory=\(directory.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func checkPrepareGeneration(_ generation: Int) throws {
        guard prepareGeneration == generation, !Task.isCancelled else {
            throw CancellationError()
        }
    }

    // MARK: - Audio file decode + resample
    //
    // Runs synchronously on whatever context calls `transcribe(audioFileURL:)`.
    // Shortcut recordings are short (~30–60 s); decoding + 16 kHz resample is
    // well under 100 ms on recent silicon — cheaper than dispatching a detached
    // task and cheaper than the model inference itself. Kept static + pure so
    // it's trivially testable and has no implicit MainActor dependency.

    private static func loadAndResample(
        url: URL,
        targetSampleRate: Double,
        log: Logger
    ) throws -> [Float] {
        log.info("loadAndResample — opening AVAudioFile at \(url.lastPathComponent, privacy: .public)")
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            let ext = url.pathExtension.isEmpty ? "(none)" : url.pathExtension
            let summary = "AVAudioFile(forReading:) failed for '\(url.lastPathComponent)' [.\(ext)]: \(error.localizedDescription)"
            log.error("loadAndResample — \(summary, privacy: .public)")
            throw TranscriptionError.audioFileUnreadable(summary)
        }

        // `processingFormat` is always Float32, deinterleaved — the canonical
        // shape `AVAudioConverter` is designed to bridge to our 16 kHz mono
        // target. Source channel count can be anything; the converter handles
        // mixdown.
        let sourceFormat = file.processingFormat
        log.info(
            "loadAndResample — source format: \(Int(sourceFormat.sampleRate), privacy: .public)Hz / \(sourceFormat.channelCount, privacy: .public)ch / \(String(describing: sourceFormat.commonFormat), privacy: .public), fileLength=\(file.length, privacy: .public) frames"
        )

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            let summary = "Could not construct 16 kHz mono Float32 target format."
            log.error("loadAndResample — \(summary, privacy: .public)")
            throw TranscriptionError.audioFileConversionFailed(summary)
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            let summary = "No converter available for source \(Int(sourceFormat.sampleRate))Hz/\(sourceFormat.channelCount)ch → 16kHz/1ch."
            log.error("loadAndResample — \(summary, privacy: .public)")
            throw TranscriptionError.audioFileConversionFailed(summary)
        }

        let totalFrames = file.length
        let readCapacity: AVAudioFrameCount = 8192
        let ratio = targetSampleRate / sourceFormat.sampleRate
        let estimatedOutCount = Int(Double(totalFrames) * ratio) + 1024

        var accumulated: [Float] = []
        accumulated.reserveCapacity(estimatedOutCount)

        while file.framePosition < totalFrames {
            let remaining = totalFrames - file.framePosition
            let thisRead = AVAudioFrameCount(min(Int64(readCapacity), remaining))

            guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: thisRead) else {
                throw TranscriptionError.audioFileConversionFailed("Could not allocate input buffer.")
            }

            do {
                try file.read(into: inputBuffer, frameCount: thisRead)
            } catch {
                throw TranscriptionError.audioFileConversionFailed("Read error: \(error.localizedDescription)")
            }

            let outCapacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio + 1024)
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else {
                throw TranscriptionError.audioFileConversionFailed("Could not allocate output buffer.")
            }

            // One-shot input: feed `inputBuffer` on the first input-block call,
            // signal `.noDataNow` on the second so the converter drains its
            // internal ring. The input block is `@Sendable` — capturing a
            // mutable `var` or an `UnsafeMutablePointer<Bool>` both fail the
            // Swift 6 strict-concurrency Sendable check (the latter per
            // SE-0414: pointer values are deliberately non-Sendable so the
            // checker isn't trivially defeated). We use a reference-type
            // `@unchecked Sendable` latch guarded by an `NSLock` — same
            // pattern as `TapOnceGate` in `RecordingService.swift`. The lock
            // is defense-in-depth; in practice `convert` invokes the block
            // synchronously on this thread so there is no real contention.
            let gate = OneShotInputGate()
            var err: NSError?
            let status = converter.convert(to: outputBuffer, error: &err) { _, inputStatus in
                if gate.fireOnce() {
                    inputStatus.pointee = .haveData
                    return inputBuffer
                }
                inputStatus.pointee = .noDataNow
                return nil
            }

            switch status {
            case .error:
                throw TranscriptionError.audioFileConversionFailed(err?.localizedDescription ?? "unknown converter error")
            case .haveData, .inputRanDry, .endOfStream:
                break
            @unknown default:
                break
            }

            guard let channelData = outputBuffer.floatChannelData else { continue }
            let frames = Int(outputBuffer.frameLength)
            guard frames > 0 else { continue }
            accumulated.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: frames))
        }

        log.info(
            "Decoded audio file — \(accumulated.count, privacy: .public) samples at \(Int(targetSampleRate))Hz from \(Int(sourceFormat.sampleRate))Hz/\(sourceFormat.channelCount)ch"
        )
        return accumulated
    }

    // MARK: - Memory pressure (best-practices §3.5)

    private func subscribeMemoryWarnings() {
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleMemoryWarning()
            }
        }
    }

    /// Proactively drop the Parakeet manager. Used by the foreground
    /// classifier ("Classify now" in the Lab dashboard) before it kicks
    /// off Qwen — co-resident Parakeet + Qwen peak around 5 GB and
    /// trip iOS jetsam. Honors the same `!isTranscribing` guard as
    /// `handleMemoryWarning` so we never evict during an active dictation.
    ///
    /// Re-warms automatically on the next `transcribe()` / `warmUp()`.
    func evictForExternalRequest(reason: String) {
        guard !isTranscribing else {
            log.notice("evictForExternalRequest: deferring — transcription in flight (reason=\(reason, privacy: .public))")
            return
        }
        guard manager != nil else {
            log.debug("evictForExternalRequest: nothing to evict (reason=\(reason, privacy: .public))")
            return
        }
        log.notice("evictForExternalRequest: dropping batch transcriber (reason=\(reason, privacy: .public))")
        manager = nil
        prepareTask = nil
        modelState = .notLoaded
    }

    private func handleMemoryWarning() {
        // Surface the memory-pressure event in the in-app diagnostics card
        // — mirrors the symmetric write in `StreamingTranscriptionService`
        // so a user reporting "Jot died right after I stopped" can see
        // the jetSam-precursor warning in Help → Diagnostics. Logged
        // unconditionally (before the early-return guards below) so a
        // mid-inference warning is still visible even if we skip
        // eviction.
        DiagnosticsLog.record(
            source: "main-app",
            category: .memoryWarning,
            message: "batch service received memory warning",
            metadata: [
                "variant": "\(SpeechModelVariant.current().rawValue)",
                "isTranscribing": "\(isTranscribing)",
                "hasParakeetManager": "\(manager != nil)",
            ]
        )
        guard !isTranscribing else {
            log.notice("Memory warning received mid-inference — deferring model eviction")
            return
        }
        guard manager != nil else { return }
        log.notice("Memory warning — evicting batch transcriber to avoid jetsam")
        manager = nil
        // Dropping the actor reference is sufficient — ARC will reclaim
        // the CoreML graphs. We don't await `cleanup()` here because the
        // memory-warning hook runs synchronously on MainActor and the
        // actor's internal cleanup is best-effort under jetsam pressure.
        prepareTask = nil
        modelState = .notLoaded
    }

    // MARK: - Sample-rate constant
    //
    // 16 kHz mirrors `RecordingService.sampleRate`. Kept as a separate constant
    // so this file doesn't reach across the layer boundary for a trivial literal.

    private static let sampleRate: Double = 16_000

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func timestamp(_ date: Date) -> String {
        timestampFormatter.string(from: date)
    }

    private static func elapsedMilliseconds(from start: Date, to end: Date) -> Double {
        end.timeIntervalSince(start) * 1_000
    }

    private static func audioDurationSeconds(sampleCount: Int) -> Double {
        Double(sampleCount) / sampleRate
    }

    private static func realTimeFactor(elapsedMS: Double, audioDurationSeconds: Double) -> Double {
        guard audioDurationSeconds > 0 else { return 0 }
        return (elapsedMS / 1_000) / audioDurationSeconds
    }

    private static func describe(_ state: ModelState) -> String {
        switch state {
        case .notLoaded:
            return "notLoaded"
        case .downloading(let progress):
            return "downloading(\(progress))"
        case .loading:
            return "loading"
        case .ready:
            return "ready"
        case .failed(let summary):
            return "failed(\(summary))"
        }
    }
}

// MARK: - Error bridging for Shortcuts / NSError consumers
//
// Shortcuts reports thrown intent errors by rendering the bridged NSError.
// Without explicit conformances, iOS displays a useless string like
// "Jot.TranscriptionService.TranscriptionError error 2" — the typed case
// information is lost.
//
// `CustomNSError` locks the error domain + numeric codes so external tooling
// (unified log predicates, screenshots, user-reported bug IDs) has a stable
// contract. Codes match Swift's default enum-ordinal bridging at the time of
// writing so historical "error N" reports stay interpretable.
//
// `CustomLocalizedStringResourceConvertible` is the AppIntents-era hook: when
// an intent throws, Shortcuts reads this resource instead of the bridged
// localizedDescription. `LocalizedError.errorDescription` also stays
// implemented as a fallback for non-AppIntents callers (e.g., main-app UI
// alerts surfacing a transcription failure).

extension TranscriptionService.TranscriptionError: CustomNSError {
    /// Public error domain. Treat as API — logs / screenshots / bug reports
    /// reference it. Renames require migration.
    public static var errorDomain: String { "Jot.TranscriptionService.TranscriptionError" }

    /// Stable numeric codes. Table is the public contract; do NOT renumber.
    /// - 0: `busy`
    /// - 1: `audioTooShort`
    /// - 2: `loadFailed`
    /// - 3: `inferenceFailed`
    /// - 4: `audioFileUnreadable`
    /// - 5: `audioFileConversionFailed`
    public var errorCode: Int {
        switch self {
        case .busy: return 0
        case .audioTooShort: return 1
        case .loadFailed: return 2
        case .inferenceFailed: return 3
        case .audioFileUnreadable: return 4
        case .audioFileConversionFailed: return 5
        }
    }

    public var errorUserInfo: [String: Any] {
        [NSLocalizedDescriptionKey: errorDescription ?? "Transcription error."]
    }
}

extension TranscriptionService.TranscriptionError: CustomLocalizedStringResourceConvertible {
    /// Rendered by Shortcuts / AppIntents surfaces when an intent's
    /// `perform()` throws. Keep strings user-facing and actionable — the
    /// recipient is someone looking at an opaque Shortcut failure banner.
    public var localizedStringResource: LocalizedStringResource {
        switch self {
        case .busy:
            return "Jot is already transcribing. Wait for the current transcription to finish, then try again."
        case .audioTooShort:
            return "Recording is under one second. Parakeet needs at least 1 second of audio."
        case .loadFailed(let summary):
            return "Model not ready: \(summary)"
        case .inferenceFailed(let summary):
            return "Transcription failed: \(summary)"
        case .audioFileUnreadable(let summary):
            return "Could not read the audio file: \(summary)"
        case .audioFileConversionFailed(let summary):
            return "Could not decode the audio to 16 kHz mono: \(summary)"
        }
    }
}

/// Single-fire gate for `AVAudioConverter.convert`'s `@Sendable` input
/// block. Returns `true` on the first call, `false` on every subsequent
/// call — lets us hand the converter one buffer per `convert` invocation
/// without capturing a mutable `var` or a non-`Sendable` pointer (both of
/// which fail Swift 6 strict-concurrency Sendable checks).
///
/// `@unchecked Sendable` with `NSLock`: mirrors `TapOnceGate` in
/// `RecordingService.swift`. Kept file-private; hoisting to a shared
/// concurrency-helpers module is a follow-up cross-lane change.
private final class OneShotInputGate: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func fireOnce() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !fired else { return false }
        fired = true
        return true
    }
}

/// Run `operation`, returning its result, or `nil` if it does not finish
/// within `seconds`. On timeout the operation task is **cancelled** and the
/// `nil` is returned to the caller. This is the safety valve that bounds the
/// vocabulary CTC spot/rescore so it can never permanently wedge the
/// transcription publish or the MainActor model pipeline.
///
/// IMPORTANT semantics: this uses `withTaskGroup`, which awaits ALL of its
/// children at scope exit — so `cancelAll()` only *requests* cancellation; the
/// group still implicitly awaits the loser. Because CoreML inference does NOT
/// reliably observe Swift task cancellation, the loser keeps running until its
/// current `MLModel.prediction` returns, and this function does not actually
/// return until then. The LIVENESS guarantee (always returns) holds anyway
/// because each `prediction` is a single bounded call that always eventually
/// completes — there is no infinite-loop path. What `seconds` truly bounds is
/// the *number of additional chunks scheduled* after the deadline, not the
/// exact wall-clock; a publish can be delayed up to one in-flight prediction
/// beyond `seconds`. That is acceptable: the caller is never blocked forever.
private func withTimeout<T: Sendable>(
    seconds: Double,
    operation: @escaping @Sendable () async throws -> T
) async -> T? {
    await withTaskGroup(of: T?.self) { group -> T? in
        group.addTask {
            try? await operation()
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil
        }
        // First child to finish wins; cancel the rest and DO NOT await them.
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
