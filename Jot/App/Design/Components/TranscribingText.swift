//
//  TranscribingText.swift
//  Jot
//
//  Live-transcript text rendered as PLAIN SwiftUI text + a trailing
//  stepping-ellipsis "still transcribing" tail — shared by the recording
//  hero and the keyboard streaming strip.
//

import SwiftUI

/// Live-transcript text with a "still transcribing — more is coming" tail.
///
/// The batch preview loop (`PreviewScheduler`) delivers the live transcript in
/// sentence-sized chunks at speech pauses / every ~5s, so a whole clause can
/// land at once and the newest word can LAG the voice by several seconds. The
/// text is rendered as a **plain SwiftUI `Text`** (full text, full ink) the
/// instant each chunk arrives — there is NO per-view animation/layout state to
/// strand, so a blank pane is structurally impossible regardless of how many
/// throwaway/ghost controllers iOS spawns around the shared streaming state.
///
/// A trailing **stepping ellipsis** (three SF Pro dots, `SteppingEllipsis`
/// cadence) is appended INLINE after the text — exactly where the next word
/// will land — stepping through a slow fill cycle (rest → · → ·· → ···,
/// 0.45s/step) so the trailing edge reads "I'm still hearing you, text is
/// catching up". Deliberately slower than a cursor blink: patient, not anxious.
/// The tail appears ONLY while `isTranscribing` (active capture); pause/stop
/// drops it (nothing is being captured, so nothing should promise more text).
///
/// The dots inherit the transcript's font (same face, same baseline, they wrap
/// with the line) but render in `dotColor` — call sites pass the surface's
/// chrome color so the tail reads as UI, never as punctuation the user
/// dictated.
///
/// Used by BOTH live-preview surfaces: the recording hero
/// (`StreamingDictationText`) and the keyboard strip (`StreamingPane`). The
/// keyboard target compiles this file explicitly (see the per-file design
/// sources in `project.yml`), so keep it free of main-app dependencies —
/// pure SwiftUI, colors injected.
///
/// - `isTranscribing == false` (paused / stopped mic) drops the tail entirely
///   — nothing is being captured, so nothing should promise more text.
/// - Reduce Motion renders a static steady ellipsis (no `TimelineView`).
/// - The tail is decorative chrome — VoiceOver reads the transcript only.
///
/// Tradeoff (owner-approved): the per-word "ink-drying" fade is gone; text
/// appears in full as each batch chunk arrives. Auto-scroll is owned by the
/// call sites (`StreamingPane` / `StreamingDictationText`), which key off the
/// `text` change, so movement is unaffected.
struct TranscribingText: View {
    let text: String
    /// Applied to the WHOLE run (transcript + dots) so the tail shares the
    /// transcript's face and baseline.
    let font: Font
    let textColor: Color
    /// Base color of the tail dots; per-dot opacity does the stepping.
    let dotColor: Color
    /// `true` while the mic is actively capturing and the preview is volatile.
    /// `false` (e.g. paused) hides the tail.
    let isTranscribing: Bool
    let reduceMotion: Bool
    /// Letter tracking for the run (the hero uses -0.4; default 0).
    var tracking: CGFloat = 0

    var body: some View {
        Group {
            if !isTranscribing {
                // No tail — paused/stopped, nothing is being captured.
                run(dotOpacities: nil)
            } else if reduceMotion {
                run(dotOpacities: SteppingEllipsis.staticOpacities)
            } else {
                TimelineView(.periodic(from: .now, by: SteppingEllipsis.stepInterval)) { context in
                    run(dotOpacities: SteppingEllipsis.opacities(at: context.date))
                }
            }
        }
        // The dots are decorative chrome — assistive tech reads the words.
        .accessibilityLabel(Text(text))
    }

    /// Single concatenated `Text` run: the full transcript + (optionally) three
    /// trailing dots. Concatenation keeps the tail IN the line-wrap flow so it
    /// always lands right after the last word — an `HStack`-appended caret
    /// instead pins to the edge of the whole text block once lines wrap.
    private func run(dotOpacities: [Double]?) -> Text {
        var run = Text(text).foregroundStyle(textColor)
        if let dotOpacities {
            run = run + Text(" ")
            for opacity in dotOpacities {
                run = run + Text(".").foregroundStyle(dotColor.opacity(opacity))
            }
        }
        return run
            .font(font)
            .tracking(tracking)
    }
}

// MARK: - Stepping ellipsis (shared dot animation)

/// The calm stepping ellipsis used by BOTH the live-transcript tail
/// (`TranscribingText`, concatenated INLINE into its text run) AND the empty
/// "waiting" placeholders (recording hero + keyboard strip), so the three dots
/// breathe identically the moment a surface appears — alive from second one,
/// quiet (no waveform).
///
/// This view is the standalone form: a leading word/label followed by the
/// three stepping dots, all in one `Text` run so the dots wrap with the label
/// and share its baseline. `TranscribingText` doesn't use this view (it builds
/// its own run with the full transcript + dots) but reads the SAME cadence and
/// opacity stepping from the shared statics here — one source of truth for the
/// dot animation.
///
/// Pure SwiftUI, colors injected — no main-app dependencies, since the keyboard
/// appex compiles this file (see the per-file design sources in `project.yml`).
/// Reduce Motion renders a static steady ellipsis (no `TimelineView`).
struct SteppingEllipsis: View {
    /// Leading text the dots trail (e.g. "Listening"). A single space is
    /// inserted between it and the first dot.
    let leading: String
    let font: Font
    let textColor: Color
    /// Base color of the tail dots; per-dot opacity does the stepping.
    let dotColor: Color
    let reduceMotion: Bool
    var tracking: CGFloat = 0

    /// One fill step. 4 phases × 0.45s = a calm 1.8s loop.
    static let stepInterval: TimeInterval = 0.45

    /// Dot opacities: lit vs resting. The resting dots stay faintly visible so
    /// the tail never pops in/out of layout — only brightness moves.
    static let litOpacity: Double = 0.9
    static let restingOpacity: Double = 0.28
    /// Reduce-Motion static ellipsis: a single steady mid tone.
    static let staticOpacity: Double = 0.55
    static let staticOpacities: [Double] = [staticOpacity, staticOpacity, staticOpacity]

    /// Per-dot opacities for the stepping cycle at a given wall-clock instant.
    /// 4 phases: 0 lit (rest beat) → 1 → 2 → 3 lit, then around. Derived from
    /// the clock so it animates without any data arriving.
    static func opacities(at date: Date) -> [Double] {
        let phase = Int(date.timeIntervalSinceReferenceDate / stepInterval) % 4
        return (0..<3).map { index in index < phase ? litOpacity : restingOpacity }
    }

    var body: some View {
        Group {
            if reduceMotion {
                run(dotOpacities: Self.staticOpacities)
            } else {
                TimelineView(.periodic(from: .now, by: Self.stepInterval)) { context in
                    run(dotOpacities: Self.opacities(at: context.date))
                }
            }
        }
        .accessibilityLabel(Text(leading))
    }

    private func run(dotOpacities: [Double]) -> Text {
        var run = Text(leading).foregroundStyle(textColor) + Text(" ")
        for opacity in dotOpacities {
            run = run + Text(".").foregroundStyle(dotColor.opacity(opacity))
        }
        return run.font(font).tracking(tracking)
    }
}
