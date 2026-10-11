import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings pane for the standard `Settings` scene (⌘,) — System
/// Settings-style grouped forms with toolbar tabs.
struct SettingsView: View {
    @Environment(AppState.self) private var appState

    enum SettingsTab: String, CaseIterable, Identifiable {
        case general
        case library
        case playback
        case subtitles
        case downloads
        case network
        case diagnostics
        case advanced

        var id: RawValue { rawValue }

        var title: String {
            switch self {
            case .general: return "General"
            case .library: return "Library"
            case .playback: return "Playback"
            case .subtitles: return "Subtitles"
            case .downloads: return "Downloads"
            case .network: return "Network"
            case .diagnostics: return "Diagnostics"
            case .advanced: return "Advanced"
            }
        }

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .library: return "books.vertical"
            case .playback: return "play.tv"
            case .subtitles: return "captions.bubble"
            case .downloads: return "arrow.down.circle"
            case .network: return "network"
            case .diagnostics: return "stethoscope"
            case .advanced: return "slider.horizontal.3"
            }
        }
    }

    @State private var selectedTab: SettingsTab = .general
    @State private var showFolderPicker = false
    @State private var cacheClearedAt: Date?
    @State private var cacheBytes: Int64?
    @State private var showProfileManager = false

    var body: some View {
        TabView(selection: $selectedTab) {
            generalTab
                .tabItem { Label(SettingsTab.general.title, systemImage: SettingsTab.general.icon) }
                .tag(SettingsTab.general)

            libraryTab
                .tabItem { Label(SettingsTab.library.title, systemImage: SettingsTab.library.icon) }
                .tag(SettingsTab.library)

            PlaybackSettingsView()
                .tabItem { Label(SettingsTab.playback.title, systemImage: SettingsTab.playback.icon) }
                .tag(SettingsTab.playback)

            SubtitleSettingsView()
                .tabItem { Label(SettingsTab.subtitles.title, systemImage: SettingsTab.subtitles.icon) }
                .tag(SettingsTab.subtitles)

            downloadsTab
                .tabItem { Label(SettingsTab.downloads.title, systemImage: SettingsTab.downloads.icon) }
                .tag(SettingsTab.downloads)

            NetworkSettingsView()
                .tabItem { Label(SettingsTab.network.title, systemImage: SettingsTab.network.icon) }
                .tag(SettingsTab.network)

            DiagnosticsView()
                .tabItem { Label(SettingsTab.diagnostics.title, systemImage: SettingsTab.diagnostics.icon) }
                .tag(SettingsTab.diagnostics)

            advancedTab
                .tabItem { Label(SettingsTab.advanced.title, systemImage: SettingsTab.advanced.icon) }
                .tag(SettingsTab.advanced)
        }
        .frame(width: 640, height: 560)
        // Settings can export the library and manage profiles, so it sits
        // behind the same lock as the main window (ADR-0014).
        .overlay {
            if AppLock.shared.isLocked { LockView() }
        }
        .fileImporter(
            isPresented: $showFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false,
        ) { result in
            if case .success(let urls) = result, let folder = urls.first {
                appState.preferences.downloadDirectory = folder
            }
        }
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Section("Onboarding") {
                LabeledContent("Welcome Tour") {
                    Button("Show Onboarding") {
                        appState.preferences.onboardingComplete = false
                    }
                }
                .help("Review the introduction and initial setup again")
            }

            Section {
                LabeledContent("Profiles") {
                    HStack(spacing: 8) {
                        Text(ProfileStore.shared.profiles.map(\.name).joined(separator: ", "))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Button("Manage…") { showProfileManager = true }
                    }
                }
                Toggle("Require \(AppLock.biometryName) to open CloudStream", isOn: Binding(
                    get: { appState.preferences.requireUnlock },
                    set: { newValue in
                        Task {
                            guard await AppLock.shared.verifyCanEnable() else { return }
                            appState.preferences.requireUnlock = newValue
                        }
                    },
                ))
                Picker("Lock again after", selection: Binding(
                    get: { appState.preferences.lockAfterMinutes },
                    set: { appState.preferences.lockAfterMinutes = $0 },
                )) {
                    Text("Only at launch and sleep").tag(0)
                    ForEach([1, 5, 15, 30, 60], id: \.self) { minutes in
                        Text("\(minutes) min in the background").tag(minutes)
                    }
                }
                .disabled(!appState.preferences.requireUnlock && !ProfileStore.shared.profiles.contains(where: \.requiresUnlock))
            } header: {
                Text("Profiles & Privacy")
            } footer: {
                Text("The lock also applies when the Mac sleeps or you switch users. Locked profiles ask before you switch into them. The lock hides the app; it doesn't encrypt your library.")
                    .foregroundStyle(.secondary)
            }
            .sheet(isPresented: $showProfileManager) { ProfileManagerView() }

            Section {
                @Bindable var preferences = appState.preferences
                Toggle("Back up the library automatically every day", isOn: $preferences.autoBackupEnabled)
                LabeledContent("Last automatic backup") {
                    let _ = preferences.autoBackupRevision
                    Text(preferences.lastAutoBackup(for: ProfileStore.shared.activeID).map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never")
                        .foregroundStyle(.secondary)
                }
                .help("Each profile is backed up once a day while CloudStream is running, including profiles that are not selected.")
                if BackupService.shared.pendingExternalRestore != nil {
                    LabeledContent("Restore") {
                        Button("Finish Restoring Extensions") {
                            Task {
                                do {
                                    let result = try await BackupService.shared.retryExternalRestore(appState: appState)
                                    if result.warnings.isEmpty { appState.presentNotice("Extension setup restored") }
                                    else { appState.presentError(result.warnings.joined(separator: "\n")) }
                                } catch { appState.presentError(error.localizedDescription) }
                            }
                        }
                        .disabled(!appState.isEngineBootstrapped)
                    }
                    .help("Adds the repositories and disabled providers from the last restored backup. Your library is not changed again.")
                }
                HStack {
                    Button("Export Backup…") { BackupService.shared.exportInteractively(appState: appState) }
                        .disabled(BackupService.shared.isRestoring)
                    Button("Import Backup…") { BackupService.shared.importInteractively(appState: appState) }
                        .disabled(BackupService.shared.isRestoring)
                    if BackupService.shared.isRestoring {
                        ProgressView().controlSize(.small)
                        Text("Restoring…").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Show Backups Folder") {
                        let folder = BackupService.shared.backupsDirectory
                        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(folder)
                    }
                }
            } header: {
                Text("Backup")
            } footer: {
                Text("Backups contain your library, watch history, per-show settings, preferences and extension list — never passwords or downloaded files. Import also accepts backups from CloudStream for Android. The last \(BackupService.retainedAutoBackups) automatic backups of each profile are kept.")
                    .foregroundStyle(.secondary)
            }

            Section("System Integration") {
                Toggle("Show titles from your library in Spotlight", isOn: Binding(
                    get: { appState.preferences.indexInSpotlight },
                    set: { enabled in
                        appState.preferences.indexInSpotlight = enabled
                    },
                ))
                if let failure = SpotlightIndexer.shared.lastFailure {
                    Text("Couldn’t update Spotlight: \(failure)").foregroundStyle(.secondary)
                    Button("Retry Spotlight Update") { Task { await SpotlightIndexer.shared.retry() } }
                }
                Toggle("Show CloudStream in the menu bar", isOn: Binding(
                    get: { appState.preferences.showMenuBarExtra },
                    set: { appState.preferences.showMenuBarExtra = $0 },
                ))
                Toggle("Show active downloads on the Dock icon", isOn: Binding(
                    get: { appState.preferences.showDockBadge },
                    set: { appState.preferences.showDockBadge = $0; DockBadge.update() },
                ))
            }

            Section("Maintenance") {
                LabeledContent("Cache") {
                    HStack(spacing: 10) {
                        if let cacheBytes {
                            Text(cacheBytes.formatted(.byteCount(style: .file)))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Button(cacheClearedAt == nil ? "Clear Cache" : "Cleared") {
                            Task { await clearCaches() }
                        }
                        .disabled(cacheClearedAt != nil || cacheBytes == 0)
                    }
                }
                .help("Clears cached posters, artwork and network responses. Downloads and extensions are kept.")
                .task { cacheBytes = await AppCaches.diskUsageBytes() }
            }
        }
        .formStyle(.grouped)
    }

    private func clearCaches() async {
        AppCaches.clearAll()
        cacheClearedAt = Date()
        cacheBytes = await AppCaches.diskUsageBytes()
        try? await Task.sleep(for: .seconds(2))
        cacheClearedAt = nil
    }

    // MARK: - Library

    @State private var confirmClearHistory = false

    private var libraryTab: some View {
        @Bindable var preferences = appState.preferences
        let stats = LibraryStore.shared.readForDisplay(or: LibraryStore.WatchStats(), { try LibraryStore.shared.watchStats() })

        return Form {
            Section {
                Toggle("Update watch status automatically", isOn: $preferences.autoUpdateLibraryStatus)
            } footer: {
                Text("Playing a Plan to Watch title moves it to Watching; finishing every episode moves it to Completed. Titles outside your library are never added.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Check Watching series for new episodes", isOn: $preferences.checkForNewEpisodes)
                Toggle("Notify me about new episodes", isOn: $preferences.notifyNewEpisodes)
                    .disabled(!preferences.checkForNewEpisodes)
                LabeledContent("Check now") {
                    Button("Check") {
                        Task { await EpisodeUpdateChecker.shared.runOnce(appState: appState) }
                    }
                    .disabled(!preferences.checkForNewEpisodes || !appState.isEngineReady)
                }
            } header: {
                Text("New Episodes")
            } footer: {
                Text("Uses your installed providers, a few titles at a time, at most every 6 hours per title.")
                    .foregroundStyle(.secondary)
            }

            Section("Home") {
                Toggle("Show provider homepage (Discover)", isOn: $preferences.showDiscoverOnHome)
            }

            Section("Watch History") {
                LabeledContent("Titles", value: stats.titles.formatted())
                LabeledContent("Episodes watched", value: stats.episodesWatched.formatted())
                LabeledContent("Movies watched", value: stats.moviesWatched.formatted())
                LabeledContent("Time watched", value: Duration.seconds(stats.secondsWatched)
                    .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))
                if stats.unownedEntries > 0 {
                    Text("\(stats.unownedEntries) more entries belong to titles that are no longer stored. Clearing history removes them.")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Clear History") {
                    Button("Clear…", role: .destructive) { confirmClearHistory = true }
                        .disabled(stats.titles == 0 && stats.unownedEntries == 0)
                }
                .help("Removes every resume position and watched mark. Library lists and favorites are kept.")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Clear all watch history?", isPresented: $confirmClearHistory) {
            Button("Clear History", role: .destructive) { LibraryStore.shared.perform { try LibraryStore.shared.clearAllWatchHistory() } }
        } message: {
            Text("Resume positions and watched marks for every title are removed. This can't be undone.")
        }
    }

    // MARK: - Downloads

    private var downloadsTab: some View {
        Form {
            Section("Storage Destination") {
                LabeledContent("Download Folder") {
                    Button("Choose…") {
                        showFolderPicker = true
                    }
                }

                LabeledContent {
                    EmptyView()
                } label: {
                    Text(appState.preferences.downloadDirectory.path)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }

            Section {
                @Bindable var preferences = appState.preferences
                Stepper(
                    "Simultaneous downloads: \(preferences.maxConcurrentDownloads)",
                    value: $preferences.maxConcurrentDownloads,
                    in: UserPreferences.downloadConcurrencyRange,
                )
                Stepper(
                    "Per provider: \(preferences.maxDownloadsPerProvider)",
                    value: $preferences.maxDownloadsPerProvider,
                    in: UserPreferences.downloadConcurrencyRange,
                )
                .help("Limits parallel downloads from one provider so its hosts don't rate-limit you")
                Picker("Download quality", selection: $preferences.preferredQuality) {
                    Text("Best available").tag(0)
                    Text("2160p").tag(2160)
                    Text("1080p").tag(1080)
                    Text("720p").tag(720)
                    Text("480p").tag(480)
                    Text("360p").tag(360)
                }
                .help("Picks the closest quality at or below this; other mirrors remain as fallbacks")
            } header: {
                Text("Transfers")
            } footer: {
                Text("Subtitles in your subtitle language (\(appState.preferences.subtitleLanguage)) are saved next to each download.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Advanced

    private var advancedTab: some View {
        Form {
            Section("Engine") {
                LabeledContent("Daemon Version") {
                    Text(appState.daemonVersion ?? "Not connected")
                        .font(.body.monospaced())
                }

                LabeledContent("Active Providers Loaded") {
                    Text("\(appState.providers.count)")
                        .font(.body.monospacedDigit())
                }

                LabeledContent("Restart Scraper Engine") {
                    Button("Restart") {
                        DaemonSupervisor.shared.restart()
                    }
                }
                .help("Terminates and restarts the background helper process")

                LabeledContent("Extension Safe Mode") {
                    Button("Restart in Safe Mode") {
                        appState.restartEngine(safeMode: true)
                    }
                }
                .help("Restarts the engine without loading any extension, so a misbehaving one can be disabled or uninstalled. You can also hold ⌥ while CloudStream opens.")

                if appState.extensions.settings.developerModeAllowed {
                    Toggle("Developer mode: install extensions from files", isOn: Binding(
                        get: { appState.extensions.settings.developerMode },
                        set: { value in Task { await appState.extensions.setDeveloperMode(value) } }
                    ))
                    .disabled(!appState.isEngineReady)
                    .help("Adds Install from File… to Extensions. Local extensions are not verified by any repository, start disabled, and stop loading when this is turned off.")
                }

                LabeledContent("Diagnostics") {
                    Button("Export Diagnostics…") {
                        Task {
                            if let message = await DiagnosticsExporter.export(appState: appState) {
                                appState.presentError(message)
                            }
                        }
                    }
                }
                .help("Saves a support file with your extension setup and recent engine events. Passwords, cookies and tokens are removed.")
            }
        }
        .formStyle(.grouped)
    }
}
