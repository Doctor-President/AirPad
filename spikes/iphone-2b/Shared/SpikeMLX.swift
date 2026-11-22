// Sweep 2b · 3.3 — Qwen3.5 4B through MLX, behind FoundationModels' own `LanguageModel` API (Q5 "same API").
// mlx-swift-lm 3.33.0's MLXFoundationModels.MLXLanguageModel conforms to FoundationModels.LanguageModel, so the
// spike drives it with exactly the LanguageModelSession calls it uses for Apple (FMEngine in SpikeRunner.swift):
// guided @Generable output (grammar-constrained), plain text, streaming.
//
// Weights come from a local directory (copied over USB to the phone; build/iphone-spike/models on the Mac) — no
// downloader is linked. Thinking stays OFF: `.reasoning` is NOT declared, and the adapter then re-renders the Qwen
// chat template with thinking disabled on the plain path (MLXLanguageModel.swift, "Capability gate"); the runner
// records reasoning-token counts and any <think> leak so the Mac run can confirm it.
import Foundation
import FoundationModels
import MLX
import MLXFoundationModels
import MLXLLM
import MLXLMCommon
import Tokenizers

enum SpikeMLX {
    static let mlxSwiftLMVersion = "3.33.0"
    static let cacheLimitBytes = 20 * 1024 * 1024   // AirPad's LocalModelService setting

    /// Compile-level answer to Q5's "same API": this file only builds if MLXLanguageModel (a FoundationModels
    /// LanguageModel) compiles and links for the platform being built.
    static var sameAPIFact: [String: Any] {
        ["mlxLanguageModelCompiled": true, "package": "mlx-swift-lm \(mlxSwiftLMVersion) MLXFoundationModels",
         "type": String(reflecting: MLXLanguageModel.self), "conformsTo": "FoundationModels.LanguageModel",
         "declaredCapabilities": [".guidedGeneration"]]
    }

    static func load(directory dir: URL) async throws -> (engine: SpikeEngine, info: [String: Any]) {
        Memory.cacheLimit = cacheLimitBytes
        _ = LLMModelFactory.shared   // keeps MLXLLM's factory (qwen3_5) linked for loadModelContainer
        let model = MLXLanguageModel(
            configuration: ModelConfiguration(directory: dir),
            capabilities: [.guidedGeneration],
            weightsLocation: { _ in dir },
            load: { _, progress in
                try await loadModelContainer(from: dir, using: LocalTokenizerLoader(), progress: progress)
            })
        try await model.preload()   // weights only; the first respond still compiles the Metal shaders (reported as `cold`)
        let snap = Memory.snapshot()
        let info: [String: Any] = [
            "modelID": model.modelID, "capabilities": String(reflecting: model.capabilities),
            "mlxActiveMemoryMB": Memory.activeMemory / 1_048_576, "mlxPeakMemoryMB": Memory.peakMemory / 1_048_576,
            "mlxCacheLimitMB": Memory.cacheLimit / 1_048_576, "mlxSnapshot": String(describing: snap),
        ]
        return (FMEngine(label: "mlx", model: model), info)
    }
}

/// swift-transformers' AutoTokenizer, read from the local weights folder, bridged to MLXLMCommon.Tokenizer (the same
/// bridge mlx-swift-lm's #huggingFaceTokenizerLoader macro writes, without the HuggingFace downloader).
struct LocalTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(upstream: try await AutoTokenizer.from(modelFolder: directory))
    }
}

struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { upstream.encode(text: text, addSpecialTokens: addSpecialTokens) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens) }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?, additionalContext: [String: any Sendable]?) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
