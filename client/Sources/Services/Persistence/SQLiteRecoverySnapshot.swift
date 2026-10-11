import CryptoKit
import Foundation
import SQLite3

/// SQLite's backup API includes committed WAL contents in one consistent image.
/// Copying the live .store file alone would not provide this recovery contract.
enum SQLiteRecoverySnapshot {
    struct Manifest: Codable, Sendable {
        let version: Int
        let createdAt: Date
        let sourceStore: String
        let snapshotSHA256: String
        let reason: String
        var sourceStoreIdentifier: String? = nil
    }
    struct Failure: LocalizedError {
        let detail: String
        var errorDescription: String? { "Couldn't create a verified recovery copy: \(detail)" }
    }

    /// Run before ModelContainer opens an older store, so recovery for an
    /// older compatible binary also preserves its original schema metadata.
    static func needsSchemaRecovery(_ source: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: source.path) else { return false }
        var database: OpaquePointer?
        guard sqlite3_open_v2(source.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            throw Failure(detail: "The existing store cannot be inspected before migration.")
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1000)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT 1 FROM sqlite_master WHERE type='table' AND upper(name)='ZLIBRARYMIGRATIONRECORD'", -1, &statement, nil) == SQLITE_OK else {
            throw Failure(detail: "The existing schema could not be inspected (SQLite \(sqlite3_errcode(database))). Retry after current database work finishes.")
        }
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW || result == SQLITE_DONE else { throw Failure(detail: "The existing schema could not be read.") }
        return result == SQLITE_DONE
    }

    /// Recover the pre-schema artifact after a process died before the marker
    /// commit. Basenames alone cannot identify a store recreated at the same path.
    static func originalSchemaSnapshot(source: URL, directory: URL) throws -> URL? {
        guard FileManager.default.fileExists(atPath: directory.path),
              let owner = try storeIdentifier(source) else { return nil }
        var candidates: [(URL, Date)] = []
        for generation in try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            guard UUID(uuidString: generation.lastPathComponent) != nil else { continue }
            let values = try generation.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let snapshot = generation.appendingPathComponent("recovery.store")
            // SIGKILL during creation can leave an unpublished partial image.
            // Only the atomic manifest publication admits a candidate.
            guard FileManager.default.fileExists(atPath: snapshot.path),
                  FileManager.default.fileExists(atPath: generation.appendingPathComponent("manifest.json").path) else { continue }
            let manifest: Manifest
            do { manifest = try readManifest(snapshot) }
            catch {
                // Recovery directories are shared by profile stores. A bad
                // artifact from another UUID cannot disable this profile.
                if (try? storeIdentifier(snapshot)) == owner { throw error }
                continue
            }
            guard manifest.reason == "before-provider-identity-schema-v2",
                  manifest.sourceStore == source.lastPathComponent else { continue }
            if let identifier = manifest.sourceStoreIdentifier {
                guard identifier == owner else { continue }
            } else {
                // Earlier version-1 manifests did not record this field.
                guard try storeIdentifier(snapshot) == owner else { continue }
            }
            candidates.append((snapshot, manifest.createdAt))
        }
        guard let latest = candidates.max(by: { $0.1 < $1.1 })?.0 else { return nil }
        try verify(latest)
        guard try storeIdentifier(latest) == owner else { throw Failure(detail: "The original recovery copy belongs to another store.") }
        guard try needsSchemaRecovery(latest) else {
            throw Failure(detail: "The original recovery copy does not contain the original schema.")
        }
        return latest
    }

    private static func storeIdentifier(_ source: URL) throws -> String? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(source.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            throw Failure(detail: "The recovery store identity cannot be inspected.")
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1000)
        var statement: OpaquePointer?
        // Non-CoreData SQLite fixture stores need no schema lineage recovery.
        guard sqlite3_prepare_v2(database, "SELECT Z_UUID FROM Z_METADATA", -1, &statement, nil) == SQLITE_OK else {
            if sqlite3_errcode(database) == SQLITE_ERROR { return nil }
            throw Failure(detail: "The store identity cannot be read (SQLite \(sqlite3_errcode(database))). Retry after current database work finishes.")
        }
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else {
            throw Failure(detail: "The store identity could not be read.")
        }
        let identifier = String(cString: value)
        guard sqlite3_step(statement) == SQLITE_DONE, UUID(uuidString: identifier) != nil else {
            throw Failure(detail: "The store identity is ambiguous or invalid.")
        }
        return identifier
    }

    private static func readManifest(_ snapshot: URL) throws -> Manifest {
        let handle = try FileHandle(forReadingFrom: snapshot.deletingLastPathComponent().appendingPathComponent("manifest.json"))
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 64 * 1024 + 1) ?? Data()
        guard data.count <= 64 * 1024 else { throw Failure(detail: "The recovery manifest is oversized.") }
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard manifest.version == 1, manifest.createdAt.timeIntervalSince1970.isFinite else {
            throw Failure(detail: "The recovery manifest is unsupported or invalid.")
        }
        return manifest
    }

    static func create(source: URL, directory: URL, reason: String) throws -> URL {
        let generation = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: generation, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let destination = generation.appendingPathComponent("recovery.store")
        var published = false
        defer { if !published { try? FileManager.default.removeItem(at: generation) } }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil,
            attributes: [.posixPermissions: 0o600]) else { throw Failure(detail: "The recovery destination is unavailable.") }
        try copyDatabase(source: source, destination: destination)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.synchronize()
        let manifest = Manifest(version: 1, createdAt: Date(), sourceStore: source.lastPathComponent,
            snapshotSHA256: try digest(destination), reason: reason, sourceStoreIdentifier: try storeIdentifier(destination))
        let manifestURL = generation.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
        let manifestHandle = try FileHandle(forWritingTo: manifestURL)
        defer { try? manifestHandle.close() }
        try manifestHandle.synchronize()
        try verify(destination)
        published = true
        return destination
    }

    static func verify(_ snapshot: URL) throws {
        let manifest = try readManifest(snapshot)
        guard manifest.version == 1, try digest(snapshot) == manifest.snapshotSHA256 else {
            throw Failure(detail: "Recovery copy verification failed.")
        }
        var database: OpaquePointer?
        guard sqlite3_open_v2(snapshot.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            throw Failure(detail: "The recovery database cannot be opened.")
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1000)
        try integrityCheck(database)
    }

    private static func copyDatabase(source: URL, destination: URL) throws {
        var input: OpaquePointer?, output: OpaquePointer?
        defer { if let input { sqlite3_close(input) }; if let output { sqlite3_close(output) } }
        guard sqlite3_open_v2(source.path, &input, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              sqlite3_open_v2(destination.path, &output, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw Failure(detail: "The database or recovery destination cannot be opened.")
        }
        guard let backup = sqlite3_backup_init(output, "main", input, "main") else {
            throw Failure(detail: "SQLite could not initialize a consistent snapshot.")
        }
        let result = sqlite3_backup_step(backup, -1)
        let finished = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE, finished == SQLITE_OK else {
            throw Failure(detail: "The database is busy or its snapshot could not be written. Retry when current work finishes.")
        }
        try integrityCheck(output)
    }

    private static func integrityCheck(_ database: OpaquePointer?) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA integrity_check", -1, &statement, nil) == SQLITE_OK else {
            throw Failure(detail: "The database integrity check could not run.")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let result = sqlite3_column_text(statement, 0),
              String(cString: result) == "ok", sqlite3_step(statement) == SQLITE_DONE else {
            throw Failure(detail: "The recovery database did not pass its integrity check.")
        }
    }

    private static func digest(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let block = try handle.read(upToCount: 256 * 1024), !block.isEmpty { hash.update(data: block) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
