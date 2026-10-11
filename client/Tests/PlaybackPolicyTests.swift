import XCTest
@testable import CloudStream

/// Offline-Features-Plan Phases 4–5: pure playback policies.
final class PlaybackPolicyTests: XCTestCase {
    private func link(_ source: String, _ quality: Int) -> StreamLinkDto {
        StreamLinkDto(url: "https://cdn/\(source)/\(quality)", name: source, source: source, quality: quality, type: "video")
    }

    // MARK: Stream info

    func testStreamInfoNamesCodecsColourAndHDR() {
        var info = StreamInfo()
        info.apply("dwidth", .int64(3840)); info.apply("dheight", .int64(1600))
        info.apply("video-codec", .string("H.265 / HEVC (High Efficiency Video Coding)"))
        info.apply("video-params/primaries", .string("bt.2020")); info.apply("video-params/gamma", .string("pq"))
        info.apply("hwdec-current", .string("videotoolbox")); info.renderer = "gpu"
        XCTAssertEqual(info.summary, "3840×1600 · H.265 · BT.2020 / PQ · HDR10 · VideoToolbox · GPU")
        XCTAssertEqual(StreamInfo.shortCodec("Google VP9"), "VP9")
        XCTAssertEqual(StreamInfo.shortCodec("Alliance for Open Media AV1"), "AV1")
        XCTAssertEqual(StreamInfo.shortCodec("H.264 / AVC / MPEG-4 AVC / MPEG-4 part 10"), "H.264")
        info.apply("current-tracks/video/dolby-vision-profile", .int64(5))
        XCTAssertEqual(info.dynamicRange, "Dolby Vision 5")
        info.apply("video-params/gamma", .string("")) // no video: cleared
        info.apply("current-tracks/video/dolby-vision-profile", .int64(0))
        XCTAssertEqual(info.dynamicRange, "—")
    }

    // MARK: LinkRanker

    func testDolbyVisionOnlyLinksGoLastWithinTheirTierButHDR10BasedOnesDoNot() {
        func named(_ name: String, _ quality: Int) -> StreamLinkDto {
            StreamLinkDto(url: "https://cdn/\(name)", name: name, source: "Src", quality: quality, type: "video")
        }
        let links = [named("Src 2160p DV", 2160), named("Src 2160p DV HDR10", 2160), named("Src 1080p", 1080),
                     named("Src 2160p Dolby Vision", 2160)]
        XCTAssertEqual(LinkRanker.rank(links, .none).map(\.name),
                       ["Src 2160p DV HDR10", "Src 1080p", "Src 2160p DV", "Src 2160p Dolby Vision"])
        XCTAssertFalse(LinkRanker.isDolbyVisionOnly(named("Server DVD-Rip", 720)), "words containing dv are not Dolby Vision")
    }

    func testDefaultOrderIsBestQualityFirstAndStable() {
        let links = [link("A", 720), link("B", 1080), link("C", 720), link("D", 0)]
        XCTAssertEqual(LinkRanker.rank(links, .none).map(\.source), ["B", "A", "C", "D"])
    }

    func testPreferredSourcesWinOverQuality() {
        let links = [link("Fast", 1080), link("Reliable", 720), link("Other", 2160)]
        let prefs = SourcePreferences(priority: ["reliable"], avoided: [], maxQuality: 0)
        XCTAssertEqual(LinkRanker.rank(links, prefs).map(\.source), ["Reliable", "Other", "Fast"])
    }

    func testAvoidedSourcesGoLastButAreKept() {
        let links = [link("Bad", 2160), link("Ok", 480)]
        let prefs = SourcePreferences(priority: [], avoided: ["bad"], maxQuality: 0)
        XCTAssertEqual(LinkRanker.rank(links, prefs).map(\.source), ["Ok", "Bad"])
    }

    func testQualityCapPrefersClosestAtOrBelow() {
        let links = [link("A", 2160), link("B", 1080), link("C", 720), link("D", 1440)]
        let prefs = SourcePreferences(priority: [], avoided: [], maxQuality: 1080)
        XCTAssertEqual(LinkRanker.rank(links, prefs).map(\.quality), [1080, 720, 1440, 2160])
    }

    func testRememberedSourceGoesFirstWithItsPickedQuality() {
        let links = [link("Fast", 1080), link("Mine", 1080), link("Mine", 720), link("Other", 2160)]
        let prefs = SourcePreferences(priority: ["fast"], avoided: ["mine"], maxQuality: 0)
        let ranked = LinkRanker.rank(links, prefs, remembered: RememberedSource(key: "mine", quality: 720))
        XCTAssertEqual(ranked.map { "\($0.source) \($0.quality)" }, ["Mine 720", "Mine 1080", "Fast 1080", "Other 2160"])
    }

    func testRememberedSourceThatIsNotOfferedLeavesTheOrderAlone() {
        let links = [link("A", 720), link("B", 1080)]
        XCTAssertEqual(LinkRanker.rank(links, .none, remembered: RememberedSource(key: "gone", quality: 1080)),
                       LinkRanker.rank(links, .none))
        XCTAssertEqual(LinkRanker.rank(links, .none, remembered: nil), LinkRanker.rank(links, .none))
    }

    func testSourceKeyIsCaseAndWhitespaceInsensitive() {
        XCTAssertEqual(LinkRanker.sourceKey("  VidPlay "), "vidplay")
    }

    func testDownloadsUseTheSameSourcePriority() {
        let links = [link("A", 1080), link("B", 720)]
        let ordered = DownloadPolicy.orderedCandidates(links, preferredQuality: 0, sources: SourcePreferences(priority: ["b"]))
        XCTAssertEqual(ordered.map(\.source), ["B", "A"])
    }

    // MARK: Chapters

    func testChapterTitlesClassify() {
        XCTAssertEqual(ChapterClassifier.kind(for: "Opening"), .intro)
        XCTAssertEqual(ChapterClassifier.kind(for: "OP2"), .intro)
        XCTAssertEqual(ChapterClassifier.kind(for: "Intro"), .intro)
        XCTAssertEqual(ChapterClassifier.kind(for: "Ending"), .credits)
        XCTAssertEqual(ChapterClassifier.kind(for: "ED"), .credits)
        XCTAssertEqual(ChapterClassifier.kind(for: "End Credits"), .credits)
        XCTAssertEqual(ChapterClassifier.kind(for: "Recap"), .recap)
        XCTAssertEqual(ChapterClassifier.kind(for: "Next Episode Preview"), .preview)
        XCTAssertNil(ChapterClassifier.kind(for: "Part A"))
        XCTAssertNil(ChapterClassifier.kind(for: "Development"), "substring 'op' must not match")
        XCTAssertNil(ChapterClassifier.kind(for: nil))
    }

    func testSegmentsUseNextChapterAsEnd() {
        let chapters = [
            MpvChapter(index: 0, title: "Prologue", time: 0),
            MpvChapter(index: 1, title: "Opening", time: 60),
            MpvChapter(index: 2, title: "Part A", time: 150),
            MpvChapter(index: 3, title: "Ending", time: 1300),
        ]
        let segments = ChapterClassifier.segments(from: chapters, duration: 1420)
        XCTAssertEqual(segments, [
            SkipSegment(kind: .intro, start: 60, end: 150),
            SkipSegment(kind: .credits, start: 1300, end: 1420),
        ])
        XCTAssertTrue(segments[0].contains(100))
        XCTAssertFalse(segments[0].contains(149.5), "hidden in the last second")
    }

    func testDegenerateSegmentsAreDropped() {
        let chapters = [MpvChapter(index: 0, title: "Opening", time: 10), MpvChapter(index: 1, title: "A", time: 11)]
        XCTAssertTrue(ChapterClassifier.segments(from: chapters, duration: 1000).isEmpty)
    }

    func testChapterNodeParsing() {
        let node: MpvNodeReader.NodeValue = .array([
            .map(["title": .string("Opening"), "time": .double(12.5)]),
            .map(["time": .int(90)]),
            .map(["title": .string("broken")]),
        ])
        let chapters = MpvNodeReader.chapters(from: node)
        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(chapters[0].title, "Opening")
        XCTAssertEqual(chapters[1].time, 90)
        XCTAssertNil(chapters[1].title)
    }

    // MARK: Up next

    func testUpNextStartsBeforeTheEnd() {
        XCTAssertEqual(UpNextPolicy.countdownStart(duration: 1440, countdown: 10, creditsStart: nil), 1430)
        XCTAssertNil(UpNextPolicy.countdownStart(duration: 1440, countdown: 0, creditsStart: nil))
        XCTAssertNil(UpNextPolicy.countdownStart(duration: 30, countdown: 10, creditsStart: nil), "clips never count down")
    }

    func testUpNextStartsAtCreditsWhenMarked() {
        XCTAssertEqual(UpNextPolicy.countdownStart(duration: 1440, countdown: 10, creditsStart: 1320), 1320)
        // A "credits" chapter in the first half is mislabelled — ignore it.
        XCTAssertEqual(UpNextPolicy.countdownStart(duration: 1440, countdown: 10, creditsStart: 200), 1430)
    }

    // MARK: Languages & tracks

    func testLanguageMatcherNormalisesCommonForms() {
        XCTAssertEqual(LanguageMatcher.code("en"), "en")
        XCTAssertEqual(LanguageMatcher.code("eng"), "en")
        XCTAssertEqual(LanguageMatcher.code("en-US"), "en")
        XCTAssertEqual(LanguageMatcher.code("English"), "en")
        XCTAssertEqual(LanguageMatcher.code("English (CC)"), "en")
        XCTAssertEqual(LanguageMatcher.code("spa"), "es")
        XCTAssertNil(LanguageMatcher.code(""))
        XCTAssertTrue(LanguageMatcher.matches("jpn", "ja"))
        XCTAssertFalse(LanguageMatcher.matches("en", "es"))
    }

    private func track(_ id: Int64, _ type: String, lang: String?, title: String? = nil) -> MpvTrack {
        MpvTrack(id: id, type: type, title: title, lang: lang, codec: nil)
    }

    func testRememberedLanguagesAreSelected() {
        var remembered = TitlePlaybackSnapshot()
        remembered.audioLanguage = "ja"
        remembered.subtitleLanguage = "English"
        let plan = TrackSelectionPolicy.plan(
            audio: [track(1, "audio", lang: "eng"), track(2, "audio", lang: "jpn")],
            subtitles: [track(3, "sub", lang: "spa"), track(4, "sub", lang: "eng")],
            remembered: remembered,
            preferredSubtitleLanguages: [],
            autoSelectSubtitles: false,
        )
        XCTAssertEqual(plan, .init(audioTrack: 2, subtitleTrack: 4, isComplete: true))
    }

    func testSubtitlesOffIsRemembered() {
        var remembered = TitlePlaybackSnapshot()
        remembered.subtitlesOff = true
        let plan = TrackSelectionPolicy.plan(audio: [], subtitles: [track(3, "sub", lang: "en")], remembered: remembered, preferredSubtitleLanguages: ["en"], autoSelectSubtitles: true)
        XCTAssertEqual(plan.subtitleTrack, 0)
    }

    func testAutoSelectFollowsLanguageOrderAndWaitsForLateTracks() {
        let early = TrackSelectionPolicy.plan(audio: [], subtitles: [track(1, "sub", lang: "fr")], remembered: nil, preferredSubtitleLanguages: ["es", "en"], autoSelectSubtitles: true)
        XCTAssertNil(early.subtitleTrack)
        XCTAssertFalse(early.isComplete, "keep waiting for the wanted language")

        let late = TrackSelectionPolicy.plan(audio: [], subtitles: [track(1, "sub", lang: "fr"), track(2, "sub", lang: "en"), track(3, "sub", lang: "es")], remembered: nil, preferredSubtitleLanguages: ["es", "en"], autoSelectSubtitles: true)
        XCTAssertEqual(late.subtitleTrack, 3)
    }

    func testNoWishesMeansNoChange() {
        let plan = TrackSelectionPolicy.plan(audio: [track(1, "audio", lang: "en")], subtitles: [track(2, "sub", lang: "en")], remembered: nil, preferredSubtitleLanguages: ["en"], autoSelectSubtitles: false)
        XCTAssertEqual(plan, .init(audioTrack: nil, subtitleTrack: nil, isComplete: true))
    }

    // MARK: Local subtitles & learned intro

    @MainActor
    func testLocalSubtitleFileRecognition() {
        let dto = PlayerViewModel.localSubtitle(for: URL(fileURLWithPath: "/tmp/Show.S01E02.en.srt"))
        XCTAssertEqual(dto?.language, "en")
        XCTAssertEqual(dto?.label, "Show.S01E02.en.srt")
        XCTAssertEqual(PlayerViewModel.localSubtitle(for: URL(fileURLWithPath: "/tmp/Show.ass"))?.language, "und")
        XCTAssertNil(PlayerViewModel.localSubtitle(for: URL(fileURLWithPath: "/tmp/movie.mkv")))
        XCTAssertNil(PlayerViewModel.localSubtitle(for: URL(string: "https://example.com/a.srt")!))
    }

    func testLearnedIntroSanity() {
        var prefs = TitlePlaybackSnapshot()
        prefs.introStart = 30
        prefs.introEnd = 115
        XCTAssertEqual(prefs.introSegment, SkipSegment(kind: .intro, start: 30, end: 115))
        prefs.introEnd = 32
        XCTAssertNil(prefs.introSegment, "too short to be an intro")
        prefs.introEnd = 1000
        XCTAssertNil(prefs.introSegment, "too long to be an intro")
    }

    @MainActor
    func testTitlePlaybackPrefsRoundTrip() throws {
        let store = LibraryStore(inMemory: true)
        XCTAssertNil(try store.playbackPrefs(itemID: "p|u"))
        let before = store.version
        try store.updatePlaybackPrefs(itemID: "p|u") { $0.speed = 1.5; $0.audioLanguage = "ja" }
        try store.updatePlaybackPrefs(itemID: "p|u") { $0.subtitleDelay = -0.4 }
        let prefs = try store.playbackPrefs(itemID: "p|u")
        XCTAssertEqual(prefs?.speed, 1.5)
        XCTAssertEqual(prefs?.audioLanguage, "ja")
        XCTAssertEqual(prefs?.subtitleDelay, -0.4)
        XCTAssertNil(prefs?.rememberedSource)
        try store.updatePlaybackPrefs(itemID: "p|u") { $0.source = "vidplay"; $0.sourceQuality = 720 }
        XCTAssertEqual(try store.playbackPrefs(itemID: "p|u")?.rememberedSource, RememberedSource(key: "vidplay", quality: 720))
        XCTAssertEqual(try store.playbackPrefs(itemID: "p|u")?.speed, 1.5)
        XCTAssertEqual(store.version, before, "playback memory must not re-render library views")
    }

    // MARK: Playback sequence (audit A34)

    private func sequenceEpisode(_ number: Int?, season: Int? = 1, audio: String? = nil, data: String? = nil) -> EpisodeDto {
        EpisodeDto(data: data ?? "s\(season ?? -1)e\(number ?? -1)\(audio ?? "")", name: nil, season: season, episode: number,
                   posterUrl: nil, description: nil, score: nil, date: nil, runTimeMinutes: nil, audio: audio)
    }

    private func sequenceDetails(_ episodes: [EpisodeDto]) -> DetailsDto {
        DetailsDto(provider: "P", url: "u", name: "S", type: "Anime", posterUrl: nil, backgroundPosterUrl: nil, logoUrl: nil,
                   plot: nil, year: nil, durationMinutes: nil, score: nil, tags: [], actors: [], contentRating: nil,
                   comingSoon: false, episodes: episodes, movieData: nil)
    }

    func testSequenceFollowsEditionAndViewingOrderNotProviderOrder() {
        // Provider order interleaves editions and lists season 2 first.
        let s2 = sequenceEpisode(1, season: 2, audio: "sub")
        let e2sub = sequenceEpisode(2, audio: "sub"), e1dub = sequenceEpisode(1, audio: "dub")
        let e1sub = sequenceEpisode(1, audio: "sub"), e2dub = sequenceEpisode(2, audio: "dub")
        let details = sequenceDetails([s2, e2sub, e1dub, e1sub, e2dub])

        let sub = PlaybackSequence(details: details, containing: e1sub)
        XCTAssertEqual(sub.edition, "sub")
        XCTAssertEqual(sub.episodes, [e1sub, e2sub, s2])
        XCTAssertEqual(sub.next(after: e1sub), e2sub)
        XCTAssertEqual(sub.next(after: e2sub), s2)
        XCTAssertNil(sub.next(after: s2))
        XCTAssertNil(sub.previous(before: e1sub))
        XCTAssertEqual(sub.previous(before: s2), e2sub)

        // An alternate edition the user started stays the session's edition.
        let dub = PlaybackSequence(details: details, containing: e2dub)
        XCTAssertEqual(dub.episodes, [e1dub, e2dub])
        XCTAssertEqual(dub.previous(before: e2dub), e1dub)
        XCTAssertNil(dub.next(after: e2dub), "autoplay must not cross into the other edition")
        XCTAssertNil(dub.next(after: e1sub), "an episode outside the sequence has no neighbours")

        // The details screen and the player agree for the same edition.
        XCTAssertEqual(PlaybackSequence(episodes: details.episodes, edition: "sub"), sub)
    }

    func testSequenceKeepsProviderOrderForMissingCoordinatesAndUnavailableEdition() {
        let special = sequenceEpisode(nil, season: nil, data: "special"), ova = sequenceEpisode(nil, season: nil, data: "ova")
        let one = sequenceEpisode(1, season: nil), two = sequenceEpisode(2, season: nil)
        let sequence = PlaybackSequence(episodes: [special, two, ova, one], edition: "dub")
        XCTAssertNil(sequence.edition, "an edition the title lacks is not applied")
        XCTAssertEqual(sequence.episodes, [one, two, special, ova])
        XCTAssertTrue(PlaybackSequence(details: sequenceDetails([one]), containing: nil).episodes.isEmpty)
    }

    @MainActor
    func testPlayerNeighboursUseTheSessionSequence() {
        let e2sub = sequenceEpisode(2, audio: "sub"), e1dub = sequenceEpisode(1, audio: "dub")
        let e1sub = sequenceEpisode(1, audio: "sub"), e2dub = sequenceEpisode(2, audio: "dub")
        let details = sequenceDetails([e2sub, e1dub, e1sub, e2dub])
        let link = StreamLinkDto(url: "https://cdn.example/v.mp4", name: "n", source: "s", quality: 720, type: "video")
        let player = PlayerViewModel()
        defer { player.close() }
        player.playResolved(details: details, episode: e1sub, links: [link], persistsProgress: false)
        XCTAssertEqual(player.session?.sequence.episodes, [e1sub, e2sub])
        XCTAssertTrue(player.hasNextEpisode)
        XCTAssertFalse(player.hasPreviousEpisode, "raw provider order would report the dub episode before it")
        player.playResolved(details: details, episode: e2dub, links: [link], persistsProgress: false)
        XCTAssertFalse(player.hasNextEpisode)
        XCTAssertTrue(player.hasPreviousEpisode)
    }

    @MainActor
    func testSeekSymbolFallback() {
        XCTAssertEqual(PlayerHUDView.seekSymbol("goforward", 10), "goforward.10")
        XCTAssertEqual(PlayerHUDView.seekSymbol("goforward", 7), "goforward")
    }
}
