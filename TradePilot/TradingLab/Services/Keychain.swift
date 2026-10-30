import Foundation
import Security

/// Generic-password Keychain items, this-device-only, in the data-protection keychain on both iOS and macOS.
nonisolated enum Keychain {
    enum Item: String {
        case alpacaKey = "key"
        case alpacaSecret = "secret"
        case gemini = "gemini"
        case refreshToken = "auth-refresh"
        case appleUserID = "auth-apple-user"
        case brokerKeyID = "broker-key-id"
        case brokerSecret = "broker-secret"
        case brokerToken = "broker-oauth-token"
        case brokerEnvironment = "broker-environment"
        var service: String {
            switch self {
            case .alpacaKey, .alpacaSecret, .gemini: return "TradingLabAlpaca" // v1 service name, kept so saved keys survive
            case .refreshToken, .appleUserID: return "TradingLabAuth"
            case .brokerKeyID, .brokerSecret, .brokerToken, .brokerEnvironment: return "TradingLabBroker"
            }
        }
    }

    private static func query(_ item: Item) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: item.service,
            kSecAttrAccount as String: item.rawValue,
        ]
        #if os(macOS)
        q[kSecUseDataProtectionKeychain as String] = true
        #endif
        return q
    }

    static func read(_ item: Item) -> String? {
        var q = query(item)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &found) == errSecSuccess, let data = found as? Data {
            return String(data: data, encoding: .utf8)
        }
        #if os(macOS)
        // v1 wrote to the legacy file keychain on macOS. Move the item over on first read.
        var legacy = q
        legacy.removeValue(forKey: kSecUseDataProtectionKeychain as String)
        if SecItemCopyMatching(legacy as CFDictionary, &found) == errSecSuccess, let data = found as? Data,
           let value = String(data: data, encoding: .utf8) {
            save(value, for: item)
            legacy.removeValue(forKey: kSecReturnData as String)
            legacy.removeValue(forKey: kSecMatchLimit as String)
            SecItemDelete(legacy as CFDictionary)
            return value
        }
        #endif
        return nil
    }

    @discardableResult
    static func save(_ value: String, for item: Item) -> Bool {
        let q = query(item)
        guard !value.isEmpty else {
            SecItemDelete(q as CFDictionary)
            return true
        }
        let data = Data(value.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(q as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ item: Item) { save("", for: item) }

    /// v1 stored a bearer "recovery key" that was the only credential for the old sync API. It is retired.
    static func deleteLegacyRecoveryKey() {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "TradingLabPracticeProfile"]
        SecItemDelete(q as CFDictionary)
        #if os(macOS)
        q[kSecUseDataProtectionKeychain as String] = true
        SecItemDelete(q as CFDictionary)
        #endif
    }
}
