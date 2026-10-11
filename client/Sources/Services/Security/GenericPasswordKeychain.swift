import Foundation
import Security

/// Generic-password operations shared by provider credentials and profile locks.
/// Callers retain their own isolation, encoding and error-handling policies.
///
/// Items live in the data protection keychain (`kSecUseDataProtectionKeychain`),
/// scoped to this app's own access group, so no other app can pre-create an
/// item and own its access control (audit L5). A build without a keychain
/// access group (ad-hoc development and test builds) gets
/// `errSecMissingEntitlement` there; it falls back to the file keychain, but
/// never updates an existing item in place: it deletes and re-adds, so every
/// item it writes is created, and its ACL owned, by this process. When an
/// existing item cannot be removed, the save fails rather than writing into it.
enum GenericPasswordKeychain {
    private enum Store { case dataProtection, file }

    private static func query(_ store: Store, service: String, account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if store == .dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    /// The attributes a new item is created with.
    private static func addition(_ query: [String: Any], data: Data) -> [String: Any] {
        query.merging([
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]) { $1 }
    }

    @discardableResult
    static func save(_ data: Data, service: String, account: String) -> OSStatus {
        let protected = query(.dataProtection, service: service, account: account)
        let status = SecItemUpdate(protected as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        switch status {
        case errSecSuccess:
            removeFileItem(service: service, account: account)
            return status
        case errSecItemNotFound:
            let added = SecItemAdd(addition(protected, data: data) as CFDictionary, nil)
            if added == errSecSuccess { removeFileItem(service: service, account: account) }
            return added
        case errSecMissingEntitlement:
            return saveToFileKeychain(data, service: service, account: account)
        default:
            return status
        }
    }

    /// Delete-then-add: an item is never written into one another process created.
    private static func saveToFileKeychain(_ data: Data, service: String, account: String) -> OSStatus {
        let file = query(.file, service: service, account: account)
        let removed = SecItemDelete(file as CFDictionary)
        guard removed == errSecSuccess || removed == errSecItemNotFound else { return removed }
        return SecItemAdd(addition(file, data: data) as CFDictionary, nil)
    }

    static func read(service: String, account: String) -> Data? {
        switch copyData(.dataProtection, service: service, account: account) {
        case .found(let data):
            return data
        case .unavailable:
            if case .found(let data) = copyData(.file, service: service, account: account) { return data }
            return nil
        case .missing:
            // An item an older build saved in the file keychain moves to the
            // data protection keychain the first time it is read.
            // Best effort: if the move fails the value is still returned and the move retried next time.
            guard case .found(let data) = copyData(.file, service: service, account: account) else { return nil }
            _ = save(data, service: service, account: account)
            return data
        }
    }

    private enum Lookup { case found(Data), missing, unavailable }

    private static func copyData(_ store: Store, service: String, account: String) -> Lookup {
        var query = query(store, service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecMissingEntitlement { return .unavailable }
        guard status == errSecSuccess, let data = result as? Data else { return .missing }
        return .found(data)
    }

    private static func removeFileItem(service: String, account: String) {
        SecItemDelete(query(.file, service: service, account: account) as CFDictionary)
    }

    static func delete(service: String, account: String) {
        SecItemDelete(query(.dataProtection, service: service, account: account) as CFDictionary)
        removeFileItem(service: service, account: account)
    }

    static func accounts(service: String) -> [String] {
        var names: [String] = []
        for store in [Store.dataProtection, .file] {
            var query = query(store, service: service)
            query[kSecReturnAttributes as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitAll
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                  let items = result as? [[String: Any]] else { continue }
            for name in items.compactMap({ $0[kSecAttrAccount as String] as? String }) where !names.contains(name) {
                names.append(name)
            }
        }
        return names
    }
}
