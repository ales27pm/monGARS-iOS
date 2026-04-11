import Foundation

typealias ModelSourceID = String

nonisolated enum ModelRole: String, Sendable {
    case chat
    case embedding
}

nonisolated enum PromptFormat: String, Sendable {
    case llama3
    case qwen
    case dolphin
}

nonisolated enum ArtifactType: String, Sendable {
    case compiledModel
    case mlpackageDirectory
    case zipArchive
}

nonisolated enum DownloadStrategy: Sendable {
    case archive(filename: String)
    case repoDirectory(modelPath: String)
    case unsupported(reason: String)
}

nonisolated struct ModelSource: Sendable, Identifiable {
    let id: ModelSourceID
    let displayName: String
    let repoID: String
    let role: ModelRole
    let downloadStrategy: DownloadStrategy
    let artifactType: ArtifactType
    let tokenizerFiles: [String]
    let configFiles: [String]
    let tokenizerRepoID: String?
    let tokenizerFallbackRepoIDs: [String]
    let requiresAuth: Bool
    let isRecommended: Bool
    let isExperimental: Bool
    let fallbackPriority: Int
    let estimatedSizeBytes: Int64
    let contextWindowTokens: Int
    let promptFormat: PromptFormat
    let notes: String?

    var isChat: Bool { role == .chat }
    var isEmbedding: Bool { role == .embedding }

    var estimatedSizeDescription: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: estimatedSizeBytes)
    }

    var isAvailableForDownload: Bool {
        switch downloadStrategy {
        case .unsupported: false
        default: true
        }
    }

    var badgeLabel: String? {
        if isRecommended { return "Recommended" }
        if isExperimental { return "Experimental" }
        return nil
    }

    var modelDirectoryName: String { id }

    var tokenizerFolderName: String { "\(id)-tokenizer" }

    var allTokenizerRepoIDs: [String] {
        var repos: [String] = []
        if let primary = tokenizerRepoID {
            repos.append(primary)
        } else {
            repos.append(repoID)
        }
        repos.append(contentsOf: tokenizerFallbackRepoIDs)
        return repos
    }

    var formatLabel: String {
        switch promptFormat {
        case .llama3: "Llama"
        case .qwen: "Qwen"
        case .dolphin: "Dolphin"
        }
    }

    func hfResolveURL(path: String) -> URL? {
        URL(string: "https://huggingface.co/\(repoID)/resolve/main/\(path)")
    }

    func hfTreeURL(path: String) -> URL? {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return URL(string: "https://huggingface.co/api/models/\(repoID)/tree/main/\(encoded)")
    }

    func tokenizerFileURL(fileName: String, fromRepo repo: String? = nil) -> URL? {
        let targetRepo = repo ?? tokenizerRepoID ?? repoID
        return URL(string: "https://huggingface.co/\(targetRepo)/resolve/main/\(fileName)")
    }
}

struct ModelSourceCatalog: Sendable {
    static let chatSources: [ModelSource] = [
        ModelSource(
            id: "llama-3.2-3b-4bit",
            displayName: "Llama 3.2 3B Instruct",
            repoID: "finnvoorhees/coreml-Llama-3.2-3B-Instruct-4bit",
            role: .chat,
            downloadStrategy: .repoDirectory(modelPath: "Llama-3.2-3B-Instruct-4bit.mlmodelc"),
            artifactType: .compiledModel,
            tokenizerFiles: ["tokenizer.json", "tokenizer_config.json"],
            configFiles: [],
            tokenizerRepoID: nil,
            tokenizerFallbackRepoIDs: [],
            requiresAuth: false,
            isRecommended: true,
            isExperimental: false,
            fallbackPriority: 2,
            estimatedSizeBytes: 1_800_000_000,
            contextWindowTokens: 4096,
            promptFormat: .llama3,
            notes: "4-bit quantized CoreML conversion by finnvoorhees"
        ),
        ModelSource(
            id: "qwen3-4b-8bit",
            displayName: "Qwen3 4B Instruct",
            repoID: "oceanicity/Qwen3-4B-Instruct-CoreML-8bit",
            role: .chat,
            downloadStrategy: .unsupported(reason: "Multi-chunk pipeline model. Requires pipeline inference support not yet implemented."),
            artifactType: .compiledModel,
            tokenizerFiles: ["tokenizer.json", "tokenizer_config.json"],
            configFiles: [],
            tokenizerRepoID: "Qwen/Qwen3-4B",
            tokenizerFallbackRepoIDs: [],
            requiresAuth: false,
            isRecommended: false,
            isExperimental: true,
            fallbackPriority: 99,
            estimatedSizeBytes: 4_500_000_000,
            contextWindowTokens: 4096,
            promptFormat: .qwen,
            notes: "8-bit multi-chunk pipeline. Not yet supported by single-model inference engine."
        ),
        ModelSource(
            id: "qwen2.5-3b-4bit",
            displayName: "Qwen 2.5 3B Instruct",
            repoID: "finnvoorhees/coreml-Qwen2.5-3B-Instruct-4bit",
            role: .chat,
            downloadStrategy: .repoDirectory(modelPath: "Qwen2.5-3B-Instruct-4bit.mlmodelc"),
            artifactType: .compiledModel,
            tokenizerFiles: ["tokenizer.json", "tokenizer_config.json"],
            configFiles: [],
            tokenizerRepoID: nil,
            tokenizerFallbackRepoIDs: [],
            requiresAuth: false,
            isRecommended: false,
            isExperimental: false,
            fallbackPriority: 3,
            estimatedSizeBytes: 1_800_000_000,
            contextWindowTokens: 4096,
            promptFormat: .qwen,
            notes: "4-bit quantized CoreML conversion by finnvoorhees. Stable alternative."
        ),
        ModelSource(
            id: "llama-3.2-1b",
            displayName: "Llama 3.2 1B Instruct",
            repoID: "yacht/Llama-3.2-1B-Instruct-CoreML",
            role: .chat,
            downloadStrategy: .archive(filename: "model.mlmodelc.zip"),
            artifactType: .zipArchive,
            tokenizerFiles: ["tokenizer.json", "tokenizer_config.json"],
            configFiles: [],
            tokenizerRepoID: "meta-llama/Llama-3.2-1B-Instruct",
            tokenizerFallbackRepoIDs: [],
            requiresAuth: false,
            isRecommended: false,
            isExperimental: false,
            fallbackPriority: 1,
            estimatedSizeBytes: 1_300_000_000,
            contextWindowTokens: 2048,
            promptFormat: .llama3,
            notes: "Lightweight fallback. Broader device compatibility."
        ),
        ModelSource(
            id: "dolphin-3.0-coreml",
            displayName: "Dolphin 3.0 CoreML",
            repoID: "ales27pm/Dolphin3.0-CoreML",
            role: .chat,
            downloadStrategy: .repoDirectory(modelPath: "Dolphin3.0-Llama3.2-3B-int4-lut.mlpackage"),
            artifactType: .mlpackageDirectory,
            tokenizerFiles: ["tokenizer.json", "tokenizer_config.json", "special_tokens_map.json"],
            configFiles: ["config.json", "generation_config.json"],
            tokenizerRepoID: nil,
            tokenizerFallbackRepoIDs: [
                "dphn/Dolphin3.0-Llama3.2-3B",
                "meta-llama/Llama-3.2-3B"
            ],
            requiresAuth: false,
            isRecommended: false,
            isExperimental: true,
            fallbackPriority: 4,
            estimatedSizeBytes: 2_000_000_000,
            contextWindowTokens: 4096,
            promptFormat: .dolphin,
            notes: "Dolphin 3.0 based on Llama 3.2 3B. Tokenizer may require fallback to upstream repos."
        ),
    ]

    static let embeddingSources: [ModelSource] = [
        ModelSource(
            id: "qwen3-embed-0.6b",
            displayName: "Qwen3 Embedding 0.6B",
            repoID: "NeoRoth/qwen3-embedding-0.6b-coreml",
            role: .embedding,
            downloadStrategy: .repoDirectory(modelPath: "encoder.mlmodelc"),
            artifactType: .compiledModel,
            tokenizerFiles: ["tokenizer.json", "tokenizer_config.json", "vocab.json", "merges.txt"],
            configFiles: [],
            tokenizerRepoID: nil,
            tokenizerFallbackRepoIDs: [],
            requiresAuth: false,
            isRecommended: true,
            isExperimental: false,
            fallbackPriority: 1,
            estimatedSizeBytes: 1_200_000_000,
            contextWindowTokens: 512,
            promptFormat: .qwen,
            notes: "Primary CoreML embedding model for semantic memory"
        ),
        ModelSource(
            id: "qwen3-embed-0.6b-alt",
            displayName: "Qwen3 Embedding 0.6B (Alt)",
            repoID: "tooktang/Qwen3-Embedding-0.6B-CoreML",
            role: .embedding,
            downloadStrategy: .unsupported(reason: "Non-standard repository structure. Use the primary NeoRoth source."),
            artifactType: .compiledModel,
            tokenizerFiles: ["tokenizer.json", "tokenizer_config.json"],
            configFiles: [],
            tokenizerRepoID: "Qwen/Qwen3-Embedding-0.6B",
            tokenizerFallbackRepoIDs: [],
            requiresAuth: false,
            isRecommended: false,
            isExperimental: true,
            fallbackPriority: 2,
            estimatedSizeBytes: 1_200_000_000,
            contextWindowTokens: 512,
            promptFormat: .qwen,
            notes: "Fallback embedding source. Non-standard repo layout."
        ),
    ]

    static let allSources: [ModelSource] = chatSources + embeddingSources

    static func source(for id: ModelSourceID) -> ModelSource? {
        allSources.first { $0.id == id }
    }

    static func chatSource(for id: ModelSourceID) -> ModelSource? {
        chatSources.first { $0.id == id }
    }

    static func embeddingSource(for id: ModelSourceID) -> ModelSource? {
        embeddingSources.first { $0.id == id }
    }

    static var downloadableChatSources: [ModelSource] {
        chatSources.filter(\.isAvailableForDownload)
    }

    static var downloadableEmbeddingSources: [ModelSource] {
        embeddingSources.filter(\.isAvailableForDownload)
    }

    static var defaultChatSourceID: ModelSourceID { "llama-3.2-3b-4bit" }
    static var defaultEmbeddingSourceID: ModelSourceID { "qwen3-embed-0.6b" }

    static var fallbackChatSourceID: ModelSourceID { "llama-3.2-1b" }

    static func migrateOldVariant(_ oldRawValue: String) -> ModelSourceID? {
        switch oldRawValue {
        case "llama-3.2-1b-instruct": return "llama-3.2-1b"
        case "llama-3.2-3b-instruct": return "llama-3.2-3b-4bit"
        case "granite-embedding-278m": return nil
        default: return nil
        }
    }
}

nonisolated enum ModelDownloadState: Sendable, Equatable {
    case notDownloaded
    case downloading(progress: Double)
    case installing
    case installed
    case installedMissingTokenizer
    case unavailable(String)
    case error(String)

    var isInstalled: Bool {
        if case .installed = self { return true }
        return false
    }

    var isInstalledPartially: Bool {
        if case .installedMissingTokenizer = self { return true }
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
    let sourceID: ModelSourceID
    let localURL: URL
    let sizeOnDisk: Int64
}

nonisolated enum ModelInstallError: Error, Sendable {
    case extractionFailed(String)
    case invalidArchive
    case modelNotFoundInArchive
    case tokenizerDownloadFailed(String)
    case tokenizerGated(String)
    case validationFailed(String)
    case insufficientSpace
    case stagingCleanupFailed
    case notAvailableForDownload(String)
    case preflightFailed(String)
    case hfTreeListFailed(String)
    case fileDownloadFailed(String)
    case mlpackageInvalid(String)
}

nonisolated enum DownloadDiagnosticError: Error, Sendable {
    case accessDenied(url: String, statusCode: Int)
    case notFound(url: String)
    case rateLimited(url: String)
    case serverError(url: String, statusCode: Int)
    case unexpectedStatus(url: String, statusCode: Int, bodyPreview: String)
    case preflightUnreachable(url: String, underlyingError: String)
    case noDownloadURL(sourceID: String)

    var userMessage: String {
        switch self {
        case .accessDenied(let url, let code):
            "Access denied (HTTP \(code)). This model may be gated and require authentication or license acceptance on Hugging Face. URL: \(url)"
        case .notFound(let url):
            "Model artifact not found (HTTP 404). The file may have been moved or removed. URL: \(url)"
        case .rateLimited(let url):
            "Rate limited (HTTP 429). Please wait a few minutes and try again. URL: \(url)"
        case .serverError(let url, let code):
            "Server error (HTTP \(code)). The model host is experiencing issues. URL: \(url)"
        case .unexpectedStatus(let url, let code, let body):
            "Unexpected response (HTTP \(code)) from \(url). Response: \(body)"
        case .preflightUnreachable(let url, let error):
            "Could not reach model host. URL: \(url). Error: \(error)"
        case .noDownloadURL(let sourceID):
            "No download URL configured for \(sourceID)."
        }
    }
}

nonisolated enum InstallPhase: String, Sendable {
    case preflight
    case downloading
    case extracting
    case validating
    case installingTokenizer
    case installingConfig
    case complete
}

nonisolated enum OverallInstallPhase: String, Sendable {
    case llmDownload
    case llmInstall
    case embeddingDownload
    case embeddingInstall
    case tokenizerInstall
    case validation
    case complete
}

nonisolated struct HFFileEntry: Sendable {
    let path: String
    let size: Int64
    let type: String
}

nonisolated struct TokenizerFallbackResult: Sendable {
    let resolvedRepo: String
    let filesDownloaded: [String]
    let filesMissing: [String]
    let gatedRepos: [String]
}
