//
//  RootCommand.swift
//  MLXStructured
//
//  Created by Ivan Petrukha on 04.10.2025.
//

import ArgumentParser
import MLXLMCommon
import MLXLLM
import MLXVLM
import Hub

@main
struct RootCommand: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "mlx-structured",
        abstract: "Examples of different structured output generation.",
        subcommands: [
            BenchmarkCommand.self,
            CodableExample.self,
            CodableStreamExample.self,
            GenerableExample.self,
            GenerableStreamExample.self,
            StructuralExample.self,
            ToolCallingExample.self,
        ]
    )
}

struct ModelArguments: ParsableArguments {

    @Option
    var id: String = "mlx-community/Qwen3-0.6B-4bit"

    @Option
    var revision: String = "main"

    @Flag
    var vlm: Bool = false

    func modelContext() async throws -> ModelContext {
        let hub = HubApi(useOfflineMode: false)
        let configuration = ModelConfiguration(id: id, revision: revision, extraEOSTokens: ["<end_of_turn>", "<|end|>"])
        let factory: ModelFactory = vlm ? VLMModelFactory.shared : LLMModelFactory.shared
        return try await factory.load(hub: hub, configuration: configuration) { progress in
            print("Loading model: \(progress.fractionCompleted.formatted(.percent))")
        }
    }
}
