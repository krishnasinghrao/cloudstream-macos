import XCTest
@testable import CloudStream

/// QuickTime-style player window fitting: aspect-correct, never off the
/// usable screen area (menu bar and Dock excluded).
@MainActor
final class PlayerWindowGeometryTests: XCTestCase {
    /// A 1512×982 MacBook screen with menu bar and a bottom Dock removed.
    private let area = NSRect(x: 0, y: 90, width: 1512, height: 857)

    private func assertInside(_ rect: NSRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(area.contains(rect), "\(rect) escapes \(area)", file: file, line: line)
    }

    func testFourByThreeVideoNearTopStaysAboveDock() {
        // The reported bug: a 4:3 film fitted from a window near the top.
        let rect = PlayerWindowController.fittedContentRect(
            videoSize: NSSize(width: 1440, height: 1080),
            around: NSPoint(x: 756, y: 900),
            in: area,
        )
        assertInside(rect)
        XCTAssertEqual(rect.width / rect.height, 4.0 / 3.0, accuracy: 0.01)
    }

    func testSmallVideoOpensAtNaturalSize() {
        let rect = PlayerWindowController.fittedContentRect(
            videoSize: NSSize(width: 640, height: 360),
            around: NSPoint(x: area.midX, y: area.midY),
            in: area,
        )
        XCTAssertEqual(rect.size, NSSize(width: 640, height: 360))
    }

    func testLargeVideoCappedToScreenFraction() {
        let rect = PlayerWindowController.fittedContentRect(
            videoSize: NSSize(width: 3840, height: 2160),
            around: NSPoint(x: area.midX, y: area.midY),
            in: area,
        )
        assertInside(rect)
        XCTAssertLessThanOrEqual(rect.width, area.width * 0.85 + 1)
        XCTAssertEqual(rect.width / rect.height, 16.0 / 9.0, accuracy: 0.01)
    }

    func testUserSizeIsABoxNotAnAspect() {
        // A remembered 16:9 size must not force a 4:3 video into 16:9.
        let rect = PlayerWindowController.fittedContentRect(
            videoSize: NSSize(width: 640, height: 480),
            preferredBox: NSSize(width: 1000, height: 562),
            around: NSPoint(x: area.midX, y: area.midY),
            in: area,
        )
        XCTAssertEqual(rect.width / rect.height, 4.0 / 3.0, accuracy: 0.01)
        XCTAssertEqual(rect.height, 562, accuracy: 1)
    }

    func testTinyVideoIsEnlargedToMinimumWithItsAspect() {
        let rect = PlayerWindowController.fittedContentRect(
            videoSize: NSSize(width: 320, height: 240),
            around: NSPoint(x: area.midX, y: area.midY),
            in: area,
        )
        XCTAssertGreaterThanOrEqual(rect.width, PlayerWindowController.minLongSide)
        XCTAssertGreaterThanOrEqual(rect.height, PlayerWindowController.minShortSide)
        XCTAssertEqual(rect.width / rect.height, 4.0 / 3.0, accuracy: 0.01)
    }

    // MARK: Extreme aspect ratios and small or missing displays (audit design note)

    func testExtremeAspectRatiosNeverExceedTheUsableArea() {
        let small = NSRect(x: 0, y: 40, width: 1024, height: 600)
        for (width, height) in [(5120.0, 1440.0), (7680.0, 1080.0), (1080.0, 2560.0), (360.0, 1920.0), (4096.0, 256.0)] {
            for screen in [area, small] {
                let video = NSSize(width: width, height: height)
                let rect = PlayerWindowController.fittedContentRect(videoSize: video,
                    around: NSPoint(x: screen.midX, y: screen.midY), in: screen)
                XCTAssertTrue(screen.contains(rect), "\(video) → \(rect) escapes \(screen)")
                // Whole-point sizes: allow the rounding of the short side.
                XCTAssertEqual(rect.width / rect.height, width / height, accuracy: (width / height) * 0.02, "aspect is kept for \(video)")
                let minimum = PlayerWindowController.minimumContentSize(aspect: width / height, within: screen.size)
                XCTAssertLessThanOrEqual(minimum.width, screen.width)
                XCTAssertLessThanOrEqual(minimum.height, screen.height)
                XCTAssertLessThanOrEqual(minimum.width, rect.width + 1, "the fitted window satisfies its own minimum")
            }
        }
        // Ordinary video on an ordinary screen keeps the usual minimum.
        XCTAssertEqual(PlayerWindowController.minimumContentSize(aspect: 16.0 / 9.0, within: area.size),
                       PlayerWindowController.minimumContentSize(aspect: 16.0 / 9.0))
    }

    func testWindowRememberedOnADisconnectedDisplayIsBroughtBackOnScreen() {
        // The old window centre lies on a display that is no longer there,
        // to the right of and above the remaining one.
        for centre in [NSPoint(x: 4200, y: 1900), NSPoint(x: -3000, y: -900), NSPoint(x: area.maxX, y: area.minY)] {
            let rect = PlayerWindowController.fittedContentRect(videoSize: NSSize(width: 1920, height: 1080),
                preferredBox: NSSize(width: 3000, height: 1700), around: centre, in: area)
            assertInside(rect)
            XCTAssertEqual(rect.width / rect.height, 16.0 / 9.0, accuracy: 0.01)
        }
    }

    func testMinimumSizeFollowsAspect() {
        let vertical = PlayerWindowController.minimumContentSize(aspect: 9.0 / 16.0)
        XCTAssertEqual(vertical.width / vertical.height, 9.0 / 16.0, accuracy: 0.01)
        XCTAssertEqual(vertical.height, PlayerWindowController.minLongSide, accuracy: 1)
        XCTAssertGreaterThanOrEqual(vertical.width, PlayerWindowController.minShortSide - 1)
    }
}
