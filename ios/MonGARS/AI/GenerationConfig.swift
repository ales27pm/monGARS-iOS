import Foundation

nonisolated struct GenerationConfig: Sendable {
    var maxNewTokens: Int
    var temperature: Float
    var topK: Int
    var topP: Float
    var minP: Float
    var repetitionPenalty: Float
    var frequencyPenalty: Float
    var stopTokenIds: Set<Int>

    static let `default` = GenerationConfig(
        maxNewTokens: 512,
        temperature: 0.7,
        topK: 40,
        topP: 0.9,
        minP: 0.05,
        repetitionPenalty: 1.1,
        frequencyPenalty: 0.0,
        stopTokenIds: []
    )

    static let precise = GenerationConfig(
        maxNewTokens: 512,
        temperature: 0.1,
        topK: 10,
        topP: 0.95,
        minP: 0.1,
        repetitionPenalty: 1.05,
        frequencyPenalty: 0.0,
        stopTokenIds: []
    )

    static let creative = GenerationConfig(
        maxNewTokens: 1024,
        temperature: 0.9,
        topK: 60,
        topP: 0.95,
        minP: 0.02,
        repetitionPenalty: 1.15,
        frequencyPenalty: 0.1,
        stopTokenIds: []
    )

    func withStopTokens(_ ids: Set<Int>) -> GenerationConfig {
        var copy = self
        copy.stopTokenIds = ids
        return copy
    }

    func withMaxTokens(_ max: Int) -> GenerationConfig {
        var copy = self
        copy.maxNewTokens = max
        return copy
    }
}

nonisolated struct GenerationResult: Sendable {
    let text: String
    let tokenCount: Int
    let promptTokenCount: Int
    let generationTimeSeconds: Double
    let tokensPerSecond: Double
    let finishReason: FinishReason
    let variant: ModelVariant

    nonisolated enum FinishReason: String, Sendable {
        case endOfSequence
        case maxTokens
        case cancelled
        case error
        case stopToken
    }
}

nonisolated struct EmbeddingResult: Sendable {
    let vector: [Float]
    let dimensions: Int
    let computeTimeSeconds: Double
    let inputTokenCount: Int
}

nonisolated struct InferenceSnapshot: Sendable {
    let timestamp: Date
    let tokensGenerated: Int
    let elapsedSeconds: Double
    let peakMemoryBytes: UInt64
    let thermalState: ProcessInfo.ThermalState
    let variant: ModelVariant

    var tokensPerSecond: Double {
        elapsedSeconds > 0 ? Double(tokensGenerated) / elapsedSeconds : 0
    }
}
