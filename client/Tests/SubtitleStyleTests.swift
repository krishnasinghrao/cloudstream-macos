import XCTest
@testable import CloudStream

/// Legacy ARGB → canonical RGBA migration (U-13).
final class SubtitleStyleTests: XCTestCase {
    func testLegacyARGBValuesMigrateToRGBA() {
        // Yellow was stored as ARGB #FFFFFF00 — alpha 00, invisible in mpv.
        XCTAssertEqual(SubtitleColor.migratingLegacy("#FFFFFF00"), SubtitleColor.yellow)
        // Cyan was ARGB #FF00FFFF — mpv parsed it as opaque magenta.
        XCTAssertEqual(SubtitleColor.migratingLegacy("#FF00FFFF"), SubtitleColor.cyan)
        // Green was ARGB #FF00FF00 — mpv parsed it as transparent magenta.
        XCTAssertEqual(SubtitleColor.migratingLegacy("#FF00FF00"), SubtitleColor.green)
    }

    func testWhiteIsCanonicalInBothOrders() {
        XCTAssertEqual(SubtitleColor.migratingLegacy("#FFFFFFFF"), SubtitleColor.white)
        XCTAssertEqual(SubtitleColor.migratingLegacy(SubtitleColor.white), SubtitleColor.white)
    }

    func testUnknownValuesPassThrough() {
        XCTAssertEqual(SubtitleColor.migratingLegacy("#00FF00FF"), "#00FF00FF")
        XCTAssertNil(SubtitleColor.migratingLegacy(nil))
    }

    func testMigrationIsCaseInsensitive() {
        XCTAssertEqual(SubtitleColor.migratingLegacy("#fffffF00"), SubtitleColor.yellow)
    }

    func testAllPresetsAreOpaqueRGBA() {
        for (_, color) in SubtitleColor.presets {
            XCTAssertEqual(color.count, 9, "preset \(color) must be #RRGGBBAA")
            XCTAssertEqual(color.hasPrefix("#"), true)
            let alpha = color.suffix(2)
            XCTAssertEqual(alpha.lowercased(), "ff", "preset \(color) must be fully opaque")
        }
    }

    func testSubtitleStyleDefaults() {
        let style = SubtitleStyle()
        XCTAssertEqual(style.fontSize, 55)
        XCTAssertEqual(style.outlineWidth, 3)
    }
}
