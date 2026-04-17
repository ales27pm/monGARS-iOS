//
//  MonGARSTests.swift
//  MonGARSTests
//
//  Created by Rork on April 10, 2026.
//

import Testing
@testable import MonGARS
import AVFoundation
import Foundation
import Speech

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

    @Test func retryPlannerHandlesRetryableHTTPStatusesAndCancellationDeterministically() {
        let planner = DownloadRetryPlanner(maxRetriesPerURL: 2, baseDelaySeconds: 1, maxDelaySeconds: 8)

        let first500 = planner.nextAction(for: .httpStatus(500), retryCountOnCurrentURL: 0, hasFallbackURL: false)
        let second429 = planner.nextAction(for: .httpStatus(429), retryCountOnCurrentURL: 1, hasFallbackURL: false)
        let exhausted500 = planner.nextAction(for: .httpStatus(500), retryCountOnCurrentURL: 2, hasFallbackURL: false)
        let cancelled = planner.nextAction(for: .cancelled, retryCountOnCurrentURL: 0, hasFallbackURL: true)

        #expect(first500 == .retry(delaySeconds: 1))
        #expect(second429 == .retry(delaySeconds: 2))
        #expect(exhausted500 == .fail)
        #expect(cancelled == .fail)
        #expect(DownloadURLSelector.nextIndex(after: .fail, currentIndex: 0, totalURLCount: 2) == nil)
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

    @MainActor
    @Test func deletingSelectedChatModelResetsSelectionToFallback() {
        let manager = ModelDownloadManager()
        let deletedSourceID = ModelSourceCatalog.defaultChatSourceID

        manager.selectedChatSourceID = deletedSourceID
        manager.refreshSelectedStates()
        manager.deleteModel(sourceID: deletedSourceID)

        #expect(manager.selectedChatSourceID != deletedSourceID)
        #expect(ModelSourceCatalog.chatSource(for: manager.selectedChatSourceID) != nil)
    }

    @MainActor
    @Test func deletingSelectedEmbeddingModelResetsSelectionToValidFallback() {
        let manager = ModelDownloadManager()
        let deletedSourceID = ModelSourceCatalog.defaultEmbeddingSourceID

        manager.selectedEmbeddingSourceID = deletedSourceID
        manager.refreshSelectedStates()
        manager.deleteModel(sourceID: deletedSourceID)

        #expect(manager.selectedEmbeddingSourceID != deletedSourceID)
        #expect(ModelSourceCatalog.embeddingSource(for: manager.selectedEmbeddingSourceID) != nil)
    }

    @MainActor
    @Test func launchValidationCorrectsPersistedSelectionThatIsMissingOnDisk() {
        let manager = ModelDownloadManager()
        let result = manager.validateSelectionOnLaunch(
            persistedChatSourceID: "qwen2.5-3b-4bit",
            persistedEmbeddingSourceID: ModelSourceCatalog.defaultEmbeddingSourceID,
            installedChatSourceIDs: [ModelSourceCatalog.fallbackChatSourceID],
            installedEmbeddingSourceIDs: [ModelSourceCatalog.defaultEmbeddingSourceID]
        )

        #expect(result.chatSourceID == ModelSourceCatalog.fallbackChatSourceID)
        #expect(result.chatNeedsPersistenceUpdate)
        #expect(result.embeddingSourceID == ModelSourceCatalog.defaultEmbeddingSourceID)
        #expect(result.embeddingNeedsPersistenceUpdate == false)
    }

    @MainActor
    @Test func obsoletePersistedModelIDsMigrateToSupportedSources() {
        let manager = ModelDownloadManager()
        let result = manager.validateSelectionOnLaunch(
            persistedChatSourceID: "llama-3.2-3b-instruct",
            persistedEmbeddingSourceID: "granite-embedding-278m",
            installedChatSourceIDs: [ModelSourceCatalog.defaultChatSourceID],
            installedEmbeddingSourceIDs: [ModelSourceCatalog.defaultEmbeddingSourceID]
        )

        #expect(result.chatSourceID == ModelSourceCatalog.defaultChatSourceID)
        #expect(result.embeddingSourceID == ModelSourceCatalog.defaultEmbeddingSourceID)
        #expect(result.chatNeedsPersistenceUpdate)
        #expect(result.embeddingNeedsPersistenceUpdate)
    }

    @MainActor
    @Test func modelDownloadManagerTracksAndClearsStructuredLastFailure() {
        let manager = ModelDownloadManager()
        let invalidSourceID = "invalid-source-id"

        manager.startDownload(sourceID: invalidSourceID)
        let failure = manager.lastFailureReport(for: invalidSourceID)

        #expect(failure != nil)
        #expect(failure?.stage == .preflight)
        #expect(failure?.recoveryActions.contains(.openModelSettings) == true)
        #expect(failure?.recoveryActions.contains(.chooseAnotherModel) == true)

        manager.cancelDownload(sourceID: invalidSourceID)
        #expect(manager.lastFailureReport(for: invalidSourceID) == nil)
    }

    @Test func downloadDiagnosticErrorsExposeActionableRecovery() {
        let accessDenied = DownloadDiagnosticError.accessDenied(url: "https://example.com", statusCode: 403)
        #expect(accessDenied.recoveryActions == [.acceptModelLicense, .retryDownload])

        let rateLimited = DownloadDiagnosticError.rateLimited(url: "https://example.com")
        #expect(rateLimited.recoveryActions == [.waitAndRetry, .retryDownload])

        let noURL = DownloadDiagnosticError.noDownloadURL(sourceID: "chat")
        #expect(noURL.recoveryActions == [.chooseAnotherModel, .openModelSettings])
    }

    @Test func runtimeGuidanceMapsAvailabilityIssuesToRecoveryActions() {
        let notInstalled = ModelRuntimeCoordinator.guidance(for: .notInstalled)
        #expect(notInstalled?.recoveryActions == [.openModelSettings, .retryDownload])

        let tokenizerInvalid = ModelRuntimeCoordinator.guidance(for: .runtimeLoadFailed(.tokenizerInvalid))
        #expect(tokenizerInvalid?.recoveryActions.contains(.reinstallModel) == true)
        #expect(tokenizerInvalid?.recoveryActions.contains(.openModelSettings) == true)

        let oom = ModelRuntimeCoordinator.guidance(for: .runtimeLoadFailed(.outOfMemory))
        #expect(oom?.recoveryActions == [.closeOtherApps, .retryRuntimeLoad])
    }

    @Test func permissionsManagerMapsSpeechAuthorizationStatuses() {
        #expect(PermissionsManager.voiceAuthorizationState(forSpeechAuthorizationStatus: .authorized) == .granted)
        #expect(PermissionsManager.voiceAuthorizationState(forSpeechAuthorizationStatus: .notDetermined) == .notDetermined)
        #expect(PermissionsManager.voiceAuthorizationState(forSpeechAuthorizationStatus: .denied) == .denied)
        #expect(PermissionsManager.voiceAuthorizationState(forSpeechAuthorizationStatus: .restricted) == .restricted)
    }

    @Test func permissionsManagerMapsMicrophoneAuthorizationStatuses() {
        #expect(PermissionsManager.voiceAuthorizationState(forMicrophonePermission: AVAudioSession.RecordPermission.granted) == .granted)
        #expect(PermissionsManager.voiceAuthorizationState(forMicrophonePermission: AVAudioSession.RecordPermission.undetermined) == .notDetermined)
        #expect(PermissionsManager.voiceAuthorizationState(forMicrophonePermission: AVAudioSession.RecordPermission.denied) == .denied)
    }

    @Test func permissionsManagerSettingsRecoveryDecisionUsesDeniedStates() {
        #expect(PermissionsManager.shouldOfferVoiceSettingsRecovery(microphoneState: .denied, speechState: .granted))
        #expect(PermissionsManager.shouldOfferVoiceSettingsRecovery(microphoneState: .granted, speechState: .restricted))
        #expect(PermissionsManager.shouldOfferVoiceSettingsRecovery(microphoneState: .notDetermined, speechState: .granted) == false)
    }

    @MainActor
    @Test func permissionsManagerMarksAppActiveRefreshTrigger() {
        let manager = PermissionsManager()
        manager.refreshAfterAppBecomesActive()
        #expect(manager.lastRefreshTrigger == .appDidBecomeActive)
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

    @Test func llmEngineBoundedTokenHistoryKeepsMostRecentTokens() {
        var history = LLMEngine.BoundedTokenHistory(capacity: 4, initialTokens: [1, 2, 3, 4, 5])

        #expect(history.asArray() == [2, 3, 4, 5])
        #expect(history.count == 4)

        let didEvict = history.append(6)
        #expect(didEvict)
        #expect(history.asArray() == [3, 4, 5, 6])
        #expect(history.suffixArray(2) == [5, 6])
    }

    @Test func llmEngineRepetitionPenaltyWindowUsesRecentTokensOnly() {
        let tokens = Array(0..<100)
        let unique = LLMEngine.uniqueRecentTokensForRepetitionPenalty(tokens: tokens, windowSize: 8)

        #expect(unique == Set(92..<100))
    }

    @Test func llmEngineBoundedTokenHistoryRecentWindowDeduplicatesTokens() {
        let history = LLMEngine.BoundedTokenHistory(capacity: 16, initialTokens: [4, 4, 5, 6, 6, 7, 8])
        let unique = history.uniqueTokensInRecentWindow(windowSize: 4)

        #expect(unique == Set([6, 7, 8]))
    }

    @Test func toolCallParserExtractsValidToolCall() throws {
        let response = #"<tool_call>{"name":"create_reminder","arguments":{"title":"Buy milk"}}</tool_call>"#
        let parsed = try ToolCallParser.parseToolCall(from: response, schemas: parserTestSchemas())

        #expect(parsed?.toolName == "create_reminder")
        #expect(parsed?.arguments["title"] == "Buy milk")
    }

    @Test func toolCallParserUsesFinalBalancedEnvelopeWhenTextHasMultipleBlocks() throws {
        let response = """
        I will try one.
        <tool_call>{"name":"create_reminder","arguments":{"title":"First"}}</tool_call>
        Ignore that and use the latest:
        <tool_call>{"name":"web_search","arguments":{"query":"Montreal weather","language":"en"}}</tool_call>
        """

        let parsed = try ToolCallParser.parseToolCall(from: response, schemas: parserTestSchemas())
        #expect(parsed?.toolName == "web_search")
        #expect(parsed?.arguments["query"] == "Montreal weather")
    }

    @Test func toolCallParserRejectsMalformedJSON() {
        let response = #"<tool_call>{"name":"create_reminder","arguments":{"title":"Buy milk"}</tool_call>"#

        do {
            _ = try ToolCallParser.parseToolCall(from: response, schemas: parserTestSchemas())
            Issue.record("Expected malformed JSON to throw, but parse succeeded.")
        } catch let error as ToolCallParsingError {
            #expect(error == .malformedJSON)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test func toolCallParserRejectsMissingRequiredArguments() {
        let response = #"<tool_call>{"name":"create_reminder","arguments":{}}</tool_call>"#

        do {
            _ = try ToolCallParser.parseToolCall(from: response, schemas: parserTestSchemas())
            Issue.record("Expected missing required args error, but parse succeeded.")
        } catch let error as ToolCallParsingError {
            #expect(error == .missingRequiredArguments(["title"]))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test func toolCallParserRejectsUnknownToolName() {
        let response = #"<tool_call>{"name":"nonexistent_tool","arguments":{"title":"Buy milk"}}</tool_call>"#

        do {
            _ = try ToolCallParser.parseToolCall(from: response, schemas: parserTestSchemas())
            Issue.record("Expected unknown tool error, but parse succeeded.")
        } catch let error as ToolCallParsingError {
            #expect(error == .unknownTool("nonexistent_tool"))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test func toolCallParserRejectsArgumentsWhenTheyAreNotAJSONObject() {
        let response = #"<tool_call>{"name":"create_reminder","arguments":"not-an-object"}</tool_call>"#

        do {
            _ = try ToolCallParser.parseToolCall(from: response, schemas: parserTestSchemas())
            Issue.record("Expected non-object arguments error, but parse succeeded.")
        } catch let error as ToolCallParsingError {
            #expect(error == .argumentsMustBeObject)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test func toolCallParserSchemaValidationCoercesSupportedScalarTypes() throws {
        let response = #"<tool_call>{"name":"set_timer","arguments":{"seconds":"15","enabled":1}}</tool_call>"#
        let parsed = try ToolCallParser.parseToolCall(from: response, schemas: parserTypedSchemas())

        #expect(parsed?.toolName == "set_timer")
        #expect(parsed?.arguments["seconds"] == "15")
        #expect(parsed?.arguments["enabled"] == "true")
    }

    @Test func toolCallParserSchemaValidationRejectsInvalidTypedArguments() {
        let response = #"<tool_call>{"name":"set_timer","arguments":{"seconds":"fifteen","enabled":"yes"}}</tool_call>"#

        do {
            _ = try ToolCallParser.parseToolCall(from: response, schemas: parserTypedSchemas())
            Issue.record("Expected invalid argument type error, but parse succeeded.")
        } catch let error as ToolCallParsingError {
            #expect(error == .invalidArgumentType(argument: "seconds", expected: .integer))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
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

    @Test func tokenizerResolvesSpecialTokenIDsFromSpecialTokensMap() async throws {
        let fixtureURL = try makeTokenizerFixtureDirectory(
            vocab: makeByteLevelVocab(),
            addedTokens: [
                (token: "<|begin_of_text|>", id: 420_000),
                (token: "<|eot_id|>", id: 420_001),
                (token: "<|custom_special|>", id: 420_002)
            ],
            config: [
                "model_max_length": 4096
            ],
            specialTokensMap: [
                "bos_token": ["content": "<|begin_of_text|>"],
                "eos_token": ["token": "<|eot_id|>"],
                "additional_special_tokens": [
                    ["id": 420_002, "content": "<|custom_special|>"]
                ]
            ]
        )
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        let tokenizer = TokenizerService()
        try await tokenizer.load(from: fixtureURL)

        #expect(await tokenizer.bosTokenId == 420_000)
        #expect(await tokenizer.eosTokenId == 420_001)
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

    private func parserTestSchemas() -> [ToolSchema] {
        [
            ToolSchema(
                name: "create_reminder",
                description: "Creates a reminder",
                parameters: [
                    ToolParameter(name: "title", description: "Reminder title", type: .string, required: true),
                    ToolParameter(name: "notes", description: "Reminder notes", type: .string, required: false),
                ],
                requiresApproval: true
            ),
            ToolSchema(
                name: "web_search",
                description: "Searches the web",
                parameters: [
                    ToolParameter(name: "query", description: "Search query", type: .string, required: true),
                    ToolParameter(name: "language", description: "Language code", type: .string, required: false),
                ],
                requiresApproval: true
            )
        ]
    }

    private func parserTypedSchemas() -> [ToolSchema] {
        [
            ToolSchema(
                name: "set_timer",
                description: "Sets a timer",
                parameters: [
                    ToolParameter(name: "seconds", description: "Timer duration in seconds", type: .integer, required: true),
                    ToolParameter(name: "enabled", description: "Whether the timer is enabled", type: .boolean, required: true),
                ],
                requiresApproval: true
            )
        ]
    }
}
