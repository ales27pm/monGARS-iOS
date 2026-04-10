import SwiftUI

@Observable
@MainActor
final class SettingsViewModel {
    let localeManager: LocaleManager
    let modelDownloadManager: ModelDownloadManager
    let permissionsManager: PermissionsManager

    var showDeleteConfirmation: Bool = false
    var modelToDelete: ModelVariant?

    init(
        localeManager: LocaleManager,
        modelDownloadManager: ModelDownloadManager,
        permissionsManager: PermissionsManager
    ) {
        self.localeManager = localeManager
        self.modelDownloadManager = modelDownloadManager
        self.permissionsManager = permissionsManager
    }

    var selectedLanguage: AppLanguage {
        get { localeManager.currentLanguage }
        set { localeManager.currentLanguage = newValue }
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
