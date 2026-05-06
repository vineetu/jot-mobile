//
//  TokenizerInfo.swift
//  mlx-swift-structured
//
//  Created by Ivan Petrukha on 03.04.2026.
//

import Foundation
import MLXLMCommon
import Hub

struct TokenizerInfo: Sendable {
    let vocab: [String]
    let vocabType: Int32
    let stopTokenIds: [Int32]
}

extension TokenizerInfo {
    static func from(
        hub: HubApi = .shared,
        configuration: ModelConfiguration,
    ) async throws -> TokenizerInfo {
        let configurations =
            switch configuration.id {
            case .id(let id, let revision):
                LanguageModelConfigurationFromHub(modelName: id, revision: revision, hubApi: hub)
            case .directory(let directory):
                LanguageModelConfigurationFromHub(modelFolder: directory, hubApi: hub)
            }

        let (modelConfig, tokenizerConfig, tokenizerData) = try await (
            configurations.modelConfig,
            configurations.tokenizerConfig,
            configurations.tokenizerData
        )

        let modelVocab: [(token: String, id: Int)] = tokenizerData
            .model.vocab.dictionary(or: [:])
            .compactMap { key, value in
                if let id = value.integer() {
                    return (token: key.string, id: id)
                } else {
                    return nil
                }
            }

        let addedTokens: [(token: String, id: Int)] = tokenizerData
            .addedTokens.array(or: [])
            .compactMap { value in
                if let id = value.id.integer(), let token = value.content.string() {
                    return (token: token, id: id)
                } else {
                    return nil
                }
            }

        let configuredVocabSize =
            [
                modelConfig?.vocabSize.integer(),
                modelConfig?.textConfig.vocabSize.integer(),
                modelConfig?.textConfiguration.vocabSize.integer(),
            ]
            .compactMap { $0 }
            .max() ?? 0

        let derivedVocabSize =
            [
                modelVocab.map(\.id).max(),
                addedTokens.map(\.id).max(),
            ]
            .compactMap { $0 }
            .map { $0 + 1 }
            .max() ?? 0

        let vocabSize = max(configuredVocabSize, derivedVocabSize)
        var vocab = Array(repeating: "", count: vocabSize)
        for (token, id) in (modelVocab + addedTokens) where vocab.indices.contains(id) {
            vocab[id] = token
        }

        let decoders: [Config] =
            switch tokenizerData.decoder.type.string() {
            case "Sequence":
                tokenizerData.decoder.decoders.array(or: [])
            default:
                [tokenizerData.decoder]
            }

        var vocabType: Int32 = 0
        loop: for decoder in decoders {
            switch decoder.type.string() {
            case "ByteFallback":
                vocabType = 1
                break loop
            case "ByteLevel":
                vocabType = 2
                break loop
            default:
                continue
            }
        }

        var stopTokenIds: [Int32] = configuration.extraEOSTokens.compactMap(vocab.firstIndex).map(Int32.init)
        if let tokenizerConfig, let eosToken = tokenizerConfig.eosToken.string(), let eosTokenId = vocab.firstIndex(of: eosToken) {
            stopTokenIds.append(Int32(eosTokenId))
        }

        return TokenizerInfo(
            vocab: vocab,
            vocabType: vocabType,
            stopTokenIds: stopTokenIds
        )
    }
}
