import SwiftUI

// MARK: - Dimension-aware Content Card

/// Grids propose the width; shelves give landscape thumbnails more room.
/// Every foreground image is aspect-fit so thumbnail text and faces survive.
/// Badges, selection, and progress stay attached to the artwork's bounds.
struct PosterCard: View {
    let title: String
    let subtitle: String?
    let posterURL: String?
    var progressFraction: Double? = nil
    var posterHeaders: [String: String]? = nil
    /// Accent badge in the top-leading corner (e.g. "3 NEW").
    var highlightBadge: String? = nil
    /// Bulk-selection state; nil when not selecting.
    var isSelected: Bool? = nil
    var layout: ArtworkCardLayout = .grid
    var imageCache: ImageCache = .shared
    var geometryHint: ArtworkGeometry? = nil
    var onGeometry: ((ArtworkGeometry) -> Void)? = nil

    @State private var artworkLoader = ArtworkLoader()
    @Environment(\.artworkCardShape) private var shape

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let request = ArtworkRequest(url: posterURL, headers: posterHeaders)
        let asset = artworkLoader.phase(for: request, cache: imageCache).asset
        let geometry = asset?.geometry ?? geometryHint ?? request.flatMap { imageCache.geometry(for: $0) }
        let ratio = shape.ratio(for: geometry, placeholder: layout.placeholderRatio)

        VStack(alignment: .leading, spacing: 8) {
            Color.clear
                .aspectRatio(ratio, contentMode: .fit)
                .overlay { ArtworkSurface(asset: asset, contentMode: shape.contentMode) }
                .overlay(alignment: .topLeading) {
                    if let highlightBadge {
                        Text(highlightBadge)
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.accentColor, in: Capsule())
                            .padding(7)
                            .accessibilityLabel(highlightBadge)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let isSelected {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title2)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, isSelected ? Color.accentColor : Color.black.opacity(0.4))
                            .shadow(radius: 2)
                            .padding(8)
                            .accessibilityLabel(isSelected ? "Selected" : "Not selected")
                    }
                }
                .overlay(alignment: .bottom) {
                    if let fraction = progressFraction, fraction > 0 {
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(Color.black.opacity(0.55))
                                Rectangle()
                                    .fill(Color.accentColor)
                                    .frame(width: max(4, proxy.size.width * min(1, max(0, fraction))))
                            }
                        }
                        .frame(height: 3.5)
                        .accessibilityHidden(true)
                    }
                }
                .clipShape(.rect(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            isSelected == true ? Color.accentColor : (hovering ? Color.primary.opacity(0.25) : Color.cardBorder),
                            lineWidth: isSelected == true ? 3 : 1,
                        )
                )
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: hovering)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: layout.width(for: geometry), alignment: .topLeading)
        .task(id: request) { await artworkLoader.load(request, cache: imageCache) }
        .onChange(of: CardGeometryUpdate(request: request, geometry: asset?.geometry), initial: true) { _, update in
            if let geometry = update.geometry { onGeometry?(geometry) }
        }
        .contentShape(.rect(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityHint(subtitle ?? "")
        // Titles are clamped to one line; the full text is a hover away.
        .help(subtitle.map { $0.isEmpty ? title : "\(title) — \($0)" } ?? title)
        .onHover { hovering in
            self.hovering = hovering
        }
    }
}

private struct CardGeometryUpdate: Equatable {
    let request: ArtworkRequest?
    let geometry: ArtworkGeometry?
}

// MARK: - 16:9 Episode Card

/// A single episode saved to a page (ADR-0021): a 16:9 thumbnail like the
/// episode list on a show's page, with the episode above the show's name.
/// Fills the grid cell or shelf width it is given.
struct EpisodeCard: View {
    let title: String
    let showTitle: String
    let thumbnailURL: String?
    var isDub = false
    var progress: EpisodeProgressSnapshot? = nil

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isWatched: Bool { progress?.watched == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Ratio placeholder, as in PosterCard: the box comes from the proposal, not the bitmap.
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay { PosterImage(url: thumbnailURL, placeholderIcon: "tv", contentMode: .fit) }
                .overlay(alignment: .bottom) {
                    if let fraction = progress?.fraction, !isWatched {
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(Color.black.opacity(0.55))
                                Rectangle().fill(Color.accentColor).frame(width: max(4, proxy.size.width * fraction))
                            }
                        }
                        .frame(height: 3.5)
                        .accessibilityHidden(true)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if isWatched {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .shadow(color: .black.opacity(0.5), radius: 2)
                            .padding(7)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if isDub {
                        Text("DUB")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.yellow, in: .rect(cornerRadius: 3))
                            .padding(7)
                    }
                }
                .overlay {
                    if hovering {
                        ZStack {
                            Color.black.opacity(0.25)
                            Image(systemName: "play.fill")
                                .font(.title2)
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.5), radius: 3)
                        }
                        .accessibilityHidden(true)
                    }
                }
                .clipShape(.rect(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(hovering ? Color.primary.opacity(0.25) : Color.cardBorder, lineWidth: 1)
                )
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: hovering)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isWatched ? .secondary : .primary)
                    .lineLimit(1)
                Text(showTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(.rect(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(showTitle)")
        .accessibilityValue(isWatched ? "Watched" : progress?.isResumable == true ? "In progress" : "")
        .onHover { hovering = $0 }
    }
}

// MARK: - Continue Watching Card

struct ContinueWatchingCard: View {
    let item: StoredMediaItem
    var onPlay: () -> Void
    var onMarkWatched: () -> Void
    var onRemove: () -> Void

    var body: some View {
        Button(action: onPlay) {
            PosterCard(
                title: item.title,
                subtitle: subtitleText,
                posterURL: item.posterURL ?? item.bannerURL,
                progressFraction: item.displayProgress,
                layout: .shelf(posterWidth: 168),
            )
        }
        .buttonStyle(PressFeedbackButtonStyle())
        .accessibilityLabel("Resume \(item.title)")
        .contextMenu {
            Button {
                onPlay()
            } label: {
                Label("Resume Playback", systemImage: "play.fill")
            }
            Button {
                onMarkWatched()
            } label: {
                Label("Mark as Watched", systemImage: "checkmark.circle")
            }
            Divider()
            Button(role: .destructive) {
                onRemove()
            } label: {
                Label("Remove from Continue Watching", systemImage: "trash")
            }
        }
    }

    private var subtitleText: String? {
        let position = item.episodePositionLabel
        // Duration can be unknown (some providers) — then there is no honest
        // "left" figure to show and we render the position alone.
        switch (position, item.remainingLabel) {
        case let (position?, remaining?):
            return "\(position) • \(remaining) left"
        case let (position?, nil):
            return position
        case let (nil, remaining?):
            return "\(remaining) left"
        case (nil, nil):
            return MediaTypeDisplay.name(for: item.mediaType)
        }
    }
}

// MARK: - Recently Searched Card

struct RecentlySearchedCard: View {
    let result: SearchResultDto
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                PosterImage(url: result.posterUrl, headers: result.posterHeaders, contentMode: .fit)
                    .frame(width: 76, height: 46)
                    .clipShape(.rect(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(result.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Text(MediaTypeDisplay.name(for: result.type))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(width: 250, height: 64)
            .background(hovering ? Color.hoverFill : Color.cardSurface, in: .rect(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.cardBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(result.name)
        .onHover { hovering in
            self.hovering = hovering
        }
    }
}
