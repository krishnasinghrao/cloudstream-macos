import XCTest
@testable import CloudStream

/// ADR-0021: pages the user makes, holding whole titles and single episodes.
@MainActor
final class LibraryPagesTests: XCTestCase {
    private func show(_ name: String = "Community", provider: String = "P") -> DetailsDto {
        DetailsDto(provider: provider, providerId: provider + "-id", url: "https://\(provider).invalid/\(name)", name: name,
            type: "TvSeries", posterUrl: "https://img.invalid/\(name).jpg", backgroundPosterUrl: nil, logoUrl: nil, plot: nil,
            year: nil, durationMinutes: nil, score: nil, tags: [], actors: [], contentRating: nil, comingSoon: false,
            episodes: [], movieData: nil)
    }

    private func episode(_ number: Int, season: Int = 1) -> EpisodeDto {
        EpisodeDto(data: "{\"ep\":\(season)-\(number)}", name: "Episode \(number)", season: season, episode: number,
                   posterUrl: "https://img.invalid/\(number).jpg", description: nil, score: nil, date: nil,
                   runTimeMinutes: 22, audio: nil)
    }

    func testPagesAreCreatedRenamedReorderedAndDeleted() throws {
        let store = LibraryStore(inMemory: true)
        let first = try store.createPage(named: "  Favourite Episodes \n")
        let second = try store.createPage(named: "Rewatch")
        XCTAssertEqual(try store.pages().map(\.name), ["Favourite Episodes", "Rewatch"], "trimmed, one line, in creation order")

        XCTAssertThrowsError(try store.createPage(named: "favourite episodes")) {
            XCTAssertEqual($0 as? LibraryStore.PageError, .duplicateName("favourite episodes"), "names are unique ignoring case")
        }
        XCTAssertThrowsError(try store.createPage(named: "   ")) { XCTAssertEqual($0 as? LibraryStore.PageError, .emptyName) }
        XCTAssertEqual(try store.createPage(named: String(repeating: "x", count: 200)).isEmpty, false)
        XCTAssertEqual(try store.pages().last?.name.count, LibraryPage.maxNameLength)

        try store.renamePage(id: first, to: "Best Episodes")
        try store.renamePage(id: first, to: "best episodes")
        XCTAssertEqual(try store.page(id: first)?.name, "best episodes", "a page may change its own name's case")
        XCTAssertThrowsError(try store.renamePage(id: second, to: "Best Episodes"))

        try store.movePages(fromOffsets: [1], toOffset: 0)
        XCTAssertEqual(try store.pages().first?.id, second)

        try store.setPageMembership(pageID: second, details: show(), isMember: true)
        try store.deletePage(id: second)
        XCTAssertNil(try store.page(id: second))
        XCTAssertTrue(try store.pageEntries(pageID: second).isEmpty, "a page's entries go with it")
    }

    func testTitlesAndEpisodesAreAddedOnceAndRemoved() throws {
        let store = LibraryStore(inMemory: true)
        let page = try store.createPage(named: "Favourite Episodes")
        let community = show()
        try store.setPageMembership(pageID: page, details: community, episode: episode(4), isMember: true)
        try store.setPageMembership(pageID: page, details: community, episode: episode(4), isMember: true)
        try store.setPageMembership(pageID: page, details: community, episode: episode(5, season: 2), isMember: true)
        try store.setPageMembership(pageID: page, details: community, isMember: true)

        let summary = try XCTUnwrap(store.page(id: page))
        XCTAssertEqual(summary.titleCount, 1)
        XCTAssertEqual(summary.episodeCount, 2, "adding an episode twice keeps one")
        XCTAssertEqual(LibraryPageView.countLabel(summary), "1 title · 2 episodes")
        XCTAssertEqual(try store.pageIDs(containing: community, episode: episode(4)), [page])
        XCTAssertEqual(try store.pageIDs(containing: community), [page], "the whole title is its own entry")
        XCTAssertTrue(try store.pageIDs(containing: community, episode: episode(6)).isEmpty)

        let saved = try XCTUnwrap(store.pageEntries(pageID: page).first { $0.episode == 4 })
        XCTAssertEqual(saved.episodeLabel, "S1 · E4")
        XCTAssertEqual(saved.episodeThumbnailURL, "https://img.invalid/4.jpg")
        XCTAssertEqual(saved.episodeDto?.data, episode(4).data)
        XCTAssertEqual(store.detailsPreview(for: saved).id, community.id, "an entry opens its own title")

        try store.setPageMembership(pageID: page, details: community, episode: episode(4), isMember: false)
        XCTAssertEqual(try store.page(id: page)?.episodeCount, 1)
        try store.removePageEntry(id: LibraryPageEntry.key(pageID: page, itemID: community.id, episodeData: nil))
        XCTAssertEqual(try store.page(id: page)?.titleCount, 0)
        XCTAssertFalse(try store.items(withWatchType: nil).contains { $0.id == community.id },
                       "pages never put a title into a watch list")
    }

    func testDownloadedFilesStayOutOfPagesAndMissingPagesFail() throws {
        let store = LibraryStore(inMemory: true)
        let page = try store.createPage(named: "Mine")
        let download = DetailsDto(provider: "P", url: "/Users/me/Movies/a.mp4", name: "A", type: "Download",
            posterUrl: nil, backgroundPosterUrl: nil, logoUrl: nil, plot: nil, year: nil, durationMinutes: nil, score: nil,
            tags: [], actors: [], contentRating: nil, comingSoon: false, episodes: [], movieData: nil)
        XCTAssertThrowsError(try store.setPageMembership(pageID: page, details: download, isMember: true)) {
            XCTAssertEqual($0 as? LibraryStore.PageError, .localTitle)
        }
        XCTAssertThrowsError(try store.setPageMembership(pageID: "gone", details: show(), isMember: true)) {
            XCTAssertEqual($0 as? LibraryStore.PageError, .pageNotFound)
        }
    }

    func testPageContentSortsAndFilters() throws {
        let store = LibraryStore(inMemory: true)
        let page = try store.createPage(named: "Mixed")
        try store.setPageMembership(pageID: page, details: show("Zeta"), isMember: true)
        try store.setPageMembership(pageID: page, details: show("Alpha"), episode: episode(2), isMember: true)
        try store.setPageMembership(pageID: page, details: show("Alpha"), episode: episode(1), isMember: true)
        try store.setPageMembership(pageID: page, details: show("Beta"), isMember: true)
        let entries = try store.pageEntries(pageID: page)

        let newest = LibraryPageView.content(entries, query: "", options: LibraryViewOptions())
        XCTAssertEqual(newest.titles.map(\.title), ["Beta", "Zeta"], "most recently added first")
        XCTAssertEqual(newest.episodes.map(\.episode), [1, 2])

        var byName = LibraryViewOptions()
        byName.sort = .alphabetical
        XCTAssertEqual(LibraryPageView.content(entries, query: "", options: byName).titles.map(\.title), ["Beta", "Zeta"])
        XCTAssertEqual(LibraryPageView.content(entries, query: "", options: byName).episodes.map(\.episode), [1, 2],
                       "episodes of one show by season and number")
        byName.reversed = true
        XCTAssertEqual(LibraryPageView.content(entries, query: "", options: byName).titles.map(\.title), ["Zeta", "Beta"])

        let filtered = LibraryPageView.content(entries, query: "episode 2", options: LibraryViewOptions())
        XCTAssertTrue(filtered.titles.isEmpty)
        XCTAssertEqual(filtered.episodes.map(\.episode), [2], "the filter matches episode names too")
    }

    func testBackupsKeepPagesAndRestoreMerges() throws {
        let store = LibraryStore(inMemory: true)
        let page = try store.createPage(named: "Favourite Episodes")
        try store.upsertLibraryEntry(details: show(), watchType: .watching)
        try store.setPageMembership(pageID: page, details: show(), episode: episode(3), isMember: true)
        try store.setPageMembership(pageID: page, details: show("Other"), isMember: true)
        let snapshot = try store.exportSnapshot()
        XCTAssertEqual(snapshot.pages?.first?.entries.count, 2)
        let document = BackupDocument(createdAt: Date(), appVersion: "test", items: snapshot.items, episodes: snapshot.episodes,
            playback: snapshot.playback, preferences: [:], repositories: [], disabledProviders: [], pages: snapshot.pages)
        let decoded = try BackupDocument.decode(document.encoded())
        // Backups keep times to the millisecond, so compare what identifies each entry.
        XCTAssertEqual(decoded.pages?.map(\.name), snapshot.pages?.map(\.name))
        XCTAssertEqual(decoded.pages?.first?.entries.map { [$0.itemID, $0.episodeData ?? ""] },
                       snapshot.pages?.first?.entries.map { [$0.itemID, $0.episodeData ?? ""] })
        XCTAssertEqual(decoded.summary.pages, 1)

        let restored = LibraryStore(inMemory: true)
        _ = try restored.importSnapshot(snapshot, mode: .replace)
        XCTAssertEqual(try restored.pages().map(\.name), ["Favourite Episodes"])
        XCTAssertEqual(try restored.page(id: page)?.count, 2)

        // Merging the same backup again adds nothing; a local page of the same name gains the entries.
        _ = try restored.importSnapshot(snapshot, mode: .merge)
        XCTAssertEqual(try restored.page(id: page)?.count, 2)
        let other = LibraryStore(inMemory: true)
        let local = try other.createPage(named: "favourite episodes")
        _ = try other.importSnapshot(snapshot, mode: .merge)
        XCTAssertEqual(try other.pages().map(\.id), [local])
        XCTAssertEqual(try other.page(id: local)?.count, 2)

        // A backup made before pages leaves local pages alone, even on replace.
        var legacy = snapshot
        legacy.pages = nil
        _ = try other.importSnapshot(legacy, mode: .replace)
        XCTAssertEqual(try other.page(id: local)?.count, 2)
    }

    func testBackupValidationRejectsBrokenPages() throws {
        func document(_ pages: [BackupDocument.Page]) -> BackupDocument {
            BackupDocument(createdAt: Date(), appVersion: "test", items: [], episodes: [], playback: [], preferences: [:],
                           repositories: [], disabledProviders: [], pages: pages)
        }
        let entry = BackupDocument.PageEntry(itemID: "remote-v2:x", title: "X", posterURL: nil, bannerURL: nil, providerName: "P",
            providerID: "p", providerURL: "https://x.invalid", mediaType: "Movie", episodeData: nil, season: nil, episode: nil,
            episodeName: nil, episodeThumbnailURL: nil, audio: nil, addedAt: Date())
        let page = BackupDocument.Page(id: "A", name: "Mine", createdAt: Date(), sortPosition: 1, entries: [entry])
        XCTAssertNoThrow(try document([page]).validate())

        var duplicateName = page
        duplicateName.id = "B"
        duplicateName.name = "MINE"
        XCTAssertThrowsError(try document([page, duplicateName]).validate())
        var blank = page
        blank.name = "  "
        XCTAssertThrowsError(try document([blank]).validate())
        var twice = page
        twice.entries = [entry, entry]
        XCTAssertThrowsError(try document([twice]).validate())
        var local = page
        local.entries = [BackupDocument.PageEntry(itemID: "local-download-v2:1", title: "X", posterURL: nil, bannerURL: nil,
            providerName: "P", providerID: nil, providerURL: "/x.mp4", mediaType: "Download", episodeData: nil, season: nil,
            episode: nil, episodeName: nil, episodeThumbnailURL: nil, audio: nil, addedAt: Date())]
        XCTAssertThrowsError(try document([local]).validate())
    }

    func testHomeShelfStorage() {
        for shelf in [HomeShelf.collection(.favorites), .collection(.dropped), .page(id: "ABC")] {
            XCTAssertEqual(HomeShelf(storageValue: shelf.storageValue), shelf)
        }
        XCTAssertNil(HomeShelf(storageValue: "nonsense"))
        XCTAssertEqual(UserPreferences.homeShelf(from: WatchType.completed.rawValue), .collection(.completed))
        XCTAssertEqual(UserPreferences.homeShelf(from: nil), .default)
    }
}
