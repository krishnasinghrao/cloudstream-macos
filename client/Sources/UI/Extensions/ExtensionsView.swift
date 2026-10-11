import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ExtensionsView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var windowSession
    @State private var selectedTab: ExtensionTab = .installed
    @State private var query = ""
    @State private var showAddRepoSheet = false
    @State private var repoURLInput = ""
    @State private var repoPendingRemoval: RepositoryDto?
    @State private var pluginPendingRemoval: PluginDto?
    @State private var selectedRepoForBrowse: RepositoryDto?
    @State private var repoPendingConsent: RepositoryDto?
    @State private var repoPendingReTrust: RepositoryDto?
    @State private var pluginForSettings: PluginDto?
    @State private var pluginForPreferences: PluginDto?

    enum ExtensionTab: String, CaseIterable, Identifiable {
        case installed = "Installed"
        case repositories = "Repositories"
        var id: String { rawValue }
    }

    private var store: ExtensionsStore { appState.extensions }
    private var installed: [PluginDto] {
        store.plugins.filter { query.isEmpty || ($0.name + " " + $0.providers.joined(separator: " ")).localizedStandardContains(query) }
    }
    private var repositories: [RepositoryDto] {
        store.repositories.filter { query.isEmpty || ($0.name + " " + $0.url).localizedStandardContains(query) }
    }
    private var canAddRepositories: Bool { store.settings.allowUserRepositories }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // Banners keep their natural height when they fit; several at once
            // (safe mode, policy, legacy, errors) scroll within a bounded area.
            ViewThatFits(in: .vertical) {
                VStack(spacing: 0) { banners }
                ScrollView { VStack(spacing: 0) { banners } }.frame(maxHeight: 220)
            }
            Group {
                switch selectedTab {
                case .installed: installedContent
                case .repositories: repositoryContent
                }
            }
            // minHeight 0: this column must never demand more height than the
            // window has. With .contentMinSize, a large minimum here grows the
            // window past the screen and shifts the whole UI (sidebar included) up.
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        }
        .sheet(isPresented: $showAddRepoSheet) {
            AddRepositorySheet(store: store, initialURL: repoURLInput, engineReady: appState.isEngineReady)
        }
        .sheet(item: $selectedRepoForBrowse) { repo in
            RepositoryCatalogSheet(repo: repo, store: store, engineReady: appState.isEngineReady,
                                   requestConsent: { repoPendingConsent = $0 })
        }
        .confirmationDialog("Uninstall “\(pluginPendingRemoval?.name ?? "")”?", isPresented: Binding(
            get: { pluginPendingRemoval != nil }, set: { if !$0 { pluginPendingRemoval = nil } }
        ), titleVisibility: .visible) {
            Button("Uninstall Extension", role: .destructive) {
                if let plugin = pluginPendingRemoval { Task { await store.uninstall(plugin) } }
                pluginPendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pluginPendingRemoval = nil }
        } message: {
            Text("Its saved settings are deleted. You can reinstall it from its repository.")
        }
        .confirmationDialog("Remove repository “\(repoPendingRemoval?.name ?? "")”?", isPresented: Binding(
            get: { repoPendingRemoval != nil }, set: { if !$0 { repoPendingRemoval = nil } }
        ), titleVisibility: .visible) {
            if let repo = repoPendingRemoval, repo.installedCount > 0 {
                Button("Remove Repository and \(repo.installedCount) Extension\(repo.installedCount == 1 ? "" : "s")", role: .destructive) {
                    Task { await store.removeRepository(repo, removeExtensions: true) }
                    repoPendingRemoval = nil
                }
                Button("Remove Repository, Keep Extensions") {
                    Task { await store.removeRepository(repo, removeExtensions: false) }
                    repoPendingRemoval = nil
                }
            } else {
                Button("Remove Repository", role: .destructive) {
                    if let repo = repoPendingRemoval { Task { await store.removeRepository(repo, removeExtensions: true) } }
                    repoPendingRemoval = nil
                }
            }
            Button("Cancel", role: .cancel) { repoPendingRemoval = nil }
        } message: {
            Text("Kept extensions keep working but no longer receive updates.")
        }
        .confirmationDialog("Allow installs from “\(repoPendingConsent?.name ?? "")”?", isPresented: Binding(
            get: { repoPendingConsent != nil }, set: { if !$0 { repoPendingConsent = nil } }
        ), titleVisibility: .visible) {
            Button("Allow Installs") {
                if let repo = repoPendingConsent { Task { await store.setConsent(true, for: repo) } }
                repoPendingConsent = nil
            }
            Button("Cancel", role: .cancel) { repoPendingConsent = nil }
        } message: {
            if repoPendingConsent?.tier == "signed" {
                Text("This repository's catalog is signed, and CloudStream will only accept catalogs signed by the same key (\(repoPendingConsent?.keyFingerprint ?? "unknown")). A signature shows who holds the key, not who the publisher is: anyone can create a key and sign a catalog. Extensions run code on this Mac. Only allow repositories you trust.")
            } else {
                Text("This is a community repository: its catalog is not signed by a publisher key. CloudStream checks a publisher digest when one is provided. Otherwise, it records the downloaded bytes locally; this confirms the bytes used on this Mac and does not verify their publisher. Extensions run code on this Mac. Only allow repositories you trust.")
            }
        }
        .sheet(item: $repoPendingReTrust) { repo in
            ReTrustSheet(repo: repo, store: store)
        }
        .sheet(item: $pluginForPreferences) { plugin in
            ExtensionPreferencesSheet(plugin: plugin)
        }
        .sheet(item: $pluginForSettings) { plugin in
            ProviderSettingsSheet(plugin: plugin)
        }
        .task(id: appState.isEngineReady) {
            if appState.isEngineReady { await appState.bootstrap() }
        }
        .onAppear(perform: consumePendingRepository)
        .onChange(of: windowSession.pendingRepoAdd) { _, _ in consumePendingRepository() }
        .onChange(of: selectedTab) { _, _ in query = "" }
    }

    // MARK: Header & banners

    private var header: some View {
        HStack(spacing: 12) {
            Picker("Section", selection: $selectedTab) {
                ForEach(ExtensionTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            TextField(selectedTab == .installed ? "Filter extensions" : "Filter repositories", text: $query)
                .textFieldStyle(.roundedBorder).frame(minWidth: 160, maxWidth: 260)
                .accessibilityLabel(selectedTab == .installed ? "Filter extensions" : "Filter repositories")
            Spacer(minLength: 12)
            if !store.pendingUpdates.isEmpty {
                Button("Update All (\(store.pendingUpdates.count))", systemImage: "arrow.down.circle") {
                    Task { await store.updateAll() }
                }
                .help("Install every available extension update")
                .disabled(!appState.isEngineReady || store.isBusy("update-all"))
            }
            if store.settings.developerMode {
                Button("Install from File…", systemImage: "doc.badge.plus") { installFromFile() }
                    .help("Developer mode: install a local .cs3 extension (it starts disabled)")
                    .disabled(!appState.isEngineReady || store.isBusy("developer-install"))
            }
            if selectedTab == .repositories && !store.repositories.isEmpty {
                Button("Sync All", systemImage: "arrow.triangle.2.circlepath") {
                    Task { await store.syncAll() }
                }
                .help("Download the latest catalog from every repository")
                .disabled(!appState.isEngineReady || store.isBusy("sync-all"))
            }
            Button {
                Task { await store.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Reload saved repositories and installed extensions")
            .disabled(store.isRefreshing || !appState.isEngineReady)
            .overlay(alignment: .leading) {
                if store.isRefreshing { ProgressView().controlSize(.mini).offset(x: -20) }
            }
            Button("Add Repository", systemImage: "plus") {
                repoURLInput = ""
                store.operationError = nil
                showAddRepoSheet = true
            }
            .buttonStyle(.borderedProminent)
            .help(canAddRepositories ? "Add a repository by URL or shortcode" : "Your organization manages the repository list")
            .disabled(!appState.isEngineReady || store.isAddingRepository || !canAddRepositories)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private func installFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cs3") ?? .data]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a CloudStream extension (.cs3). It is installed disabled; enable it when you are ready."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        selectedTab = .installed
        Task { await store.installExtensionFile(url) }
    }

    @ViewBuilder private var banners: some View {
        if !appState.isEngineReady {
            InfoBanner(systemImage: "network", text: "Waiting for the extension engine…")
        } else if let restore = appState.engineHealth?.extensions, restore.phase == "restoring" {
            InfoBanner(systemImage: "hourglass", text: "Starting installed extensions…")
        }
        if appState.isEngineReady, let reason = appState.engineHealth?.isolation?.warning {
            InfoBanner(systemImage: "exclamationmark.shield", tint: .orange,
                       text: "Extensions are running without the macOS sandbox. \(reason) Extension code can access your files.")
        }
        if store.settings.safeMode {
            InfoBanner(systemImage: "shield.lefthalf.filled", tint: .orange,
                       text: "Safe mode is on: no extension code is loaded. You can still update, disable or uninstall extensions.",
                       actionTitle: "Restart Normally") { appState.restartEngine(safeMode: false) }
        }
        if store.settings.policyManaged {
            InfoBanner(systemImage: "building.2", text: "Some extension settings are managed by your organization.")
        }
        if store.settings.legacyArtifactsPending > 0 {
            InfoBanner(systemImage: "clock.arrow.circlepath",
                       text: "\(store.settings.legacyArtifactsPending) extension\(store.settings.legacyArtifactsPending == 1 ? "" : "s") from an earlier version will be restored after its repository syncs. Sync your repositories, or reinstall them from the catalog.",
                       actionTitle: "Dismiss") { Task { await store.dismissLegacyExtensions() } }
        }
        if let error = store.operationError {
            ExtensionErrorBanner(message: error) { store.operationError = nil }
        }
        if let error = store.refreshError {
            ExtensionErrorBanner(message: error) { store.refreshError = nil }
        }
        if store.isAddingRepository {
            HStack {
                ProgressView().controlSize(.small)
                Text("Adding repository…").font(.callout)
                Spacer()
            }.padding(12)
        }
    }

    // MARK: Installed

    @ViewBuilder private var installedContent: some View {
        if store.plugins.isEmpty && store.isRefreshing {
            LoadingView("Loading installed extensions…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.plugins.isEmpty {
            ContentUnavailableView {
                Label("No Extensions Installed", systemImage: "puzzlepiece.extension")
            } description: {
                Text("Browse a repository and install the extensions you want to use.")
            } actions: {
                Button("Browse Repositories") { selectedTab = .repositories }
                    .buttonStyle(.borderedProminent)
            }
        } else if installed.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            List {
                Section("\(store.plugins.count) installed") {
                    ForEach(installed) { plugin in
                        InstalledExtensionRow(plugin: plugin, store: store, engineReady: appState.isEngineReady,
                                              remove: { pluginPendingRemoval = plugin },
                                              settings: { pluginForSettings = plugin },
                                              preferences: { pluginForPreferences = plugin })
                    }
                }
                Section("Updates") {
                    Toggle("Update extensions automatically", isOn: Binding(
                        get: { store.settings.autoUpdate },
                        set: { value in Task { await store.setAutoUpdate(value) } }
                    ))
                    .disabled(!appState.isEngineReady || store.settings.autoUpdateManaged || store.isBusy("settings"))
                    .help(store.settings.autoUpdateManaged ? "Managed by your organization" : "Checks repositories shortly after launch, every six hours and on each sync. Updates keep the previous version for one-click rollback")
                }
            }.listStyle(.inset)
        }
    }

    // MARK: Repositories

    private var repositoryContent: some View {
        List {
            Section("Configured Repositories") {
                if store.repositories.isEmpty {
                    Text(store.isRefreshing ? "Loading saved repositories…" : "Add a repository to browse its extensions.")
                        .foregroundStyle(.secondary).padding(.vertical, 12)
                } else if repositories.isEmpty {
                    Text("No repositories match “\(query)”.").foregroundStyle(.secondary)
                }
                ForEach(repositories) { repo in
                    RepositoryRow(repo: repo, store: store, engineReady: appState.isEngineReady,
                                  browse: { selectedRepoForBrowse = repo },
                                  remove: { repoPendingRemoval = repo },
                                  consent: { repoPendingConsent = repo },
                                  reTrust: { repoPendingReTrust = repo })
                }
            }

        }.listStyle(.inset)
    }

    private func consumePendingRepository() {
        guard let pending = windowSession.pendingRepoAdd else { return }
        repoURLInput = pending
        windowSession.pendingRepoAdd = nil
        showAddRepoSheet = true
    }
}

// MARK: - Rows

private struct StatusChip: View {
    let text: String
    let tint: Color
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

private struct TierBadge: View {
    let tier: String?
    var body: some View {
        if tier == "verified" {
            Label("Verified", systemImage: "checkmark.seal.fill")
                .font(.caption2.weight(.semibold)).foregroundStyle(.green)
                .help("Signed with a publisher key your organization approved")
                .accessibilityLabel("Verified repository")
        } else if tier == "signed" {
            Label("Signed", systemImage: "signature")
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .help("Signed catalog: only catalogs signed with the same key are accepted. The signature does not identify the publisher; check the key fingerprint.")
                .accessibilityLabel("Signed repository")
        } else if tier == "developer" {
            Label("Developer", systemImage: "hammer")
                .font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                .help("Installed from a local file in developer mode; not verified by any repository")
                .accessibilityLabel("Developer extension")
        } else if tier == "community" {
            Label("Community", systemImage: "person.2")
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .help("Unsigned catalog: publisher digests are checked when provided; other downloads have a local byte record")
                .accessibilityLabel("Community repository")
        }
    }
}

private struct InstalledExtensionRow: View {
    let plugin: PluginDto
    let store: ExtensionsStore
    let engineReady: Bool
    let remove: () -> Void
    let settings: () -> Void
    let preferences: () -> Void

    private var needsVPN: Bool {
        DiscoverStore.shared.providers.contains { plugin.providers.contains($0.name) && $0.needsVPN }
    }
    private var busy: Bool { store.isBusy(plugin.id) }

    private var chip: (String, Color)? {
        switch plugin.runState {
        case "running": return nil
        case "ready": return ("Ready", .secondary)
        case "starting": return ("Starting", .secondary)
        case "disabled": return ("Disabled", .secondary)
        case "failed": return ("Failed", .orange)
        case "revoked": return ("Disabled by publisher", .red)
        case "quarantined": return ("Quarantined", .red)
        case "safe_mode": return ("Safe mode", .orange)
        default: return (plugin.runState.capitalized, .secondary)
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "puzzlepiece.extension").font(.title2).foregroundStyle(.secondary).frame(width: 30).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(plugin.name).font(.headline)
                    if let version = ExtensionVersion.label(plugin.version) { Text(version).font(.caption.monospaced()).foregroundStyle(.secondary) }
                    TierBadge(tier: plugin.tier)
                    if let chip { StatusChip(text: chip.0, tint: chip.1) }
                    if let language = plugin.language, !language.isEmpty {
                        StatusChip(text: language.uppercased(), tint: .secondary).help("Content language")
                    }
                    if needsVPN {
                        Label("VPN", systemImage: "lock.shield")
                            .font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                            .help("This provider may require a VPN in some regions")
                    }
                }
                if let error = plugin.lastError, !error.isEmpty, !plugin.isOperational {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange).lineLimit(3).help(error)
                }
                Text(plugin.isExtractorOnly ? "Extractor extension" : plugin.providers.joined(separator: ", "))
                    .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                if plugin.updateAvailable == true, let available = plugin.availableVersion {
                    Text("Version \(available) is available").font(.caption).foregroundStyle(.blue)
                }
                if plugin.repositoryPresent == false {
                    Text("Its repository was removed; this extension no longer receives updates.").font(.caption).foregroundStyle(.secondary)
                } else if plugin.missingFromCatalog == true {
                    Text("No longer listed by its repository.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(plugin.sharedProviderNames ?? [], id: \.self) { shared in
                    Label("“\(shared.provider)” is also provided by \(shared.alsoIn.map { "“\($0)”" }.formatted(.list(type: .and)))",
                          systemImage: "square.on.square")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        .help("Titles saved with only a provider name can't tell these apart. In the Library, Control-click such a title and choose Choose Provider….")
                }
                if let features = plugin.unsupportedFeatures, !features.isEmpty {
                    Text("Not available on Mac: \(features.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                }
                if let compatibility = plugin.compatibility, compatibility.hasCoreGaps {
                    Text("Some features may not work on Mac")
                        .font(.caption).foregroundStyle(.secondary)
                        .help("This extension uses Android features the Mac engine does not provide. Parts that rely on them fail when used: "
                              + compatibility.coreCode.map { symbol in
                                  // Members arrive as "Class.member()"; types as dotted names, shown by their last part.
                                  symbol.hasSuffix("()") ? symbol : symbol.split(separator: ".").last.map(String.init) ?? symbol
                              }.joined(separator: ", "))
                }
                if plugin.isOperational, let failure = plugin.latestFailure {
                    Label("\(failure.stageLabel) failed for \(failure.provider): \(failure.message ?? "unknown error")",
                          systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.orange).lineLimit(2)
                        .help(failure.message ?? failure.code ?? "")
                }
                if let activity = store.pluginActivities[plugin.id] {
                    Text(activity).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            if plugin.updateAvailable == true {
                Button("Update") { Task { await store.update(plugin) } }
                    .disabled(!engineReady || busy)
            }
            if ["failed", "quarantined", "starting"].contains(plugin.runState) {
                Button("Retry") { Task { await store.retry(plugin) } }
                    .help("Load this extension again")
                    .disabled(!engineReady || busy)
            }
            Toggle("Enable \(plugin.name)", isOn: Binding(
                get: { store.pendingEnabled[plugin.id] ?? plugin.enabled },
                set: { enabled in Task { await store.setEnabled(enabled, plugin: plugin) } }
            ))
            .toggleStyle(.switch).controlSize(.small).labelsHidden()
            .help(plugin.enabled ? "Disable \(plugin.name)" : "Enable \(plugin.name)")
            .disabled(!engineReady || busy || plugin.runState == "revoked")
            Menu {
                if let previous = plugin.previousVersion {
                    Button(ExtensionVersion.label(previous).map { "Restore Previous Version (\($0))" } ?? "Restore Previous Version") {
                        Task { await store.rollback(plugin) }
                    }
                }
                if !plugin.isExtractorOnly {
                    Button("Provider Settings…", action: settings)
                }
                if plugin.isOperational {
                    Button("Extension Settings…", action: preferences)
                }
                if !plugin.isExtractorOnly, plugin.isOperational {
                    Button("Test This Extension") { Task { await store.diagnose(plugin) } }
                        .help("Runs home page, search, details and video links for each of its providers")
                }
                if plugin.canRecheck {
                    // No publisher digest: only downloading again shows whether the file changed.
                    Button("Check for Changes") { Task { await store.recheck(plugin) } }
                }
                Text(plugin.verificationLabel)
                if let hash = plugin.sha256 {
                    Button("Copy SHA-256") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(hash, forType: .string)
                    }
                }
                Divider()
                Button("Uninstall…", role: .destructive, action: remove)
            } label: {
                Label("More actions for \(plugin.name)", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton).fixedSize()
            .disabled(!engineReady || busy)
        }.padding(.vertical, 8)
    }
}

private struct RepositoryRow: View {
    let repo: RepositoryDto
    let store: ExtensionsStore
    let engineReady: Bool
    let browse: () -> Void
    let remove: () -> Void
    let consent: () -> Void
    let reTrust: () -> Void

    private var busy: Bool { store.repositoryActivities[repo.url] != nil }

    private var syncSummary: String {
        if let activity = store.repositoryActivities[repo.url] { return activity }
        var parts = ["\(repo.pluginCount) extensions"]
        if repo.installedCount > 0 { parts.append("\(repo.installedCount) installed") }
        if let synced = repo.lastSyncedAt {
            let date = Date(timeIntervalSince1970: TimeInterval(synced) / 1000)
            parts.append("synced \(date.formatted(.relative(presentation: .named)))")
        } else {
            parts.append("never synced")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "folder.badge.gearshape").font(.title2).foregroundStyle(.secondary).frame(width: 30).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(repo.name).font(.headline)
                    TierBadge(tier: repo.tier)
                    if !repo.allowedByPolicy { StatusChip(text: "Blocked by policy", tint: .red) }
                    if repo.consentRequired && repo.consented { StatusChip(text: "Installs allowed", tint: .secondary) }
                }
                Text(repo.url).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(repo.url).textSelection(.enabled)
                Text(syncSummary).font(.caption).foregroundStyle(.secondary)
                if let error = repo.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange).lineLimit(3).help(error)
                }
                if let fingerprint = repo.keyFingerprint {
                    Text("Key \(fingerprint)").font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1).textSelection(.enabled)
                }
            }
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            if repo.consentRequired && !repo.consented && repo.allowedByPolicy {
                Button("Allow Installs…", action: consent).disabled(!engineReady || busy)
            }
            Button("Browse", action: browse).disabled(!engineReady)
            Button {
                Task { await store.syncRepository(repo) }
            } label: {
                Label("Sync \(repo.name)", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
            }
            .help("Fetch the latest catalog for \(repo.name)")
            .disabled(!engineReady || busy)
            Menu {
                if repo.keyFingerprint != nil {
                    Button("Trust New Signing Key…", action: reTrust)
                }
                if repo.consentRequired && repo.consented {
                    Button("Stop Allowing Installs") { Task { await store.setConsent(false, for: repo) } }
                }
                Divider()
                Button("Remove Repository…", role: .destructive, action: remove)
            } label: {
                Label("More actions for \(repo.name)", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton).fixedSize()
            .disabled(!engineReady || busy || store.isAddingRepository)
        }.padding(.vertical, 8)
    }
}

/// Key rotation needs an explicit, informed decision: the user compares the
/// pinned fingerprint with the one the publisher announced out of band.
private struct ReTrustSheet: View {
    @Environment(\.dismiss) private var dismiss
    let repo: RepositoryDto
    let store: ExtensionsStore
    @State private var confirmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Trust a New Signing Key?").font(.title2.weight(.semibold))
            Text("“\(repo.name)” is pinned to the key below. Continue only if the publisher announced a key change through a channel you trust. The new key is verified with a complete signed catalog before it replaces the old one; if anything fails, the old key stays pinned.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let fingerprint = repo.keyFingerprint {
                LabeledContent("Current key") { Text(fingerprint).font(.caption.monospaced()).textSelection(.enabled) }
            }
            Text("Installed extensions whose files are unchanged are re-verified under the new key. Others are disabled until you update them.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("I verified the publisher's new key", isOn: $confirmed)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Trust New Key") {
                    Task { await store.reTrust(repo); dismiss() }
                }
                .buttonStyle(.borderedProminent).disabled(!confirmed)
            }
        }.padding(24).frame(width: 520)
    }
}

private struct AddRepositorySheet: View {
    @Environment(\.dismiss) private var dismiss
    let store: ExtensionsStore
    let engineReady: Bool
    @State private var url: String

    init(store: ExtensionsStore, initialURL: String, engineReady: Bool) {
        self.store = store
        self.engineReady = engineReady
        _url = State(initialValue: initialURL)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Repository").font(.title2.weight(.semibold))
            Text("Enter a repository URL or shortcode, then browse its catalog to choose extensions. Unsigned (community) repositories ask for your permission before anything is installed.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("https://…/repo.json or shortcode", text: $url)
                .textFieldStyle(.roundedBorder).onSubmit(add)
                .disabled(store.isAddingRepository)
            if let error = store.operationError {
                ExtensionErrorBanner(message: error) { store.operationError = nil }
            }
            if !engineReady { Text("Waiting for the extension engine…").foregroundStyle(.secondary) }
            HStack {
                if store.isAddingRepository {
                    ProgressView().controlSize(.small)
                    Text("Adding repository…").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(store.isAddingRepository ? "Close" : "Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add Repository", action: add).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(store.isAddingRepository || !engineReady || url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 480)
    }

    private func add() {
        let target = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, engineReady, !store.isAddingRepository else { return }
        Task { if await store.addRepository(target) { dismiss() } }
    }
}

// MARK: - Catalog

private struct RepositoryCatalogSheet: View {
    @Environment(\.dismiss) private var dismiss
    let repo: RepositoryDto
    let store: ExtensionsStore
    let engineReady: Bool
    let requestConsent: (RepositoryDto) -> Void
    @State private var catalog = RepositoryCatalogStore()
    @State private var query = ""
    @State private var tvType = ""
    @State private var language = ""
    @State private var sortByName = false
    @State private var retry = 0
    @State private var detailPlugin: RepoPluginDto?

    private var currentRepo: RepositoryDto { store.repositories.first { $0.url == repo.url } ?? repo }
    private var tvTypes: [String] { Array(Set(catalog.plugins.flatMap(\.tvTypes))).sorted() }
    private var languages: [String] { Array(Set(catalog.plugins.compactMap(\.language).filter { !$0.isEmpty })).sorted() }

    private var filtered: [RepoPluginDto] {
        let matches = catalog.plugins.filter { plugin in
            (query.isEmpty || (plugin.name + " " + (plugin.description ?? "") + " " + plugin.authors.joined(separator: " ")).localizedStandardContains(query))
                && (tvType.isEmpty || plugin.tvTypes.contains(tvType))
                && (language.isEmpty || plugin.language == language)
        }
        return sortByName ? matches.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } : matches
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(currentRepo.name).font(.title2.weight(.semibold))
                        TierBadge(tier: currentRepo.tier)
                    }
                    Text("\(catalog.plugins.count) extensions").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if catalog.isLoading { ProgressView().controlSize(.small) }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if currentRepo.consentRequired && !currentRepo.consented && currentRepo.allowedByPolicy {
                InfoBanner(systemImage: currentRepo.tier == "signed" ? "signature" : "person.2",
                           text: currentRepo.tier == "signed"
                               ? "This repository is signed by a key your organization has not approved. Allow installs to choose extensions from it."
                               : "This community repository is not signed. Allow installs to choose extensions from it.",
                           actionTitle: "Allow Installs…") { requestConsent(currentRepo) }
            }
            HStack {
                TextField("Filter by name, description or author", text: $query).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Filter catalog")
                Picker("Type", selection: $tvType) {
                    Text("All Types").tag("")
                    ForEach(tvTypes, id: \.self) { Text($0).tag($0) }
                }.fixedSize()
                Picker("Language", selection: $language) {
                    Text("All Languages").tag("")
                    ForEach(languages, id: \.self) { Text($0.uppercased()).tag($0) }
                }.fixedSize()
                Picker("Sort", selection: $sortByName) {
                    Text("Catalog Order").tag(false)
                    Text("Name").tag(true)
                }.fixedSize()
            }
            if let error = catalog.error {
                HStack(alignment: .top) {
                    Label(error, systemImage: "exclamationmark.triangle").font(.callout).textSelection(.enabled)
                    Spacer()
                    Button("Retry") { retry += 1 }.disabled(!engineReady || catalog.isLoading)
                }
            }
            if let error = store.operationError {
                ExtensionErrorBanner(message: error) { store.operationError = nil }
            }
            if !engineReady {
                Label("Waiting for the extension engine…", systemImage: "network").foregroundStyle(.secondary)
            }
            if catalog.plugins.isEmpty && catalog.isLoading {
                LoadingView("Loading catalog…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if catalog.plugins.isEmpty && catalog.error != nil {
                ContentUnavailableView("Catalog Unavailable", systemImage: "network", description: Text("Retry when the engine is available."))
            } else if filtered.isEmpty {
                ContentUnavailableView(query.isEmpty && tvType.isEmpty && language.isEmpty ? "No Extensions" : "No Matches",
                                       systemImage: "puzzlepiece.extension",
                                       description: Text(query.isEmpty ? "This repository has no available extensions." : "Try another search."))
            } else {
                List(filtered, id: \.catalogID) { plugin in
                    CatalogExtensionRow(plugin: plugin, store: store, engineReady: engineReady,
                                        showDetails: { detailPlugin = plugin }, requestConsent: { requestConsent(currentRepo) })
                }.listStyle(.inset)
            }
        }
        .padding(22).frame(width: 720, height: 580)
        .sheet(item: $detailPlugin) { plugin in CatalogDetailSheet(plugin: plugin) }
        .task(id: "\(repo.url)|\(store.catalogRevision)|\(retry)|\(engineReady)") {
            if engineReady { await catalog.load(repoURL: repo.url) }
        }
    }
}

private struct CatalogExtensionRow: View {
    let plugin: RepoPluginDto
    let store: ExtensionsStore
    let engineReady: Bool
    let showDetails: () -> Void
    let requestConsent: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(plugin.name).font(.headline)
                    if let version = ExtensionVersion.label(plugin.version) { Text(version).font(.caption.monospaced()).foregroundStyle(.secondary) }
                    if let language = plugin.language, !language.isEmpty { StatusChip(text: language.uppercased(), tint: .secondary) }
                    if plugin.status == 2 { StatusChip(text: "Slow", tint: .orange) }
                    if plugin.status == 3 {
                        StatusChip(text: "Beta", tint: .purple)
                            .help("The publisher marks this extension as a beta: it may be incomplete or change often.")
                    }
                }
                if let description = plugin.description, !description.isEmpty {
                    Text(description).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                if plugin.isUpdateAvailable, let installed = plugin.installedVersion {
                    Text("Installed v\(installed) · update available").font(.caption).foregroundStyle(.blue)
                } else if plugin.updateState == "older_in_catalog" {
                    Text("The catalog lists an older version than the one installed").font(.caption).foregroundStyle(.secondary)
                }
                if let reason = plugin.installationBlockedReason, !plugin.isInstalled, plugin.requiresConsent != true {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button { showDetails() } label: { Label("Details for \(plugin.name)", systemImage: "info.circle").labelStyle(.iconOnly) }
                .buttonStyle(.borderless)
            if let activity = store.pluginActivities[plugin.catalogID] {
                ProgressView().controlSize(.small)
                Text(activity).font(.callout).foregroundStyle(.secondary)
            } else if plugin.isInstalled && plugin.isUpdateAvailable && plugin.installationAllowed == true {
                Button("Update") { Task { await store.install(plugin) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!engineReady || store.isBusy(plugin.installationId ?? plugin.catalogID))
            } else if plugin.isInstalled {
                Label("Installed", systemImage: "checkmark").font(.callout).foregroundStyle(.secondary)
            } else if plugin.requiresConsent == true {
                Button("Allow Installs…", action: requestConsent).disabled(!engineReady)
            } else if plugin.installationAllowed != true {
                Label("Unavailable", systemImage: "lock").font(.callout).foregroundStyle(.secondary)
                    .help(plugin.installationBlockedReason ?? "")
            } else {
                Button("Install") { Task { await store.install(plugin) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!engineReady || store.isBusy(plugin.catalogID) || store.repositoryActivities[plugin.repositoryUrl] != nil)
            }
        }.padding(.vertical, 6)
    }
}

private struct CatalogDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let plugin: RepoPluginDto

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(plugin.name).font(.title2.weight(.semibold))
                TierBadge(tier: plugin.tier)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let description = plugin.description { Text(description).font(.callout) }
            Form {
                LabeledContent("Version", value: "\(plugin.version)")
                if let installed = plugin.installedVersion { LabeledContent("Installed", value: "\(installed)") }
                if !plugin.authors.isEmpty { LabeledContent("Authors", value: plugin.authors.joined(separator: ", ")) }
                if let language = plugin.language { LabeledContent("Language", value: language) }
                if !plugin.tvTypes.isEmpty { LabeledContent("Content", value: plugin.tvTypes.joined(separator: ", ")) }
                if let size = plugin.fileSize { LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) }
                LabeledContent("Repository") { Text(plugin.repositoryUrl).textSelection(.enabled).lineLimit(2) }
                LabeledContent("Publisher SHA-256") { Text(plugin.fileHash ?? "Not provided; download will be recorded locally").font(.caption.monospaced()).textSelection(.enabled).lineLimit(2) }
                if let reason = plugin.installationBlockedReason { LabeledContent("Status", value: reason) }
            }.formStyle(.grouped)
        }.padding(22).frame(width: 520)
    }
}

// MARK: - Provider settings

/// Per-provider enable state, clone-site URL and credentials for one extension.
private struct ProviderSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let plugin: PluginDto
    @State private var providers: [ProviderInfoDto] = []
    @State private var urls: [String: String] = [:]
    @State private var credentials: [String: String] = [:]
    @State private var status: String?
    @State private var busy = false

    private var ids: [String] { plugin.providerIds ?? plugin.providers.map { "\(plugin.id):\($0)" } }
    /// Shown instead of a stored secret, which never leaves the Keychain.
    private static let storedPlaceholder = "••••••••"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(plugin.name) Settings").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Credentials are stored in your Keychain and sent to the engine in memory only.")
                .font(.callout).foregroundStyle(.secondary)
            Form {
                ForEach(ids, id: \.self) { id in
                    let info = providers.first { $0.providerId == id }
                    Section(info?.name ?? id.components(separatedBy: ":").last ?? id) {
                        if ids.count > 1 {
                            Toggle("Enabled", isOn: Binding(
                                get: { info?.enabled ?? true },
                                set: { value in Task { await setEnabled(id, value) } }
                            )).disabled(busy)
                        }
                        TextField("Site URL", text: Binding(get: { urls[id] ?? info?.mainUrl ?? "" }, set: { urls[id] = $0 }))
                            .textContentType(.URL)
                        SecureField("Credentials (optional)", text: Binding(get: { credentials[id] ?? "" }, set: { credentials[id] = $0 }))
                        HStack {
                            Button("Reset to Defaults") { Task { await reset(id) } }
                            Spacer()
                            Button("Apply") { Task { await apply(id, info: info) } }.buttonStyle(.borderedProminent)
                        }.disabled(busy)
                    }
                }
            }.formStyle(.grouped)
            if let status { Text(status).font(.callout).foregroundStyle(.secondary) }
        }
        .padding(22).frame(width: 540, height: 520)
        .task { await load() }
    }

    private func load() async {
        providers = (try? await DaemonClient.shared.allProviders())?.filter { ids.contains($0.providerId ?? "") } ?? []
        for id in ids where ProviderCredentialStore.credential(for: id) != nil { credentials[id] = Self.storedPlaceholder }
    }

    private func apply(_ id: String, info: ProviderInfoDto?) async {
        busy = true; defer { busy = false }
        // An emptied field is an explicit clear; an untouched one is unchanged.
        let url: ProviderSettingPatch = urls[id].map { entered in
            let trimmed = entered.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? .clear : (trimmed == info?.mainUrl ? .unchanged : .set(trimmed))
        } ?? .unchanged
        let credential: ProviderSettingPatch
        switch credentials[id] {
        case nil, Self.storedPlaceholder?: credential = .unchanged
        case let entered? where entered.isEmpty:
            credential = ProviderCredentialStore.credential(for: id) == nil ? .unchanged : .clear
        case let entered?: credential = .set(entered)
        }
        let outcome = await ProviderConfiguration.apply(providerId: id, url: url, credential: credential)
        status = outcome.message
        // Even a failed attempt may have changed the live provider.
        AppState.shared.providerSettingsChanged()
        if outcome.succeeded { urls[id] = nil; credentials[id] = nil; await load() }
    }

    private func reset(_ id: String) async {
        busy = true; defer { busy = false }
        let outcome = await ProviderConfiguration.apply(providerId: id, reset: true)
        status = outcome.message
        AppState.shared.providerSettingsChanged()
        if outcome.succeeded { credentials[id] = nil; urls[id] = nil; await load() }
    }

    private func setEnabled(_ id: String, _ enabled: Bool) async {
        busy = true; defer { busy = false }
        do {
            try await DaemonClient.shared.setProviderEnabled(providerId: id, enabled: enabled)
            AppState.shared.providerSettingsChanged()
            await load()
        }
        catch { status = ExtensionsStore.message(for: error) }
    }
}

// MARK: - Banners

private struct InfoBanner: View {
    let systemImage: String
    var tint: Color = .secondary
    let text: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage).foregroundStyle(tint).accessibilityHidden(true)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let actionTitle, let action { Button(actionTitle, action: action) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ExtensionErrorBanner: View {
    let message: String
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).accessibilityHidden(true)
            Text(message).font(.callout).textSelection(.enabled)
            Spacer()
            Button(action: dismiss) { Label("Dismiss error", systemImage: "xmark").labelStyle(.iconOnly) }
                .buttonStyle(.plain)
        }.padding(12)
    }
}

