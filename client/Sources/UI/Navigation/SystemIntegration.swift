import AppIntents
import AppKit
import CoreSpotlight
import SwiftUI

// Offline-Features-Plan Phase 9: menu bar extra, Dock, Handoff activity
// types, App Intents and the keyboard shortcut reference.

enum UserActivityType {
    /// A title page, for Handoff / state restoration.
    static let viewTitle = "com.lagradost.cloudstream.view-title"
}

/// Menu bar: Continue Watching, download status, quick actions.
struct CloudStreamMenuBarContent: View {
    let appState: AppState

    var body: some View {
        let _ = LibraryStore.shared.version
        let items = AppLock.shared.isLocked ? [] : Array(LibraryStore.shared.readForDisplay(or: [], { try LibraryStore.shared.continueWatching }).prefix(5))
        if AppLock.shared.isLocked {
            Text("CloudStream is locked")
        } else if items.isEmpty {
            Text("Nothing in progress")
        } else {
            Section("Continue Watching") {
                ForEach(items) { item in
                    Button(Self.label(for: item)) {
                        NSApp.activate()
                        LibraryStore.shared.startResume(item: item, appState: appState)
                    }
                }
            }
        }
        Divider()
        let downloads = DownloadService.shared
        if downloads.totalActiveOrQueuedCount > 0, !AppLock.shared.isLocked {
            Text("Downloads: \(downloads.activeCount) active, \(downloads.totalActiveOrQueuedCount) total")
            Button("Show Downloads") {
                NSApp.activate()
                appState.navigateTo(.downloaded)
            }
            Divider()
        }
        Button("Search…") {
            NSApp.activate()
            appState.navigateTo(.search)
        }
        .disabled(AppLock.shared.isLocked)
        Button("Open CloudStream") { NSApp.activate() }
        Divider()
        Button("Quit CloudStream") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    static func label(for item: StoredMediaItem) -> String {
        var text = item.title
        if let season = item.lastSeason, let episode = item.lastEpisode { text += " — S\(season) E\(episode)" }
        if let remaining = item.remainingLabel { text += " (\(remaining) left)" }
        return text
    }
}

/// Dock badge = downloads in flight.
@MainActor
enum DockBadge {
    static func update() {
        let count = DownloadService.shared.totalActiveOrQueuedCount
        NSApp.dockTile.badgeLabel = UserPreferences.shared.showDockBadge && count > 0 ? "\(count)" : nil
    }
}

/// Help ▸ Keyboard Shortcuts.
struct KeyboardShortcutsView: View {
    @Environment(\.dismiss) private var dismiss

    static let groups: [(String, [(String, String)])] = [
        ("Navigation", [("⌘1–⌘6", "Home, Watching, Plan to Watch, Favorites, Completed, Downloaded"),
                        ("⌘F", "Search"), ("⌘Y", "History"), ("⇧⌘E", "Extensions"), ("⌘,", "Settings")]),
        ("Title Page", [("⌘R", "Reload details"), ("⌘D", "Add to / remove from Favorites"), ("⇧⌘R", "Surprise me (Home)")]),
        ("Player", [("Space / K", "Play / pause"), ("← → / J L", "Seek (⇧ doubles)"), ("↑ ↓", "Volume"),
                    ("S", "Skip intro / credits"), ("N", "Next episode"), ("Z / X", "Subtitle earlier / later"),
                    (", / .", "Previous / next frame"), ("F", "Full screen"), ("M", "Mute"), ("Esc", "Dismiss Up Next / exit")]),
        ("Library", [("⌥⌘E", "Export backup"), ("⌥⌘I", "Import backup"), ("⌃⌘L", "Lock now")]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Keyboard Shortcuts").font(.title2.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Self.groups, id: \.0) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(group.0).font(.headline)
                            ForEach(group.1, id: \.0) { shortcut in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(shortcut.0)
                                        .font(.body.monospaced())
                                        .frame(width: 130, alignment: .leading)
                                    Text(shortcut.1).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520, height: 560)
    }
}

// MARK: - App Intents (Shortcuts, Spotlight actions)

struct SearchCloudStreamIntent: AppIntent {
    static let title: LocalizedStringResource = "Search CloudStream"
    static let description = IntentDescription("Searches every installed provider.")
    static let openAppWhenRun = true

    @Parameter(title: "Title")
    var query: String

    @MainActor
    func perform() async throws -> some IntentResult {
        AppState.shared.perform(.search(query))
        return .result()
    }
}

struct ContinueWatchingIntent: AppIntent {
    static let title: LocalizedStringResource = "Continue Watching"
    static let description = IntentDescription("Resumes the title you watched most recently.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppState.shared.perform(.continueWatching)
        return .result()
    }
}

struct CloudStreamShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ContinueWatchingIntent(),
            phrases: ["Continue watching in \(.applicationName)", "Resume \(.applicationName)"],
            shortTitle: "Continue Watching",
            systemImageName: "play.circle",
        )
        AppShortcut(
            intent: SearchCloudStreamIntent(),
            phrases: ["Search \(.applicationName)"],
            shortTitle: "Search",
            systemImageName: "magnifyingglass",
        )
    }
}
