import Foundation
import ZIPFoundation
import os

nonisolated struct ModelSelectionValidationResult: Sendable, Equatable {
    let chatSourceID: ModelSourceID
    let embeddingSourceID: ModelSourceID
    let chatNeedsPersistenceUpdate: Bool
    let embeddingNeedsPersistenceUpdate: Bool
}

@Observable
@MainActor
final class ModelDownloadManager {
    private static let installMarkerFileName = ".install-complete.json"
    private static let installMarkerDateFormatter = ISO8601DateFormatter()

    @preconcurrency
    private final class SessionDelegateProxy: NSObject, URLSessionDownloadDelegate, URLSessionTaskDelegate, @unchecked Sendable {
        weak var owner: ModelDownloadManager?

        init(owner: ModelDownloadManager) {
            self.owner = owner
        }

        nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            Task { @MainActor [weak owner] in
                owner?.handleDownloadProgress(taskIdentifier: downloadTask.taskIdentifier, totalBytesWritten: totalBytesWritten, totalBytesExpected: totalBytesExpectedToWrite)
            }
        }

        nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            Task { @MainActor [weak owner] in
                owner?.handleTaskFinishedDownloading(taskIdentifier: downloadTask.taskIdentifier, location: location)
            }
        }

        nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            Task { @MainActor [weak owner] in
                owner?.handleTaskCompletion(task: task, error: error)
            }
        }
    }

    private struct DownloadResumeKey: Hashable, Sendable {
        let sourceID: ModelSourceID
        let remoteURL: String
    }

    private enum DownloadProgressMode: Sendable {
        case sourceOnly
        case cumulative(totalExpectedBytes: Int64, completedBytesBeforeCurrentTask: Int64)
    }

    private struct TaskRouting {
        let sourceID: ModelSourceID
        let resumeKey: DownloadResumeKey
        let progressMode: DownloadProgressMode
    }

    private enum DownloadTaskResult {
        case success(tempURL: URL, response: URLResponse?)
        case failure(error: Error, resumeData: Data?)
    }

    var llmState: ModelDownloadState = .notDownloaded
    var embeddingState: ModelDownloadState = .notDownloaded
    var selectedChatSourceID: ModelSourceID = ModelSourceCatalog.defaultChatSourceID
    var selectedEmbeddingSourceID: ModelSourceID = ModelSourceCatalog.defaultEmbeddingSourceID
    var currentInstallPhase: InstallPhase?
    var overallPhase: OverallInstallPhase?
    var lastDiagnosticMessage: String?
    var lastTokenizerFallbackResult: TokenizerFallbackResult?
    private(set) var lastFailureBySourceID: [ModelSourceID: ModelFailureReport] = [:]

    @ObservationIgnored private var activeTasks: [ModelSourceID: URLSessionDownloadTask] = [:]
    @ObservationIgnored private var taskToSourceID: [Int: ModelSourceID] = [:]
    @ObservationIgnored private var taskRouting: [Int: TaskRouting] = [:]
    @ObservationIgnored private var taskTempFiles: [Int: URL] = [:]
    @ObservationIgnored private var taskContinuations: [Int: CheckedContinuation<DownloadTaskResult, Never>] = [:]
    @ObservationIgnored private var resumeDataStore: [DownloadResumeKey: Data] = [:]
    @ObservationIgnored private var cancelledSources: Set<ModelSourceID> = []
    @ObservationIgnored private let retryPlanner = DownloadRetryPlanner()
    @ObservationIgnored private let logger = Logger(subsystem: "com.mongars.models", category: "download")
    @ObservationIgnored private let fileManager = FileManager.default
    @ObservationIgnored private lazy var sessionDelegate = SessionDelegateProxy(owner: self)
    @ObservationIgnored private lazy var downloadSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: sessionDelegate, delegateQueue: nil)
    }()

    init() {
        do {
            try AppStoragePaths.preparePersistentDirectories()
        } catch {
            let message = "Storage initialization failed. Free storage space and retry."
            llmState = .error(message)
            embeddingState = .error(message)
            lastDiagnosticMessage = message
            recordFailure(
                for: selectedChatSourceID,
                stage: .storage,
                message: message,
                recoveryActions: [.freeStorageSpace, .retryDownload]
            )
            recordFailure(
                for: selectedEmbeddingSourceID,
                stage: .storage,
                message: message,
                recoveryActions: [.freeStorageSpace, .retryDownload]
            )
            logger.error("Failed to prepare persistent directories: \(error.localizedDescription, privacy: .public)")
            return
        }
        checkExistingModels()
    }

    var selectedChatSource: ModelSource? {
        ModelSourceCatalog.chatSource(for: selectedChatSourceID)
    }

    var selectedEmbeddingSource: ModelSource? {
        ModelSourceCatalog.embeddingSource(for: selectedEmbeddingSourceID)
    }

    var isLLMReady: Bool { llmState.isInstalled }
    var isEmbeddingReady: Bool { embeddingState.isInstalled }
    var isFullyReady: Bool { isLLMReady && isEmbeddingReady }
    var isChatReady: Bool { isLLMReady }
    var isSemanticMemoryReady: Bool { isEmbeddingReady }

    var isLLMPartial: Bool { llmState.isInstalledPartially }

    var llmStorageUsed: String {
        guard isLLMReady || isLLMPartial else { return "0 MB" }
        return directorySizeString(at: modelDirectory(for: selectedChatSourceID))
    }

    var embeddingStorageUsed: String {
        guard isEmbeddingReady else { return "0 MB" }
        return directorySizeString(at: modelDirectory(for: selectedEmbeddingSourceID))
    }

    func startDownload(sourceID: ModelSourceID) {
        guard let source = ModelSourceCatalog.source(for: sourceID) else {
            let message = "Selected model source is invalid. Re-select a model in Settings."
            updateState(for: sourceID, state: .error(message))
            recordFailure(
                for: sourceID,
                stage: .preflight,
                message: message,
                recoveryActions: [.openModelSettings, .chooseAnotherModel]
            )
            return
        }

        cancelledSources.remove(sourceID)
        clearFailure(for: sourceID)

        guard source.isAvailableForDownload else {
            if case .unsupported(let reason) = source.downloadStrategy {
                updateState(for: sourceID, state: .unavailable(reason))
            } else {
                updateState(for: sourceID, state: .unavailable("Not available for download"))
            }
            return
        }

        guard hasSufficientSpace(for: source) else {
            let message = "Not enough storage to download this model. Free at least \(source.estimatedSizeDescription) and retry."
            updateState(for: sourceID, state: .error(message))
            recordFailure(
                for: sourceID,
                stage: .storage,
                message: message,
                recoveryActions: [.freeStorageSpace, .retryDownload]
            )
            return
        }

        if let existingTask = activeTasks[sourceID] {
            existingTask.cancel()
        }

        updateState(for: sourceID, state: ModelDownloadStateReducer.reduce(stateForSource(sourceID), event: .started))
        currentInstallPhase = .preflight

        Task { @MainActor [weak self] in
            guard let self else { return }
            switch source.downloadStrategy {
            case .archive(let filename):
                let urls = source.hfResolveURLs(path: filename)
                guard !urls.isEmpty else {
                    let diag = DownloadDiagnosticError.noDownloadURL(sourceID: sourceID)
                    updateState(for: sourceID, state: .error(diag.userMessage))
                    recordFailure(
                        for: sourceID,
                        stage: .preflight,
                        message: diag.userMessage,
                        recoveryActions: diag.recoveryActions
                    )
                    return
                }
                let preflightOK = await preflightCheck(urls: urls, sourceID: sourceID)
                guard preflightOK else { return }
                guard !isSourceCancelled(sourceID) else {
                    updateState(for: sourceID, state: ModelDownloadStateReducer.reduce(stateForSource(sourceID), event: .cancelled))
                    currentInstallPhase = nil
                    overallPhase = nil
                    return
                }
                currentInstallPhase = .downloading
                if source.isChat {
                    overallPhase = .llmDownload
                } else {
                    overallPhase = .embeddingDownload
                }
                await beginArchiveDownload(urls: urls, sourceID: sourceID)

            case .repoDirectory(let modelPath):
                if source.isChat {
                    overallPhase = .llmDownload
                } else {
                    overallPhase = .embeddingDownload
                }
                await downloadRepoDirectory(source: source, modelPath: modelPath)

            case .unsupported:
                break
            }
        }
    }

    func startFullInstall() {
        overallPhase = .llmDownload
        startDownload(sourceID: selectedChatSourceID)
    }

    func startEmbeddingDownload() {
        overallPhase = .embeddingDownload
        startDownload(sourceID: selectedEmbeddingSourceID)
    }

    func cancelDownload(sourceID: ModelSourceID) {
        cancelledSources.insert(sourceID)

        if let task = activeTasks[sourceID] {
            let taskID = task.taskIdentifier
            let resumeKey = taskRouting[taskID]?.resumeKey
            task.cancel { [weak self] resumeData in
                guard let self, let resumeData, let resumeKey else { return }
                Task { @MainActor [weak self] in
                    self?.resumeDataStore[resumeKey] = resumeData
                }
            }
        }

        currentInstallPhase = nil
        overallPhase = nil
        updateState(for: sourceID, state: ModelDownloadStateReducer.reduce(stateForSource(sourceID), event: .cancelled))
        clearFailure(for: sourceID)
    }

    func deleteModel(sourceID: ModelSourceID) {
        let deletedSource = ModelSourceCatalog.source(for: sourceID)
        let deletingSelectedChat = deletedSource?.isChat == true && selectedChatSourceID == sourceID
        let deletingSelectedEmbedding = deletedSource?.isEmbedding == true && selectedEmbeddingSourceID == sourceID

        cancelDownload(sourceID: sourceID)
        clearResumeData(for: sourceID)
        clearFailure(for: sourceID)
        let modelDir = modelDirectory(for: sourceID)
        try? fileManager.removeItem(at: modelDir)
        updateState(for: sourceID, state: ModelDownloadStateReducer.reduce(stateForSource(sourceID), event: .cancelled))

        if deletingSelectedChat {
            let fallbackChatSourceID = ModelSourceCatalog.resolveChatSelection(
                candidate: nil,
                installedSourceIDs: installedChatSourceIDsOnDisk(),
                excluding: [sourceID]
            )
            selectedChatSourceID = fallbackChatSourceID
        }

        if deletingSelectedEmbedding {
            let fallbackEmbeddingSourceID = ModelSourceCatalog.resolveEmbeddingSelection(
                candidate: nil,
                installedSourceIDs: installedEmbeddingSourceIDsOnDisk(),
                excluding: [sourceID]
            )
            selectedEmbeddingSourceID = fallbackEmbeddingSourceID
        }

        if deletingSelectedChat || deletingSelectedEmbedding {
            refreshSelectedStates()
        }
        logger.info("Model deleted: \(sourceID)")
    }

    func lastFailureReport(for sourceID: ModelSourceID) -> ModelFailureReport? {
        lastFailureBySourceID[sourceID]
    }

    func modelsBaseDirectory() -> URL {
        AppStoragePaths.modelsDirectory
    }

    func modelDirectory(for sourceID: ModelSourceID) -> URL {
        modelsBaseDirectory().appending(path: sourceID, directoryHint: .isDirectory)
    }

    func modelFileURL(for sourceID: ModelSourceID) -> URL? {
        let dir = modelDirectory(for: sourceID)
        guard fileManager.fileExists(atPath: dir.path) else { return nil }
        if let source = ModelSourceCatalog.source(for: sourceID) {
            return resolveModelArtifactURL(for: source, in: dir)
        }
        return resolveModelArtifactURLInDirectory(dir)
    }

    func tokenizerDirectory(for sourceID: ModelSourceID) -> URL? {
        let modelDir = modelDirectory(for: sourceID)
        let tokenizerJson = modelDir.appendingPathComponent("tokenizer.json")
        if fileManager.fileExists(atPath: tokenizerJson.path) {
            return modelDir
        }
        return nil
    }

    func hasTokenizer(for sourceID: ModelSourceID) -> Bool {
        tokenizerDirectory(for: sourceID) != nil
    }

    var availableDiskSpaceBytes: Int64 {
        let path = AppStoragePaths.appRootDirectory
        guard let values = try? path.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage else {
            return 0
        }
        return available
    }

    func hasSufficientSpace(for source: ModelSource) -> Bool {
        let buffer: Int64 = 500_000_000
        return availableDiskSpaceBytes > (source.estimatedSizeBytes + buffer)
    }

    // MARK: - Preflight

    private func preflightCheck(urls: [URL], sourceID: ModelSourceID) async -> Bool {
        guard !urls.isEmpty else {
            let diag = DownloadDiagnosticError.noDownloadURL(sourceID: sourceID)
            let message = diag.userMessage
            updateState(for: sourceID, state: ModelDownloadStateReducer.reduce(stateForSource(sourceID), event: .fail(message: message)))
            recordFailure(for: sourceID, stage: .preflight, message: message, recoveryActions: diag.recoveryActions)
            return false
        }

        var lastFailureMessage: String?

        for (index, url) in urls.enumerated() {
            logger.info("Preflight: checking \(url.absoluteString)")
            lastDiagnosticMessage = "Preflight: \(url.absoluteString)"

            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 15

            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    lastFailureMessage = "Model host returned an invalid response during preflight."
                    continue
                }

                let finalURL = http.url ?? url
                logger.info("Preflight resolved URL: \(finalURL.absoluteString), status: \(http.statusCode)")

                if (200...399).contains(http.statusCode) {
                    return true
                }

                let diagError = classifyHTTPError(statusCode: http.statusCode, url: finalURL.absoluteString, bodyPreview: "")
                lastFailureMessage = diagError.userMessage

                let hasFallback = index + 1 < urls.count
                let action = retryPlanner.nextAction(for: .httpStatus(http.statusCode), retryCountOnCurrentURL: retryPlanner.maxRetriesPerURL, hasFallbackURL: hasFallback)
                if case .switchToFallbackURL = action {
                    logger.warning("Preflight switching to fallback URL for \(sourceID) after HTTP \(http.statusCode)")
                    continue
                }
                if case .retry = action {
                    // Transient responses are handled in the download loop with backoff.
                    return true
                }

                updateState(for: sourceID, state: ModelDownloadStateReducer.reduce(stateForSource(sourceID), event: .fail(message: diagError.userMessage)))
                recordFailure(
                    for: sourceID,
                    stage: .preflight,
                    message: diagError.userMessage,
                    recoveryActions: diagError.recoveryActions
                )
                return false
            } catch {
                let failureKind = downloadFailureKind(from: error)
                let hasFallback = index + 1 < urls.count
                let action = retryPlanner.nextAction(for: failureKind, retryCountOnCurrentURL: retryPlanner.maxRetriesPerURL, hasFallbackURL: hasFallback)

                if failureKind == .transientNetwork {
                    // Continue into the normal download flow so retries/resume logic can recover.
                    return true
                }

                if case .switchToFallbackURL = action {
                    logger.warning("Preflight switching to fallback URL for \(sourceID) after error: \(error.localizedDescription)")
                    continue
                }

                if failureKind == .cancelled {
                    updateState(for: sourceID, state: ModelDownloadStateReducer.reduce(stateForSource(sourceID), event: .cancelled))
                    return false
                }

                let diag = DownloadDiagnosticError.preflightUnreachable(
                    url: url.absoluteString,
                    underlyingError: error.localizedDescription
                )
                let message = diag.userMessage
                updateState(for: sourceID, state: ModelDownloadStateReducer.reduce(stateForSource(sourceID), event: .fail(message: message)))
                recordFailure(for: sourceID, stage: .preflight, message: message, recoveryActions: diag.recoveryActions)
                return false
            }
        }

        let finalMessage = lastFailureMessage ?? DownloadDiagnosticError.noDownloadURL(sourceID: sourceID).userMessage
        updateState(for: sourceID, state: ModelDownloadStateReducer.reduce(stateForSource(sourceID), event: .fail(message: finalMessage)))
        recordFailure(
            for: sourceID,
            stage: .preflight,
            message: finalMessage,
            recoveryActions: [.retryDownload, .checkNetworkConnection]
        )
        return false
    }

    // MARK: - Archive Download

    private func beginArchiveDownload(urls: [URL], sourceID: ModelSourceID) async {
        guard !isSourceCancelled(sourceID) else {
            updateState(for: sourceID, state: ModelDownloadStateReducer.reduce(stateForSource(sourceID), event: .cancelled))
            currentInstallPhase = nil
            overallPhase = nil
            return
        }

        logger.info("Starting archive download for \(sourceID) with \(urls.count) candidate URL(s)")

        do {
            let archiveURL = try await downloadFileStreaming(
                sourceID: sourceID,
                candidateURLs: urls,
                progressMode: .sourceOnly
            )

            guard !isSourceCancelled(sourceID) else {
                try? fileManager.removeItem(at: archiveURL)
                updateState(for: sourceID, state: ModelDownloadStateReducer.reduce(stateForSource(sourceID), event: .cancelled))
                currentInstallPhase = nil
                overallPhase = nil
                return
            }

            updateState(for: sourceID, state: ModelDownloadStateReducer.reduce(stateForSource(sourceID), event: .beginInstall))
            await installArchive(archiveURL: archiveURL, sourceID: sourceID)
        } catch is CancellationError {
            updateState(for: sourceID, state: ModelDownloadStateReducer.reduce(stateForSource(sourceID), event: .cancelled))
            currentInstallPhase = nil
            overallPhase = nil
        } catch {
            let message = errorMessage(from: error, defaultPrefix: "Download error")
            updateState(for: sourceID, state: ModelDownloadStateReducer.reduce(stateForSource(sourceID), event: .fail(message: message)))
            let (stage, actions) = classifyFailureContext(for: error, fallbackStage: .downloading)
            recordFailure(for: sourceID, stage: stage, message: message, recoveryActions: actions)
            currentInstallPhase = nil
            overallPhase = nil
        }
    }

    private func installArchive(archiveURL: URL, sourceID: ModelSourceID) async {
        guard let source = ModelSourceCatalog.source(for: sourceID) else { return }
        let stagingDir = modelsBaseDirectory().appendingPathComponent("staging-\(sourceID)", isDirectory: true)

        do {
            try cleanAndCreateDirectory(at: stagingDir)

            currentInstallPhase = .extracting
            if source.isChat {
                overallPhase = .llmInstall
            } else {
                overallPhase = .embeddingInstall
            }

            try extractArchive(at: archiveURL, to: stagingDir)

            currentInstallPhase = .validating
            overallPhase = .validation
            let modelArtifactURL = try locateModelArtifact(in: stagingDir)

            let destDir = modelDirectory(for: sourceID)
            try cleanAndCreateDirectory(at: destDir)

            let destModelURL = destDir.appendingPathComponent(modelArtifactURL.lastPathComponent)
            try fileManager.moveItem(at: modelArtifactURL, to: destModelURL)

            currentInstallPhase = .installingTokenizer
            overallPhase = .tokenizerInstall
            let tokResult = await downloadTokenizerWithFallback(source: source, to: destDir)
            lastTokenizerFallbackResult = tokResult

            currentInstallPhase = .installingConfig
            await downloadConfigFiles(source: source, to: destDir)

            try validateInstall(modelDir: destDir, source: source)
            try excludeFromBackup(destDir)
            writeInstallMarkerBestEffort(for: source, in: destDir, context: "archive-install")

            try? fileManager.removeItem(at: stagingDir)
            try? fileManager.removeItem(at: archiveURL)
            clearResumeData(for: sourceID)

            currentInstallPhase = .complete
            let hasTokenizer = tokResult.filesDownloaded.contains("tokenizer.json")
            clearFailure(for: sourceID)
            updateState(for: sourceID, state: ModelDownloadStateReducer.reduce(stateForSource(sourceID), event: .success(hasTokenizer: hasTokenizer)))
            logger.info("Archive model installed: \(sourceID)")
        } catch {
            try? fileManager.removeItem(at: stagingDir)
            clearResumeData(for: sourceID)
            let message = errorMessage(from: error, defaultPrefix: "Install failed")
            updateState(for: sourceID, state: ModelDownloadStateReducer.reduce(stateForSource(sourceID), event: .fail(message: message)))
            let (stage, actions) = classifyFailureContext(for: error, fallbackStage: .installing)
            recordFailure(for: sourceID, stage: stage, message: message, recoveryActions: actions)
        }

        currentInstallPhase = nil
    }

    // MARK: - Repo Directory Download

    private func downloadRepoDirectory(source: ModelSource, modelPath: String) async {
        let sourceID = source.id

        let treeURLs = source.hfTreeURLs(path: modelPath)
        guard !treeURLs.isEmpty else {
            let message = "Model source configuration is invalid. Select another model source and retry."
            updateState(for: sourceID, state: .error(message))
            recordFailure(
                for: sourceID,
                stage: .preflight,
                message: message,
                recoveryActions: [.chooseAnotherModel, .openModelSettings]
            )
            currentInstallPhase = nil
            return
        }

        logger.info("Listing HF directory candidates for \(sourceID): \(treeURLs.count)")
        if let firstTreeURL = treeURLs.first {
            lastDiagnosticMessage = "Listing files: \(firstTreeURL.absoluteString)"
        }

        do {
            currentInstallPhase = .preflight

            let preflightOK = await preflightCheckTree(treeURLs: treeURLs, sourceID: sourceID)
            guard preflightOK else { return }
            guard !isSourceCancelled(sourceID) else {
                updateState(for: sourceID, state: ModelDownloadStateReducer.reduce(stateForSource(sourceID), event: .cancelled))
                currentInstallPhase = nil
                overallPhase = nil
                return
            }

            let fileEntries = try await listHFDirectory(treeURLs: treeURLs, sourceID: sourceID)
            guard !fileEntries.isEmpty else {
                let message = "Model host did not return required files. Try again later or select another model."
                updateState(for: sourceID, state: .error(message))
                recordFailure(
                    for: sourceID,
                    stage: .downloading,
                    message: message,
                    recoveryActions: [.waitAndRetry, .chooseAnotherModel]
                )
                currentInstallPhase = nil
                return
            }

            let totalBytes = fileEntries.reduce(Int64(0)) { $0 + $1.size }
            logger.info("Found \(fileEntries.count) files, total \(totalBytes) bytes")

            currentInstallPhase = .downloading

            let destDir = modelDirectory(for: sourceID)
            try cleanAndCreateDirectory(at: destDir)

            let modelArtifactDir = destDir.appendingPathComponent(modelPath, isDirectory: true)
            try fileManager.createDirectory(at: modelArtifactDir, withIntermediateDirectories: true)

            var downloadedBytes: Int64 = 0

            for entry in fileEntries {
                if Task.isCancelled || isSourceCancelled(sourceID) {
                    updateState(for: sourceID, state: ModelDownloadStateReducer.reduce(stateForSource(sourceID), event: .cancelled))
                    currentInstallPhase = nil
                    overallPhase = nil
                    return
                }

                let fileURLs = source.hfResolveURLs(path: entry.path)
                guard !fileURLs.isEmpty else { continue }

                let relativePath = entry.path.replacingOccurrences(of: modelPath + "/", with: "")
                let localFile = modelArtifactDir.appendingPathComponent(relativePath)

                let localDir = localFile.deletingLastPathComponent()
                if !fileManager.fileExists(atPath: localDir.path) {
                    try fileManager.createDirectory(at: localDir, withIntermediateDirectories: true)
                }

                try await downloadFileStreaming(
                    sourceID: sourceID,
                    candidateURLs: fileURLs,
                    to: localFile,
                    progressMode: .cumulative(totalExpectedBytes: totalBytes, completedBytesBeforeCurrentTask: downloadedBytes)
                )
                let fileSize = (try? localFile.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                downloadedBytes += Int64(fileSize)

                let progress = totalBytes > 0 ? Double(downloadedBytes) / Double(totalBytes) : 0
                updateState(for: sourceID, state: ModelDownloadStateReducer.reduce(stateForSource(sourceID), event: .progress(min(progress, 0.99))))
            }

            currentInstallPhase = .installingTokenizer
            overallPhase = source.isChat ? .tokenizerInstall : .tokenizerInstall
            let tokResult = await downloadTokenizerWithFallback(source: source, to: destDir)
            lastTokenizerFallbackResult = tokResult

            currentInstallPhase = .installingConfig
            await downloadConfigFiles(source: source, to: destDir)

            currentInstallPhase = .validating
            overallPhase = .validation

            if source.artifactType == .mlpackageDirectory {
                try validateMLPackageStructure(packageDir: modelArtifactDir)
            }

            try validateInstall(modelDir: destDir, source: source)
            try excludeFromBackup(destDir)
            writeInstallMarkerBestEffort(for: source, in: destDir, context: "repo-install")

            currentInstallPhase = .complete
            let hasTokenizer = tokResult.filesDownloaded.contains("tokenizer.json")
            clearResumeData(for: sourceID)
            clearFailure(for: sourceID)
            updateState(for: sourceID, state: ModelDownloadStateReducer.reduce(stateForSource(sourceID), event: .success(hasTokenizer: hasTokenizer)))
            logger.info("Repo directory model installed: \(sourceID)")
        } catch is CancellationError {
            let destDir = modelDirectory(for: sourceID)
            try? fileManager.removeItem(at: destDir)
            updateState(for: sourceID, state: ModelDownloadStateReducer.reduce(stateForSource(sourceID), event: .cancelled))
            logger.info("Repo directory install cancelled for \(sourceID)")
        } catch {
            let destDir = modelDirectory(for: sourceID)
            try? fileManager.removeItem(at: destDir)
            clearResumeData(for: sourceID)
            let message = errorMessage(from: error, defaultPrefix: "Install failed")
            updateState(for: sourceID, state: ModelDownloadStateReducer.reduce(stateForSource(sourceID), event: .fail(message: message)))
            let (stage, actions) = classifyFailureContext(for: error, fallbackStage: .installing)
            recordFailure(for: sourceID, stage: stage, message: message, recoveryActions: actions)
            logger.error("Repo directory install failed for \(sourceID): \(message, privacy: .public)")
        }

        currentInstallPhase = nil
    }

    private func preflightCheckTree(treeURLs: [URL], sourceID: ModelSourceID) async -> Bool {
        guard !treeURLs.isEmpty else {
            let message = "Model source configuration is invalid. Select another model source and retry."
            updateState(for: sourceID, state: ModelDownloadStateReducer.reduce(stateForSource(sourceID), event: .fail(message: message)))
            recordFailure(
                for: sourceID,
                stage: .preflight,
                message: message,
                recoveryActions: [.chooseAnotherModel, .openModelSettings]
            )
            currentInstallPhase = nil
            return false
        }

        var lastFailureMessage: String?

        for (index, treeURL) in treeURLs.enumerated() {
            let recursiveURL = recursiveTreeURL(for: treeURL)
            logger.info("Preflight tree: \(recursiveURL.absoluteString)")
            lastDiagnosticMessage = "Verifying artifact: \(recursiveURL.absoluteString)"

            do {
                var request = URLRequest(url: recursiveURL)
                request.httpMethod = "GET"
                request.timeoutInterval = 15

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    lastFailureMessage = "Model host returned an invalid response while checking model files."
                    continue
                }

                let finalURL = http.url ?? recursiveURL

                if (200...299).contains(http.statusCode) {
                    if let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], !jsonArray.isEmpty {
                        return true
                    }
                    lastFailureMessage = "Model files are missing from the selected source."
                    continue
                }

                let bodyPreview = String(data: data.prefix(300), encoding: .utf8) ?? ""
                let diagError = classifyHTTPError(statusCode: http.statusCode, url: finalURL.absoluteString, bodyPreview: bodyPreview)
                lastFailureMessage = diagError.userMessage

                let hasFallback = index + 1 < treeURLs.count
                let action = retryPlanner.nextAction(for: .httpStatus(http.statusCode), retryCountOnCurrentURL: retryPlanner.maxRetriesPerURL, hasFallbackURL: hasFallback)
                if case .switchToFallbackURL = action {
                    logger.warning("Preflight tree switching to fallback URL for \(sourceID) after HTTP \(http.statusCode)")
                    continue
                }
                if case .retry = action {
                    // Defer transient handling to directory-list retries.
                    return true
                }

                updateState(for: sourceID, state: ModelDownloadStateReducer.reduce(stateForSource(sourceID), event: .fail(message: diagError.userMessage)))
                recordFailure(
                    for: sourceID,
                    stage: .preflight,
                    message: diagError.userMessage,
                    recoveryActions: diagError.recoveryActions
                )
                currentInstallPhase = nil
                return false
            } catch {
                let failureKind = downloadFailureKind(from: error)
                let hasFallback = index + 1 < treeURLs.count
                let action = retryPlanner.nextAction(for: failureKind, retryCountOnCurrentURL: retryPlanner.maxRetriesPerURL, hasFallbackURL: hasFallback)

                if failureKind == .transientNetwork {
                    return true
                }

                if case .switchToFallbackURL = action {
                    logger.warning("Preflight tree switching to fallback URL for \(sourceID) after error: \(error.localizedDescription)")
                    continue
                }

                if failureKind == .cancelled {
                    updateState(for: sourceID, state: ModelDownloadStateReducer.reduce(stateForSource(sourceID), event: .cancelled))
                    currentInstallPhase = nil
                    return false
                }

                let diag = DownloadDiagnosticError.preflightUnreachable(
                    url: recursiveURL.absoluteString,
                    underlyingError: error.localizedDescription
                )
                let message = diag.userMessage
                updateState(for: sourceID, state: ModelDownloadStateReducer.reduce(stateForSource(sourceID), event: .fail(message: message)))
                recordFailure(for: sourceID, stage: .preflight, message: message, recoveryActions: diag.recoveryActions)
                currentInstallPhase = nil
                return false
            }
        }

        let finalMessage = lastFailureMessage ?? "Model files are missing from the selected source."
        updateState(for: sourceID, state: ModelDownloadStateReducer.reduce(stateForSource(sourceID), event: .fail(message: finalMessage)))
        recordFailure(
            for: sourceID,
            stage: .preflight,
            message: finalMessage,
            recoveryActions: [.chooseAnotherModel, .retryDownload]
        )
        currentInstallPhase = nil
        return false
    }

    private func listHFDirectory(treeURLs: [URL], sourceID: ModelSourceID) async throws -> [HFFileEntry] {
        guard !treeURLs.isEmpty else {
            throw ModelInstallError.hfTreeListFailed("No tree URL candidates provided")
        }

        var currentIndex = 0
        var retryCount = 0
        var lastFailureMessage = "Unable to list model directory"

        while currentIndex < treeURLs.count {
            if isSourceCancelled(sourceID) || Task.isCancelled {
                throw CancellationError()
            }

            let recursiveURL = recursiveTreeURL(for: treeURLs[currentIndex])
            logger.info("Listing HF directory (recursive): \(recursiveURL.absoluteString)")

            do {
                let (data, response) = try await URLSession.shared.data(from: recursiveURL)
                guard let http = response as? HTTPURLResponse else {
                    throw ModelInstallError.hfTreeListFailed("Model host returned an invalid response while listing files.")
                }

                if (200...299).contains(http.statusCode) {
                    guard let jsonArray = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                        throw ModelInstallError.hfTreeListFailed("Invalid JSON from HF API")
                    }

                    var entries: [HFFileEntry] = []
                    for item in jsonArray {
                        guard let type = item["type"] as? String,
                              let path = item["path"] as? String else { continue }

                        if type == "file" {
                            let lfsSize = (item["lfs"] as? [String: Any])?["size"] as? Int64
                            let directSize = item["size"] as? Int64
                            let size = lfsSize ?? directSize ?? 0
                            entries.append(HFFileEntry(path: path, size: size, type: type))
                        }
                    }

                    return entries
                }

                let bodyPreview = String(data: data.prefix(300), encoding: .utf8) ?? ""
                let diagError = classifyHTTPError(statusCode: http.statusCode, url: recursiveURL.absoluteString, bodyPreview: bodyPreview)
                lastFailureMessage = diagError.userMessage

                let hasFallback = currentIndex + 1 < treeURLs.count
                let action = retryPlanner.nextAction(for: .httpStatus(http.statusCode), retryCountOnCurrentURL: retryCount, hasFallbackURL: hasFallback)
                switch action {
                case .retry(let delay):
                    retryCount += 1
                    logger.warning("Retrying HF directory listing for \(sourceID) in \(delay, privacy: .public)s")
                    try await sleepForRetry(delaySeconds: delay, sourceID: sourceID)
                case .switchToFallbackURL:
                    retryCount = 0
                    if let nextIndex = DownloadURLSelector.nextIndex(after: .switchToFallbackURL, currentIndex: currentIndex, totalURLCount: treeURLs.count) {
                        logger.warning("Switching HF directory listing to fallback URL for \(sourceID)")
                        currentIndex = nextIndex
                    } else {
                        throw ModelInstallError.hfTreeListFailed(lastFailureMessage)
                    }
                case .fail:
                    throw ModelInstallError.hfTreeListFailed(lastFailureMessage)
                }
            } catch {
                if error is CancellationError {
                    throw error
                }

                let failureKind = downloadFailureKind(from: error)
                let hasFallback = currentIndex + 1 < treeURLs.count
                let action = retryPlanner.nextAction(for: failureKind, retryCountOnCurrentURL: retryCount, hasFallbackURL: hasFallback)
                lastFailureMessage = "Unable to list model files from the host. Check your network and retry."

                switch action {
                case .retry(let delay):
                    retryCount += 1
                    logger.warning("Retrying HF directory listing after error for \(sourceID) in \(delay, privacy: .public)s")
                    try await sleepForRetry(delaySeconds: delay, sourceID: sourceID)
                case .switchToFallbackURL:
                    retryCount = 0
                    if let nextIndex = DownloadURLSelector.nextIndex(after: .switchToFallbackURL, currentIndex: currentIndex, totalURLCount: treeURLs.count) {
                        logger.warning("Switching HF directory listing to fallback URL after error for \(sourceID)")
                        currentIndex = nextIndex
                    } else {
                        throw ModelInstallError.hfTreeListFailed(lastFailureMessage)
                    }
                case .fail:
                    throw ModelInstallError.hfTreeListFailed(lastFailureMessage)
                }
            }
        }

        throw ModelInstallError.hfTreeListFailed(lastFailureMessage)
    }

    // MARK: - Tokenizer with Fallback Chain

    private func downloadTokenizerWithFallback(source: ModelSource, to directory: URL) async -> TokenizerFallbackResult {
        let allRepos = source.allTokenizerRepoIDs
        var filesDownloaded: [String] = []
        var filesMissing: [String] = []
        var gatedRepos: [String] = []
        var resolvedRepo = allRepos.first ?? source.repoID

        for repo in allRepos {
            let result = await attemptTokenizerDownload(
                files: source.tokenizerFiles,
                fromRepo: repo,
                to: directory,
                alreadyDownloaded: filesDownloaded
            )

            filesDownloaded.append(contentsOf: result.downloaded)
            gatedRepos.append(contentsOf: result.gated ? [repo] : [])

            if result.downloaded.contains("tokenizer.json") {
                resolvedRepo = repo
                logger.info("Tokenizer resolved from repo: \(repo)")
                break
            }
        }

        for file in source.tokenizerFiles where !filesDownloaded.contains(file) {
            filesMissing.append(file)
        }

        if !filesMissing.isEmpty {
            logger.warning("Tokenizer files missing after fallback chain: \(filesMissing.joined(separator: ", "))")
        }
        if !gatedRepos.isEmpty {
            logger.warning("Gated repos encountered during tokenizer fallback: \(gatedRepos.joined(separator: ", "))")
        }

        return TokenizerFallbackResult(
            resolvedRepo: resolvedRepo,
            filesDownloaded: filesDownloaded,
            filesMissing: filesMissing,
            gatedRepos: gatedRepos
        )
    }

    private struct TokenizerAttemptResult {
        let downloaded: [String]
        let gated: Bool
    }

    private func attemptTokenizerDownload(files: [String], fromRepo repo: String, to directory: URL, alreadyDownloaded: [String]) async -> TokenizerAttemptResult {
        var downloaded: [String] = []
        var encounteredGate = false

        for fileName in files {
            if alreadyDownloaded.contains(fileName) { continue }

            let destFile = directory.appendingPathComponent(fileName)
            if fileManager.fileExists(atPath: destFile.path) {
                downloaded.append(fileName)
                continue
            }

            guard let url = URL(string: "https://huggingface.co/\(repo)/resolve/main/\(fileName)") else { continue }

            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let httpResponse = response as? HTTPURLResponse else { continue }

                if (200...299).contains(httpResponse.statusCode) {
                    try data.write(to: destFile, options: .atomic)
                    downloaded.append(fileName)
                    logger.info("Downloaded tokenizer file \(fileName) from \(repo)")
                } else if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                    encounteredGate = true
                    logger.warning("Tokenizer file \(fileName) gated at \(repo) (HTTP \(httpResponse.statusCode))")
                } else {
                    logger.warning("Tokenizer file \(fileName) not available from \(repo) (HTTP \(httpResponse.statusCode))")
                }
            } catch {
                logger.warning("Failed to download tokenizer file \(fileName) from \(repo): \(error.localizedDescription)")
            }
        }

        return TokenizerAttemptResult(downloaded: downloaded, gated: encounteredGate)
    }

    // MARK: - Config Files

    private func downloadConfigFiles(source: ModelSource, to directory: URL) async {
        guard !source.configFiles.isEmpty else { return }

        let allRepos = source.allTokenizerRepoIDs

        for fileName in source.configFiles {
            let destFile = directory.appendingPathComponent(fileName)
            if fileManager.fileExists(atPath: destFile.path) { continue }

            var downloaded = false
            for repo in allRepos {
                guard let url = URL(string: "https://huggingface.co/\(repo)/resolve/main/\(fileName)") else { continue }

                do {
                    let (data, response) = try await URLSession.shared.data(from: url)
                    guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else { continue }
                    try data.write(to: destFile, options: .atomic)
                    logger.info("Downloaded config file \(fileName) from \(repo)")
                    downloaded = true
                    break
                } catch {
                    continue
                }
            }

            if !downloaded {
                logger.info("Config file \(fileName) not found in any repo (non-critical)")
            }
        }
    }

    // MARK: - MLPackage Validation

    private func validateMLPackageStructure(packageDir: URL) throws {
        let manifestURL = packageDir.appendingPathComponent("Manifest.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw ModelInstallError.mlpackageInvalid("Missing Manifest.json in \(packageDir.lastPathComponent)")
        }

        let modelFileURL = packageDir
            .appendingPathComponent("Data")
            .appendingPathComponent("com.apple.CoreML")
            .appendingPathComponent("model.mlmodel")

        guard fileManager.fileExists(atPath: modelFileURL.path) else {
            throw ModelInstallError.mlpackageInvalid("Missing Data/com.apple.CoreML/model.mlmodel in \(packageDir.lastPathComponent)")
        }

        let weightsDir = packageDir
            .appendingPathComponent("Data")
            .appendingPathComponent("com.apple.CoreML")
            .appendingPathComponent("weights")

        if fileManager.fileExists(atPath: weightsDir.path) {
            let weightFiles = (try? fileManager.contentsOfDirectory(at: weightsDir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            let hasWeights = weightFiles.contains { url in
                let ext = url.pathExtension.lowercased()
                return ext == "bin" || ext == "weight" || ext == "dat"
            }
            if !hasWeights && !weightFiles.isEmpty {
                logger.info("Weights directory exists but no standard weight files found — may use alternative format")
            }
        }

        logger.info("MLPackage structure validated: \(packageDir.lastPathComponent)")
    }

    // MARK: - Validation

    private func validateInstall(modelDir: URL, source: ModelSource) throws {
        guard fileManager.fileExists(atPath: modelDir.path) else {
            throw ModelInstallError.validationFailed("Model directory does not exist")
        }

        try validateExpectedArtifactLocation(modelDir: modelDir, source: source)

        guard let contents = try? fileManager.contentsOfDirectory(at: modelDir, includingPropertiesForKeys: nil),
              !contents.isEmpty else {
            throw ModelInstallError.validationFailed("Model directory is empty")
        }

        guard resolveModelArtifactURL(for: source, in: modelDir) != nil else {
            throw ModelInstallError.validationFailed("No Core ML model found in install directory")
        }

        let dirSize = directorySize(at: modelDir)
        let minimumExpected = source.estimatedSizeBytes / 20
        guard dirSize > minimumExpected else {
            throw ModelInstallError.validationFailed("Installed model appears too small (\(dirSize) bytes, expected at least \(minimumExpected))")
        }
    }

    private func validateExpectedArtifactLocation(modelDir: URL, source: ModelSource) throws {
        switch source.downloadStrategy {
        case .repoDirectory(let modelPath):
            let expectedURL = modelDir.appendingPathComponent(modelPath)
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: expectedURL.path, isDirectory: &isDir) else {
                throw ModelInstallError.validationFailed("Expected model artifact is missing at \(modelPath)")
            }
            if source.artifactType != .zipArchive && !isDir.boolValue {
                throw ModelInstallError.validationFailed("Expected model artifact path is not a directory: \(modelPath)")
            }
        case .archive:
            break
        case .unsupported:
            break
        }
    }

    // MARK: - Archive Extraction

    private func extractArchive(at archiveURL: URL, to destinationDir: URL) throws {
        let archiveData = try Data(contentsOf: archiveURL, options: .mappedIfSafe)
        let headerBytes = [UInt8](archiveData.prefix(4))
        let isZip = headerBytes.count >= 4 && headerBytes[0] == 0x50 && headerBytes[1] == 0x4B && headerBytes[2] == 0x03 && headerBytes[3] == 0x04

        guard isZip else {
            throw ModelInstallError.invalidArchive
        }

        try fileManager.unzipItem(at: archiveURL, to: destinationDir)
    }

    private func locateModelArtifact(in directory: URL) throws -> URL {
        let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [])

        var bestCandidate: URL?
        var candidateExtension = ""

        while let url = enumerator?.nextObject() as? URL {
            let ext = url.pathExtension
            if ext == "mlmodelc" {
                return url
            }
            if ext == "mlpackage" && candidateExtension != "mlmodelc" {
                bestCandidate = url
                candidateExtension = ext
            }
            if ext == "mlmodel" && bestCandidate == nil {
                bestCandidate = url
                candidateExtension = ext
            }
        }

        if let candidate = bestCandidate {
            return candidate
        }

        throw ModelInstallError.modelNotFoundInArchive
    }

    // MARK: - State Management

    func validateSelectionOnLaunch(
        persistedChatSourceID: ModelSourceID?,
        persistedEmbeddingSourceID: ModelSourceID?,
        installedChatSourceIDs: Set<ModelSourceID>? = nil,
        installedEmbeddingSourceIDs: Set<ModelSourceID>? = nil
    ) -> ModelSelectionValidationResult {
        let migratedChatSourceID = ModelSourceCatalog.migratePersistedChatSourceID(persistedChatSourceID)
        let migratedEmbeddingSourceID = ModelSourceCatalog.migratePersistedEmbeddingSourceID(persistedEmbeddingSourceID)

        let chatInstalledIDs = installedChatSourceIDs ?? installedChatSourceIDsOnDisk()
        let embeddingInstalledIDs = installedEmbeddingSourceIDs ?? installedEmbeddingSourceIDsOnDisk()

        let resolvedChatSourceID = ModelSourceCatalog.resolveChatSelection(
            candidate: migratedChatSourceID,
            installedSourceIDs: chatInstalledIDs
        )
        let resolvedEmbeddingSourceID = ModelSourceCatalog.resolveEmbeddingSelection(
            candidate: migratedEmbeddingSourceID,
            installedSourceIDs: embeddingInstalledIDs
        )

        let chatNeedsPersistenceUpdate = persistedChatSourceID != nil && persistedChatSourceID != resolvedChatSourceID
        let embeddingNeedsPersistenceUpdate = persistedEmbeddingSourceID != nil && persistedEmbeddingSourceID != resolvedEmbeddingSourceID

        return ModelSelectionValidationResult(
            chatSourceID: resolvedChatSourceID,
            embeddingSourceID: resolvedEmbeddingSourceID,
            chatNeedsPersistenceUpdate: chatNeedsPersistenceUpdate,
            embeddingNeedsPersistenceUpdate: embeddingNeedsPersistenceUpdate
        )
    }

    private func checkExistingModels() {
        refreshSelectedStates()
    }

    func refreshSelectedStates() {
        refreshStateForSource(selectedChatSourceID)
        refreshStateForSource(selectedEmbeddingSourceID)
    }

    private func refreshStateForSource(_ sourceID: ModelSourceID) {
        guard let source = ModelSourceCatalog.source(for: sourceID) else { return }

        if !source.isAvailableForDownload {
            let dir = modelDirectory(for: source.id)
            if fileManager.fileExists(atPath: dir.path) {
                do {
                    try validateInstall(modelDir: dir, source: source)
                    let hasTok = hasTokenizer(for: source.id)
                    updateState(for: source.id, state: hasTok ? .installed : .installedMissingTokenizer)
                    return
                } catch {
                    // fall through
                }
            }
            if case .unsupported(let reason) = source.downloadStrategy {
                updateState(for: source.id, state: .unavailable(reason))
            }
            return
        }

        let dir = modelDirectory(for: source.id)
        guard fileManager.fileExists(atPath: dir.path) else {
            updateState(for: source.id, state: .notDownloaded)
            return
        }

        do {
            try validateInstall(modelDir: dir, source: source)
            backfillInstallMarkerIfNeeded(for: source, at: dir, context: "refresh")
            let hasTok = hasTokenizer(for: source.id)
            updateState(for: source.id, state: hasTok ? .installed : .installedMissingTokenizer)
        } catch {
            logger.warning("Existing model \(source.id) failed validation: \(error.localizedDescription)")
            updateState(for: source.id, state: .notDownloaded)
        }
    }

    private func installedChatSourceIDsOnDisk() -> Set<ModelSourceID> {
        installedSourceIDsOnDisk(in: ModelSourceCatalog.chatSources)
    }

    private func installedEmbeddingSourceIDsOnDisk() -> Set<ModelSourceID> {
        installedSourceIDsOnDisk(in: ModelSourceCatalog.embeddingSources)
    }

    private func installedSourceIDsOnDisk(in sources: [ModelSource]) -> Set<ModelSourceID> {
        Set(sources.compactMap { source in
            isSourceInstalledOnDisk(source) ? source.id : nil
        })
    }

    private func isSourceInstalledOnDisk(_ source: ModelSource) -> Bool {
        let dir = modelDirectory(for: source.id)
        guard fileManager.fileExists(atPath: dir.path) else { return false }
        do {
            try validateInstall(modelDir: dir, source: source)
            return true
        } catch {
            return false
        }
    }

    func stateForSource(_ sourceID: ModelSourceID) -> ModelDownloadState {
        guard let source = ModelSourceCatalog.source(for: sourceID) else { return .notDownloaded }
        if source.isChat && sourceID == selectedChatSourceID {
            return llmState
        }
        if source.isEmbedding && sourceID == selectedEmbeddingSourceID {
            return embeddingState
        }
        let dir = modelDirectory(for: sourceID)
        if fileManager.fileExists(atPath: dir.path) {
            if let src = ModelSourceCatalog.source(for: sourceID) {
                do {
                    try validateInstall(modelDir: dir, source: src)
                    backfillInstallMarkerIfNeeded(for: src, at: dir, context: "state-check")
                    let hasTok = hasTokenizer(for: sourceID)
                    return hasTok ? .installed : .installedMissingTokenizer
                } catch {
                    return .notDownloaded
                }
            }
        }
        if !source.isAvailableForDownload {
            if case .unsupported(let reason) = source.downloadStrategy {
                return .unavailable(reason)
            }
        }
        return .notDownloaded
    }

    private func updateState(for sourceID: ModelSourceID, state: ModelDownloadState) {
        guard let source = ModelSourceCatalog.source(for: sourceID) else { return }
        if source.isChat && sourceID == selectedChatSourceID {
            llmState = state
        } else if source.isEmbedding && sourceID == selectedEmbeddingSourceID {
            embeddingState = state
        }
    }

    // MARK: - Streaming File Download

    private func recursiveTreeURL(for treeURL: URL) -> URL {
        if treeURL.absoluteString.contains("recursive=true") {
            return treeURL
        }
        let separator = treeURL.absoluteString.contains("?") ? "&" : "?"
        return URL(string: treeURL.absoluteString + separator + "recursive=true") ?? treeURL
    }

    private func downloadFileStreaming(sourceID: ModelSourceID, candidateURLs: [URL], progressMode: DownloadProgressMode) async throws -> URL {
        try await downloadRemoteFileWithRetry(sourceID: sourceID, candidateURLs: candidateURLs, progressMode: progressMode)
    }

    private func downloadFileStreaming(sourceID: ModelSourceID, candidateURLs: [URL], to localFile: URL, progressMode: DownloadProgressMode) async throws {
        let tempURL = try await downloadRemoteFileWithRetry(sourceID: sourceID, candidateURLs: candidateURLs, progressMode: progressMode)
        if fileManager.fileExists(atPath: localFile.path) {
            try fileManager.removeItem(at: localFile)
        }
        try fileManager.moveItem(at: tempURL, to: localFile)
    }

    private func downloadRemoteFileWithRetry(sourceID: ModelSourceID, candidateURLs: [URL], progressMode: DownloadProgressMode) async throws -> URL {
        guard !candidateURLs.isEmpty else {
            throw ModelInstallError.fileDownloadFailed("No download URL provided")
        }

        var currentIndex = 0
        var retryCount = 0
        var lastFailureMessage = "Download failed."

        while currentIndex < candidateURLs.count {
            if isSourceCancelled(sourceID) || Task.isCancelled {
                throw CancellationError()
            }

            let currentURL = candidateURLs[currentIndex]
            let resumeKey = DownloadResumeKey(sourceID: sourceID, remoteURL: currentURL.absoluteString)
            let resumeData = resumeDataStore[resumeKey]

            let result = await enqueueDownloadTask(
                sourceID: sourceID,
                remoteURL: currentURL,
                resumeData: resumeData,
                resumeKey: resumeKey,
                progressMode: progressMode
            )

            switch result {
            case .success(let tempURL, let response):
                if let http = response as? HTTPURLResponse, !(200...399).contains(http.statusCode) {
                    let bodyPreview = readBodyPreview(from: tempURL)
                    try? fileManager.removeItem(at: tempURL)
                    let diagError = classifyHTTPError(statusCode: http.statusCode, url: currentURL.absoluteString, bodyPreview: bodyPreview)
                    lastFailureMessage = diagError.userMessage

                    let hasFallback = currentIndex + 1 < candidateURLs.count
                    let action = retryPlanner.nextAction(for: .httpStatus(http.statusCode), retryCountOnCurrentURL: retryCount, hasFallbackURL: hasFallback)
                    switch action {
                    case .retry(let delay):
                        retryCount += 1
                        logger.warning("Retrying download for \(sourceID) in \(delay, privacy: .public)s after HTTP \(http.statusCode)")
                        try await sleepForRetry(delaySeconds: delay, sourceID: sourceID)
                    case .switchToFallbackURL:
                        retryCount = 0
                        resumeDataStore.removeValue(forKey: resumeKey)
                        if let nextIndex = DownloadURLSelector.nextIndex(after: .switchToFallbackURL, currentIndex: currentIndex, totalURLCount: candidateURLs.count) {
                            logger.warning("Switching download URL to fallback for \(sourceID) after HTTP \(http.statusCode)")
                            currentIndex = nextIndex
                        } else {
                            throw ModelInstallError.fileDownloadFailed(lastFailureMessage)
                        }
                    case .fail:
                        resumeDataStore.removeValue(forKey: resumeKey)
                        throw ModelInstallError.fileDownloadFailed(lastFailureMessage)
                    }
                    continue
                }

                resumeDataStore.removeValue(forKey: resumeKey)
                return tempURL

            case .failure(let error, let resumeData):
                if let resumeData {
                    resumeDataStore[resumeKey] = resumeData
                }

                let failureKind = downloadFailureKind(from: error)
                if failureKind == .cancelled || isSourceCancelled(sourceID) || Task.isCancelled {
                    throw CancellationError()
                }

                switch failureKind {
                case .transientNetwork:
                    lastFailureMessage = "Network error while downloading model files. Check your connection and retry."
                case .httpStatus:
                    lastFailureMessage = "Model host returned an invalid response during download. Retry the download."
                case .other:
                    lastFailureMessage = "Download failed while fetching model files. Retry the download."
                case .cancelled:
                    lastFailureMessage = "Download was cancelled."
                }
                let hasFallback = currentIndex + 1 < candidateURLs.count
                let action = retryPlanner.nextAction(for: failureKind, retryCountOnCurrentURL: retryCount, hasFallbackURL: hasFallback)

                switch action {
                case .retry(let delay):
                    retryCount += 1
                    logger.warning("Retrying download for \(sourceID) in \(delay, privacy: .public)s after error: \(error.localizedDescription, privacy: .public)")
                    try await sleepForRetry(delaySeconds: delay, sourceID: sourceID)
                case .switchToFallbackURL:
                    retryCount = 0
                    resumeDataStore.removeValue(forKey: resumeKey)
                    if let nextIndex = DownloadURLSelector.nextIndex(after: .switchToFallbackURL, currentIndex: currentIndex, totalURLCount: candidateURLs.count) {
                        logger.warning("Switching download URL to fallback for \(sourceID) after error: \(error.localizedDescription, privacy: .public)")
                        currentIndex = nextIndex
                    } else {
                        throw ModelInstallError.fileDownloadFailed(lastFailureMessage)
                    }
                case .fail:
                    resumeDataStore.removeValue(forKey: resumeKey)
                    throw ModelInstallError.fileDownloadFailed(lastFailureMessage)
                }
            }
        }

        throw ModelInstallError.fileDownloadFailed(lastFailureMessage)
    }

    private func enqueueDownloadTask(
        sourceID: ModelSourceID,
        remoteURL: URL,
        resumeData: Data?,
        resumeKey: DownloadResumeKey,
        progressMode: DownloadProgressMode
    ) async -> DownloadTaskResult {
        await withCheckedContinuation { continuation in
            let task: URLSessionDownloadTask
            if let resumeData, !resumeData.isEmpty {
                task = downloadSession.downloadTask(withResumeData: resumeData)
                logger.info("Resuming download task for \(sourceID) from stored resume data")
            } else {
                task = downloadSession.downloadTask(with: remoteURL)
            }

            let taskIdentifier = task.taskIdentifier
            taskToSourceID[taskIdentifier] = sourceID
            taskRouting[taskIdentifier] = TaskRouting(sourceID: sourceID, resumeKey: resumeKey, progressMode: progressMode)
            taskContinuations[taskIdentifier] = continuation
            activeTasks[sourceID] = task
            task.resume()
        }
    }

    private func handleDownloadProgress(taskIdentifier: Int, totalBytesWritten: Int64, totalBytesExpected: Int64) {
        guard let routing = taskRouting[taskIdentifier] else { return }
        guard !isSourceCancelled(routing.sourceID) else { return }

        switch routing.progressMode {
        case .sourceOnly:
            guard totalBytesExpected > 0 else { return }
            let progress = Double(totalBytesWritten) / Double(totalBytesExpected)
            updateState(for: routing.sourceID, state: ModelDownloadStateReducer.reduce(stateForSource(routing.sourceID), event: .progress(progress)))
        case .cumulative(let totalExpectedBytes, let completedBytesBeforeCurrentTask):
            let totalBytes = max(1, totalExpectedBytes)
            let combinedWritten = completedBytesBeforeCurrentTask + max(0, totalBytesWritten)
            let progress = Double(combinedWritten) / Double(totalBytes)
            updateState(for: routing.sourceID, state: ModelDownloadStateReducer.reduce(stateForSource(routing.sourceID), event: .progress(min(progress, 0.99))))
        }
    }

    private func handleTaskFinishedDownloading(taskIdentifier: Int, location: URL) {
        taskTempFiles[taskIdentifier] = location
    }

    private func handleTaskCompletion(task: URLSessionTask, error: Error?) {
        let taskIdentifier = task.taskIdentifier
        let continuation = taskContinuations[taskIdentifier]
        let tempURL = taskTempFiles[taskIdentifier]

        if let sourceID = taskToSourceID[taskIdentifier],
           let activeTask = activeTasks[sourceID],
           activeTask.taskIdentifier == taskIdentifier {
            activeTasks.removeValue(forKey: sourceID)
        }

        cleanupTaskState(for: taskIdentifier)

        guard let continuation else { return }

        if let error {
            let nsError = error as NSError
            let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            continuation.resume(returning: .failure(error: error, resumeData: resumeData))
            return
        }

        guard let tempURL else {
            let unknownError = NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorUnknown,
                userInfo: [NSLocalizedDescriptionKey: "Download completed without file location."]
            )
            continuation.resume(returning: .failure(error: unknownError, resumeData: nil))
            return
        }

        continuation.resume(returning: .success(tempURL: tempURL, response: task.response))
    }

    private func cleanupTaskState(for taskIdentifier: Int) {
        taskToSourceID.removeValue(forKey: taskIdentifier)
        taskRouting.removeValue(forKey: taskIdentifier)
        taskTempFiles.removeValue(forKey: taskIdentifier)
        taskContinuations.removeValue(forKey: taskIdentifier)
    }

    private func clearResumeData(for sourceID: ModelSourceID) {
        resumeDataStore = resumeDataStore.filter { $0.key.sourceID != sourceID }
    }

    private func sleepForRetry(delaySeconds: Double, sourceID: ModelSourceID) async throws {
        let nanoseconds = UInt64(max(0, delaySeconds) * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)
        if isSourceCancelled(sourceID) || Task.isCancelled {
            throw CancellationError()
        }
    }

    private func isSourceCancelled(_ sourceID: ModelSourceID) -> Bool {
        cancelledSources.contains(sourceID)
    }

    private func downloadFailureKind(from error: Error) -> DownloadFailureKind {
        if error is CancellationError {
            return .cancelled
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorCancelled:
                return .cancelled
            case NSURLErrorTimedOut,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorNotConnectedToInternet,
                 NSURLErrorCannotFindHost,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorDNSLookupFailed,
                 NSURLErrorInternationalRoamingOff,
                 NSURLErrorCallIsActive,
                 NSURLErrorDataNotAllowed,
                 NSURLErrorResourceUnavailable,
                 NSURLErrorCannotLoadFromNetwork:
                return .transientNetwork
            default:
                break
            }
        }

        return .other
    }

    private func errorMessage(from error: Error, defaultPrefix: String) -> String {
        if let installError = error as? ModelInstallError {
            switch installError {
            case .extractionFailed(let message),
                 .tokenizerDownloadFailed(let message),
                 .tokenizerGated(let message),
                 .validationFailed(let message),
                 .notAvailableForDownload(let message),
                 .preflightFailed(let message),
                 .hfTreeListFailed(let message),
                 .fileDownloadFailed(let message),
                 .mlpackageInvalid(let message):
                return message
            case .invalidArchive:
                return "\(defaultPrefix): Invalid archive format."
            case .modelNotFoundInArchive:
                return "\(defaultPrefix): No Core ML model found in the archive."
            case .insufficientSpace:
                return "\(defaultPrefix): Insufficient storage space."
            case .stagingCleanupFailed:
                return "\(defaultPrefix): Failed to clean staging directory."
            }
        }

        let failureKind = downloadFailureKind(from: error)
        switch failureKind {
        case .transientNetwork:
            return "Network error while downloading model files. Check your connection and retry."
        case .cancelled:
            return "\(defaultPrefix): Download cancelled."
        case .httpStatus, .other:
            return "\(defaultPrefix): Please retry. If this continues, reinstall the model."
        }
    }

    private func recordFailure(
        for sourceID: ModelSourceID,
        stage: ModelFailureStage,
        message: String,
        recoveryActions: [ModelRecoveryAction]
    ) {
        lastFailureBySourceID[sourceID] = ModelFailureReport(
            sourceID: sourceID,
            stage: stage,
            message: message,
            recoveryActions: recoveryActions,
            timestamp: Date()
        )
        lastDiagnosticMessage = message
    }

    private func clearFailure(for sourceID: ModelSourceID) {
        lastFailureBySourceID.removeValue(forKey: sourceID)
    }

    private func classifyFailureContext(for error: Error, fallbackStage: ModelFailureStage) -> (ModelFailureStage, [ModelRecoveryAction]) {
        if let installError = error as? ModelInstallError {
            switch installError {
            case .insufficientSpace:
                return (.storage, [.freeStorageSpace, .retryDownload])
            case .tokenizerDownloadFailed, .tokenizerGated:
                return (.tokenizer, [.reinstallModel, .openModelSettings])
            case .validationFailed, .mlpackageInvalid, .invalidArchive, .modelNotFoundInArchive:
                return (.validating, [.reinstallModel, .chooseAnotherModel])
            case .preflightFailed:
                return (.preflight, [.checkNetworkConnection, .retryDownload])
            case .hfTreeListFailed, .fileDownloadFailed:
                return (.downloading, [.checkNetworkConnection, .retryDownload])
            case .notAvailableForDownload:
                return (.preflight, [.chooseAnotherModel, .openModelSettings])
            case .extractionFailed, .stagingCleanupFailed:
                return (.installing, [.retryDownload, .reinstallModel])
            }
        }

        if (error as NSError).domain == NSURLErrorDomain {
            return (.downloading, [.checkNetworkConnection, .retryDownload])
        }

        return (fallbackStage, [.retryDownload])
    }

    // MARK: - Utilities

    private func classifyHTTPError(statusCode: Int, url: String, bodyPreview: String) -> DownloadDiagnosticError {
        switch statusCode {
        case 401, 403:
            .accessDenied(url: url, statusCode: statusCode)
        case 404:
            .notFound(url: url)
        case 429:
            .rateLimited(url: url)
        case 500...599:
            .serverError(url: url, statusCode: statusCode)
        default:
            .unexpectedStatus(url: url, statusCode: statusCode, bodyPreview: String(bodyPreview.prefix(200)))
        }
    }

    private func readBodyPreview(from fileURL: URL) -> String {
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else { return "" }
        return String(data: data.prefix(500), encoding: .utf8) ?? ""
    }

    private func cleanAndCreateDirectory(at url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func hasInstallMarker(in modelDir: URL) -> Bool {
        let markerURL = modelDir.appendingPathComponent(Self.installMarkerFileName)
        return fileManager.fileExists(atPath: markerURL.path)
    }

    private func writeInstallMarker(for source: ModelSource, in modelDir: URL) throws {
        let markerURL = modelDir.appendingPathComponent(Self.installMarkerFileName)
        let payload: [String: String] = [
            "sourceID": source.id,
            "completedAt": Self.installMarkerDateFormatter.string(from: Date()),
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: markerURL, options: .atomic)
    }

    private func backfillInstallMarkerIfNeeded(for source: ModelSource, at modelDir: URL, context: String) {
        guard source.isAvailableForDownload, !hasInstallMarker(in: modelDir) else { return }
        writeInstallMarkerBestEffort(for: source, in: modelDir, context: "backfill-\(context)")
    }

    private func writeInstallMarkerBestEffort(for source: ModelSource, in modelDir: URL, context: String) {
        do {
            try writeInstallMarker(for: source, in: modelDir)
            logger.info("Install marker written (\(context)) for \(source.id)")
        } catch {
            logger.warning("Failed to write install marker (\(context)) for \(source.id): \(error.localizedDescription)")
        }
    }

    private func resolveModelArtifactURL(for source: ModelSource, in modelDir: URL) -> URL? {
        if case .repoDirectory(let modelPath) = source.downloadStrategy {
            let expected = modelDir.appendingPathComponent(modelPath)
            if fileManager.fileExists(atPath: expected.path), isModelArtifactURL(expected) {
                return expected
            }
        }
        return resolveModelArtifactURLInDirectory(modelDir)
    }

    private func resolveModelArtifactURLInDirectory(_ modelDir: URL) -> URL? {
        if let contents = try? fileManager.contentsOfDirectory(at: modelDir, includingPropertiesForKeys: nil) {
            if let topLevelArtifact = contents.first(where: { isModelArtifactURL($0) }) {
                return topLevelArtifact
            }
        }

        let enumerator = fileManager.enumerator(at: modelDir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        while let url = enumerator?.nextObject() as? URL {
            if isModelArtifactURL(url) {
                return url
            }
        }
        return nil
    }

    private func isModelArtifactURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "mlmodelc" || ext == "mlpackage" || ext == "mlmodel"
    }

    private func excludeFromBackup(_ url: URL) throws {
        var mutableURL = url
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try mutableURL.setResourceValues(resourceValues)
    }

    private func directorySizeString(at url: URL) -> String {
        let totalBytes = directorySize(at: url)
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: totalBytes)
    }

    private func directorySize(at url: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
               let size = values.fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}
