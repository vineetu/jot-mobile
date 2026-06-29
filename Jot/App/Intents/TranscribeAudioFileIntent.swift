import AppIntents
import Foundation
import UniformTypeIdentifiers

/// Shortcuts-driven entry point for *file-based* on-device transcription.
///
/// Designed to chain after Shortcuts' built-in *Record Audio* action (or any
/// other action that hands us an audio file): the upstream action records
/// the audio, we run Parakeet on it, and we return the transcript as a
/// string the next Shortcut step can consume. The whole flow stays inside
/// the Shortcuts runtime — **no app foregrounding**.
///
/// ## Relationship to `DictateIntent`
///
/// `DictateIntent` is the Action-Button-toggle flow: it foregrounds Jot so
/// `AVAudioEngine` can activate the mic, presents a Live Activity, and toggles
/// start/stop across two presses. It's preserved for users who bind the
/// Action Button directly.
///
/// `TranscribeAudioFileIntent` is the *composable* entry point: the user
/// chains it inside a Shortcut (Record Audio → this → Paste / Send Message /
/// Copy / etc.). We deliberately skip mic capture — the forum-documented
/// Shortcuts mic restriction¹ doesn't apply because our upstream action owns
/// the recording and hands us a decoded file.
///
/// ¹ Apple DevForums #756507: "You cannot trigger an audio recording from
///   the Shortcuts app. Your app needs to be in the foreground before the
///   user can start recording audio." (DTS Engineer, 2024) — referenced in
///   `DictateIntent.swift`.
///
/// ## Shape decisions — source of truth: `docs/research/shortcuts-transcribe-intent.md`
///
/// - **`openAppWhenRun = false`** is load-bearing. iOS headless-launches the
///   Jot process (runs `didFinishLaunchingWithOptions` without instantiating
///   any `UIWindowScene`) and executes `perform()` in-process. The user
///   never leaves the app they were in — see §3 of the research doc.
///
/// - **`@Parameter var audioFile: IntentFile`** — `IntentFile` is the
///   canonical AppIntents type for a file parameter. `supportedContentTypes:
///   [.audio]` restricts what Shortcuts will plumb into the parameter to
///   any AVAudioFile-decodable format (m4a / wav / caf / aiff). The built-in
///   *Record Audio* action emits m4a by default — covered.
///
/// - **No struct-level `@MainActor` annotation.** The research doc (§3
///   "Concurrency") is explicit: annotating the intent `@MainActor` has
///   historically produced un-bindable intents on the Action Button picker.
///   Our concurrency model is: `perform()` runs on an arbitrary queue, the
///   transcriber + cleanup service hop to `@MainActor` internally.
///
/// - **Plain `AppIntent`** (not `AudioRecordingIntent`, not
///   `ForegroundContinuableIntent`). The audio-marker protocols hurt
///   Action Button bindability (see `DictateIntent`'s doc comment).
///   `ForegroundContinuableIntent` is a future option if we run into the
///   ~30 s headless-intent budget on long audio (research doc §6 risk 2) —
///   we'll add it then, not now.
///
/// - **`cleanup` defaults to `false`.** A power-user who wants LLM cleanup
///   can toggle the parameter in the Shortcuts editor. Defaulting to
///   `false` keeps the zero-network invariant intact for privacy-conscious
///   users — they see no outbound traffic on the happy path unless they
///   opt in (research doc §6 risk 7).
///
/// - **Transcription API.** `parakeet-file-engineer` landed the file-based
///   entry point as an instance method on the existing `@MainActor`
///   `TranscriptionService`:
///   `func transcribe(audioFileURL url: URL) async throws -> String`.
///   (This is a simpler shape than the research doc's suggested
///   `ParakeetFileTranscriber.shared` — one class instead of two, and
///   the service already owns the lazy Parakeet manager.) We call it from
///   a `@MainActor` helper to respect the service's isolation.
struct TranscribeAudioFileIntent: AppIntent {
    static let title: LocalizedStringResource = "Transcribe Audio with Jot"

    static let description = IntentDescription(
        """
        Transcribe an audio file on-device using Parakeet. \
        Designed to chain after Shortcuts' built-in Record Audio action. \
        Fully local — nothing leaves your device.
        """,
        categoryName: "Dictation"
    )

    /// Load-bearing. See class doc.
    static let openAppWhenRun: Bool = false

    /// Belt-and-suspenders: advertise to every system surface (Shortcuts,
    /// Siri phrases, Action Button). Defaults to `true` upstream; we pin it
    /// so a future SDK default flip doesn't silently hide this intent.
    static let isDiscoverable: Bool = true

    @Parameter(
        title: "Audio File",
        description: "The audio to transcribe. Accepts outputs from Shortcuts' Record Audio action, or any audio file passed from a prior step.",
        supportedContentTypes: [.audio]
    )
    var audioFile: IntentFile

    @Parameter(
        title: "Clean Up Transcript",
        description: "Apply Apple Foundation Models cleanup (removes filler words, false starts) using your configured cleanup preferences.",
        default: false
    )
    var cleanup: Bool

    /// Rendered as the action's body cell in the Shortcuts editor. Without
    /// this, iOS 26.2's Shortcuts daemon can surface a generic "Something
    /// went wrong" error during the binding commit step — see the
    /// equivalent note in `DictateIntent`. The trailing closure places
    /// `$cleanup` in the Shortcuts editor's "Show More" fold, since it's a
    /// secondary opt-in.
    static var parameterSummary: some ParameterSummary {
        Summary("Transcribe \(\.$audioFile) with Jot") {
            \.$cleanup
        }
    }

    init() {}

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let audioURL = try materializeAudioToOwnedTempFile(from: audioFile)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let rawTranscript = try await runTranscription(fileURL: audioURL)

        let finalText: String
        if cleanup {
            finalText = await runCleanupTolerantly(on: rawTranscript)
        } else {
            finalText = rawTranscript
        }

        // Append to the transcript ledger so this path is history-visible
        // alongside `RecordAndTranscribeIntent` and `DictateIntent`. "No
        // code-path divergence" across the three transcription surfaces is
        // a shipped invariant per the full-v2 brief: a user who only ever
        // runs this intent from a Shortcut (e.g. Record Audio → Transcribe
        // with Jot → Send Message) must still see their transcripts in
        // the library when they open the app.
        //
        // Duration is passed as `nil`: `TranscriptStore.append`'s own
        // doc calls this case out — for file-transcription intents where
        // the upstream action owned the recording, "duration" isn't
        // meaningful to us (we'd have to crack the container with
        // `AVAudioFile` just to label a row). The ledger UI renders a
        // duration-less row cleanly.
        let rawForLedger = rawTranscript
        let cleanedForLedger = cleanup ? finalText : nil
        // `MainActor.run { ... }` infers its return type from the last
        // expression. `TranscriptStore.append` now returns `Transcript?`
        // (a non-`Sendable` `@Model` class) so the closure cannot return it
        // across the actor boundary. Explicitly swallow the result with
        // `_ =` so the closure's inferred type stays `Void`. We don't need
        // the returned `Transcript` here — ledger reflection is driven by
        // the main app's `@Query` re-firing after the insert.
        try await MainActor.run {
            _ = try TranscriptStore.append(
                raw: rawForLedger,
                cleaned: cleanedForLedger,
                duration: nil,
                source: "file",
                // Retain the imported audio (copied before this intent's `defer`
                // removes the temp file) so it can be re-transcribed.
                retainAudioFileURL: audioURL
            )
        }

        return .result(value: finalText)
    }

    // MARK: - Helpers

    /// Copy the intent-supplied audio bytes into a tmp file **inside our
    /// own sandbox**, and return the URL. Always materializes — we
    /// deliberately do NOT use `IntentFile.fileURL`'s fast-path.
    ///
    /// ## Why we can't use `file.fileURL`
    ///
    /// When Jot runs headless inside Shortcuts (`openAppWhenRun = false`),
    /// the chained `Record Audio` action executes in Shortcuts'
    /// `BackgroundShortcutRunner` — a *different* process with a
    /// *different* sandbox. `IntentFile.fileURL` points into that other
    /// sandbox. AVFoundation can't read across sandbox boundaries:
    /// `ExtAudioFileOpenURL` returns `-54`
    /// (`kAudioFileFilePermissionError`) and `AVAudioFile(forReading:)`
    /// surfaces that as `.audioFileUnreadable` — what our users saw as
    /// "TranscriptionError error 2" on device runs.
    ///
    /// `IntentFile.data` is the serialized bytes — accessing the property
    /// copies them into our process memory, no cross-sandbox read
    /// involved. Writing them to our own `temporaryDirectory` gives
    /// `AVAudioFile` a URL it can read from our sandbox.
    ///
    /// Alternative considered: `startAccessingSecurityScopedResource()`
    /// bracketing around `file.fileURL`. Rejected — the URL is a
    /// sandbox-boundary issue, not a scope issue, so scope bracketing
    /// wouldn't have helped. The data-copy path is the simpler and
    /// strictly more correct fix.
    ///
    /// Caller owns the returned URL and must delete it when done (via the
    /// `defer` block in `perform()`).
    private func materializeAudioToOwnedTempFile(from file: IntentFile) throws -> URL {
        let suffix = file.filename.isEmpty ? "audio.m4a" : file.filename
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-intent-\(UUID().uuidString)-\(suffix)")
        try file.data.write(to: tmp, options: .atomic)
        return tmp
    }

    /// File-based transcription, hopped to `@MainActor` to match
    /// `TranscriptionService`'s isolation.
    ///
    /// We route through `TranscriptionService.shared` (process-wide
    /// singleton) so that any prior `warmUp()` / record-button load from
    /// the main-app side of the process carries across to this call path.
    /// Without sharing, a warm main-app instance and a cold intent
    /// instance coexisted and the user paid the ~10 s Parakeet load twice
    /// — once when they first recorded in-app, again when their first
    /// Shortcut run fired. See `TranscriptionService.shared` for the full
    /// rationale.
    ///
    /// Headless-launch behavior is unchanged: if this is the first access
    /// in the process, `.shared` lazily constructs exactly as a fresh
    /// `TranscriptionService()` would have — no regression on cold
    /// Shortcut runs, and the `transcribe(audioFileURL:)` path internally
    /// awaits `ensurePreparing().value` before touching the model.
    @MainActor
    private func runTranscription(fileURL: URL) async throws -> String {
        return try await TranscriptionService.shared.transcribe(audioFileURL: fileURL)
    }

    /// Cleanup is best-effort: if Apple Intelligence isn't available
    /// (device unsupported, user disabled it, model still downloading), we
    /// surface the raw transcript rather than failing the whole Shortcut.
    /// That matches the main-app toggle semantics — cleanup is an
    /// enhancement, not a gate.
    ///
    /// Annotated `@MainActor` because `CleanupService` is main-actor-isolated.
    /// The non-isolated `perform()` auto-hops on the `await` call site; the
    /// struct itself stays un-annotated to avoid the Action Button binding
    /// regression documented in the struct-level doc comment.
    @MainActor
    private func runCleanupTolerantly(on transcript: String) async -> String {
        let settings = CleanupSettings.load()
        let service = CleanupService()
        do {
            return try await service.clean(
                transcript: transcript,
                instructions: settings.instructions
            )
        } catch {
            return transcript
        }
    }
}
