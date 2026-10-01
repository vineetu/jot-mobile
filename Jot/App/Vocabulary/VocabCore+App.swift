import Foundation
import JotVocabCore

/// **App-side wiring for the shared `JotVocabCore` package's injection seams.**
///
/// The vocabulary-correction brains (gate, correction/provenance stores, ask
/// policy, common-words loading) now live in `JotVocabCore` (see
/// `../../jot-shared`, same no-forks rule as `JotTextPipeline`). The package is
/// a pure Foundation island; everything platform-specific crosses one of its
/// four seams. This file supplies the iOS side of all four:
///   1. engine-neutral rescore input — mapped at the rescorer call site
///      (`VocabularyRescorerHolder`), not here;
///   2. `CommonWordsProvider` — `AppVocabCore.commonWords` (loud-fail sink);
///   3. `DiagnosticsSink` — `AppVocabDiagnosticsSink` → `DiagnosticsLog`;
///   4. storage root — `AppVocabCore.containerRoot` (Application Support).
///
/// It also re-establishes the `.shared` singletons the app called before the
/// stores moved into the package (the package types are unopinionated about
/// process/paths and take injected roots/sinks), so every existing call site
/// keeps compiling unchanged.

/// Maps the package's typed diagnostics category onto the app's
/// `DiagnosticsLog.Category` (a 2-case switch — the moved code emits exactly
/// these two). Replaces the `os.Logger` + `DiagnosticsLog.record` calls that
/// the in-tree stores/gate made directly.
struct AppVocabDiagnosticsSink: JotVocabCore.DiagnosticsSink {
    func record(category: JotVocabCore.DiagnosticsCategory, message: String, metadata: [String: String]) {
        let appCategory: DiagnosticsCategory
        switch category {
        case .vocabularyGate: appCategory = .vocabularyGate
        case .vocabularySaveFailed: appCategory = .vocabularySaveFailed
        }
        DiagnosticsLog.record(source: "main-app", category: appCategory, message: message, metadata: metadata)
    }
}

/// Canonical app-process instances of the package's injected dependencies.
enum AppVocabCore {
    static let diagnostics = AppVocabDiagnosticsSink()

    /// The container root the package's `Vocabulary/…` subtree lives under.
    /// Resolves the **same** `Application Support` directory the in-tree
    /// `CorrectionStore.fileURL` / `CorrectionProvenance.fileURL` /
    /// `VocabularyStore.fileURL` used, so the package's fixed
    /// `<root>/Vocabulary/{corrections.json, provenance/, vocabulary.txt}`
    /// layout lands BYTE-IDENTICALLY on top of the existing files — zero data
    /// migration on iOS (design §3: iOS is already the unified layout).
    static let containerRoot: URL? = try? FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)

    /// The gate's common-words provider — package-resource-backed, loud-fails a
    /// missing/unreadable list through the app sink (the exact over-correction
    /// class the guard exists to prevent). Wired into `VocabularyGate.apply`
    /// at the rescorer seam.
    static let commonWords = BundledCommonWordsProvider(diagnostics: diagnostics)
}

/// The single main-app correction store (was `CorrectionStore.shared`, now the
/// package actor with the app's root + sink injected). App-sandbox only — the
/// keyboard never touches this (it reads `CorrectionBridge`).
extension CorrectionStore {
    static let shared = CorrectionStore(
        containerRoot: AppVocabCore.containerRoot, diagnostics: AppVocabCore.diagnostics,
        isCommonOriginal: AppVocabCore.isCommonOriginal)
}

extension AppVocabCore {
    /// The ONE common-original predicate (jot-shared design R9): the gate's own
    /// `VocabularyGate.isCommonOriginal` (ANY word is an everyday word) over the
    /// ACTIVE dictation language's list. Used by the store's learning guard —
    /// Jot never learns to replace an everyday word ("not → Jot") — and by the
    /// ask selection, so it never asks a question whose answer it would refuse
    /// to learn. The provider caches and locks, so this is cheap off any actor.
    @Sendable static func isCommonOriginal(_ original: String) -> Bool {
        JotVocabCore.VocabularyGate.isCommonOriginal(original, commonWords: activeCommonWords())
    }

    /// The active dictation language's everyday-word set (empty when no list
    /// ships for it — the guard then no-ops, as the gate does).
    static func activeCommonWords() -> Set<String> {
        commonWords.words(forResource: LanguageChoice.current.commonWordsResource)
    }

    private static let commonRuleMigrationKey = "jot.vocabulary.commonRuleMigrationDone"

    /// One-time (A3): drop rules learned for an everyday word before the guard
    /// existed. Marked done only when the active language has a list AND the
    /// ledger was actually read (`dropCommonOriginalRules` returns nil
    /// otherwise), so a missing list or an unreadable file retries next launch.
    static func migrateCommonOriginalRulesIfNeeded() async {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: commonRuleMigrationKey),
              !activeCommonWords().isEmpty,
              let dropped = await CorrectionStore.shared.dropCommonOriginalRules() else { return }
        defaults.set(true, forKey: commonRuleMigrationKey)
        if dropped > 0 {
            DiagnosticsLog.record(
                source: "main-app", category: .vocabularyGate,
                message: "dropped learned rules for everyday words",
                metadata: ["count": "\(dropped)"])
        }
    }
}

/// The single main-app provenance store (was `CorrectionProvenance.shared`).
extension CorrectionProvenance {
    static let shared = CorrectionProvenance(
        containerRoot: AppVocabCore.containerRoot, diagnostics: AppVocabCore.diagnostics)
}

/// **Learn from Corrections** (jot-shared `VocabularyLearning`, Mac 1.23): the
/// one correction path. Every surface — transcript Edit → Save, Add to
/// Vocabulary (in-app and keyboard-queued), the review list, the keyboard ask
/// deck's verdicts, Settings sounds-like chips, Find & Replace's learn offer,
/// teach-by-voice — describes what the user did as a `Correction` and calls
/// `VocabularyLearning.shared.apply`. Nothing else writes a sounds-like or the
/// store's learning counters.
extension VocabularyLearning {
    @MainActor static let shared = VocabularyLearning(
        list: VocabularyStore.shared, store: CorrectionStore.shared)
}

extension AppVocabCore {
    /// Whether the active dictation language ships an everyday-word list.
    /// Learn-from-edits runs only when it does (no D8 brake ⇒ every edit would
    /// teach), the same rule the model-free corrector follows.
    static var hasActiveCommonWords: Bool { !activeCommonWords().isEmpty }

    private static let editPairMigrationKey = "jot.vocabulary.editPairsInListMigrationDone"

    /// One-time (Revision 2 review #1): pairs learned from transcript edits
    /// before the list became the only home of corrections are written into it
    /// as sounds-likes. Marked done only when the list and corrections.json were
    /// both read (`migrateEditLearnedPairs` returns nil otherwise → retry).
    @MainActor
    static func migrateEditLearnedPairsIfNeeded() async {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: editPairMigrationKey),
              let added = await VocabularyLearning.shared.migrateEditLearnedPairs() else { return }
        defaults.set(true, forKey: editPairMigrationKey)
        if added > 0 {
            DiagnosticsLog.record(
                source: "main-app", category: .vocabularyGate,
                message: "moved edit-learned pairs into the vocabulary list",
                metadata: ["count": "\(added)"])
        }
    }
}
