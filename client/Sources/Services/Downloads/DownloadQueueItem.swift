import Foundation
import Observation

/// Queue values and per-transfer progress; execution stays in DownloadService.
extension DownloadService {
    enum ItemState: Int, Equatable {
        case queued = 0
        case resolving = 1
        case downloading = 2
        case paused = 3
        case completed = 4
        case failed = 5
        case cancelled = 6
        /// The transfer finished; the file is being moved into place and the
        /// completion committed. Appended so older raw values keep their meaning.
        case finalizing = 7

        /// Holds (or is waiting for) a queue slot.
        var isActive: Bool {
            switch self {
            case .queued, .resolving, .downloading, .paused, .finalizing: return true
            case .completed, .failed, .cancelled: return false
            }
        }

        var isFinished: Bool { !isActive }
    }

    enum EnqueueResult: Equatable {
        case enqueued
        case alreadyQueued
        case alreadyDownloaded
        case persistenceFailed
    }

    /// A download request from the UI. `directory` + `baseName` are turned
    /// into a collision-free destination by the service (not the caller),
    /// because only the service knows which paths queued items reserve.
    struct Request {
        var title: String
        var episodeLabel: String
        var provider: String
        /// Stable provider identity used to resolve links (IPC v4).
        var providerID: String? = nil
        var episodeData: String
        var directory: URL
        var baseName: String
        var durationSeconds: Double?
        /// Source the user picked; nil = automatic order.
        var preferredSource: DownloadPolicy.SourceChoice? = nil
    }

    @MainActor
    @Observable
    final class QueueItem: Identifiable {
        let id: UUID
        let title: String
        let episodeLabel: String
        let provider: String
        let providerID: String?
        let episodeData: String
        /// Final file path. The extension may change on completion (a direct
        /// `.mkv`, or the Matroska fallback for streams MP4 can't hold).
        var destinationURL: URL
        let durationSeconds: Double?
        /// Source the user picked. Tried first; the automatic order remains
        /// the fallback.
        let preferredSource: DownloadPolicy.SourceChoice?
        /// Profile that queued this download (nil for legacy records).
        let originProfileID: UUID?
        /// The user (or the network returning) asked a frozen transfer to
        /// continue; it does so only when admission grants it a slot.
        var resumeRequested = false
        /// Set while a mirror other than the picked source is in use.
        var fallbackSourceName: String?
        /// Queue order across restarts (restore sorts by it).
        var createdAt: Date

        var orderedLinks: [StreamLinkDto] = []
        var orderedMirrorKeys: [String] = []
        var subtitles: [SubtitleDto] = []
        var linksResolvedAt: Date?

        var state: ItemState = .queued
        /// Secondary status ("Waiting for streaming engine…", "Retrying…").
        var statusDetail: String?
        var progress: Double = 0 // 0...1
        var bytesWritten: Int64 = 0
        var totalBytesExpected: Int64?
        var speedBytesPerSecond: Double = 0
        var startedAt: Date?
        /// Number of mirrors already given up on (drives "mirror #n").
        var activeLinkIndex = 0
        var failureReason: FailureReason?

        // Retry bookkeeping for the current mirror.
        var triedMirrorKeys: Set<String> = []
        var currentMirrorKey: String?
        var retriedCurrentMirror = false
        var useMatroska = false
        var forceResolve = false
        var lastFailure: FailureReason?
        var stallDetected = false

        /// ffmpeg's own processing rate (`speed=`, e.g. 12.4× realtime).
        var mediaSpeedMultiplier: Double = 0
        /// Stream position from `out_time_us`, seconds.
        var streamPositionSeconds: Double = 0
        /// Authoritative duration reported by ffmpeg for the source; beats
        /// the provider's approximate runtime.
        var inputDurationSeconds: Double?
        var lastSampleAt: Date?
        var lastSampleBytes: Int64 = 0
        var lastProgressAt: Date?

        init(
            id: UUID = UUID(),
            title: String,
            episodeLabel: String,
            provider: String,
            episodeData: String,
            destinationURL: URL,
            durationSeconds: Double?,
            createdAt: Date = Date(),
            providerID: String? = nil,
            preferredSource: DownloadPolicy.SourceChoice? = nil,
            originProfileID: UUID? = nil,
        ) {
            self.id = id
            self.originProfileID = originProfileID
            self.providerID = providerID
            self.preferredSource = preferredSource
            self.title = title
            self.episodeLabel = episodeLabel
            self.provider = provider
            self.episodeData = episodeData
            self.destinationURL = destinationURL
            self.durationSeconds = durationSeconds
            self.createdAt = createdAt
        }

        /// `<dir>/<name>` without extension: the reserved identity of this
        /// download on disk.
        var baseURL: URL { destinationURL.deletingPathExtension() }
        var partURL: URL { baseURL.appendingPathExtension("part") }

        var effectiveDuration: Double? {
            if let inputDurationSeconds, inputDurationSeconds > 0 { return inputDurationSeconds }
            if let durationSeconds, durationSeconds > 0 { return durationSeconds }
            return nil
        }

        var speedLabel: String {
            switch state {
            case .queued: return statusDetail ?? "Queued"
            case .resolving: return statusDetail ?? "Resolving…"
            case .completed: return "Completed"
            case .cancelled: return "Cancelled"
            case .failed: return "Failed — \(failureReason?.label ?? "unknown")"
            case .finalizing: return statusDetail ?? "Finishing…"
            case .downloading, .paused:
                let mbps = speedBytesPerSecond / 1_048_576
                return String(format: "%.1f MB/s", mbps)
            }
        }

        var progressLabel: String {
            guard state == .downloading || state == .paused || state == .completed else { return "—" }
            if totalBytesExpected != nil || effectiveDuration != nil {
                return String(format: "%.0f%%", progress * 100)
            }
            return ByteCountFormatter.string(fromByteCount: bytesWritten, countStyle: .file)
        }

        /// Honest ETA: bytes-remaining for direct files, stream-remaining at
        /// ffmpeg's realtime multiplier for remuxes. Hidden when unknown.
        var etaLabel: String? {
            guard state == .downloading else { return nil }
            if let total = totalBytesExpected, total > 0 {
                guard speedBytesPerSecond > 0 else { return nil }
                let remaining = Double(total - bytesWritten)
                guard remaining > 0 else { return nil }
                return Self.formatDuration(remaining / speedBytesPerSecond)
            }
            guard mediaSpeedMultiplier > 0, let duration = effectiveDuration else { return nil }
            let streamRemaining = duration - streamPositionSeconds
            guard streamRemaining > 0 else { return nil }
            return Self.formatDuration(streamRemaining / mediaSpeedMultiplier)
        }

        nonisolated static func formatDuration(_ seconds: Double) -> String {
            let total = Int(seconds)
            let hours = total / 3600
            let minutes = (total % 3600) / 60
            let secs = total % 60
            if hours > 0 { return "\(hours)h \(minutes)m" }
            return "\(minutes)m \(secs)s"
        }

        /// Ingests one `-progress` key=value pair.
        func ingest(progressKey key: String, value: String) {
            guard state == .downloading else { return }
            switch key {
            case "out_time_us":
                guard let micros = Double(value), micros >= 0 else { return }
                let position = micros / 1_000_000
                if position > streamPositionSeconds { lastProgressAt = Date() }
                streamPositionSeconds = position
                if let duration = effectiveDuration {
                    progress = min(1, streamPositionSeconds / duration)
                }
            case "speed":
                // "12.4x" → 12.4
                let scalar = value.trimmingCharacters(in: CharacterSet(charactersIn: "x "))
                mediaSpeedMultiplier = Double(scalar) ?? mediaSpeedMultiplier
            case "total_size":
                guard let bytes = Int64(value) else { return }
                sampleSpeed(bytes: bytes)
            case "progress":
                if value == "end" {
                    progress = 1
                }
            default:
                break
            }
        }

        /// Direct-file progress (bytes on disk / Content-Length).
        func ingestDirect(written: Int64, total: Int64?) {
            guard state == .downloading else { return }
            totalBytesExpected = total
            sampleSpeed(bytes: written)
            if let total, total > 0 {
                progress = min(1, Double(written) / Double(total))
            }
        }

        private func sampleSpeed(bytes: Int64) {
            if bytes < bytesWritten {
                // The transfer restarted from zero (new mirror/range refused).
                lastSampleAt = nil
                lastSampleBytes = 0
                speedBytesPerSecond = 0
            }
            if bytes > bytesWritten {
                let now = Date()
                lastProgressAt = now
                if let lastAt = lastSampleAt,
                   let started = startedAt,
                   now.timeIntervalSince(lastAt) > 0.3,
                   started.distance(to: now) > 0.5 {
                    let instant = Double(bytes - lastSampleBytes) / now.timeIntervalSince(lastAt)
                    // Exponential moving average so a single burst sample
                    // doesn't whipsaw the label.
                    speedBytesPerSecond = speedBytesPerSecond == 0
                        ? instant
                        : speedBytesPerSecond * 0.7 + instant * 0.3
                    lastSampleAt = now
                    lastSampleBytes = bytes
                } else if lastSampleAt == nil {
                    lastSampleAt = now
                    lastSampleBytes = bytes
                }
            }
            bytesWritten = bytes
        }

        /// Clears live transfer metrics before a new attempt so a failover
        /// doesn't freeze the speed label at the previous mirror's bytes.
        func resetTransferMetrics() {
            progress = 0
            bytesWritten = 0
            totalBytesExpected = nil
            speedBytesPerSecond = 0
            mediaSpeedMultiplier = 0
            streamPositionSeconds = 0
            inputDurationSeconds = nil
            lastSampleAt = nil
            lastSampleBytes = 0
            lastProgressAt = nil
            stallDetected = false
        }

        /// Full reset for a user retry: fresh links, fresh mirror list.
        func resetForRetry() {
            resetTransferMetrics()
            orderedLinks = []
            orderedMirrorKeys = []
            subtitles = []
            linksResolvedAt = nil
            activeLinkIndex = 0
            failureReason = nil
            startedAt = nil
            statusDetail = nil
            triedMirrorKeys = []
            currentMirrorKey = nil
            retriedCurrentMirror = false
            useMatroska = false
            forceResolve = false
            lastFailure = nil
        }
    }
}
