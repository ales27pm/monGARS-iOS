import Foundation

nonisolated enum ModelVariant: String, Codable, Sendable, CaseIterable, Identifiable {
    case llama1B = "llama-3.2-1b-instruct"
    case llama3B = "llama-3.2-3b-instruct"
    case graniteEmbedding = "granite-embedding-278m"

    nonisolated var id: String { rawValue }

    var displayName: String {
        switch self {
        case .llama1B: "Llama 3.2 1B Instruct"
        case .llama3B: "Llama 3.2 3B Instruct"
        case .graniteEmbedding: "Granite Embedding 278M"
        }
    }

    var estimatedSizeBytes: Int64 {
        switch self {
        case .llama1B: 1_300_000_000
        case .llama3B: 3_600_000_000
        case .graniteEmbedding: 560_000_000
        }
    }

    var estimatedSizeDescription: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: estimatedSizeBytes)
    }

    var isLanguageModel: Bool {
        switch self {
        case .llama1B, .llama3B: true
        case .graniteEmbedding: false
        }
    }

    var isEmbeddingModel: Bool {
        self == .graniteEmbedding
    }

    var contextWindowTokens: Int {
        switch self {
        case .llama1B: 2048
        case .llama3B: 4096
        case .graniteEmbedding: 512
        }
    }

    var modelFileName: String {
        "\(rawValue).mlmodelc"
    }

    var tokenizerFolderName: String {
        "\(rawValue)-tokenizer"
    }

    var archiveFileName: String {
        "model.mlpackage.zip"
    }

    var tokenizerFiles: [String] {
        ["tokenizer.json", "tokenizer_config.json"]
    }

    var huggingFaceRepo: String {
        switch self {
        case .llama1B: "coreml-community/llama-3.2-1b-instruct"
        case .llama3B: "coreml-community/llama-3.2-3b-instruct"
        case .graniteEmbedding: "coreml-community/granite-embedding-278m-multilingual"
        }
    }
}

nonisolated enum ModelDownloadState: Sendable, Equatable {
    case notDownloaded
    case downloading(progress: Double)
    case installing
    case installed
    case error(String)

    var isInstalled: Bool {
        if case .installed = self { return true }
        return false
    }

    var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }

    var isInstalling: Bool {
        if case .installing = self { return true }
        return false
    }

    var isDownloaded: Bool { isInstalled }
}

nonisolated struct ModelFileInfo: Sendable {
    let variant: ModelVariant
    let localURL: URL
    let sizeOnDisk: Int64
}

nonisolated enum ModelInstallError: Error, Sendable {
    case extractionFailed(String)
    case invalidArchive
    case modelNotFoundInArchive
    case tokenizerDownloadFailed(String)
    case validationFailed(String)
    case insufficientSpace
    case stagingCleanupFailed
}
