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
    var undoDepth: Int = 0
    var redoDepth: Int = 0
    var lastPastedText: String? = nil
    var lastPastedAt: Date? = nil
    var isStopRequestPending: Bool = false
    var statusBanner: String? = nil
    var showWarmHoldNudge: Bool = false
    var showParakeetUpgradeNudge: Bool = false
    var showVocabNudge: Bool = false
    var keyboardAppearance: UIKeyboardAppearance = .default
    var hasSelection: Bool = false
    /// Automatic cleanup (§7.14) on/off, read from the App Group each sync;
    /// the actions pane's Cleanup tile shows and flips it.
    var cleanupEnabled: Bool = false
    /// Whether the app last saw Apple Intelligence able to run the cleanup
    /// (`AppGroup.Keys.aiCleanupAvailable`; absent ⇒ true).
    var cleanupAvailable: Bool = true
    /// Whether Apple's on-device model can rewrite the host's selection right
    /// here (§7.15). Refreshed when the actions pane opens. False ⇒ the
    /// Rewrite tile is washed and its tap explains why via the status banner.
    var rewriteAvailable: Bool = false
    /// True while a keyboard rewrite is running (tile washed, double-tap guard).
    var rewriteInFlight: Bool = false
    /// Translate pane (§7.16): the target languages to offer for the current
    /// selection (empty while the installed-pack check runs), the detected
    /// source code, and the in-flight guard.
    var translateOptions: [KeyboardTranslateOption] = []
    var translateSource: String = "en"
    var translateInFlight: Bool = false
    var showCorrectionNudge: Bool = false
    var correctionAsks: CorrectionBridge.Asks? = nil
    /// Ask-before-paste HOLD deck (F1) — the hub's deck snapshot while it is
    /// REVIEWING (nil otherwise), plus whether a held paste exists in any phase
    /// (which blocks a second dictation — F1b).
    var askDeckSnapshot: AskDeckSnapshot? = nil
    var askDeckBlocksDictation: Bool = false
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
    let onToggleCleanup: () -> Void
    let onRewriteSelection: () -> Void
    let onTranslateOpen: () -> Bool
    let onTranslateSelection: (String) -> Void
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
    let onParakeetUpgradeNudgeUpgrade: () -> Void
    let onParakeetUpgradeNudgeDismiss: () -> Void
    let onVocabNudgeSetUp: () -> Void
    let onVocabNudgeDismiss: () -> Void
    let onCorrectionVerdict: (String, String) -> Void
    let onCorrectionFinished: () -> Void
    let onAskDeckVerdict: (AskDeckToken, String, String) -> Void
    let onAskDeckStopAsking: (AskDeckToken, String) -> Void
    let onAskDeckSkipCard: (AskDeckToken, String) -> Void
    let onAskDeckSkipAll: (AskDeckToken) -> Void
    let onAskDeckFinished: (AskDeckToken) -> Void

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
            undoDepth: inputs.undoDepth,
            redoDepth: inputs.redoDepth,
            lastPastedText: inputs.lastPastedText,
            lastPastedAt: inputs.lastPastedAt,
            isStopRequestPending: inputs.isStopRequestPending,
            statusBanner: inputs.statusBanner,
            showWarmHoldNudge: inputs.showWarmHoldNudge,
            showParakeetUpgradeNudge: inputs.showParakeetUpgradeNudge,
            showVocabNudge: inputs.showVocabNudge,
            keyboardAppearance: inputs.keyboardAppearance,
            hasSelection: inputs.hasSelection,
            cleanupEnabled: inputs.cleanupEnabled,
            cleanupAvailable: inputs.cleanupAvailable,
            rewriteAvailable: inputs.rewriteAvailable,
            rewriteInFlight: inputs.rewriteInFlight,
            translateOptions: inputs.translateOptions,
            translateInFlight: inputs.translateInFlight,
            onCopy: onCopy,
            onAddToVocabulary: onAddToVocabulary,
            onPaste: onPaste,
            onUndoLastInsertion: onUndoLastInsertion,
            onRedoInsertion: onRedoInsertion,
            onToggleCleanup: onToggleCleanup,
            onRewriteSelection: onRewriteSelection,
            onTranslateOpen: onTranslateOpen,
            onTranslateSelection: onTranslateSelection,
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
            onParakeetUpgradeNudgeUpgrade: onParakeetUpgradeNudgeUpgrade,
            onParakeetUpgradeNudgeDismiss: onParakeetUpgradeNudgeDismiss,
            onVocabNudgeSetUp: onVocabNudgeSetUp,
            onVocabNudgeDismiss: onVocabNudgeDismiss,
            showCorrectionNudge: inputs.showCorrectionNudge,
            correctionAsks: inputs.correctionAsks,
            onCorrectionVerdict: onCorrectionVerdict,
            onCorrectionFinished: onCorrectionFinished,
            askDeckSnapshot: inputs.askDeckSnapshot,
            askDeckBlocksDictation: inputs.askDeckBlocksDictation,
            onAskDeckVerdict: onAskDeckVerdict,
            onAskDeckStopAsking: onAskDeckStopAsking,
            onAskDeckSkipCard: onAskDeckSkipCard,
            onAskDeckSkipAll: onAskDeckSkipAll,
            onAskDeckFinished: onAskDeckFinished,
            feedback: feedback
        )
    }
}
