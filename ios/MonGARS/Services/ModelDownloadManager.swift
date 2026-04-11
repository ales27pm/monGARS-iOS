import Foundation
import ZIPFoundation
import os

nonisolated enum InstallPhase: String, Sendable {
    case downloading
    case extracting
    case validating
    case installingTokenizer
    case complete
}

@Observable
@MainActor
final class ModelDownloadManager {
    var llmState: ModelDownloadState = .notDownloaded
    var embeddingState: ModelDownloadState = .notDownloaded
    var selectedLLMVariant: ModelVariant = .llama1B
    var currentInstallPhase: InstallPhase?

    private var activeTasks: [ModelVariant: URLSessionDownloadTask] = [:]
    private var progressObservations: [ModelVariant: NSKeyValueObservation] = [:]
    private let logger = Logger(subsystem: "com.mongars.models", category: "download")
    private let fileManager = FileManager.default

    init() {
        checkExistingModels()
    }

    var isLLMReady: Bool { llmState.isInstalled }
    var isEmbeddingReady: Bool { embeddingState.isInstalled }
    var isFullyReady: Bool { isLLMReady }

    var llmStorageUsed: String {
        guard isLLMReady else { return "0 MB" }
        return directorySizeString(at: modelDirectory(for: selectedLLMVariant))
    }

    var embeddingStorageUsed: String {
        guard isEmbeddingReady else { return "0 MB" }
        return directorySizeString(at: modelDirectory(for: .graniteEmbedding))
    }

    func startDownload(variant: ModelVariant) {
        guard let url = archiveDownloadURL(for: variant) else {
            updateState(for: variant, state: .error("Invalid download URL"))
            return
        }

        guard hasSufficientSpace(for: variant) else {
            updateState(for: variant, state: .error("Insufficient disk space"))
            return
        }

        updateState(for: variant, state: .downloading(progress: 0))
        currentInstallPhase = .downloading

        let task = URLSession.shared.downloadTask(with: url) { [weak self] tempURL, response, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.progressObservations.removeValue(forKey: variant)
                self.activeTasks.removeValue(forKey: variant)

                if let error {
                    if (error as NSError).code == NSURLErrorCancelled {
                        self.updateState(for: variant, state: .notDownloaded)
                    } else {
                        self.updateState(for: variant, state: .error(error.localizedDescription))
                    }
                    self.currentInstallPhase = nil
                    return
                }

                guard let tempURL else {
                    self.updateState(for: variant, state: .error("Download failed: no file received"))
                    self.currentInstallPhase = nil
                    return
                }

                guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
                    self.updateState(for: variant, state: .error("Server returned an error"))
                    self.currentInstallPhase = nil
                    return
                }

                self.updateState(for: variant, state: .installing)
                await self.installModel(archiveURL: tempURL, variant: variant)
            }
        }

        let observation = task.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
            Task { @MainActor [weak self] in
                self?.updateState(for: variant, state: .downloading(progress: progress.fractionCompleted))
            }
        }
        progressObservations[variant] = observation
        activeTasks[variant] = task
        task.resume()
    }

    func cancelDownload(variant: ModelVariant) {
        activeTasks[variant]?.cancel()
        activeTasks.removeValue(forKey: variant)
        progressObservations.removeValue(forKey: variant)
        currentInstallPhase = nil
        updateState(for: variant, state: .notDownloaded)
    }

    func deleteModel(variant: ModelVariant) {
        let modelDir = modelDirectory(for: variant)
        try? fileManager.removeItem(at: modelDir)

        let tokDir = modelsBaseDirectory().appendingPathComponent(variant.tokenizerFolderName, isDirectory: true)
        try? fileManager.removeItem(at: tokDir)

        updateState(for: variant, state: .notDownloaded)
        logger.info("Model deleted: \(variant.rawValue)")
    }

    func modelsBaseDirectory() -> URL {
        URL.documentsDirectory.appending(path: "models", directoryHint: .isDirectory)
    }

    func modelDirectory(for variant: ModelVariant) -> URL {
        modelsBaseDirectory().appending(path: variant.rawValue, directoryHint: .isDirectory)
    }

    func modelFileURL(for variant: ModelVariant) -> URL? {
        let dir = modelDirectory(for: variant)

        let mlmodelc = dir.appendingPathComponent(variant.modelFileName)
        if fileManager.fileExists(atPath: mlmodelc.path) {
            return mlmodelc
        }

        let mlpackage = dir.appendingPathComponent("\(variant.rawValue).mlpackage")
        if fileManager.fileExists(atPath: mlpackage.path) {
            return mlpackage
        }

        if let contents = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            if let compiledModel = contents.first(where: { $0.pathExtension == "mlmodelc" }) {
                return compiledModel
            }
            if let packageModel = contents.first(where: { $0.pathExtension == "mlpackage" }) {
                return packageModel
            }
        }

        return nil
    }

    func tokenizerDirectory(for variant: ModelVariant) -> URL? {
        let modelDir = modelDirectory(for: variant)

        let tokenizerJson = modelDir.appendingPathComponent("tokenizer.json")
        if fileManager.fileExists(atPath: tokenizerJson.path) {
            return modelDir
        }

        let siblingDir = modelsBaseDirectory().appendingPathComponent(variant.tokenizerFolderName, isDirectory: true)
        let siblingJson = siblingDir.appendingPathComponent("tokenizer.json")
        if fileManager.fileExists(atPath: siblingJson.path) {
            return siblingDir
        }

        return nil
    }

    var availableDiskSpaceBytes: Int64 {
        let path = URL.documentsDirectory
        guard let values = try? path.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage else {
            return 0
        }
        return available
    }

    func hasSufficientSpace(for variant: ModelVariant) -> Bool {
        let required = variant.estimatedSizeBytes
        let buffer: Int64 = 500_000_000
        return availableDiskSpaceBytes > (required + buffer)
    }

    private func installModel(archiveURL: URL, variant: ModelVariant) async {
        let stagingDir = modelsBaseDirectory().appendingPathComponent("staging-\(variant.rawValue)", isDirectory: true)

        do {
            try cleanAndCreateDirectory(at: stagingDir)

            currentInstallPhase = .extracting
            logger.info("Extracting archive for \(variant.rawValue)...")
            try extractArchive(at: archiveURL, to: stagingDir)

            currentInstallPhase = .validating
            let modelArtifactURL = try locateModelArtifact(in: stagingDir, variant: variant)
            logger.info("Found model artifact: \(modelArtifactURL.lastPathComponent)")

            let destDir = modelDirectory(for: variant)
            try cleanAndCreateDirectory(at: destDir)

            let destModelURL = destDir.appendingPathComponent(modelArtifactURL.lastPathComponent)
            try fileManager.moveItem(at: modelArtifactURL, to: destModelURL)

            currentInstallPhase = .installingTokenizer
            await downloadTokenizerFiles(variant: variant, to: destDir)

            try validateInstall(modelDir: destDir, variant: variant)

            var mutableDest = destDir
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            try mutableDest.setResourceValues(resourceValues)

            try? fileManager.removeItem(at: stagingDir)
            try? fileManager.removeItem(at: archiveURL)

            currentInstallPhase = .complete
            updateState(for: variant, state: .installed)
            logger.info("Model installed successfully: \(variant.rawValue)")

        } catch {
            try? fileManager.removeItem(at: stagingDir)
            let msg = "Install failed: \(error.localizedDescription)"
            updateState(for: variant, state: .error(msg))
            logger.error("\(msg)")
        }

        currentInstallPhase = nil
    }

    private func extractArchive(at archiveURL: URL, to destinationDir: URL) throws {
        let archiveData = try Data(contentsOf: archiveURL, options: .mappedIfSafe)
        let headerBytes = [UInt8](archiveData.prefix(4))
        let isZip = headerBytes.count >= 4 && headerBytes[0] == 0x50 && headerBytes[1] == 0x4B && headerBytes[2] == 0x03 && headerBytes[3] == 0x04

        guard isZip else {
            throw ModelInstallError.invalidArchive
        }

        try fileManager.unzipItem(at: archiveURL, to: destinationDir)
    }

    private func locateModelArtifact(in directory: URL, variant: ModelVariant) throws -> URL {
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

    private func downloadTokenizerFiles(variant: ModelVariant, to directory: URL) async {
        for fileName in variant.tokenizerFiles {
            let destFile = directory.appendingPathComponent(fileName)
            if fileManager.fileExists(atPath: destFile.path) { continue }

            guard let url = tokenizerFileURL(for: variant, fileName: fileName) else { continue }

            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                    logger.warning("Tokenizer file \(fileName) not available (HTTP error)")
                    continue
                }
                try data.write(to: destFile, options: .atomic)
                logger.info("Downloaded tokenizer file: \(fileName)")
            } catch {
                logger.warning("Failed to download tokenizer file \(fileName): \(error.localizedDescription)")
            }
        }
    }

    private func validateInstall(modelDir: URL, variant: ModelVariant) throws {
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
        let minimumExpected = variant.estimatedSizeBytes / 10
        guard dirSize > minimumExpected else {
            throw ModelInstallError.validationFailed("Installed model appears too small (\(dirSize) bytes)")
        }
    }

    private func checkExistingModels() {
        for variant in ModelVariant.allCases {
            let dir = modelDirectory(for: variant)
            guard fileManager.fileExists(atPath: dir.path) else { continue }

            do {
                try validateInstall(modelDir: dir, variant: variant)
                updateState(for: variant, state: .installed)
            } catch {
                logger.warning("Existing model \(variant.rawValue) failed validation: \(error.localizedDescription)")
                updateState(for: variant, state: .notDownloaded)
            }
        }
    }

    private func updateState(for variant: ModelVariant, state: ModelDownloadState) {
        if variant.isLanguageModel {
            llmState = state
        } else if variant.isEmbeddingModel {
            embeddingState = state
        }
    }

    private func archiveDownloadURL(for variant: ModelVariant) -> URL? {
        URL(string: "https://huggingface.co/\(variant.huggingFaceRepo)/resolve/main/\(variant.archiveFileName)")
    }

    private func tokenizerFileURL(for variant: ModelVariant, fileName: String) -> URL? {
        URL(string: "https://huggingface.co/\(variant.huggingFaceRepo)/resolve/main/\(fileName)")
    }

    private func cleanAndCreateDirectory(at url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
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
