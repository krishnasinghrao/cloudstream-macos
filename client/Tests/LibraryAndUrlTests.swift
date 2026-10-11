import XCTest
@testable import CloudStream

/// Repo URL normalization — the single implementation behind deep links and
/// the Extensions add flow (U-67).
final class RepoURLNormalizationTests: XCTestCase {
    func testPlainHTTPSURLPassesThrough() {
        XCTAssertEqual(
            DaemonClient.normalizeRepoUrl("https://example.com/repo.json"),
            "https://example.com/repo.json",
        )
    }

    func testCustomSchemesAreStripped() {
        XCTAssertEqual(
            DaemonClient.normalizeRepoUrl("cloudstreamrepo://example.com/repo.json"),
            "https://example.com/repo.json",
        )
        XCTAssertEqual(
            DaemonClient.normalizeRepoUrl("cs.repo://example.com/repo.json"),
            "https://example.com/repo.json",
        )
        XCTAssertEqual(
            DaemonClient.normalizeRepoUrl("cs3://example.com/repo.json"),
            "https://example.com/repo.json",
        )
        XCTAssertEqual(
            DaemonClient.normalizeRepoUrl("cloudstream://example.com/repo.json"),
            "https://example.com/repo.json",
        )
    }

    func testSchemelessHostGetsHTTPS() {
        XCTAssertEqual(
            DaemonClient.normalizeRepoUrl("example.com/repo.json"),
            "https://example.com/repo.json",
        )
    }

    func testHTTPUpgradedToHTTPS() {
        XCTAssertEqual(
            DaemonClient.normalizeRepoUrl("http://example.com/repo.json"),
            "https://example.com/repo.json",
        )
    }

    func testMarkdownLinkStripped() {
        XCTAssertEqual(
            DaemonClient.normalizeRepoUrl("[My Repo](https://example.com/repo.json)"),
            "https://example.com/repo.json",
        )
    }

    func testQueryParameterFormResolved() {
        XCTAssertEqual(
            DaemonClient.normalizeRepoUrl("cs.repo://cs.repo/url=https://example.com/repo.json"),
            "https://example.com/repo.json",
        )
    }
}

/// StoredMediaItem honest labels (U-22).
final class StoredMediaItemTests: XCTestCase {
    private func makeItem(progress: Double, total: Double) -> StoredMediaItem {
        let item = StoredMediaItem(
            id: "p|u",
            title: "T",
            providerName: "p",
            providerURL: "u",
            mediaType: "movie",
        )
        item.progressSeconds = progress
        item.totalDurationSeconds = total
        return item
    }

    func testRemainingLabelNilForUnknownDuration() {
        XCTAssertNil(makeItem(progress: 30, total: 0).remainingLabel)
    }

    func testSubMinuteRendersUnder1m() {
        XCTAssertEqual(makeItem(progress: 100, total: 120).remainingLabel, "<1m")
    }

    func testMinutesAndHours() {
        XCTAssertEqual(makeItem(progress: 0, total: 45 * 60).remainingLabel, "45m")
        XCTAssertEqual(makeItem(progress: 0, total: (2 * 3600) + (5 * 60)).remainingLabel, "2h 5m")
    }

    func testDisplayProgressNilWithoutDuration() {
        XCTAssertNil(makeItem(progress: 100, total: 0).displayProgress)
        XCTAssertEqual(makeItem(progress: 50, total: 100).displayProgress ?? 0, 0.5, accuracy: 0.001)
    }

    func testDisplayProgressClampedToHundredPercent() {
        XCTAssertEqual(makeItem(progress: 500, total: 100).displayProgress ?? 0, 1.0, accuracy: 0.001)
    }

    func testRemainingLabelNeverZeroMinutes() {
        // The old label rendered "0m left" for sub-minute remainders.
        let label = makeItem(progress: 119, total: 120).remainingLabel
        XCTAssertNotEqual(label, "0m")
    }
}

/// LibraryStore mutation → version protocol and data-correctness rules
/// (U-20, U-22, V-23 client side), on an in-memory container.
@MainActor
final class LibraryStoreTests: XCTestCase {
    private func makeStore() -> LibraryStore {
        LibraryStore(inMemory: true)
    }

    private func details(name: String = "Show") -> DetailsDto {
        DetailsDto(
            provider: "prov",
            url: "u/\(name)",
            name: name,
            type: "tvseries",
            posterUrl: nil,
            backgroundPosterUrl: nil,
            logoUrl: nil,
            plot: nil,
            year: nil,
            durationMinutes: nil,
            score: nil,
            tags: [],
            actors: [],
            contentRating: nil,
            comingSoon: false,
            episodes: [],
            movieData: nil,
        )
    }

    func testMutationBumpsVersion() throws {
        let store = makeStore()
        let before = store.version
        try store.upsertLibraryEntry(details: details(), watchType: .watching)
        XCTAssertEqual(store.version, before + 1)

        try store.toggleFavorite(details: details())
        XCTAssertEqual(store.version, before + 2)

        try store.removeProgress(id: "prov|u/Show")
        XCTAssertEqual(store.version, before + 3)
    }

    func testMarkWatchedCompletesAndClearsProgress() throws {
        let store = makeStore()
        let dto = details()
        try store.recordProgress(details: dto, episode: nil, progressSeconds: 300, totalDurationSeconds: 1000)
        try store.markWatched(itemID: "prov|u/Show")

        XCTAssertEqual(try store.watchType(details: dto), .completed)
        let item = try store.resumeItem(for: dto)
        XCTAssertEqual(item?.progressSeconds ?? -1, 0, "Mark as Watched must clear the resume position")
    }

    func testAllFiveWatchTypesAreRetrievable() throws {
        let store = makeStore()
        for (index, type) in WatchType.allCases.enumerated() {
            let dto = DetailsDto(
                provider: "prov",
                url: "type\(index)",
                name: "T\(index)",
                type: "movie",
                posterUrl: nil,
                backgroundPosterUrl: nil,
                logoUrl: nil,
                plot: nil,
                year: nil,
                durationMinutes: nil,
                score: nil,
                tags: [],
                actors: [],
                contentRating: nil,
                comingSoon: false,
                episodes: [],
                movieData: nil,
            )
            try store.upsertLibraryEntry(details: dto, watchType: type)
            XCTAssertEqual(try store.items(withWatchType: type).count, 1, "\(type.label) entries must be retrievable")
        }
    }

    func testContinueWatchingEligibilityMatrix() throws {
        let store = makeStore()

        // In progress, known duration → eligible.
        try store.recordProgress(
            details: details(name: "known"),
            episode: nil,
            progressSeconds: 300,
            totalDurationSeconds: 1000,
        )
        // Unknown duration stays eligible — it can never reach a fraction.
        try store.recordProgress(
            details: details(name: "unknown"),
            episode: nil,
            progressSeconds: 60,
            totalDurationSeconds: 0,
        )
        // 95%+ watched → completed, not "continue".
        try store.recordProgress(
            details: details(name: "almost"),
            episode: nil,
            progressSeconds: 960,
            totalDurationSeconds: 1000,
        )
        // Below the 10 s threshold → not in continue watching at all.
        try store.recordProgress(
            details: details(name: "barely"),
            episode: nil,
            progressSeconds: 5,
            totalDurationSeconds: 1000,
        )

        let ids = Set(try store.continueWatching.map(\.id))
        XCTAssertTrue(ids.contains("prov|u/known"))
        XCTAssertTrue(ids.contains("prov|u/unknown"))
        XCTAssertFalse(ids.contains("prov|u/almost"))
        XCTAssertFalse(ids.contains("prov|u/barely"))
    }

    func testRemoveFromLibraryDeletes() throws {
        let store = makeStore()
        let dto = details()
        try store.upsertLibraryEntry(details: dto, watchType: .planToWatch)
        try store.removeFromLibrary(details: dto)
        XCTAssertTrue(try store.allEntries().isEmpty)
    }

    func testPlaybackDoesNotAddToWatchingLibrary() throws {
        let store = makeStore()
        let dto = details()
        try store.recordProgress(details: dto, episode: nil, progressSeconds: 300, totalDurationSeconds: 1000)

        XCTAssertNil(try store.watchType(details: dto))
        XCTAssertTrue(try store.items(withWatchType: .watching).isEmpty)
        XCTAssertEqual(try store.continueWatching.map(\.id), ["prov|u/Show"])
    }

    func testRemoveFromLibraryKeepsContinueWatching() throws {
        let store = makeStore()
        let dto = details()
        try store.upsertLibraryEntry(details: dto, watchType: .watching)
        try store.recordProgress(details: dto, episode: nil, progressSeconds: 300, totalDurationSeconds: 1000)
        try store.removeFromLibrary(details: dto)

        XCTAssertTrue(try store.items(withWatchType: .watching).isEmpty)
        XCTAssertEqual(try store.continueWatching.map(\.id), ["prov|u/Show"])
    }
}
