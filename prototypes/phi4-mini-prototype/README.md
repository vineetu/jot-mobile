# Phi4MiniPrototype

Standalone iOS prototype to validate `mlx-swift-lm` 3.31.3 + `mlx-community/Phi-4-mini-instruct-4bit` (3.8 B params, Q4, ~2.16 GB) running on-device via Metal/MLX. The goal is to de-risk a future production integration into the Jot iOS dictation app — verifying SPM resolution, the audit-corrected MLX API surface, real download/load behavior, tokens-per-second throughput, and peak RAM headroom on iPhone 15 Pro+ before committing to it inside the main app.

## Setup

```sh
cd /Users/vsriram/code/jot-mobile/prototypes/phi4-mini-prototype
xcodegen generate
open Phi4MiniPrototype.xcodeproj
```

Pins:
- `mlx-swift-lm` 3.31.3 — products `MLXLLM`, `MLXLMCommon`, `MLXHuggingFace` (the macro library)
- `huggingface/swift-huggingface` `0.9.0..<1.0.0` — exports `HuggingFace` for `HubClient` + `Repo.ID`
- `huggingface/swift-transformers` `1.3.0..<2.0.0` — exports `Tokenizers` for `AutoTokenizer`

### Why the macro path instead of the DePasquale adapters

The original audit-corrected list had us pulling `swift-hf-api-mlx` (`MLXLMHFAPI`) and `swift-tokenizers-mlx` (`MLXLMTokenizers`) as the integration packages — both work, but the macro path keeps the dependency graph smaller (no Rust binary trait machinery in `swift-tokenizers`) and matches mlx-swift-lm's documented "parity with 2.x" entry point. The `#hubDownloader()` and `#huggingFaceTokenizerLoader()` freestanding macros from `MLXHuggingFace` expand at compile time into thin adapters around `HuggingFace.HubClient` and `Tokenizers.AutoTokenizer` respectively.

Bundle id `com.vineetu.jot.mobile.Jot.Phi4Prototype`, team `8VB2ULDN22`, deployment target iOS 26.0, Swift 6 strict concurrency.

## Run

1. Pick a real iPhone 15 Pro (or newer) as the run destination. Simulator is supported only as a UI smoke test — it returns a `[simulator stand-in]` string and does not actually run inference, since MLX requires Metal.
2. First time only: tap **Download Phi-4 (2.2 GB)**. This pulls weights from `mlx-community/Phi-4-mini-instruct-4bit` via the `HubClient.default` foreground URLSession. Expect ~3–8 minutes on a fast Wi-Fi connection.
3. Status will move `Not downloaded → Downloading XX% → Loading → Ready`.
4. Edit the system prompt, instruction, and input transcript inline (defaults are seeded for the rewrite-spoken-selection use case).
5. Tap **Run Rewrite**. The output and last-run stats panel populate when generation completes.
6. **Evict model** drops the in-memory container and clears the MLX cache so the next run pays a cold-load penalty — useful for repeating timing measurements.

## What this prototype is validating

1. **SPM resolution** — `mlx-swift-lm` 3.31.3 plus `huggingface/swift-huggingface` 0.9 and `huggingface/swift-transformers` 1.3 resolve into a buildable graph for `iOS 26.0` with Swift 6 strict concurrency, and the `MLXHuggingFaceMacros` macro plugin compiles inside the same dependency tree.
2. **API surface** — the macro entry points (`#hubDownloader()`, `#huggingFaceTokenizerLoader()`) plus `LLMModelFactory.shared.loadContainer(from:using:configuration:progressHandler:)`, `ChatSession(_:instructions:generateParameters:)`, `session.streamResponse(to:)`, `Memory.cacheLimit`, `Memory.clearCache()` all compile and link.
3. **Download flow** — the macro-expanded HubClient adapter pulls the Phi-4-mini snapshot from Hugging Face and `LLMModelFactory.shared.loadContainer` materializes a usable `ModelContainer`.
4. **Tokens/sec** — measured via `streamResponse(...)` with TTFT and total time, plus a tokenizer-based output-token count from `container.perform { ctx.tokenizer.encode(...) }`.
5. **RAM peak** — `os_proc_available_memory()` is sampled every 100 ms during a run; the stats panel shows baseline-min delta in MB. Memory ticker on the main screen also samples once per second while foregrounded.

## Known limitations / gaps

- **Background download is NOT survived.** `HuggingFace.HubClient` (the implementation behind the `#hubDownloader()` macro) uses a foreground `URLSession` configuration — if the app is backgrounded mid-download, the transfer pauses and is restarted from the last completed file when the user returns. A production-grade integration would need a custom `URLSessionConfiguration.background(...)` downloader that writes into the same cache directory the `HubClient` resolves against. We did NOT implement that here; for v0 the user keeps the app foregrounded for the initial pull.
- **No eviction handshake testing.** Production Jot needs Phi-4 to evict cleanly before Parakeet (ASR) reloads, and vice versa. This prototype only proves *self-eviction* (`Memory.clearCache()` after dropping the container reference) — actual co-residency with Parakeet is out of scope until they're hosted in the same process.
- **Simulator path is a stub.** `#if !targetEnvironment(simulator)` gates all MLX imports and calls. Simulator runs return a placeholder string; treat simulator builds as a UI/structure check only.
- **Cached-snapshot probe is conservative.** On launch the engine reports `.notDownloaded` even if weights are already on disk; the first `download()` call short-circuits via `HubClient.resolveCachedSnapshot` so the user just sees "Downloading 0%" → "Loading" → "Ready" almost instantly when re-running.
- **TTFT may be over-estimated.** `streamResponse` chunks are emitted token-by-token by the underlying `Generation` stream, so first-token latency reflects when the first chunk reaches the consumer — which includes any internal buffering. Treat the absolute number as an upper bound on real first-token wall time.
- **No progress UI for model load** (only for download). The transition from `Downloading` to `Loading` to `Ready` has no fraction display during the load step itself.

## Build verification

The prototype was verified to build for both real-device and simulator destinations with:

```sh
xcodegen generate
xcodebuild -scheme Phi4MiniPrototype \
    -destination "generic/platform=iOS" \
    -configuration Debug \
    -skipMacroValidation build           # BUILD SUCCEEDED
xcodebuild -scheme Phi4MiniPrototype \
    -destination "generic/platform=iOS Simulator" \
    -configuration Debug \
    -skipMacroValidation build           # BUILD SUCCEEDED
```

Notes:
- `-skipMacroValidation` is required because `mlx-swift-lm` pulls in the `MLXHuggingFaceMacros` macro target (transitively via the macro library, even though we don't use the macros directly). On a fresh machine, Xcode's UI would otherwise prompt the developer to "Trust" the macro on first open. The flag is benign — it only relaxes Xcode's "user must approve macro" gate, not any code-correctness checks.
- The Metal toolchain (`xcodebuild -downloadComponent MetalToolchain`) must be installed for the simulator build, because `mlx-swift` includes Metal shader sources that compile during the package build.

## File map

```
phi4-mini-prototype/
├── project.yml                                 # xcodegen config (iOS 26, Swift 6 strict)
├── Phi4MiniPrototype/
│   ├── Phi4MiniPrototypeApp.swift              # @main, WindowGroup { ContentView() }
│   ├── ContentView.swift                       # single screen, all sections
│   ├── Phi4Engine.swift                        # @MainActor @Observable engine, MLX wiring
│   ├── MemoryUtils.swift                       # availableMemoryMB() helper
│   ├── Info.plist                              # generated by xcodegen from project.yml
│   └── Assets.xcassets/                        # AppIcon placeholder
└── README.md                                   # you are here
```

## Results

_Empty for now — fill in after running on a real device._

| metric | iPhone 15 Pro | iPhone 17 Pro | notes |
| --- | --- | --- | --- |
| Cold model load (s) | TBD | TBD | from `Loading` to `Ready` |
| Download time (s @ 100 Mbps) | TBD | TBD | first-time only |
| Tokens / sec (rewrite, ~50 in-tokens) | TBD | TBD | streamed |
| TTFT (ms) | TBD | TBD | upper bound (see limitations) |
| Available memory baseline → min (MB) | TBD | TBD | `os_proc_available_memory()` |
| Peak RAM delta (MB) | TBD | TBD | baseline − min |
| Thermal state after 10 runs | TBD | TBD | Settings → Battery |
