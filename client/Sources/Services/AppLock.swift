import AppKit
import LocalAuthentication

/// Touch ID / password lock (Offline-Features-Plan Phase 7.3). Uses the
/// system owner-authentication policy: Touch ID when available, otherwise
/// the Mac account password. Nothing secret is stored by the app.
@MainActor
@Observable
final class AppLock {
    static let shared = AppLock()

    private(set) var isLocked = false
    /// Lock/unlock while an operation waits cannot restore its authorization.
    private(set) var generation: UInt64 = 0
    private(set) var lastError: String?

    @ObservationIgnored private var resignedActiveAt: Date?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var isAuthenticating = false

    /// Test seam: replaces LocalAuthentication.
    @ObservationIgnored var authenticator: (String) async -> Result<Void, Error> = AppLock.systemAuthenticate

    /// Whether a lock applies right now (global setting or locked profile).
    var isLockEnabled: Bool {
        UserPreferences.shared.requireUnlock || ProfileStore.shared.active.requiresUnlock
    }

    static var biometryName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return context.biometryType == .touchID ? "Touch ID" : "your password"
    }

    func start() {
        guard observers.isEmpty else { return }
        if isLockEnabled {
            isLocked = true
            Task { await self.syncDaemonLockState() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lockIfEnabled(reason: "screen_sleep") }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lockIfEnabled(reason: "session_switch") }
        })
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resignedActiveAt = Date() }
        })
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIdleTimeout() }
        })
    }

    private func checkIdleTimeout(now: Date = Date()) {
        defer { resignedActiveAt = nil }
        let minutes = UserPreferences.shared.lockAfterMinutes
        guard minutes > 0, let away = resignedActiveAt, now.timeIntervalSince(away) >= Double(minutes * 60) else { return }
        lockIfEnabled(reason: "idle")
    }

    func lockIfEnabled(reason: String) {
        guard isLockEnabled, !isLocked else { return }
        isLocked = true
        generation &+= 1
        EpisodeUpdateChecker.shared.cancelCurrentRun()
        LibraryStore.shared.cancelProfileOperations()
        // Nothing keeps playing (or showing) behind the lock screen.
        AppState.shared.player.close()
        DaemonLog.client("lock.locked", fields: ["reason": reason])
        Task { await self.syncDaemonLockState() }
    }

    func unlock() async {
        guard isLocked, !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }
        switch await authenticator("unlock CloudStream") {
        case .success:
            isLocked = false
            lastError = nil
            await syncDaemonLockState()
        case .failure(let error):
            lastError = (error as? LAError)?.code == .userCancel ? nil : error.localizedDescription
        }
    }

    // MARK: - Daemon synchronization (SEC-08)

    @ObservationIgnored private var daemonSync: Task<Bool, Never>?

    /// Sends the lock state current at send time, one request after another,
    /// so a late lock request can never land after the unlock that followed it.
    @discardableResult
    func syncDaemonLockState() async -> Bool {
        let previous = daemonSync
        let sync = Task { @MainActor in
            _ = await previous?.value
            for attempt in 1...3 {
                do {
                    _ = try await DaemonClient.shared.setAppLock(locked: isLocked)
                    return true
                } catch {
                    DaemonLog.client("lock.sync_failed", fields: ["error": error.localizedDescription, "attempt": String(attempt)])
                    if attempt < 3 { try? await Task.sleep(for: .milliseconds(500)) }
                }
            }
            return false
        }
        daemonSync = sync
        return await sync.value
    }

    /// Switching into a locked profile or leaving a locked profile asks for authentication first.
    func switchProfile(to profile: ViewerProfile) async -> Bool {
        let active = ProfileStore.shared.active
        if (profile.requiresUnlock || active.requiresUnlock), profile.id != active.id {
            let reason = profile.requiresUnlock ? "switch to \(profile.name)" : "leave \(active.name)"
            guard case .success = await authenticator(reason) else { return false }
        }
        do {
            EpisodeUpdateChecker.shared.cancelCurrentRun()
            LibraryStore.shared.cancelProfileOperations()
            AppState.shared.player.close()
            WindowSessionRegistry.shared.invalidateProfileNavigation()
            let providers = AppState.shared.isEngineReady
                ? LibraryIdentityMigration.catalog(plugins: AppState.shared.providers) : []
            try ProfileStore.shared.select(profile, identityProviders: providers)
            return true
        } catch {
            AppState.shared.presentError("Couldn't open \(profile.name): \(error.localizedDescription)")
            return false
        }
    }

    /// Confirms the user can authenticate before a lock is turned on, so a
    /// lock can never be enabled on a Mac without a usable owner check.
    func verifyCanEnable() async -> Bool {
        if case .success = await authenticator("turn on the lock") { return true }
        return false
    }

    nonisolated static func systemAuthenticate(_ reason: String) async -> Result<Void, Error> {
        let context = LAContext()
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            return .failure(policyError ?? LAError(.passcodeNotSet))
        }
        do {
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            return .success(())
        } catch {
            return .failure(error)
        }
    }
}
