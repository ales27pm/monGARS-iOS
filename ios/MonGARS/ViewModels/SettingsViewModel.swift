import Foundation
import SwiftUI
import UIKit

@Observable
@MainActor
final class SettingsViewModel {
    let localeManager: LocaleManager
    let modelDownloadManager: ModelDownloadManager
    let permissionsManager: PermissionsManager
    let networkPolicy: NetworkPolicyService
    let runtimeCoordinator: ModelRuntimeCoordinator?

    private static let diagnosticsDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var showDeleteConfirmation: Bool = false
    var deleteTargetSourceID: ModelSourceID?

    init(
        localeManager: LocaleManager,
        modelDownloadManager: ModelDownloadManager,
        permissionsManager: PermissionsManager,
        networkPolicy: NetworkPolicyService,
        runtimeCoordinator: ModelRuntimeCoordinator? = nil
    ) {
        self.localeManager = localeManager
        self.modelDownloadManager = modelDownloadManager
        self.permissionsManager = permissionsManager
        self.networkPolicy = networkPolicy
        self.runtimeCoordinator = runtimeCoordinator
    }

    var selectedLanguage: AppLanguage {
        get { localeManager.currentLanguage }
        set { localeManager.currentLanguage = newValue }
    }

    var selectedChatSourceID: ModelSourceID {
        get { modelDownloadManager.selectedChatSourceID }
        set {
            modelDownloadManager.selectedChatSourceID = newValue
            modelDownloadManager.refreshSelectedStates()
            Task {
                try? await SecureStoreService.shared.save(key: .selectedModelVariant, value: newValue)
            }
        }
    }

    var selectedEmbeddingSourceID: ModelSourceID {
        get { modelDownloadManager.selectedEmbeddingSourceID }
        set {
            modelDownloadManager.selectedEmbeddingSourceID = newValue
            modelDownloadManager.refreshSelectedStates()
            Task {
                try? await SecureStoreService.shared.save(key: .selectedEmbeddingSource, value: newValue)
            }
        }
    }

    var runtimeAvailabilityGuidance: ModelRuntimeCoordinator.LLMAvailabilityGuidance? {
        ModelRuntimeCoordinator.guidance(for: runtimeCoordinator?.llmAvailabilityIssue)
    }

    var chatModelLastFailure: ModelFailureReport? {
        modelDownloadManager.lastFailureReport(for: selectedChatSourceID)
    }

    var embeddingModelLastFailure: ModelFailureReport? {
        modelDownloadManager.lastFailureReport(for: selectedEmbeddingSourceID)
    }

    var hasDiagnostics: Bool {
        runtimeAvailabilityGuidance != nil || chatModelLastFailure != nil || embeddingModelLastFailure != nil
    }

    func deleteModel(_ sourceID: ModelSourceID) {
        modelDownloadManager.deleteModel(sourceID: sourceID)
        persistSelectedSourceIDs()
    }

    func downloadModel(_ sourceID: ModelSourceID) {
        modelDownloadManager.startDownload(sourceID: sourceID)
    }

    func requestVoicePermissions() async {
        await permissionsManager.requestAllVoicePermissions()
    }

    var shouldShowVoiceSettingsRecovery: Bool {
        permissionsManager.voicePermissionsDenied
    }

    /// Opens this app's iOS Settings page for permission recovery flows.
    func openAppSettings() {
        guard let settingsURL = URL(string: UIApplication.openSettingsURLString),
              UIApplication.shared.canOpenURL(settingsURL) else {
            return
        }
        UIApplication.shared.open(settingsURL)
    }

    func requestAllNativeFeaturePermissions() async {
        await permissionsManager.requestAllNativeFeaturePermissions()
    }

    func localizedRuntimeAvailabilityMessage(_ guidance: ModelRuntimeCoordinator.LLMAvailabilityGuidance) -> String {
        switch localeManager.currentLanguage {
        case .englishCA:
            guidance.englishMessage
        case .frenchCA:
            guidance.frenchMessage
        }
    }

    func localizedFailureStage(_ stage: ModelFailureStage) -> String {
        switch stage {
        case .preflight:
            return localeManager.localizedString("Preflight", "Pré-vérification")
        case .downloading:
            return localeManager.localizedString("Download", "Téléchargement")
        case .installing:
            return localeManager.localizedString("Install", "Installation")
        case .validating:
            return localeManager.localizedString("Validation", "Validation")
        case .tokenizer:
            return localeManager.localizedString("Tokenizer", "Tokenizer")
        case .storage:
            return localeManager.localizedString("Storage", "Stockage")
        case .runtime:
            return localeManager.localizedString("Runtime", "Runtime")
        }
    }

    func localizedRecoveryAction(_ action: ModelRecoveryAction) -> String {
        switch action {
        case .retryDownload:
            return localeManager.localizedString("Retry the download.", "Réessayez le téléchargement.")
        case .checkNetworkConnection:
            return localeManager.localizedString("Check internet connectivity and retry.", "Vérifiez la connexion Internet et réessayez.")
        case .waitAndRetry:
            return localeManager.localizedString("Wait a few minutes, then retry.", "Attendez quelques minutes, puis réessayez.")
        case .acceptModelLicense:
            return localeManager.localizedString("Accept model access/license on Hugging Face, then retry.", "Acceptez l'accès/la licence du modèle sur Hugging Face, puis réessayez.")
        case .freeStorageSpace:
            return localeManager.localizedString("Free storage space on device, then retry.", "Libérez de l'espace de stockage sur l'appareil, puis réessayez.")
        case .reinstallModel:
            return localeManager.localizedString("Reinstall the selected model from Settings.", "Réinstallez le modèle sélectionné depuis les Réglages.")
        case .chooseAnotherModel:
            return localeManager.localizedString("Select another model source in Settings.", "Sélectionnez une autre source de modèle dans les Réglages.")
        case .openModelSettings:
            return localeManager.localizedString("Open Settings > Chat Model to review model setup.", "Ouvrez Réglages > Modèle de conversation pour vérifier la configuration du modèle.")
        case .closeOtherApps:
            return localeManager.localizedString("Close other apps to reduce memory pressure.", "Fermez les autres apps pour réduire la pression mémoire.")
        case .retryRuntimeLoad:
            return localeManager.localizedString("Retry loading the model runtime from Settings.", "Réessayez le chargement du runtime du modèle depuis les Réglages.")
        }
    }

    func localizedTimestamp(_ date: Date) -> String {
        Self.diagnosticsDateFormatter.string(from: date)
    }

    private func persistSelectedSourceIDs() {
        let chatSourceID = modelDownloadManager.selectedChatSourceID
        let embeddingSourceID = modelDownloadManager.selectedEmbeddingSourceID
        Task {
            try? await SecureStoreService.shared.save(key: .selectedModelVariant, value: chatSourceID)
            try? await SecureStoreService.shared.save(key: .selectedEmbeddingSource, value: embeddingSourceID)
        }
    }
}
