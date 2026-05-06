import Foundation

/// Darwin-notification names and observer helpers that fan out the rewrite
/// job's terminal state from the main-app process (where
/// `RewriteWithPromptIntent.perform()` runs after `LiveActivityIntent`
/// promotion) to the keyboard extension process (which presents the result
/// or error UI).
///
/// Distinct from `Jot/Shared/CrossProcessNotification.swift`'s recording-pipeline
/// names — keeping rewrite signaling in its own namespace avoids a stray
/// pipeline-phase observer accidentally subscribing to a rewrite completion
/// event and vice versa. The transport mechanism (Darwin notify center) is
/// the same.
enum RewriteNotifications {

    /// Fired by `RewriteWithPromptIntent.perform()` whenever the rewrite job
    /// reaches a terminal state — success, error, or cancellation. Subscribers
    /// (notably the keyboard extension) read `AppGroup.rewriteResult` and
    /// `AppGroup.rewriteError` to discover which terminal branch fired.
    ///
    /// Single notification name for all three terminal cases — the slot
    /// contents disambiguate. This keeps the observer wiring on the keyboard
    /// side simple: one observer, one read of the AppGroup state.
    static let rewriteCompleted = "com.vineetu.jot.mobile.rewrite.completed"

    /// Sentinel value written into `AppGroup.rewriteError` when the user
    /// cancelled the rewrite mid-flight. The keyboard checks for an exact
    /// match before showing the error toast — a cancellation is user-driven
    /// and not a failure to surface. Both writer (intent) and reader
    /// (keyboard) reference this constant so the magic string only lives
    /// in one place.
    static let cancelledSentinel = "Cancelled"

    /// Post the rewrite-completed notification. Called by the intent after
    /// writing terminal state into the AppGroup. Cross-process delivery via
    /// the Darwin notify center is non-coalescing in `.deliverImmediately`
    /// observers, which matches the keyboard's "show result the moment the
    /// main app says it's ready" requirement.
    static func postCompleted() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(rewriteCompleted as CFString),
            nil,
            nil,
            true
        )
    }

    /// Register a Darwin observer for the rewrite-completed notification.
    /// Returns an opaque token whose deinit unregisters the observer — the
    /// caller (typically the keyboard's view-controller lifecycle) just has
    /// to hold the token for as long as it wants to receive callbacks.
    ///
    /// The handler is hopped onto `@MainActor` because callers are
    /// uniformly UI code reading `AppGroup` and updating views.
    static func addCompletedObserver(
        handler: @escaping @MainActor @Sendable () -> Void
    ) -> Observer {
        Observer(name: rewriteCompleted, handler: handler)
    }

    /// Token that registers a Darwin observer on init and removes it on
    /// deinit. Mirrors the pattern in `CrossProcessNotification.Observer` —
    /// the Darwin notify center is C-API and requires a stable opaque
    /// pointer, which `Unmanaged.passUnretained(self).toOpaque()` gives us
    /// for as long as the token is retained.
    final class Observer: @unchecked Sendable {
        private let name: String
        private let handler: @MainActor @Sendable () -> Void
        private var pointer: UnsafeMutableRawPointer {
            Unmanaged.passUnretained(self).toOpaque()
        }

        init(
            name: String,
            handler: @escaping @MainActor @Sendable () -> Void
        ) {
            self.name = name
            self.handler = handler

            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                pointer,
                Self.callback,
                name as CFString,
                nil,
                .deliverImmediately
            )
        }

        deinit {
            CFNotificationCenterRemoveObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                pointer,
                CFNotificationName(name as CFString),
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
