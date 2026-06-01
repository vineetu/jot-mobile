import Foundation
import Observation
import SwiftUI
import os.log

/// Drives **inline dictation inside the Edit `TextEditor`** on the transcript
/// detail surface (UX-overhaul round 2 WS-B).
///
/// ## What it owns
///
/// One `InlineDictationSession` at a time, plus the insert-at-cursor bookkeeping
/// (R3): when dictation starts it snapshots the editor text on either side of
/// the caret/selection into `prefix` / `suffix`. While recording, the host view
/// streams the live partial into the field by rendering `prefix + partial +
/// suffix`; on `finalize()` the final text replaces that span. Selected text (a
/// non-empty selection) is replaced by the dictated text — the selection range
/// IS the insertion span.
///
/// ## Why a class (not view `@State` closures)
///
/// `InlineDictationReceiver.Target` is `AnyObject`, so the keyboard-while-in-Jot
/// tap (R5) can route to the focused Edit field. A SwiftUI `struct` can't
/// conform. This controller conforms and registers/deregisters itself with the
/// shared receiver as the Edit editor gains / loses focus. The same controller
/// also backs the in-editor mic button, so the two entry points (mic tap and
/// keyboard Dictate tap) share ONE session and ONE insert-at-cursor path.
///
/// ## What it does NOT do
///
/// It never saves a `Transcript` and never touches `DictationStats` — inline
/// Edit dictation pastes into the field only (decision #3, R7). All of that is
/// inherited from `InlineDictationSession`; this type only adds the field-bound
/// insert-at-cursor layer on top.
@MainActor
@Observable
final class EditDictationController: InlineDictationReceiver.Target {

    /// True between `start()` and a terminal. Drives the mic-button glyph and
    /// disables the editor's other affordances while live.
    private(set) var isDictating = false

    /// Snapshot of the editor text BEFORE the caret/selection at dictation
    /// start. The live partial (and the final text) render between these.
    private var prefix = ""
    /// Snapshot of the editor text AFTER the caret/selection at dictation start.
    private var suffix = ""

    /// The host's editor-text binding. Set by ``bind(editorText:selection:)``
    /// while Edit mode is active so partial/final text can be written straight
    /// into the `TextEditor` without the view re-wiring a closure per render.
    private var editorTextBinding: Binding<String>?
    /// The host's live caret/selection binding. Read at dictation-start (mic or
    /// keyboard tap) to snapshot the insertion span. Bound — never a captured
    /// struct snapshot — so the value is always current.
    private var selectionBinding: Binding<TextSelection?>?

    private let recordingService: RecordingService
    private let transcribe: (_ samples: [Float]) async throws -> String
    private var session: InlineDictationSession?

    private static let log = Logger(
        subsystem: "com.vineetu.jot.mobile.Jot",
        category: "edit-dictation"
    )

    init(
        recordingService: RecordingService = .shared,
        transcribe: @escaping (_ samples: [Float]) async throws -> String
    ) {
        self.recordingService = recordingService
        self.transcribe = transcribe
    }

    /// The inline mic must be inert while a prior dictation's pipeline is still
    /// finishing — otherwise a tap is a silent no-op (R6). The host gates the
    /// button on this.
    var isMicEnabled: Bool {
        !recordingService.isPipelineInFlight || isDictating
    }

    /// Bind the editor's text + selection so streamed/finalized text lands
    /// directly in the field and the insertion span is read live (never a stale
    /// struct snapshot). Re-bound each time Edit mode opens.
    func bind(editorText: Binding<String>, selection: Binding<TextSelection?>) {
        editorTextBinding = editorText
        selectionBinding = selection
    }

    // MARK: - Start / stop (mic button)

    /// Begin dictation from the in-editor mic. Snapshots the insertion span from
    /// the LIVE bound editor text + selection (nil selection → caret at end =
    /// append), then starts the session.
    func start() {
        guard !isDictating, isMicEnabled else { return }
        snapshotSpanFromBindings()
        isDictating = true
        os_log("RECORDING START FROM: edit-inline mic tap")
        let session = InlineDictationSession(
            recordingService: recordingService,
            transcribe: transcribe
        )
        self.session = session
        session.start()
    }

    /// Stop + transcribe + insert at the snapshotted span. No-op when idle.
    func finalize() {
        guard isDictating, let session else { return }
        self.session = nil
        isDictating = false
        Task { @MainActor in
            let text = await session.finalize()
            insertFinal(text)
        }
    }

    /// Render a live partial into the field: `prefix + partial + suffix`.
    /// Called by the host on every `streamingPartial.streamingText` change while
    /// `isDictating`. Cheap string concat — the same shape Ask uses.
    func renderPartial(_ partial: String) {
        guard isDictating else { return }
        editorTextBinding?.wrappedValue = join(prefix: prefix, mid: partial, suffix: suffix)
    }

    // MARK: - InlineDictationReceiver.Target (keyboard-in-Jot tap, R5)
    //
    // The receiver drives start via `inlineDictationWillStart` (the receiver
    // owns the `InlineDictationSession` on this path; we only snapshot the span
    // and accept the terminal). Finish/discard mirror the mic path.

    func inlineDictationWillStart() {
        snapshotSpanFromBindings()
        isDictating = true
        os_log("RECORDING START FROM: edit-inline keyboard-in-Jot tap")
    }

    func inlineDictationDidFinish(text: String?) {
        isDictating = false
        session = nil
        insertFinal(text)
    }

    func inlineDictationDidDiscard() {
        isDictating = false
        session = nil
        // Restore the field to its pre-dictation content (drop the live
        // partial). The snapshot prefix+suffix IS that content.
        editorTextBinding?.wrappedValue = prefix + suffix
    }

    // MARK: - Discard (Edit back-out without an explicit stop)

    /// Abandon any live dictation without inserting (R6). Used when Edit mode
    /// exits (Cancel/Save) or the surface backgrounds mid-dictation. Drops the
    /// audio, restores the field to its pre-dictation content, and never paints
    /// a partial that won't be finalized.
    func discard() {
        guard isDictating else { return }
        isDictating = false
        let session = self.session
        self.session = nil
        editorTextBinding?.wrappedValue = prefix + suffix
        session?.discard()
    }

    // MARK: - Internals

    /// Capture the text on either side of the insertion span from the LIVE
    /// bound editor text + selection. A non-empty selection is REPLACED (its
    /// content drops from both prefix and suffix); a caret splits the text at
    /// that offset; no resolvable single-range selection appends at the end.
    private func snapshotSpanFromBindings() {
        let editorText = editorTextBinding?.wrappedValue ?? ""
        if let range = resolveSelectionRange(in: editorText) {
            prefix = String(editorText[editorText.startIndex..<range.lowerBound])
            suffix = String(editorText[range.upperBound..<editorText.endIndex])
        } else {
            prefix = editorText
            suffix = ""
        }
    }

    /// Resolve the live `TextSelection` (iOS 18+) into a `Range<String.Index>`
    /// of `editorText`, or `nil` to mean "append at the end." Only a single
    /// range is honored; a multi-selection (or none) appends. Defensively
    /// clamps against a range that no longer lines up with the current text so
    /// a stale index can't crash the substring slice.
    private func resolveSelectionRange(in editorText: String) -> Range<String.Index>? {
        guard let selection = selectionBinding?.wrappedValue else { return nil }
        switch selection.indices {
        case .selection(let range):
            guard range.lowerBound >= editorText.startIndex,
                  range.upperBound <= editorText.endIndex else {
                return nil
            }
            return range
        case .multiSelection:
            return nil
        @unknown default:
            return nil
        }
    }

    /// Write the final transcribed text into the span. `nil` / empty → restore
    /// the original (drop the live partial, insert nothing).
    private func insertFinal(_ text: String?) {
        guard let text, !text.isEmpty else {
            editorTextBinding?.wrappedValue = prefix + suffix
            return
        }
        editorTextBinding?.wrappedValue = join(prefix: prefix, mid: text, suffix: suffix)
        Self.log.info("edit-inline dictation inserted chars=\(text.count)")
    }

    /// Join the three spans, inserting single separating spaces only where a
    /// word boundary would otherwise be lost (no double spaces, no glued words).
    private func join(prefix: String, mid: String, suffix: String) -> String {
        var out = prefix
        if !mid.isEmpty {
            if !out.isEmpty,
               !(out.last?.isWhitespace ?? false),
               !(mid.first?.isWhitespace ?? false) {
                out += " "
            }
            out += mid
        }
        if !suffix.isEmpty {
            if !out.isEmpty,
               !(out.last?.isWhitespace ?? false),
               !(suffix.first?.isWhitespace ?? false) {
                out += " "
            }
            out += suffix
        }
        return out
    }
}
