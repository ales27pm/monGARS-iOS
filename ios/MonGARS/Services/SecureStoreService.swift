import Foundation
import Security

nonisolated enum SecureStoreKey: String, Sendable {
    case selectedModelVariant = "selected_model_variant"
    case lastUsedLanguage = "last_used_language"
    case onboardingCompleted = "onboarding_completed"
    case modelDownloadToken = "model_download_token"
    case networkToolsEnabled = "network_tools_enabled"
    case allowWebSearch = "allow_web_search"
    case allowWeather = "allow_weather"
    case askBeforeNetworkUse = "ask_before_network_use"
    case offlineMode = "offline_mode"
}

actor SecureStoreService {
    static let shared = SecureStoreService()

    private let serviceName = "com.mongars.securestore"

    func save(key: SecureStoreKey, value: String) throws {
        try save(rawKey: key.rawValue, value: value)
    }

    func load(key: SecureStoreKey) throws -> String? {
        try load(rawKey: key.rawValue)
    }

    func delete(key: SecureStoreKey) throws {
        try delete(rawKey: key.rawValue)
    }

    func exists(key: SecureStoreKey) -> Bool {
        exists(rawKey: key.rawValue)
    }

    static func syncExists(key: SecureStoreKey) -> Bool {
        let serviceName = "com.mongars.securestore"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: false
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func syncLoad(key: SecureStoreKey) -> String? {
        let serviceName = "com.mongars.securestore"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(rawKey: String, value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw SecureStoreError.encodingFailed
        }
        try save(rawKey: rawKey, data: data)
    }

    func save(rawKey: String, data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: rawKey
        ]

        SecItemDelete(query as CFDictionary)

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SecureStoreError.saveFailed(status)
        }
    }

    func load(rawKey: String) throws -> String? {
        guard let data = try loadData(rawKey: rawKey) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func loadData(rawKey: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: rawKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw SecureStoreError.loadFailed(status)
        }
        return result as? Data
    }

    func delete(rawKey: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: rawKey
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecureStoreError.deleteFailed(status)
        }
    }

    func exists(rawKey: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: rawKey,
            kSecReturnData as String: false
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
}

nonisolated enum SecureStoreError: Error, Sendable {
    case encodingFailed
    case saveFailed(OSStatus)
    case loadFailed(OSStatus)
    case deleteFailed(OSStatus)
}
