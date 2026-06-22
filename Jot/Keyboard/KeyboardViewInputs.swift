import SwiftUI
import UIKit

/// `@Observable` bag of every *value* input `KeyboardView` takes (everything
/// except `recordingState`, `feedback`, and the action closures).
///
/// ## Why this exists
///
/// The keyboard controller used to drive ALL UI updates by reassigning a
/// type-erased `AnyView` root onto its `UIHostingController` (a 37-call-site
/// `renderRootView()` → `hostingController?.rootView = makeRootView()`).
/// Reassigning a type-erased root wholesale defeats SwiftUI's `@Observable`
/// incremental updates — the streaming-preview pane intermittently committed a
/// STALE frame (blank / old text) until a re-present forced a fresh layout.
///
/// The structural fix builds the root host ONCE (`KeyboardRootHostView`) and
/// drives every value update through this `@Observable` object instead. The
/// controller now copies its current state into `keyboardInputs.X` in
/// `syncKeyboardInputs()`; `KeyboardRootHostView.body` reads `inputs.X`, so it
/// observes the changes and recomposes only the affected subtree — no root
/// reassignment, no type erasure, no stale-frame thrash.
///
/// Streaming/recording updates flow through `recordingState` (also
/// `@Observable`), which `KeyboardView` reads directly — so the preview pane
/// updates incrementally without touching this object at all.
@MainActor
@Observable
final class KeyboardViewInputs {
    var hasFullAccess: Bool = false
    var hasPasteboardContent: Bool = false
    var needsInputModeSwitchKey: Bool = false
    var returnKeyType: UIReturnKeyType = .default
    var historyEntries: [TranscriptHistoryMirror.Entry] = []
    var canUndoLastInsertion: Bool = false
    var canRedoInsertion: Bool = false
    var lastPastedText: String? = nil
    var lastPastedAt: Date? = nil
    var isStopRequestPending: Bool = false
    var statusBanner: String? = nil
    var showWarmHoldNudge: Bool = false
    var keyboardAppearance: UIKeyboardAppearance = .default
    var hasSelection: Bool = false
    var showCorrectionNudge: Bool = false
    var correctionAsks: CorrectionBridge.Asks? = nil
    /// Ask-before-paste HOLD deck (Thread 2) — pre-paste review; the paste is held
    /// while this is true.
    var showAskDeck: Bool = false
    var askDeckAsks: CorrectionBridge.Asks? = nil
}

/// Concrete, build-once root for the hosted keyboard surface.
///
/// Holds the `@Observable` `inputs` bag plus the pass-through `recordingState`,
/// `feedback`, and all of `KeyboardView`'s action closures. Its `body` builds
/// `KeyboardView` exactly as the controller's old `makeKeyboardView()` did,
/// except every *value* argument now reads from `inputs.X`. Because `body`
/// reads `inputs.X` it observes those values; because `KeyboardView` reads
/// `recordingState.X` directly, streaming updates flow via `@Observable` with
/// no root reassignment.
struct KeyboardRootHostView: View {
    let inputs: KeyboardViewInputs
    let recordingState: KeyboardRecordingState
    let feedback: KeyboardFeedback

    let onCopy: () -> Void
    let onAddToVocabulary: () -> Void
    let onPaste: () -> Void
    let onUndoLastInsertion: () -> Void
    let onRedoInsertion: () -> Void
    let onJumpToStart: () -> Void
    let onJumpToEnd: () -> Void
    let onTapToSpeak: () -> Void
    let onInsertHistoryEntry: (TranscriptHistoryMirror.Entry) -> Void
    let onInsertText: (String) -> Void
    let onKey: (KeyboardKeyDescriptor) -> Void
    let onKeyPressChange: (KeyboardKeyDescriptor, Bool) -> Void
    let onAdvanceToNextInputMode: () -> Void
    let onOpenFullAccess: () -> Void
    let onStatusBannerRendered: () -> Void
    let onOpenHome: () -> Void
    let onOpenHistoryEntryInApp: (TranscriptHistoryMirror.Entry) -> Void
    let onActionsTapped: () -> Void
    let onCancelRecording: () -> Void
    let onPauseRecording: () -> Void
    let onResumeRecording: () -> Void
    let onWarmHoldNudgeKeepMicReady: () -> Void
    let onWarmHoldNudgeDismiss: () -> Void
    let onCorrectionVerdict: (String, String) -> Void
    let onCorrectionFinished: () -> Void
    let onAskDeckVerdict: (String, String) -> Void
    let onAskDeckStopAsking: (String) -> Void
    let onAskDeckFinished: () -> Void

    var body: some View {
        KeyboardView(
            hasFullAccess: inputs.hasFullAccess,
            hasPasteboardContent: inputs.hasPasteboardContent,
            recordingState: recordingState,
            needsInputModeSwitchKey: inputs.needsInputModeSwitchKey,
            returnKeyType: inputs.returnKeyType,
            historyEntries: inputs.historyEntries,
            canUndoLastInsertion: inputs.canUndoLastInsertion,
            canRedoInsertion: inputs.canRedoInsertion,
            lastPastedText: inputs.lastPastedText,
            lastPastedAt: inputs.lastPastedAt,
            isStopRequestPending: inputs.isStopRequestPending,
            statusBanner: inputs.statusBanner,
            showWarmHoldNudge: inputs.showWarmHoldNudge,
            keyboardAppearance: inputs.keyboardAppearance,
            hasSelection: inputs.hasSelection,
            onCopy: onCopy,
            onAddToVocabulary: onAddToVocabulary,
            onPaste: onPaste,
            onUndoLastInsertion: onUndoLastInsertion,
            onRedoInsertion: onRedoInsertion,
            onJumpToStart: onJumpToStart,
            onJumpToEnd: onJumpToEnd,
            onTapToSpeak: onTapToSpeak,
            onInsertHistoryEntry: onInsertHistoryEntry,
            onInsertText: onInsertText,
            onKey: onKey,
            onKeyPressChange: onKeyPressChange,
            onAdvanceToNextInputMode: onAdvanceToNextInputMode,
            onOpenFullAccess: onOpenFullAccess,
            onStatusBannerRendered: onStatusBannerRendered,
            onOpenHome: onOpenHome,
            onOpenHistoryEntryInApp: onOpenHistoryEntryInApp,
            onActionsTapped: onActionsTapped,
            onCancelRecording: onCancelRecording,
            onPauseRecording: onPauseRecording,
            onResumeRecording: onResumeRecording,
            onWarmHoldNudgeKeepMicReady: onWarmHoldNudgeKeepMicReady,
            onWarmHoldNudgeDismiss: onWarmHoldNudgeDismiss,
            showCorrectionNudge: inputs.showCorrectionNudge,
            correctionAsks: inputs.correctionAsks,
            onCorrectionVerdict: onCorrectionVerdict,
            onCorrectionFinished: onCorrectionFinished,
            showAskDeck: inputs.showAskDeck,
            askDeckAsks: inputs.askDeckAsks,
            onAskDeckVerdict: onAskDeckVerdict,
            onAskDeckStopAsking: onAskDeckStopAsking,
            onAskDeckFinished: onAskDeckFinished,
            feedback: feedback
        )
    }
}
