import Foundation
import Security

/// Stores the user's GitHub token as a generic password in the login Keychain.
///
/// Shared by the app and `reload` (docs/architecture/core.md).
public struct KeychainStore: Sendable {
    public struct KeychainError: Error, LocalizedError, Sendable {
        public var status: OSStatus
        public var errorDescription: String? {
            (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)."
        }
    }

    public var service: String
    public var account: String

    public init(service: String = AppInfo.bundleID, account: String = "github-token") {
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

    /// The stored value, or nil if none is stored or it can't be read. The default service
    /// also takes over a token stored under the old ForeverAddons bundle ID, once (decision 0024).
    public func get() -> String? {
        if let value = read() { return value }
        guard service == AppInfo.bundleID else { return nil }
        let legacy = KeychainStore(service: LegacyDataMigration.legacyBundleID, account: account)
        guard let value = legacy.read(), (try? set(value)) != nil else { return nil }
        try? legacy.delete()
        return value
    }

    private func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Stores `value`, replacing any existing one. An empty string deletes the item.
    public func set(_ value: String) throws {
        guard !value.isEmpty else { return try delete() }
        let data = Data(value.utf8)
        let status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    /// Removes the item. Succeeds if nothing was stored.
    public func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}
