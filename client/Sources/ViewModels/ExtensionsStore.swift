import Foundation
import UserNotifications
import Observation

protocol ExtensionsAPI: Sendable {
    func repos() async throws -> [RepositoryDto]
    func plugins() async throws -> [PluginDto]
    func repoPlugins(_ repoUrl: String) async throws -> [RepoPluginDto]
    func syncRepo(_ repoUrl: String, installAll: Bool) async throws -> RepositoryDto
    func removeRepo(_ repoUrl: String, deleteDownloadedPlugins: Bool) async throws
    func installPlugin(repoUrl: String, internalName: String, pluginUrl: String, fileHash: String?) async throws -> PluginDto
    func uninstallPlugin(_ installationId: String) async throws
    func setPluginEnabled(_ installationId: String, enabled: Bool) async throws -> PluginDto
    func updatePlugin(_ installationId: String) async throws -> PluginDto
    func updateAllPlugins(repoUrl: String?) async throws -> [UpdateResultDto]
    func rollbackPlugin(_ installationId: String) async throws -> PluginDto
    func retryPlugin(_ installationId: String) async throws -> PluginDto
    func setRepositoryConsent(_ repoUrl: String, allow: Bool) async throws -> RepositoryDto
    func reTrustRepository(_ repoUrl: String) async throws -> RepositoryDto
    func extensionSettings() async throws -> ExtensionSettingsDto
    func setAutoUpdate(_ enabled: Bool) async throws -> ExtensionSettingsDto
    func setDeveloperMode(_ enabled: Bool) async throws -> ExtensionSettingsDto
    func installExtensionFile(path: String) async throws -> PluginDto
    func dismissLegacyExtensions() async throws -> ExtensionSettingsDto
    /// Runs home → search → details → links for these providers (RT-16 diagnostic).
    func testProviders(_ providerIds: [String]) async throws -> [ProviderTestResultDto]
}

extension DaemonClient: ExtensionsAPI {
    func testProviders(_ providerIds: [String]) async throws -> [ProviderTestResultDto] {
        var results: [ProviderTestResultDto] = []
        for try await event in providerTestStream(providers: providerIds) {
            if let result = event.result { results.append(result) }
        }
        return results
    }
}

/// The daemon owns repositories and installations; this store holds their last
/// successful projection. Mutations are keyed per target (installation or
/// repository): different rows may operate concurrently, the same row may not,
/// and the daemon serializes per installation. After any mutation the store
/// re-reads daemon state instead of inferring success from a response.
@MainActor @Observable
final class ExtensionsStore {
    private(set) var repositories: [RepositoryDto] = []
    private(set) var plugins: [PluginDto] = []
    private(set) var settings = ExtensionSettingsDto()
    private(set) var isRefreshing = false
    private(set) var isAddingRepository = false
    /// Activity label per target key (installation ID, catalog ID or repository URL).
    private(set) var pluginActivities: [String: String] = [:]
    private(set) var repositoryActivities: [String: String] = [:]
    private(set) var pendingEnabled: [String: Bool] = [:]
    private(set) var catalogRevision: UInt64 = 0
    private(set) var lastUpdateResults: [UpdateResultDto] = []
    var operationError: String?
    var refreshError: String?

    @ObservationIgnored private let api: any ExtensionsAPI
    @ObservationIgnored private var epoch: UInt64 = 0
    @ObservationIgnored private var refreshGeneration: UInt64 = 0
    @ObservationIgnored private var inFlight: Set<String> = []
    /// Advances when the installed extensions change in a way that can change
    /// what a provider returns: version or artifact replacement, enable state,
    /// removal, or its site address. Client caches key their entries by it.
    private(set) var providerGeneration: UInt64 = 0
    @ObservationIgnored private var providerFingerprint: [String] = []
    /// Called after `plugins` holds a changed provider set.
    @ObservationIgnored var onProvidersChanged: (@MainActor () -> Void)?

    /// Posts the automatic-update summary; replaceable in tests.
    @ObservationIgnored var notifyAutoUpdates: @MainActor ([String]) -> Void = ExtensionsStore.postAutoUpdateNotification
    @ObservationIgnored private let defaults: UserDefaults

    init(api: any ExtensionsAPI = DaemonClient.shared, defaults: UserDefaults = AppEnvironment.defaults) {
        self.api = api
        self.defaults = defaults
    }

    var pendingUpdates: [PluginDto] { plugins.filter { $0.updateAvailable == true } }

    func isBusy(_ key: String) -> Bool { inFlight.contains(key) }

    /// Invalidate all responses from a previous daemon, including mutation
    /// completions. Preserve the visible snapshot while the engine reconnects.
    func engineChanged() {
        epoch &+= 1
        refreshGeneration &+= 1
        inFlight.removeAll()
        isRefreshing = false
        clearActivities()
        catalogRevision &+= 1
    }

    @discardableResult
    func refresh() async -> Bool {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let engine = epoch
        isRefreshing = true
        defer { if generation == refreshGeneration { isRefreshing = false } }

        async let repositoryRequest = api.repos()
        async let pluginRequest = api.plugins()
        async let settingsRequest = api.extensionSettings()
        var errors: [String] = []
        var repos: [RepositoryDto]?
        var installed: [PluginDto]?
        var loadedSettings: ExtensionSettingsDto?
        do { repos = try await repositoryRequest } catch { errors.append(error.localizedDescription) }
        do { installed = try await pluginRequest } catch { errors.append(error.localizedDescription) }
        loadedSettings = try? await settingsRequest
        guard !Task.isCancelled, generation == refreshGeneration, engine == epoch else { return false }
        if let repos { repositories = repos }
        if let installed {
            let fingerprint = installed.map {
                "\($0.id)|\($0.version)|\($0.sha256 ?? "")|\($0.enabled)|\($0.mainUrl ?? "")|\(($0.providerIds ?? $0.providers).joined(separator: ","))"
            }.sorted()
            let changed = fingerprint != providerFingerprint
            if changed {
                providerFingerprint = fingerprint
                providerGeneration &+= 1
            }
            plugins = installed
            if changed { onProvidersChanged?() }
        }
        if let loadedSettings {
            settings = loadedSettings
            announceBackgroundUpdates(loadedSettings.lastBackgroundRefresh)
        }
        refreshError = errors.isEmpty ? nil : "Couldn't refresh saved extensions: " + errors.joined(separator: "; ")
        return errors.isEmpty
    }

    // MARK: - Repositories

    @discardableResult
    func addRepository(_ url: String) async -> Bool {
        await perform(key: "add:\(url)", activity: "Adding…", repository: url, adding: true) {
            _ = try await self.api.syncRepo(url, installAll: false)
        }
    }

    func syncRepository(_ repo: RepositoryDto) async {
        await perform(key: "repo:\(repo.url)", activity: "Syncing…", repository: repo.url) {
            _ = try await self.api.syncRepo(repo.url, installAll: false)
        }
    }

    /// Syncs every top-level repository (discovered child repositories refresh
    /// through their parent). The engine records each failure on its repository;
    /// the ones that failed are also named in one message here.
    func syncAll() async {
        let targets = repositories.filter { $0.discoveredVia == nil }
        await perform(key: "sync-all", activity: "Syncing…", activityKey: "sync-all") {
            var failed: [String] = []
            for repo in targets where !(await self.syncPaced(repo.url)) {
                failed.append(repo.name.isEmpty ? repo.url : repo.name)
            }
            if !failed.isEmpty { throw SyncAllFailure(repositories: failed) }
        }
    }

    /// The engine admits a few syncs at once and then one every two seconds;
    /// a refused sync waits its turn instead of being skipped.
    private func syncPaced(_ url: String) async -> Bool {
        for attempt in 0..<Self.syncAttempts {
            do {
                _ = try await api.syncRepo(url, installAll: false)
                return true
            } catch let error as DaemonClient.DaemonError where error.code == "rate_limited" && attempt + 1 < Self.syncAttempts {
                try? await Task.sleep(for: .seconds(2.5))
            } catch {
                return false
            }
        }
        return false
    }

    private static let syncAttempts = 4

    private struct SyncAllFailure: LocalizedError {
        let repositories: [String]
        var errorDescription: String? {
            "Couldn't sync " + repositories.joined(separator: ", ") + ". Each repository shows its own error."
        }
    }

    func removeRepository(_ repo: RepositoryDto, removeExtensions: Bool = true) async {
        await perform(key: "repo:\(repo.url)", activity: "Removing…", repository: repo.url) {
            try await self.api.removeRepo(repo.url, deleteDownloadedPlugins: removeExtensions)
        }
    }

    /// Community repositories need explicit consent before installation.
    func setConsent(_ allow: Bool, for repo: RepositoryDto) async {
        await perform(key: "repo:\(repo.url)", activity: allow ? "Allowing…" : "Revoking…", repository: repo.url) {
            _ = try await self.api.setRepositoryConsent(repo.url, allow: allow)
        }
    }

    /// Accepts a changed signing key after the user compared fingerprints.
    func reTrust(_ repo: RepositoryDto) async {
        await perform(key: "repo:\(repo.url)", activity: "Verifying new key…", repository: repo.url) {
            _ = try await self.api.reTrustRepository(repo.url)
        }
    }

    // MARK: - Installations

    func install(_ plugin: RepoPluginDto) async {
        guard plugin.installationAllowed == true else {
            operationError = plugin.installationBlockedReason ?? "Sync this repository to verify that installation is allowed."
            return
        }
        await perform(key: plugin.installationId ?? plugin.catalogID, activity: plugin.isInstalled ? "Updating…" : "Installing…",
                      activityKey: plugin.catalogID) {
            _ = try await self.api.installPlugin(repoUrl: plugin.repositoryUrl, internalName: plugin.internalName,
                                                 pluginUrl: plugin.url, fileHash: plugin.fileHash)
        }
    }

    func update(_ plugin: PluginDto) async {
        await perform(key: plugin.id, activity: "Updating…") { _ = try await self.api.updatePlugin(plugin.id) }
    }

    /// User-requested diagnostic (RT-16): runs every stage for this extension's providers. Each stage's
    /// outcome is recorded by the engine and shown on the row; failures are summarized here too.
    func diagnose(_ plugin: PluginDto) async {
        let ids = plugin.providerIds ?? []
        guard !ids.isEmpty else { return }
        await perform(key: plugin.id, activity: "Testing…") {
            let results = try await self.api.testProviders(ids)
            let failed = results.filter { $0.status != "pass" }.map { result in
                let steps = result.steps.filter { !$0.ok }.map { step in step.detail.map { "\(step.name): \($0)" } ?? step.name }
                return "\(result.provider) — \(steps.joined(separator: "; "))"
            }
            if !failed.isEmpty { self.operationError = "Test found problems: " + failed.joined(separator: " · ") }
        }
    }

    /// Downloads a hashless extension again; the engine keeps the installed version when the file is unchanged.
    func recheck(_ plugin: PluginDto) async {
        await perform(key: plugin.id, activity: "Checking for changes…") { _ = try await self.api.updatePlugin(plugin.id) }
    }

    /// One notification per engine refresh that updated extensions automatically.
    private func announceBackgroundUpdates(_ refresh: BackgroundRefreshDto?) {
        let key = "extensions.lastAnnouncedBackgroundRefresh"
        guard let refresh, refresh.at > Int64(defaults.integer(forKey: key)) else { return }
        defaults.set(Int(refresh.at), forKey: key)
        if !refresh.updated.isEmpty { notifyAutoUpdates(refresh.updated) }
    }

    static func postAutoUpdateNotification(_ names: [String]) {
        let content = UNMutableNotificationContent()
        content.title = names.count == 1 ? "Extension updated" : "\(names.count) extensions updated"
        content.body = names.count <= 3 ? ListFormatter.localizedString(byJoining: names)
            : ListFormatter.localizedString(byJoining: Array(names.prefix(3))) + " and \(names.count - 3) more"
        let request = UNNotificationRequest(identifier: "extensions.auto-update", content: content, trigger: nil)
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert])) == true else { return }
            try? await center.add(request)
        }
    }

    func updateAll() async {
        await perform(key: "update-all", activity: "Updating…", activityKey: "update-all") {
            let results = try await self.api.updateAllPlugins(repoUrl: nil)
            self.lastUpdateResults = results
            let failed = results.filter { $0.error != nil }
            if !failed.isEmpty {
                self.operationError = failed.map { "\($0.name): \($0.error ?? "failed")" }.joined(separator: "\n")
            }
        }
    }

    func rollback(_ plugin: PluginDto) async {
        await perform(key: plugin.id, activity: "Restoring previous version…") { _ = try await self.api.rollbackPlugin(plugin.id) }
    }

    func retry(_ plugin: PluginDto) async {
        await perform(key: plugin.id, activity: "Starting…") {
            let result = try await self.api.retryPlugin(plugin.id)
            if !result.isOperational, let error = result.lastError { self.operationError = error }
        }
    }

    func uninstall(_ plugin: PluginDto) async {
        await perform(key: plugin.id, activity: "Uninstalling…") { try await self.api.uninstallPlugin(plugin.id) }
    }

    func setEnabled(_ enabled: Bool, plugin: PluginDto) async {
        pendingEnabled[plugin.id] = enabled
        defer { pendingEnabled[plugin.id] = nil }
        await perform(key: plugin.id, activity: enabled ? "Enabling…" : "Disabling…") {
            let result = try await self.api.setPluginEnabled(plugin.id, enabled: enabled)
            if enabled, !result.isOperational, let error = result.lastError { self.operationError = error }
        }
    }

    // MARK: - Settings

    func setAutoUpdate(_ enabled: Bool) async {
        await perform(key: "settings", activity: "Saving…", activityKey: "settings") {
            self.settings = try await self.api.setAutoUpdate(enabled)
        }
    }

    func setDeveloperMode(_ enabled: Bool) async {
        await perform(key: "settings", activity: "Saving…", activityKey: "settings") {
            self.settings = try await self.api.setDeveloperMode(enabled)
        }
    }

    /// Imports a local extension file; it stays disabled until the user enables it.
    func installExtensionFile(_ url: URL) async {
        await perform(key: "developer-install", activity: "Installing…", activityKey: "developer-install") {
            _ = try await self.api.installExtensionFile(path: url.path)
        }
    }

    func dismissLegacyExtensions() async {
        await perform(key: "settings", activity: "Saving…", activityKey: "settings") {
            self.settings = try await self.api.dismissLegacyExtensions()
        }
    }

    // MARK: - Operation plumbing

    @discardableResult
    private func perform(key: String, activity: String, repository: String? = nil, activityKey: String? = nil,
                         adding: Bool = false, action: () async throws -> Void) async -> Bool {
        guard !inFlight.contains(key) else {
            operationError = "That item is still being updated. Try again when it finishes."
            return false
        }
        let engine = epoch
        inFlight.insert(key)
        refreshGeneration &+= 1 // discard any pre-mutation read still in flight
        isRefreshing = false
        operationError = nil
        if adding { isAddingRepository = true }
        if let repository { repositoryActivities[repository] = activity } else { pluginActivities[activityKey ?? key] = activity }
        defer {
            if engine == epoch {
                inFlight.remove(key)
                if adding { isAddingRepository = false }
                if let repository { repositoryActivities[repository] = nil } else { pluginActivities[activityKey ?? key] = nil }
            }
        }
        var succeeded = false
        do { try await action(); succeeded = true }
        catch {
            if engine == epoch { operationError = Self.message(for: error) }
        }
        guard engine == epoch, !Task.isCancelled else { return false }
        catalogRevision &+= 1
        // Even an unsuccessful HTTP response may follow a server-side commit.
        // Read the daemon's state; never infer success or undo from a timeout.
        await refresh()
        return succeeded
    }

    static func message(for error: Error) -> String {
        if let daemon = error as? DaemonClient.DaemonError, let code = daemon.code {
            switch code {
            case "consent_required": return "Allow installs from this community repository first."
            case "operation_conflict": return "\(daemon.localizedDescription) Try again."
            default: return daemon.localizedDescription
            }
        }
        return "\(error.localizedDescription) The saved state will be refreshed to check the result."
    }

    private func clearActivities() {
        isAddingRepository = false
        pluginActivities = [:]
        repositoryActivities = [:]
        pendingEnabled = [:]
    }
}

@MainActor @Observable
final class RepositoryCatalogStore {
    private(set) var plugins: [RepoPluginDto] = []
    private(set) var isLoading = false
    private(set) var error: String?
    @ObservationIgnored private let api: any ExtensionsAPI
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var repositoryURL: String?

    /// Posts the automatic-update summary; replaceable in tests.
    @ObservationIgnored var notifyAutoUpdates: @MainActor ([String]) -> Void = ExtensionsStore.postAutoUpdateNotification
    @ObservationIgnored private let defaults: UserDefaults

    init(api: any ExtensionsAPI = DaemonClient.shared, defaults: UserDefaults = AppEnvironment.defaults) {
        self.api = api
        self.defaults = defaults
    }

    func load(repoURL: String) async {
        generation &+= 1
        let request = generation
        if repositoryURL != repoURL { plugins = []; repositoryURL = repoURL }
        isLoading = true
        error = nil
        defer { if generation == request { isLoading = false } }
        do {
            let result = try await api.repoPlugins(repoURL)
            guard !Task.isCancelled, request == generation else { return }
            plugins = result
        } catch {
            guard !Task.isCancelled, request == generation else { return }
            self.error = error.localizedDescription
        }
    }
}
