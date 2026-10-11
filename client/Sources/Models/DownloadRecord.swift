import Foundation
import SwiftData

/// Persisted download state (plan WS-3.6): the queue survives app restarts
/// (incomplete items re-enqueue on launch, safe because link resolution is
/// Just-In-Time) and the "Downloaded Titles" tab reflects real files.
@Model
final class DownloadRecord {
    @Attribute(.unique) var id: UUID
    var title: String
    var episodeLabel: String
    var provider: String
    /// Stable provider identity (IPC v4); nil for records made by older versions.
    var providerID: String?
    var episodeData: String
    var destinationPath: String
    /// 0=queued 1=resolving 2=downloading 3=paused 4=completed 5=failed 6=cancelled
    /// 7=finalizing: the transfer is complete and `destinationPath` is the
    /// planned final file. Values are appended, never renumbered.
    var statusRaw: Int
    var bytesWritten: Int64
    var durationSeconds: Double?
    var failureReason: String?
    var createdAt: Date
    var completedAt: Date?
    /// JSON `DownloadPolicy.SourceChoice` when the user picked a source; nil
    /// for automatic downloads and records made by older versions.
    var preferredSource: String?
    /// Profile that queued the download; its library receives the optional
    /// entry on completion. nil = legacy/unowned: nothing is filed automatically.
    var originProfileID: UUID?
    /// Durable deletion intent, saved before the file is touched.
    var deletionRequestedAt: Date?

    init(
        id: UUID = UUID(),
        title: String,
        episodeLabel: String,
        provider: String,
        episodeData: String,
        destinationPath: String,
        statusRaw: Int = 0,
        bytesWritten: Int64 = 0,
        durationSeconds: Double? = nil,
        failureReason: String? = nil,
        createdAt: Date = Date(),
        completedAt: Date? = nil,
        providerID: String? = nil,
        preferredSource: String? = nil,
        originProfileID: UUID? = nil,
    ) {
        self.id = id
        self.title = title
        self.episodeLabel = episodeLabel
        self.provider = provider
        self.providerID = providerID
        self.episodeData = episodeData
        self.destinationPath = destinationPath
        self.statusRaw = statusRaw
        self.bytesWritten = bytesWritten
        self.durationSeconds = durationSeconds
        self.failureReason = failureReason
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.preferredSource = preferredSource
        self.originProfileID = originProfileID
    }

    var destinationURL: URL { URL(fileURLWithPath: destinationPath) }

    /// Typed view of `statusRaw` (`DownloadService.ItemState.rawValue`).
    var status: DownloadService.ItemState {
        get { DownloadService.ItemState(rawValue: statusRaw) ?? .queued }
        set { statusRaw = newValue.rawValue }
    }

    var existsOnDisk: Bool {
        FileManager.default.fileExists(atPath: destinationPath)
    }

    var fileByteSize: Int64 {
        (try? destinationURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0
    }
}
