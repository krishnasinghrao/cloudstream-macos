import AppKit
import SwiftUI

/// Weak routing targets for application entry points that have no SwiftUI
/// focused scene (menu-bar actions and App Intents). Views use their environment
/// session directly; this registry never owns a window or its navigation.
@MainActor
final class WindowSessionRegistry {
    static let shared = WindowSessionRegistry()
    private final class Entry {
        weak var session: WindowSession?
        var tokens: [NSObjectProtocol] = []
        init(_ session: WindowSession) { self.session = session }
    }
    private var entries: [UUID: Entry] = [:]
    private var activeID: UUID?
    private var activationOrder: [UUID] = []
    private let pending = WindowSession()

    var routedSession: WindowSession {
        if let activeID, let session = entries[activeID]?.session { return session }
        return activationOrder.reversed().compactMap { entries[$0]?.session }.first ?? pending
    }

    var activeDetailKeys: Set<DetailCoordinate> {
        Set(entries.values.compactMap(\.session).flatMap(\.detailPath) + pending.detailPath)
    }

    func register(_ session: WindowSession, window: NSWindow? = nil) {
        guard entries[session.id] == nil else { return }
        if entries.isEmpty && (pending.selection != .home || !pending.detailPath.isEmpty
            || !pending.searchQuery.isEmpty || pending.pendingRepoAdd != nil || pending.showShortcuts) {
            session.selection = pending.selection
            session.detailPath = pending.detailPath
            session.libraryFilter = pending.libraryFilter
            session.pendingRepoAdd = pending.pendingRepoAdd
            session.showShortcuts = pending.showShortcuts
            if !pending.searchQuery.isEmpty {
                session.searchQuery = pending.searchQuery
                session.commitSearch()
            }
            pending.navigateTo(.home)
            pending.clearSearch()
            pending.pendingRepoAdd = nil
            pending.showShortcuts = false
        }
        let entry = Entry(session)
        entries[session.id] = entry
        activationOrder.insert(session.id, at: 0)
        if activeID == nil || window?.isKeyWindow == true { activate(session.id) }
        if let window {
            let id = session.id
            entry.tokens.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.activate(id) }
                })
            entry.tokens.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.unregister(id) }
                })
        }
    }

    func activate(_ id: UUID) {
        guard entries[id]?.session != nil else { return }
        activeID = id
        activationOrder.removeAll { $0 == id }
        activationOrder.append(id)
    }

    func unregister(_ id: UUID) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        entry.tokens.forEach(NotificationCenter.default.removeObserver)
        entry.session?.cancelSearch()
        activationOrder.removeAll { $0 == id }
        if activeID == id { activeID = nil }
    }

    func cancelAllSearches() {
        pending.cancelSearch()
        entries.values.compactMap(\.session).forEach { $0.cancelSearch() }
    }

    func invalidateProfileNavigation() {
        for session in entries.values.compactMap(\.session) + [pending] {
            session.detailPath.removeAll()
            session.clearSearch()
            session.libraryFilter = ""
        }
    }
}

extension FocusedValues {
    @Entry var windowSession: WindowSession?
}

/// Tracks the actual owning window rather than looking up NSApp.keyWindow.
struct WindowSessionAnchor: NSViewRepresentable {
    let session: WindowSession
    final class AnchorView: NSView {
        var session: WindowSession?
        private var fullScreenTokens: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            fullScreenTokens.forEach(NotificationCenter.default.removeObserver)
            fullScreenTokens = []
            // Leaving the window (window == nil) only drops the observers.
            guard let session, let window else { return }
            WindowSessionRegistry.shared.register(session, window: window)
            session.isFullScreen = window.styleMask.contains(.fullScreen)
            // "Will" rather than "did", so screens restyle during the transition.
            for (name, value) in [(NSWindow.willEnterFullScreenNotification, true),
                                  (NSWindow.willExitFullScreenNotification, false)] {
                fullScreenTokens.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak session] _ in
                    MainActor.assumeIsolated { session?.isFullScreen = value }
                })
            }
        }
    }
    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView(); view.session = session; return view
    }
    func updateNSView(_ view: AnchorView, context: Context) {}
    static func dismantleNSView(_ view: AnchorView, coordinator: ()) {
        if let session = view.session { WindowSessionRegistry.shared.unregister(session.id) }
    }
}
