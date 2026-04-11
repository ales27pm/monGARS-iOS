import SwiftUI

@Observable
@MainActor
final class SettingsViewModel {
    let localeManager: LocaleManager
    let modelDownloadManager: ModelDownloadManager
    let permissionsManager: PermissionsManager
    let networkPolicy: NetworkPolicyService

    var showDeleteConfirmation: Bool = false
    var deleteTargetSourceID: ModelSourceID?

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

        if let storedID = SecureStoreService.syncLoad(key: .selectedModelVariant) {
            if ModelSourceCatalog.chatSource(for: storedID) != nil {
                modelDownloadManager.selectedChatSourceID = storedID
            } else if let migrated = ModelSourceCatalog.migrateOldVariant(storedID),
                      ModelSourceCatalog.chatSource(for: migrated) != nil {
                modelDownloadManager.selectedChatSourceID = migrated
            }
        }

        if let storedEmbedID = SecureStoreService.syncLoad(key: .selectedEmbeddingSource) {
            if ModelSourceCatalog.embeddingSource(for: storedEmbedID) != nil {
                modelDownloadManager.selectedEmbeddingSourceID = storedEmbedID
            }
        }
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

    func deleteModel(_ sourceID: ModelSourceID) {
        modelDownloadManager.deleteModel(sourceID: sourceID)
    }

    func downloadModel(_ sourceID: ModelSourceID) {
        modelDownloadManager.startDownload(sourceID: sourceID)
    }

    func requestVoicePermissions() async {
        await permissionsManager.requestAllVoicePermissions()
    }
}
