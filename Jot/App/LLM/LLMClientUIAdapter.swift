import Foundation
import Observation
import os.log

/// `@MainActor` SwiftUI adapter wrapping an underlying `LLMClient`.
///
/// ## Why this exists
///
/// The `LLMClient` protocol exposes its lifecycle status as
/// `var status: LLMClientStatus { get async }` — backend-agnostic and
/// non-`@MainActor` so concrete clients can manage their state without
/// forcing every caller through MainActor. SwiftUI views, however,
/// want a synchronous, observable property to drive download /
/// loading / ready / error rows without `await` ceremony.
///
/// `LLMClientUIAdapter` bridges the two:
///   - Owns a polling/streaming task that mirrors the underlying
///     client's `status` into a MainActor-isolated `@Observable`
///     `observableStatus` property.
///   - Exposes `cancelDownload()` for the settings UI's cancel button.
///   - Settings views observe `observableStatus` directly — no
///     `await` in the view body.
///
/// Currently the only concrete `LLMClient` is `Phi4Client`
/// (MLX-backed Phi-4-mini-instruct-4bit), but the adapter shape is
/// preserved so future provider work can swap in without rewriting the
/// settings UI.
///
/// ## Status mirror semantics
///
/// On `start(pollingInterval:)`, the adapter spawns a Task that loops:
///   1. `await client.status` to read the current value.
///   2. If different from `observableStatus`, hop to MainActor and
///      update the published value.
///   3. Sleep for `pollingInterval` (default 250 ms — fast enough to
///      surface download fraction updates smoothly, slow enough to
///      avoid contending with the underlying actor).
///   4. Repeat until the task is cancelled.
///
/// We deliberately use polling rather than an `AsyncStream` from each
/// client: it lets us keep `LLMClient` minimal (no stream channel
/// requirement on the protocol), and 250 ms is well under any UI
/// refresh budget for the rows the settings view renders.
///
/// ## Concurrency
///
/// Class is `@MainActor`-isolated; `@Observable` macro emits
/// MainActor-safe property accessors. The polling Task is detached so
/// the `await client.status` call doesn't pin the MainActor. Updates
/// hop back to MainActor via `Task { @MainActor in ... }` for the
/// observable mutation.
@available(iOS 26.0, *)
@MainActor
@Observable
final class LLMClientUIAdapter {

    @ObservationIgnored
    private let log = Logger(
        subsystem: "com.vineetu.jot.mobile.Jot",
        category: "LLMClientUIAdapter"
    )

    /// Mirror of the underlying client's `status`, refreshed by the
    /// polling task at `pollingInterval` cadence. `.notReady` until the
    /// first poll completes.
    private(set) var observableStatus: LLMClientStatus = .notReady

    /// Underlying client. Reference identity matters: the factory
    /// returns the same `LLMClient` instance across calls in normal
    /// flow, and the adapter holds a strong reference for the lifetime
    /// of the SwiftUI view.
    @ObservationIgnored
    let client: any LLMClient

    @ObservationIgnored
    private var pollingTask: Task<Void, Never>?

    @ObservationIgnored
    private let pollingInterval: UInt64

    /// - Parameters:
    ///   - client: the `LLMClient` to mirror.
    ///   - pollingIntervalMillis: how often to poll `client.status`.
    ///     Default 250 ms.
    init(client: any LLMClient, pollingIntervalMillis: UInt64 = 250) {
        self.client = client
        self.pollingInterval = pollingIntervalMillis * 1_000_000
        // Kick off an immediate one-shot read so the first SwiftUI render
        // doesn't see stale `.notReady` before the polling task's first
        // tick. Detached so we don't block init on the underlying
        // client's actor.
        Task { [weak self] in
            await self?.refreshOnce()
        }
    }

    deinit {
        pollingTask?.cancel()
    }

    /// Begin the background mirror task. Idempotent: a running task is
    /// reused. Safe to call from `.task { ... }` modifiers.
    func start() {
        if pollingTask != nil { return }
        let interval = pollingInterval
        let client = self.client
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                let next = await client.status
                if let self {
                    await MainActor.run {
                        if self.observableStatus != next {
                            self.observableStatus = next
                        }
                    }
                }
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    /// Cancel the background mirror task. Called when the settings
    /// view disappears so we don't keep polling on a hidden screen.
    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// One-shot status read used to seed `observableStatus` before the
    /// polling task's first tick.
    private func refreshOnce() async {
        let next = await client.status
        await MainActor.run {
            if observableStatus != next {
                observableStatus = next
            }
        }
    }

    /// Forward a download/warm cancel into the underlying client.
    ///
    /// Both `Phi4Client.cancelDownload()` and `Qwen35Client.cancelDownload()`
    /// halt an in-flight HuggingFace download or load and drop back to
    /// `.notReady`. The protocol itself doesn't require this method — only
    /// download-capable backends expose it — so we accept a runtime cast
    /// and log a no-op for any future client that doesn't implement cancel.
    func cancelDownload() {
        if let qwen = client as? Qwen35Client {
            qwen.cancelDownload()
            return
        }
        if let phi4 = client as? Phi4Client {
            phi4.cancelDownload()
            return
        }
        log.info("cancelDownload: client \(String(describing: type(of: self.client)), privacy: .public) does not support cancel")
    }

    /// Trigger the underlying client's `warm()` lifecycle — used by the
    /// settings UI's "Download" CTA. Errors are logged but not re-thrown
    /// because the underlying client is already responsible for
    /// transitioning its `status` to `.error(...)` on failure, and the
    /// SwiftUI row reads that status to render the failure UI.
    ///
    /// Idempotent: a second call while warm is in flight joins the
    /// existing warm Task at the client layer.
    func warm() {
        let client = self.client
        Task {
            do {
                try await client.warm()
            } catch is CancellationError {
                // User cancelled or app backgrounded — silent.
            } catch {
                self.log.error("warm failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Drop the in-memory model. The underlying client transitions to
    /// `.evicted` (weights still on disk) or `.notReady` (no weights).
    /// This is the lighter-weight "free RAM" affordance. For full
    /// disk purge use `deleteModel()`.
    func evict() {
        let client = self.client
        Task { await client.evict() }
    }

    /// Drop in-memory state. Phi-4 weights live in the HuggingFace cache
    /// directory managed by the MLX bridge — the client doesn't expose a
    /// disk-purge entry point, so we fall back to a plain `evict()` here.
    /// The settings UI can hide the "Delete model" affordance for Phi-4
    /// or surface this as "Free memory" instead.
    func deleteModel() {
        let client = self.client
        Task { await client.evict() }
    }
}
