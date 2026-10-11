import XCTest
@testable import CloudStream

/// Remediation 1.3: the hero sizes itself to the artwork it actually has.
final class DetailsHeroTests: XCTestCase {
    private func details(banner: String?, poster: String?) -> DetailsDto {
        DetailsDto(provider: "P", url: "https://p.invalid/t", name: "Title", type: "Movie",
            posterUrl: poster, backgroundPosterUrl: banner, logoUrl: nil, plot: nil, year: 2020, durationMinutes: nil,
            score: nil, tags: [], actors: [], contentRating: nil, comingSoon: false, episodes: [], movieData: nil)
    }

    func testTheHeroUsesTheBackdropThenTheLonePosterThenACompactGradient() {
        typealias Hero = MediaDetailView.HeroArtwork
        let backdrop = Hero(details: details(banner: "https://img.invalid/b.jpg", poster: "https://img.invalid/p.jpg"))
        XCTAssertEqual(backdrop, .backdrop("https://img.invalid/b.jpg"), "a widescreen backdrop wins over the poster")
        XCTAssertEqual(backdrop.height, 580)

        let poster = Hero(details: details(banner: nil, poster: "https://img.invalid/p.jpg"))
        XCTAssertEqual(poster, .poster("https://img.invalid/p.jpg"), "a lone portrait poster is shown as a poster, not stretched")
        XCTAssertLessThan(poster.height, backdrop.height)

        for empty in [details(banner: nil, poster: nil), details(banner: "", poster: "")] {
            let none = Hero(details: empty)
            XCTAssertEqual(none, .none, "empty URLs count as no artwork")
            XCTAssertEqual(none.height, 260, "no artwork collapses to the compact banner, never a vacant 580 pt box")
        }
    }
}
