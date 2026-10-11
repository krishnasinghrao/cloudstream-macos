import XCTest
@testable import CloudStream

/// IPC v3 metadata passthrough (Offline-Features-Plan Phase 2).
final class MetadataDtoTests: XCTestCase {
    private let v2Payload = """
    {"provider":"p","url":"u","name":"N","type":"Movie","tags":[],"actors":[],"comingSoon":false,"episodes":[],"movieData":"d"}
    """

    private let v3Payload = """
    {"provider":"p","url":"u","name":"N","type":"TvSeries","tags":["Drama"],
     "actors":[{"name":"A","role":"Hero","voiceActor":"V"}],
     "comingSoon":false,"episodes":[],
     "recommendations":[{"name":"R","url":"r","provider":"p","type":"Movie","isMovie":true,"posterHeaders":{"Referer":"x"}}],
     "trailers":[{"url":"https://t","referer":"https://ref","raw":true,"headers":{}}],
     "showStatus":"Ongoing",
     "nextAiring":{"episode":7,"unixTime":1900000000,"season":2},
     "seasonNames":[{"season":1,"name":"Arc One","displaySeason":1},{"season":2,"name":"Movie Arc"}],
     "syncIds":{"imdb":"tt1"},
     "posterHeaders":{"Referer":"https://site"},
     "uniqueUrl":"stable"}
    """

    func testV2PayloadStillDecodes() throws {
        let details = try JSONDecoder().decode(DetailsDto.self, from: Data(v2Payload.utf8))
        XCTAssertNil(details.recommendations)
        XCTAssertNil(details.trailers)
        XCTAssertNil(details.nextAiring)
        XCTAssertEqual(details.seasonTitle(1), "Season 1")
    }

    func testV3PayloadDecodesEveryField() throws {
        let details = try JSONDecoder().decode(DetailsDto.self, from: Data(v3Payload.utf8))
        XCTAssertEqual(details.recommendations?.first?.posterHeaders?["Referer"], "x")
        XCTAssertEqual(details.trailers?.first?.requestHeaders["Referer"], "https://ref")
        XCTAssertEqual(details.showStatus, "Ongoing")
        XCTAssertEqual(details.nextAiring?.episode, 7)
        XCTAssertEqual(details.nextAiring?.date, Date(timeIntervalSince1970: 1_900_000_000))
        XCTAssertEqual(details.syncIds?["imdb"], "tt1")
        XCTAssertEqual(details.uniqueUrl, "stable")
        XCTAssertEqual(details.actors.first?.voiceActor, "V")
    }

    func testSeasonTitleRules() throws {
        let details = try JSONDecoder().decode(DetailsDto.self, from: Data(v3Payload.utf8))
        XCTAssertEqual(details.seasonTitle(1), "Season 1 · Arc One")
        XCTAssertEqual(details.seasonTitle(2), "Movie Arc", "name only when no display number")
        XCTAssertEqual(details.seasonTitle(3), "Season 3")
    }

    func testTrailerExplicitRefererHeaderWins() {
        let trailer = TrailerDto(url: "https://t", referer: "https://a", raw: true, headers: ["Referer": "https://b"])
        XCTAssertEqual(trailer.requestHeaders["Referer"], "https://b")
    }

    func testPosterHeaderSanitizer() {
        let cleaned = ImageCache.sanitizedHeaders([
            "Referer": "https://ok",
            "Host": "evil",
            "X-Bad": "a\r\nInjected: 1",
            "Bad:Name": "v",
            "Content-Length": "9",
        ])
        XCTAssertEqual(cleaned, ["Referer": "https://ok"])
        XCTAssertEqual(ImageCache.sanitizedHeaders(nil), [:])
    }
}
