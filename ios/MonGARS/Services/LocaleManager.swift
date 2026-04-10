import SwiftUI

@Observable
@MainActor
final class LocaleManager {
    var currentLanguage: AppLanguage {
        didSet {
            UserDefaults.standard.set(currentLanguage.rawValue, forKey: "app_language")
            Task {
                try? await SecureStoreService.shared.save(key: .lastUsedLanguage, value: currentLanguage.rawValue)
            }
        }
    }

    init() {
        let stored = UserDefaults.standard.string(forKey: "app_language")
        if let stored, let lang = AppLanguage(rawValue: stored) {
            self.currentLanguage = lang
        } else {
            let preferred = Locale.preferredLanguages.first ?? "en-CA"
            self.currentLanguage = preferred.hasPrefix("fr") ? .frenchCA : .englishCA
        }
    }

    func localizedString(_ english: String, _ french: String) -> String {
        currentLanguage == .frenchCA ? french : english
    }
}
