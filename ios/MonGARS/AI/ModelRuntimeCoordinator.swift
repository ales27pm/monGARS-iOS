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
    let llmEngine: LLMEngine
    let embeddingEngine: EmbeddingEngine
    let diagnostics: InferenceDiagnostics
    let modelDownloadManager: ModelDownloadManager

    private(set) var runtimeState: RuntimeState = .idle
    private(set) var llmReady: Bool = false
    private(set) var embeddingReady: Bool = false

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
        let sourceID = modelDownloadManager.selectedChatSourceID
        guard modelDownloadManager.llmState.isDownloaded else {
            runtimeState = .degraded("LLM model not downloaded")
            return
        }

        runtimeState = .loadingLLM

        guard let modelURL = modelDownloadManager.modelFileURL(for: sourceID) else {
            runtimeState = .error("Model files not found on disk")
            llmReady = false
            return
        }

        let source = ModelSourceCatalog.chatSource(for: sourceID)
        let contextWindow = source?.contextWindowTokens ?? 2048

        let tokenizerDir = modelDownloadManager.tokenizerDirectory(for: sourceID)
            ?? modelDownloadManager.modelDirectory(for: sourceID)

        do {
            try await llmEngine.loadModel(sourceID: sourceID, modelURL: modelURL, tokenizerDirectory: tokenizerDir, contextWindow: contextWindow)
            await llmEngine.warmup()
            llmReady = await llmEngine.isReady
            updateRuntimeState()
        } catch {
            logger.error("LLM load failed: \(error.localizedDescription)")
            runtimeState = .error("Failed to load language model: \(error.localizedDescription)")
            llmReady = false
        }
    }

    func loadEmbeddingIfAvailable() async {
        let sourceID = modelDownloadManager.selectedEmbeddingSourceID
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
            embeddingReady = await embeddingEngine.isReady
            updateRuntimeState()
        } catch {
            logger.error("Embedding load failed: \(error.localizedDescription)")
            embeddingReady = false
            updateRuntimeState()
        }
    }

    func loadAllAvailable() async {
        await loadLLMIfAvailable()
        await loadEmbeddingIfAvailable()
    }

    func unloadAll() async {
        await llmEngine.unloadModel()
        await embeddingEngine.unloadModel()
        llmReady = false
        embeddingReady = false
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
        }
    }

    var isFullyOperational: Bool {
        llmReady
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
