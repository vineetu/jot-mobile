import Foundation
import Observation
import os.log

// ============================================================================
// 🚧 BEING REMOVED — DO NOT EXTEND. See docs/plans/unify-keyboard-dictation.md
// ----------------------------------------------------------------------------
// This whole registration layer (the "inline dictation receiver" + targets +
// heroFallbackRequest) is slated for DELETION. In-Jot keyboard dictation is
// moving to the SAME path the keyboard uses in any other app: record in-app,
// insert the result into the focused field on stop. Jot's fields become "just
// fields" — no registration, no live-partial streaming, no hero fallback.
//
// The doc comments below describe the OLD (current) behavior accurately, but
// that behavior is NOT the target design. Do not add features here or "fix"
// this in its own terms — align with the plan instead.
//
// Survivors: Ask keeps its own InlineDictationSession; warm-hold is untouched.
// ============================================================================

/// App-level receiver for the keyboard's Dictate-tap (`keyboardDictateTapped`)
/// when the host app is Jot itself and the **setup wizard is NOT presented**
/// (UX-overhaul round 2 §9 R5 — the unified receiver).
///
/// ## Why this exists
///
/// The keyboard extension can't capture audio. When the user taps the keyboard's
/// Dictate pill while Jot is foreground, the keyboard posts `keyboardDictateTapped`
/// (it can't drive the `jot://dictate` URL bounce — iOS refuses to re-launch the
/// already-foreground app). Two consumers want that tap:
///
///   - **The wizard** (W5 keyboard-try step) installs its own observer while it
///     is presented, and STARTS A PIPELINE recording (it needs the paste to land
///     in the wizard's TextField). That path is UNCHANGED — see `SetupWizardView`.
///   - **Everywhere else in-app** (R5 matrix "Keyboard-while-Jot-foreground")
///     wants an **inline** dictation into the focused field that saves **no**
///     transcript. That's this receiver.
///
/// The two never run at once: this receiver's handler bails when the wizard is
/// presented (the wizard's own observer owns that case), so there's no
/// double-fire even though both observe the same Darwin name.
///
/// ## Binding to the focused field
///
/// "The focused field" is whatever in-app editable surface registered itself as
/// the active inline target via ``register(target:)`` (Edit registers on focus;
/// Ask owns its own in-sheet flow and does not register here). When a tap
/// arrives and a target is registered, we drive a shared `InlineDictationSession`
/// and hand the focused target each lifecycle beat (start → partial-fill →
/// terminal). With no registered target there is nothing to insert into, so the
/// tap is a graceful no-op (the user isn't editing anything).
///
/// `discard()` is called on any dismiss/abandon so a backgrounded inline session
/// never leaks a live recording (R6).
@MainActor
@Observable
final class InlineDictationReceiver {
    /// A focused, editable in-app surface that can host an inline dictation.
    /// The surface implements insert-at-cursor itself (R3); this protocol is the
    /// minimal lifecycle the receiver drives. All callbacks land on the
    /// MainActor.
    @MainActor
    protocol Target: AnyObject {
        /// Called the instant a dictation is requested for this target, before
        /// audio is live, so the surface can snapshot the caret (prefix/suffix)
        /// for insert-at-cursor.
        func inlineDictationWillStart()
        /// Called with the final transcribed text to insert at the caret. `nil`
        /// when nothing was captured / transcription failed (no insert).
        func inlineDictationDidFinish(text: String?)
        /// Called when the dictation was discarded (abandon path) — no insert.
        func inlineDictationDidDiscard()
    }

    private static let log = Logger(
        subsystem: "com.vineetu.jot.mobile.Jot",
        category: "inline-dictation-receiver"
    )

    private let recordingService: RecordingService
    private let transcribe: (_ samples: [Float]) async throws -> String

    /// Weakly-held active inline target (the focused editable surface). Weak so a
    /// dismissed surface that forgot to deregister can't keep the receiver
    /// pinning it alive.
    private weak var target: Target?

    /// The live session for the current inline dictation, if any.
    private var session: InlineDictationSession?

    /// Set while the receiver is the active host of a keyboard-driven Darwin tap,
    /// so a host can decide whether the unified path (vs. the wizard) handled it.
    private(set) var isHosting = false

    /// Incremented when a keyboard Dictate tap arrives while Jot is foreground but
    /// NO editable field is a registered inline target (e.g. Send Feedback, the
    /// search field, the prompt editor). The host (`ContentView`) observes this and
    /// falls back to a HERO recording, so a keyboard Dictate tap inside Jot is
    /// NEVER a silent dead-end ("not opening and not recording"). Cold / background
    /// taps can't reach here — they URL-bounce; this is purely the Jot-foreground,
    /// no-inline-field case.
    private(set) var heroFallbackRequest = 0

    init(
        recordingService: RecordingService = .shared,
        transcribe: @escaping (_ samples: [Float]) async throws -> String
    ) {
        self.recordingService = recordingService
        self.transcribe = transcribe
    }

    // MARK: - Target registration

    /// Register the focused editable surface as the inline-dictation target.
    /// Call on focus (e.g. Edit's TextEditor gaining focus). Replacing a target
    /// while a session is live discards the in-flight one first (R6 — never leak
    /// a recording when focus moves).
    func register(target: Target) {
        if session != nil, self.target !== target {
            discardActive()
        }
        self.target = target
    }

    /// Deregister `target` if it is the current one (call on blur / disappear).
    /// Idempotent and identity-checked so a stale surface can't clear a newer
    /// one's registration. Discards any live session for this target (R6).
    func deregister(target: Target) {
        guard self.target === target else { return }
        if session != nil { discardActive() }
        self.target = nil
    }

    // MARK: - Keyboard-tap routing

    /// Handle a `keyboardDictateTapped` Darwin tap. Toggles: a tap while a
    /// session is live FINALIZES it (mirrors the keyboard Stop pill landing back
    /// here); a tap with no live session STARTS one against the focused target.
    /// No-ops gracefully when no target is focused or a pipeline is already in
    /// flight.
    func handleKeyboardDictateTap() {
        // A live session means the keyboard pill is showing Stop — finalize.
        if session != nil {
            finalizeActive()
            return
        }
        guard let target else {
            // No focused inline field to dictate into — DON'T drop the tap. Ask
            // the host to present a hero recording instead (Fix for the silent
            // dead-tap in Jot fields that aren't registered inline surfaces).
            heroFallbackRequest &+= 1
            Self.log.notice("keyboardDictateTapped with no inline target -> hero fallback")
            return
        }
        // Don't start over a prior dictation's tail (R6) — a tap here would be a
        // silent no-op otherwise.
        guard !recordingService.isRecording, !recordingService.isPipelineInFlight else {
            Self.log.notice("keyboardDictateTapped while recorder busy; ignoring")
            return
        }
        startInline(into: target)
    }

    /// Handle a cross-process `stopRequested` (the keyboard posted it because the
    /// pipeline projection shows `.recording` — it cannot tell our inline session
    /// from a capture). If we own a live inline session, finalize it INLINE:
    /// transcribe + insert at the cursor, write NO Transcript. No-op otherwise —
    /// a capture stop is owned by `JotApp.handleStopRequested`, which only reaches
    /// its saving path when no inline session owns the recording.
    func handleExternalStop() {
        guard session != nil else { return }
        Self.log.notice("stopRequested while hosting an inline session → finalize inline, no save")
        finalizeActive()
    }

    // MARK: - Lifecycle

    private func startInline(into target: Target) {
        os_log("RECORDING START FROM: inline-receiver keyboard-in-Jot tap")
        isHosting = true
        target.inlineDictationWillStart()
        let session = InlineDictationSession(
            recordingService: recordingService,
            transcribe: transcribe
        )
        self.session = session
        session.start()
    }

    private func finalizeActive() {
        guard let session, let target else {
            self.session = nil
            isHosting = false
            return
        }
        self.session = nil
        Task { @MainActor in
            let text = await session.finalize()
            target.inlineDictationDidFinish(text: text)
            isHosting = false
        }
    }

    /// Discard the live session (any dismiss / abandon / focus-move). Drops the
    /// audio, inserts nothing (R6). Safe to call when nothing is live.
    func discardActive() {
        guard let session else { isHosting = false; return }
        self.session = nil
        let target = self.target
        session.discard()
        target?.inlineDictationDidDiscard()
        isHosting = false
    }
}
