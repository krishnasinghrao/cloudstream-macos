import Foundation
import Synchronization

/// A bounded layout index, independent of bitmap eviction. Keys are hashes of
/// URL + sanitized request headers; credentials and source URLs are never saved.
///
/// All file reads/encoding/writes run off the main actor. The main actor only
/// touches `generation` (an atomic load) and `invalidate()`. Reads take no lock:
/// writes are atomic renames, so a reader sees a whole old or new file. The
/// write lock only serializes a cache clear with an already-running write, so
/// cleared metadata cannot come back.
final class ArtworkMetadataStore: Sendable {
    struct Record: Codable, Sendable {
        let geometry: ArtworkGeometry
        let updated: TimeInterval
    }

    static let maximumRecords = 20_000
    static let maximumBytes = 4 * 1_048_576
    private let file: URL
    private let epoch = Atomic<UInt64>(0)
    private let writeLock = Mutex<Void>(())

    init(directory: URL) { file = directory.appendingPathComponent("artwork-layout.json") }

    var generation: UInt64 { epoch.load(ordering: .acquiring) }

    func read() -> [String: Record] {
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= Self.maximumBytes,
              let data = try? Data(contentsOf: file), data.count <= Self.maximumBytes,
              let records = try? JSONDecoder().decode([String: Record].self, from: data) else { return [:] }
        return Self.bounded(records)
    }

    func write(_ records: [String: Record], generation: UInt64) {
        guard let data = try? JSONEncoder().encode(Self.bounded(records)), data.count <= Self.maximumBytes else { return }
        writeLock.withLock { _ in
            guard epoch.load(ordering: .acquiring) == generation else { return }
            // Do not recreate a deleted test/cache directory from a late write.
            try? data.write(to: file, options: .atomic)
        }
    }

    /// Waits for a write already in progress, so a caller that deletes the
    /// file next is guaranteed nothing older lands after it.
    func invalidate() {
        writeLock.withLock { _ in
            epoch.wrappingAdd(1, ordering: .releasing)
        }
    }

    static func bounded(_ records: [String: Record]) -> [String: Record] {
        let valid = records.filter { key, value in
            key.count == 64 && key.allSatisfy(\.isHexDigit) && value.updated.isFinite
        }
        guard valid.count > maximumRecords else { return valid }
        return Dictionary(uniqueKeysWithValues: valid.sorted {
            $0.value.updated == $1.value.updated ? $0.key < $1.key : $0.value.updated > $1.value.updated
        }.prefix(maximumRecords).map { ($0.key, $0.value) })
    }
}
