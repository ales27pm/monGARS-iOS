//
//  MonGARSTests.swift
//  MonGARSTests
//
//  Created by Rork on April 10, 2026.
//

import Testing
@testable import MonGARS
import Foundation

struct MonGARSTests {
    @Test func retryPlannerRetriesTransientFailuresWithExponentialBackoff() {
        let planner = DownloadRetryPlanner(maxRetriesPerURL: 3, baseDelaySeconds: 1, maxDelaySeconds: 8)

        let first = planner.nextAction(for: .transientNetwork, retryCountOnCurrentURL: 0, hasFallbackURL: true)
        let second = planner.nextAction(for: .transientNetwork, retryCountOnCurrentURL: 1, hasFallbackURL: true)
        let capped = planner.nextAction(for: .transientNetwork, retryCountOnCurrentURL: 4, hasFallbackURL: true)

        #expect(first == .retry(delaySeconds: 1))
        #expect(second == .retry(delaySeconds: 2))

        #expect(capped == .switchToFallbackURL)
        #expect(planner.delay(forRetryAttempt: 7) == 8)
    }

    @Test func retryPlannerSwitchesToFallbackOnRepositorySpecificFailures() {
        let planner = DownloadRetryPlanner(maxRetriesPerURL: 2, baseDelaySeconds: 1, maxDelaySeconds: 8)

        let on404WithFallback = planner.nextAction(for: .httpStatus(404), retryCountOnCurrentURL: 0, hasFallbackURL: true)
        let on404NoFallback = planner.nextAction(for: .httpStatus(404), retryCountOnCurrentURL: 0, hasFallbackURL: false)
        let on403WithFallback = planner.nextAction(for: .httpStatus(403), retryCountOnCurrentURL: 0, hasFallbackURL: true)

        #expect(on404WithFallback == .switchToFallbackURL)
        #expect(on404NoFallback == .fail)
        #expect(on403WithFallback == .switchToFallbackURL)
    }

    @Test func fallbackURLSelectionIsDeterministic() {
        #expect(DownloadURLSelector.nextIndex(after: .switchToFallbackURL, currentIndex: 0, totalURLCount: 3) == 1)
        #expect(DownloadURLSelector.nextIndex(after: .switchToFallbackURL, currentIndex: 2, totalURLCount: 3) == nil)
        #expect(DownloadURLSelector.nextIndex(after: .retry(delaySeconds: 1), currentIndex: 1, totalURLCount: 3) == 1)
    }

    @Test func stateReducerTransitionsDownloadLifecycle() {
        var state = ModelDownloadState.notDownloaded

        state = ModelDownloadStateReducer.reduce(state, event: .started)
        #expect(state == .downloading(progress: 0))

        state = ModelDownloadStateReducer.reduce(state, event: .progress(0.42))
        #expect(state == .downloading(progress: 0.42))

        state = ModelDownloadStateReducer.reduce(state, event: .beginInstall)
        #expect(state == .installing)

        state = ModelDownloadStateReducer.reduce(state, event: .success(hasTokenizer: false))
        #expect(state == .installedMissingTokenizer)

        state = ModelDownloadStateReducer.reduce(state, event: .fail(message: "network down"))
        #expect(state == .error("network down"))

        state = ModelDownloadStateReducer.reduce(state, event: .cancelled)
        #expect(state == .notDownloaded)
    }

    @Test func llmEngineStatefulDetectionUsesAnyModelStateDescription() {
        #expect(LLMEngine.isStatefulModel(stateDescriptionNames: [String]()) == false)
        #expect(LLMEngine.isStatefulModel(stateDescriptionNames: ["keyCache"]))
        #expect(LLMEngine.isStatefulModel(stateDescriptionNames: ["decoder_state", "attention_cache"]))
    }

    @Test func llmEngineFreshGenerationResetPolicyDependsOnStatefulness() {
        #expect(LLMEngine.shouldResetStateForFreshGeneration(isStateful: true))
        #expect(LLMEngine.shouldResetStateForFreshGeneration(isStateful: false) == false)
    }

    @Test func llmEngineContextOverflowPlanTruncatesAndSignalsResetForStatefulModels() {
        let tokens = Array(0..<10)
        let plan = LLMEngine.makeContextWindowPlan(tokens: tokens, contextWindow: 8, isStateful: true)

        #expect(plan.didTruncate)
        #expect(plan.requiresStateReset)
        #expect(plan.tokensForPrediction.count == 7)
        #expect(plan.tokensForPrediction == Array(3..<10))
    }

    @Test func llmEngineContextOverflowPlanTruncatesWithoutResetForStatelessModels() {
        let tokens = Array(0..<10)
        let plan = LLMEngine.makeContextWindowPlan(tokens: tokens, contextWindow: 8, isStateful: false)

        #expect(plan.didTruncate)
        #expect(plan.requiresStateReset == false)
        #expect(plan.tokensForPrediction == Array(3..<10))
    }

    @Test func llmEngineContextOverflowPlanHandlesSmallContextWindowSafely() {
        let tokens = [11, 22, 33]
        let plan = LLMEngine.makeContextWindowPlan(tokens: tokens, contextWindow: 1, isStateful: true)

        #expect(plan.didTruncate)
        #expect(plan.tokensForPrediction == [33])
        #expect(plan.requiresStateReset)
    }

    @Test func embeddingStoreSearchUsesBoundedRecentCandidateWindow() async throws {
        let topK = 1
        let candidateLimit = EmbeddingStore.searchCandidateLimit(topK: topK)

        try await withTemporaryEmbeddingStore { store in
            try await store.insertChunk(
                makeChunk(
                    id: "old-best",
                    source: "conversation:bounded",
                    language: "en",
                    createdAt: 1,
                    vector: [1, 0]
                )
            )

            for index in 0..<(candidateLimit + 20) {
                try await store.insertChunk(
                    makeChunk(
                        id: "new-\(index)",
                        source: "conversation:bounded",
                        language: "en",
                        createdAt: TimeInterval(index + 2),
                        vector: [0, 1]
                    )
                )
            }

            let results = try await store.searchSimilar(
                queryVector: [1, 0],
                topK: topK,
                source: "conversation:bounded",
                language: "en",
                minScore: -1
            )

            #expect(results.count == 1)
            #expect(results.first?.chunk.id != "old-best")
        }
    }

    @Test func embeddingStoreSearchLimitPreservesSourceAndLanguageFilters() async throws {
        let topK = 2
        let candidateLimit = EmbeddingStore.searchCandidateLimit(topK: topK)

        try await withTemporaryEmbeddingStore { store in
            try await store.insertChunk(
                makeChunk(
                    id: "target-old-best",
                    source: "conversation:target",
                    language: "fr",
                    createdAt: 1,
                    vector: [1, 0]
                )
            )

            for index in 0..<(candidateLimit + 5) {
                try await store.insertChunk(
                    makeChunk(
                        id: "target-new-\(index)",
                        source: "conversation:target",
                        language: "fr",
                        createdAt: TimeInterval(index + 2),
                        vector: [0, 1]
                    )
                )
            }

            for index in 0..<40 {
                try await store.insertChunk(
                    makeChunk(
                        id: "noise-\(index)",
                        source: "conversation:other",
                        language: "en",
                        createdAt: TimeInterval(index + 10_000),
                        vector: [1, 0]
                    )
                )
            }

            let results = try await store.searchSimilar(
                queryVector: [1, 0],
                topK: topK,
                source: "conversation:target",
                language: "fr",
                minScore: -1
            )

            #expect(results.count == topK)
            #expect(results.allSatisfy { $0.chunk.source == "conversation:target" })
            #expect(results.allSatisfy { $0.chunk.language == "fr" })
            #expect(results.allSatisfy { $0.chunk.id != "target-old-best" })
        }
    }

    @Test func embeddingRequestCacheEvictsLeastRecentlyUsedEntry() {
        var cache = EmbeddingRequestCache(capacity: 2)
        cache.insert(makeEmbeddingResult(marker: 1), for: "a")
        cache.insert(makeEmbeddingResult(marker: 2), for: "b")

        _ = cache.value(for: "a")
        cache.insert(makeEmbeddingResult(marker: 3), for: "c")

        #expect(cache.count == 2)
        #expect(cache.value(for: "a") != nil)
        #expect(cache.value(for: "b") == nil)
        #expect(cache.value(for: "c") != nil)
    }

    @Test func embeddingRequestCacheCapacityIsAlwaysBounded() {
        var cache = EmbeddingRequestCache(capacity: 0)
        cache.insert(makeEmbeddingResult(marker: 1), for: "a")
        cache.insert(makeEmbeddingResult(marker: 2), for: "b")

        #expect(cache.count == 1)
        #expect(cache.value(for: "a") == nil)
        #expect(cache.value(for: "b") != nil)
    }

    @Test func tokenizerRoundTripEncodeDecode() async throws {
        let fixtureURL = try makeTokenizerFixtureDirectory(
            vocab: makeByteLevelVocab(),
            addedTokens: [
                (token: "<|begin_of_text|>", id: 300_000),
                (token: "<|eot_id|>", id: 300_001),
                (token: "<|start_header_id|>", id: 300_002),
                (token: "<|end_header_id|>", id: 300_003)
            ],
            config: [
                "bos_token": "<|begin_of_text|>",
                "eos_token": "<|eot_id|>"
            ]
        )
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        let tokenizer = TokenizerService()
        try await tokenizer.load(from: fixtureURL)

        let sample = "monGARS says hello 42!"
        let encoded = await tokenizer.encode(sample)
        let bosID = await tokenizer.bosTokenId
        #expect(encoded.first == bosID)
        #expect(encoded.count > 1)

        let decoded = await tokenizer.decode(encoded)
        #expect(decoded == sample)
    }

    @Test func tokenizerInfersSpecialTokenIDsFromKnownAddedTokens() async throws {
        let fixtureURL = try makeTokenizerFixtureDirectory(
            vocab: makeByteLevelVocab(),
            addedTokens: [
                (token: "<|begin_of_text|>", id: 410_000),
                (token: "<|end_of_text|>", id: 410_001)
            ],
            config: [
                "model_max_length": 2048
            ]
        )
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        let tokenizer = TokenizerService()
        try await tokenizer.load(from: fixtureURL)

        #expect(await tokenizer.bosTokenId == 410_000)
        #expect(await tokenizer.eosTokenId == 410_001)
    }

    @Test func tokenizerRejectsStructurallyValidButSemanticallyBrokenData() async throws {
        let fixtureURL = try makeTokenizerFixtureDirectory(
            vocab: ["x": 0],
            addedTokens: [
                (token: "<|begin_of_text|>", id: 500_000),
                (token: "<|eot_id|>", id: 500_001)
            ],
            config: [
                "bos_token": "<|begin_of_text|>",
                "eos_token": "<|eot_id|>"
            ]
        )
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        let tokenizer = TokenizerService()

        do {
            try await tokenizer.load(from: fixtureURL)
            Issue.record("Expected semantic tokenizer validation failure, but load succeeded")
        } catch let error as TokenizerError {
            guard case .semanticValidationFailed(let reason) = error else {
                Issue.record("Expected semantic validation error, got: \(error.localizedDescription)")
                return
            }
            #expect(reason.contains("Readiness probe"))
        } catch {
            Issue.record("Unexpected error type: \(error.localizedDescription)")
        }
    }

    private func makeTokenizerFixtureDirectory(
        vocab: [String: Int],
        addedTokens: [(token: String, id: Int)],
        config: [String: Any]? = nil,
        specialTokensMap: [String: Any]? = nil
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenizerFixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let tokenizerJSON: [String: Any] = [
            "model": [
                "vocab": vocab,
                "merges": [String]()
            ],
            "added_tokens": addedTokens.map { ["id": $0.id, "content": $0.token] }
        ]

        try writeJSON(tokenizerJSON, to: directory.appendingPathComponent("tokenizer.json"))

        if let config {
            try writeJSON(config, to: directory.appendingPathComponent("tokenizer_config.json"))
        }
        if let specialTokensMap {
            try writeJSON(specialTokensMap, to: directory.appendingPathComponent("special_tokens_map.json"))
        }

        return directory
    }

    private func writeJSON(_ value: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private func makeByteLevelVocab() -> [String: Int] {
        var byteEncoder: [Int: String] = [:]

        for byte in 33...126 { byteEncoder[byte] = String(UnicodeScalar(byte)!) }
        for byte in 161...172 { byteEncoder[byte] = String(UnicodeScalar(byte)!) }
        for byte in 174...255 { byteEncoder[byte] = String(UnicodeScalar(byte)!) }

        var extraScalar = 256
        for byte in 0...255 where byteEncoder[byte] == nil {
            byteEncoder[byte] = String(UnicodeScalar(extraScalar)!)
            extraScalar += 1
        }

        var vocab: [String: Int] = [:]
        for byte in 0...255 {
            if let token = byteEncoder[byte] {
                vocab[token] = byte
            }
        }
        return vocab
    }

    private func withTemporaryEmbeddingStore(
        _ body: (EmbeddingStore) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmbeddingStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dbURL = root.appendingPathComponent("embeddings.sqlite3")
        let store = EmbeddingStore(databaseURL: dbURL)
        try await store.open()

        do {
            try await body(store)
            await store.close()
            try FileManager.default.removeItem(at: root)
        } catch {
            await store.close()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private func makeChunk(
        id: String,
        source: String,
        language: String?,
        createdAt: TimeInterval,
        vector: [Float]
    ) -> SemanticChunk {
        SemanticChunk(
            id: id,
            content: "content-\(id)",
            source: source,
            language: language,
            createdAt: Date(timeIntervalSince1970: createdAt),
            vector: vector,
            dimensions: vector.count
        )
    }

    private func makeEmbeddingResult(marker: Float) -> EmbeddingResult {
        EmbeddingResult(
            vector: [marker],
            dimensions: 1,
            computeTimeSeconds: 0.01,
            inputTokenCount: Int(marker)
        )
    }
}
