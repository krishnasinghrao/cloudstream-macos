import CryptoKit
import Foundation

/// Stable provider IDs identify installations; display names do not. Length
/// framing avoids separator collisions and original URL bytes remain intact.
enum LibraryIdentity {
    static let version = 2
    static func remote(providerID: String, url: String) -> String {
        let framed = "\(providerID.utf8.count):\(providerID)\(url.utf8.count):\(url)"
        let digest = SHA256.hash(data: Data(framed.utf8))
        return "remote-v2:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    static func localDownload(_ id: UUID) -> String { "local-download-v2:" + id.uuidString.lowercased() }
    static func downloadID(from key: String) -> UUID? {
        let prefix = "local-download-v2:"
        guard key.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(key.dropFirst(prefix.count)))
    }

    static func legacy(providerName: String, url: String) -> String { "\(providerName)|\(url)" }

    static func key(providerID: String?, providerName: String, url: String) -> String {
        guard let providerID, !providerID.isEmpty else { return legacy(providerName: providerName, url: url) }
        return remote(providerID: providerID, url: url)
    }
}
