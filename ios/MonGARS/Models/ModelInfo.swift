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
}

nonisolated enum ModelDownloadState: Sendable, Equatable {
    case notDownloaded
    case downloading(progress: Double)
    case paused(progress: Double)
    case downloaded
    case error(String)

    var isDownloaded: Bool {
        if case .downloaded = self { return true }
        return false
    }

    var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }
}

nonisolated struct ModelFileInfo: Sendable {
    let variant: ModelVariant
    let localURL: URL
    let sizeOnDisk: Int64
}
