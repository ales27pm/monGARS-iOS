import Foundation
import ZIPFoundation
import os

@Observable
@MainActor
final class ModelDownloadManager {
    var llmState: ModelDownloadState = .notDownloaded
    var embeddingState: ModelDownloadState = .notDownloaded
    var selectedChatSourceID: ModelSourceID = ModelSourceCatalog.defaultChatSourceID
    var selectedEmbeddingSourceID: ModelSourceID = ModelSourceCatalog.defaultEmbeddingSourceID
    var currentInstallPhase: InstallPhase?
    var overallPhase: OverallInstallPhase?
    var lastDiagnosticMessage: String?
    var lastTokenizerFallbackResult: TokenizerFallbackResult?

    private var activeTasks: [ModelSourceID: URLSessionDownloadTask] = [:]
    private var progressObservations: [ModelSourceID: NSKeyValueObservation] = [:]
    private let logger = Logger(subsystem: "com.mongars.models", category: "download")
    private let fileManager = FileManager.default

    init() {
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
            updateState(for: sourceID, state: .error("Unknown model source: \(sourceID)"))
            return
        }

        guard source.isAvailableForDownload else {
            if case .unsupported(let reason) = source.downloadStrategy {
                updateState(for: sourceID, state: .unavailable(reason))
            } else {
                updateState(for: sourceID, state: .unavailable("Not available for download"))
            }
            return
        }

        guard hasSufficientSpace(for: source) else {
            updateState(for: sourceID, state: .error("Insufficient disk space. Need \(source.estimatedSizeDescription) free."))
            return
        }

        updateState(for: sourceID, state: .downloading(progress: 0))
        currentInstallPhase = .preflight

        Task {
            switch source.downloadStrategy {
            case .archive(let filename):
                guard let url = source.hfResolveURL(path: filename) else {
                    updateState(for: sourceID, state: .error(DownloadDiagnosticError.noDownloadURL(sourceID: sourceID).userMessage))
                    return
                }
                let preflightOK = await preflightCheck(url: url, sourceID: sourceID)
                guard preflightOK else { return }
                currentInstallPhase = .downloading
                if source.isChat {
                    overallPhase = .llmDownload
                } else {
                    overallPhase = .embeddingDownload
                }
                beginArchiveDownload(url: url, sourceID: sourceID)

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
        activeTasks[sourceID]?.cancel()
        activeTasks.removeValue(forKey: sourceID)
        progressObservations.removeValue(forKey: sourceID)
        currentInstallPhase = nil
        overallPhase = nil
        updateState(for: sourceID, state: .notDownloaded)
    }

    func deleteModel(sourceID: ModelSourceID) {
        let modelDir = modelDirectory(for: sourceID)
        try? fileManager.removeItem(at: modelDir)
        updateState(for: sourceID, state: .notDownloaded)
        logger.info("Model deleted: \(sourceID)")
    }

    func modelsBaseDirectory() -> URL {
        URL.documentsDirectory.appending(path: "models", directoryHint: .isDirectory)
    }

    func modelDirectory(for sourceID: ModelSourceID) -> URL {
        modelsBaseDirectory().appending(path: sourceID, directoryHint: .isDirectory)
    }

    func modelFileURL(for sourceID: ModelSourceID) -> URL? {
        let dir = modelDirectory(for: sourceID)
        guard fileManager.fileExists(atPath: dir.path) else { return nil }

        if let contents = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            if let compiled = contents.first(where: { $0.pathExtension == "mlmodelc" }) {
                return compiled
            }
            if let pkg = contents.first(where: { $0.pathExtension == "mlpackage" }) {
                return pkg
            }
            if let mlmodel = contents.first(where: { $0.pathExtension == "mlmodel" }) {
                return mlmodel
            }
        }

        return nil
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
        let path = URL.documentsDirectory
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

    private func preflightCheck(url: URL, sourceID: ModelSourceID) async -> Bool {
        logger.info("Preflight: checking \(url.absoluteString)")
        lastDiagnosticMessage = "Preflight: \(url.absoluteString)"

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 15

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                updateState(for: sourceID, state: .error("Preflight: non-HTTP response"))
                return false
            }

            let finalURL = http.url ?? url
            logger.info("Preflight resolved URL: \(finalURL.absoluteString), status: \(http.statusCode)")

            if (200...399).contains(http.statusCode) {
                return true
            }

            let diagError = classifyHTTPError(statusCode: http.statusCode, url: finalURL.absoluteString, bodyPreview: "")
            let msg = diagError.userMessage
            updateState(for: sourceID, state: .error(msg))
            lastDiagnosticMessage = msg
            return false
        } catch {
            let msg = DownloadDiagnosticError.preflightUnreachable(url: url.absoluteString, underlyingError: error.localizedDescription).userMessage
            updateState(for: sourceID, state: .error(msg))
            lastDiagnosticMessage = msg
            return false
        }
    }

    // MARK: - Archive Download

    private func beginArchiveDownload(url: URL, sourceID: ModelSourceID) {
        logger.info("Starting archive download: \(url.absoluteString) for \(sourceID)")

        let task = URLSession.shared.downloadTask(with: url) { [weak self] tempURL, response, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.progressObservations.removeValue(forKey: sourceID)
                self.activeTasks.removeValue(forKey: sourceID)

                if let error {
                    if (error as NSError).code == NSURLErrorCancelled {
                        self.updateState(for: sourceID, state: .notDownloaded)
                    } else {
                        self.updateState(for: sourceID, state: .error("Download error: \(error.localizedDescription)"))
                    }
                    self.currentInstallPhase = nil
                    return
                }

                guard let tempURL else {
                    self.updateState(for: sourceID, state: .error("Download failed: no file received"))
                    self.currentInstallPhase = nil
                    return
                }

                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    let bodyPreview = self.readBodyPreview(from: tempURL)
                    let finalURL = http.url?.absoluteString ?? url.absoluteString
                    let diagError = self.classifyHTTPError(statusCode: http.statusCode, url: finalURL, bodyPreview: bodyPreview)
                    self.updateState(for: sourceID, state: .error(diagError.userMessage))
                    self.lastDiagnosticMessage = diagError.userMessage
                    self.currentInstallPhase = nil
                    try? self.fileManager.removeItem(at: tempURL)
                    return
                }

                self.updateState(for: sourceID, state: .installing)
                await self.installArchive(archiveURL: tempURL, sourceID: sourceID)
            }
        }

        let observation = task.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
            Task { @MainActor [weak self] in
                self?.updateState(for: sourceID, state: .downloading(progress: progress.fractionCompleted))
            }
        }
        progressObservations[sourceID] = observation
        activeTasks[sourceID] = task
        task.resume()
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

            try? fileManager.removeItem(at: stagingDir)
            try? fileManager.removeItem(at: archiveURL)

            currentInstallPhase = .complete
            let hasTokenizer = tokResult.filesDownloaded.contains("tokenizer.json")
            updateState(for: sourceID, state: hasTokenizer ? .installed : .installedMissingTokenizer)
            logger.info("Archive model installed: \(sourceID)")
        } catch {
            try? fileManager.removeItem(at: stagingDir)
            updateState(for: sourceID, state: .error("Install failed: \(error.localizedDescription)"))
        }

        currentInstallPhase = nil
    }

    // MARK: - Repo Directory Download

    private func downloadRepoDirectory(source: ModelSource, modelPath: String) async {
        let sourceID = source.id

        guard let treeURL = source.hfTreeURL(path: modelPath) else {
            updateState(for: sourceID, state: .error("Invalid tree URL for \(sourceID)"))
            currentInstallPhase = nil
            return
        }

        logger.info("Listing HF directory: \(treeURL.absoluteString)")
        lastDiagnosticMessage = "Listing files: \(treeURL.absoluteString)"

        do {
            currentInstallPhase = .preflight

            let preflightOK = await preflightCheckTree(treeURL: treeURL, sourceID: sourceID)
            guard preflightOK else { return }

            let fileEntries = try await listHFDirectory(treeURL: treeURL)
            guard !fileEntries.isEmpty else {
                updateState(for: sourceID, state: .error("No files found in model directory on HuggingFace"))
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
                if Task.isCancelled {
                    updateState(for: sourceID, state: .notDownloaded)
                    currentInstallPhase = nil
                    return
                }

                guard let fileURL = source.hfResolveURL(path: entry.path) else { continue }

                let relativePath = entry.path.replacingOccurrences(of: modelPath + "/", with: "")
                let localFile = modelArtifactDir.appendingPathComponent(relativePath)

                let localDir = localFile.deletingLastPathComponent()
                if !fileManager.fileExists(atPath: localDir.path) {
                    try fileManager.createDirectory(at: localDir, withIntermediateDirectories: true)
                }

                let (data, response) = try await URLSession.shared.data(from: fileURL)
                if let http = response as? HTTPURLResponse, !(200...399).contains(http.statusCode) {
                    let diagError = classifyHTTPError(statusCode: http.statusCode, url: fileURL.absoluteString, bodyPreview: "")
                    throw ModelInstallError.fileDownloadFailed(diagError.userMessage)
                }

                try data.write(to: localFile, options: .atomic)
                downloadedBytes += Int64(data.count)

                let progress = totalBytes > 0 ? Double(downloadedBytes) / Double(totalBytes) : 0
                updateState(for: sourceID, state: .downloading(progress: min(progress, 0.99)))
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

            currentInstallPhase = .complete
            let hasTokenizer = tokResult.filesDownloaded.contains("tokenizer.json")
            updateState(for: sourceID, state: hasTokenizer ? .installed : .installedMissingTokenizer)
            logger.info("Repo directory model installed: \(sourceID)")
        } catch {
            let destDir = modelDirectory(for: sourceID)
            try? fileManager.removeItem(at: destDir)
            updateState(for: sourceID, state: .error("Install failed: \(error.localizedDescription)"))
            logger.error("Repo directory install failed for \(sourceID): \(error.localizedDescription)")
        }

        currentInstallPhase = nil
    }

    private func preflightCheckTree(treeURL: URL, sourceID: ModelSourceID) async -> Bool {
        logger.info("Preflight tree: \(treeURL.absoluteString)")
        lastDiagnosticMessage = "Verifying artifact: \(treeURL.absoluteString)"

        do {
            var request = URLRequest(url: treeURL)
            request.httpMethod = "GET"
            request.timeoutInterval = 15

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                updateState(for: sourceID, state: .error("Preflight: non-HTTP response"))
                currentInstallPhase = nil
                return false
            }

            let finalURL = http.url ?? treeURL

            if (200...299).contains(http.statusCode) {
                if let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], !jsonArray.isEmpty {
                    return true
                }
                updateState(for: sourceID, state: .error("Artifact directory is empty or invalid at \(finalURL.absoluteString)"))
                currentInstallPhase = nil
                return false
            }

            let bodyPreview = String(data: data.prefix(300), encoding: .utf8) ?? ""
            let diagError = classifyHTTPError(statusCode: http.statusCode, url: finalURL.absoluteString, bodyPreview: bodyPreview)
            updateState(for: sourceID, state: .error(diagError.userMessage))
            lastDiagnosticMessage = diagError.userMessage
            currentInstallPhase = nil
            return false
        } catch {
            let msg = DownloadDiagnosticError.preflightUnreachable(url: treeURL.absoluteString, underlyingError: error.localizedDescription).userMessage
            updateState(for: sourceID, state: .error(msg))
            lastDiagnosticMessage = msg
            currentInstallPhase = nil
            return false
        }
    }

    private func listHFDirectory(treeURL: URL) async throws -> [HFFileEntry] {
        let (data, response) = try await URLSession.shared.data(from: treeURL)

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw ModelInstallError.hfTreeListFailed("HTTP \(code) from \(treeURL.absoluteString)")
        }

        guard let jsonArray = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ModelInstallError.hfTreeListFailed("Invalid JSON from HF API")
        }

        var entries: [HFFileEntry] = []
        for item in jsonArray {
            guard let type = item["type"] as? String,
                  let path = item["path"] as? String else { continue }

            if type == "file" {
                let size = (item["size"] as? Int64)
                    ?? (item["lfs"] as? [String: Any])?["size"] as? Int64
                    ?? 0
                entries.append(HFFileEntry(path: path, size: size, type: type))
            }
        }

        return entries
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

        guard let contents = try? fileManager.contentsOfDirectory(at: modelDir, includingPropertiesForKeys: nil),
              !contents.isEmpty else {
            throw ModelInstallError.validationFailed("Model directory is empty")
        }

        let hasModel = contents.contains { url in
            let ext = url.pathExtension
            return ext == "mlmodelc" || ext == "mlpackage" || ext == "mlmodel"
        }

        guard hasModel else {
            throw ModelInstallError.validationFailed("No Core ML model found in install directory")
        }

        let dirSize = directorySize(at: modelDir)
        let minimumExpected = source.estimatedSizeBytes / 20
        guard dirSize > minimumExpected else {
            throw ModelInstallError.validationFailed("Installed model appears too small (\(dirSize) bytes, expected at least \(minimumExpected))")
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

    private func checkExistingModels() {
        for source in ModelSourceCatalog.allSources {
            if !source.isAvailableForDownload {
                let dir = modelDirectory(for: source.id)
                if fileManager.fileExists(atPath: dir.path) {
                    do {
                        try validateInstall(modelDir: dir, source: source)
                        let hasTok = hasTokenizer(for: source.id)
                        updateState(for: source.id, state: hasTok ? .installed : .installedMissingTokenizer)
                        continue
                    } catch {
                        // fall through
                    }
                }
                if case .unsupported(let reason) = source.downloadStrategy {
                    updateState(for: source.id, state: .unavailable(reason))
                }
                continue
            }

            let dir = modelDirectory(for: source.id)
            guard fileManager.fileExists(atPath: dir.path) else { continue }

            do {
                try validateInstall(modelDir: dir, source: source)
                let hasTok = hasTokenizer(for: source.id)
                updateState(for: source.id, state: hasTok ? .installed : .installedMissingTokenizer)
            } catch {
                logger.warning("Existing model \(source.id) failed validation: \(error.localizedDescription)")
                updateState(for: source.id, state: .notDownloaded)
            }
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
        if source.isChat {
            llmState = state
        } else if source.isEmbedding {
            embeddingState = state
        }
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
