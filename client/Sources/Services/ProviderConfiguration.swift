import Foundation

/// Applies provider settings so the Keychain and the engine end up agreeing.
///
/// Setting a credential keeps the previous Keychain value until the engine
/// accepts the new one, and restores it otherwise. Clearing removes the
/// Keychain value first and never restores it: if the running engine cannot
/// drop the old secret, the engine is restarted, because credentials exist
/// there in memory only.
@MainActor
enum ProviderConfiguration {
    struct Outcome: Equatable {
        /// Both stores hold the requested state.
        let succeeded: Bool
        let retryable: Bool
        let message: String
    }

    struct Store {
        var read: (String) -> String?
        var save: (String, String) throws -> Void
        var delete: (String) -> Void

        static var keychain: Store {
            Store(read: ProviderCredentialStore.credential(for:),
                  save: { try ProviderCredentialStore.save($0, for: $1) },
                  delete: ProviderCredentialStore.delete(for:))
        }
    }

    static func apply(
        providerId: String,
        url: ProviderSettingPatch = .unchanged,
        credential: ProviderSettingPatch = .unchanged,
        reset: Bool = false,
        store: Store = .keychain,
        engine: ((PluginConfigRequestDto) async throws -> PluginConfigResponseDto)? = nil,
        revokeLiveCredentials: (() -> Void)? = nil,
    ) async -> Outcome {
        let engine = engine ?? { try await DaemonClient.shared.configureProvider($0) }
        let revokeLiveCredentials = revokeLiveCredentials ?? { DaemonSupervisor.shared.restart() }
        let previous = store.read(providerId)
        let clearsSecret = reset || credential == .clear
        if clearsSecret {
            store.delete(providerId)
        } else if case .set(let value) = credential {
            do { try store.save(value, providerId) }
            catch { return Outcome(succeeded: false, retryable: true, message: "Couldn't save to the Keychain: \(error.localizedDescription)") }
        }
        func restoreKeychain() {
            guard case .set = credential else { return }
            if let previous { try? store.save(previous, providerId) } else { store.delete(providerId) }
        }
        do {
            let result = try await engine(PluginConfigRequestDto(providerId: providerId, url: url, credentials: credential, reset: reset))
            guard result.accepted else {
                restoreKeychain()
                if clearsSecret, previous != nil { revokeLiveCredentials() }
                return Outcome(succeeded: false, retryable: result.retryable == true, message: result.detail ?? "The provider did not accept these settings.")
            }
            if let detail = result.detail { return Outcome(succeeded: true, retryable: false, message: detail) }
            return Outcome(succeeded: true, retryable: false,
                           message: reset ? "Defaults restored." : "Saved. Now using \(result.mainUrl).")
        } catch {
            restoreKeychain()
            let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if clearsSecret, previous != nil {
                // The secret is gone from the Keychain; make the engine forget it too.
                revokeLiveCredentials()
                return Outcome(succeeded: false, retryable: true,
                               message: "Removed from the Keychain, but the engine couldn't be updated (\(detail)). The engine is restarting to remove the old credential.")
            }
            return Outcome(succeeded: false, retryable: true, message: "Nothing was changed: \(detail)")
        }
    }
}
