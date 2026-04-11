import SwiftUI

@Observable
@MainActor
final class OnboardingViewModel {
    let modelDownloadManager: ModelDownloadManager
    let localeManager: LocaleManager

    var currentStep: OnboardingStep = .welcome

    init(modelDownloadManager: ModelDownloadManager, localeManager: LocaleManager) {
        self.modelDownloadManager = modelDownloadManager
        self.localeManager = localeManager
    }

    var hasCompletedOnboarding: Bool {
        SecureStoreService.syncExists(key: .onboardingCompleted)
    }

    var isLLMDownloading: Bool {
        modelDownloadManager.llmState.isDownloading
    }

    var isLLMInstalling: Bool {
        modelDownloadManager.llmState.isInstalling
    }

    var isLLMReady: Bool {
        modelDownloadManager.isLLMReady
    }

    var isEmbeddingDownloading: Bool {
        modelDownloadManager.embeddingState.isDownloading
    }

    var isEmbeddingInstalling: Bool {
        modelDownloadManager.embeddingState.isInstalling
    }

    var isEmbeddingReady: Bool {
        modelDownloadManager.isEmbeddingReady
    }

    var isEmbeddingUnavailable: Bool {
        modelDownloadManager.embeddingState.isUnavailable
    }

    var isAnyDownloadActive: Bool {
        isLLMDownloading || isLLMInstalling || isEmbeddingDownloading || isEmbeddingInstalling
    }

    var isChatReady: Bool {
        modelDownloadManager.isChatReady
    }

    var llmProgress: Double {
        if case .downloading(let progress) = modelDownloadManager.llmState {
            return progress
        }
        return 0
    }

    var embeddingProgress: Double {
        if case .downloading(let progress) = modelDownloadManager.embeddingState {
            return progress
        }
        return 0
    }

    var llmErrorMessage: String? {
        modelDownloadManager.llmState.errorMessage
    }

    var embeddingErrorMessage: String? {
        modelDownloadManager.embeddingState.errorMessage
    }

    var installPhaseDescription: String? {
        guard let phase = modelDownloadManager.currentInstallPhase else { return nil }
        switch phase {
        case .preflight:
            return localeManager.localizedString("Checking model host...", "Vérification de l'hôte...")
        case .downloading:
            return localeManager.localizedString("Downloading...", "Téléchargement...")
        case .extracting:
            return localeManager.localizedString("Extracting model...", "Extraction du modèle...")
        case .validating:
            return localeManager.localizedString("Validating...", "Validation...")
        case .installingTokenizer:
            return localeManager.localizedString("Installing tokenizer...", "Installation du tokenizer...")
        case .complete:
            return localeManager.localizedString("Complete", "Terminé")
        }
    }

    var overallPhaseDescription: String? {
        guard let phase = modelDownloadManager.overallPhase else { return nil }
        switch phase {
        case .llmDownload:
            return localeManager.localizedString("Downloading language model...", "Téléchargement du modèle de langue...")
        case .llmInstall:
            return localeManager.localizedString("Installing language model...", "Installation du modèle de langue...")
        case .embeddingDownload:
            return localeManager.localizedString("Downloading embedding model...", "Téléchargement du modèle d'embeddings...")
        case .embeddingInstall:
            return localeManager.localizedString("Installing embedding model...", "Installation du modèle d'embeddings...")
        case .tokenizerInstall:
            return localeManager.localizedString("Installing tokenizer...", "Installation du tokenizer...")
        case .validation:
            return localeManager.localizedString("Validating...", "Validation...")
        case .complete:
            return localeManager.localizedString("Complete", "Terminé")
        }
    }

    func startDownload() {
        modelDownloadManager.startDownload(variant: modelDownloadManager.selectedLLMVariant)
    }

    func startEmbeddingDownload() {
        modelDownloadManager.startDownload(variant: .graniteEmbedding)
    }

    func cancelDownload() {
        modelDownloadManager.cancelDownload(variant: modelDownloadManager.selectedLLMVariant)
        modelDownloadManager.cancelDownload(variant: .graniteEmbedding)
    }

    func advanceStep() {
        switch currentStep {
        case .welcome:
            currentStep = .privacy
        case .privacy:
            currentStep = .language
        case .language:
            currentStep = .modelDownload
        case .modelDownload:
            currentStep = .complete
        case .complete:
            markOnboardingComplete()
        }
    }

    func skipToComplete() {
        markOnboardingComplete()
    }

    private func markOnboardingComplete() {
        Task {
            try? await SecureStoreService.shared.save(key: .onboardingCompleted, value: "true")
        }
    }
}

enum OnboardingStep: Int, CaseIterable {
    case welcome
    case privacy
    case language
    case modelDownload
    case complete
}
