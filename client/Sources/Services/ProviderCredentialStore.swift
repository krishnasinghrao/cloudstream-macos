import Foundation
import Security
import Synchronization

/// Provider credentials (e.g. account tokens for providers that support them)
/// live only in the login Keychain, keyed by stable provider ID. The engine
/// receives them in memory after each start and never writes them to disk.
enum ProviderCredentialStore {
    private static let isolatedCredentials = Mutex<[String: String]>([:])
    private static let service = "com.lagradost.cloudstream.provider-credentials"
    /// Tests only: observes each credential read (audit M8 checks the thread).
    static let readObserver = Mutex<(@Sendable () -> Void)?>(nil)

    static func save(_ credential: String, for providerId: String) throws {
        if AppEnvironment.isIsolated() {
            isolatedCredentials.withLock { $0[providerId] = credential }
            return
        }
        let status = GenericPasswordKeychain.save(Data(credential.utf8), service: service, account: providerId)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    static func credential(for providerId: String) -> String? {
        readObserver.withLock { $0 }?()
        if AppEnvironment.isIsolated() { return isolatedCredentials.withLock { $0[providerId] } }
        guard let data = GenericPasswordKeychain.read(service: service, account: providerId) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(for providerId: String) {
        if AppEnvironment.isIsolated() {
            isolatedCredentials.withLock { $0[providerId] = nil }
            return
        }
        GenericPasswordKeychain.delete(service: service, account: providerId)
    }

    /// Provider IDs that have a stored credential.
    static func storedProviderIds() -> [String] {
        readObserver.withLock { $0 }?()
        if AppEnvironment.isIsolated() { return isolatedCredentials.withLock { Array($0.keys).sorted() } }
        return GenericPasswordKeychain.accounts(service: service)
    }

    /// Re-applies stored credentials to a freshly started engine. Providers
    /// that are not installed (yet) are skipped and retried next start.
    @discardableResult
    static func resendAll(availableProviderIds: Set<String>? = nil) async -> [String: String] {
        var failures: [String: String] = [:]
        // Keychain reads can block (a locked keychain, an access prompt):
        // they never run on the caller's actor, which is the main one (audit M8).
        let stored = await Task.detached(priority: .utility) { storedProviderIds().sorted() }.value
        for providerId in stored {
            guard !Task.isCancelled else { break }
            guard availableProviderIds.map({ $0.contains(providerId) }) ?? true else { continue }
            guard let credential = await Task.detached(priority: .utility, operation: { credential(for: providerId) }).value else { continue }
            do {
                let result = try await DaemonClient.shared.configureProvider(
                    PluginConfigRequestDto(providerId: providerId, credentials: .set(credential)))
                if !result.accepted { failures[providerId] = result.detail ?? "The provider did not accept its credentials." }
            } catch {
                guard !Task.isCancelled else { break }
                failures[providerId] = error.localizedDescription
            }
        }
        return failures
    }

    struct KeychainError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
        }
    }
}
