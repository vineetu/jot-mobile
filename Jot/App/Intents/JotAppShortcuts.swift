import AppIntents

/// Registers Jot's intents with the Shortcuts app so they show up in the
/// Shortcuts library and — critically — in the Action Button configuration
/// screen at Settings → Action Button → Shortcut → Jot.
///
/// `AppShortcutsProvider` is how iOS discovers the shortcuts a user can run
/// without manually building a Shortcuts workflow. Every `AppShortcut` here
/// gets a system-synthesized tile. The short phrases are what Siri matches
/// against; they also appear as the default label on the Action Button.
///
/// ## Registration order = priority
///
/// `AppShortcutsProvider` returns an ordered result builder. The first
/// entry is what the Action Button picker shows at the top — and in
/// practice, what users end up binding because they pick the top option.
/// The order here is therefore a de-facto "primary entry point" choice.
///
/// ## One AppShortcut tile, three intent entry points
///
/// - **`RecordAndTranscribeIntent`** (tile + catalog) — *primary* binding.
///   Uses `supportedModes = .foreground(.immediate)` to bring Jot forward and
///   DEFERS the mic-start to scene-`.active` (iOS forbids starting capture from
///   a non-foreground process — GitHub issue #3). There is a brief, unavoidable
///   app-bounce on press; that is the Apple-prescribed path (DTS
///   forums/thread/756507). See `docs/carplay/issue-3-mic-rootcause.md`.
///
/// - **`DictateIntent`** (dormant — NOT registered here, NOT in catalog) —
///   identical-shape toggle (also `supportedModes` foreground + deferred
///   scene-active start). The intent stays compiled
///   in the binary and can be revived as an Action Button tile by flipping
///   `isDiscoverable` back to `true` and re-registering an `AppShortcut`
///   here — but Apple's AppIntents metadata extractor enforces that any
///   intent used in an `AppShortcut` MUST be `isDiscoverable = true`
///   (build error: *"App Intent 'DictateIntent' must be visible for App
///   Shortcuts use"*). The two-flag split ("tile without catalog") is not
///   expressible in the Apple API, so the legacy fallback tile is retired
///   in favour of the one clean picker the user asked for.
///
/// - **`TranscribeAudioFileIntent`** (catalog only, NOT here) — composable
///   file-in/text-out step: `openAppWhenRun = false`. Designed to chain
///   inside a user-built Shortcut after the system's *Record Audio*
///   action — the upstream step owns the mic, we transcribe the resulting
///   file. NOT a recording entry point. Deliberately not registered here
///   so it doesn't clutter the Action Button picker, where "pick an audio
///   file to transcribe" would be a dead-end UX (Action Button has no
///   file argument to hand it). Intent-level `isDiscoverable = true` is
///   retained so power users can still drop it into the Shortcuts editor
///   as one step in a composed workflow — that's the *only* surface where
///   it makes sense.
///
/// If `RecordAndTranscribeIntent` ever fails to bind on a particular iOS
/// release, the OTA recovery path is: flip `DictateIntent.isDiscoverable`
/// back to `true`, add a second `AppShortcut` entry here, rebuild and ship.
/// Accepting a one-app-update latency is cheaper than shipping a picker
/// with two tiles to 100% of users for the 0% case.
///
/// ## Phrase count — the multi-phrase scar
///
/// An earlier version of `DictateIntent`'s entry listed three phrases and
/// hit an iOS 26.2 Shortcuts-daemon commit bug ("Something went wrong,
/// please try again later") that broke the WHOLE provider binding —
/// including the Action Button tile. For a while every shortcut therefore
/// carried a single phrase. The record tile now carries three close verb
/// variants again ("Jot this down" / "… it down" / "… something down") to
/// widen Siri's near-exact matching; `AskJotIntent` stays single ("Ask
/// Jot"). Because this re-enters the condition that previously broke
/// binding, the on-device gate after ANY phrase change is: the Action
/// Button must still bind AND still record. If it regresses on a given iOS
/// release, collapse the record tile back to a single phrase.
///
/// Provider is plain `struct`, not `public struct`: the provider lives in
/// the main app target and doesn't need cross-module visibility. Apple's
/// sample code uses the bare form, and the AppIntents metadata extractor
/// has historically been sensitive to access-level decoration on these
/// types.
struct JotAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        // Primary. Foregrounds Jot to record, with the mic-start deferred to
        // scene-active (GitHub issue #3). See `RecordAndTranscribeIntent` doc.
        AppShortcut(
            intent: RecordAndTranscribeIntent(),
            phrases: [
                // `\(.applicationName)` is required — AppShortcuts metadata
                // validation rejects phrases without the placeholder (the
                // literal "Jot" doesn't satisfy the validator). We lean INTO
                // that: "Jot" is also the verb, so each phrase reads as a
                // natural sentence ("Hey Siri, Jot this down") with the
                // placeholder vanishing into the verb. Three close variants
                // widen Siri's near-exact match without changing meaning.
                //
                // ⚠️ MULTI-PHRASE RISK: an earlier 3-phrase entry hit an
                // iOS 26.2 Shortcuts-daemon commit bug ("Something went wrong,
                // please try again later") that broke the WHOLE provider
                // binding — including the Action Button tile below. We may be
                // past that iOS now. On-device gate after any change here:
                // confirm the Action Button still binds AND still records. If
                // it regresses, collapse back to a single phrase.
                "\(.applicationName) this down",
                "\(.applicationName) it down",
                "\(.applicationName) something down"
            ],
            shortTitle: "Jot down",
            // Coherent `waveform.*` family across all three Jot intents so
            // the Shortcuts picker reads as one app, not three. The mic
            // badge communicates "captures via mic, outputs transcription"
            // — the exact primary-path semantic.
            systemImageName: "waveform.badge.mic"
        )

        // "Hey Siri, Ask Jot" → AskJotIntent. Headless, no mic (Siri prompts
        // for the question, AskEngine answers, Siri reads the clean spoken
        // answer back). `\(.applicationName)` placeholder is required by the
        // AppShortcuts validator (same reason as the phrase above). Single
        // phrase on purpose — added incrementally to keep the iOS-26.2
        // Shortcuts-daemon commit (which binds the WHOLE provider, including
        // the Action Button tile above) stable; the on-device gate is that
        // "Jot down" still binds + records after this is added.
        AppShortcut(
            intent: AskJotIntent(),
            phrases: [
                "Ask \(.applicationName)"
            ],
            shortTitle: "Ask your notes",
            systemImageName: "sparkle.magnifyingglass"
        )

        // NOTE: `DictateIntent` is NOT registered as an `AppShortcut` here.
        // It was previously listed as a dormant Action Button fallback, but
        // Apple's AppIntents metadata extractor enforces that every intent
        // used in an `AppShortcut` must have `isDiscoverable = true`. The
        // user asked for a single clean Action Button tile, and flipping
        // `DictateIntent.isDiscoverable = true` just to keep it here would
        // re-expose it in the Shortcuts action catalog (the tile-without-
        // catalog split is not expressible via the AppIntents API). The
        // intent still compiles in the binary and remains the OTA recovery
        // path if the primary ever fails to bind — flip `isDiscoverable`
        // back to `true` and re-register here.
        //
        // NOTE: `TranscribeAudioFileIntent` is deliberately NOT registered
        // as an `AppShortcut` here. It has a required `@Parameter audioFile:
        // IntentFile` — there's no file argument available on the Action
        // Button surface or at the top of the Shortcuts library, so a tile
        // here would bind to a dead-end "pick a file" prompt. Its intent
        // keeps `isDiscoverable = true` so power users can drop it into the
        // Shortcuts editor as a step in a composed workflow (chained after
        // the system's *Record Audio* action), which is the only surface
        // where the file-in/text-out shape makes sense.
    }
}
