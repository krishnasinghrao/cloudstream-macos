import AppKit
import SwiftUI

/// MediaDetailView: Apple TV macOS media details layout.
/// Features a prominent top-anchored hero backdrop with buttons and metadata
/// positioned lower down to showcase the artwork cleanly.
/// Includes an expandable synopsis, the classic image-based Cast & Crew shelf,
/// and an episode list for series.
struct MediaDetailView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var windowSession

    let details: DetailsDto
    /// Re-fetches details bypassing the daemon cache (toolbar ⌘R).
    var onRefresh: (() -> Void)? = nil

    @State private var selectedSeason = 1
    /// Season whose "Download from…" source picker is open.
    @State private var seasonSourcePicker: Int?
    @State private var showMovieSourcePicker = false
    @State private var isPlotExpanded = false
    @State private var preferDub = false

    /// Library state cached per store version (P2-20): the hero screen
    /// re-renders often (hover, selection), and re-running four synchronous
    /// SwiftData fetches per render stalls the main thread. `.task(id:)` on
    /// the store version refreshes the cache off the render path and doubles
    /// as the observation hook for mutations.
    @State private var cachedIsFavorite = false
    @State private var cachedWatchType: WatchType?
    @State private var cachedResume: StoredMediaItem?
    /// Every source of this title, its primary first (ADR-0020); one entry when not merged.
    @State private var cachedSources: [StoredMediaItem] = []
    /// The library entry this page shows, so the Sources row can mark it.
    @State private var cachedItemID: String?
    /// Per-episode history keyed by `EpisodeDto.data` (Phase 1).
    @State private var cachedProgress: [String: EpisodeProgressSnapshot] = [:]
    /// Episode waiting on the "Resume / Start Over" choice.
    @State private var resumePrompt: ResumePrompt?
    @State private var didAutoSelectSeason = false
    @State private var noteDraft = ""
    @State private var noteLoaded = false
    /// The profile store the draft was loaded from; a save never lands in another profile.
    @State private var noteOwner: LibraryStore.ProfileOperationContext?
    @FocusState private var noteFocused: Bool

    struct ResumePrompt: Identifiable {
        let episode: EpisodeDto
        let position: Double
        var id: String { episode.data }
    }

    private func refreshLibraryState() {
        cachedIsFavorite = LibraryStore.shared.readForDisplay(or: false, { try LibraryStore.shared.isFavorite(details: details) })
        cachedWatchType = LibraryStore.shared.readForDisplay(or: nil, { try LibraryStore.shared.watchType(details: details) })
        cachedResume = LibraryStore.shared.readForDisplay(or: nil, { try LibraryStore.shared.resumeItem(for: details) })
        cachedSources = LibraryStore.shared.readForDisplay(or: [], { try LibraryStore.shared.titleSources(details: details) })
        cachedItemID = cachedSources.count > 1
            ? LibraryStore.shared.readForDisplay(or: nil, { try LibraryStore.shared.persistedItemID(for: details) }) : nil
        cachedProgress = details.isSeries ? LibraryStore.shared.readForDisplay(or: [:], { try LibraryStore.shared.episodeProgress(details: details) }) : [:]
        if !noteLoaded || !noteFocused {
            noteDraft = titleEntry?.userNote ?? ""
            noteOwner = try? LibraryStore.shared.captureProfileOperation()
            noteLoaded = true
        }
        if !didAutoSelectSeason {
            didAutoSelectSeason = true
            // Open on the season the user is actually in, not always Season 1.
            if let season = nextPick?.episode.season, availableSeasons.contains(season) {
                selectedSeason = season
            }
        }
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                heroSection
                synopsisSection
                personalSection

                if !details.actors.isEmpty {
                    castSection
                }

                if details.isSeries {
                    episodeSection
                        .padding(.horizontal, 36)
                        .padding(.top, 24)
                }

                if let recommendations = details.recommendations, !recommendations.isEmpty {
                    recommendationsSection(recommendations)
                }
            }
            .padding(.bottom, 60)
        }
        // The safe-area edge, title and toolbar background belong to the one
        // container that hosts this view (DetailsDestinationView): applied at
        // both levels they fought in full screen and clipped the toolbar
        // (Remediation 1.2).
        .task(id: LibraryStore.shared.version) {
            refreshLibraryState()
        }
        .userActivity(UserActivityType.viewTitle) { activity in
            activity.title = details.name
            activity.isEligibleForHandoff = true
            activity.isEligibleForSearch = false
            var info = ["provider": details.provider, "url": details.url]
            if let providerID = details.providerId { info["providerId"] = providerID }
            activity.userInfo = info
            activity.requiredUserInfoKeys = ["provider", "url"]
        }
        .confirmationDialog(
            resumePrompt.map { "Resume \(PlayerViewModel.episodeLabel(for: $0.episode, fallbackIndex: nil))?" } ?? "",
            isPresented: Binding(get: { resumePrompt != nil }, set: { if !$0 { resumePrompt = nil } }),
            presenting: resumePrompt,
        ) { prompt in
            Button("Resume from \(WatchProgressPolicy.timestamp(prompt.position))") {
                startEpisode(prompt.episode, resumeAt: prompt.position)
            }
            .keyboardShortcut(.defaultAction)
            Button("Start Over") {
                startEpisode(prompt.episode, resumeAt: nil)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("You can change this in Settings ▸ Playback.")
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) { actionButtons }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        if let onRefresh {
            Button(action: onRefresh) {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            .labelStyle(.iconOnly)
            .keyboardShortcut("r", modifiers: .command)
            .help("Reload details from the provider (⌘R)")
        }

        let isFavorite = cachedIsFavorite
        Button {
            LibraryStore.shared.perform { try LibraryStore.shared.toggleFavorite(details: details) }
        } label: {
            Label(
                isFavorite ? "Remove from Favorites" : "Add to Favorites",
                systemImage: isFavorite ? "heart.fill" : "heart",
            )
        }
        .labelStyle(.iconOnly)
        .keyboardShortcut("d", modifiers: .command)
        .help(isFavorite ? "Remove from Favorites (⌘D)" : "Add to Favorites (⌘D)")

        AddToPageMenu(details: details)
            .labelStyle(.iconOnly)
            .help("Add this title to one of your pages")

        if let shareURL = externalURL {
            ShareLink(item: shareURL) {
                Label("Share Link", systemImage: "square.and.arrow.up")
            }
            .labelStyle(.iconOnly)
            .help("Share Link")

            Button {
                NSWorkspace.shared.open(shareURL)
            } label: {
                Label("Open in Browser", systemImage: "safari")
            }
            .labelStyle(.iconOnly)
            .help("Open in Browser")
        }
    }

    // MARK: - Actions

    private var externalURL: URL? {
        guard let url = URL(string: details.url),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    /// Primary button: resumes the in-progress episode or starts the next
    /// unwatched one (Android's "Play S2 · E6"). Movies resume their position.
    private func play() {
        if details.isSeries {
            guard let pick = nextPick else { return }
            startEpisode(pick.episode, resumeAt: pick.resumeAt)
            return
        }
        let resume = LibraryStore.shared.readForDisplay(or: nil, { try LibraryStore.shared.resumeItem(for: details) })
        let position = resume?.progressSeconds ?? 0
        let finished = resume.map { WatchProgressPolicy.isWatched(position: $0.progressSeconds, duration: $0.totalDurationSeconds) } ?? false
        startEpisode(nil, resumeAt: position > WatchProgressPolicy.minimumResumeSeconds && !finished ? position : nil)
    }

    private func startEpisode(_ episode: EpisodeDto?, resumeAt: Double?) {
        Task {
            await appState.player.play(
                details: details,
                episode: episode,
                resumeAt: resumeAt,
                preferences: UserPreferences.shared,
            )
        }
    }

    /// Episode-row tap: honours Settings ▸ Playback ▸ "When Resuming".
    private func playEpisodeFromRow(_ episode: EpisodeDto) {
        guard let snapshot = cachedProgress[episode.data], snapshot.isResumable else {
            startEpisode(episode, resumeAt: nil)
            return
        }
        switch UserPreferences.shared.resumeBehavior {
        case .ask: resumePrompt = ResumePrompt(episode: episode, position: snapshot.positionSeconds)
        case .alwaysResume: startEpisode(episode, resumeAt: snapshot.positionSeconds)
        case .alwaysStartOver: startEpisode(episode, resumeAt: nil)
        }
    }

    /// What the primary button plays for a series.
    private var nextPick: NextEpisodeResolver.Pick? {
        NextEpisodeResolver.pick(
            episodes: playbackOrder,
            progress: cachedProgress,
            lastEpisodeData: cachedResume?.lastEpisodeData,
        )
    }

    /// Every episode in viewing order, following the sub/dub preference.
    private var playbackOrder: [EpisodeDto] {
        PlaybackSequence(episodes: details.episodes, edition: details.isAnime ? (preferDub ? "dub" : "sub") : nil).episodes
    }

    private func downloadSeason(season: Int, source: DownloadPolicy.SourceChoice? = nil) {
        let requests = episodes(forSeason: season).map { downloadRequest(for: $0, source: source) }
        DownloadService.shared.enqueueBatch(requests)
    }

    /// The episode whose sources stand in for the season: the first one that
    /// would actually be downloaded.
    private func sourceSampleEpisode(forSeason season: Int) -> EpisodeDto? {
        let seasonEpisodes = episodes(forSeason: season)
        return seasonEpisodes.first { episode in
            DownloadService.shared.activeItem(forProvider: details.provider, episodeData: episode.data) == nil
                && DownloadService.shared.completedRecord(provider: details.provider, episodeData: episode.data) == nil
        } ?? seasonEpisodes.first
    }

    @ViewBuilder
    private func seasonSourcePickerContent(season: Int) -> some View {
        if let sample = sourceSampleEpisode(forSeason: season) {
            DownloadSourcePicker(
                title: "Download Season \(season) from",
                footnote: "Sources of \(PlayerViewModel.episodeLabel(for: sample, fallbackIndex: details.episodes.firstIndex(of: sample))). Episodes without this source use the best available one.",
                provider: details.provider,
                providerID: details.providerId,
                episodeData: sample.data,
            ) { source in
                downloadSeason(season: season, source: source)
            }
        }
    }

    private func downloadMovie(source: DownloadPolicy.SourceChoice? = nil) {
        guard let dataString = details.movieData else { return }
        DownloadService.shared.enqueue(
            DownloadService.Request(
                title: details.name,
                episodeLabel: "Movie",
                provider: details.provider,
                providerID: details.providerId,
                episodeData: dataString,
                directory: UserPreferences.shared.downloadDirectory,
                baseName: details.name,
                durationSeconds: details.durationMinutes.map { Double($0) * 60 },
                preferredSource: source,
            ),
        )
    }

    private func enqueueEpisodeDownload(_ episode: EpisodeDto, source: DownloadPolicy.SourceChoice? = nil) {
        DownloadService.shared.enqueue(downloadRequest(for: episode, source: source))
    }

    /// Series files go into a per-show folder (Android parity); dubbed
    /// episodes get a suffix so they never share a name with the sub.
    private func downloadRequest(for episode: EpisodeDto, source: DownloadPolicy.SourceChoice? = nil) -> DownloadService.Request {
        let label = PlayerViewModel.episodeLabel(for: episode, fallbackIndex: details.episodes.firstIndex(of: episode))
        let audioSuffix = episode.isDub ? " (Dub)" : ""
        return DownloadService.Request(
            title: details.name,
            episodeLabel: label + audioSuffix,
            provider: details.provider,
            providerID: details.providerId,
            episodeData: episode.data,
            directory: UserPreferences.shared.downloadDirectory
                .appendingPathComponent(DownloadService.sanitizedFileName(details.name), isDirectory: true),
            baseName: "\(details.name) \(label)\(audioSuffix)",
            durationSeconds: episode.runTimeMinutes.map { Double($0) * 60 },
            preferredSource: source,
        )
    }

    // MARK: - Hero Section

    /// What the hero can show (Remediation 1.3): a widescreen backdrop fills
    /// the full-height banner; a lone portrait poster is centred over a
    /// blurred copy of itself instead of being stretched; with no artwork the
    /// banner collapses to a compact gradient instead of a vacant 580 pt box.
    enum HeroArtwork: Equatable {
        case backdrop(String)
        case poster(String)
        case none

        init(details: DetailsDto) {
            if let banner = details.backgroundPosterUrl?.nonEmpty { self = .backdrop(banner) }
            else if let poster = details.posterUrl?.nonEmpty { self = .poster(poster) }
            else { self = .none }
        }

        var height: CGFloat {
            switch self {
            case .backdrop: 580
            case .poster: 440
            case .none: 260
            }
        }
    }

    @ViewBuilder
    private func heroArtwork(_ artwork: HeroArtwork, height: CGFloat) -> some View {
        switch artwork {
        case .backdrop(let url):
            PosterImage(url: url, alignment: .top, headers: details.posterHeaders, rendition: .full)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .clipped()
        case .poster(let url):
            ZStack {
                PosterImage(url: url, alignment: .center, headers: details.posterHeaders, rendition: .full)
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .blur(radius: 40, opaque: true)
                    .opacity(0.55)
                    .clipped()
                    .accessibilityHidden(true)
                PosterImage(url: url, alignment: .center, headers: details.posterHeaders, rendition: .full)
                    .aspectRatio(2 / 3, contentMode: .fit)
                    .frame(height: height - 120)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 48)
                    .padding(.bottom, 60)
            }
            .frame(height: height)
        case .none:
            LinearGradient(colors: [Color.accentColor.opacity(0.28), Color.canvas], startPoint: .topLeading, endPoint: .bottomTrailing)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .accessibilityHidden(true)
        }
    }

    private var heroSection: some View {
        let artwork = HeroArtwork(details: details)
        let heroHeight = artwork.height

        return ZStack(alignment: .bottomLeading) {
            heroArtwork(artwork, height: heroHeight)

            // Smooth bottom gradient transition into canvas behind the title, metadata, and buttons.
            // Upper 55% remains completely clear so artwork typography and faces are unobscured.
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .clear, location: 0.55),
                    .init(color: Color.canvas.opacity(0.4), location: 0.72),
                    .init(color: Color.canvas.opacity(0.85), location: 0.88),
                    .init(color: Color.canvas, location: 1.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            // Content inside the hero pinned to the bottom: Title, Metadata, Action Buttons
            VStack(alignment: .leading, spacing: 10) {
                // 1. Title: the provider's logo artwork when it has one, else text
                HeroTitle(name: details.name, logoURL: details.logoUrl, headers: details.posterHeaders)

                // 2. Metadata Badges Row (Left badges, Right provider pill)
                metadataBadges

                if let nextAiring = details.nextAiring, nextAiring.date > Date() {
                    nextAiringBadge(nextAiring)
                }

                // 3. Action Buttons (Play, Watching, Download)
                actionBar
            }
            .padding(.horizontal, 36)
            .padding(.bottom, 16)
        }
        .frame(height: heroHeight)
    }

    // MARK: - Metadata Badges

    private var metadataBadges: some View {
        HStack(spacing: 8) {
            if let year = details.year {
                Text(String(year))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                Text("•")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.35))
            }

            if let rating = details.score {
                HStack(spacing: 3) {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                    Text(String(format: "%.1f", Double(rating) / 10.0))
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.yellow.opacity(0.18), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.yellow.opacity(0.3), lineWidth: 0.5))

                Text("•")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.35))
            }

            if let contentRating = details.contentRating, !contentRating.isEmpty {
                Text(contentRating)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.4), lineWidth: 1)
                    )

                Text("•")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.35))
            }

            Text(MediaTypeDisplay.name(for: details.type))
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))

            if let status = details.showStatus {
                let ongoing = status.caseInsensitiveCompare("Ongoing") == .orderedSame
                Text(ongoing ? "Ongoing" : "Completed")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(ongoing ? Color.green : .white.opacity(0.85))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background((ongoing ? Color.green : Color.white).opacity(0.15), in: Capsule())
                    .accessibilityLabel(ongoing ? "Currently airing" : "Finished airing")
            }

            if let duration = details.durationMinutes {
                Text("•")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.35))
                Text(MediaTypeDisplay.duration(minutes: duration))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
            }

            if !details.tags.isEmpty {
                Text("•")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.35))
                Text(details.tags.prefix(2).joined(separator: ", "))
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }

            Spacer()

            Text(details.provider)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 9)
                .padding(.vertical, 3.5)
                .background(Color.white.opacity(0.12), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5))
        }
    }

    private func nextAiringBadge(_ nextAiring: NextAiringDto) -> some View {
        let label = nextAiring.season.map { "S\($0) · E\(nextAiring.episode)" } ?? "Episode \(nextAiring.episode)"
        return HStack(spacing: 6) {
            Image(systemName: "calendar.badge.clock")
            Text("\(label) airs ") + Text(nextAiring.date, style: .relative).monospacedDigit()
            Text("·")
                .foregroundStyle(.white.opacity(0.4))
            Text(nextAiring.date, format: .dateTime.weekday(.abbreviated).month().day().hour().minute())
                .foregroundStyle(.white.opacity(0.7))
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(.white)
        .help("Next episode air date from the provider")
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        let currentWatchType = cachedWatchType

        return HStack(spacing: 12) {
            // Signature Apple TV Primary Play Pill (Solid white capsule with black text)
            Button {
                play()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill")
                        .font(.body.weight(.bold))
                    Text(playButtonTitle)
                        .font(.body.weight(.bold))
                }
                .foregroundStyle(.black)
                .padding(.horizontal, 22)
                .padding(.vertical, 9)
                .background(Capsule().fill(Color.white))
                .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 2)
            }
            .buttonStyle(PressFeedbackButtonStyle())
            .help(playButtonTitle)

            // Watch Status Capsule (Frosted Translucent)
            Menu {
                ForEach(WatchType.allCases) { type in
                    Button {
                        LibraryStore.shared.perform { try LibraryStore.shared.upsertLibraryEntry(details: details, watchType: type) }
                    } label: {
                        Label(type.label, systemImage: type.symbolName)
                    }
                }

                if currentWatchType != nil {
                    Divider()
                    Button(role: .destructive) {
                        LibraryStore.shared.perform { try LibraryStore.shared.removeFromLibrary(details: details) }
                    } label: {
                        Label("Remove from Library", systemImage: "trash")
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: currentWatchType?.symbolName ?? "plus")
                    Text(currentWatchType?.label ?? "Add to Library")
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .font(.body.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Capsule().fill(Color.white.opacity(0.15)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Set watch status")

            // Download Capsule
            if details.isSeries {
                let seasonEpisodes = episodes(forSeason: selectedSeason)
                let activeCountInSeason = seasonEpisodes.filter { ep in
                    DownloadService.shared.activeItem(forProvider: details.provider, episodeData: ep.data) != nil
                }.count

                Menu {
                    ForEach(availableSeasons, id: \.self) { season in
                        let episodesInSeason = episodes(forSeason: season)
                        let seasonActive = episodesInSeason.contains { ep in
                            DownloadService.shared.activeItem(forProvider: details.provider, episodeData: ep.data) != nil
                        }
                        if seasonActive {
                            Button("Cancel Season \(season) Downloads") {
                                // Active items only: finished downloads in
                                // the season keep their files.
                                for ep in episodesInSeason {
                                    if let item = DownloadService.shared.activeItem(forProvider: details.provider, episodeData: ep.data) {
                                        DownloadService.shared.cancel(item)
                                    }
                                }
                            }
                        } else {
                            Button("Download Season \(season)") {
                                downloadSeason(season: season)
                            }
                            Button("Download Season \(season) from…") {
                                seasonSourcePicker = season
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        if activeCountInSeason > 0 {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .controlSize(.small)
                            Text("Downloading Season (\(activeCountInSeason)/\(seasonEpisodes.count))")
                        } else {
                            Image(systemName: "arrow.down.circle")
                            Text("Download Season")
                        }
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .font(.body.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Color.white.opacity(0.15)))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Download or cancel a full season — right-click to choose a source")
                .contextMenu {
                    Button("Download Season \(selectedSeason) from…") {
                        seasonSourcePicker = selectedSeason
                    }
                }
                .popover(
                    isPresented: Binding(
                        get: { seasonSourcePicker != nil },
                        set: { if !$0 { seasonSourcePicker = nil } },
                    ),
                    arrowEdge: .bottom,
                ) {
                    if let season = seasonSourcePicker {
                        seasonSourcePickerContent(season: season)
                    }
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.75), value: activeCountInSeason)
            } else if let movieData = details.movieData {
                movieDownloadCapsule(movieData: movieData)
            }

            if let trailer = details.trailers?.first {
                Button {
                    Task { await appState.player.playTrailer(trailer, for: details) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "film")
                        Text("Trailer")
                    }
                    .font(.body.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Color.white.opacity(0.15)))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Play the trailer")
            }

            Spacer()
        }
        .padding(.top, 2)
    }

    private var playButtonTitle: String {
        // Short numbered label only; an episode *name* (e.g. a full YouTube
        // video title) does not belong in the primary button.
        if details.isSeries {
            guard let pick = nextPick else { return "Play" }
            let verb = pick.resumeAt != nil ? "Resume" : "Play"
            guard let number = pick.episode.episode else { return verb }
            if let season = pick.episode.season {
                return "\(verb) S\(season) · E\(number)"
            }
            return "\(verb) E\(number)"
        }
        if let resume = cachedResume, resume.progressSeconds > WatchProgressPolicy.minimumResumeSeconds,
           !WatchProgressPolicy.isWatched(position: resume.progressSeconds, duration: resume.totalDurationSeconds) {
            if resume.totalDurationSeconds > 0 {
                return "Resume · " + WatchProgressPolicy.remainingLabel(resume.totalDurationSeconds - resume.progressSeconds)
            }
            return "Resume"
        }
        return "Play"
    }

    // MARK: - Synopsis Section (Canvas)

    @ViewBuilder
    private var synopsisSection: some View {
        let cleanPlot = HTMLStringSanitizer.sanitize(details.plot)
        if !cleanPlot.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(cleanPlot)
                    .font(.body)
                    .lineSpacing(4)
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .lineLimit(isPlotExpanded ? nil : 4)

                Button(isPlotExpanded ? "Less" : "More") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isPlotExpanded.toggle()
                    }
                }
                .buttonStyle(.borderless)
                .font(.callout.weight(.medium))
                .foregroundStyle(Color.accentColor)
            }
            .frame(maxWidth: 860, alignment: .leading)
            .padding(.horizontal, 36)
            .padding(.top, 24)
        }
    }

    // MARK: - Personal rating & note (Phase 6)

    /// Where the title's rating and note live: its primary source when merged.
    private var titleEntry: StoredMediaItem? { cachedSources.first ?? cachedResume }

    private var personalSection: some View {
        let rating = titleEntry?.userRating ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                HStack(spacing: 2) {
                    ForEach(1...5, id: \.self) { star in
                        Button {
                            LibraryStore.shared.perform { try LibraryStore.shared.setUserRating(details: details, rating: star == rating ? 0 : star) }
                        } label: {
                            Image(systemName: star <= rating ? "star.fill" : "star")
                                .foregroundStyle(star <= rating ? Color.yellow : Color.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help(star == rating ? "Clear rating" : "Rate \(star) of 5")
                        .accessibilityLabel("\(star) star\(star == 1 ? "" : "s")")
                        .accessibilityAddTraits(star <= rating ? .isSelected : [])
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Your rating")

                TextField("Add a private note…", text: $noteDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .focused($noteFocused)
                    .onSubmit(saveNote)
                    .onChange(of: noteFocused) { _, focused in if !focused { saveNote() } }
                    .frame(maxWidth: 520)

                Spacer()

                Button {
                    windowSession.searchQuery = details.name
                    windowSession.navigateTo(.search)
                    windowSession.commitSearch()
                } label: {
                    Label("Find on Other Providers", systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("Search every installed provider for “\(details.name)”")
            }
            if cachedSources.count > 1 {
                sourcesRow
            }
        }
        .frame(maxWidth: 1100, alignment: .leading)
        .padding(.horizontal, 36)
        .padding(.top, 16)
        .onDisappear(perform: saveNote)
    }

    /// The title's sources (ADR-0020): open another one, or separate a merged one again.
    private var sourcesRow: some View {
        HStack(spacing: 8) {
            Text("Sources").font(.callout).foregroundStyle(.secondary)
            ForEach(cachedSources, id: \.id) { source in
                sourceControl(source, isCurrent: source.id == cachedItemID)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sources of this title")
    }

    @ViewBuilder
    private func sourceControl(_ source: StoredMediaItem, isCurrent: Bool) -> some View {
        let label = Text(source.providerName).font(.callout.weight(isCurrent ? .semibold : .regular))
        if isCurrent, source.mergedIntoID == nil {
            // The title's primary, viewed now: nothing to open or separate.
            label.help("You are viewing this source")
        } else {
            Menu {
                if !isCurrent {
                    Button("Open This Source") {
                        windowSession.openLibraryItem(id: source.id, provider: source.providerName,
                                                      providerID: source.providerID, url: source.providerURL)
                    }
                }
                if source.mergedIntoID != nil {
                    Button("Separate from This Title") {
                        LibraryStore.shared.perform { try LibraryStore.shared.separateSource(itemID: source.id) }
                    }
                }
            } label: {
                label
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(isCurrent ? "You are viewing this source" : "Open or separate this source")
        }
    }

    private func saveNote() {
        let current = titleEntry?.userNote ?? ""
        let trimmed = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != current, let noteOwner, LibraryStore.shared.owns(noteOwner) else { return }
        LibraryStore.shared.perform { try LibraryStore.shared.setUserNote(details: details, note: trimmed) }
    }

    // MARK: - Cast & Crew Section (Canvas)

    private var castSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Cast & Crew")
                .font(.title3.weight(.semibold))

            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(details.actors, id: \.self) { actor in
                        CastCard(actor: actor)
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.horizontal, 36)
        .padding(.top, 24)
    }

    // MARK: - More Like This

    private func recommendationsSection(_ items: [SearchResultDto]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider()
                .padding(.top, 8)
            Text("More Like This")
                .font(.title3.weight(.semibold))
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(items) { item in
                        Button {
                            windowSession.openDetails(item)
                        } label: {
                            PosterCard(
                                title: item.name,
                                subtitle: [item.year.map(String.init), MediaTypeDisplay.name(for: item.type)].compactMap { $0 }.first,
                                posterURL: item.posterUrl,
                                posterHeaders: item.posterHeaders,
                            )
                        }
                        .buttonStyle(.plain)
                        .frame(width: 150)
                        .help(item.name)
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.horizontal, 36)
        .padding(.top, 24)
    }

    // MARK: - Episodes Section

    private var episodeSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Divider()
                .padding(.top, 8)

            HStack(spacing: 12) {
                Text("Episodes")
                    .font(.title3.weight(.semibold))

                Spacer()

                if details.isAnime {
                    Picker("Audio", selection: $preferDub) {
                        Text("Subbed").tag(false)
                        Text("Dubbed").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 140)
                    .help("Prefer subbed or dubbed episodes")
                }

                if availableSeasons.count > 1 {
                    Picker("Season", selection: $selectedSeason) {
                        ForEach(availableSeasons, id: \.self) { season in
                            Text(details.seasonTitle(season)).tag(season)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(minWidth: 140, maxWidth: 260)
                    .fixedSize()
                }

                seasonWatchMenu
            }

            // Lazy: providers can return hundreds of episodes per season.
            LazyVStack(spacing: 10) {
                ForEach(Array(episodesForSelectedSeason().enumerated()), id: \.element.id) { index, episode in
                    EpisodeRow(
                        episode: episode,
                        provider: details.provider,
                        title: details,
                        indexLabel: "Episode \(episode.episode ?? index + 1)",
                        progress: cachedProgress[episode.data],
                        isUpNext: nextPick?.episode == episode,
                        onPlay: {
                            playEpisodeFromRow(episode)
                        },
                        onSetWatched: { watched in
                            LibraryStore.shared.perform { try LibraryStore.shared.setEpisodesWatched(details: details, episodes: [episode], watched: watched) }
                        },
                        onMarkPreviousWatched: {
                            LibraryStore.shared.perform { try LibraryStore.shared.markPreviousWatched(details: details, orderedEpisodes: playbackOrder, upTo: episode) }
                        },
                        onPlayLocal: { localURL in
                            Task {
                                await appState.player.play(
                                    details: details,
                                    episode: episode,
                                    preferences: UserPreferences.shared,
                                    localMediaURL: localURL,
                                )
                            }
                        },
                        onDownload: {
                            enqueueEpisodeDownload(episode)
                        },
                        providerID: details.providerId,
                        onDownloadFrom: { source in
                            enqueueEpisodeDownload(episode, source: source)
                        },
                    )
                }
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func movieDownloadCapsule(movieData: String) -> some View {
        let queueItem = DownloadService.shared.queueItem(forProvider: details.provider, episodeData: movieData)
        let completedRecord = DownloadService.shared.completedRecord(provider: details.provider, episodeData: movieData)

        if let item = queueItem, item.state == .downloading || item.state == .resolving || item.state == .queued || item.state == .paused {
            Button {
                DownloadService.shared.cancel(item)
            } label: {
                HStack(spacing: 6) {
                    if item.state == .downloading {
                        ProgressView(value: item.progress)
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                        Text("Downloading \(item.progressLabel)")
                    } else if item.state == .resolving {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                        Text("Preparing…")
                    } else if item.state == .paused {
                        Image(systemName: "pause.circle.fill")
                        Text("Paused")
                    } else {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                        Text("Queued")
                    }
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                }
                .font(.body.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Capsule().fill(Color.white.opacity(0.15)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Cancel download")
            .animation(.spring(response: 0.35, dampingFraction: 0.75), value: item.state)
        } else if let completed = completedRecord {
            Menu {
                Button("Play Local File") {
                    Task {
                        await appState.player.play(
                            details: details,
                            episode: nil,
                            preferences: UserPreferences.shared,
                            localMediaURL: completed.destinationURL,
                        )
                    }
                }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([completed.destinationURL])
                }
                Divider()
                Button("Delete Download", role: .destructive) {
                    DownloadService.shared.deleteCompleted(
                        recordID: completed.id,
                        provider: completed.provider,
                        destinationURL: completed.destinationURL,
                    )
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                    Text("Downloaded")
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .font(.body.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Capsule().fill(Color.white.opacity(0.15)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
            }
            .menuStyle(.borderlessButton)
            .help("Downloaded — click for actions")
        } else {
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                    downloadMovie()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle")
                    Text("Download")
                }
                .font(.body.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Capsule().fill(Color.white.opacity(0.15)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Download this movie — right-click to choose a source")
            .contextMenu {
                Button("Download from…") { showMovieSourcePicker = true }
            }
            .popover(isPresented: $showMovieSourcePicker, arrowEdge: .bottom) {
                DownloadSourcePicker(
                    title: "Download from",
                    footnote: nil,
                    provider: details.provider,
                    providerID: details.providerId,
                    episodeData: movieData,
                ) { source in
                    downloadMovie(source: source)
                }
            }
        }
    }

    /// "8 of 12 watched" + bulk marking for the visible season.
    private var seasonWatchMenu: some View {
        let seasonEpisodes = episodesForSelectedSeason()
        let watchedCount = seasonEpisodes.filter { cachedProgress[$0.data]?.watched == true }.count
        let allWatched = !seasonEpisodes.isEmpty && watchedCount == seasonEpisodes.count
        return Menu {
            Button(allWatched ? "Mark Season as Unwatched" : "Mark Season as Watched") {
                LibraryStore.shared.perform { try LibraryStore.shared.setEpisodesWatched(details: details, episodes: seasonEpisodes, watched: !allWatched) }
            }
            Button("Mark All Episodes as Watched") {
                LibraryStore.shared.perform { try LibraryStore.shared.setEpisodesWatched(details: details, episodes: playbackOrder, watched: true) }
            }
            Divider()
            Button("Clear Watch History", role: .destructive) {
                LibraryStore.shared.perform { try LibraryStore.shared.clearWatchHistory(details: details) }
            }
            .disabled(cachedProgress.isEmpty)
        } label: {
            Label("\(watchedCount)/\(seasonEpisodes.count) watched", systemImage: allWatched ? "checkmark.circle.fill" : "checkmark.circle")
                .font(.callout.monospacedDigit())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Watched episodes in this season")
    }

    private var availableSeasons: [Int] {
        let seasons = Set(details.episodes.compactMap(\.season)).filter { $0 > 0 }
        return seasons.isEmpty ? [1] : seasons.sorted()
    }

    private func episodesForSelectedSeason() -> [EpisodeDto] {
        episodes(forSeason: selectedSeason)
    }

    /// The episodes shown for a season — also what "Download Season"
    /// queues: season-less shows fall back to every episode, and anime
    /// follows the Sub/Dub preference instead of downloading both.
    private func episodes(forSeason season: Int) -> [EpisodeDto] {
        var forSeason = details.episodes.filter { $0.season == season }
        if forSeason.isEmpty {
            forSeason = details.episodes
        }

        if details.isAnime {
            let wanted = preferDub ? "dub" : "sub"
            let filtered = forSeason.filter { $0.audio == wanted }
            if !filtered.isEmpty {
                forSeason = filtered
            }
        }

        return forSeason.sorted { ($0.episode ?? 0) < ($1.episode ?? 0) }
    }
}

// MARK: - Hero Title

/// The title in the hero. Shows the provider's logo artwork (`logoUrl`) in
/// place of the text, matching the Android app. While a logo is loading the
/// title is held back so the text never flashes and then swaps; the text
/// appears only when there is no logo, it fails, or it is slow to arrive.
/// Whichever of the two appears first stays for the visit — a logo that
/// lands after the text is only cached for next time.
private struct HeroTitle: View {
    let name: String
    let logoURL: String?
    var headers: [String: String]? = nil
    @State private var logo: NSImage?
    /// The logo failed or is taking too long; show the text instead.
    @State private var fellBack = false

    /// How long a blank title is tolerated before the text steps in.
    private static let patience: Duration = .seconds(1.5)

    private var hasLogoURL: Bool {
        logoURL?.isEmpty == false
    }

    var body: some View {
        // A cached logo is used on the very first frame, with no fade.
        let shown = fellBack ? nil : logo ?? logoURL.flatMap { ImageCache.shared.synchronousMemoryImage(for: $0, headers: headers) }

        ZStack(alignment: .bottomLeading) {
            if let shown {
                Image(nsImage: shown)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 380, maxHeight: 130, alignment: .bottomLeading)
                    .shadow(color: .black.opacity(0.6), radius: 8, x: 0, y: 2)
                    .accessibilityLabel(name)
                    .accessibilityAddTraits(.isHeader)
                    .transition(.opacity)
            } else {
                Text(name)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .shadow(color: .black.opacity(0.8), radius: 6, x: 0, y: 2)
                    // Keeps its space while the logo loads, without showing.
                    .opacity(hasLogoURL && !fellBack ? 0 : 1)
                    .transition(.opacity)
            }
        }
        .task(id: logoURL) {
            logo = nil
            fellBack = false
            guard let logoURL, !logoURL.isEmpty else { return }
            let loaded = await ImageCache.shared.image(for: logoURL, headers: headers)
            guard !Task.isCancelled, !fellBack else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                logo = loaded
                fellBack = loaded == nil
            }
        }
        .task(id: logoURL) {
            guard hasLogoURL else { return }
            try? await Task.sleep(for: Self.patience)
            guard !Task.isCancelled, logo == nil else { return }
            withAnimation(.easeOut(duration: 0.25)) { fellBack = true }
        }
    }
}

private extension String {
    var nonEmpty: String? { trimmingCharacters(in: .whitespaces).isEmpty ? nil : self }
}
