import CoreML
import Foundation

nonisolated enum LLMEngineState: Sendable, Equatable {
    case unloaded
    case loading
    case ready
    case generating
    case error(String)
}

actor LLMEngine {
    private var model: MLModel?
    private var tokenizer: TokenizerService?
    private var state: LLMEngineState = .unloaded
    private var currentVariant: ModelVariant?

    var engineState: LLMEngineState { state }
    var isReady: Bool { state == .ready }

    func loadModel(variant: ModelVariant, modelURL: URL, tokenizerDirectory: URL) async throws {
        state = .loading

        let tokService = TokenizerService()
        do {
            try await tokService.load(from: tokenizerDirectory)
        } catch {
            state = .error("Tokenizer loading failed: \(error.localizedDescription)")
            throw error
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
            self.tokenizer = tokService
            self.currentVariant = variant
            self.state = .ready
        } catch {
            state = .error("Model loading failed: \(error.localizedDescription)")
            throw error
        }
    }

    func generate(prompt: String, maxTokens: Int = 512, temperature: Float = 0.7) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish(throwing: LLMError.engineDeallocated)
                    return
                }

                do {
                    guard let model = await self.model, let tokenizer = await self.tokenizer else {
                        continuation.finish(throwing: LLMError.modelNotLoaded)
                        return
                    }

                    await self.setState(.generating)

                    let inputTokens = await tokenizer.encode(prompt)
                    var generatedTokens = inputTokens
                    let eosToken = await tokenizer.eosTokenId

                    for _ in 0..<maxTokens {
                        guard !Task.isCancelled else {
                            continuation.finish()
                            await self.setState(.ready)
                            return
                        }

                        let nextToken = try await self.predictNextToken(
                            model: model,
                            tokens: generatedTokens,
                            temperature: temperature
                        )

                        if nextToken == eosToken { break }

                        generatedTokens.append(nextToken)

                        let decoded = await tokenizer.decode([nextToken])
                        if !decoded.isEmpty {
                            continuation.yield(decoded)
                        }
                    }

                    continuation.finish()
                    await self.setState(.ready)
                } catch {
                    continuation.finish(throwing: error)
                    await self.setState(.ready)
                }
            }
        }
    }

    func unloadModel() {
        model = nil
        tokenizer = nil
        currentVariant = nil
        state = .unloaded
    }

    private func setState(_ newState: LLMEngineState) {
        state = newState
    }

    private func predictNextToken(model: MLModel, tokens: [Int], temperature: Float) async throws -> Int {
        let maxLength = currentVariant?.contextWindowTokens ?? 2048
        let inputLength = min(tokens.count, maxLength)
        let truncatedTokens = Array(tokens.suffix(inputLength))

        let inputArray = try MLMultiArray(shape: [1, NSNumber(value: inputLength)], dataType: .int32)
        for (i, token) in truncatedTokens.enumerated() {
            inputArray[[0, NSNumber(value: i)] as [NSNumber]] = NSNumber(value: token)
        }

        let inputFeatures = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: inputArray)
        ])

        let output = try await model.prediction(from: inputFeatures)

        guard let logitsValue = output.featureValue(for: "logits"),
              let logits = logitsValue.multiArrayValue else {
            throw LLMError.invalidModelOutput
        }

        let vocabSize = logits.shape.last?.intValue ?? 0
        let lastPosition = inputLength - 1

        var logitsArray = [Float](repeating: 0, count: vocabSize)
        for i in 0..<vocabSize {
            logitsArray[i] = logits[[0, NSNumber(value: lastPosition), NSNumber(value: i)] as [NSNumber]].floatValue
        }

        if temperature > 0 {
            return sampleWithTemperature(logitsArray, temperature: temperature)
        } else {
            return argmax(logitsArray)
        }
    }

    private func sampleWithTemperature(_ logits: [Float], temperature: Float) -> Int {
        let scaled = logits.map { $0 / temperature }
        let maxVal = scaled.max() ?? 0
        let exps = scaled.map { exp($0 - maxVal) }
        let sumExps = exps.reduce(0, +)
        let probs = exps.map { $0 / sumExps }

        let random = Float.random(in: 0..<1)
        var cumulative: Float = 0
        for (i, p) in probs.enumerated() {
            cumulative += p
            if cumulative >= random {
                return i
            }
        }
        return probs.count - 1
    }

    private func argmax(_ array: [Float]) -> Int {
        var maxIdx = 0
        var maxVal = array[0]
        for (i, val) in array.enumerated() where val > maxVal {
            maxVal = val
            maxIdx = i
        }
        return maxIdx
    }
}

nonisolated enum LLMError: Error, Sendable {
    case modelNotLoaded
    case invalidModelOutput
    case engineDeallocated
    case generationCancelled
    case contextOverflow
}
