import Accelerate
import CoreML
import Foundation
import os

nonisolated enum EmbeddingEngineState: Sendable, Equatable {
    case unloaded
    case loading
    case ready
    case error(String)
}

actor EmbeddingEngine {
    private let logger = Logger(subsystem: "com.mongars.ai", category: "embedding")
    private let diagnostics: InferenceDiagnostics

    private var model: MLModel?
    private var tokenizer: TokenizerService?
    private var engineState: EmbeddingEngineState = .unloaded
    private var dimensionCount: Int = 0
    private var currentSourceID: ModelSourceID?
    private var maxContextTokens: Int = 512
    private var embeddingCache = EmbeddingRequestCache(capacity: 32)

    init(diagnostics: InferenceDiagnostics) {
        self.diagnostics = diagnostics
    }

    var currentState: EmbeddingEngineState { engineState }
    var isReady: Bool { engineState == .ready }
    var dimensions: Int { dimensionCount }

    func loadModel(sourceID: ModelSourceID, modelURL: URL, tokenizerDirectory: URL?, contextWindow: Int) async throws {
        guard engineState != .loading else { return }
        engineState = .loading
        embeddingCache.clear()

        let loadStart = CFAbsoluteTimeGetCurrent()

        if let tokenizerDirectory {
            let tokService = TokenizerService()
            do {
                try await tokService.load(from: tokenizerDirectory)
                self.tokenizer = tokService
            } catch {
                logger.warning("Embedding tokenizer load failed (will try text input): \(error.localizedDescription)")
            }
        }

        do {
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndNeuralEngine

            let compiledURL: URL
            if modelURL.pathExtension == "mlmodelc" {
                compiledURL = modelURL
            } else {
                compiledURL = try await MLModel.compileModel(at: modelURL)
            }

            let loadedModel = try await MLModel.load(contentsOf: compiledURL, configuration: config)
            self.model = loadedModel
            self.currentSourceID = sourceID
            self.maxContextTokens = contextWindow

            if let outputDesc = loadedModel.modelDescription.outputDescriptionsByName["embedding"],
               let shape = outputDesc.multiArrayConstraint?.shape {
                dimensionCount = shape.last?.intValue ?? 0
            }

            engineState = .ready

            let loadDuration = CFAbsoluteTimeGetCurrent() - loadStart
            await diagnostics.recordModelLoad(sourceID: sourceID, durationSeconds: loadDuration, success: true)
        } catch {
            let loadDuration = CFAbsoluteTimeGetCurrent() - loadStart
            engineState = .error("Embedding model loading failed: \(error.localizedDescription)")
            await diagnostics.recordModelLoad(sourceID: sourceID, durationSeconds: loadDuration, success: false)
            throw error
        }
    }

    func embed(text: String) async throws -> EmbeddingResult {
        guard let model else { throw EmbeddingError.modelNotLoaded }

        if let cached = embeddingCache.value(for: text) {
            return EmbeddingResult(
                vector: cached.vector,
                dimensions: cached.dimensions,
                computeTimeSeconds: 0,
                inputTokenCount: cached.inputTokenCount
            )
        }

        let start = CFAbsoluteTimeGetCurrent()

        let inputFeatures: MLDictionaryFeatureProvider
        var inputTokenCount = 0

        if let tokenizer {
            let tokens = await tokenizer.encode(text)
            inputTokenCount = tokens.count
            let truncated = Array(tokens.prefix(maxContextTokens))

            let inputArray = try MLMultiArray(shape: [1, NSNumber(value: truncated.count)], dataType: .int32)
            for (i, token) in truncated.enumerated() {
                inputArray[[0, NSNumber(value: i)] as [NSNumber]] = NSNumber(value: token)
            }
            inputFeatures = try MLDictionaryFeatureProvider(dictionary: [
                "input_ids": MLFeatureValue(multiArray: inputArray)
            ])
        } else {
            inputFeatures = try MLDictionaryFeatureProvider(dictionary: [
                "text": MLFeatureValue(string: text)
            ])
        }

        let output = try await model.prediction(from: inputFeatures)

        guard let embeddingValue = output.featureValue(for: "embedding"),
              let embeddingArray = embeddingValue.multiArrayValue else {
            throw EmbeddingError.invalidOutput
        }

        let count = embeddingArray.count
        var vector = [Float](repeating: 0, count: count)

        if embeddingArray.dataType == .float32 {
            let ptr = embeddingArray.dataPointer.assumingMemoryBound(to: Float.self)
            vector.withUnsafeMutableBufferPointer { dest in
                dest.baseAddress!.initialize(from: ptr, count: count)
            }
        } else {
            for i in 0..<count {
                vector[i] = embeddingArray[i].floatValue
            }
        }

        let normalized = l2Normalize(vector)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        let result = EmbeddingResult(
            vector: normalized,
            dimensions: count,
            computeTimeSeconds: elapsed,
            inputTokenCount: inputTokenCount
        )
        embeddingCache.insert(result, for: text)
        return result
    }

    func embedBatch(texts: [String]) async throws -> [EmbeddingResult] {
        var results: [EmbeddingResult] = []
        results.reserveCapacity(texts.count)
        for text in texts {
            try Task.checkCancellation()
            let result = try await embed(text: text)
            results.append(result)
        }
        return results
    }

    func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }

        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0

        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        vDSP_svesq(a, 1, &normA, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &normB, vDSP_Length(b.count))

        let denom = sqrt(normA) * sqrt(normB)
        guard denom > 0 else { return 0 }
        return dot / denom
    }

    func rankBySimilarity(query: [Float], candidates: [(id: String, vector: [Float])], topK: Int? = nil) -> [(id: String, score: Float)] {
        var scored = candidates.map { (id: $0.id, score: cosineSimilarity(query, $0.vector)) }
        scored.sort { $0.score > $1.score }
        if let topK {
            return Array(scored.prefix(topK))
        }
        return scored
    }

    func unloadModel() {
        model = nil
        tokenizer = nil
        dimensionCount = 0
        currentSourceID = nil
        maxContextTokens = 512
        embeddingCache.clear()
        engineState = .unloaded
        logger.info("Embedding engine unloaded")
    }

    // MARK: - Private

    private func l2Normalize(_ vector: [Float]) -> [Float] {
        var sumSq: Float = 0
        vDSP_svesq(vector, 1, &sumSq, vDSP_Length(vector.count))
        let norm = sqrt(sumSq)
        guard norm > 0 else { return vector }

        var result = [Float](repeating: 0, count: vector.count)
        var divisor = norm
        vDSP_vsdiv(vector, 1, &divisor, &result, 1, vDSP_Length(vector.count))
        return result
    }
}

nonisolated enum EmbeddingError: Error, Sendable {
    case modelNotLoaded
    case invalidOutput
    case textTooLong
}

nonisolated struct EmbeddingRequestCache: Sendable {
    private struct Entry: Sendable {
        var result: EmbeddingResult
        var accessTick: UInt64
    }

    private(set) var capacity: Int
    private var entries: [String: Entry] = [:]
    private var currentTick: UInt64 = 0

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    var count: Int { entries.count }

    mutating func value(for key: String) -> EmbeddingResult? {
        guard var entry = entries[key] else { return nil }
        currentTick &+= 1
        entry.accessTick = currentTick
        entries[key] = entry
        return entry.result
    }

    mutating func insert(_ result: EmbeddingResult, for key: String) {
        currentTick &+= 1
        entries[key] = Entry(result: result, accessTick: currentTick)
        evictIfNeeded()
    }

    mutating func clear() {
        entries.removeAll(keepingCapacity: false)
        currentTick = 0
    }

    private mutating func evictIfNeeded() {
        while entries.count > capacity {
            guard let evictionKey = entries.min(by: { $0.value.accessTick < $1.value.accessTick })?.key else {
                return
            }
            entries.removeValue(forKey: evictionKey)
        }
    }
}
