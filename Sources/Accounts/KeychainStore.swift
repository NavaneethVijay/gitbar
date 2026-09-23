import Foundation
import Security

/// Account tokens, in the Keychain only, keyed by account id — the raw
/// token never touches `UserDefaults` or any `Codable` model.
enum KeychainStore {
    private static let service = "com.navaneeth.gitbar.pat"

    static func store(token: String, for accountID: String) {
        let data = Data(token.utf8)
        var query = baseQuery(for: accountID)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let attributes: [String: Any] = [kSecValueData as String: data]
            SecItemUpdate(baseQuery(for: accountID) as CFDictionary, attributes as CFDictionary)
        }
    }

    static func read(for accountID: String) -> String? {
        var query = baseQuery(for: accountID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(for accountID: String) {
        SecItemDelete(baseQuery(for: accountID) as CFDictionary)
    }

    private static func baseQuery(for accountID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID,
        ]
    }
}
