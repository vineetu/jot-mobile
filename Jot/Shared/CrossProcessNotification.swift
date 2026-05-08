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
