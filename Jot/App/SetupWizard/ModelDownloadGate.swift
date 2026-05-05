import Foundation
import Network
import os.log

/// Observes the current network path so the setup wizard can show
/// "Currently on Wi-Fi / cellular / offline" and decide whether the
/// 948 MB speech-model download is allowed to start without an
/// explicit cellular opt-in.
///
/// Lives on `@MainActor` so SwiftUI can bind directly to its
/// `@Observable` properties. `NWPathMonitor`'s callbacks are dispatched
/// on a private background queue and bridge back to the main actor
/// via `Task { @MainActor in ... }`.
@MainActor
@Observable
final class ModelDownloadGate {
    enum NetworkType: Equatable {
        case wifi
        case cellular
        case wired
        case other
        case unavailable

        var displayName: String {
            switch self {
            case .wifi: return "Wi-Fi"
            case .cellular: return "Cellular"
            case .wired: return "Wired"
            case .other: return "Network"
            case .unavailable: return "Offline"
            }
        }

        var isWiFiOrWired: Bool {
            self == .wifi || self == .wired
        }
    }

    private(set) var networkType: NetworkType = .unavailable
    var allowCellular: Bool = false

    /// True when the user-tapped download is allowed to begin under the
    /// current network conditions (Wi-Fi / wired always; cellular only
    /// when the user has explicitly opted in via `allowCellular`).
    var canStartDownload: Bool {
        switch networkType {
        case .wifi, .wired, .other:
            return true
        case .cellular:
            return allowCellular
        case .unavailable:
            return false
        }
    }

    @ObservationIgnored
    private let monitor: NWPathMonitor
    @ObservationIgnored
    private let monitorQueue = DispatchQueue(
        label: "com.vineetu.jot.mobile.Jot.model-download-gate",
        qos: .utility
    )
    @ObservationIgnored
    private var started = false
    @ObservationIgnored
    private let log = Logger(subsystem: "com.vineetu.jot.mobile.Jot", category: "model-download-gate")

    init() {
        self.monitor = NWPathMonitor()
    }

    deinit {
        monitor.cancel()
    }

    /// Idempotent. Repeat calls are no-ops.
    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let resolved = Self.resolveNetworkType(from: path)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.networkType = resolved
                self.log.info("network type changed — type=\(resolved.displayName, privacy: .public)")
            }
        }
        monitor.start(queue: monitorQueue)
    }

    private nonisolated static func resolveNetworkType(from path: NWPath) -> NetworkType {
        guard path.status == .satisfied else { return .unavailable }
        if path.usesInterfaceType(.wifi) { return .wifi }
        if path.usesInterfaceType(.wiredEthernet) { return .wired }
        if path.usesInterfaceType(.cellular) { return .cellular }
        return .other
    }
}
