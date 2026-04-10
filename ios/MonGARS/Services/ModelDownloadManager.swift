import Foundation
import os

@Observable
@MainActor
final class ModelDownloadManager {
    var llmState: ModelDownloadState = .notDownloaded
    var embeddingState: ModelDownloadState = .notDownloaded
    var selectedLLMVariant: ModelVariant = .llama1B

    private var activeTasks: [ModelVariant: URLSessionDownloadTask] = [:]
    private var progressObservations: [ModelVariant: NSKeyValueObservation] = [:]
    private let logger = Logger(subsystem: "com.mongars.models", category: "download")
    private let fileManager = FileManager.default

    init() {
        checkExistingModels()
    }

    var isLLMReady: Bool { llmState.isDownloaded }
    var isEmbeddingReady: Bool { embeddingState.isDownloaded }
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
        guard let url = downloadURL(for: variant) else {
            updateState(for: variant, state: .error("Invalid download URL"))
            return
        }

        updateState(for: variant, state: .downloading(progress: 0))

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
                    return
                }

                guard let tempURL else {
                    self.updateState(for: variant, state: .error("Download failed: no file received"))
                    return
                }

                do {
                    try self.installDownloadedFile(tempURL: tempURL, variant: variant)
                    self.updateState(for: variant, state: .downloaded)
                    self.logger.info("Model installed: \(variant.rawValue)")
                } catch {
                    self.updateState(for: variant, state: .error("Install failed: \(error.localizedDescription)"))
                    self.logger.error("Install error for \(variant.rawValue): \(error.localizedDescription)")
                }
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
        updateState(for: variant, state: .notDownloaded)
    }

    func deleteModel(variant: ModelVariant) {
        let path = modelDirectory(for: variant)
        try? fileManager.removeItem(at: path)
        updateState(for: variant, state: .notDownloaded)
        logger.info("Model deleted: \(variant.rawValue)")
    }

    func modelsBaseDirectory() -> URL {
        let docs = URL.documentsDirectory
        return docs.appending(path: "models", directoryHint: .isDirectory)
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

        let mlmodel = dir.appendingPathComponent("\(variant.rawValue).mlmodel")
        if fileManager.fileExists(atPath: mlmodel.path) {
            return mlmodel
        }

        if fileManager.fileExists(atPath: dir.path) {
            return dir
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

    private func installDownloadedFile(tempURL: URL, variant: ModelVariant) throws {
        let destDir = modelDirectory(for: variant)
        let parentDir = destDir.deletingLastPathComponent()

        if !fileManager.fileExists(atPath: parentDir.path) {
            try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }

        if fileManager.fileExists(atPath: destDir.path) {
            try fileManager.removeItem(at: destDir)
        }

        try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)

        let tempFilePath = tempURL.path
        let destFile = destDir.appendingPathComponent(variant.modelFileName)
        try fileManager.moveItem(atPath: tempFilePath, toPath: destFile.path)

        logger.info("Installed model file to \(destDir.lastPathComponent)/\(variant.modelFileName)")

        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableDest = destDir
        try mutableDest.setResourceValues(resourceValues)
    }

    private func checkExistingModels() {
        for variant in ModelVariant.allCases {
            let dir = modelDirectory(for: variant)
            if fileManager.fileExists(atPath: dir.path) {
                updateState(for: variant, state: .downloaded)
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

    private func downloadURL(for variant: ModelVariant) -> URL? {
        URL(string: "https://huggingface.co/coreml-community/\(variant.rawValue)/resolve/main/model.mlpackage.zip")
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

nonisolated enum ModelInstallError: Error, Sendable {
    case extractionFailed(String)
    case invalidArchive
}
