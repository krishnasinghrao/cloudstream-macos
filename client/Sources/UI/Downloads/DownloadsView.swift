import AppKit
import SwiftUI

/// Downloads: Active Queue and Downloaded Titles with live progress, honest
/// ETA, storage gauge, and confirmed destructive actions.
struct DownloadsView: View {
    enum Tab: Hashable {
        case queue
        case completed
    }

    @State private var tab: Tab = .queue
    @State private var diskFree: Int64 = 0
    @State private var diskTotal: Int64 = 0
    @State private var diskName: String?
    @State private var diskIsInternal = true
    @State private var recordForDeletion: DownloadRecord?

    /// Observation hooks: queue items are @Observable and the library store
    /// bumps `version` on every record mutation — no polling timer.
    private var storeVersion: UInt64 { LibraryStore.shared.version }

    var body: some View {
        VStack(spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                Spacer()
                if tab == .queue, !DownloadService.shared.queue.isEmpty {
                    HStack(spacing: 8) {
                        if activeOrQueuedCount > 0 {
                            Button("Cancel All") {
                                DownloadService.shared.cancelAll()
                            }
                            .buttonStyle(.bordered)
                        }
                        Button("Clear Finished") {
                            DownloadService.shared.clearFinished()
                        }
                        .buttonStyle(.bordered)
                        .disabled(finishedCount == 0)
                    }
                }
            }
            .padding(.horizontal, 28)

            Picker("Section", selection: $tab) {
                Text("Active Queue").tag(Tab.queue)
                Text("Downloaded Titles").tag(Tab.completed)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 340)
            .padding(.horizontal, 28)

            storageGauge
                .padding(.horizontal, 28)

            switch tab {
            case .queue:
                queueTable
            case .completed:
                downloadedList
            }
        }
        .padding(.top, 16)
        .padding(.bottom, 48)
        .task {
            refreshDisk()
        }
        .onChange(of: tab) { _, _ in
            refreshDisk()
        }
        .onChange(of: DownloadService.shared.activityTrigger) { _, _ in
            refreshDisk()
        }
        .onChange(of: UserPreferences.shared.downloadDirectory) { _, _ in
            refreshDisk()
        }
        .confirmationDialog(
            "Delete “\(recordForDeletion?.title ?? "") — \(recordForDeletion?.episodeLabel ?? "")”?",
            isPresented: Binding(
                get: { recordForDeletion != nil },
                set: { if !$0 { recordForDeletion = nil } },
            ),
            titleVisibility: .visible,
        ) {
            Button("Delete File from Disk", role: .destructive) {
                if let record = recordForDeletion {
                    deleteCompleted(record)
                }
                recordForDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                recordForDeletion = nil
            }
        } message: {
            Text("The downloaded file will be removed from “\(recordForDeletion?.destinationPath ?? "")”. This cannot be undone.")
        }
    }

    private var store: LibraryStore { LibraryStore.shared }

    private var records: [DownloadRecord] {
        let _ = storeVersion
        return store.readForDisplay(or: [], { try store.downloadRecords() })
    }

    private var activeOrQueuedCount: Int {
        DownloadService.shared.queue.filter { item in
            switch item.state {
            case .downloading, .resolving, .queued, .paused, .finalizing: return true
            default: return false
            }
        }.count
    }

    private var finishedCount: Int {
        DownloadService.shared.queue.filter { item in
            switch item.state {
            case .completed, .cancelled, .failed: return true
            default: return false
            }
        }.count
    }

    private var completedRecords: [DownloadRecord] {
        records.filter { $0.status == .completed }
    }

    private func deleteCompleted(_ record: DownloadRecord) {
        DownloadService.shared.deleteCompleted(
            recordID: record.id,
            provider: record.provider,
            destinationURL: record.destinationURL,
        )
    }

    private var storageGauge: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(diskName ?? "Storage", systemImage: diskIsInternal ? "internaldrive" : "externaldrive")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(ByteCountFormatter.string(fromByteCount: diskFree, countStyle: .file)) free of \(ByteCountFormatter.string(fromByteCount: diskTotal, countStyle: .file))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    let used = max(0, diskTotal - diskFree)
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: proxy.size.width * (diskTotal > 0 ? Double(used) / Double(diskTotal) : 0))
                }
            }
            .frame(height: 6)
        }
        .padding(16)
        .background(Color.cardSurface, in: .rect(cornerRadius: 12, style: .continuous))
        .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.cardBorder, lineWidth: 1))
    }

    @ViewBuilder
    private var queueTable: some View {
        let queue = DownloadService.shared.queue
        if queue.isEmpty {
            ContentUnavailableView(
                "Queue is empty",
                systemImage: "tray",
                description: Text("Download seasons or movies from any details view."),
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical) {
                VStack(spacing: 12) {
                    ForEach(queue) { item in
                        QueueRow(
                            item: item,
                            onPause: { DownloadService.shared.pause(item) },
                            onResume: { DownloadService.shared.resume(item) },
                            onCancel: { DownloadService.shared.cancel(item) },
                            onRetry: { DownloadService.shared.retry(item) },
                            onRemove: { DownloadService.shared.removeFromQueue(item) },
                        )
                        .contextMenu {
                            if item.state == .queued {
                                Button("Download Next") {
                                    DownloadService.shared.moveToFront(item)
                                }
                            }
                            if item.state == .completed || item.state == .failed || item.state == .cancelled {
                                Button("Reveal in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([item.destinationURL.deletingLastPathComponent()])
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 28)
            }
        }
    }

    @ViewBuilder
    private var downloadedList: some View {
        let completed = completedRecords
        if completed.isEmpty {
            ContentUnavailableView(
                "No downloaded titles",
                systemImage: "arrow.down.circle",
                description: Text("Completed downloads will appear here."),
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical) {
                VStack(spacing: 12) {
                    ForEach(completed) { record in
                        DownloadedRow(record: record) {
                            recordForDeletion = record
                        }
                    }
                }
                .padding(.horizontal, 28)
            }
        }
    }

    private func refreshDisk() {
        let capacity = DownloadPolicy.volumeCapacity(for: UserPreferences.shared.downloadDirectory)
        diskFree = capacity?.free ?? 0
        diskTotal = capacity?.total ?? 0
        diskName = capacity?.name
        diskIsInternal = capacity?.isInternal ?? true
    }
}

/// Active-queue row: live progress, speed, ETA, transport actions.
struct QueueRow: View {
    @Bindable var item: DownloadService.QueueItem
    var onPause: () -> Void
    var onResume: () -> Void
    var onCancel: () -> Void
    var onRetry: () -> Void
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(item.title) — \(item.episodeLabel)")
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 10) {
                    Text(stateLabel)
                        .foregroundStyle(item.state == .failed ? Color.red : Color.secondary)
                    // Queued/resolving rows already say it all in stateLabel.
                    if item.state == .downloading || item.state == .paused || item.state == .failed {
                        Text(item.speedLabel)
                            .lineLimit(1)
                    }
                    Text(item.progressLabel)
                    if let eta = item.etaLabel {
                        Text("ETA \(eta)")
                    }
                    if item.activeLinkIndex > 0 {
                        Text("mirror #\(item.activeLinkIndex + 1)")
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.subheadline.monospacedDigit())

                if item.state == .resolving {
                    ProgressView()
                        .progressViewStyle(.linear)
                } else {
                    ProgressView(value: item.state == .completed ? 1 : item.progress)
                        .progressViewStyle(.linear)
                        .tint(item.state == .failed ? .red : .accentColor)
                }
            }

            Spacer()

            switch item.state {
            case .downloading:
                Button {
                    onPause()
                } label: {
                    Image(systemName: "pause.fill")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.bordered)
                .help("Pause download")
            case .paused where item.resumeRequested:
                Button {
                    onPause()
                } label: {
                    Image(systemName: "pause.fill")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.bordered)
                .help("Keep paused")
            case .paused:
                Button {
                    onResume()
                } label: {
                    Image(systemName: "play.fill")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.bordered)
                .help("Resume download")
            default:
                EmptyView()
            }
            if item.state == .failed || item.state == .cancelled {
                Button {
                    onRetry()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.bordered)
                .help("Retry download")
            }
            if item.state == .finalizing {
                EmptyView()
            } else if item.state == .downloading || item.state == .paused || item.state == .queued || item.state == .resolving {
                Button {
                    onCancel()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.bordered)
                .help("Cancel download")
            } else {
                Button {
                    onRemove()
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.bordered)
                .help(item.state == .completed ? "Remove from list (keeps the downloaded file)" : "Remove from queue")
            }
        }
        .padding(16)
        .background(Color.cardSurface, in: .rect(cornerRadius: 12, style: .continuous))
        .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.cardBorder, lineWidth: 1))
    }

    private var stateLabel: String {
        switch item.state {
        case .queued: return item.statusDetail ?? "Queued"
        case .resolving: return item.statusDetail ?? "Resolving link…"
        case .downloading:
            if let detail = item.statusDetail { return detail }
            if let fallback = item.fallbackSourceName { return "Downloading from \(fallback) — chosen source unavailable" }
            return "Downloading"
        case .paused: return item.statusDetail ?? "Paused"
        case .finalizing: return item.statusDetail ?? "Finishing…"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }
}

/// Completed download row: real file-backed, with Play (local mpv), Reveal,
/// and a confirmed Delete action.
struct DownloadedRow: View {
    let record: DownloadRecord
    var onDelete: () -> Void
    private var availability: DownloadService.FileAvailability { DownloadService.availability(of: record.destinationURL) }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: record.existsOnDisk ? "film.fill" : "film")
                .font(.title2)
                .foregroundStyle(record.existsOnDisk ? Color.accentColor : Color.textTertiary)
                .frame(width: 40)

            VStack(alignment: .leading, spacing: 4) {
                Text("\(record.title) — \(record.episodeLabel)")
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(record.provider)
                    Text(ByteCountFormatter.string(fromByteCount: record.fileByteSize, countStyle: .file))
                    Text(record.destinationPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption)
                .foregroundStyle(.tertiary)

                if availability == .volumeUnavailable {
                    Label("Disk not connected", systemImage: "externaldrive.badge.exclamationmark")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                } else if availability == .missing {
                    Label("File missing on disk", systemImage: "exclamationmark.triangle")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                }
            }

            Spacer()

            if record.existsOnDisk {
                Button {
                    playLocalFile()
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .help("Play downloaded file")
                .accessibilityLabel("Play downloaded file")

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([record.destinationURL])
                } label: {
                    Image(systemName: "folder")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.bordered)
                .help("Reveal in Finder")
            }

            if availability == .missing {
                // The file is already gone: forgetting the entry is its own
                // explicit action, never a side effect of a failed delete.
                Button("Remove from List") {
                    DownloadService.shared.forgetMissingDownload(recordID: record.id, provider: record.provider,
                                                                 destinationURL: record.destinationURL)
                }
                .help("Remove this entry. No file is deleted.")
            } else {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.bordered)
                .disabled(availability == .volumeUnavailable)
                .help(availability == .volumeUnavailable ? "Connect the disk to delete this download" : "Delete download and file")
            }
        }
        .contextMenu {
            if availability == .present {
                Button("Add to Library") { DownloadService.shared.addCompletedToCurrentLibrary(record) }
            }
        }
        .padding(16)
        .background(Color.cardSurface, in: .rect(cornerRadius: 12, style: .continuous))
        .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.cardBorder, lineWidth: 1))
    }

    /// Local playback through the embedded mpv pipeline.
    private func playLocalFile() {
        Task {
            var details = DetailsDto(
                provider: record.provider,
                url: record.destinationPath,
                name: record.title,
                type: "Download",
                posterUrl: nil,
                backgroundPosterUrl: nil,
                logoUrl: nil,
                plot: nil,
                year: nil,
                durationMinutes: record.durationSeconds.map { Int($0 / 60) },
                score: nil,
                tags: [],
                actors: [],
                contentRating: nil,
                comingSoon: false,
                episodes: [],
                movieData: nil,
            )
            details.localDownloadID = record.id
            // The local path is the stream — mpv plays filesystem paths
            // directly, no daemon /links resolution (P0-4).
            await AppState.shared.player.play(
                details: details,
                episode: nil,
                preferences: UserPreferences.shared,
                localMediaURL: record.destinationURL,
            )
        }
    }
}
