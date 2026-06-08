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
/// - **`RecordAndTranscribeIntent`** (tile + catalog) — *primary* Action
///   Button binding for iOS 18+. `openAppWhenRun = false` + `AudioRecordingIntent`
///   conformance gives us the "no app bounce, Live Activity is the UI"
///   target experience. See that class's doc for the full research chain;
///   see `docs/research/action-button-interaction-palette.md` §3.A for
///   the iOS-side "blessed path" evidence.
///
/// - **`DictateIntent`** (dormant — NOT registered here, NOT in catalog) —
///   pre-`AudioRecordingIntent`-era toggle that uses `openAppWhenRun = true`
///   to force-foreground Jot for mic activation. The intent stays compiled
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
/// ## Why each shortcut keeps a single phrase
///
/// The earlier version of `DictateIntent`'s entry listed three phrases and
/// hit an iOS 26.2 Shortcuts-daemon commit bug ("Something went wrong,
/// please try again later"). Apple's sample patterns use one unambiguous
/// phrase per shortcut; doing the same here removes one dimension of
/// variability in the generated metadata and keeps the Action Button
/// binding flow reliable.
///
/// Provider is plain `struct`, not `public struct`: the provider lives in
/// the main app target and doesn't need cross-module visibility. Apple's
/// sample code uses the bare form, and the AppIntents metadata extractor
/// has historically been sensitive to access-level decoration on these
/// types.
struct JotAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        // Primary. iOS 18+ blessed path — no app bounce, Live Activity is
        // the sole UI. See `RecordAndTranscribeIntent` class doc.
        AppShortcut(
            intent: RecordAndTranscribeIntent(),
            phrases: [
                // `\(.applicationName)` is required — AppShortcuts metadata
                // validation rejects phrases without the placeholder (the
                // literal "Jot" doesn't satisfy the validator). The phrase
                // Siri matches against therefore reads "New Jot note" —
                // expressed through the placeholder so the extractor accepts it.
                "New \(.applicationName) note"
            ],
            shortTitle: "Jot down",
            // Coherent `waveform.*` family across all three Jot intents so
            // the Shortcuts picker reads as one app, not three. The mic
            // badge communicates "captures via mic, outputs transcription"
            // — the exact primary-path semantic.
            systemImageName: "waveform.badge.mic"
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
