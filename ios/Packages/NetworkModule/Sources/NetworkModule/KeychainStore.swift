import Foundation
import Security

/// Thin wrapper over Keychain Services for storing auth tokens.
/// Service identifier is shared across all tokens; each token is a unique "account" key.
/// Accessibility: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — survives relaunch
/// without requiring the device to be currently unlocked, but doesn't migrate to new devices.
public struct KeychainStore: Sendable {
    private let service: String

    public static let `default` = KeychainStore(service: "com.don.Kiki.auth")

    public init(service: String) {
        self.service = service
    }

    public enum Error: Swift.Error, Sendable {
        case encodingFailed
        case unexpectedStatus(OSStatus)
    }

    public func set(_ value: String, for account: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw Error.encodingFailed
        }

        // Delete any existing item first so we can "set" (add-or-replace) with one call.
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw Error.unexpectedStatus(status)
        }
    }

    public func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public func remove(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    public func removeAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
