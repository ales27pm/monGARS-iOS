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
        get {
            let exists = SecureStoreService.syncExists(key: .onboardingCompleted)
            if exists { return true }
            return UserDefaults.standard.bool(forKey: "has_completed_onboarding")
        }
    }

    var isDownloading: Bool {
        modelDownloadManager.llmState.isDownloading
    }

    var isInstalling: Bool {
        modelDownloadManager.llmState.isInstalling
    }

    var isModelReady: Bool {
        modelDownloadManager.isLLMReady
    }

    var downloadProgress: Double {
        if case .downloading(let progress) = modelDownloadManager.llmState {
            return progress
        }
        return 0
    }

    var downloadErrorMessage: String? {
        if case .error(let msg) = modelDownloadManager.llmState {
            return msg
        }
        return nil
    }

    var installPhaseDescription: String? {
        guard let phase = modelDownloadManager.currentInstallPhase else { return nil }
        switch phase {
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

    func startDownload() {
        modelDownloadManager.startDownload(variant: modelDownloadManager.selectedLLMVariant)
    }

    func cancelDownload() {
        modelDownloadManager.cancelDownload(variant: modelDownloadManager.selectedLLMVariant)
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
        UserDefaults.standard.set(true, forKey: "has_completed_onboarding")
    }
}

enum OnboardingStep: Int, CaseIterable {
    case welcome
    case privacy
    case language
    case modelDownload
    case complete
}
