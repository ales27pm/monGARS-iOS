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

    func loadLLMIfAvailable() async {
        let variant = modelDownloadManager.selectedLLMVariant
        guard modelDownloadManager.llmState.isDownloaded else {
            runtimeState = .degraded("LLM model not downloaded")
            return
        }

        runtimeState = .loadingLLM

        let modelDir = modelDownloadManager.modelDirectory(for: variant)
        let tokenizerDir = modelDownloadManager.modelDirectory(for: variant)
            .deletingLastPathComponent()
            .appendingPathComponent(variant.tokenizerFolderName, isDirectory: true)

        let tokenizerFallback = modelDir

        let actualTokenizerDir: URL
        if FileManager.default.fileExists(atPath: tokenizerDir.path) {
            actualTokenizerDir = tokenizerDir
        } else {
            actualTokenizerDir = tokenizerFallback
        }

        do {
            try await llmEngine.loadModel(variant: variant, modelURL: resolveModelURL(modelDir, variant: variant), tokenizerDirectory: actualTokenizerDir)
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
        guard modelDownloadManager.embeddingState.isDownloaded else { return }

        runtimeState = .loadingEmbedding

        let modelDir = modelDownloadManager.modelDirectory(for: .graniteEmbedding)
        let modelURL = resolveModelURL(modelDir, variant: .graniteEmbedding)

        let tokenizerDir = modelDownloadManager.modelDirectory(for: .graniteEmbedding)
            .deletingLastPathComponent()
            .appendingPathComponent(ModelVariant.graniteEmbedding.tokenizerFolderName, isDirectory: true)

        let actualTokenizerDir: URL?
        if FileManager.default.fileExists(atPath: tokenizerDir.path) {
            actualTokenizerDir = tokenizerDir
        } else if FileManager.default.fileExists(atPath: modelDir.appendingPathComponent("tokenizer.json").path) {
            actualTokenizerDir = modelDir
        } else {
            actualTokenizerDir = nil
        }

        do {
            try await embeddingEngine.loadModel(modelURL: modelURL, tokenizerDirectory: actualTokenizerDir)
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
        let currentVariant = modelDownloadManager.selectedLLMVariant
        guard currentVariant == .llama3B else {
            runtimeState = .error("No fallback model available")
            return
        }

        logger.info("Attempting fallback to 1B model")

        guard modelDownloadManager.llmState.isDownloaded || true else {
            runtimeState = .error("Fallback model not downloaded")
            return
        }

        let fallbackDir = modelDownloadManager.modelDirectory(for: .llama1B)
        guard FileManager.default.fileExists(atPath: fallbackDir.path) else {
            runtimeState = .error("Fallback model not available on disk")
            return
        }

        await llmEngine.unloadModel()

        do {
            let modelURL = resolveModelURL(fallbackDir, variant: .llama1B)
            let tokenizerDir = fallbackDir
            try await llmEngine.loadModel(variant: .llama1B, modelURL: modelURL, tokenizerDirectory: tokenizerDir)
            await llmEngine.warmup()
            llmReady = await llmEngine.isReady
            runtimeState = .degraded("Running fallback 1B model")
        } catch {
            runtimeState = .error("Fallback load failed: \(error.localizedDescription)")
            llmReady = false
        }
    }

    var isFullyOperational: Bool {
        llmReady
    }

    // MARK: - Private

    private func resolveModelURL(_ directory: URL, variant: ModelVariant) -> URL {
        let mlmodelc = directory.appendingPathComponent(variant.modelFileName)
        if FileManager.default.fileExists(atPath: mlmodelc.path) {
            return mlmodelc
        }

        let mlpackage = directory.appendingPathComponent("\(variant.rawValue).mlpackage")
        if FileManager.default.fileExists(atPath: mlpackage.path) {
            return mlpackage
        }

        let mlmodel = directory.appendingPathComponent("\(variant.rawValue).mlmodel")
        if FileManager.default.fileExists(atPath: mlmodel.path) {
            return mlmodel
        }

        return mlmodelc
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
