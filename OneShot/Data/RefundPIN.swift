import Foundation
import Security

/// The owner's 4-digit refund PIN, kept in the Keychain on this iPad only (never UserDefaults, never a backup).
enum RefundPIN {
    struct KeychainError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)" }
    }

    static func isValid(_ pin: String) -> Bool { pin.count == 4 && pin.allSatisfy { $0.isASCII && $0.isNumber } }

    /// A Keychain that can't be read counts as set, so refunds fail closed.
    static func isSet(account: String = "refundPIN") -> Bool {
        do { return try read(account) != nil } catch { return true }
    }

    static func matches(_ entry: String, account: String = "refundPIN") -> Bool {
        do { return try read(account) == entry } catch { return false }
    }

    /// nil turns the PIN off.
    static func save(_ pin: String?, account: String = "refundPIN") throws {
        let deleted = SecItemDelete(query(account) as CFDictionary)
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else { throw KeychainError(status: deleted) }
        UserDefaults.standard.removeObject(forKey: account)
        guard let pin else { return }
        var item = query(account)
        item[kSecValueData as String] = Data(pin.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        UserDefaults.standard.set(true, forKey: account)
    }

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "OneShot", kSecAttrAccount as String: account]
    }

    private static func read(_ account: String) throws -> String? {
        // The Keychain outlives a reinstall and UserDefaults doesn't, so this flag (not the PIN) makes a forgotten PIN
        // go away with a reinstall. Last resort, not advertised: a reinstall also wipes Documents (prices, taught products).
        guard UserDefaults.standard.bool(forKey: account) else { return nil }
        var query = query(account)
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError(status: status) }
        return String(decoding: data, as: UTF8.self)
    }
}
