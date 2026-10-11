import AppKit
import CoreSpotlight
import SwiftUI

/// RootView: the main window shell — sidebar + detail stack. Playback lives
/// in its own window (PlayerWindowController), not an overlay here.
struct RootView: View {
    @Environment(AppState.self) private var appState
    @State private var windowSession = WindowSession()
    @State private var showOnboarding = !UserPreferences.shared.onboardingComplete
    /// Height of the title bar + toolbar, so top-trailing banners sit below
    /// the toolbar's search field instead of covering it.
    @State private var toolbarInset: CGFloat = 52

    var body: some View {
        @Bindable var windowSession = windowSession

        // Sidebar is fixed (Apple TV–style): pinned visible, no toggle button,
        // resizable only within a narrow range. SwiftUI alone still lets the divider be dragged shut (with
        // no way back), so SidebarPin also locks the underlying split item.
        NavigationSplitView(columnVisibility: .constant(.all)) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: SidebarPin.minWidth, ideal: SidebarPin.idealWidth, max: SidebarPin.maxWidth)
                .toolbar(removing: .sidebarToggle)
                .background(SidebarPin().frame(width: 0, height: 0))
        } detail: {
            NavigationStack(path: $windowSession.detailPath) {
                detailContent
                    // No screen may raise the window's minimum size: with
                    // .contentMinSize that grows the window past the display and
                    // shifts the whole UI off-screen (seen with safe mode).
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    // Root screens only: pushed title pages have no search
                    // field (their own toolbar actions keep the header height).
                    .globalSearch()
                    .navigationDestination(for: DetailCoordinate.self) { coordinate in
                        DetailsDestinationView(coordinate: coordinate)
                    }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .environment(windowSession)
        .focusedSceneValue(\.windowSession, windowSession)
        .background(WindowSessionAnchor(session: windowSession).frame(width: 0, height: 0))
        .background(ToolbarInsetReader(inset: $toolbarInset).frame(width: 0, height: 0))
        .sheet(isPresented: $windowSession.showShortcuts) { KeyboardShortcutsView() }
        .pageEditing(windowSession)
        .overlay {
            if AppLock.shared.isLocked {
                LockView()
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .topTrailing) {
            // One banner channel for engine failures and one-off action
            // errors surfaced from screens without inline error UI.
            if appState.player.session == nil {
                if let transient = appState.transientError {
                    ErrorBanner(message: transient, isTransient: true) {
                        appState.dismissTransientError()
                    }
                    .padding(.trailing, 16)
                    .padding(.top, toolbarInset + 8)
                    .ignoresSafeArea()
                    .transition(.move(edge: .top).combined(with: .opacity))
                } else if case .error(let message) = appState.daemonState {
                    ErrorBanner(message: "Engine error — \(message)", isTransient: false,
                                actionTitle: "Retry") { DaemonSupervisor.shared.restart() }
                        .padding(.trailing, 16)
                        .padding(.top, toolbarInset + 8)
                        .ignoresSafeArea()
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .overlay(alignment: .topLeading) {
            if !AppLock.shared.isLocked, let failure = LibraryStore.shared.readFailure ?? LibraryStore.shared.pendingProgressFailure ?? LibraryStore.shared.identityMigrationFailure {
                let isIdentityUpdate = LibraryStore.shared.readFailure == nil && LibraryStore.shared.pendingProgressFailure == nil
                VStack(alignment: .leading, spacing: 8) {
                    ErrorBanner(message: isIdentityUpdate ? "Couldn't update the library: \(failure)" : LibraryStore.shared.readFailure == nil
                        ? "Couldn't save playback progress: \(failure)" : "Couldn't load the library: \(failure)", isTransient: false)
                    Button(isIdentityUpdate ? "Retry Library Update" : LibraryStore.shared.readFailure == nil ? "Retry Saving" : "Retry Library") {
                        let profile = ProfileStore.shared.active
                        LibraryStore.shared.perform {
                            if isIdentityUpdate {
                                try LibraryStore.shared.migrateProviderIdentities(providers: LibraryIdentityMigration.catalog(plugins: appState.providers))
                                return
                            }
                            try LibraryStore.shared.flushPendingProgress()
                            if LibraryStore.shared.readFailure != nil {
                                try LibraryStore.shared.retryOpeningStores(profileStoreName: profile.isDefault ? nil : profile.storeName)
                                try DownloadService.shared.retryRestoringQueue()
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(12)
            }
        }
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                if !ConnectivityMonitor.shared.isOnline {
                    OfflineBanner()
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if let notice = appState.transientNotice {
                    Label(notice, systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .accessibilityAddTraits(.isStaticText)
                }
            }
            .padding(.top, 10)
        }
        .animation(.easeInOut(duration: 0.22), value: appState.transientNotice)
        .animation(.easeInOut(duration: 0.22), value: appState.transientError)
        .animation(.easeInOut(duration: 0.22), value: ConnectivityMonitor.shared.isOnline)
        .onOpenURL { url in
            guard !AppLock.shared.isLocked else { return }
            windowSession.handleDeepLink(url)
        }
        // Spotlight result → its title page.
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            guard !AppLock.shared.isLocked else { return }
            guard let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                  let item = LibraryStore.shared.readForDisplay(or: nil, { try LibraryStore.shared.item(id: id) }) else { return }
            windowSession.perform(.openTitle(provider: item.providerName, providerID: item.providerID, url: item.providerURL))
        }
        // Handoff from another Mac.
        .onContinueUserActivity(UserActivityType.viewTitle) { activity in
            guard !AppLock.shared.isLocked else { return }
            guard let provider = activity.userInfo?["provider"] as? String,
                  let url = activity.userInfo?["url"] as? String else { return }
            windowSession.perform(.openTitle(provider: provider, providerID: activity.userInfo?["providerId"] as? String, url: url))
        }
        .sheet(isPresented: $showOnboarding) {
            // Both Choose Extensions and Set Up Later explicitly complete
            // onboarding; neither depends on network or installed providers.
            OnboardingView()
                .environment(windowSession)
                .interactiveDismissDisabled()
        }
        .onChange(of: appState.preferences.onboardingComplete) { _, complete in
            showOnboarding = !complete
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch windowSession.selection {
        case .home:
            HomeView()
                .navigationTitle("Home")
        case .search:
            SearchView()
                .navigationTitle("Search")
        case .watching:
            LibraryView(collection: .watching)
                .navigationTitle("Watching")
        case .planToWatch:
            LibraryView(collection: .planToWatch)
                .navigationTitle("Plan to Watch")
        case .favorites:
            LibraryView(collection: .favorites)
                .navigationTitle("Favorites")
        case .completed:
            LibraryView(collection: .completed)
                .navigationTitle("Completed")
        case .onHold:
            LibraryView(collection: .onHold)
                .navigationTitle("On Hold")
        case .dropped:
            LibraryView(collection: .dropped)
                .navigationTitle("Dropped")
        case .downloaded:
            DownloadsView()
                .navigationTitle("Downloads")
        case .history:
            HistoryView()
                .navigationTitle("History")
        case .extensions:
            ExtensionsView()
                .navigationTitle("Extensions")
        case .page(let id):
            LibraryPageView(pageID: id)
        }
    }
}

/// Destination view for pushed media coordinates on the navigation stack.
struct DetailsDestinationView: View {
    let coordinate: DetailCoordinate
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var windowSession
    @State private var details: DetailsDto?
    @State private var loadError: String?
    @State private var reloadToken = 0

    private func refresh() {
        reloadToken += 1
    }

    var body: some View {
        Group {
            if let details {
                MediaDetailView(details: details, onRefresh: refresh)
            } else if let loadError {
                ContentUnavailableView(
                    "Couldn't Load Details",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError),
                )
                .toolbar {
                    Button("Retry") { reloadToken += 1 }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Windowed, the artwork runs under a transparent toolbar; in full
        // screen the toolbar is solid and the artwork starts below it.
        .ignoresSafeArea(edges: windowSession.isFullScreen ? [] : .top)
        .navigationTitle("")
        .toolbarTitleDisplayMode(.inline)
        .toolbarBackgroundVisibility(windowSession.isFullScreen ? .visible : .hidden, for: .windowToolbar)
        // Details shown from an earlier engine or provider configuration are
        // revalidated as soon as a usable engine can answer.
        .onChange(of: appState.isEngineBootstrapped) { _, usable in
            if usable, appState.detailsAreStale(for: coordinate) { reloadToken += 1 }
        }
        .onChange(of: appState.extensions.providerGeneration) { _, _ in
            if appState.isEngineBootstrapped, appState.detailsAreStale(for: coordinate) { reloadToken += 1 }
        }
        .task(id: reloadToken) {
            loadError = nil
            switch await appState.loadDetails(for: coordinate, refresh: reloadToken > 0 && details != nil) {
            case .success(let loaded):
                details = loaded
                LibraryStore.shared.perform { try LibraryStore.shared.acknowledgeEpisodes(details: loaded) }
            case .failure(let error):
                if details != nil {
                    // A failed reload keeps the page; say why instead of
                    // swapping it for an error screen.
                    appState.presentError("Couldn't reload: \(error.localizedDescription)")
                } else {
                    loadError = error.localizedDescription
                }
            }
        }
    }
}

/// Native macOS sidebar: standard List selection, system badges for counts,
/// and the user's pages in their own section with a + in its header.
struct SidebarView: View {
    @Environment(WindowSession.self) private var windowSession

    /// Observation hooks: selection drives the highlight; the store version
    /// drives the badges (one fetch per render, not six).
    private var counts: LibraryStore.LibraryCounts {
        let _ = LibraryStore.shared.version
        return LibraryStore.shared.readForDisplay(or: LibraryStore.LibraryCounts(), { try LibraryStore.shared.counts() })
    }

    private var pages: [LibraryPageSummary] {
        let _ = LibraryStore.shared.version
        return LibraryStore.shared.readForDisplay(or: [], { try LibraryStore.shared.pages() })
    }

    var body: some View {
        @Bindable var windowSession = windowSession
        let counts = counts
        let pages = pages
        let activeDownloads = DownloadService.shared.totalActiveOrQueuedCount

        List(selection: $windowSession.selection) {
            Section {
                Label("Home", systemImage: "house").tag(AppDestination.home)
                Label("Search", systemImage: "magnifyingglass").tag(AppDestination.search)
            }

            Section("Library") {
                Label("Watching", systemImage: "play.circle").badge(counts.watching).tag(AppDestination.watching)
                Label("Plan to Watch", systemImage: "bookmark").badge(counts.planToWatch).tag(AppDestination.planToWatch)
                Label("Favorites", systemImage: "heart").badge(counts.favorites).tag(AppDestination.favorites)
                Label("Completed", systemImage: "checkmark.circle").badge(counts.completed).tag(AppDestination.completed)
                Label("On Hold", systemImage: "pause.circle").badge(counts.onHold).tag(AppDestination.onHold)
                Label("Dropped", systemImage: "xmark.circle").badge(counts.dropped).tag(AppDestination.dropped)
                Label("Downloaded", systemImage: "arrow.down.circle")
                    .badge(activeDownloads > 0 ? Text("\(activeDownloads)").foregroundStyle(Color.accentColor) : nil)
                    .tag(AppDestination.downloaded)
                Label("History", systemImage: "clock.arrow.circlepath").tag(AppDestination.history)
            }

            Section {
                ForEach(pages) { page in
                    Label(page.name, systemImage: "rectangle.stack")
                        .badge(page.count)
                        .tag(AppDestination.page(page.id))
                        .contextMenu { pageMenu(page) }
                }
                .onMove { source, destination in
                    LibraryStore.shared.perform { try LibraryStore.shared.movePages(fromOffsets: source, toOffset: destination) }
                }
            } header: {
                HStack {
                    Text("Pages")
                    Spacer()
                    Button {
                        windowSession.pageEditor = PageEditorRequest(mode: .create(adding: nil))
                    } label: {
                        Image(systemName: "plus")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // Centres the button over the rows' count badges.
                    .padding(.trailing, 10)
                    .disabled(AppLock.shared.isLocked)
                    .accessibilityLabel("New Page")
                    .help("New Page (⌥⌘N)")
                }
            }

            Section {
                Label("Extensions", systemImage: "puzzlepiece.extension").tag(AppDestination.extensions)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                ProfileSwitcher()
            }
        }
        .onChange(of: windowSession.selection) { _, _ in
            // Same unwind the menu/deep-link paths use via navigateTo:
            // switching sections leaves any pushed details behind.
            windowSession.detailPath.removeAll()
        }
    }

    @ViewBuilder
    private func pageMenu(_ page: LibraryPageSummary) -> some View {
        Button("Rename…") {
            windowSession.pageEditor = PageEditorRequest(mode: .rename(pageID: page.id, currentName: page.name))
        }
        Button("Delete Page…", role: .destructive) { windowSession.pageToDelete = page }
        Divider()
        Button("New Page…") { windowSession.pageEditor = PageEditorRequest(mode: .create(adding: nil)) }
    }
}

/// Locks the sidebar's NSSplitViewItem: not collapsible (by divider drag,
/// window resize or double-click) and a bounded thickness.
struct SidebarPin: NSViewRepresentable {
    static let minWidth: CGFloat = 190
    static let idealWidth: CGFloat = 220
    static let maxWidth: CGFloat = 280

    func makeNSView(context: Context) -> PinView { PinView() }

    func updateNSView(_ view: PinView, context: Context) {
        view.pin()
    }

    final class PinView: NSView {
        private weak var pinned: NSSplitViewItem?
        private var observations: [NSKeyValueObservation] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            pin()
            // The split item may not be attached yet on first layout.
            DispatchQueue.main.async { [weak self] in self?.pin() }
        }

        func pin() {
            var ancestor = superview
            while let view = ancestor, !(view is NSSplitView) { ancestor = view.superview }
            guard let splitView = ancestor as? NSSplitView,
                  let controller = splitView.delegate as? NSSplitViewController,
                  let item = controller.splitViewItems.first(where: { isDescendant(of: $0.viewController.view) })
            else { return }
            enforce(on: item)
            guard pinned !== item else { return }
            pinned = item
            // SwiftUI rewrites these on its own updates (it puts back a 140pt
            // minimum, no maximum, and collapsibility), so re-assert each time.
            let reassert: @Sendable () -> Void = { [weak self] in
                DispatchQueue.main.async {
                    guard let self, let item = self.pinned else { return }
                    self.enforce(on: item)
                }
            }
            observations = [
                item.observe(\.canCollapse) { _, _ in reassert() },
                item.observe(\.isCollapsed) { _, _ in reassert() },
                item.observe(\.minimumThickness) { _, _ in reassert() },
                item.observe(\.maximumThickness) { _, _ in reassert() },
            ]
        }

        private func enforce(on item: NSSplitViewItem) {
            if item.canCollapse { item.canCollapse = false }
            if item.canCollapseFromWindowResize { item.canCollapseFromWindowResize = false }
            if item.minimumThickness != SidebarPin.minWidth { item.minimumThickness = SidebarPin.minWidth }
            if item.maximumThickness != SidebarPin.maxWidth { item.maximumThickness = SidebarPin.maxWidth }
            if item.isCollapsed { item.isCollapsed = false }
        }
    }
}

/// Reports the height of the window's title bar + toolbar (the part of the
/// content view that `contentLayoutRect` excludes), including across resize and
/// full-screen transitions.
struct ToolbarInsetReader: NSViewRepresentable {
    @Binding var inset: CGFloat

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = { inset = $0 }
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onChange = { inset = $0 }
    }

    final class ReaderView: NSView {
        var onChange: ((CGFloat) -> Void)?
        private var last: CGFloat = -1
        private var tokens: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens = []
            guard let window else { return }
            for name in [NSWindow.didResizeNotification,
                         NSWindow.didEnterFullScreenNotification,
                         NSWindow.didExitFullScreenNotification] {
                tokens.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                })
            }
            // The toolbar is laid out after the view joins the window.
            DispatchQueue.main.async { [weak self] in self?.report() }
        }

        override func layout() {
            super.layout()
            DispatchQueue.main.async { [weak self] in self?.report() }
        }

        private func report() {
            guard let window, let contentView = window.contentView else { return }
            let inset = max(0, contentView.frame.height - window.contentLayoutRect.maxY)
            guard abs(inset - last) > 0.5 else { return }
            last = inset
            onChange?(inset)
        }
    }
}

/// Shown while the Mac has no network path. Library, history and downloaded
/// titles keep working, so this informs rather than blocks.
struct OfflineBanner: View {
    var body: some View {
        Label {
            Text("You're offline. Downloads are paused; your library and downloaded titles still work.")
                .font(.callout)
        } icon: {
            Image(systemName: "wifi.slash")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.orange.opacity(0.6), lineWidth: 1))
        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }
}

/// Banner used for engine and transient action errors. Not styled as glass —
/// it is content-layer feedback, and red+icon+text carries the signal.
struct ErrorBanner: View {
    let message: String
    var isTransient: Bool
    var onDismiss: (() -> Void)?
    /// A recovery action shown beside the message (for example Retry).
    var actionTitle: String?
    var onAction: (() -> Void)?

    init(message: String, isTransient: Bool, onDismiss: (() -> Void)? = nil) {
        self.message = message
        self.isTransient = isTransient
        self.onDismiss = onDismiss
    }

    init(message: String, isTransient: Bool, actionTitle: String, onAction: @escaping () -> Void) {
        self.message = message
        self.isTransient = isTransient
        self.actionTitle = actionTitle
        self.onAction = onAction
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
                .font(.callout)
                .lineLimit(3)
                .textSelection(.enabled)
            if let actionTitle, let onAction {
                Button(actionTitle, action: onAction)
                    .buttonStyle(.bordered)
                    .tint(.white)
            }
            if isTransient {
                Button("Dismiss") { onDismiss?() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.red.opacity(0.92), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .foregroundStyle(.white)
        .frame(maxWidth: 420)
        .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
    }
}
