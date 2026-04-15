import Accelerate
import CoreML
import Foundation
import os

nonisolated enum LLMEngineState: Sendable, Equatable {
    case unloaded
    case loading
    case ready
    case warmingUp
    case generating
    case error(String)

    var isOperational: Bool {
        self == .ready || self == .generating
    }
}

actor LLMEngine {
    struct ContextWindowPlan: Equatable, Sendable {
        let tokensForPrediction: [Int]
        let didTruncate: Bool
        let requiresStateReset: Bool
    }

    private let logger = Logger(subsystem: "com.mongars.ai", category: "llm")
    private let diagnostics: InferenceDiagnostics

    private var model: MLModel?
    private var state: MLState?
    private var tokenizer: TokenizerService?
    private var currentSourceID: ModelSourceID?
    private var currentContextWindow: Int = 2048
    private var engineState: LLMEngineState = .unloaded
    private var isStateful: Bool = false

    init(diagnostics: InferenceDiagnostics) {
        self.diagnostics = diagnostics
    }

    var currentState: LLMEngineState { engineState }
    var isReady: Bool { engineState == .ready }
    var loadedSourceID: ModelSourceID? { currentSourceID }

    static func isStatefulModel(stateDescriptionNames: some Collection<String>) -> Bool {
        !stateDescriptionNames.isEmpty
    }

    static func shouldResetStateForFreshGeneration(isStateful: Bool) -> Bool {
        isStateful
    }

    static func makeContextWindowPlan(tokens: [Int], contextWindow: Int, isStateful: Bool) -> ContextWindowPlan {
        guard !tokens.isEmpty else {
            return ContextWindowPlan(tokensForPrediction: [], didTruncate: false, requiresStateReset: false)
        }

        let safeWindow = max(contextWindow, 1)
        let maxTokensForPrediction = max(safeWindow - 1, 1)
        guard tokens.count > maxTokensForPrediction else {
            return ContextWindowPlan(tokensForPrediction: tokens, didTruncate: false, requiresStateReset: false)
        }

        let truncated = Array(tokens.suffix(maxTokensForPrediction))
        return ContextWindowPlan(tokensForPrediction: truncated, didTruncate: true, requiresStateReset: isStateful)
    }

    func loadModel(sourceID: ModelSourceID, modelURL: URL, tokenizerDirectory: URL, contextWindow: Int) async throws {
        guard engineState != .loading else { return }
        engineState = .loading

        let loadStart = CFAbsoluteTimeGetCurrent()

        let tokService = TokenizerService()
        do {
            try await tokService.load(from: tokenizerDirectory)
        } catch {
            engineState = .error("Tokenizer loading failed: \(error.localizedDescription)")
            await diagnostics.recordError("Tokenizer load failed: \(error)", sourceID: sourceID)
            throw error
        }

        do {
            let config = MLModelConfiguration()
            config.computeUnits = computeUnitsForCurrentDevice()

            let compiledURL: URL
            if modelURL.pathExtension == "mlmodelc" {
                compiledURL = modelURL
            } else {
                compiledURL = try await MLModel.compileModel(at: modelURL)
            }

            let loadedModel = try await MLModel.load(contentsOf: compiledURL, configuration: config)

            isStateful = hasModelState(loadedModel)
            if isStateful {
                state = loadedModel.makeState()
                logger.info("Stateful model state detected and initialized for \(sourceID)")
            } else {
                state = nil
            }

            self.model = loadedModel
            self.tokenizer = tokService
            self.currentSourceID = sourceID
            self.currentContextWindow = contextWindow
            self.engineState = .ready

            let loadDuration = CFAbsoluteTimeGetCurrent() - loadStart
            await diagnostics.recordModelLoad(sourceID: sourceID, durationSeconds: loadDuration, success: true)
        } catch {
            let loadDuration = CFAbsoluteTimeGetCurrent() - loadStart
            engineState = .error("Model loading failed: \(error.localizedDescription)")
            await diagnostics.recordModelLoad(sourceID: sourceID, durationSeconds: loadDuration, success: false)
            throw error
        }
    }

    func warmup() async {
        guard let tokenizer, engineState == .ready else { return }
        engineState = .warmingUp

        let warmStart = CFAbsoluteTimeGetCurrent()
        let warmupTokens = await tokenizer.encode("Hello")
        do {
            _ = try await predictNextTokenLogits(tokens: warmupTokens)
            if isStateful {
                resetKVCache()
            }
        } catch {
            logger.warning("Warmup prediction failed (non-fatal): \(error.localizedDescription)")
        }

        let warmDuration = CFAbsoluteTimeGetCurrent() - warmStart
        engineState = .ready
        if let sourceID = currentSourceID {
            await diagnostics.recordWarmup(sourceID: sourceID, durationSeconds: warmDuration)
        }
    }

    func generate(prompt: String, config: GenerationConfig = .default) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish(throwing: LLMError.engineDeallocated)
                    return
                }
                await self.runGeneration(prompt: prompt, config: config, continuation: continuation)
            }
        }
    }

    func generateFull(prompt: String, config: GenerationConfig = .default) async throws -> GenerationResult {
        guard let _ = model, let tokenizer, engineState == .ready else {
            throw LLMError.modelNotLoaded
        }

        engineState = .generating
        defer { engineState = .ready }
        prepareForFreshGenerationIfNeeded()

        let genStart = CFAbsoluteTimeGetCurrent()
        let inputTokens = await tokenizer.encode(prompt)
        var generatedTokens = inputTokens
        let eosToken = await tokenizer.eosTokenId
        let contextWindow = currentContextWindow

        var mergedStopTokens = config.stopTokenIds
        mergedStopTokens.insert(eosToken)

        var tokenFrequencies: [Int: Int] = [:]
        var newTokenCount = 0
        var finishReason: GenerationResult.FinishReason = .maxTokens

        for _ in 0..<config.maxNewTokens {
            if Task.isCancelled {
                finishReason = .cancelled
                break
            }

            let stepPlan = Self.makeContextWindowPlan(tokens: generatedTokens, contextWindow: contextWindow, isStateful: isStateful)
            if stepPlan.didTruncate {
                generatedTokens = stepPlan.tokensForPrediction
                if stepPlan.requiresStateReset {
                    resetKVCache()
                }
            }

            let logits = try await predictNextTokenLogits(tokens: generatedTokens)
            var processedLogits = logits

            if config.repetitionPenalty > 1.0 {
                applyRepetitionPenalty(&processedLogits, tokens: generatedTokens, penalty: config.repetitionPenalty)
            }
            if config.frequencyPenalty > 0 {
                applyFrequencyPenalty(&processedLogits, frequencies: tokenFrequencies, penalty: config.frequencyPenalty)
            }

            let nextToken = sampleToken(processedLogits, config: config)

            if mergedStopTokens.contains(nextToken) {
                finishReason = nextToken == eosToken ? .endOfSequence : .stopToken
                break
            }

            generatedTokens.append(nextToken)
            tokenFrequencies[nextToken, default: 0] += 1
            newTokenCount += 1
        }

        let genDuration = CFAbsoluteTimeGetCurrent() - genStart
        let outputTokens = Array(generatedTokens.suffix(newTokenCount))
        let text = await tokenizer.decode(outputTokens)

        let sourceID = currentSourceID ?? "unknown"
        let snapshot = InferenceSnapshot(
            timestamp: Date(),
            tokensGenerated: newTokenCount,
            elapsedSeconds: genDuration,
            peakMemoryBytes: currentMemoryUsage(),
            thermalState: ProcessInfo.processInfo.thermalState,
            sourceID: sourceID
        )
        await diagnostics.recordSnapshot(snapshot)

        return GenerationResult(
            text: text,
            tokenCount: newTokenCount,
            promptTokenCount: inputTokens.count,
            generationTimeSeconds: genDuration,
            tokensPerSecond: genDuration > 0 ? Double(newTokenCount) / genDuration : 0,
            finishReason: finishReason,
            sourceID: sourceID
        )
    }

    func unloadModel() {
        model = nil
        state = nil
        tokenizer = nil
        currentSourceID = nil
        currentContextWindow = 2048
        isStateful = false
        engineState = .unloaded
        logger.info("LLM engine unloaded")
    }

    func resetKVCache() {
        guard isStateful, let model else { return }
        state = model.makeState()
    }

    var canHandleMemoryPressure: Bool {
        let thermal = ProcessInfo.processInfo.thermalState
        return thermal == .serious || thermal == .critical
    }

    func handleMemoryPressure() async {
        let mem = currentMemoryUsage()
        let thermal = ProcessInfo.processInfo.thermalState
        await diagnostics.recordMemoryPressure(bytesUsed: mem, thermal: thermal)

        if thermal == .critical {
            logger.warning("Critical thermal state — unloading model")
            unloadModel()
        }
    }

    // MARK: - Private

    private func runGeneration(prompt: String, config: GenerationConfig, continuation: AsyncThrowingStream<String, Error>.Continuation) async {
        guard let _ = model, let tokenizer, engineState == .ready else {
            continuation.finish(throwing: LLMError.modelNotLoaded)
            return
        }

        engineState = .generating
        prepareForFreshGenerationIfNeeded()
        let genStart = CFAbsoluteTimeGetCurrent()

        let inputTokens = await tokenizer.encode(prompt)
        var generatedTokens = inputTokens
        let eosToken = await tokenizer.eosTokenId
        let contextWindow = currentContextWindow

        var mergedStopTokens = config.stopTokenIds
        mergedStopTokens.insert(eosToken)

        var tokenFrequencies: [Int: Int] = [:]
        var newTokenCount = 0
        var finishReason: GenerationResult.FinishReason = .maxTokens

        do {
            for _ in 0..<config.maxNewTokens {
                if Task.isCancelled {
                    finishReason = .cancelled
                    break
                }

                let stepPlan = Self.makeContextWindowPlan(tokens: generatedTokens, contextWindow: contextWindow, isStateful: isStateful)
                if stepPlan.didTruncate {
                    generatedTokens = stepPlan.tokensForPrediction
                    if stepPlan.requiresStateReset {
                        resetKVCache()
                    }
                }

                let logits = try await predictNextTokenLogits(tokens: generatedTokens)
                var processedLogits = logits

                if config.repetitionPenalty > 1.0 {
                    applyRepetitionPenalty(&processedLogits, tokens: generatedTokens, penalty: config.repetitionPenalty)
                }
                if config.frequencyPenalty > 0 {
                    applyFrequencyPenalty(&processedLogits, frequencies: tokenFrequencies, penalty: config.frequencyPenalty)
                }

                let nextToken = sampleToken(processedLogits, config: config)

                if mergedStopTokens.contains(nextToken) {
                    finishReason = nextToken == eosToken ? .endOfSequence : .stopToken
                    break
                }

                generatedTokens.append(nextToken)
                tokenFrequencies[nextToken, default: 0] += 1
                newTokenCount += 1

                let decoded = await tokenizer.decode([nextToken])
                if !decoded.isEmpty {
                    continuation.yield(decoded)
                }
            }

            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
            if let sourceID = currentSourceID {
                await diagnostics.recordError("Generation error: \(error)", sourceID: sourceID)
            }
        }

        let genDuration = CFAbsoluteTimeGetCurrent() - genStart
        let sourceID = currentSourceID ?? "unknown"
        let snapshot = InferenceSnapshot(
            timestamp: Date(),
            tokensGenerated: newTokenCount,
            elapsedSeconds: genDuration,
            peakMemoryBytes: currentMemoryUsage(),
            thermalState: ProcessInfo.processInfo.thermalState,
            sourceID: sourceID
        )
        await diagnostics.recordSnapshot(snapshot)

        engineState = .ready
    }

    private func predictNextTokenLogits(tokens: [Int]) async throws -> [Float] {
        guard let model else { throw LLMError.modelNotLoaded }

        let maxLength = max(currentContextWindow, 1)
        let inputLength = min(tokens.count, maxLength)
        guard inputLength > 0 else { throw LLMError.contextOverflow }
        let truncatedTokens = Array(tokens.suffix(inputLength))

        let inputArray = try MLMultiArray(shape: [1, NSNumber(value: inputLength)], dataType: .int32)
        for (i, token) in truncatedTokens.enumerated() {
            inputArray[[0, NSNumber(value: i)] as [NSNumber]] = NSNumber(value: token)
        }

        let inputFeatures = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: inputArray)
        ])

        let output: MLFeatureProvider
        if isStateful, let state {
            output = try await model.prediction(from: inputFeatures, using: state)
        } else {
            output = try await model.prediction(from: inputFeatures)
        }

        guard let logitsValue = output.featureValue(for: "logits"),
              let logits = logitsValue.multiArrayValue else {
            throw LLMError.invalidModelOutput
        }

        let vocabSize = logits.shape.last?.intValue ?? 0
        guard vocabSize > 0 else { throw LLMError.invalidModelOutput }

        let lastPosition = inputLength - 1
        var logitsArray = [Float](repeating: 0, count: vocabSize)

        let pointer = logits.dataPointer.assumingMemoryBound(to: Float.self)
        let strides = logits.strides.map { $0.intValue }

        if logits.dataType == .float32 && strides.count >= 3 {
            let offset = lastPosition * strides[strides.count - 2]
            logitsArray.withUnsafeMutableBufferPointer { dest in
                let src = pointer.advanced(by: offset)
                dest.baseAddress!.initialize(from: src, count: vocabSize)
            }
        } else {
            for i in 0..<vocabSize {
                logitsArray[i] = logits[[0, NSNumber(value: lastPosition), NSNumber(value: i)] as [NSNumber]].floatValue
            }
        }

        return logitsArray
    }

    // MARK: - Sampling with Accelerate

    private func sampleToken(_ logits: [Float], config: GenerationConfig) -> Int {
        if config.temperature <= 0 {
            return argmax(logits)
        }

        var scaled = [Float](repeating: 0, count: logits.count)
        var temp = config.temperature
        vDSP_vsdiv(logits, 1, &temp, &scaled, 1, vDSP_Length(logits.count))

        var maxVal: Float = 0
        vDSP_maxv(scaled, 1, &maxVal, vDSP_Length(scaled.count))

        var negMax = -maxVal
        vDSP_vsadd(scaled, 1, &negMax, &scaled, 1, vDSP_Length(scaled.count))

        var count = Int32(scaled.count)
        vvexpf(&scaled, scaled, &count)

        var topKIndices: [Int]
        var topKValues: [Float]

        if config.topK > 0 && config.topK < logits.count {
            (topKIndices, topKValues) = accelerateTopK(scaled, k: config.topK)
        } else {
            topKIndices = Array(0..<scaled.count)
            topKValues = scaled
        }

        if config.topP < 1.0 {
            (topKIndices, topKValues) = applyTopP(indices: topKIndices, values: topKValues, p: config.topP)
        }

        if config.minP > 0 {
            (topKIndices, topKValues) = applyMinP(indices: topKIndices, values: topKValues, minP: config.minP)
        }

        guard !topKIndices.isEmpty else { return argmax(logits) }

        var sum: Float = 0
        vDSP_sve(topKValues, 1, &sum, vDSP_Length(topKValues.count))

        guard sum > 0 else { return topKIndices[0] }

        var probs = [Float](repeating: 0, count: topKValues.count)
        var divisor = sum
        vDSP_vsdiv(topKValues, 1, &divisor, &probs, 1, vDSP_Length(topKValues.count))

        let random = Float.random(in: 0..<1)
        var cumulative: Float = 0
        for (i, p) in probs.enumerated() {
            cumulative += p
            if cumulative >= random {
                return topKIndices[i]
            }
        }
        return topKIndices[probs.count - 1]
    }

    private func accelerateTopK(_ values: [Float], k: Int) -> (indices: [Int], values: [Float]) {
        let n = values.count
        guard k < n else { return (Array(0..<n), values) }

        var indexed = values.enumerated().map { ($0.offset, $0.element) }
        indexed.sort { $0.1 > $1.1 }

        let topK = Array(indexed.prefix(k))
        return (topK.map(\.0), topK.map(\.1))
    }

    private func applyTopP(indices: [Int], values: [Float], p: Float) -> (indices: [Int], values: [Float]) {
        guard !values.isEmpty else { return (indices, values) }

        var sum: Float = 0
        vDSP_sve(values, 1, &sum, vDSP_Length(values.count))
        guard sum > 0 else { return (indices, values) }

        var probs = [Float](repeating: 0, count: values.count)
        var divisor = sum
        vDSP_vsdiv(values, 1, &divisor, &probs, 1, vDSP_Length(values.count))

        var sorted = probs.enumerated().map { ($0.offset, $0.element) }
        sorted.sort { $0.1 > $1.1 }

        var cumulative: Float = 0
        var filteredIndices: [Int] = []
        var filteredValues: [Float] = []

        for (localIdx, prob) in sorted {
            filteredIndices.append(indices[localIdx])
            filteredValues.append(values[localIdx])
            cumulative += prob
            if cumulative >= p { break }
        }

        return (filteredIndices, filteredValues)
    }

    private func applyMinP(indices: [Int], values: [Float], minP: Float) -> (indices: [Int], values: [Float]) {
        guard !values.isEmpty else { return (indices, values) }

        var maxVal: Float = 0
        vDSP_maxv(values, 1, &maxVal, vDSP_Length(values.count))
        let threshold = maxVal * minP

        var filteredIndices: [Int] = []
        var filteredValues: [Float] = []

        for (i, v) in values.enumerated() {
            if v >= threshold {
                filteredIndices.append(indices[i])
                filteredValues.append(v)
            }
        }

        if filteredIndices.isEmpty {
            if let maxIdx = values.firstIndex(of: maxVal) {
                return ([indices[maxIdx]], [maxVal])
            }
            return (indices, values)
        }

        return (filteredIndices, filteredValues)
    }

    private func applyRepetitionPenalty(_ logits: inout [Float], tokens: [Int], penalty: Float) {
        let uniqueRecent = Set(tokens.suffix(64))
        for token in uniqueRecent where token < logits.count {
            if logits[token] > 0 {
                logits[token] /= penalty
            } else {
                logits[token] *= penalty
            }
        }
    }

    private func applyFrequencyPenalty(_ logits: inout [Float], frequencies: [Int: Int], penalty: Float) {
        for (token, count) in frequencies where token < logits.count {
            logits[token] -= penalty * Float(count)
        }
    }

    private func argmax(_ array: [Float]) -> Int {
        var maxIdx: vDSP_Length = 0
        var maxVal: Float = 0
        vDSP_maxvi(array, 1, &maxVal, &maxIdx, vDSP_Length(array.count))
        return Int(maxIdx)
    }

    // MARK: - Model Inspection

    private func hasModelState(_ model: MLModel) -> Bool {
        Self.isStatefulModel(stateDescriptionNames: model.modelDescription.stateDescriptionsByName.keys)
    }

    private func prepareForFreshGenerationIfNeeded() {
        guard Self.shouldResetStateForFreshGeneration(isStateful: isStateful) else { return }
        resetKVCache()
    }

    private func computeUnitsForCurrentDevice() -> MLComputeUnits {
        let thermal = ProcessInfo.processInfo.thermalState
        if thermal == .critical || thermal == .serious {
            return .cpuOnly
        }
        return .cpuAndNeuralEngine
    }

    private func currentMemoryUsage() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }
}

nonisolated enum LLMError: Error, Sendable {
    case modelNotLoaded
    case invalidModelOutput
    case engineDeallocated
    case generationCancelled
    case contextOverflow
    case thermalThrottled
}
