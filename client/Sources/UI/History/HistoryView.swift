import SwiftUI

/// Watch history (Offline-Features-Plan Phase 6): every episode and movie
/// played, most recent first, grouped by day, with lifetime stats.
struct HistoryView: View {
    @Environment(WindowSession.self) private var windowSession
    @Environment(AppState.self) private var appState
    @State private var providerAssignment: ProviderAssignment?
    @State private var confirmClear = false

    struct Row: Identifiable {
        let id: String
        let itemID: String
        let title: String
        let posterURL: String?
        let provider: String
        let providerID: String?
        let providerURL: String
        let label: String?
        let fraction: Double?
        let watched: Bool
        let updatedAt: Date
        var isDownload = false
    }

    var body: some View {
        let _ = LibraryStore.shared.version
        let rows = LibraryStore.shared.readForDisplay(or: [], { try Self.rows() })

        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    Spacer()
                    Button("Clear History…", role: .destructive) { confirmClear = true }
                        .disabled(rows.isEmpty)
                }

                if rows.isEmpty {
                    ContentUnavailableView(
                        "Nothing watched yet",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Episodes and movies you play appear here."),
                    )
                    .frame(maxWidth: .infinity, minHeight: 260)
                } else {
                    LazyVStack(alignment: .leading, spacing: 18, pinnedViews: [.sectionHeaders]) {
                        ForEach(Self.groupedByDay(rows), id: \.day) { group in
                            Section {
                                ForEach(group.rows) { row in
                                    historyRow(row)
                                }
                            } header: {
                                Text(group.day, format: .dateTime.weekday(.wide).month().day().year())
                                    .font(.headline)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 4)
                                    .background(Color.canvas)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
        }
        .sheet(item: $providerAssignment) { ProviderAssignmentSheet(assignment: $0) }
        .confirmationDialog("Clear all watch history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { LibraryStore.shared.perform { try LibraryStore.shared.clearAllWatchHistory() } }
        } message: {
            Text("Resume positions and watched marks for every title are removed. Library lists and favorites are kept.")
        }
    }

    private func historyRow(_ row: Row) -> some View {
        Button {
            windowSession.openLibraryItem(id: row.itemID, provider: row.provider, providerID: row.providerID, url: row.providerURL)
        } label: {
            HStack(spacing: 14) {
                PosterImage(url: row.posterURL)
                    .frame(width: 44, height: 66)
                    .clipShape(.rect(cornerRadius: 5, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.title)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if let label = row.label {
                            Text(label)
                            Text("·").foregroundStyle(.tertiary)
                        }
                        Text(row.provider)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    if let fraction = row.fraction, !row.watched {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                            .frame(maxWidth: 220)
                            .tint(.accentColor)
                    }
                }
                Spacer()
                if row.watched {
                    Label("Watched", systemImage: "checkmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(Color.accentColor)
                }
                Text(row.updatedAt, format: .dateTime.hour().minute())
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open") { windowSession.openLibraryItem(id: row.itemID, provider: row.provider, providerID: row.providerID, url: row.providerURL) }
            if !row.isDownload, appState.isProviderMissing(row.providerID) {
                Button("Choose Provider…") {
                    providerAssignment = ProviderAssignment(id: row.itemID, title: row.title,
                        profileID: ProfileStore.shared.activeID, owner: LibraryStore.shared.identityOwnerToken)
                }
            }
            Divider()
            Button("Remove from History", role: .destructive) { LibraryStore.shared.perform { try LibraryStore.shared.deleteHistoryEntry(id: row.id) } }
            Button("Clear History for “\(row.title)”", role: .destructive) { LibraryStore.shared.perform { try LibraryStore.shared.clearWatchHistory(itemID: row.itemID) } }
        }
    }

    // MARK: Data

    @MainActor
    static func rows(limit: Int = 500) throws -> [Row] {
        let store = LibraryStore.shared
        var items: [String: StoredMediaItem?] = [:]
        return try store.watchHistory(limit: limit).compactMap { entry in
            if !items.keys.contains(entry.itemID) {
                items[entry.itemID] = try store.item(id: entry.itemID)
            }
            guard let item = items[entry.itemID] as? StoredMediaItem else { return nil }
            let label: String?
            switch (entry.season, entry.episode) {
            case _ where entry.isMovie: label = item.mediaType == "Download" ? "Download" : MediaTypeDisplay.name(for: item.mediaType)
            case let (season?, episode?): label = "S\(season) · E\(episode)"
            case let (nil, episode?): label = "Episode \(episode)"
            default: label = nil
            }
            return Row(
                id: entry.id,
                itemID: item.id,
                title: item.title,
                posterURL: item.posterURL ?? item.bannerURL,
                provider: item.providerName, providerID: item.providerID,
                providerURL: item.providerURL,
                label: label,
                fraction: entry.durationSeconds > 0 ? min(1, entry.positionSeconds / entry.durationSeconds) : nil,
                watched: entry.watched,
                updatedAt: entry.updatedAt,
                isDownload: item.mediaType == "Download",
            )
        }
    }

    struct DayGroup { let day: Date; let rows: [Row] }

    static func groupedByDay(_ rows: [Row], calendar: Calendar = .current) -> [DayGroup] {
        var order: [Date] = []
        var buckets: [Date: [Row]] = [:]
        for row in rows {
            let day = calendar.startOfDay(for: row.updatedAt)
            if buckets[day] == nil { order.append(day) }
            buckets[day, default: []].append(row)
        }
        return order.map { DayGroup(day: $0, rows: buckets[$0] ?? []) }
    }
}
