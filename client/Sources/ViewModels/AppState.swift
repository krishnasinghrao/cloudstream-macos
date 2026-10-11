import SwiftUI

/// Root navigation destinations (native macOS sidebar). Settings lives in the
/// standard `Settings` scene (⌘,), not the sidebar.
enum AppDestination: Hashable {
    case home
    case search
    case watching
    case planToWatch
    case completed
    case favorites
    case onHold
    case dropped
    case downloaded
    case history
    case extensions
    /// One of the user's library pages (ADR-0021), by ID.
    case page(String)

    /// The Library collection this destination shows, if any.
    var libraryCollection: LibraryCollection? {
        switch self {
        case .watching: .watching
        case .planToWatch: .planToWatch
        case .completed: .completed
        case .onHold: .onHold
        case .dropped: .dropped
        case .favorites: .favorites
        case .home, .search, .downloaded, .history, .extensions, .page: nil
        }
    }

    /// The screen's title. Pages are named by the user; see LibraryPageView.
    var title: String {
        switch self {
        case .home: "Home"
        case .search: "Search"
        case .watching: "Watching"
        case .planToWatch: "Plan to Watch"
        case .favorites: "Favorites"
        case .completed: "Completed"
        case .onHold: "On Hold"
        case .dropped: "Dropped"
        case .downloaded: "Downloads"
        case .history: "History"
        case .extensions: "Extensions"
        case .page: "Page"
        }
    }

    /// Screens whose titles the window's search field filters instead of searching providers.
    var filtersLibrary: Bool {
        if case .page = self { return true }
        return libraryCollection != nil
    }
}

/// Details are pushed onto the NavigationStack; coordinates let us push before
/// the network call resolves and swap in the loaded DTO.
enum DetailCoordinate: Hashable {
    case result(SearchResultDto)
    case libraryItem(id: String, provider: String, providerID: String? = nil, url: String)

    var provider: String {
        switch self {
        case .result(let result): return result.provider
        case .libraryItem(_, let provider, _, _): return provider
        }
    }

    /// Unambiguous provider reference for the details request.
    var requestProvider: String {
        switch self {
        case .result(let result): return result.providerKey
        case .libraryItem(_, let provider, let providerID, _): return providerID ?? provider
        }
    }

    var url: String {
        switch self {
        case .result(let result): return result.url
        case .libraryItem(_, _, _, let url): return url
        }
    }
}

/// Application-scoped services, connection health, caches and player session.
/// Main-window navigation and searches are owned by WindowSession.
@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    var windowSession: WindowSession { WindowSessionRegistry.shared.routedSession }
    @ObservationIgnored private var detailsCache = DetailsCache()
    /// Advanced by provider setting changes made in this app (address,
    /// credentials, per-provider enable state).
    @ObservationIgnored private var providerSettingsGeneration: UInt64 = 0
    private var detailsGeneration: DetailsCache.Generation {
        .init(engine: connection.generation, extensions: extensions.providerGeneration, settings: providerSettingsGeneration)
    }

    /// Hashable form of the current provider-data generation for other caches.
    var providerDataGeneration: [UInt64] { [connection.generation, extensions.providerGeneration, providerSettingsGeneration] }

    /// A provider's address, credentials or enable state changed: details
    /// loaded before the change are no longer authoritative.
    func providerSettingsChanged() { providerSettingsGeneration &+= 1 }

    /// True when the details shown for `coordinate` come from an earlier
    /// engine/provider configuration or are older than the freshness window.
    func detailsAreStale(for coordinate: DetailCoordinate) -> Bool {
        detailsCache.isStale(coordinate, generation: detailsGeneration)
    }
    func navigateTo(_ destination: AppDestination) { windowSession.navigateTo(destination) }
    func perform(_ route: DeepLinkRoute) { windowSession.perform(route) }

    // Engine
    private(set) var connection = EngineConnection() {
        didSet {
            connectionSubscribers.values.forEach { $0.yield(connection) }
            SmokeStatus.publish(connection)
        }
    }
    @ObservationIgnored private var connectionSubscribers: [UUID: AsyncStream<EngineConnection>.Continuation] = [:]

    func waitForUsableEngine() async throws {
        let id = UUID()
        let changes = AsyncStream<EngineConnection>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            connectionSubscribers[id] = continuation
            continuation.yield(connection)
        }
        defer { connectionSubscribers.removeValue(forKey: id) }
        try await EngineConnection.awaitUsable(in: changes)
    }
    var daemonState: DaemonState { connection.daemonState }
    var daemonVersion: String?
    private(set) var engineRecoveryError: String?
    private(set) var credentialRestoreErrors: [String: String] = [:]
    let extensions = ExtensionsStore()
    var providers: [PluginDto] { extensions.plugins }
    var repositories: [RepositoryDto] { extensions.repositories }
    private var engineGeneration: UInt64 { connection.generation }

    // Player
    let player = PlayerViewModel()
    let preferences = UserPreferences.shared

    /// Last /health snapshot (extension restore progress, safe mode, policy).
    var engineHealth: HealthDto? { connection.health }
    private var healthWatchTask: Task<Void, Never>?
    /// Read-only extensions refresh so engine-side background results (updates,
    /// revocations) reach the UI and notifications without user action.
    private var extensionsPollTask: Task<Void, Never>?
    #if DEBUG
    private var uiTestExtensionImported = false
    #endif

    private var bootstrapTask: Task<Void, Never>?
    private var observingEngine = false
    private var connectionTask: Task<Void, Never>?
    private var verificationTask: Task<Void, Never>?
    private var solvePollTask: Task<Void, Never>?
    private var mediaPollTask: Task<Void, Never>?
    private var webViewPollTask: Task<Void, Never>?

    private init() {
        // Bootstrap reconciles once per engine; later installs, removals and
        // enable changes reach the library through this.
        extensions.onProvidersChanged = { [weak self] in
            guard let self, self.isEngineBootstrapped, LibraryStore.shared.profileStoreHealth == .available else { return }
            self.reconcileLibraryIdentities()
        }
    }

    var isEngineReady: Bool { connection.isReady }
    var isEngineBootstrapped: Bool { connection.isUsable }

    /// Application-scoped, idempotent observation. Streams are independent
    /// replayable subscriptions, never reconsumed by a replacement window.
    func observeEngine() {
        guard !observingEngine else { return }
        observingEngine = true
        connection.invalidate(DaemonSupervisor.shared.state)
        connectionTask = Task { [weak self] in
            guard let self else { return }
            for await snapshot in DaemonSupervisor.shared.connectionChanges {
                guard !Task.isCancelled else { return }
                guard snapshot == DaemonSupervisor.shared.connectionSnapshot else { continue }
                if case .ready = snapshot.state, let endpoint = snapshot.endpoint {
                    guard connection.endpoint != endpoint else { continue }
                    resetEngineWork()
                    connection.beginVerification(endpoint)
                    let generation = engineGeneration
                    engineRecoveryError = nil
                    verificationTask = Task { [weak self] in
                        await self?.verifyConnection(endpoint, generation: generation)
                    }
                } else {
                    resetEngineWork()
                    connection.invalidate(snapshot.state)
                    engineRecoveryError = nil
                }
            }
        }
    }

    private func verifyConnection(_ endpoint: DaemonEndpoint, generation: UInt64) async {
        // Transport ownership belongs to the supervisor. Verification never
        // writes an endpoint from a queued old event into the client actor.
        var health: HealthDto?
        var lastError: Error?
        for attempt in 1...3 {
            guard generation == engineGeneration, !Task.isCancelled else { return }
            do { health = try await DaemonClient.shared.connectAndVerify(); break }
            catch {
                lastError = error
                if attempt < 3 {
                    do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                }
            }
        }
        guard generation == engineGeneration, !Task.isCancelled,
              endpoint == DaemonSupervisor.shared.endpoint else { return }
        if let health {
            guard connection.acceptHealth(health, generation: generation) else {
                engineRecoveryError = health.recoveryError
                if let error = health.recoveryError { presentError(error) }
                return
            }
            daemonVersion = health.version
            // A relayed stream belonged to the previous engine (section 9).
            player.engineReconnected()
            startSolvePolling()
            startWebViewPolling()
            bootstrapTask = Task { [weak self] in await self?.bootstrap() }
        } else if let lastError {
            connection.fail(lastError.localizedDescription, generation: generation)
        }
    }

    private func resetEngineWork() {
        WindowSessionRegistry.shared.cancelAllSearches()
        verificationTask?.cancel()
        bootstrapTask?.cancel()
        credentialRestoreErrors = [:]
        extensions.engineChanged()
        WebViewSolverService.shared.reset()
        MediaResolverService.shared.reset()
        WebViewSessionService.shared.reset()
        solvePollTask?.cancel()
        mediaPollTask?.cancel()
        webViewPollTask?.cancel()
        healthWatchTask?.cancel()
        healthWatchTask = nil
        extensionsPollTask?.cancel()
    }

    func stopApplicationTasks() {
        observingEngine = false
        connectionTask?.cancel(); connectionTask = nil
        resetEngineWork()
        noticeDismissTask?.cancel()
        connection.invalidate(.initializing)
    }

    /// Restarts the engine; `safeMode` starts it without loading extension code.
    func restartEngine(safeMode: Bool) {
        DaemonSupervisor.shared.restart(safeMode: safeMode)
    }

    /// Extensions restore in the background after the engine is reachable.
    /// Poll /health until that finishes, then refresh the installed list once.
    private func watchExtensionRestore(generation: UInt64) {
        guard healthWatchTask == nil else { return }
        healthWatchTask = Task { [weak self] in
            guard let self else { return }
            defer { if generation == engineGeneration { healthWatchTask = nil } }
            let deadline = ContinuousClock.now.advanced(by: .seconds(120))
            while ContinuousClock.now < deadline {
                guard generation == engineGeneration, !Task.isCancelled else { return }
                do {
                    let health = try await DaemonClient.shared.connectAndVerify()
                    guard generation == engineGeneration, !Task.isCancelled else { return }
                    guard connection.acceptHealth(health, generation: generation) else {
                        engineRecoveryError = health.recoveryError
                        return
                    }
                    if connection.providersRestored {
                        await bootstrap()
                        guard generation == engineGeneration, !Task.isCancelled else { return }
                        if isEngineBootstrapped { return }
                    }
                } catch {
                    guard generation == engineGeneration, !Task.isCancelled else { return }
                    // A transient /health failure does not abandon restoration.
                    DaemonLog.client("engine.restore_health_retry", fields: ["error": error.localizedDescription])
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
            guard generation == engineGeneration, !Task.isCancelled else { return }
            connection.fail("Provider restoration did not complete. Restart the engine to retry.", generation: generation)
        }
    }

    #if DEBUG
    /// UI tests only (Debug builds, isolated data root): import a local fixture
    /// extension through developer mode so install/enable/uninstall flows can be
    /// driven without network access. Absent from Release builds.
    private func importUITestExtensionIfRequested() async {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CS_IN_MEMORY_DB"] == "1", let path = environment["CS_UITEST_DEVELOPER_EXTENSION"],
              !uiTestExtensionImported else { return }
        uiTestExtensionImported = true
        await extensions.setDeveloperMode(true)
        await extensions.installExtensionFile(URL(fileURLWithPath: path))
        await extensions.refresh()
    }
    #endif

    /// Matches titles saved before provider identity was recorded against the
    /// installed providers. Runs when an engine becomes usable and whenever
    /// the installed providers change, so a title that only now has exactly
    /// one candidate is bound without waiting for the next launch. Ambiguous
    /// or missing providers stay unresolved for an explicit choice.
    ///
    /// A pass with the same provider catalog and library as the last one can
    /// change nothing, so it is skipped, and the unresolved count is logged
    /// only when it changes (Remediation 4.3).
    func reconcileLibraryIdentities() {
        let catalog = LibraryIdentityMigration.catalog(plugins: providers)
        let fingerprint = IdentityReconcileFingerprint(catalog: catalog, store: LibraryStore.shared)
        guard fingerprint != lastIdentityReconcile else { return }
        do {
            let report = try LibraryStore.shared.migrateProviderIdentities(providers: catalog)
            if report.unresolved.count != lastUnresolvedIdentityCount, !report.unresolved.isEmpty {
                DaemonLog.client("library.identity_unresolved", fields: ["count": "\(report.unresolved.count)"])
            }
            lastUnresolvedIdentityCount = report.unresolved.count
            // Recorded after the pass, whose own changes bump the library version.
            lastIdentityReconcile = IdentityReconcileFingerprint(catalog: catalog, store: LibraryStore.shared)
        } catch {
            presentError("Couldn't update library identities: \(error.localizedDescription)")
        }
    }

    struct IdentityReconcileFingerprint: Equatable {
        let providers: [String]
        let profileGeneration: UInt64
        let libraryVersion: UInt64
        @MainActor init(catalog: [LibraryIdentityMigration.Provider], store: LibraryStore) {
            providers = catalog.map { "\($0.id)\u{1F}\($0.name)" }.sorted()
            profileGeneration = store.profileGeneration
            libraryVersion = store.version
        }
    }
    @ObservationIgnored private var lastIdentityReconcile: IdentityReconcileFingerprint?
    @ObservationIgnored private var legacyImportNotice = OncePerGeneration()
    @ObservationIgnored private var lastUnresolvedIdentityCount = 0

    /// Whether a saved title has no usable provider installation: none was
    /// recorded, or the recorded one is no longer installed. Only answered
    /// from a complete provider list, so a starting engine never makes every
    /// title look orphaned.
    func isProviderMissing(_ providerID: String?) -> Bool {
        guard let providerID, !providerID.isEmpty else { return true }
        guard isEngineBootstrapped, extensions.refreshError == nil else { return false }
        return !providers.contains { $0.providerIds?.contains(providerID) == true }
    }

    /// Refreshes the authoritative saved state without remote repository sync.
    func bootstrap() async {
        guard isEngineReady else { return }
        let generation = engineGeneration
        guard connection.providersRestored else { watchExtensionRestore(generation: generation); return }
        if !preferences.repositoryMigrationComplete {
            do {
                try await DaemonClient.shared.importLegacyRepositories(preferences.repositoryURLs)
                guard generation == engineGeneration, !Task.isCancelled else { return }
                preferences.repositoryMigrationComplete = true
            } catch {
                guard generation == engineGeneration, !Task.isCancelled else { return }
                // Retried on later bootstrap passes, but shown once per engine (audit Q8).
                DaemonLog.client("repositories.legacy_import_failed", fields: ["error": error.localizedDescription])
                if legacyImportNotice.shouldShow(generation: generation) {
                    presentError("Couldn't import saved repositories: \(error.localizedDescription)")
                }
            }
        }
        let refreshed = await extensions.refresh()
        guard generation == engineGeneration, !Task.isCancelled else { return }
        guard refreshed else { watchExtensionRestore(generation: generation); return }
        reconcileLibraryIdentities()
        // Credentials never persist in the engine; await resend for this generation.
        let credentialFailures = await ProviderCredentialStore.resendAll(availableProviderIds: Set(providers.filter(\.isOperational).flatMap { $0.providerIds ?? [] }))
        guard generation == engineGeneration, !Task.isCancelled else { return }
        credentialRestoreErrors = credentialFailures
        if !credentialFailures.isEmpty {
            presentError("Some provider credentials could not be restored. Review these providers in Extensions: " + credentialFailures.keys.sorted().joined(separator: ", "))
        }
        #if DEBUG
        await importUITestExtensionIfRequested()
        #endif
        if preferences.activeProvider.isEmpty, let first = providers.first {
            preferences.activeProvider = first.providers.first ?? ""
        }
        // Still the same healthy engine (no restart raced the sync)?
        if isEngineReady && refreshed {
            guard connection.markUsable(generation: generation) else { return }
            extensionsPollTask?.cancel()
            extensionsPollTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30 * 60))
                    guard let self, generation == self.engineGeneration, self.isEngineReady else { return }
                    await self.extensions.refresh()
                }
            }
            // Remember the extension setup for backups, which no longer wait
            // for the engine.
            await BackupService.shared.refreshExtensionSetup(appState: self)
            // Provider capabilities (homepage, VPN) for Discover and Extensions.
            await DiscoverStore.shared.refreshProviders(preferences: preferences)
        }
    }

    /// User-actionable failure from a screen that has nowhere better to show
    /// it (library resume, repo sync, downloads). Rendered by the root banner.
    var transientError: String?

    func presentError(_ message: String) {
        transientError = message
    }

    func dismissTransientError() {
        transientError = nil
    }

    /// Short confirmation (backup written, restore done). Auto-dismisses.
    var transientNotice: String?
    private var noticeDismissTask: Task<Void, Never>?

    func presentNotice(_ message: String) {
        transientNotice = message
        noticeDismissTask?.cancel()
        noticeDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.transientNotice = nil
        }
    }

    // MARK: - Anti-bot solve polling (plan WS-1.3)

    /// While the engine is ready, long-polls `/solve/pending` and drives the
    /// offscreen WebKit solver for parked challenges, and `/media/pending`
    /// for extensions waiting on a WebViewResolver page (RT-11). Each request
    /// is held by the engine until something is parked (up to 25 s), so an
    /// idle app and engine do not wake each other every few seconds.
    private func startSolvePolling() {
        solvePollTask?.cancel()
        solvePollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isEngineReady else {
                    try? await Task.sleep(for: .seconds(2))
                    continue
                }
                let generation = self.engineGeneration
                let pending: [SolvePendingDto]
                do { pending = try await DaemonClient.shared.pendingSolves(waitMs: Self.longPollMilliseconds) }
                catch { try? await Task.sleep(for: .seconds(2)); continue }
                guard !Task.isCancelled, self.engineGeneration == generation, self.isEngineReady else { continue }
                var started = false
                for task in pending where !WebViewSolverService.shared.isSolving {
                    if !WebViewSolverService.shared.canSolve(targetUrl: task.targetUrl) {
                        DaemonLog.client("solve.rejected_target", fields: ["taskId": task.taskId, "host": URL(string: task.targetUrl)?.host ?? "invalid"])
                        continue
                    }
                    WebViewSolverService.shared.solve(taskId: task.taskId, targetUrl: task.targetUrl, userAgent: task.userAgent)
                    started = true
                }
                // Tasks stay listed while they are being solved: do not spin.
                if !pending.isEmpty && !started { try? await Task.sleep(for: .seconds(2)) }
            }
        }
        mediaPollTask?.cancel()
        mediaPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isEngineReady else {
                    try? await Task.sleep(for: .seconds(2))
                    continue
                }
                let generation = self.engineGeneration
                let pending: [MediaPendingDto]
                do { pending = try await DaemonClient.shared.pendingMedia(waitMs: Self.longPollMilliseconds) }
                catch { try? await Task.sleep(for: .seconds(2)); continue }
                guard !Task.isCancelled, self.engineGeneration == generation, self.isEngineReady else { continue }
                let active = MediaResolverService.shared.activeTaskIds
                let fresh = pending.filter { !active.contains($0.taskId) }
                for task in fresh { MediaResolverService.shared.start(task) }
                // A provider call is waiting on these: re-check soon, without spinning.
                if !pending.isEmpty && fresh.isEmpty { try? await Task.sleep(for: .milliseconds(500)) }
            }
        }
    }

    /// Extension-created WebViews (RT-14): each command runs in the app's WebKit.
    private func startWebViewPolling() {
        webViewPollTask?.cancel()
        webViewPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isEngineReady else {
                    try? await Task.sleep(for: .seconds(2))
                    continue
                }
                let generation = self.engineGeneration
                let commands: [WebViewCommandDto]
                do { commands = try await DaemonClient.shared.pendingWebViewCommands(waitMs: Self.longPollMilliseconds) }
                catch { try? await Task.sleep(for: .seconds(2)); continue }
                guard !Task.isCancelled, self.engineGeneration == generation, self.isEngineReady else { continue }
                // Each command is handed out once by the engine.
                for command in commands { WebViewSessionService.shared.handle(command) }
            }
        }
    }

    /// How long the engine may hold a pending-work request (it caps at 25 s).
    static let longPollMilliseconds = 25_000

    /// Loads (or returns cached) details for a coordinate. The destination
    /// view owns rendering the failure — no shared "error of the top of the
    /// path" that smears one screen's error onto the next.
    /// - Parameter refresh: bypass both this cache and the daemon's (⌘R).
    func loadDetails(for coordinate: DetailCoordinate, refresh: Bool = false) async -> Result<DetailsDto, Error> {
        if !refresh, let cached = detailsCache.current(coordinate, generation: detailsGeneration) { return .success(cached) }

        guard isEngineReady else {
            // No engine: an earlier copy can still be shown, marked stale. It
            // is never served once an engine is available to revalidate it.
            if !refresh, let snapshot = detailsCache.snapshot(coordinate) { return .success(snapshot) }
            return .failure(DaemonClient.DaemonError.notReady)
        }
        let generation = detailsGeneration
        do {
            let details = try await DaemonClient.shared.details(
                provider: coordinate.requestProvider,
                url: coordinate.url,
                refresh: refresh,
            )
            // Stored under the generation that requested it: a change during
            // the request leaves this entry stale rather than authoritative.
            detailsCache.store(details, for: coordinate, generation: generation,
                               keeping: WindowSessionRegistry.shared.activeDetailKeys)
            return .success(details)
        } catch {
            return .failure(error)
        }
    }
}

/// Recently viewed details, so back-navigation is instant. An entry is
/// authoritative only for the engine/provider configuration that produced it
/// and for a short time; least recently used entries are evicted first.
struct DetailsCache {
    struct Generation: Equatable {
        var engine: UInt64
        var extensions: UInt64
        var settings: UInt64
    }
    private struct Entry {
        let details: DetailsDto
        let generation: Generation
        let loadedAt: Date
        var lastUsed: UInt64
    }

    /// Matches the engine's own details cache lifetime.
    static let freshness: TimeInterval = 10 * 60
    static let limit = 12

    private var entries: [DetailCoordinate: Entry] = [:]
    private var tick: UInt64 = 0
    var count: Int { entries.count }

    /// An authoritative hit: same configuration and still fresh.
    mutating func current(_ key: DetailCoordinate, generation: Generation, now: Date = Date()) -> DetailsDto? {
        guard let entry = entries[key], entry.generation == generation,
              now.timeIntervalSince(entry.loadedAt) < Self.freshness, now >= entry.loadedAt else { return nil }
        tick &+= 1
        entries[key]?.lastUsed = tick
        return entry.details
    }

    /// Whatever is held, for display when nothing can be loaded.
    func snapshot(_ key: DetailCoordinate) -> DetailsDto? { entries[key]?.details }

    func isStale(_ key: DetailCoordinate, generation: Generation, now: Date = Date()) -> Bool {
        guard let entry = entries[key] else { return false }
        return entry.generation != generation || now.timeIntervalSince(entry.loadedAt) >= Self.freshness
    }

    mutating func store(_ details: DetailsDto, for key: DetailCoordinate, generation: Generation,
                        keeping active: Set<DetailCoordinate> = [], now: Date = Date()) {
        tick &+= 1
        entries[key] = Entry(details: details, generation: generation, loadedAt: now, lastUsed: tick)
        // Open detail pages keep their entry; the rest go oldest-use first.
        let evictable = entries.filter { !active.contains($0.key) && $0.key != key }.sorted { $0.value.lastUsed < $1.value.lastUsed }
        for (candidate, _) in evictable.prefix(max(0, entries.count - Self.limit)) { entries[candidate] = nil }
    }
}


/// For the isolated smoke launch only (`CS_SMOKE_STATUS_FILE` plus an
/// isolated root): the app states which engine it owns and how far that
/// engine's verified connection has come, so a script can check this launch
/// instead of guessing from old log text or unrelated processes. The file
/// holds no token and nothing is written in a normal launch.
@MainActor
enum SmokeStatus {
    static func publish(_ connection: EngineConnection, environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard AppEnvironment.isIsolated(environment), !AppEnvironment.isUnitTestHost,
              let path = environment["CS_SMOKE_STATUS_FILE"], path.hasPrefix("/") else { return }
        let phase: String
        switch connection.phase {
        case .launching: phase = "launching"
        case .verifying: phase = "verifying"
        case .restoring: phase = "restoring"
        case .usable: phase = "usable"
        case .recovering: phase = "recovering"
        case .failed: phase = "failed"
        }
        let supervisor = DaemonSupervisor.shared
        let resources = Bundle.main.resourceURL
        let status: [String: Any] = [
            "appPID": ProcessInfo.processInfo.processIdentifier,
            "generation": connection.generation,
            "phase": phase,
            "enginePID": supervisor.ownedEngineProcessID.map { Int($0) } ?? NSNull(),
            "launchID": supervisor.launchID?.uuidString ?? NSNull(),
            "ipcVersion": connection.health?.ipcVersion ?? NSNull(),
            "player": [
                "ffmpeg": DownloadService.ffmpegBinaryPath() != nil,
                "libmpv": resources.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Binaries/libmpv.dylib").path) } ?? false,
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: status, options: [.sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        publishEndpoint(connection, environment: environment)
    }

    /// Live checks only (`scripts/live_extension_run.py --app`): an isolated
    /// launch may hand its usable engine's endpoint to the script driving it,
    /// in a 0600 file inside the private test root. Never in a normal launch.
    private static func publishEndpoint(_ connection: EngineConnection, environment: [String: String]) {
        guard connection.isUsable, let endpoint = connection.endpoint,
              let path = environment["CS_LIVE_ENDPOINT_FILE"], path.hasPrefix("/"),
              let root = AppEnvironment.root(environment: environment),
              URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/"),
              let data = try? JSONSerialization.data(withJSONObject: ["port": endpoint.port, "token": endpoint.token]) else { return }
        FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
    }
}
