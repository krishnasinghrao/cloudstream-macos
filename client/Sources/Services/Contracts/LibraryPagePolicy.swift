import CryptoKit
import Foundation

/// Shared page rules for persistence and portable backups, without SwiftData.
enum LibraryPagePolicy {
    static let maxNameLength = 60

    /// Trimmed, single-line and bounded; nil when nothing usable is left.
    static func normalizedName(_ raw: String) -> String? {
        let singleLine = raw.components(separatedBy: .newlines).joined(separator: " ")
        let trimmed = singleLine.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxNameLength))
    }

    /// Hash multi-KB episode data to keep the unique index small.
    static func entryKey(pageID: String, itemID: String, episodeData: String?) -> String {
        guard let episodeData else { return pageID + "|" + itemID }
        let digest = SHA256.hash(data: Data(episodeData.utf8))
        return pageID + "|" + itemID + "|" + digest.map { String(format: "%02x", $0) }.joined()
    }
}
