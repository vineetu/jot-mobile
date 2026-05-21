import Foundation

enum CrossProcessNotification {
    struct Name: RawRepresentable, Sendable, Equatable {
        let rawValue: String

        init(rawValue: String) {
            self.rawValue = rawValue
        }
    }

    static let stopRequested = Name(
        rawValue: "com.vineetu.jot.mobile.recording-stop-requested"
    )

    static let transcriptReady = Name(
        rawValue: "com.vineetu.jot.mobile.transcript-ready"
    )

    static let pipelinePhaseChanged = Name(
        rawValue: "com.vineetu.jot.mobile.pipeline-phase-changed"
    )

    static let streamingPartialChanged = Name(
        rawValue: "com.vineetu.jot.mobile.streaming-partial-changed"
    )

    /// Posted by the main app's `StreamingTranscriptionService` whenever
    /// `sessionLoadState` flips (`.idle` ↔ `.loading` ↔ `.ready`).
    /// Observed by the keyboard extension to re-read
    /// `AppGroup.streamingLoadingActive` and re-render the streaming
    /// strip's "Loading [variant]…" placeholder accordingly.
    static let streamingLoadingChanged = Name(
        rawValue: "com.vineetu.jot.mobile.streaming-loading-changed"
    )

    /// Posted by the main app AFTER `TranscriptHistoryMirror.refresh(...)`
    /// completes a write to the App Group JSON mirror. Distinct from
    /// `transcriptReady`, which the dictation pipeline posts BEFORE the
    /// SwiftData append + mirror write run (publish-first contract — see
    /// `DictationPipeline.swift`). Keyboard observers that need to see the
    /// latest history rows must listen here, not on `transcriptReady`, or
    /// they will reload a mirror that hasn't been updated yet and end up
    /// rendering stale recents until the next presentation.
    static let historyMirrorUpdated = Name(
        rawValue: "com.vineetu.jot.mobile.history-mirror-updated"
    )

    /// Posted by the keyboard extension when the user taps the Dictate
    /// (mic CTA) pill AND the host app is detected as Jot itself
    /// (typically: setup wizard W5 keyboard-try step). iOS silently refuses
    /// `extensionContext.open` for the already-foreground app, so the
    /// keyboard cannot route the tap through the normal `jot://dictate`
    /// URL bounce in this case — without this notification, the tap
    /// appears to do nothing. The main app's wizard observer treats this
    /// as proof the user can find the Dictate pill and advances W5 → W6.
    /// See `JotKeyboardViewController.handleMicCTATap` for the host-app
    /// detection (App Group foreground heartbeat) and `SetupWizardView`
    /// for the wizard wiring.
    static let keyboardDictateTapped = Name(
        rawValue: "com.vineetu.jot.mobile.keyboard-dictate-tapped"
    )

    /// Posted by the keyboard extension when the user taps Dictate AND the
    /// warm-hold window (`AppGroup.warmHoldExpiresAt`) is in the future. The
    /// main app's observer calls `RecordingService.start()` which takes the
    /// warm fast-path (`engine.start()` on the paused engine). Distinct from
    /// `keyboardDictateTapped` -- that one signals "user found the pill during
    /// wizard W5" and the wizard observer advances. `warmResumeRequested`
    /// signals "recording should resume now via the warm path".
    static let warmResumeRequested = Name(
        rawValue: "com.vineetu.jot.mobile.warm-resume-requested"
    )

    static func post(name: Name) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name.rawValue as CFString),
            nil,
            nil,
            true
        )
    }

    static func addObserver(
        name: Name,
        handler: @escaping @MainActor @Sendable () -> Void
    ) -> Observer {
        Observer(name: name, handler: handler)
    }

    final class Observer: @unchecked Sendable {
        private let name: Name
        private let handler: @MainActor @Sendable () -> Void
        private var pointer: UnsafeMutableRawPointer {
            Unmanaged.passUnretained(self).toOpaque()
        }

        init(name: Name, handler: @escaping @MainActor @Sendable () -> Void) {
            self.name = name
            self.handler = handler

            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                pointer,
                Self.callback,
                name.rawValue as CFString,
                nil,
                .deliverImmediately
            )
        }

        deinit {
            CFNotificationCenterRemoveObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                pointer,
                CFNotificationName(name.rawValue as CFString),
                nil
            )
        }

        private static let callback: CFNotificationCallback = { _, observer, _, _, _ in
            guard let observer else { return }
            let token = Unmanaged<Observer>.fromOpaque(observer).takeUnretainedValue()

            Task { @MainActor in
                token.handler()
            }
        }
    }
}
