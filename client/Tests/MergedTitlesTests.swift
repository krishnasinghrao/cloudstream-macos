import XCTest
@testable import CloudStream

/// ADR-0020 / plan U3: one library title, several sources.
@MainActor
final class MergedTitlesTests: XCTestCase {
    private func details(provider: String, name: String = "Community", year: Int? = 2009, type: String = "TvSeries") -> DetailsDto {
        DetailsDto(provider: provider, url: "https://\(provider).invalid/\(name)", name: name, type: type,
            posterUrl: nil, backgroundPosterUrl: nil, logoUrl: nil, plot: nil, year: year, durationMinutes: nil,
            score: nil, tags: [], actors: [], contentRating: nil, comingSoon: false, episodes: [], movieData: nil)
    }

    private func id(_ dto: DetailsDto) -> String { LibraryStore.itemID(for: dto) }

    func testStrongMatchesMergeIntoOneTitleAndShowOnce() throws {
        let store = LibraryStore(inMemory: true)
        let a = details(provider: "MovieBox"), b = details(provider: "CineStream", name: "community (2009)")
        try store.upsertLibraryEntry(details: a, watchType: .planToWatch)
        try store.upsertLibraryEntry(details: b, watchType: .watching)

        XCTAssertEqual(try store.items(withWatchType: nil).count, 1, "the same show from two providers is one title")
        XCTAssertEqual(try store.counts().watching, 1)
        XCTAssertEqual(try store.counts().planToWatch, 0)
        let sources = try store.titleSources(details: a)
        XCTAssertEqual(Set(sources.map(\.id)), [id(a), id(b)])
        XCTAssertEqual(sources.first?.watchType, .watching, "the most active status wins")
        // Either source's details page reports the title's state.
        XCTAssertEqual(try store.watchType(details: a), .watching)
        XCTAssertEqual(try store.watchType(details: b), .watching)
    }

    func testAMergedSourceThatKeepsItsOwnStatusIsNeverShownOrCountedTwice() throws {
        // Remediation 4.1: e.g. a restored backup whose source row still carries a status and a favorite.
        let store = LibraryStore(inMemory: true)
        func row(_ id: String, merged: String?) -> BackupDocument.Item {
            var item = BackupDocument.Item(id: id, title: "Community", posterURL: nil, bannerURL: nil, providerName: "P",
                providerURL: "https://p.invalid/\(id)", mediaType: "TvSeries", watchTypeRaw: WatchType.watching.rawValue, isFavorite: true,
                lastEpisodeData: nil, lastSeason: nil, lastEpisode: nil, progressSeconds: 0, totalDurationSeconds: 0,
                lastUpdated: Date(timeIntervalSince1970: 100), createdAt: Date(timeIntervalSince1970: 50), knownEpisodeCount: 0,
                userNote: nil, userRating: 0, providerID: "p-\(id)")
            item.mergedIntoID = merged
            return item
        }
        try store.importSnapshot(.init(items: [row("primary", merged: nil), row("source", merged: "primary")], episodes: [], playback: []), mode: .replace)
        XCTAssertEqual(try store.items(withWatchType: .watching).map(\.id), ["primary"])
        XCTAssertEqual(try store.items(withWatchType: nil).map(\.id), ["primary"])
        XCTAssertEqual(try store.favorites.map(\.id), ["primary"])
        let counts = try store.counts()
        XCTAssertEqual(counts.watching, 1)
        XCTAssertEqual(counts.favorites, 1, "badges count distinct titles")
    }

    func testWeakMatchesAreNeverMergedAutomatically() throws {
        let store = LibraryStore(inMemory: true)
        try store.upsertLibraryEntry(details: details(provider: "A", year: nil), watchType: .watching)
        try store.upsertLibraryEntry(details: details(provider: "B", year: nil), watchType: .watching)
        try store.upsertLibraryEntry(details: details(provider: "C", year: 2010), watchType: .watching)
        try store.upsertLibraryEntry(details: details(provider: "D", type: "Movie"), watchType: .watching)
        XCTAssertEqual(try store.items(withWatchType: nil).count, 4, "no year, another year or another kind of title")
    }

    func testEditsFromAnySourceGoToTheTitleAndConflictsResolve() throws {
        let store = LibraryStore(inMemory: true)
        let a = details(provider: "A", year: nil), b = details(provider: "B", year: nil)
        try store.upsertLibraryEntry(details: a, watchType: .completed)
        try store.setUserNote(details: a, note: "first note")
        try store.toggleFavorite(details: b)
        try store.setUserNote(details: b, note: "second note")
        try store.upsertLibraryEntry(details: b, watchType: .onHold)
        try store.mergeTitles(itemIDs: [id(a), id(b)])

        let title = try XCTUnwrap(store.titleSources(details: a).first)
        XCTAssertEqual(title.watchType, .onHold, "On Hold is more active than Completed")
        XCTAssertTrue(title.isFavorite)
        XCTAssertTrue(title.userNote?.contains("first note") == true && title.userNote?.contains("second note") == true)
        XCTAssertEqual(try store.favorites.count, 1)

        try store.setUserRating(details: a, rating: 4)
        try store.setWatchType(details: a, watchType: .watching)
        XCTAssertEqual(try store.titleSources(details: b).first?.userRating, 4)
        XCTAssertEqual(try store.items(withWatchType: .watching).map(\.id), [title.id])
    }

    func testPlayingASourceMakesItTheTitleWithItsOwnProgress() throws {
        let store = LibraryStore(inMemory: true)
        let a = details(provider: "A"), b = details(provider: "B")
        try store.upsertLibraryEntry(details: a, watchType: .watching)
        try store.toggleFavorite(details: a)
        try store.upsertLibraryEntry(details: b, watchType: .planToWatch)
        let primaryBefore = try XCTUnwrap(store.titleSources(details: a).first?.id)
        let other = primaryBefore == id(a) ? b : a

        try store.recordProgress(details: other, episode: nil, progressSeconds: 600, totalDurationSeconds: 1200)
        let sources = try store.titleSources(details: a)
        XCTAssertEqual(sources.first?.id, id(other), "the source last played fronts the title")
        XCTAssertEqual(sources.first?.watchType, .watching)
        XCTAssertTrue(sources.first?.isFavorite == true)
        XCTAssertEqual(try store.continueWatching.map(\.id), [id(other)])
        XCTAssertEqual(try store.items(withWatchType: nil).count, 1)
    }

    func testSeparatingASourceBringsItBackWithTheTitlesStatus() throws {
        let store = LibraryStore(inMemory: true)
        let a = details(provider: "A"), b = details(provider: "B")
        try store.upsertLibraryEntry(details: a, watchType: .watching)
        try store.upsertLibraryEntry(details: b, watchType: .watching)
        let merged = try XCTUnwrap(store.titleSources(details: a).last)
        try store.separateSource(itemID: merged.id)
        XCTAssertEqual(try store.items(withWatchType: .watching).count, 2)
        XCTAssertEqual(try store.titleSources(details: a).count, 1)
    }

    func testBackupsKeepMergedSources() throws {
        let store = LibraryStore(inMemory: true)
        let a = details(provider: "A"), b = details(provider: "B")
        try store.upsertLibraryEntry(details: a, watchType: .watching)
        try store.upsertLibraryEntry(details: b, watchType: .watching)
        let snapshot = try store.exportSnapshot()
        XCTAssertEqual(snapshot.items.filter { $0.mergedIntoID != nil }.count, 1)

        let restored = LibraryStore(inMemory: true)
        _ = try restored.importSnapshot(snapshot, mode: .replace)
        XCTAssertEqual(try restored.items(withWatchType: nil).count, 1)
        XCTAssertEqual(try restored.titleSources(details: a).count, 2)
    }

    func testTitleNormalisation() {
        XCTAssertEqual(LibraryStore.normalizedTitle("Amélie (2001)"), "amelie")
        XCTAssertEqual(LibraryStore.normalizedTitle("Spider-Man: Brand New Day"), "spider man brand new day")
        XCTAssertEqual(LibraryStore.normalizedTitle("2012"), "2012", "a title that is only a year keeps it")
        XCTAssertNil(LibraryStore.typeFamily("Live"))
        XCTAssertEqual(LibraryStore.typeFamily("AnimeMovie"), LibraryStore.typeFamily("Movie"))
        XCTAssertEqual(LibraryStore.typeFamily("Anime"), LibraryStore.typeFamily("TvSeries"))
    }
}
