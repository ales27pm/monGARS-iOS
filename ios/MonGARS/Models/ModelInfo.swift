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

    var shortDescription: String {
        switch self {
        case .llama1B, .llama3B: "Language Model"
        case .graniteEmbedding: "Semantic Memory"
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

    var tokenizerFiles: [String] {
        ["tokenizer.json", "tokenizer_config.json"]
    }
}

nonisolated struct ModelManifestEntry: Codable, Sendable {
    let variant: String
    let archiveURL: String
    let archiveFileName: String
    let tokenizerBaseURL: String
    let requiresAuth: Bool
    let notes: String?
}

nonisolated struct ModelManifest: Sendable {
    static let entries: [ModelVariant: ModelManifestEntry] = [
        .llama1B: ModelManifestEntry(
            variant: "llama-3.2-1b-instruct",
            archiveURL: "https://huggingface.co/yacht/Llama-3.2-1B-Instruct-CoreML/resolve/main/model.mlpackage.zip",
            archiveFileName: "model.mlpackage.zip",
            tokenizerBaseURL: "https://huggingface.co/meta-llama/Llama-3.2-1B-Instruct/resolve/main",
            requiresAuth: false,
            notes: "Community CoreML conversion, anonymous download"
        ),
        .llama3B: ModelManifestEntry(
            variant: "llama-3.2-3b-instruct",
            archiveURL: "https://huggingface.co/yacht/Llama-3.2-3B-Instruct-CoreML/resolve/main/model.mlpackage.zip",
            archiveFileName: "model.mlpackage.zip",
            tokenizerBaseURL: "https://huggingface.co/meta-llama/Llama-3.2-3B-Instruct/resolve/main",
            requiresAuth: false,
            notes: "Community CoreML conversion, anonymous download"
        ),
        .graniteEmbedding: ModelManifestEntry(
            variant: "granite-embedding-278m",
            archiveURL: "",
            archiveFileName: "",
            tokenizerBaseURL: "https://huggingface.co/ibm-granite/granite-embedding-278m-multilingual/resolve/main",
            requiresAuth: false,
            notes: "No CoreML conversion available yet. Embedding model requires manual conversion from safetensors."
        )
    ]

    static func entry(for variant: ModelVariant) -> ModelManifestEntry? {
        entries[variant]
    }

    static func archiveURL(for variant: ModelVariant) -> URL? {
        guard let entry = entries[variant], !entry.archiveURL.isEmpty else { return nil }
        return URL(string: entry.archiveURL)
    }

    static func tokenizerFileURL(for variant: ModelVariant, fileName: String) -> URL? {
        guard let entry = entries[variant] else { return nil }
        return URL(string: "\(entry.tokenizerBaseURL)/\(fileName)")
    }

    static func isAvailableForDownload(_ variant: ModelVariant) -> Bool {
        guard let entry = entries[variant] else { return false }
        return !entry.archiveURL.isEmpty
    }
}

nonisolated enum ModelDownloadState: Sendable, Equatable {
    case notDownloaded
    case downloading(progress: Double)
    case installing
    case installed
    case unavailable(String)
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

    var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }

    var errorMessage: String? {
        switch self {
        case .error(let msg): msg
        case .unavailable(let msg): msg
        default: nil
        }
    }
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
    case notAvailableForDownload(String)
    case preflightFailed(String)
}

nonisolated enum DownloadDiagnosticError: Error, Sendable {
    case accessDenied(url: String, statusCode: Int)
    case notFound(url: String)
    case rateLimited(url: String)
    case serverError(url: String, statusCode: Int)
    case unexpectedStatus(url: String, statusCode: Int, bodyPreview: String)
    case preflightUnreachable(url: String, underlyingError: String)
    case noArchiveURL(variant: String)

    var userMessage: String {
        switch self {
        case .accessDenied(let url, let code):
            "Access denied (HTTP \(code)). This model requires authentication on Hugging Face. URL: \(url)"
        case .notFound(let url):
            "Model archive not found (HTTP 404). The file may have been moved or removed. URL: \(url)"
        case .rateLimited(let url):
            "Rate limited (HTTP 429). Please wait a few minutes and try again. URL: \(url)"
        case .serverError(let url, let code):
            "Server error (HTTP \(code)). The model host is experiencing issues. URL: \(url)"
        case .unexpectedStatus(let url, let code, let body):
            "Unexpected response (HTTP \(code)) from \(url). Response: \(body)"
        case .preflightUnreachable(let url, let error):
            "Could not reach model host. URL: \(url). Error: \(error)"
        case .noArchiveURL(let variant):
            "No download URL configured for \(variant). This model may require manual conversion."
        }
    }
}
