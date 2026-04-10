import CoreML
import Foundation

actor EmbeddingEngine {
    private var model: MLModel?
    private var isLoaded: Bool = false

    var ready: Bool { isLoaded }

    func loadModel(at url: URL) async throws {
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine

        let compiledURL: URL
        if url.pathExtension == "mlmodelc" {
            compiledURL = url
        } else {
            compiledURL = try await MLModel.compileModel(at: url)
        }

        model = try await MLModel.load(contentsOf: compiledURL, configuration: config)
        isLoaded = true
    }

    func embed(text: String) async throws -> [Float] {
        guard let model else {
            throw EmbeddingError.modelNotLoaded
        }

        let inputFeatures = try MLDictionaryFeatureProvider(dictionary: [
            "text": MLFeatureValue(string: text)
        ])

        let output = try await model.prediction(from: inputFeatures)

        guard let embeddingValue = output.featureValue(for: "embedding"),
              let embeddingArray = embeddingValue.multiArrayValue else {
            throw EmbeddingError.invalidOutput
        }

        let count = embeddingArray.count
        var vector = [Float](repeating: 0, count: count)
        for i in 0..<count {
            vector[i] = embeddingArray[i].floatValue
        }

        return normalize(vector)
    }

    func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = sqrt(normA) * sqrt(normB)
        guard denom > 0 else { return 0 }
        return dot / denom
    }

    func unloadModel() {
        model = nil
        isLoaded = false
    }

    private func normalize(_ vector: [Float]) -> [Float] {
        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }
}

nonisolated enum EmbeddingError: Error, Sendable {
    case modelNotLoaded
    case invalidOutput
}
