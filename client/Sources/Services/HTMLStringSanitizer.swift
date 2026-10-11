import Foundation

/// Fast, safe utility for decoding HTML entities and stripping markup
/// from scraper synopses, episode descriptions, and subtitles.
enum HTMLStringSanitizer {
    /// Matches decimal (`&#65;`), hex (`&#x41;`), and named entities.
    private static let entityPattern = try! NSRegularExpression(
        pattern: "&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]*);",
    )

    private static let namedEntities: [String: String] = [
        "quot": "\"",
        "apos": "'",
        "amp": "&",
        "lt": "<",
        "gt": ">",
        "nbsp": "\u{00A0}",
        "ndash": "–",
        "mdash": "—",
        "lsquo": "‘",
        "rsquo": "’",
        "ldquo": "“",
        "rdquo": "”",
        "hellip": "…",
    ]

    static func sanitize(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }

        var text = raw

        // Standard line-break replacements. A <p> opens a paragraph, so both
        // the open and close tags become breaks ("" glued "three<p>four").
        text = text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "</p>", with: "\n\n", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "<p>", with: "\n\n", options: .caseInsensitive)

        // Strip remaining HTML tags
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)

        // Single-pass entity decode: one regex sweep for decimal/hex/named
        // forms. (`&#65;` becomes "A" — the old two-phase replace emitted the
        // literal digits.) A single pass also means `&amp;#65;` correctly
        // decodes to `&#65;` and stops.
        text = Self.decodeEntities(in: text)

        // Clean up excessive empty lines and trailing whitespace
        let cleanedLines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        var result: [String] = []
        var emptyCount = 0
        for line in cleanedLines {
            if line.isEmpty {
                emptyCount += 1
                if emptyCount <= 1 && !result.isEmpty {
                    result.append("")
                }
            } else {
                emptyCount = 0
                result.append(line)
            }
        }

        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeEntities(in text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        var result = String.UnicodeScalarView()
        var cursor = text.startIndex

        for match in entityPattern.matches(in: text, range: range) {
            guard let full = Range(match.range, in: text) else { continue }
            result.append(contentsOf: text[cursor..<full.lowerBound].unicodeScalars)

            let bodyStart = text.index(after: full.lowerBound)
            let bodyEnd = text.index(before: full.upperBound)
            let name = String(text[bodyStart..<bodyEnd])

            if let replacement = decodeEntityBody(name) {
                result.append(contentsOf: replacement.unicodeScalars)
            } else {
                // Unknown entity — leave verbatim.
                result.append(contentsOf: text[full].unicodeScalars)
            }
            cursor = full.upperBound
        }
        result.append(contentsOf: text[cursor...].unicodeScalars)
        return String(result)
    }

    private static func decodeEntityBody(_ name: String) -> String? {
        if name.hasPrefix("#") {
            let digits = name.dropFirst()
            var scalarValue: UInt32 = 0
            if digits.first == "x" || digits.first == "X" {
                scalarValue = UInt32(digits.dropFirst(), radix: 16) ?? 0
            } else {
                scalarValue = UInt32(digits, radix: 10) ?? 0
            }
            guard scalarValue > 0, scalarValue <= 0x10FFFF,
                  let scalar = Unicode.Scalar(scalarValue) else { return nil }
            return String(Character(scalar))
        }
        return namedEntities[name.lowercased()]
    }
}
