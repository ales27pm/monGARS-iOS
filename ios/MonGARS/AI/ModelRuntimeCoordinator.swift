import Foundation
import os

nonisolated enum RuntimeState: Sendable, Equatable {
    case idle
    case loadingLLM
    case loadingEmbedding
    case ready
    case degraded(String)
    case error(String)
}

@Observable
@MainActor
final class ModelRuntimeCoordinator {
    nonisolated enum LLMRuntimeFailureCategory: Sendable, Equatable {
        case modelFilesMissing
        case tokenizerInvalid
        case outOfMemory
        case initializationFailed
    }

    nonisolated enum LLMAvailabilityIssue: Sendable, Equatable {
        case notInstalled
        case tokenizerMissing
        case runtimeLoadFailed(LLMRuntimeFailureCategory)
    }

    let llmEngine: LLMEngine
    let embeddingEngine: EmbeddingEngine
    let diagnostics: InferenceDiagnostics
    let modelDownloadManager: ModelDownloadManager

    private(set) var runtimeState: RuntimeState = .idle
    private(set) var llmReady: Bool = false
    private(set) var embeddingReady: Bool = false
    private(set) var lastLLMLoadError: String?
    private(set) var lastLLMLoadFailureCategory: LLMRuntimeFailureCategory?

    private let logger = Logger(subsystem: "com.mongars.ai", category: "runtime")
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var thermalObserver: NSObjectProtocol?

    init(modelDownloadManager: ModelDownloadManager) {
        let diag = InferenceDiagnostics()
        self.diagnostics = diag
        self.llmEngine = LLMEngine(diagnostics: diag)
        self.embeddingEngine = EmbeddingEngine(diagnostics: diag)
        self.modelDownloadManager = modelDownloadManager
        setupSystemMonitoring()
    }

    var activePromptFormat: PromptFormat {
        let sourceID = modelDownloadManager.selectedChatSourceID
        return ModelSourceCatalog.chatSource(for: sourceID)?.promptFormat ?? .llama3
    }

    func loadLLMIfAvailable() async {
        await loadLLMIfAvailable(expectedSourceID: nil)
    }

    private func loadLLMIfAvailable(expectedSourceID: ModelSourceID?) async {
        let sourceID = modelDownloadManager.selectedChatSourceID
        if let expectedSourceID, expectedSourceID != sourceID { return }
        let llmState = modelDownloadManager.llmState
        guard llmState.isDownloaded || llmState.isInstalledPartially else {
            runtimeState = .degraded("LLM model not downloaded")
            clearLLMFailureState()
            return
        }

        guard modelDownloadManager.hasTokenizer(for: sourceID) else {
            runtimeState = .degraded("Tokenizer missing for \(sourceID). Chat model cannot load without tokenizer files.")
            llmReady = false
            clearLLMFailureState()
            return
        }

        runtimeState = .loadingLLM
        clearLLMFailureState()

        guard let modelURL = modelDownloadManager.modelFileURL(for: sourceID) else {
            runtimeState = .error("Model files not found on disk")
            llmReady = false
            lastLLMLoadError = "Model files not found on disk"
            lastLLMLoadFailureCategory = .modelFilesMissing
            return
        }

        let source = ModelSourceCatalog.chatSource(for: sourceID)
        let contextWindow = source?.contextWindowTokens ?? 2048

        let tokenizerDir = modelDownloadManager.tokenizerDirectory(for: sourceID)
            ?? modelDownloadManager.modelDirectory(for: sourceID)

        do {
            try await llmEngine.loadModel(sourceID: sourceID, modelURL: modelURL, tokenizerDirectory: tokenizerDir, contextWindow: contextWindow)
            if let expectedSourceID, modelDownloadManager.selectedChatSourceID != expectedSourceID {
                await llmEngine.unloadModel()
                return
            }
            await llmEngine.warmup()
            if let expectedSourceID, modelDownloadManager.selectedChatSourceID != expectedSourceID {
                await llmEngine.unloadModel()
                return
            }
            llmReady = await llmEngine.isReady
            if let expectedSourceID, modelDownloadManager.selectedChatSourceID != expectedSourceID {
                llmReady = false
                await llmEngine.unloadModel()
                return
            }
            updateRuntimeState()
        } catch {
            logger.error("LLM load failed: \(error.localizedDescription)")
            if let expectedSourceID, modelDownloadManager.selectedChatSourceID != expectedSourceID { return }
            runtimeState = .error("Failed to load language model: \(error.localizedDescription)")
            llmReady = false
            lastLLMLoadError = error.localizedDescription
            lastLLMLoadFailureCategory = classifyLLMLoadFailure(error)
        }
    }

    func loadEmbeddingIfAvailable() async {
        await loadEmbeddingIfAvailable(expectedSourceID: nil)
    }

    private func loadEmbeddingIfAvailable(expectedSourceID: ModelSourceID?) async {
        let sourceID = modelDownloadManager.selectedEmbeddingSourceID
        if let expectedSourceID, expectedSourceID != sourceID { return }
        guard modelDownloadManager.embeddingState.isDownloaded else { return }

        runtimeState = .loadingEmbedding

        guard let modelURL = modelDownloadManager.modelFileURL(for: sourceID) else {
            embeddingReady = false
            updateRuntimeState()
            return
        }

        let source = ModelSourceCatalog.embeddingSource(for: sourceID)
        let contextWindow = source?.contextWindowTokens ?? 512
        let tokenizerDir = modelDownloadManager.tokenizerDirectory(for: sourceID)

        do {
            try await embeddingEngine.loadModel(sourceID: sourceID, modelURL: modelURL, tokenizerDirectory: tokenizerDir, contextWindow: contextWindow)
            if let expectedSourceID, modelDownloadManager.selectedEmbeddingSourceID != expectedSourceID {
                await embeddingEngine.unloadModel()
                return
            }
            embeddingReady = await embeddingEngine.isReady
            if let expectedSourceID, modelDownloadManager.selectedEmbeddingSourceID != expectedSourceID {
                embeddingReady = false
                await embeddingEngine.unloadModel()
                return
            }
            updateRuntimeState()
        } catch {
            logger.error("Embedding load failed: \(error.localizedDescription)")
            if let expectedSourceID, modelDownloadManager.selectedEmbeddingSourceID != expectedSourceID { return }
            embeddingReady = false
            updateRuntimeState()
        }
    }

    func loadAllAvailable() async {
        await loadLLMIfAvailable()
        await loadEmbeddingIfAvailable()
    }

    func reloadSelectedChatModelRuntime() async {
        let startID = modelDownloadManager.selectedChatSourceID
        await llmEngine.unloadModel()
        guard modelDownloadManager.selectedChatSourceID == startID else { return }
        llmReady = false
        clearLLMFailureState()

        let llmState = modelDownloadManager.llmState
        guard llmState.isInstalled || llmState.isInstalledPartially else {
            runtimeState = .degraded("LLM model not downloaded")
            return
        }

        await loadLLMIfAvailable(expectedSourceID: startID)
    }

    func reloadSelectedEmbeddingModelRuntime() async {
        let startID = modelDownloadManager.selectedEmbeddingSourceID
        await embeddingEngine.unloadModel()
        guard modelDownloadManager.selectedEmbeddingSourceID == startID else { return }
        embeddingReady = false

        guard modelDownloadManager.embeddingState.isInstalled else {
            updateRuntimeState()
            return
        }

        await loadEmbeddingIfAvailable(expectedSourceID: startID)
    }

    func unloadAll() async {
        await llmEngine.unloadModel()
        await embeddingEngine.unloadModel()
        llmReady = false
        embeddingReady = false
        clearLLMFailureState()
        runtimeState = .idle
    }

    func attemptFallback() async {
        let fallbackID = ModelSourceCatalog.fallbackChatSourceID
        let currentID = modelDownloadManager.selectedChatSourceID

        guard currentID != fallbackID else {
            runtimeState = .error("No fallback model available")
            return
        }

        logger.info("Attempting fallback to \(fallbackID)")

        let fallbackDir = modelDownloadManager.modelDirectory(for: fallbackID)
        guard FileManager.default.fileExists(atPath: fallbackDir.path) else {
            runtimeState = .error("Fallback model not available on disk")
            return
        }

        await llmEngine.unloadModel()
        clearLLMFailureState()

        do {
            guard let modelURL = modelDownloadManager.modelFileURL(for: fallbackID) else {
                runtimeState = .error("Fallback model files missing")
                return
            }
            let source = ModelSourceCatalog.chatSource(for: fallbackID)
            let contextWindow = source?.contextWindowTokens ?? 2048
            let tokenizerDir = modelDownloadManager.tokenizerDirectory(for: fallbackID) ?? fallbackDir
            try await llmEngine.loadModel(sourceID: fallbackID, modelURL: modelURL, tokenizerDirectory: tokenizerDir, contextWindow: contextWindow)
            await llmEngine.warmup()
            llmReady = await llmEngine.isReady
            runtimeState = .degraded("Running fallback model")
        } catch {
            runtimeState = .error("Fallback load failed: \(error.localizedDescription)")
            llmReady = false
            lastLLMLoadError = error.localizedDescription
            lastLLMLoadFailureCategory = classifyLLMLoadFailure(error)
        }
    }

    var isFullyOperational: Bool {
        llmReady
    }

    var llmAvailabilityIssue: LLMAvailabilityIssue? {
        let sourceID = modelDownloadManager.selectedChatSourceID
        if !(modelDownloadManager.llmState.isInstalled || modelDownloadManager.llmState.isInstalledPartially) {
            return .notInstalled
        }
        if !modelDownloadManager.hasTokenizer(for: sourceID) {
            return .tokenizerMissing
        }
        guard !llmReady else { return nil }
        if case .loadingLLM = runtimeState {
            return nil
        }
        if case .idle = runtimeState {
            return nil
        }
        if case .error = runtimeState {
            return .runtimeLoadFailed(lastLLMLoadFailureCategory ?? .initializationFailed)
        }
        if lastLLMLoadFailureCategory != nil {
            return .runtimeLoadFailed(lastLLMLoadFailureCategory ?? .initializationFailed)
        }
        return nil
    }

    private func updateRuntimeState() {
        if llmReady && embeddingReady {
            runtimeState = .ready
        } else if llmReady {
            runtimeState = .ready
        } else if case .error = runtimeState {
            return
        } else {
            runtimeState = .degraded("Some models not loaded")
        }
    }

    private func clearLLMFailureState() {
        lastLLMLoadError = nil
        lastLLMLoadFailureCategory = nil
    }

    private func classifyLLMLoadFailure(_ error: Error) -> LLMRuntimeFailureCategory {
        let message = error.localizedDescription.lowercased()
        if message.contains("tokenizer") {
            return .tokenizerInvalid
        }
        if message.contains("memory") || message.contains("out of memory") {
            return .outOfMemory
        }
        if message.contains("file") || message.contains("not found") || message.contains("missing") {
            return .modelFilesMissing
        }
        return .initializationFailed
    }

    private func setupSystemMonitoring() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.handleMemoryPressure()
            }
        }
        source.resume()
        memoryPressureSource = source

        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.handleThermalChange()
            }
        }
    }

    private func handleMemoryPressure() async {
        logger.warning("System memory pressure detected")
        await llmEngine.handleMemoryPressure()
        llmReady = await llmEngine.isReady

        if !llmReady {
            runtimeState = .degraded("Model unloaded due to memory pressure")
            lastLLMLoadFailureCategory = .outOfMemory
            lastLLMLoadError = "Model unloaded due to memory pressure"
        }
    }

    private func handleThermalChange() async {
        let thermal = ProcessInfo.processInfo.thermalState
        if thermal == .critical {
            logger.warning("Critical thermal state — triggering memory pressure handler")
            await handleMemoryPressure()
        }
    }

    func cleanup() {
        memoryPressureSource?.cancel()
        if let thermalObserver {
            NotificationCenter.default.removeObserver(thermalObserver)
        }
    }
}
