import CryptoKit
import Foundation

extension Sequence where Element == UInt8 {
    /// Lowercase hexadecimal, two digits per byte: digests, MACs and tokens.
    var hexString: String {
        let lookup: [UInt8] = Array("0123456789abcdef".utf8)
        var bytes: [UInt8] = []
        let estimatedCount = underestimatedCount
        if estimatedCount > 0 { bytes.reserveCapacity(estimatedCount * 2) }
        for byte in self {
            bytes.append(lookup[Int(byte >> 4)])
            bytes.append(lookup[Int(byte & 0x0F)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

extension SHA256 {
    /// The lowercase hexadecimal SHA-256 of a file, read in 256 KiB blocks so
    /// large archives and databases are never loaded whole.
    static func hexDigest(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let block = try handle.read(upToCount: 256 * 1024), !block.isEmpty { hash.update(data: block) }
        return hash.finalize().hexString
    }
}
