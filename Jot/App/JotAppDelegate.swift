import BackgroundTasks
import Foundation
import UIKit
import os.log

private let backgroundWarmLog = Logger(subsystem: "com.jot.mobile.Jot", category: "background-warm")

final class JotAppDelegate: NSObject, UIApplicationDelegate {
    static let backgroundWarmTaskIdentifier = "com.jot.mobile.Jot.warm-parakeet"

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.backgroundWarmTaskIdentifier,
            using: nil
        ) { task in
            guard let processingTask = task as? BGProcessingTask else {
                backgroundWarmLog.error(
                    "BG warm launch handler received unexpected task type for identifier=\(Self.backgroundWarmTaskIdentifier, privacy: .public)"
                )
                task.setTaskCompleted(success: false)
                return
            }
            self.handleBackgroundWarmTask(processingTask)
        }

        if registered {
            backgroundWarmLog.info(
                "BG warm register success — identifier=\(Self.backgroundWarmTaskIdentifier, privacy: .public)"
            )
        } else {
            backgroundWarmLog.error(
                "BG warm register failure — identifier=\(Self.backgroundWarmTaskIdentifier, privacy: .public)"
            )
        }

        self.submitBackgroundWarmTask(reason: "launch")
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        self.submitBackgroundWarmTask(reason: "didEnterBackground")
    }

    private func handleBackgroundWarmTask(_ task: BGProcessingTask) {
        backgroundWarmLog.info(
            "BG warm task launched — identifier=\(Self.backgroundWarmTaskIdentifier, privacy: .public)"
        )
        self.submitBackgroundWarmTask(reason: "handler")

        let warmTask = Task { @MainActor in
            await TranscriptionService.shared.warmUpInBackground()
        }

        task.expirationHandler = {
            backgroundWarmLog.notice(
                "BG warm expired — identifier=\(Self.backgroundWarmTaskIdentifier, privacy: .public)"
            )
            warmTask.cancel()
            Task { @MainActor in
                TranscriptionService.shared.cancelBackgroundWarm()
            }
        }

        Task {
            let success = await warmTask.value
            task.setTaskCompleted(success: success)
            backgroundWarmLog.info("BG warm completed success=\(success, privacy: .public)")
        }
    }

    private func submitBackgroundWarmTask(reason: String) {
        let request = BGProcessingTaskRequest(identifier: Self.backgroundWarmTaskIdentifier)
        request.requiresExternalPower = false
        request.requiresNetworkConnectivity = false

        do {
            try BGTaskScheduler.shared.submit(request)
            backgroundWarmLog.info(
                "BG warm submit success — identifier=\(Self.backgroundWarmTaskIdentifier, privacy: .public) reason=\(reason, privacy: .public)"
            )
            if reason == "handler" {
                backgroundWarmLog.info(
                    "BG warm resubmitted — identifier=\(Self.backgroundWarmTaskIdentifier, privacy: .public)"
                )
            }
        } catch {
            backgroundWarmLog.error(
                "BG warm submit failure — identifier=\(Self.backgroundWarmTaskIdentifier, privacy: .public) reason=\(reason, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
