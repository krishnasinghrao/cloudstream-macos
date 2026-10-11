import SwiftUI
import SwiftData
import AppKit

/// Application delegate: guarantees the daemon never outlives the app
/// (plan WS-2.3) — `onDisappear` is unreliable on quit.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var sigtermSource: (any DispatchSourceSignal)?
    private var sigintSource: (any DispatchSourceSignal)?

    override init() {
        signal(SIGPIPE, SIG_IGN)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if MainActor.assumeIsolated({ IdentityMigrationProcessProbe.runIfRequested() || DownloadFinalizationProcessProbe.runIfRequested() }) { return }
        #endif
        guard !AppEnvironment.isUnitTestHost else { return }
        setupSignalHandlers()
        MainActor.assumeIsolated {
            // Open the active profile's library before any window reads it,
            // then arm the lock (locks immediately if enabled).
            ProfileStore.shared.activateStoredProfile()
            AppLock.shared.start()
            // Engine responses older builds left in the shared HTTP cache (audit M3).
            if !AppEnvironment.isIsolated(), EngineTransport.purgeLegacyResponseCache() { DaemonLog.client("ipc.legacy_cache_purged") }
            AppState.shared.observeEngine()
            DaemonSupervisor.shared.start()
            ConnectivityMonitor.shared.start()
            EpisodeUpdateChecker.shared.start(appState: AppState.shared)
            BackupService.shared.startScheduling(appState: AppState.shared)
            SpotlightIndexer.shared.scheduleReindex()
        }
    }

    private func setupSignalHandlers() {
        signal(SIGPIPE, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termSource.setEventHandler {
            MainActor.assumeIsolated {
                ApplicationShutdown.shared.begin { exit(0) }
            }
        }
        termSource.resume()
        self.sigtermSource = termSource

        signal(SIGINT, SIG_IGN)
        let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        intSource.setEventHandler {
            MainActor.assumeIsolated {
                ApplicationShutdown.shared.begin { exit(0) }
            }
        }
        intSource.resume()
        self.sigintSource = intSource
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if AppEnvironment.isUnitTestHost { return .terminateNow }
        return MainActor.assumeIsolated {
            if DownloadService.shared.hasTransfersInFlight, !Self.isSystemInitiatedQuit(), !confirmQuitDuringDownloads() {
                return .terminateCancel
            }
            // Persist the playing episode's position before anything stops.
            AppState.shared.player.close()
            do { try LibraryStore.shared.flushPendingProgress() }
            catch {
                DaemonLog.client("store.quit_flush_failed", fields: ["error": error.localizedDescription])
                if !Self.isSystemInitiatedQuit() {
                    let alert = NSAlert()
                    alert.messageText = "Playback progress couldn't be saved"
                    alert.informativeText = "Keep CloudStream open to retry saving, or quit without saving the latest playback position.\n\n\(error.localizedDescription)"
                    alert.addButton(withTitle: "Keep Open")
                    alert.addButton(withTitle: "Quit Without Saving")
                    guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
                }
            }
            // Transfers stop without changing their persisted state, so the
            // next launch restores them (direct files resume from .part).
            ApplicationShutdown.shared.begin(persistProgress: false) {
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
    }

    /// Logout/restart/shutdown must never be blocked by a modal.
    private static func isSystemInitiatedQuit() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              let reason = event.attributeDescriptor(forKeyword: kAEQuitReason)?.typeCodeValue else { return false }
        return reason == kAELogOut || reason == kAEReallyLogOut || reason == kAEShowRestartDialog
            || reason == kAEShowShutdownDialog || reason == kAERestart || reason == kAEShutDown
    }

    @MainActor
    private func confirmQuitDuringDownloads() -> Bool {
        let count = DownloadService.shared.activeCount
        let alert = NSAlert()
        alert.messageText = count == 1 ? "A download is in progress" : "\(count) downloads are in progress"
        alert.informativeText = "Quitting stops them. They continue the next time you open CloudStream; streamed (HLS) downloads start over."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Dock menu: Continue Watching shortcuts (Phase 9).
    @MainActor
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard !AppLock.shared.isLocked else { return nil }
        let menu = NSMenu()
        let items = LibraryStore.shared.readForDisplay(or: [], { try LibraryStore.shared.continueWatching }).prefix(5)
        for item in items {
            let entry = NSMenuItem(title: CloudStreamMenuBarContent.label(for: item), action: #selector(resumeFromDock(_:)), keyEquivalent: "")
            entry.representedObject = item.id
            entry.target = self
            menu.addItem(entry)
        }
        return items.isEmpty ? nil : menu
    }

    @MainActor @objc private func resumeFromDock(_ sender: NSMenuItem) {
        guard !AppLock.shared.isLocked, let id = sender.representedObject as? String,
              let item = LibraryStore.shared.readForDisplay(or: [], { try LibraryStore.shared.continueWatching }).first(where: { $0.id == id }) else { return }
        NSApp.activate()
        LibraryStore.shared.startResume(item: item, appState: AppState.shared)
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard !AppEnvironment.isUnitTestHost else { return }
            ApplicationShutdown.shared.begin()
        }
    }
}

@main
struct CloudStreamMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState.shared
    @FocusedValue(\.windowSession) private var focusedSession
    /// Settings/player windows have no main-window scene value. Their Go
    /// commands retain the existing behavior by targeting the last main window.
    private var navigationSession: WindowSession { focusedSession ?? appState.windowSession }

    init() {
        signal(SIGPIPE, SIG_IGN)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .frame(minWidth: 980, minHeight: 600)
                // In full screen the toolbar stays put on a solid background,
                // like Finder; title pages start their artwork below it.
                .windowToolbarFullScreenVisibility(.visible)
                .onChange(of: LibraryStore.shared.version) { _, _ in
                    SpotlightIndexer.shared.scheduleReindex()
                }
                .onChange(of: DownloadService.shared.totalActiveOrQueuedCount) { _, _ in
                    DockBadge.update()
                }

        }
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .help) {
                Button("Keyboard Shortcuts") { navigationSession.showShortcuts = true }
                    .keyboardShortcut("/", modifiers: .command)
            }

            CommandGroup(after: .newItem) {
                // ⌘N is New Window and ⇧⌘N is Next Episode.
                Button("New Library Page…") {
                    navigationSession.pageEditor = PageEditorRequest(mode: .create(adding: nil))
                }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(AppLock.shared.isLocked)
            }

            CommandGroup(after: .importExport) {
                Button("Export Backup…") {
                    BackupService.shared.exportInteractively(appState: appState)
                }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(AppLock.shared.isLocked)
                Button("Import Backup…") {
                    BackupService.shared.importInteractively(appState: appState)
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(AppLock.shared.isLocked)
            }

            CommandMenu("Go") {
                Button("Home") {
                    navigationSession.navigateTo(.home)
                }
                .keyboardShortcut("1", modifiers: .command)

                Button("Search") {
                    navigationSession.navigateTo(.search)
                }
                .keyboardShortcut("f", modifiers: .command)

                Divider()

                Button("Watching") {
                    navigationSession.navigateTo(.watching)
                }
                .keyboardShortcut("2", modifiers: .command)

                Button("Plan to Watch") {
                    navigationSession.navigateTo(.planToWatch)
                }
                .keyboardShortcut("3", modifiers: .command)

                Button("Favorites") {
                    navigationSession.navigateTo(.favorites)
                }
                .keyboardShortcut("4", modifiers: .command)

                Button("Completed") {
                    navigationSession.navigateTo(.completed)
                }
                .keyboardShortcut("5", modifiers: .command)

                Button("On Hold") {
                    navigationSession.navigateTo(.onHold)
                }

                Button("Dropped") {
                    navigationSession.navigateTo(.dropped)
                }

                Button("Downloaded") {
                    navigationSession.navigateTo(.downloaded)
                }
                .keyboardShortcut("6", modifiers: .command)

                Button("History") {
                    navigationSession.navigateTo(.history)
                }
                .keyboardShortcut("y", modifiers: .command)

                Divider()

                Button("Extensions") {
                    navigationSession.navigateTo(.extensions)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            }

            // Playback shortcuts are ⌘-modified and disabled without a
            // session: bare Space/arrows in the menu bar would swallow text
            // input app-wide (U-01). Unmodified keys are handled locally by
            // the player window's own event monitor.
            CommandMenu("Playback") {
                PlaybackCommands(player: appState.player)
            }
        }

        Settings {
            SettingsView()
                .environment(appState)
        }

        MenuBarExtra("CloudStream", systemImage: "play.tv", isInserted: Binding(
            get: { appState.preferences.showMenuBarExtra },
            set: { appState.preferences.showMenuBarExtra = $0 },
        )) {
            CloudStreamMenuBarContent(appState: appState)
        }
    }
}

/// Playback menu (Player-Remediation-Plan D4): every HUD action also lives in
/// the menu bar, disabled — never hidden — without a session. Selections use
/// `Picker` so the current value carries a native checkmark.
private struct PlaybackCommands: View {
    let player: PlayerViewModel

    var body: some View {
        let hasSession = player.session != nil

        Button(player.isPlaying ? "Pause" : "Play") {
            player.togglePlayPause()
        }
        .disabled(!hasSession)
        .help("Space works while the player is open")

        Button("Skip Forward 10 Seconds") {
            player.seek(by: 10)
        }
        .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
        .disabled(!hasSession)

        Button("Skip Backward 10 Seconds") {
            player.seek(by: -10)
        }
        .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
        .disabled(!hasSession)

        Divider()

        Button("Next Episode") {
            player.playNextEpisode()
        }
        // ⌘N is File ▸ New Window; shift it instead of repurposing it.
        .keyboardShortcut("n", modifiers: [.command, .shift])
        .disabled(!player.hasNextEpisode)

        Button("Previous Episode") {
            player.playPreviousEpisode()
        }
        .disabled(!player.hasPreviousEpisode)

        Divider()

        Button(player.isMuted ? "Unmute" : "Mute") {
            player.toggleMute()
        }
        // ⌘M is Window ▸ Minimize; shift it instead of repurposing it.
        .keyboardShortcut("m", modifiers: [.command, .shift])
        .disabled(!hasSession)

        Button("Volume Up") {
            player.setVolume(player.volume + 5)
        }
        .keyboardShortcut(.upArrow, modifiers: [.command, .shift])
        .disabled(!hasSession)

        Button("Volume Down") {
            player.setVolume(player.volume - 5)
        }
        .keyboardShortcut(.downArrow, modifiers: [.command, .shift])
        .disabled(!hasSession)

        Divider()

        Menu("Speed") {
            PlayerSpeedPicker(player: player)
        }
        .disabled(!hasSession)

        Menu("Audio & Subtitles") {
            PlayerTrackMenuContent(player: player)
        }
        .disabled(!hasSession)

        Menu("Aspect Ratio") {
            PlayerAspectPicker(player: player)
        }
        .disabled(!hasSession)

        if let session = player.session, session.links.count > 1 {
            Menu("Quality & Mirrors") {
                PlayerMirrorPicker(session: session, player: player)
            }
        } else {
            Menu("Quality & Mirrors") {}
                .disabled(true)
        }

        Divider()

        Toggle("Float on Top", isOn: Binding(
            get: { player.isFloatingOnTop },
            set: { _ in player.toggleFloatOnTop() },
        ))
        .disabled(!hasSession)

        Button(player.isFullScreen ? "Exit Player Full Screen" : "Enter Player Full Screen") {
            player.toggleFullScreen()
        }
        .disabled(!hasSession)
    }
}


#if DEBUG
/// A separate debug app process exercises production ModelContainer/SQLite
/// transactions at deterministic kill points. Release builds contain no probe.
@MainActor
private enum IdentityMigrationProcessProbe {
    static func runIfRequested() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard let phase = environment["CS_IDENTITY_PROCESS_PHASE"] else { return false }
        guard ["schema-snapshot", "schema-opened", "identity-commit", "identity-committed"].contains(phase),
              AppEnvironment.isIsolated(environment),
              let path = environment["CS_TEST_ROOT"], path.hasPrefix("/"), path != "/" else { exit(64) }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let profile = environment["CS_IDENTITY_PROCESS_PROFILE"]
        guard profile == nil || profile == "CloudStreamMac-Profile-fixture" else { exit(64) }
        let target = (profile ?? LibraryStore.defaultStoreName) + ".store"
        do {
            let store = LibraryStore(storeDirectory: root, containerFactory: { schema, configurations in
                let isTarget = configurations.first?.url.lastPathComponent == target
                if isTarget, phase == "schema-snapshot" { try stop(at: phase, root: root) }
                let model = try ModelContainer(for: schema, configurations: configurations)
                if isTarget, phase == "schema-opened" { try stop(at: phase, root: root) }
                return model
            })
            guard store.sharedStoreHealth == .available else { exit(65) }
            store.persistenceFault = { boundary in
                if phase == "identity-commit", boundary == .identityCommit { try stop(at: phase, root: root) }
            }
            if let profile { try store.activateProfileStore(named: profile) }
            else { try store.migrateProviderIdentities(providers: []) }
            if phase == "identity-committed" { try stop(at: phase, root: root) }
            exit(66)
        } catch { exit(67) }
    }

    private static func stop(at phase: String, root: URL) throws -> Never {
        let ready = root.appendingPathComponent("identity-process-ready")
        try Data(phase.utf8).write(to: ready, options: .atomic)
        let handle = try FileHandle(forWritingTo: ready)
        try handle.synchronize()
        try handle.close()
        raise(SIGSTOP)
        exit(68) // Resuming rather than killing is not an accepted fixture path.
    }
}

/// A separate debug app process runs one real download through the
/// production queue, store and file operations and stops at a finalization
/// boundary to be killed (audit A30). A second process, started with
/// `reconcile`, reopens the same store and reports what launch
/// reconciliation decided. Release builds contain no probe.
@MainActor
private enum DownloadFinalizationProcessProbe {
    static func runIfRequested() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard let phase = environment["CS_DOWNLOAD_PROCESS_PHASE"] else { return false }
        let boundaries: [String: DownloadService.FinalizationBoundary] = [
            "intent-saved": .intentSaved, "renamed": .renamed, "completion-saved": .completionSaved,
        ]
        guard boundaries[phase] != nil || phase == "reconcile", AppEnvironment.crashFixtureStoreDirectory != nil,
              let root = AppEnvironment.root(environment: environment) else { exit(64) }
        guard LibraryStore.shared.sharedStoreHealth == .available else { exit(65) }
        // A fixture process shows nothing and takes no focus.
        NSApp.setActivationPolicy(.prohibited)
        // Creating the service restores the durable queue and reconciles it.
        let service = DownloadService.shared
        if phase == "reconcile" {
            do {
                let records = try LibraryStore.shared.downloadRecords().map { record -> [String: Any] in
                    ["status": record.statusRaw, "path": record.destinationPath, "bytes": record.bytesWritten,
                     "failure": record.failureReason ?? ""]
                }
                try JSONSerialization.data(withJSONObject: records).write(to: root.appendingPathComponent("reconcile-report.json"), options: .atomic)
                exit(0)
            } catch { exit(67) }
        }
        guard let address = environment["CS_DOWNLOAD_PROCESS_URL"], address.hasPrefix("http://127.0.0.1:"),
              let target = boundaries[phase] else { exit(64) }
        let directory = root.appendingPathComponent("Downloads", isDirectory: true)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) } catch { exit(67) }
        service.isEngineReady = { true }
        service.engineWait = nil
        service.linkResolver = { provider, _ in
            LinksResponseDto(provider: provider, links: [StreamLinkDto(url: address, name: "fixture", source: "fixture", quality: 720, type: "VIDEO")], subtitles: [])
        }
        service.finalizationFault = { boundary in
            if boundary == target { stop(at: phase, root: root) }
            return false
        }
        guard service.enqueue(.init(title: "Killed", episodeLabel: "Movie", provider: "Probe", episodeData: "probe-data",
                                    directory: directory, baseName: "Killed", durationSeconds: nil)) == .enqueued else { exit(66) }
        // The run loop carries the download; never linger if it cannot finish.
        Task {
            try? await Task.sleep(for: .seconds(40))
            exit(69)
        }
        return true
    }

    private static func stop(at phase: String, root: URL) -> Never {
        let ready = root.appendingPathComponent("download-process-ready")
        do {
            try Data(phase.utf8).write(to: ready, options: .atomic)
            let handle = try FileHandle(forWritingTo: ready)
            try handle.synchronize()
            try handle.close()
        } catch { exit(67) }
        raise(SIGSTOP)
        exit(68) // Resuming rather than killing is not an accepted fixture path.
    }
}
#endif
