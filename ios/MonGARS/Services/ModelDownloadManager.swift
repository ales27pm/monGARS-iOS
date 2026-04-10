import Foundation

@Observable
@MainActor
final class ModelDownloadManager {
    var llmState: ModelDownloadState = .notDownloaded
    var embeddingState: ModelDownloadState = .notDownloaded
    var selectedLLMVariant: ModelVariant = .llama1B

    private var activeTasks: [ModelVariant: URLSessionDownloadTask] = [:]

    private static let modelBaseURLString = "https://huggingface.co/coreml-community"

    init() {
        checkExistingModels()
    }

    var isLLMReady: Bool { llmState.isDownloaded }
    var isEmbeddingReady: Bool { embeddingState.isDownloaded }
    var isFullyReady: Bool { isLLMReady }

    var llmStorageUsed: String {
        guard isLLMReady else { return "0 MB" }
        return fileSizeString(at: modelDirectory(for: selectedLLMVariant))
    }

    var embeddingStorageUsed: String {
        guard isEmbeddingReady else { return "0 MB" }
        return fileSizeString(at: modelDirectory(for: .graniteEmbedding))
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

                if let error {
                    self.updateState(for: variant, state: .error(error.localizedDescription))
                    return
                }

                guard let tempURL else {
                    self.updateState(for: variant, state: .error("Download failed: no file received"))
                    return
                }

                do {
                    let destination = self.modelDirectory(for: variant)
                    let parent = destination.deletingLastPathComponent()
                    if !FileManager.default.fileExists(atPath: parent.path) {
                        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                    }
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.removeItem(at: destination)
                    }
                    try FileManager.default.moveItem(at: tempURL, to: destination)
                    self.updateState(for: variant, state: .downloaded)
                } catch {
                    self.updateState(for: variant, state: .error("Failed to save model: \(error.localizedDescription)"))
                }
            }
        }

        let observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            Task { @MainActor [weak self] in
                self?.updateState(for: variant, state: .downloading(progress: progress.fractionCompleted))
            }
        }

        _ = observation

        activeTasks[variant] = task
        task.resume()
    }

    func cancelDownload(variant: ModelVariant) {
        activeTasks[variant]?.cancel()
        activeTasks.removeValue(forKey: variant)
        updateState(for: variant, state: .notDownloaded)
    }

    func deleteModel(variant: ModelVariant) {
        let path = modelDirectory(for: variant)
        try? FileManager.default.removeItem(at: path)
        updateState(for: variant, state: .notDownloaded)
    }

    func modelDirectory(for variant: ModelVariant) -> URL {
        let docs = URL.documentsDirectory
        return docs.appending(path: "models/\(variant.rawValue)", directoryHint: .isDirectory)
    }

    func modelFileURL(for variant: ModelVariant) -> URL {
        modelDirectory(for: variant).appendingPathComponent(variant.modelFileName)
    }

    private func checkExistingModels() {
        for variant in ModelVariant.allCases {
            let dir = modelDirectory(for: variant)
            if FileManager.default.fileExists(atPath: dir.path) {
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
        URL(string: "\(Self.modelBaseURLString)/\(variant.rawValue)/resolve/main/model.mlpackage.zip")
    }

    private func fileSizeString(at url: URL) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else {
            return "Unknown"
        }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
}
