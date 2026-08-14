import Foundation
import Security

/// Keychain storage for the backend API key.
///
/// The key lives here and nowhere else — not in source, not in `Info.plist`, not in
/// `UserDefaults`. A key committed to a repo is irreversible without rewriting history, and a
/// shipped key is extractable anyway, which is why the backend also rate-limits. See ADR-022.
public struct APIKeyStore: Sendable {
    private let service: String
    private let account: String

    public init(
        service: String = "com.codenamepromise.journal",
        account: String = "backend-api-key"
    ) {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty
        else { return nil }
        return key
    }

    /// Stores or replaces the key. Accessible only after first unlock and never synced to
    /// other devices or included in backups.
    public func write(_ key: String) throws {
        let data = Data(key.utf8)

        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let update: [String: Any] = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.unexpected(updateStatus)
            }
        default:
            throw KeychainError.unexpected(status)
        }
    }

    public func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    public enum KeychainError: Error, Sendable {
        case unexpected(OSStatus)
    }
}
