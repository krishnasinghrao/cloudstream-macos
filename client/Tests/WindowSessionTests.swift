import AppKit
import XCTest
@testable import CloudStream

@MainActor
final class WindowSessionTests: XCTestCase {
    private func result(_ name: String) -> SearchResultDto {
        .init(name: name, url: "https://fixture.test/\(name)", provider: "Fixture",
            type: "Movie", posterUrl: nil, quality: nil, score: nil,
            language: nil, episodes: nil, year: nil, isMovie: true)
    }

    private func event(_ name: String) -> SearchStreamEventDto {
        .init(type: "provider_result", provider: "Fixture", results: [result(name)], error: nil)
    }

    func testNavigationSearchAndSheetsBelongToTheirOwnWindow() {
        let first = WindowSession(), second = WindowSession()
        first.openDetails(result("first"))
        second.openDetails(result("second"))
        second.libraryFilter = "retained"
        second.pendingRepoAdd = "https://fixture.test/second"
        first.showShortcuts = true
        first.searchQuery = "first query"
        first.navigateTo(.extensions)
        XCTAssertTrue(first.detailPath.isEmpty)
        XCTAssertEqual(second.detailPath, [.result(result("second"))])
        XCTAssertEqual(second.libraryFilter, "retained")
        XCTAssertEqual(second.pendingRepoAdd, "https://fixture.test/second")
        XCTAssertFalse(second.showShortcuts)
        XCTAssertTrue(second.searchQuery.isEmpty)
        XCTAssertEqual(second.selection, .home)
    }

    func testRoutingTargetsOwningWindowAndClosingDoesNotMutateAnother() {
        let registry = WindowSessionRegistry()
        let first = WindowSession(), second = WindowSession()
        let firstWindow = NSWindow(), secondWindow = NSWindow()
        registry.register(first, window: firstWindow)
        registry.register(second, window: secondWindow)
        defer { registry.unregister(first.id); registry.unregister(second.id) }
        registry.activate(first.id)
        registry.routedSession.navigateTo(.downloaded)
        registry.activate(second.id)
        registry.routedSession.navigateTo(.history)
        XCTAssertEqual(first.selection, .downloaded)
        XCTAssertEqual(second.selection, .history)
        registry.unregister(second.id)
        XCTAssertTrue(registry.routedSession === first)
        XCTAssertEqual(first.selection, .downloaded)
    }

    func testProfileInvalidationClearsEveryWindowWithoutChangingDestinations() {
        let registry = WindowSessionRegistry()
        let first = WindowSession(), second = WindowSession()
        registry.register(first); registry.register(second)
        defer { registry.unregister(first.id); registry.unregister(second.id) }
        first.selection = .history; second.selection = .favorites
        for session in [first, second] {
            session.openDetails(result("private"))
            session.searchQuery = "private"
            session.libraryFilter = "private"
        }
        registry.invalidateProfileNavigation()
        for session in [first, second] {
            XCTAssertTrue(session.detailPath.isEmpty)
            XCTAssertTrue(session.searchQuery.isEmpty)
            XCTAssertTrue(session.libraryFilter.isEmpty)
        }
        XCTAssertEqual(first.selection, .history)
        XCTAssertEqual(second.selection, .favorites)
    }

    func testConcurrentSearchesRemainIndependentAndOldQueryCannotPublish() async throws {
        var streams: [String: AsyncThrowingStream<SearchStreamEventDto, Error>.Continuation] = [:]
        let factory: (String) -> AsyncThrowingStream<SearchStreamEventDto, Error> = { query in
            AsyncThrowingStream { streams[query] = $0 }
        }
        let first = WindowSession(searchStream: factory), second = WindowSession(searchStream: factory)
        defer { first.cancelSearch(); second.cancelSearch(); streams.values.forEach { $0.finish() } }
        first.searchQuery = "old"; first.commitSearch()
        second.searchQuery = "second"; second.commitSearch()
        try await until { streams["old"] != nil && streams["second"] != nil }
        first.searchQuery = "new"; first.commitSearch()
        try await until { streams["new"] != nil }
        streams["old"]?.yield(event("stale"))
        streams["second"]?.yield(event("second"))
        streams["new"]?.yield(event("new"))
        streams["second"]?.finish(); streams["new"]?.finish()
        try await until { !first.isSearching && !second.isSearching }
        XCTAssertEqual(first.searchResults.map(\.name), ["new"])
        XCTAssertEqual(second.searchResults.map(\.name), ["second"])
        first.clearSearch()
        XCTAssertEqual(second.searchResults.map(\.name), ["second"])
    }

    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition() {
            guard ContinuousClock.now < deadline else { XCTFail("Session fixture timed out"); throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
