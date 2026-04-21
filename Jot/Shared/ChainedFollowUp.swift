import Foundation

/// Constants + shared types for the chained-follow-up feature.
///
/// ## What chained follow-up is
///
/// When a user dictates a short utterance shortly after a prior dictation,
/// it's often not a fresh thought — it's a *command* against the text they
/// just produced. "Make this more casual." "Actually, change 'meeting' to
/// 'coffee'." "Translate that to Spanish." The naive UX would paste that
/// literal sentence next to the prior transcript on the clipboard, which is
/// never what the user wanted.
///
/// Chained follow-up detects this: the intent pipeline pulls the most recent
/// `Transcript` from the store, passes it to
/// `CleanupService.resolveUtterance(new:priorTranscript:)` alongside the new
/// utterance, and the classifier decides which of two paths to run:
///
/// - `.freshDictation` → behave as before (append, publish, done).
/// - `.command(instruction:, result:)` → publish the *transformed prior* to
///   the clipboard, append a new `Transcript` marked as a follow-up
///   (`derivedFromID` + `instruction`), and mark the prior `Transcript` as
///   superseded so the library UI can dim/group the pair.
///
/// The design doc lives at `docs/design/voice-interaction-patterns.md` — it's
/// the #1-recommended pattern per product, and the full-v2 amendment elevates
/// it from nice-to-have to required-before-ship.
///
/// ## The freshness window
///
/// Only prior transcripts within `freshnessWindow` seconds of now are
/// considered candidates. Beyond that, the user has almost certainly moved
/// on to a new thought and the classifier would produce false positives
/// ("compose an email to Sarah" dictated two hours after "thanks for the
/// reminder" must not become a command against "thanks for the reminder").
///
/// 45 seconds is the team-lead-set value. It's long enough to cover "pause
/// to think, re-read what was captured, decide to tweak it" while staying
/// inside the user's active rephrase window, and short enough that it
/// doesn't cross reasonable session boundaries. Earlier candidates of 75s
/// and 120s were rejected because they let unrelated dictations collide.
///
/// The classifier itself does NOT consult time — it accepts `priorTranscript:
/// String?` and short-circuits to `.freshDictation` when `nil`. Timing is
/// therefore the caller's responsibility: if the most recent transcript is
/// older than this window, the caller passes `nil` and no round-trip fires.
enum ChainedFollowUp {
    /// How recent a prior transcript must be (in seconds) to be considered a
    /// candidate for command resolution. See class doc for why 45.
    static let freshnessWindow: TimeInterval = 45
}
