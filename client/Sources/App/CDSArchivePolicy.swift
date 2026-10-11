import CryptoKit
import Foundation

/// Optional optimization: a stale/missing archive always falls back to normal
/// JVM startup. Call from a background executor; hashing is bounded streaming IO.
enum CDSArchivePolicy {
    private struct Metadata: Decodable {
        let version: Int
        let jarSha256: String
        let modulesSha256: String
        let archiveSha256: String
    }

    static func validatedArchive(archive: URL, jar: URL, java: URL) -> URL? {
        let metadataURL = archive.deletingPathExtension().appendingPathExtension("cds.json")
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: metadataURL.path)
            guard let size = attributes[.size] as? UInt64, size <= 65_536 else { return nil }
            let metadata = try JSONDecoder().decode(Metadata.self, from: Data(contentsOf: metadataURL))
            let modules = java.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("lib/modules")
            guard metadata.version == 1,
                  try digest(jar) == metadata.jarSha256,
                  try digest(modules) == metadata.modulesSha256,
                  try digest(archive) == metadata.archiveSha256 else { return nil }
            return archive
        } catch { return nil }
    }

    static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
