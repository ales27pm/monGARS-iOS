import SwiftUI

@Observable
@MainActor
final class SettingsViewModel {
    let localeManager: LocaleManager
    let modelDownloadManager: ModelDownloadManager
    let permissionsManager: PermissionsManager
    let networkPolicy: NetworkPolicyService

    var showDeleteConfirmation: Bool = false
    var modelToDelete: ModelVariant?

    init(
        localeManager: LocaleManager,
        modelDownloadManager: ModelDownloadManager,
        permissionsManager: PermissionsManager,
        networkPolicy: NetworkPolicyService
    ) {
        self.localeManager = localeManager
        self.modelDownloadManager = modelDownloadManager
        self.permissionsManager = permissionsManager
        self.networkPolicy = networkPolicy

        if let storedVariant = SecureStoreService.syncLoad(key: .selectedModelVariant),
           let variant = ModelVariant(rawValue: storedVariant) {
            modelDownloadManager.selectedLLMVariant = variant
        }
    }

    var selectedLanguage: AppLanguage {
        get { localeManager.currentLanguage }
        set { localeManager.currentLanguage = newValue }
    }

    var selectedModelVariant: ModelVariant {
        get { modelDownloadManager.selectedLLMVariant }
        set {
            modelDownloadManager.selectedLLMVariant = newValue
            Task {
                try? await SecureStoreService.shared.save(key: .selectedModelVariant, value: newValue.rawValue)
            }
        }
    }

    func deleteModel(_ variant: ModelVariant) {
        modelDownloadManager.deleteModel(variant: variant)
    }

    func downloadModel(_ variant: ModelVariant) {
        modelDownloadManager.startDownload(variant: variant)
    }

    func requestVoicePermissions() async {
        await permissionsManager.requestAllVoicePermissions()
    }
}
