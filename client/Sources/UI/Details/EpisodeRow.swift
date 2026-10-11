import AppKit
import SwiftUI

// MARK: - Episode Row

/// One episode: thumbnail tap (or the Play button) starts playback; Download
/// is its own button — no button nested inside a button.
struct EpisodeRow: View {
    let episode: EpisodeDto
    let provider: String
    /// The show, for Add to Page; nil hides it.
    var title: DetailsDto? = nil
    let indexLabel: String
    var progress: EpisodeProgressSnapshot? = nil
    /// The episode the primary Play button will start.
    var isUpNext = false
    var onPlay: () -> Void
    var onSetWatched: ((Bool) -> Void)? = nil
    var onMarkPreviousWatched: (() -> Void)? = nil
    var onPlayLocal: ((URL) -> Void)? = nil
    var onDownload: () -> Void
    var providerID: String? = nil
    /// Download from a source the user picks (right-click ▸ "Download … from…").
    var onDownloadFrom: ((DownloadPolicy.SourceChoice) -> Void)? = nil

    private var isWatched: Bool { progress?.watched == true }

    @State private var hovering = false
    @State private var showSourcePicker = false

    private var queueItem: DownloadService.QueueItem? {
        DownloadService.shared.queueItem(forProvider: provider, episodeData: episode.data)
    }

    private var completedRecord: DownloadRecord? {
        DownloadService.shared.completedRecord(provider: provider, episodeData: episode.data)
    }

    var body: some View {
        HStack(spacing: 16) {
            Button(action: onPlay) {
                ZStack(alignment: .bottomLeading) {
                    PosterImage(url: episode.posterUrl)
                        .frame(width: 140, height: 80)
                        .clipShape(.rect(cornerRadius: 6, style: .continuous))

                    if let fraction = progress?.fraction, !isWatched {
                        // Android-style resume bar pinned to the thumbnail's bottom edge.
                        GeometryReader { proxy in
                            VStack {
                                Spacer()
                                ZStack(alignment: .leading) {
                                    Rectangle().fill(Color.black.opacity(0.55))
                                    Rectangle().fill(Color.accentColor)
                                        .frame(width: proxy.size.width * fraction)
                                }
                                .frame(height: 3)
                            }
                        }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }

                    if isWatched {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.callout)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .shadow(color: .black.opacity(0.5), radius: 2)
                            .padding(5)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .accessibilityLabel("Watched")
                    }

                    if episode.isDub {
                        Text("DUB")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.yellow, in: .rect(cornerRadius: 3))
                            .padding(5)
                    }
                }
                .frame(width: 140, height: 80)
                .overlay {
                    if hovering {
                        ZStack {
                            Color.black.opacity(0.25)
                            Image(systemName: "play.fill")
                                .font(.title3)
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.5), radius: 3)
                        }
                        .clipShape(.rect(cornerRadius: 6, style: .continuous))
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(hovering ? Color.primary.opacity(0.3) : .clear, lineWidth: 1)
                )
            }
            .buttonStyle(PressFeedbackButtonStyle())
            .help("Play \(indexLabel)")
            .onHover { hovering in
                self.hovering = hovering
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(episode.name ?? indexLabel)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(isWatched ? .secondary : .primary)
                        .lineLimit(1)

                    if let remaining = progress?.remainingSeconds, progress?.isResumable == true {
                        Text(WatchProgressPolicy.remainingLabel(remaining))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Color.accentColor)
                    } else if let runtime = episode.runTimeMinutes {
                        Text(MediaTypeDisplay.duration(minutes: runtime))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    if isUpNext {
                        Text("UP NEXT")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1))
                    }
                }

                let cleanDesc = HTMLStringSanitizer.sanitize(episode.description)
                if !cleanDesc.isEmpty {
                    Text(cleanDesc)
                        .font(.callout)
                        .lineSpacing(2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            downloadControl
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(hovering ? Color.hoverFill : Color.cardSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.cardBorder, lineWidth: 1)
        )
        .padding(.vertical, 1)
        .contextMenu { rowMenu }
    }

    @ViewBuilder
    private var rowMenu: some View {
        Button("Play \(indexLabel)", action: onPlay)
        if let onSetWatched {
            Divider()
            if isWatched {
                Button("Mark as Unwatched") { onSetWatched(false) }
            } else {
                Button("Mark as Watched") { onSetWatched(true) }
            }
        }
        if let onMarkPreviousWatched {
            Button("Mark All Previous as Watched", action: onMarkPreviousWatched)
        }
        if let title {
            AddToPageMenu(details: title, episode: episode)
        }
        Divider()
        if completedRecord == nil, queueItem == nil {
            Button("Download \(indexLabel)", action: onDownload)
            if onDownloadFrom != nil {
                Button("Download \(indexLabel) from…") { showSourcePicker = true }
            }
        }
        Button("Copy Episode Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(episode.name ?? indexLabel, forType: .string)
        }
    }

    @ViewBuilder
    private var downloadControl: some View {
        Group {
            if let completed = completedRecord {
                Button {
                    if let onPlayLocal {
                        onPlayLocal(completed.destinationURL)
                    } else {
                        onPlay()
                    }
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .help("Downloaded — click to play local file")
                .accessibilityLabel("Play downloaded \(indexLabel)")
            } else if let item = queueItem, item.state == .downloading || item.state == .resolving || item.state == .queued || item.state == .paused {
                Button {
                    DownloadService.shared.cancel(item)
                } label: {
                    ZStack {
                        if item.state == .downloading {
                            ProgressView(value: item.progress)
                                .progressViewStyle(.circular)
                                .controlSize(.small)
                        } else {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .controlSize(.small)
                        }
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color.secondary)
                    }
                    .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .help(item.state == .resolving ? "Resolving link… click to cancel" : (item.state == .queued ? "Queued… click to cancel" : "Downloading \(item.progressLabel)… click to cancel"))
                .accessibilityLabel("Cancel download of \(indexLabel)")
            } else {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        onDownload()
                    }
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.title3)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .help(onDownloadFrom == nil ? "Download \(indexLabel)" : "Download \(indexLabel) — right-click to choose a source")
                .accessibilityLabel("Download \(indexLabel)")
            }
        }
        .popover(isPresented: $showSourcePicker, arrowEdge: .leading) {
            if let onDownloadFrom {
                DownloadSourcePicker(
                    title: "Download \(indexLabel) from",
                    footnote: nil,
                    provider: provider,
                    providerID: providerID,
                    episodeData: episode.data,
                    onChoose: onDownloadFrom,
                )
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: queueItem?.state)
    }
}
