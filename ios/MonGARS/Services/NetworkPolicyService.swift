import SwiftUI

@Observable
@MainActor
final class NetworkPolicyService {
    var networkToolsEnabled: Bool {
        didSet { persist(.networkToolsEnabled, value: networkToolsEnabled) }
    }

    var allowWebSearch: Bool {
        didSet { persist(.allowWebSearch, value: allowWebSearch) }
    }

    var allowWeather: Bool {
        didSet { persist(.allowWeather, value: allowWeather) }
    }

    var askBeforeNetworkUse: Bool {
        didSet { persist(.askBeforeNetworkUse, value: askBeforeNetworkUse) }
    }

    var offlineMode: Bool {
        didSet { persist(.offlineMode, value: offlineMode) }
    }

    var isNetworkAllowed: Bool {
        !offlineMode && networkToolsEnabled
    }

    init() {
        self.networkToolsEnabled = Self.loadBool(.networkToolsEnabled, default: false)
        self.allowWebSearch = Self.loadBool(.allowWebSearch, default: false)
        self.allowWeather = Self.loadBool(.allowWeather, default: false)
        self.askBeforeNetworkUse = Self.loadBool(.askBeforeNetworkUse, default: true)
        self.offlineMode = Self.loadBool(.offlineMode, default: false)
    }

    func isToolAllowed(_ toolName: String) -> Bool {
        guard isNetworkAllowed else { return false }
        switch toolName {
        case "web_search": return allowWebSearch
        case "get_weather": return allowWeather
        default: return true
        }
    }

    private func persist(_ key: SecureStoreKey, value: Bool) {
        Task {
            try? await SecureStoreService.shared.save(key: key, value: value ? "1" : "0")
        }
    }

    private static func loadBool(_ key: SecureStoreKey, default defaultValue: Bool) -> Bool {
        guard let stored = SecureStoreService.syncLoad(key: key) else { return defaultValue }
        return stored == "1"
    }
}
