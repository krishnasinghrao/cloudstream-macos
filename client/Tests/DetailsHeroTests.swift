import AppKit
import SwiftUI
import XCTest
@testable import CloudStream

/// Remediation 1.3: the hero sizes itself to the artwork it actually has.
final class DetailsHeroTests: XCTestCase {
    private func details(banner: String?, poster: String?) -> DetailsDto {
        DetailsDto(provider: "P", url: "https://p.invalid/t", name: "Title", type: "Movie",
            posterUrl: poster, backgroundPosterUrl: banner, logoUrl: nil, plot: nil, year: 2020, durationMinutes: nil,
            score: nil, tags: [], actors: [], contentRating: nil, comingSoon: false, episodes: [], movieData: nil)
    }

    private func geometry(_ width: Int, _ height: Int) -> ArtworkGeometry {
        ArtworkGeometry(width: width, height: height)!
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

    func testOnlyALandscapeLonePosterBecomesTheBanner() {
        typealias Hero = MediaDetailView.HeroArtwork
        let landscape = geometry(1280, 720)
        let both = details(banner: "https://img.invalid/b.jpg", poster: "https://img.invalid/p.jpg")
        let lone = details(banner: nil, poster: "https://img.invalid/p.jpg")

        XCTAssertEqual(Hero(details: lone, posterShape: landscape), .thumbnail("https://img.invalid/p.jpg"),
                       "a 16:9 thumbnail fills the full-height banner instead of sitting beside it")
        XCTAssertEqual(Hero(details: lone, posterShape: geometry(480, 360)), .thumbnail("https://img.invalid/p.jpg"),
                       "4:3 video thumbnails count as landscape too")
        XCTAssertEqual(Hero(details: lone, posterShape: landscape).height, 580)

        // Everything else is exactly the original behaviour.
        XCTAssertEqual(Hero(details: both, posterShape: landscape), .backdrop("https://img.invalid/b.jpg"))
        XCTAssertEqual(Hero(details: lone, posterShape: geometry(600, 900)), .poster("https://img.invalid/p.jpg"))
        XCTAssertEqual(Hero(details: lone, posterShape: geometry(800, 800)), .poster("https://img.invalid/p.jpg"),
                       "square artwork keeps the poster layout")
        XCTAssertEqual(Hero(details: lone, posterShape: nil), .poster("https://img.invalid/p.jpg"),
                       "an unknown shape keeps the original poster layout")

        XCTAssertEqual(Hero.posterToMeasure(in: lone), "https://img.invalid/p.jpg")
        XCTAssertNil(Hero.posterToMeasure(in: both), "titles with a backdrop never measure the poster")
        XCTAssertNil(Hero.posterToMeasure(in: details(banner: nil, poster: " ")))
    }

    func testCardGeometryPreservesCommonRatiosAndBoundsExtremeArtwork() {
        let landscape = geometry(1280, 720)
        let portrait = geometry(600, 900)
        let square = geometry(800, 800)
        XCTAssertEqual(landscape.cardAspectRatio, 16 / 9, accuracy: 0.001)
        XCTAssertEqual(portrait.cardAspectRatio, 2 / 3, accuracy: 0.001)
        XCTAssertEqual(square.cardAspectRatio, 1)
        XCTAssertGreaterThan(landscape.shelfWidth(posterWidth: 168), portrait.shelfWidth(posterWidth: 168))
        XCTAssertEqual(geometry(10000, 50).cardAspectRatio, 2.2)
        XCTAssertEqual(geometry(50, 10000).cardAspectRatio, 0.55)
        XCTAssertNil(ArtworkGeometry(width: 0, height: 20))
        XCTAssertNil(ArtworkGeometry(width: 20, height: -1))
        XCTAssertNil(ArtworkCardLayout.grid.width(for: landscape))
        let hinted = ArtworkCardLayout.shelf(posterWidth: 168, landscapeHint: true)
        XCTAssertEqual(hinted.placeholderRatio, 16 / 9)
        XCTAssertEqual(hinted.width(for: portrait), 168, "decoded dimensions override a provider shelf hint")
    }

    func testCardsSnapToPosterWidescreenOrSquareOutsideTheGallery() {
        let shapes: [(ArtworkGeometry, standard: CGFloat)] = [
            (geometry(600, 900), 2 / 3), (geometry(500, 800), 2 / 3), (geometry(700, 900), 2 / 3),
            (geometry(800, 800), 1), (geometry(900, 1000), 1), (geometry(1100, 1000), 1), (geometry(1280, 720), 16 / 9), (geometry(480, 360), 16 / 9),
            (geometry(2560, 1080), 16 / 9),
        ]
        for (shape, standard) in shapes {
            XCTAssertEqual(ArtworkCardShape.standard.ratio(for: shape, placeholder: 2 / 3), standard, accuracy: 0.001,
                           "\(shape.width)×\(shape.height) becomes one of the three card shapes")
            XCTAssertEqual(ArtworkCardShape.natural.ratio(for: shape, placeholder: 2 / 3), shape.cardAspectRatio,
                           "the gallery keeps the artwork's own shape")
        }
        XCTAssertEqual(ArtworkCardShape.standard.ratio(for: nil, placeholder: 16 / 9), 16 / 9)
        XCTAssertEqual(ArtworkCardShape.standard.contentMode, .fill, "a snapped box is filled, never letterboxed")
        XCTAssertEqual(ArtworkCardShape.natural.contentMode, .fit)
        // Row-height parity: every shelf card is as tall as a 2:3 poster (252pt for 168pt posters).
        for shape in [geometry(600, 900), geometry(800, 800), geometry(1280, 720), geometry(2560, 1080)] {
            let width = shape.shelfWidth(posterWidth: 168)
            XCTAssertEqual(width / shape.standardCardRatio, 252, accuracy: 0.001, "\(shape.width)×\(shape.height) matches the poster row height")
        }
        XCTAssertEqual(geometry(800, 800).shelfWidth(posterWidth: 168), 252, accuracy: 0.001)
        XCTAssertEqual(geometry(1280, 720).shelfWidth(posterWidth: 168), 448, accuracy: 0.001)
        XCTAssertEqual(ArtworkCardLayout.shelf(posterWidth: 150, landscapeHint: true).width(for: nil)! / (16 / 9), 225, accuracy: 0.001,
                       "a hinted placeholder already has the row height")
    }

    func testRequestIdentityMatchesCacheCredentialsAndRendition() throws {
        let request = try XCTUnwrap(ArtworkRequest(url: " https://example.invalid/art.jpg\n", headers: ["Referer": "a"]))
        XCTAssertEqual(request, ArtworkRequest(url: request.url, headers: ["referer": "a", "Host": "ignored"]))
        XCTAssertNotEqual(request, ArtworkRequest(url: request.url, headers: ["Referer": "b"]))
        XCTAssertNotEqual(request, ArtworkRequest(url: request.url, headers: request.headers, rendition: .full))
        XCTAssertNil(ArtworkRequest(url: " \n\t"))
    }


    @MainActor
    func testActionsWrapToMeasuredRows() throws {
        let renderer = ImageRenderer(content: DetailsControlFlow {
            Text("Play").frame(width: 110, height: 36)
            Text("Add to Library").frame(width: 160, height: 36)
            Text("Download Season").frame(width: 180, height: 36)
        }.frame(width: 348))
        renderer.scale = 1
        let wrapped = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        XCTAssertEqual(wrapped.pixelsWide, 348)
        XCTAssertEqual(wrapped.pixelsHigh, 82, "actions wrap to two measured rows")
    }
}
