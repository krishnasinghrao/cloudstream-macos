import Foundation

enum BackupFilePolicy {
    static func automaticName(profileID: UUID, reason: String, date: Date = Date(), id: UUID = UUID()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd_HHmmssSSS"
        let safeReason = String(reason.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }.prefix(32))
        return "CloudStream-Backup-\(profileID.uuidString)-\(formatter.string(from: date))-\(id.uuidString).\(safeReason.isEmpty ? "automatic" : safeReason).json"
    }

    /// Publish the fully written inode atomically and exclusively. A hard
    /// link in the same directory cannot replace an existing safety snapshot.
    /// Falls back to atomic move on filesystems that don't support hard links (exFAT, SMB).
    static func writeUnique(_ data: Data, to url: URL) throws {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: url.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".backup-\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        do {
            try fileManager.linkItem(at: temporary, to: url)
        } catch {
            guard !fileManager.fileExists(atPath: url.path) else {
                throw CocoaError(.fileWriteFileExists)
            }
            try fileManager.moveItem(at: temporary, to: url)
        }
    }
}
