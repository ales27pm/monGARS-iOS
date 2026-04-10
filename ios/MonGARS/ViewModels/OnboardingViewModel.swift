import SwiftUI

@Observable
@MainActor
final class OnboardingViewModel {
    let modelDownloadManager: ModelDownloadManager
    let localeManager: LocaleManager

    var currentStep: OnboardingStep = .welcome
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "has_completed_onboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "has_completed_onboarding") }
    }

    init(modelDownloadManager: ModelDownloadManager, localeManager: LocaleManager) {
        self.modelDownloadManager = modelDownloadManager
        self.localeManager = localeManager
    }

    var isDownloading: Bool {
        modelDownloadManager.llmState.isDownloading
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
            hasCompletedOnboarding = true
        }
    }

    func skipToComplete() {
        hasCompletedOnboarding = true
    }
}

enum OnboardingStep: Int, CaseIterable {
    case welcome
    case privacy
    case language
    case modelDownload
    case complete
}
