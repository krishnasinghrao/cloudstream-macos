import XCTest
@testable import CloudStream

/// Single-pass entity decoding (U-62). The old implementation replaced
/// `&#65;` with the literal digits "65".
final class HTMLStringSanitizerTests: XCTestCase {
    func testNumericEntityDecodesToCharacter() {
        XCTAssertEqual(HTMLStringSanitizer.sanitize("&#65;&#66;&#67;"), "ABC")
    }

    func testHexEntityDecodesToCharacter() {
        XCTAssertEqual(HTMLStringSanitizer.sanitize("&#x41;&#x42;"), "AB")
        XCTAssertEqual(HTMLStringSanitizer.sanitize("&#X26;"), "&")
    }

    func testMultibyteNumericEntity() {
        XCTAssertEqual(HTMLStringSanitizer.sanitize("&#233;"), "é")
        XCTAssertEqual(HTMLStringSanitizer.sanitize("&#20013;"), "中")
    }

    func testNamedEntities() {
        XCTAssertEqual(HTMLStringSanitizer.sanitize("Tom &amp; Jerry &lt;3 &quot;hi&quot; &hellip;"), "Tom & Jerry <3 \"hi\" …")
    }

    func testDoubleEncodedEntityDoesNotDoubleDecode() {
        // `&amp;#65;` must render as the literal `&#65;`, not "A".
        XCTAssertEqual(HTMLStringSanitizer.sanitize("&amp;#65;"), "&#65;")
    }

    func testUnknownEntityStaysVerbatim() {
        XCTAssertEqual(HTMLStringSanitizer.sanitize("&fakeentity;"), "&fakeentity;")
    }

    func testTagsAreStripped() {
        XCTAssertEqual(HTMLStringSanitizer.sanitize("<b>Bold</b> and <i>italic</i>"), "Bold and italic")
    }

    func testLineBreaks() {
        XCTAssertEqual(HTMLStringSanitizer.sanitize("one<br>two<br/>three<p>four</p>"), "one\ntwo\nthree\n\nfour")
    }

    func testEmptyInput() {
        XCTAssertEqual(HTMLStringSanitizer.sanitize(nil), "")
        XCTAssertEqual(HTMLStringSanitizer.sanitize(""), "")
    }

    func testExcessBlankLinesCollapse() {
        XCTAssertEqual(HTMLStringSanitizer.sanitize("a\n\n\n\nb"), "a\n\nb")
    }
}
