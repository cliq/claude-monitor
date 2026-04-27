import Foundation
import Security

/// Thin wrapper over Security.framework for storing one UTF-8 string per
/// (service, account) pair. Used by the Prowl integration to keep the API key
/// out of UserDefaults.
struct KeychainStore {
    enum Error: Swift.Error, Equatable {
        case unexpectedStatus(OSStatus)
    }

    let service: String
    let account: String

    func get() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecItemNotFound: return nil
        case errSecSuccess:
            guard let data = item as? Data, let str = String(data: data, encoding: .utf8) else { return nil }
            return str
        default:
            throw Error.unexpectedStatus(status)
        }
    }

    func set(_ value: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound { throw Error.unexpectedStatus(updateStatus) }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw Error.unexpectedStatus(addStatus) }
    }

    func delete() throws {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw Error.unexpectedStatus(status)
        }
    }
}

extension KeychainStore {
    /// Default store for the Prowl API key.
    static let prowl = KeychainStore(
        service: "com.cliq.ClaudeMonitor.prowl",
        account: "default"
    )
}
