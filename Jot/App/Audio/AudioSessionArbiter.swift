import Foundation

/// Coordinates the single process-wide `AVAudioSession` between the **playback**
/// owner (TTS Lab read-aloud) and the **record** owner (dictation), so playback
/// cleanly yields the session before a recording reconfigures it.
///
/// ## Why this exists
/// There is exactly one `AVAudioSession` per app. `TTSService` sets it to
/// `.playback` and runs its own engine; `RecordingService` sets it to `.record`.
/// Before this arbiter, the two mutated the session independently — so playing a
/// voice and then dictating left a live `.playback` engine colliding with the
/// `.record` session (input came up 0ch/0Hz → dictation failed, intermittently).
/// `TTSService` already guarded the *mic-already-live* direction; this closes the
/// reverse one.
///
/// ## The model (deliberately minimal — a single-registrant registry)
/// The current playback owner **registers its own teardown closure** (TTS's
/// `stop()`). When a recording is about to start, `RecordingService.start()` (and
/// the clone recorder, which uses its own `AVAudioRecorder` and bypasses
/// `start()`) calls ``yieldForRecording()``, which invokes that closure so
/// playback tears itself down **before** the recorder touches the session.
///
/// ## Warm-hold safety — the load-bearing invariant
/// The arbiter **never touches `AVAudioSession` itself.** The only deactivation
/// is inside the registrant's own `stop()`, and that runs only if a registrant
/// exists. When nothing is playing (the normal dictation / warm-hold case) there
/// is no registrant, so ``yieldForRecording()`` is a pure no-op — it cannot
/// deactivate or disturb a warm-held or active `.record` session. `RecordingService`
/// is only ever a *caller*, never a registrant, so no path lets the arbiter tear
/// down a record session. Two independent design reviews verified this property.
///
/// Registration is **identity-keyed** (by the caller's generation token) so a
/// superseding `speak()` that replaced the registrant is not clobbered when the
/// superseded task's `defer` resigns.
@MainActor
final class AudioSessionArbiter {
    static let shared = AudioSessionArbiter()
    private init() {}

    private static let noRegistrant = Int.min

    private var registrantToken: Int = AudioSessionArbiter.noRegistrant
    private var playbackYield: (() -> Void)?

    /// The current playback owner registers its teardown. `token` identifies this
    /// registration (use a per-utterance generation); a later registration with a
    /// new token supersedes this one.
    func registerPlayback(token: Int, yield: @escaping () -> Void) {
        registrantToken = token
        playbackYield = yield
    }

    /// Resign — only if `token` still matches the current registrant. A superseded
    /// owner (whose registration was already replaced) is a no-op, so its `defer`
    /// can't clobber the live registrant.
    func resignPlayback(token: Int) {
        guard token == registrantToken else { return }
        registrantToken = Self.noRegistrant
        playbackYield = nil
    }

    /// Called at the TOP of any recording start. If a playback owner is registered,
    /// invoke its teardown so it releases the session before `.record` is taken.
    /// No-op when nothing is registered. The closure is snapshotted first because
    /// invoking it re-enters `resignPlayback` mid-call.
    func yieldForRecording() {
        let yield = playbackYield
        registrantToken = Self.noRegistrant
        playbackYield = nil
        yield?()
    }
}
