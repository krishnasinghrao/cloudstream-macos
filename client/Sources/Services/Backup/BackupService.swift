import AppKit
import Foundation
import UniformTypeIdentifiers

/// Export, restore and automatic backups (Offline-Features-Plan Phase 7).
@MainActor
@Observable
final class BackupService {
    static let shared = BackupService()

    /// Automatic backups kept on disk.
    enum RestoreError: LocalizedError, Equatable {
        case safetyBackupFailed(String)
        case locked
        /// The profile changed between choosing the file and applying it.
        case profileChanged

        var errorDescription: String? {
            switch self {
            case .safetyBackupFailed(let reason):
                return "Nothing was replaced: CloudStream couldn't save a safety copy of your current library first (\(reason))."
            case .locked:
                return "Unlock CloudStream before importing or exporting a backup."
            case .profileChanged:
                return "Nothing was changed: the profile was switched while the backup was being prepared. Start again in the profile you want."
            }
        }
    }

    static let retainedAutoBackups = 7
    static let retainedSafetyBackups = 5
    static let autoBackupInterval: TimeInterval = 24 * 60 * 60

    /// How often the running app looks for profiles whose daily backup is due.
    static let scheduleCheckInterval: Duration = .seconds(60 * 60)

    /// Test seam.
    @ObservationIgnored var backupsDirectoryOverride: URL?
    @ObservationIgnored private var schedule: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private weak var scheduledAppState: AppState?
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = AppEnvironment.defaults) {
        self.defaults = defaults
        registerRepositories = { try await DaemonClient.shared.registerRepositories($0) }
        listProviders = { try await DaemonClient.shared.allProviders() }
        setProviderEnabled = { try await DaemonClient.shared.setProviderEnabled(providerId: $0, enabled: $1) }
    }

    // MARK: Extension setup (repositories, disabled providers)

    /// What the engine last reported. Backups are written whether or not the
    /// engine is running, so the setup they carry is this remembered copy
    /// with the time it was read — never presented as freshly verified.
    struct ExtensionSetup: Codable, Equatable {
        var repositories: [String]
        var disabledProviderIDs: [String]
        var disabledProviderNames: [String]
        var capturedAt: Date
    }

    private(set) var extensionSetup: ExtensionSetup? {
        get { defaults.data(forKey: "backup.extensionSetup.v1").flatMap { try? JSONDecoder().decode(ExtensionSetup.self, from: $0) } }
        set { defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "backup.extensionSetup.v1") }
    }

    func rememberExtensionSetup(repositories: [String], providers: [ProviderInfoDto], at date: Date = Date()) {
        let disabled = providers.filter { $0.enabled == false }
        extensionSetup = ExtensionSetup(repositories: repositories.sorted(),
            disabledProviderIDs: disabled.compactMap(\.providerId).sorted(),
            disabledProviderNames: Array(Set(disabled.map(\.name))).sorted(), capturedAt: date)
    }

    /// Reads the current setup from a usable engine; keeps the previous copy on failure.
    func refreshExtensionSetup(appState: AppState) async {
        guard appState.isEngineBootstrapped, let providers = try? await DaemonClient.shared.allProviders() else { return }
        rememberExtensionSetup(repositories: appState.repositories.map(\.url), providers: providers)
    }

    var backupsDirectory: URL {
        if let backupsDirectoryOverride { return backupsDirectoryOverride }
        if let isolated = AppEnvironment.directory("Backups") { return isolated }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("CloudStream/Backups", isDirectory: true)
    }

    // MARK: Build & write

    func makeDocument(appState: AppState?, store: LibraryStore = .shared, preferences: UserPreferences = .shared) throws -> BackupDocument {
        try requireUnlocked()
        return try snapshotDocument(appState: appState, store: store, preferences: preferences)
    }

    /// Internal protection may run while locked; this never exposes a document
    /// through a user-facing export entry point.
    private func snapshotDocument(appState: AppState?, store: LibraryStore = .shared, preferences: UserPreferences = .shared) throws -> BackupDocument {
        document(snapshot: try store.exportSnapshot(), profileID: ProfileStore.shared.activeID, preferences: preferences)
    }

    private func document(snapshot: LibraryStore.LibrarySnapshot, profileID: UUID, preferences: UserPreferences = .shared) -> BackupDocument {
        let setup = extensionSetup
        return BackupDocument(
            createdAt: Date(),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            items: snapshot.items,
            episodes: snapshot.episodes,
            playback: snapshot.playback,
            preferences: preferences.backupValues(),
            repositories: setup?.repositories ?? [],
            disabledProviders: setup?.disabledProviderNames ?? [],
            profileID: profileID,
            disabledProviderIDs: setup?.disabledProviderIDs,
            extensionSetupCapturedAt: setup?.capturedAt,
            pages: snapshot.pages,
        )
    }

    /// Atomic write (temp file + replace) so a crash never leaves half a backup.
    func write(_ document: BackupDocument, to url: URL) throws {
        try requireUnlocked()
        let data = try document.encoded()
        try data.write(to: url, options: [.atomic])
    }

    static func defaultFileName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        return "CloudStream-Backup-\(formatter.string(from: date)).json"
    }

    // MARK: Read

    enum Source: Equatable {
        case mac(BackupDocument)
        case android(itemCount: Int)
    }

    struct Pending {
        let source: Source
        let snapshot: LibraryStore.LibrarySnapshot
        let document: BackupDocument?
        /// The profile library this restore was prepared for. A restore never
        /// lands in a profile that was selected afterwards.
        var owner: LibraryStore.ProfileOperationContext? = nil
        var androidReport: AndroidBackupImporter.Report? = nil
        /// Raw Android file, kept so another account can be chosen.
        var androidData: Data? = nil
    }

    /// Reads and validates a backup of either format, without applying it.
    func read(_ url: URL, store: LibraryStore = .shared) throws -> Pending {
        try requireUnlocked()
        let owner = try? store.captureProfileOperation()
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        if let size = values.fileSize, size > BackupDocument.maxFileBytes { throw BackupDocument.ValidationError.tooLarge }
        let data = try Data(contentsOf: url)
        if AndroidBackupImporter.looksLikeAndroidBackup(data) {
            var pending = try androidPending(data, account: nil)
            pending.owner = owner
            return pending
        }
        let document = try BackupDocument.decode(data)
        return Pending(
            source: .mac(document),
            snapshot: LibraryStore.LibrarySnapshot(items: document.items, episodes: document.episodes, playback: document.playback,
                                                  formatVersion: document.version, pages: document.pages),
            document: document,
            owner: owner,
        )
    }

    /// One Android account, or all of them when `account` is nil.
    func androidPending(_ data: Data, account: Int?) throws -> Pending {
        let plan = try AndroidBackupImporter.plan(from: data, account: account)
        try validate(plan.snapshot)
        return Pending(source: .android(itemCount: plan.snapshot.items.count), snapshot: plan.snapshot, document: nil,
                       androidReport: plan.report, androidData: data)
    }

    /// What a restore did, phase by phase. The library is one transaction;
    /// preferences and the extension setup are separate stores and are
    /// reported separately — this is not all-or-nothing across them.
    struct RestoreResult {
        var library = LibraryStore.ImportReport()
        var preferencesApplied = false
        var repositories: [RepoRegistrationDto] = []
        var providersDisabled = 0
        /// Repositories/providers could not be finished now and can be
        /// retried without touching the library again.
        var externalPhasesPending = false
        var warnings: [String] = []
    }

    /// Extension setup of the last restore that could not be finished (engine
    /// not ready, or a request failed). `retryExternalRestore` applies only it.
    private(set) var pendingExternalRestore: BackupDocument?
    /// True while a restore is being applied; the app stays usable meanwhile.
    private(set) var isRestoring = false

    /// Applies a validated backup. The library part is one transaction; the
    /// preferences and extension setup follow only if it succeeded.
    func restore(_ pending: Pending, mode: LibraryStore.ImportMode, includePreferences: Bool, appState: AppState?, store: LibraryStore = .shared) async throws -> [String] {
        try await restoreDetailed(pending, mode: mode, includePreferences: includePreferences, appState: appState, store: store).warnings
    }

    func restoreDetailed(_ pending: Pending, mode: LibraryStore.ImportMode, includePreferences: Bool, appState: AppState?,
                         store: LibraryStore = .shared) async throws -> RestoreResult {
        try requireUnlocked()
        if let owner = pending.owner, !store.owns(owner) { throw RestoreError.profileChanged }
        isRestoring = true
        defer { isRestoring = false }
        // Validate both the snapshot actually applied and every external
        // phase before even creating the safety copy or mutating the library.
        try validate(pending.snapshot)
        if let document = pending.document { try document.validate() }
        var result = RestoreResult()
        // Safety net: snapshot the current state first. Replace wipes the
        // library, so it never proceeds without one; Merge only adds and
        // updates, so a failed snapshot is logged and the merge continues.
        do {
            _ = try writeAutoBackup(appState: appState, reason: "before-restore", store: store)
        } catch {
            DaemonLog.client("backup.safety_failed", fields: ["error": error.localizedDescription])
            if mode == .replace { throw BackupService.RestoreError.safetyBackupFailed(error.localizedDescription) }
            result.warnings.append("A safety copy couldn’t be saved before merging: \(error.localizedDescription)")
        }
        // Off the main thread; the store refuses a profile change meanwhile,
        // so what follows still belongs to the profile checked above. A lock
        // during it postpones the extension setup (applyExternalPhases).
        result.library = try await store.importSnapshotInBackground(pending.snapshot, mode: mode)
        result.warnings.append(contentsOf: result.library.warnings)
        if let report = pending.androidReport { result.warnings.append(contentsOf: report.warnings) }
        guard let document = pending.document else { return result }
        if includePreferences {
            try UserPreferences.shared.applyBackupValues(document.preferences)
            result.preferencesApplied = true
        }
        if document.extensionSetupCapturedAt == nil, document.version >= 2,
           document.repositories.isEmpty, document.disabledProviders.isEmpty {
            result.warnings.append("This backup was made while the extension setup was unavailable, so repositories and disabled providers were not part of it.")
        }
        await applyExternalPhases(document, appState: appState, into: &result)
        return result
    }

    /// Finishes the extension setup of an earlier restore. The library and
    /// its safety copy are not touched again.
    @discardableResult
    func retryExternalRestore(appState: AppState?) async throws -> RestoreResult {
        try requireUnlocked()
        var result = RestoreResult()
        guard let document = pendingExternalRestore else { return result }
        await applyExternalPhases(document, appState: appState, into: &result)
        return result
    }

    /// Repositories, then disabled providers. Both are idempotent in the
    /// engine, so repeating them after a failure is safe.
    private func applyExternalPhases(_ document: BackupDocument, appState: AppState?, into result: inout RestoreResult) async {
        let providerIDs = document.disabledProviderIDs ?? []
        // Names are only for backups that predate stable IDs.
        let legacyNames = document.disabledProviderIDs == nil ? document.disabledProviders : []
        guard !document.repositories.isEmpty || !providerIDs.isEmpty || !legacyNames.isEmpty else {
            pendingExternalRestore = nil
            return
        }
        func postpone(_ reason: String) {
            pendingExternalRestore = document
            result.externalPhasesPending = true
            result.warnings.append("Your library was restored, but the extension setup wasn’t: \(reason) Use Finish Restoring Extensions in Settings to try again.")
        }
        guard let access = engineAccess ?? appState.map(ExternalEngine.init), access.isUsable() else { return postpone("the engine isn’t ready.") }
        let engine = access.generation()
        func stillValid() -> Bool { !AppLock.shared.isLocked && access.isUsable() && access.generation() == engine }

        if !document.repositories.isEmpty {
            do { result.repositories = try await registerRepositories(document.repositories) }
            catch { return postpone("repositories couldn’t be added (\(error.localizedDescription)).") }
            guard stillValid() else { return postpone("CloudStream was locked or the engine restarted.") }
            let rejected = result.repositories.filter { $0.status == "rejected" }
            if !rejected.isEmpty {
                result.warnings.append("\(rejected.count) repositories weren’t added: " + rejected.map { "\($0.url) — \($0.reason ?? "not allowed")" }.joined(separator: "; "))
            }
        }

        if !providerIDs.isEmpty || !legacyNames.isEmpty {
            let providers: [ProviderInfoDto]
            do { providers = try await listProviders() }
            catch { return postpone("providers couldn’t be read (\(error.localizedDescription)).") }
            guard stillValid() else { return postpone("CloudStream was locked or the engine restarted.") }
            var targets: [String] = []
            var notInstalled = 0, ambiguous: [String] = []
            for id in providerIDs {
                if providers.contains(where: { $0.providerId == id }) { targets.append(id) } else { notInstalled += 1 }
            }
            for name in legacyNames {
                let matches = providers.filter { $0.name == name }
                if matches.count == 1, let id = matches[0].providerId { targets.append(id) }
                else if matches.isEmpty { notInstalled += 1 }
                else { ambiguous.append(name) }
            }
            var failed: [String] = []
            for id in targets {
                do { try await setProviderEnabled(id, false); result.providersDisabled += 1 }
                catch { failed.append(providers.first { $0.providerId == id }?.name ?? id) }
                guard stillValid() else { return postpone("CloudStream was locked or the engine restarted.") }
            }
            if notInstalled > 0 {
                result.warnings.append("\(notInstalled) disabled providers aren’t installed on this Mac. Restoring adds repositories but doesn’t install extensions; disable those providers again after installing them.")
            }
            if !ambiguous.isEmpty {
                result.warnings.append("These providers exist in more than one extension, so an older backup can’t say which to disable: \(ambiguous.joined(separator: ", ")).")
            }
            if !failed.isEmpty { return postpone("these providers couldn’t be disabled: \(failed.joined(separator: ", ")).") }
        }
        pendingExternalRestore = nil
        await access.refresh()
    }

    /// The engine as the external phases need it: usable, and still the same
    /// one after each request.
    struct ExternalEngine {
        var isUsable: () -> Bool
        var generation: () -> UInt64
        var refresh: () async -> Void

        init(isUsable: @escaping () -> Bool, generation: @escaping () -> UInt64, refresh: @escaping () async -> Void) {
            self.isUsable = isUsable
            self.generation = generation
            self.refresh = refresh
        }

        @MainActor
        init(_ appState: AppState) {
            self.init(isUsable: { appState.isEngineBootstrapped }, generation: { appState.connection.generation }, refresh: {
                _ = await appState.extensions.refresh()
                await BackupService.shared.refreshExtensionSetup(appState: appState)
            })
        }
    }
    /// Tests supply the engine; the app derives it from its state.
    @ObservationIgnored var engineAccess: ExternalEngine?

    /// Engine operations of the external phases (tests replace them).
    @ObservationIgnored var registerRepositories: @MainActor ([String]) async throws -> [RepoRegistrationDto]
    @ObservationIgnored var listProviders: @MainActor () async throws -> [ProviderInfoDto]
    @ObservationIgnored var setProviderEnabled: @MainActor (String, Bool) async throws -> Void

    // MARK: Automatic backups

    /// Starts the daily-backup schedule for the life of the app: a check now,
    /// then hourly, and whenever the Mac wakes. Profile activation calls
    /// `checkSchedule`. Nothing here depends on the engine.
    func startScheduling(appState: AppState?) {
        guard schedule == nil else { return }
        scheduledAppState = appState
        schedule = Task { [weak self] in
            while !Task.isCancelled {
                self?.runDueBackups()
                do { try await Task.sleep(for: Self.scheduleCheckInterval) } catch { return }
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.runDueBackups() }
        }
    }

    func stopScheduling() {
        schedule?.cancel()
        schedule = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }

    /// A profile was just activated: back it up now if it is due.
    func checkSchedule() {
        guard schedule != nil else { return }
        runDueBackups()
    }

    /// Backs up every profile whose own last successful backup is older than
    /// a day. Inactive profiles are read through their own store; the visible
    /// profile is not switched. A profile that fails stays due.
    @discardableResult
    func runDueBackups(now: Date = Date(), store: LibraryStore = .shared, profiles: ProfileStore = .shared,
                       preferences: UserPreferences = .shared) -> [UUID] {
        guard preferences.autoBackupEnabled else { return [] }
        var written: [UUID] = []
        for profile in profiles.profiles {
            if let last = preferences.lastAutoBackup(for: profile.id), now.timeIntervalSince(last) < Self.autoBackupInterval, now >= last { continue }
            do {
                let snapshot = try profile.id == profiles.activeID ? store.exportSnapshot()
                    : store.exportSnapshot(profileStoreName: profile.storeName)
                var document = document(snapshot: snapshot, profileID: profile.id, preferences: preferences)
                document.reason = "daily"
                // An empty library has nothing to protect and is not a backup.
                guard try writeBackup(document, profileID: profile.id, reason: "daily") != nil else { continue }
                preferences.setLastAutoBackup(now, for: profile.id)
                written.append(profile.id)
            } catch {
                DaemonLog.client("backup.auto_failed", fields: ["error": error.localizedDescription, "active": String(profile.id == profiles.activeID)])
            }
        }
        return written
    }

    /// Writes a rolling backup of the active profile. Returns nil — without
    /// writing — when the library is empty: there is nothing to protect, and
    /// an empty file would push a real backup out of the rotation.
    @discardableResult
    func writeAutoBackup(appState: AppState?, reason: String, store: LibraryStore = .shared) throws -> URL? {
        var document = try snapshotDocument(appState: appState, store: store)
        document.reason = reason
        return try writeBackup(document, profileID: ProfileStore.shared.activeID, reason: reason)
    }

    private func writeBackup(_ document: BackupDocument, profileID: UUID, reason: String) throws -> URL? {
        guard !document.items.isEmpty || !document.episodes.isEmpty else { return nil }
        let directory = backupsDirectory.appendingPathComponent(profileID.uuidString, isDirectory: true)
            .appendingPathComponent(reason == "daily" ? "Daily" : "Safety", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(BackupFilePolicy.automaticName(profileID: profileID, reason: reason))
        try BackupFilePolicy.writeUnique(try document.encoded(), to: url)
        if reason == "daily" {
            pruneAutoBackups(in: directory, keep: Self.retainedAutoBackups)
        } else {
            pruneSafetyBackups(in: directory, keep: Self.retainedSafetyBackups)
        }
        DaemonLog.client("backup.auto_written", fields: ["reason": reason, "items": String(document.items.count)])
        return url
    }

    nonisolated static func autoBackupFiles(in directory: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
        )) ?? []
        return urls
            .filter { $0.lastPathComponent.hasPrefix("CloudStream-Backup-") && $0.pathExtension == "json" }
            .sorted {
                let l = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let r = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return l > r
            }
    }

    nonisolated func pruneAutoBackups(in directory: URL, keep: Int) {
        // Legacy safety copies in a flat directory are also protected.
        for url in Self.autoBackupFiles(in: directory).filter({ $0.lastPathComponent.hasSuffix(".daily.json") }).dropFirst(max(0, keep)) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    nonisolated func pruneSafetyBackups(in directory: URL, keep: Int) {
        for url in Self.autoBackupFiles(in: directory).filter({ !$0.lastPathComponent.hasSuffix(".daily.json") }).dropFirst(max(0, keep)) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: UI flows (File menu / Settings)

    func exportInteractively(appState: AppState) {
        guard !AppLock.shared.isLocked else { appState.presentError(RestoreError.locked.localizedDescription); return }
        let panel = NSSavePanel()
        panel.title = "Export Backup"
        panel.nameFieldStringValue = Self.defaultFileName()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        // A modal panel still lets the app lock or the profile change.
        let owner = try? LibraryStore.shared.captureProfileOperation()
        let lock = AppLock.shared.generation
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard AppLock.shared.generation == lock else { throw RestoreError.locked }
            guard let owner, LibraryStore.shared.owns(owner) else { throw RestoreError.profileChanged }
            let document = try makeDocument(appState: appState)
            try write(document, to: url)
            let summary = document.summary
            appState.presentNotice("Backed up \(summary.items) titles and \(summary.episodes) episodes")
        } catch {
            appState.presentError("Couldn't write the backup: \(error.localizedDescription)")
        }
    }

    func importInteractively(appState: AppState) {
        guard !AppLock.shared.isLocked else { appState.presentError(RestoreError.locked.localizedDescription); return }
        let panel = NSOpenPanel()
        panel.title = "Import Backup"
        panel.message = "Choose a CloudStream backup from this Mac or from CloudStream for Android."
        panel.allowedContentTypes = [.json, UTType(filenameExtension: "txt") ?? .plainText]
        panel.allowsMultipleSelection = false
        let lock = AppLock.shared.generation
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var pending: Pending
        do {
            guard AppLock.shared.generation == lock else { throw RestoreError.locked }
            pending = try read(url)
        } catch {
            appState.presentError(error.localizedDescription)
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        switch pending.source {
        case .mac(let document):
            let summary = document.summary
            alert.messageText = "Restore this backup?"
            alert.informativeText = """
            Created \(document.createdAt.formatted(date: .abbreviated, time: .shortened)) — \(summary.items) titles \
            (\(summary.libraryEntries) in your lists, \(summary.favorites) favorites), \(summary.episodes) episodes of history, \
            \(summary.repositories) repositories\(summary.pages > 0 ? ", \(summary.pages) \(summary.pages == 1 ? "page" : "pages")" : "").

            Merge adds missing titles and applies newer edits when their order is known. If the order is unknown, your current \
            values stay. Replace discards your current library and history first. CloudStream attempts a safety backup either way.
            """
        case .android(let count):
            alert.messageText = "Import from CloudStream for Android?"
            alert.informativeText = """
            \(count) bookmarked or favorite titles with their watch status and Continue Watching positions will be merged \
            into your library. Per-episode history and Android settings can't be transferred.
            """
        }
        alert.addButton(withTitle: "Merge")
        if pending.document != nil { alert.addButton(withTitle: "Replace…") }
        alert.addButton(withTitle: "Cancel")
        let preferencesBox = NSButton(checkboxWithTitle: "Also restore settings", target: nil, action: nil)
        preferencesBox.state = .on
        if pending.document != nil { alert.accessoryView = preferencesBox }
        // Several Android accounts: all of them by default, or just one.
        let accounts = pending.androidReport?.accounts ?? []
        let accountPicker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26), pullsDown: false)
        if accounts.count > 1 {
            accountPicker.addItem(withTitle: "All Android accounts")
            for account in accounts { accountPicker.addItem(withTitle: "Android account \(account + 1) only") }
            alert.accessoryView = accountPicker
            if let conflicts = pending.androidReport, !conflicts.warnings.isEmpty {
                alert.informativeText += "\n\n" + conflicts.warnings.joined(separator: " ")
            }
        }

        let response = alert.runModal()
        if accounts.count > 1, accountPicker.indexOfSelectedItem > 0, let data = pending.androidData {
            let owner = pending.owner
            do {
                pending = try androidPending(data, account: accounts[accountPicker.indexOfSelectedItem - 1])
                pending.owner = owner
            } catch { appState.presentError(error.localizedDescription); return }
        }
        let mode: LibraryStore.ImportMode
        switch response {
        case .alertFirstButtonReturn: mode = .merge
        case .alertSecondButtonReturn where pending.document != nil:
            let confirm = NSAlert()
            confirm.alertStyle = .warning
            confirm.messageText = "Replace your library?"
            confirm.informativeText = "Your current library, watch history and per-show settings are removed and replaced by the backup. A safety backup is saved first."
            confirm.addButton(withTitle: "Replace")
            confirm.addButton(withTitle: "Cancel")
            guard confirm.runModal() == .alertFirstButtonReturn else { return }
            mode = .replace
        default:
            return
        }

        let includePreferences = preferencesBox.state == .on
        Task {
            do {
                guard AppLock.shared.generation == lock else { throw RestoreError.locked }
                let result = try await restoreDetailed(pending, mode: mode, includePreferences: includePreferences, appState: appState)
                if !result.warnings.isEmpty {
                    appState.presentError(result.warnings.joined(separator: "\n"))
                } else {
                    appState.presentNotice("Backup restored")
                }
            } catch {
                appState.presentError(error.localizedDescription)
            }
        }
    }

    private func requireUnlocked() throws {
        if AppLock.shared.isLocked { throw RestoreError.locked }
    }

    private func validate(_ snapshot: LibraryStore.LibrarySnapshot) throws {
        try BackupDocument(version: snapshot.formatVersion, createdAt: Date(), appVersion: "validation", items: snapshot.items,
                           episodes: snapshot.episodes, playback: snapshot.playback,
                           preferences: [:], repositories: [], disabledProviders: [], pages: snapshot.pages).validate()
    }
}
