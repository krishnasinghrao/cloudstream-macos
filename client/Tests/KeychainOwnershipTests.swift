import Foundation
import Security
import XCTest
@testable import CloudStream

/// Security audit L5 against the real keychain: an item another process
/// pre-created (and whose access control it therefore owns) is never written
/// into. The app's save replaces it with an item this process creates.
final class KeychainOwnershipTests: XCTestCase {
    private let service = "com.lagradost.CloudStreamMac.tests.l5-\(UUID().uuidString)"
    private let account = "provider"

    override func tearDown() {
        GenericPasswordKeychain.delete(service: service, account: account)
        super.tearDown()
    }

    private func fileItemAttributes() -> [String: Any]? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnAttributes as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? [String: Any]
    }

    func testAPreCreatedItemIsReplacedNotWrittenInto() throws {
        // The "other app": a file-keychain item with its own label, created first.
        let planted: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                      kSecAttrAccount as String: account, kSecAttrLabel as String: "planted",
                                      kSecValueData as String: Data("old".utf8)]
        XCTAssertEqual(SecItemAdd(planted as CFDictionary, nil), errSecSuccess, "test precondition: the planted item exists")
        XCTAssertEqual(fileItemAttributes()?[kSecAttrLabel as String] as? String, "planted")

        XCTAssertEqual(GenericPasswordKeychain.save(Data("new".utf8), service: service, account: account), errSecSuccess)

        XCTAssertEqual(GenericPasswordKeychain.read(service: service, account: account), Data("new".utf8))
        // Whichever keychain now holds the value, the planted item is gone: it
        // was deleted (and the value re-added by this process), not updated.
        if let attributes = fileItemAttributes() {
            XCTAssertNotEqual(attributes[kSecAttrLabel as String] as? String, "planted", "the planted item was written into")
        }
        XCTAssertEqual(GenericPasswordKeychain.accounts(service: service), [account])
    }
}
