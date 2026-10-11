import XCTest
@testable import CloudStream

@MainActor
final class ProviderIdentityTests: XCTestCase {
    private func details(_ providerID: String?, name: String = "Same Name", url: String = "https://fixture.test/title?sig=a%2Fb&x=1") -> DetailsDto {
        .init(provider: name, providerId: providerID, url: url, name: "Title", type: "TvSeries",
              posterUrl: nil, backgroundPosterUrl: nil, logoUrl: nil, plot: nil, year: nil,
              durationMinutes: nil, score: nil, tags: [], actors: [], contentRating: nil,
              comingSoon: false, episodes: [], movieData: nil)
    }

    private func entry(_ details: DetailsDto, id: String) -> BackupDocument.Item {
        .init(id: id, title: details.name, posterURL: nil, bannerURL: nil,
              providerName: details.provider, providerURL: details.url, mediaType: details.type,
              watchTypeRaw: 0, isFavorite: false, lastEpisodeData: nil, lastSeason: nil,
              lastEpisode: nil, progressSeconds: 0, totalDurationSeconds: 0,
              lastUpdated: Date(timeIntervalSince1970: 100), createdAt: Date(timeIntervalSince1970: 50),
              providerID: details.providerId)
    }

    func testIdentityUsesStableProviderAndOriginalURLBytesWithoutSeparatorCollisions() {
        XCTAssertNotEqual(LibraryIdentity.remote(providerID: "a|b", url: "c"), LibraryIdentity.remote(providerID: "a", url: "b|c"))
        XCTAssertNotEqual(details("one").id, details("two").id)
        XCTAssertEqual(details("one").id, details("one", name: "Renamed").id)
        XCTAssertNotEqual(details("one").id, details("one", url: "https://fixture.test/title?sig=a/b&x=1").id)
    }

    func testPreviewAndLibraryOperationsKeepSameNamedInstallationsIndependent() throws {
        let store = LibraryStore(inMemory: true)
        let first = details("repository-one/provider"), second = details("repository-two/provider")
        try store.upsertLibraryEntry(details: first, watchType: .watching)
        try store.upsertLibraryEntry(details: second, watchType: .planToWatch)
        try store.setUserNote(details: first, note: "first only")
        try store.toggleFavorite(details: second)
        let rows = try store.allEntries()
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(try store.watchType(details: first), .watching)
        XCTAssertEqual(try store.watchType(details: second), .planToWatch)
        XCTAssertFalse(try store.isFavorite(details: first))
        XCTAssertTrue(try store.isFavorite(details: second))
        for row in rows { XCTAssertEqual(store.detailsPreview(for: row).providerId, row.providerID) }
        let search = SearchResultDto(name: "Title", url: first.url, provider: first.provider,
            providerId: first.providerId, type: "TvSeries", posterUrl: nil, quality: nil,
            score: nil, language: nil, episodes: nil, year: nil, isMovie: false)
        XCTAssertEqual(store.detailsPreview(for: search).providerId, first.providerId)
    }

    func testKnownLegacyOwnerKeepsHistoryAndPrefsEvenAfterDisplayRename() throws {
        let store = LibraryStore(inMemory: true)
        let old = details("stable-provider")
        let oldKey = LibraryIdentity.legacy(providerName: old.provider, url: old.url)
        let item = entry(old, id: oldKey)
        let episode = BackupDocument.Episode(itemID: oldKey, episodeData: "episode", season: 1, episode: 1,
            positionSeconds: 100, durationSeconds: 1000, watched: false, updatedAt: Date(timeIntervalSince1970: 100))
        let prefs = BackupDocument.Playback(itemID: oldKey, audioLanguage: "ja", subtitleLanguage: "en",
            subtitlesOff: false, subtitleDelay: -1, speed: 1.25, introStart: nil, introEnd: nil,
            updatedAt: Date(timeIntervalSince1970: 100))
        try store.importSnapshot(.init(items: [item], episodes: [episode], playback: [prefs]), mode: .replace)
        let renamed = details("stable-provider", name: "Renamed")
        XCTAssertEqual(try store.persistedItemID(for: renamed), oldKey)
        XCTAssertEqual(try store.episodeProgress(details: renamed)["episode"]?.positionSeconds, 100)
        XCTAssertEqual(try store.playbackPrefs(details: renamed)?.speed, 1.25)
        store.mutationClock = { Date(timeIntervalSince1970: 150) }
        try store.upsertLibraryEntry(details: renamed, watchType: .completed)
        try store.updatePlaybackPrefs(details: renamed) { $0.speed = 1.5 }
        XCTAssertEqual(try store.allEntries().count, 1)
        XCTAssertEqual(try store.playbackPrefs(itemID: oldKey)?.speed, 1.5)
        // A canonical-key backup merges into the same legacy owner without
        // rekeying or leaving history/preferences under an incoming orphan key.
        var incoming = entry(old, id: old.id)
        incoming.identityVersion = 2
        var incomingEpisode = episode
        incomingEpisode.itemID = old.id
        incomingEpisode.updatedAt = Date(timeIntervalSince1970: 200)
        incomingEpisode.positionSeconds = 200
        var incomingPrefs = prefs
        incomingPrefs.itemID = old.id
        incomingPrefs.speed = 2
        incomingPrefs.updatedAt = Date(timeIntervalSince1970: 200)
        try store.importSnapshot(.init(items: [incoming], episodes: [incomingEpisode], playback: [incomingPrefs]), mode: .merge)
        XCTAssertEqual(try store.allEntries().count, 1)
        XCTAssertEqual(try store.persistedItemID(for: renamed), oldKey)
        XCTAssertEqual(try store.episodeProgress(details: renamed)["episode"]?.positionSeconds, 200)
        XCTAssertEqual(try store.playbackPrefs(details: renamed)?.speed, 2)
    }

    func testKnownLegacyBackupCannotClaimAnUnknownSameNamedLocalOwner() throws {
        let store = LibraryStore(inMemory: true)
        let unknown = details(nil)
        let oldID = LibraryIdentity.legacy(providerName: unknown.provider, url: unknown.url)
        var local = entry(unknown, id: oldID)
        local.userNote = "Unknown owner's note"
        try store.importSnapshot(.init(items: [local], episodes: [], playback: []), mode: .replace)
        let known = details("different-installation")
        var incoming = entry(known, id: oldID)
        incoming.userNote = "Known backup owner's note"
        let history = BackupDocument.Episode(itemID: oldID, episodeData: "incoming", season: 1, episode: 1,
            positionSeconds: 50, durationSeconds: 100, watched: false, updatedAt: Date(timeIntervalSince1970: 100))
        try store.importSnapshot(.init(items: [incoming], episodes: [history], playback: []), mode: .merge)
        XCTAssertNil(try store.item(id: oldID)?.providerID)
        XCTAssertEqual(try store.item(id: oldID)?.userNote, "Unknown owner's note")
        XCTAssertEqual(try store.item(id: known.id)?.providerID, "different-installation")
        XCTAssertEqual(try store.item(id: known.id)?.userNote, "Known backup owner's note")
        XCTAssertTrue(try store.episodeProgress(itemID: oldID).isEmpty)
        XCTAssertEqual(try store.episodeProgress(itemID: known.id)["incoming"]?.positionSeconds, 50)
        let knownLegacy = LibraryStore(inMemory: true)
        try knownLegacy.importSnapshot(.init(items: [incoming], episodes: [], playback: []), mode: .replace)
        let before = knownLegacy.version
        XCTAssertThrowsError(try knownLegacy.importSnapshot(.init(items: [local], episodes: [history], playback: []), mode: .merge))
        XCTAssertEqual(knownLegacy.version, before)
        XCTAssertEqual(try knownLegacy.item(id: oldID)?.providerID, "different-installation")
        XCTAssertTrue(try knownLegacy.episodeProgress(itemID: oldID).isEmpty)
    }

    func testUnknownLegacyOwnerIsNotGuessedFromMatchingDisplayName() throws {
        let store = LibraryStore(inMemory: true)
        let unknown = details(nil)
        let oldKey = LibraryIdentity.legacy(providerName: unknown.provider, url: unknown.url)
        try store.importSnapshot(.init(items: [entry(unknown, id: oldKey)], episodes: [], playback: []), mode: .replace)
        try store.upsertLibraryEntry(details: details("identified"), watchType: .completed)
        let rows = try store.allEntries()
        XCTAssertEqual(rows.count, 2)
        XCTAssertNil(rows.first { $0.id == oldKey }?.providerID)
        XCTAssertEqual(rows.first { $0.id != oldKey }?.providerID, "identified")
    }

    func testV2BackupAndDiskReopenPreserveIdentityAndLegacyV1StillDecodes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("identity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = LibraryStore(inMemory: true)
        for id in ["one", "two"] { try source.upsertLibraryEntry(details: details(id), watchType: .watching) }
        let snapshot = try source.exportSnapshot()
        let backup = BackupDocument(createdAt: Date(), appVersion: "fixture", items: snapshot.items,
            episodes: snapshot.episodes, playback: snapshot.playback, preferences: [:], repositories: [], disabledProviders: [])
        let decoded = try BackupDocument.decode(backup.encoded())
        XCTAssertEqual(decoded.version, 2)
        XCTAssertEqual(Set(decoded.items.compactMap(\.providerID)), ["one", "two"])
        var writer: LibraryStore? = LibraryStore(storeDirectory: root)
        try XCTUnwrap(writer).importSnapshot(.init(items: decoded.items, episodes: decoded.episodes, playback: decoded.playback), mode: .replace)
        writer = nil
        let reopened = LibraryStore(storeDirectory: root)
        XCTAssertEqual(try reopened.allEntries().count, 2)
        XCTAssertEqual(try reopened.watchType(details: details("one")), .watching)

        var legacy = backup
        legacy.version = 1
        let unknown = details(nil)
        legacy.items = [entry(unknown, id: LibraryIdentity.legacy(providerName: unknown.provider, url: unknown.url))]
        let v1 = try BackupDocument.decode(legacy.encoded())
        XCTAssertEqual(v1.version, 1)
        XCTAssertNil(v1.items.first?.providerID)
    }

    func testBackupRejectsConflictingStableKeysAndDeepLinksRetainIdentity() throws {
        let first = details("stable")
        var item = entry(first, id: first.id)
        item.identityVersion = LibraryIdentity.version
        var backup = BackupDocument(createdAt: Date(), appVersion: "fixture", items: [item], episodes: [], playback: [], preferences: [:], repositories: [], disabledProviders: [])
        try backup.validate()
        backup.items[0].providerID = "different"
        XCTAssertThrowsError(try backup.validate())
        backup.items = [item, entry(first, id: "different-legacy-key")]
        XCTAssertThrowsError(try backup.validate())
        let link = try XCTUnwrap(DeepLinkRouter.titleURL(provider: first.provider, providerID: first.providerId, url: first.url))
        XCTAssertEqual(DeepLinkRouter.route(link), .openTitle(provider: first.provider, providerID: first.providerId, url: first.url))
        XCTAssertEqual(DetailCoordinate.libraryItem(id: first.id, provider: first.provider, providerID: first.providerId, url: first.url).requestProvider, "stable")
    }
}


/// Audit A33: provider settings are unchanged / set / clear, and the Keychain
/// and the engine must agree before success is reported.
@MainActor
final class ProviderConfigurationTests: XCTestCase {
    private final class Fixture {
        var keychain: [String: String] = [:]
        var requests: [PluginConfigRequestDto] = []
        var restarts = 0
        var failSave = false
        var store: ProviderConfiguration.Store {
            .init(read: { self.keychain[$0] },
                  save: { value, id in if self.failSave { throw URLError(.cannotWriteToFile) }; self.keychain[id] = value },
                  delete: { self.keychain[$0] = nil })
        }
    }
    private func response(applied: Bool = true, pending: Bool? = nil, retryable: Bool? = nil, detail: String? = nil) -> PluginConfigResponseDto {
        PluginConfigResponseDto(providerId: "p", mainUrl: "https://site", applied: applied, detail: detail, pending: pending, retryable: retryable)
    }
    private func apply(_ fixture: Fixture, url: ProviderSettingPatch = .unchanged, credential: ProviderSettingPatch = .unchanged,
                       reset: Bool = false, engine: @escaping (PluginConfigRequestDto) throws -> PluginConfigResponseDto) async -> ProviderConfiguration.Outcome {
        await ProviderConfiguration.apply(providerId: "p", url: url, credential: credential, reset: reset, store: fixture.store,
            engine: { fixture.requests.append($0); return try engine($0) }, revokeLiveCredentials: { fixture.restarts += 1 })
    }

    func testSetCommitsBothStoresAndUnchangedTouchesNeither() async {
        let fixture = Fixture()
        fixture.keychain["p"] = "old"
        var outcome = await apply(fixture, url: .set("https://b")) { _ in self.response() }
        XCTAssertTrue(outcome.succeeded)
        XCTAssertEqual(fixture.keychain["p"], "old", "an unchanged credential is not rewritten or resent")
        XCTAssertNil(fixture.requests.last?.credentials)
        XCTAssertEqual(fixture.requests.last?.clearCredentials, false)
        outcome = await apply(fixture, credential: .set("new")) { _ in self.response(applied: false, pending: true, detail: "Saved; it applies when the extension finishes loading.") }
        XCTAssertTrue(outcome.succeeded, "a held setting is committed desired state")
        XCTAssertEqual(fixture.keychain["p"], "new")
    }

    func testEngineOrKeychainFailureWhileSettingRestoresThePreviousSecret() async {
        let fixture = Fixture()
        fixture.keychain["p"] = "old"
        var outcome = await apply(fixture, credential: .set("new")) { _ in throw URLError(.networkConnectionLost) }
        XCTAssertFalse(outcome.succeeded); XCTAssertTrue(outcome.retryable)
        XCTAssertEqual(fixture.keychain["p"], "old")
        outcome = await apply(fixture, credential: .set("new")) { _ in self.response(applied: false, detail: "This provider does not support custom settings.") }
        XCTAssertFalse(outcome.succeeded); XCTAssertFalse(outcome.retryable)
        XCTAssertEqual(outcome.message, "This provider does not support custom settings.")
        XCTAssertEqual(fixture.keychain["p"], "old")
        XCTAssertEqual(fixture.restarts, 0)

        fixture.keychain["p"] = nil
        outcome = await apply(fixture, credential: .set("first")) { _ in throw URLError(.timedOut) }
        XCTAssertNil(fixture.keychain["p"], "a failed first save leaves no secret behind")

        fixture.failSave = true
        let sent = fixture.requests.count
        outcome = await apply(fixture, credential: .set("x")) { _ in self.response() }
        XCTAssertFalse(outcome.succeeded)
        XCTAssertEqual(fixture.requests.count, sent, "nothing reaches the engine when the Keychain refuses")
    }

    func testClearNeverRestoresTheSecretAndRevokesTheLiveOneOnFailure() async {
        let fixture = Fixture()
        fixture.keychain["p"] = "old"
        var outcome = await apply(fixture, credential: .clear) { _ in self.response() }
        XCTAssertTrue(outcome.succeeded)
        XCTAssertNil(fixture.keychain["p"])
        XCTAssertEqual(fixture.requests.last?.clearCredentials, true)
        XCTAssertEqual(fixture.restarts, 0)

        fixture.keychain["p"] = "old"
        outcome = await apply(fixture, credential: .clear) { _ in throw URLError(.networkConnectionLost) }
        XCTAssertFalse(outcome.succeeded, "success needs both stores to agree")
        XCTAssertNil(fixture.keychain["p"], "clearing wins over keeping a stale secret")
        XCTAssertEqual(fixture.restarts, 1, "the engine's in-memory copy is dropped by restarting it")

        fixture.keychain["p"] = "old"
        outcome = await apply(fixture, reset: true) { _ in throw URLError(.timedOut) }
        XCTAssertNil(fixture.keychain["p"])
        XCTAssertEqual(fixture.restarts, 2)
        XCTAssertEqual(fixture.requests.last?.reset, true)
    }
}
