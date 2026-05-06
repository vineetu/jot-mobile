# Phi-4-mini integration spec (v2) — iOS Jot

A future-PR-ready integration plan for slotting `Phi4MiniClient` next to `AppleIntelligenceClient` once v1's `LLMClient` protocol lands.

---

## 1. Repo state survey

**Confirmed.** `LLMClient`-shaped code in `/Users/vsriram/code/jot-mobile/Jot/` lives in exactly one place today: `Jot/App/Cleanup/CleanupService.swift` (429 lines). It is `@MainActor @Observable`, currently couples Foundation Models directly (`import FoundationModels`, `LanguageModelSession`), and exposes two operations: `clean(transcript:instructions:)` (lines 122-163) and `resolveUtterance(new:priorTranscript:)` (lines 290-341, used for the chained-follow-up command path). There is no protocol abstraction yet — v1 will add `LLMClient` and refactor `CleanupService` into the first conformer (`AppleIntelligenceClient`). Callsites that v1 will need to update: `App/JotApp.swift:74`, `App/Intents/DictateIntent.swift:412/431/488`, `App/Intents/DictationPipeline.swift:150`, `App/Intents/DictationPostProcessingCoordinator.swift:54/64`, `App/Intents/TranscribeAudioFileIntent.swift:239-240`, plus `Tests/CleanupServiceCommandLibraryTests.swift`.

**Confirmed (corrected).** `prototypes/dual-model-prototype/` does exist, but it is **not** a Phi-4 prototype. It validates dual ASR (Parakeet TDT 0.6B v2 + Parakeet EOU 120M streaming) co-residency on iPhone 17 — see `prototypes/dual-model-prototype/README.md`. No prior Phi-4 / MLX prototype exists.

**Confirmed.** Zero MLX usage in the iOS repo today: `grep -ri "MLX\|mlx-swift\|import MLX" /Users/vsriram/code/jot-mobile/Jot/` returned nothing. v2 is a greenfield SPM addition.

**Confirmed.** macOS reference `/Users/vsriram/code/jot/Sources/LLM/`:

| File | Owns |
|---|---|
| `LLMClient.swift` | Provider-neutral actor: routes `transform`/`rewrite` to either Apple Intelligence (short-circuit, lines 71-83) or HTTP providers; centralizes prompt composition and error mapping. |
| `AppleIntelligenceClienting.swift` | The protocol seam (`Sendable` actor-friendly), 3 ops: `transform`, `rewrite`, `streamChat` + `nonisolated var isAvailable`. |
| `AppleIntelligenceClient.swift` | Live conformer — actor wrapping `FoundationModels.LanguageModelSession`. |
| `LLMPrompts.swift` | `TransformPrompt.default`, `RewritePrompt.default` (the shared-invariants string starting "You rewrite a selection of the user's text…", line 57-59), `RewriteBranchPrompt`. |
| `RewriteInstructionClassifier.swift` | Regex-based 4-way branch classifier (voice / structural / translation / code). |
| `LLMConfiguration.swift`, `LLMProvider.swift`, `LLMConfigMigration.swift`, `LLMError.swift` | Provider enum + persisted config + error type. |
| `AIService.swift`, `GroundingDocFacts.swift` | Ask Jot only — out of scope for iOS v2. |

The iOS v2 abstraction will be smaller than the macOS one (no HTTP providers, no streaming for the rewrite path), but the protocol shape and prompt composition are direct ports.

---

## 2. SPM dependency drop-in

**Library:** `mlx-swift-lm` (`https://github.com/ml-explore/mlx-swift-lm`), v3.x line. The 3.x release split the 2.x monolith into core + adapters; iOS Jot is greenfield so we land on 3.x directly. Confirmed via Context7 docs: 3.x requires three packages, not one.

**Version pin recommendation.** `from: "3.0.0"`. The library tagged 3.0.0 at the start of the 3.x line; pinning floor-only follows the Jot iOS convention of letting minor/patch float for upstream fixes. (FluidAudio in `Jot/project.yml:23-25` uses `exactVersion: "0.13.6"` — that's a pre-1.0 library where minor bumps are breaking. mlx-swift-lm at 3.x has stable semver.) **Confidence: Likely** — verify the exact tag at v2 PR time; if a 3.x release introduces breaking changes mid-cycle, switch to `exactVersion`.

**`project.yml` patch (main app target only — the keyboard's ~60 MB ceiling and widget's ~30 MB ceiling cannot host a 2.6 GB working set):**

```yaml
packages:
  FluidAudio:
    url: https://github.com/FluidInference/FluidAudio
    exactVersion: "0.13.6"
  MLXSwiftLM:
    url: https://github.com/ml-explore/mlx-swift-lm
    from: "3.0.0"
  SwiftHuggingFaceMLX:
    url: https://github.com/DePasqualeOrg/swift-hf-api-mlx
    from: "0.2.0"
  SwiftTokenizersMLX:
    url: https://github.com/DePasqualeOrg/swift-tokenizers-mlx
    from: "0.2.0"
```

In `targets.Jot.dependencies`:

```yaml
    dependencies:
      - package: FluidAudio
        product: FluidAudio
      - package: MLXSwiftLM
        product: MLXLLM
      - package: MLXSwiftLM
        product: MLXLMCommon
      - package: SwiftHuggingFaceMLX
        product: MLXLMHuggingFace
      - package: SwiftTokenizersMLX
        product: MLXLMTokenizers
      - sdk: AppIntents.framework
      - sdk: BackgroundTasks.framework
      - target: JotKeyboard
      - target: JotWidget
```

**Confidence: Likely** on the exact product names in the adapter packages — the 3.x upgrade doc names them `MLXLMHuggingFace` / `MLXLMTokenizers` per Context7. The 3.x docs show two slightly different import incantations (`MLXLMHFAPI` vs `MLXLMHuggingFace`); resolve at PR time by reading the package's actual `Package.swift`.

---

## 3. `Phi4MiniClient.swift` draft

Drop-in file at `/Users/vsriram/code/jot-mobile/Jot/App/LLM/Phi4MiniClient.swift` (new directory). Mirrors the `TranscriptionService` patterns: `@MainActor @Observable` singleton, App Support cache, `handleMemoryWarning()` evicting the model handle, simulator stand-in, status reporting through a `LLMClientStatus` projection.

Protocol shape:

```swift
protocol LLMClient: Sendable {
    var status: LLMClientStatus { get }
    func rewrite(text: String, instructions: String, sharedInvariants: String) async throws -> String
}

enum LLMClientStatus: Sendable {
    case ready
    case downloading(fraction: Double)
    case loading
    case unavailable(reason: String)
}
```

Phi4MiniClient body (excerpted core):

```swift
import Foundation
import UIKit
import os.log

#if !targetEnvironment(simulator)
import MLX
import MLXLLM
import MLXLMCommon
import MLXLMHuggingFace
import MLXLMTokenizers
#endif

@MainActor
@Observable
final class Phi4MiniClient: LLMClient {

    private(set) var status: LLMClientStatus = .unavailable(reason: "Not loaded")

    func rewrite(
        text: String,
        instructions: String,
        sharedInvariants: String
    ) async throws -> String {
        #if targetEnvironment(simulator)
        try await Task.sleep(for: .milliseconds(800))
        return "[Phi-4 simulator stand-in] \(text)"
        #else
        let container = try await ensureLoaded()
        let userPrompt = """
            <instruction>
            \(instructions)
            </instruction>

            <selection>
            \(text)
            </selection>

            Follow the <instruction> above. Rewrite the <selection> and \
            return only the rewritten text.
            """

        let session = ChatSession(
            container,
            instructions: sharedInvariants,
            generateParameters: GenerateParameters(maxTokens: 1024, temperature: 0.1)
        )
        defer { Task { await session.clear() } }

        do {
            try Task.checkCancellation()
            let response = try await session.respond(to: userPrompt)
            let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? text : trimmed
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw LLMError.generationFailed(error.localizedDescription)
        }
        #endif
    }

    @MainActor static let shared = Phi4MiniClient()
    static let modelID = "mlx-community/Phi-4-mini-instruct-4bit"
    private static var didCapGPUCache = false
    #if !targetEnvironment(simulator)
    private var container: ModelContainer?
    private var loadTask: Task<ModelContainer, Error>?
    #endif
    private static let idleEvictDelay: Duration = .seconds(60)

    #if !targetEnvironment(simulator)
    private func ensureLoaded() async throws -> ModelContainer {
        if let container { scheduleIdleEvict(); return container }
        if let loadTask { return try await loadTask.value }

        if !Self.didCapGPUCache {
            MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)
            Self.didCapGPUCache = true
        }

        status = .downloading(fraction: 0)
        let task = Task<ModelContainer, Error> { [weak self] in
            let container = try await LLMModelFactory.shared.loadContainer(
                from: HubClient.default,
                using: TokenizersLoader(),
                configuration: ModelConfiguration(id: Self.modelID),
                progressHandler: { progress in
                    Task { @MainActor [weak self] in
                        let f = max(0, min(1, progress.fractionCompleted))
                        if case .downloading = self?.status {
                            self?.status = .downloading(fraction: f)
                        }
                    }
                }
            )
            return container
        }
        loadTask = task

        do {
            status = .loading
            let container = try await task.value
            self.container = container
            self.loadTask = nil
            self.status = .ready
            scheduleIdleEvict()
            return container
        } catch {
            self.loadTask = nil
            self.status = .unavailable(reason: error.localizedDescription)
            throw error
        }
    }
    #endif

    func evict() {
        #if !targetEnvironment(simulator)
        guard container != nil else { return }
        container = nil
        loadTask = nil
        idleEvictTask?.cancel()
        idleEvictTask = nil
        MLX.GPU.clearCache()
        status = .unavailable(reason: "Evicted")
        #endif
    }
}
```

API citations (Confirmed via Context7 `/ml-explore/mlx-swift-lm`):
- `LLMModelFactory.shared.loadContainer(from:using:configuration:progressHandler:)`
- `HubClient.default`, `TokenizersLoader()`
- `ChatSession(_:instructions:generateParameters:)`
- `GenerateParameters(maxTokens:temperature:)`
- `session.respond(to:)` returns `String`
- Eviction by `container = nil`
- `MLX.GPU.set(cacheLimit:)` / `MLX.GPU.clearCache()` — **Likely** / **Unknown** whether 3.x renamed it

---

## 4. Co-residency / eviction handshake

1.25 GB Parakeet + 2.6 GB Phi-4 ≈ 3.9 GB working set. iPhone 15 Pro 8 GB RAM, per-app jetsam ~3 GB without entitlement. Eviction is the contract.

```swift
extension TranscriptionService {
    func evictModel() {
        guard !isTranscribing else {
            log.notice("evictModel deferred — transcription in flight")
            return
        }
        guard manager != nil else { return }
        log.notice("Parakeet evicted by LLM handshake (~1.25 GB freed)")
        manager = nil
        prepareTask = nil
        modelState = .notLoaded
    }
}
```

Integration:

```swift
@MainActor
func runRewrite(rawTranscript: String, settings: CleanupSettings) async throws -> String {
    let provider = settings.provider
    if provider == .phi4Mini {
        TranscriptionService.shared.evictModel()
        let result = try await Phi4MiniClient.shared.rewrite(
            text: rawTranscript,
            instructions: settings.instructions,
            sharedInvariants: settings.sharedInvariants
        )
        TranscriptionService.shared.warmUp()
        return result
    } else {
        return try await AppleIntelligenceClient.shared.rewrite(...)
    }
}
```

Re-warm cost: ~10 s cold-start. Phi-4 self-evicts on `UIApplication.didReceiveMemoryWarningNotification` AND after 60 s idle.

**Confidence: Likely** — needs field tuning of the 60s idle window.

---

## 5. Settings UI delta

```swift
enum LLMProvider: String, Codable, CaseIterable, Sendable {
    case foundationModels
    case phi4Mini

    var displayName: String {
        switch self {
        case .foundationModels: return "Apple Intelligence"
        case .phi4Mini: return "Phi-4 mini (local, 2.2 GB)"
        }
    }
}
```

SettingsView snippet:

```swift
Section {
    Picker("Provider", selection: $settings.provider) {
        ForEach(LLMProvider.allCases, id: \.self) { provider in
            Text(provider.displayName)
                .tag(provider)
                .disabled(provider == .phi4Mini && !phi4Client.status.isReady)
        }
    }

    if settings.provider == .phi4Mini || phi4Client.status != .unavailable(reason: "Not loaded") {
        LabeledContent {
            HStack(spacing: 8) {
                Image(systemName: phi4StatusSymbol)
                    .foregroundStyle(phi4StatusColor)
                Text(phi4StatusText)
                    .foregroundStyle(.secondary)
            }
        } label: { Text("Phi-4 status") }

        if case .unavailable = phi4Client.status {
            Button {
                Task { try? await phi4Client.warmUp() }
            } label: {
                Label("Download Phi-4 (2.2 GB)", systemImage: "arrow.down.circle")
            }
        }
    }
} header: {
    Text("Rewrite")
} footer: {
    Text("Phi-4 runs entirely on this iPhone over Wi-Fi-free Metal/GPU. Larger and slower than Apple Intelligence; 2.2 GB download.")
}
```

---

## 6. Entitlement + provisioning

`com.apple.developer.kernel.increased-memory-limit` — **NOT required** for v2 launch. Eviction caps peak at ~2.8 GB, just under the 3 GB jetsam ceiling. **Confidence: Likely** — needs measurement.

App Store framing: opt-in, explicit-tap download. Privacy nutrition note: "Optional 2.16 GB local model download from Hugging Face. No user content is transmitted."

---

## 7. Effort + risk recap

**~560 LOC delta.** Files: project.yml, SettingsView.swift, CleanupSettings.swift, TranscriptionService.swift (+evictModel), DictationPipeline.swift modified; Phi4MiniClient.swift, LLMClient.swift, Phi4MiniClientTests.swift created.

**Top 3 risks:**
1. **Memory pressure jetsam** under sustained Phi-4 use (High × High). 60s idle eviction may be too generous.
2. **MLX-Swift API drift** between research and PR time (Medium × Medium). Verify symbols at PR time.
3. **First-rewrite latency reads as "broken"** (Medium × High). Mitigation: speculative warm on `.recording` start.

**5-step smoke test:** cold download, first rewrite + eviction handshake, memory ceiling under co-residency, memory-warning eviction, provider toggle round-trip.

---

## Ready to ship when…

…v1 has landed (`LLMClient` protocol + `AppleIntelligenceClient` conformer + provider picker shipped); the macOS Jot rewrite-prompts patterns have been ported to iOS; `mlx-swift-lm` 3.x has been verified; on-device memory measurements on iPhone 15 Pro have empirically confirmed peak working set stays under the ~3 GB jetsam ceiling with Parakeet evicted; and the App Store privacy disclosure draft has been reviewed against the existing Parakeet disclosure pattern.
