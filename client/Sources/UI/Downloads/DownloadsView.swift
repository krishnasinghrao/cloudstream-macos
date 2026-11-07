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
    @State private var confirmCancelAll = false

    /// Observation hooks: queue items are @Observable and the library store
    /// bumps `version` on every record mutation — no polling timer.
    private var storeVersion: UInt64 { LibraryStore.shared.version }

    var body: some View {
        VStack(spacing: 20) {
            // One header row: the section switch leads, the queue's bulk
            // actions trail it (no empty row when they do not apply).
            HStack(spacing: 8) {
                Picker("Section", selection: $tab) {
                    Text("Active Queue").tag(Tab.queue)
                    Text("Downloaded Titles").tag(Tab.completed)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                Spacer()

                if tab == .queue, !DownloadService.shared.queue.isEmpty {
                    Button("Cancel All…") {
                        confirmCancelAll = true
                    }
                    .disabled(activeOrQueuedCount == 0)
                    .help("Stop every queued and active download")
                    Button("Clear Finished") {
                        DownloadService.shared.clearFinished()
                    }
                    .disabled(finishedCount == 0)
                    .help("Remove finished, failed and cancelled rows from the queue")
                }
            }
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
            activeOrQueuedCount == 1 ? "Cancel 1 download?" : "Cancel \(activeOrQueuedCount) downloads?",
            isPresented: $confirmCancelAll,
            titleVisibility: .visible,
        ) {
            Button("Cancel Downloads", role: .destructive) {
                DownloadService.shared.cancelAll()
            }
            Button("Keep Downloading", role: .cancel) {}
        } message: {
            Text("Partially downloaded files are discarded.")
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
            ProgressView(value: usedFraction)
                .progressViewStyle(.linear)
                .tint(usedFraction > 0.95 ? .orange : .accentColor)
                .accessibilityLabel("Storage used")
                .accessibilityValue("\(ByteCountFormatter.string(fromByteCount: diskFree, countStyle: .file)) free")
        }
        .padding(16)
        .background(Color.cardSurface, in: .rect(cornerRadius: 12, style: .continuous))
        .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.cardBorder, lineWidth: 1))
    }

    private var usedFraction: Double {
        guard diskTotal > 0 else { return 0 }
        return min(1, max(0, Double(diskTotal - diskFree) / Double(diskTotal)))
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
                            // Every row button is also here, plus queue order.
                            switch item.state {
                            case .downloading:
                                Button("Pause") { DownloadService.shared.pause(item) }
                            case .paused where !item.resumeRequested:
                                Button("Resume") { DownloadService.shared.resume(item) }
                            default:
                                EmptyView()
                            }
                            if item.state == .queued {
                                Button("Download Next") {
                                    DownloadService.shared.moveToFront(item)
                                }
                            }
                            if item.state == .failed || item.state == .cancelled {
                                Button("Retry") { DownloadService.shared.retry(item) }
                            }
                            if item.state == .completed || item.state == .failed || item.state == .cancelled {
                                Button("Reveal in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([item.destinationURL.deletingLastPathComponent()])
                                }
                                Divider()
                                Button("Remove from Queue") { DownloadService.shared.removeFromQueue(item) }
                            } else if item.state != .finalizing {
                                Divider()
                                Button("Cancel Download", role: .destructive) { DownloadService.shared.cancel(item) }
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
                    .help("\(item.title) — \(item.episodeLabel)")
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
                        Text("Mirror \(item.activeLinkIndex + 1)")
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
                .accessibilityLabel("Pause download")
            case .paused where item.resumeRequested:
                Button {
                    onPause()
                } label: {
                    Image(systemName: "pause.fill")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.bordered)
                .help("Keep paused")
                .accessibilityLabel("Keep paused")
            case .paused:
                Button {
                    onResume()
                } label: {
                    Image(systemName: "play.fill")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.bordered)
                .help("Resume download")
                .accessibilityLabel("Resume download")
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
                .accessibilityLabel("Retry download")
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
                .accessibilityLabel("Cancel download")
            } else {
                Button {
                    onRemove()
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.bordered)
                .help(item.state == .completed ? "Remove from list (keeps the downloaded file)" : "Remove from queue")
                .accessibilityLabel("Remove from queue")
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
                    .help("\(record.title) — \(record.episodeLabel)")
                HStack(spacing: 8) {
                    Text(record.provider)
                    Text(ByteCountFormatter.string(fromByteCount: record.fileByteSize, countStyle: .file))
                    Text(record.destinationPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(record.destinationPath)
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
                    Image(systemName: "play.fill")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.bordered)
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
                .accessibilityLabel("Reveal in Finder")
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
                .accessibilityLabel("Delete download")
                .disabled(availability == .volumeUnavailable)
                .help(availability == .volumeUnavailable ? "Connect the disk to delete this download" : "Delete download and file")
            }
        }
        .contextMenu {
            if record.existsOnDisk {
                Button("Play", action: playLocalFile)
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([record.destinationURL])
                }
            }
            if availability == .present {
                Button("Add to Library") { DownloadService.shared.addCompletedToCurrentLibrary(record) }
            }
            Divider()
            if availability == .missing {
                Button("Remove from List") {
                    DownloadService.shared.forgetMissingDownload(recordID: record.id, provider: record.provider,
                                                                 destinationURL: record.destinationURL)
                }
            } else {
                Button("Delete Download…", role: .destructive, action: onDelete)
                    .disabled(availability == .volumeUnavailable)
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
