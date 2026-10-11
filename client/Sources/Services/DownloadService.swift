import AppKit
import Foundation
import SwiftData
import UserNotifications

/// Just-In-Time download pipeline (Architecture.md §4.2, plan WS-3.6).
///
/// Queue items hold *provider coordinates*, not stream URLs. Links are
/// resolved through the daemon immediately before each attempt — and again
/// before every mirror failover or retry once they are older than
/// `linkFreshness` — so neither batch season downloads nor late failovers run
/// into 15–30 minute host token expiry (Invariant 8).
///
/// Execution model (one structured task per item run):
/// * `runs[itemID]` holds the run's task, a generation `token`, and the live
///   job. Every completion path checks its token, so a superseded run (cancel
///   → retry, quit) can never mutate the item's newer attempt.
/// * A cancelled run is *torn down* before the item may start again: the next
///   attempt never overlaps a still-exiting ffmpeg writing the same file.
/// * Failures carry a disposition (retry same mirror once / next mirror /
///   terminal), Android `DownloadStatus` parity: a full disk fails once
///   instead of burning through every mirror.
/// * Transfers write to `<base>.part` and are atomically renamed on success;
///   direct files resume with HTTP `Range`, HLS/DASH are remuxed by ffmpeg.
///
/// Every spawned ffmpeg process is registered with `DaemonSupervisor` so app
/// quit terminates downloads too (zero-orphan contract).
@MainActor
@Observable
final class DownloadService {
    static let shared = DownloadService()

    typealias FailureReason = DownloadPolicy.FailureReason

    nonisolated static let defaultUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    /// Links older than this are re-resolved before a new attempt.
    static let linkFreshness: TimeInterval = 120
    /// Refuse to start with less free space than this on the target volume.
    static let minimumFreeBytes: Int64 = 512 * 1_048_576

    private enum ActiveJob {
        case ffmpeg(FFmpegJob)
        case direct(DirectFileJob)

        func stop() {
            switch self {
            case .ffmpeg(let job): job.terminate()
            case .direct(let job): job.cancel()
            }
        }
    }

    private struct ActiveRun {
        let token: UUID
        let task: Task<Void, Never>
        var job: ActiveJob?
    }

    private enum AttemptResult {
        case completed(URL)
        case failed(FailureReason)
        /// Paused (direct), cancelled, superseded, or app quitting.
        case stopped
    }

    private enum ResolutionOutcome {
        case ready
        case failed(FailureReason)
        case stopped
    }

    /// Whether providers are available for link resolution. Injectable so
    /// tests can pin the engine state; production reads AppState.
    @ObservationIgnored
    var isEngineReady: () -> Bool = { AppState.shared.isEngineBootstrapped }
    /// Profile a newly queued download belongs to.
    @ObservationIgnored var originProfile: () -> UUID? = { ProfileStore.shared.activeID }
    /// Store name of an existing profile; nil when it was deleted.
    @ObservationIgnored var profileStoreName: (UUID) -> String? = { id in ProfileStore.shared.profiles.first { $0.id == id }?.storeName }
    /// Tests stop finalization at a boundary, as a crash there would.
    enum FinalizationBoundary: CaseIterable { case intentSaved, renamed, completionSaved }
    @ObservationIgnored var finalizationFault: ((FinalizationBoundary) -> Bool)?
    /// Test seam: an error the final rename fails with instead of running (audit M2).
    @ObservationIgnored var finalizationRenameFault: (() -> Error?)?
    @ObservationIgnored
    var engineFailure: () -> String? = {
        if case .error(let message) = AppState.shared.daemonState { return message }
        return nil
    }
    /// Production waits on connection changes. Fixtures that supply their own
    /// readiness closures can disable this and use the cancellable poll below.
    @ObservationIgnored
    var engineWait: (() async throws -> Void)? = { try await AppState.shared.waitForUsableEngine() }

    /// Link resolution (the daemon's `/links`). Injectable for end-to-end
    /// queue tests against a local HTTP server.
    @ObservationIgnored
    var linkResolver: (_ provider: String, _ data: String) async throws -> LinksResponseDto

    /// Engine relay registration for credentialed streams (audit A2).
    /// Injectable so queue tests can run against a real engine they launch.
    @ObservationIgnored
    var relayRegistrar: @Sendable ([MediaRelayResourceDto]) async throws -> DaemonClient.MediaRelaySession = {
        try await DaemonClient.shared.registerMediaRelay($0)
    }
    @ObservationIgnored
    var relayRevoker: @Sendable (String) async -> Void = { await DaemonClient.shared.revokeMediaRelay(sessionID: $0) }

    /// No progress for this long while downloading → the watchdog stops the
    /// attempt as stalled (ffmpeg's own `-rw_timeout` usually fires first).
    @ObservationIgnored
    var stallTimeout: TimeInterval = 120
    @ObservationIgnored
    var watchdogInterval: TimeInterval = 15

    private(set) var queue: [QueueItem] = []
    @ObservationIgnored private var runs: [UUID: ActiveRun] = [:]
    @ObservationIgnored private var teardowns: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var notificationPermissionRequested = false
    @ObservationIgnored private var powerActivity: NSObjectProtocol?
    @ObservationIgnored private var watchdogTask: Task<Void, Never>?
    @ObservationIgnored private var isTerminating = false
    /// True while the Mac has no network path: nothing new starts, and the
    /// transfers that were running are paused until the path returns.
    private(set) var isNetworkSuspended = false
    @ObservationIgnored private var networkPausedIDs: Set<UUID> = []

    /// Monotonic trigger bumped on additions, state transitions, and
    /// completions — refreshes download badges and storage usage.
    private(set) var activityTrigger: Int = 0

    @ObservationIgnored private var completedIndex: [String: DownloadRecord] = [:]
    @ObservationIgnored private var completedIndexVersion: UInt64?

    private init() {
        linkResolver = { provider, data in
            try await DaemonClient.shared.links(provider: provider, data: data)
        }
        do {
            try restorePersistedQueue()
            removeOrphanedPartials()
        } catch {
            _ = LibraryStore.shared.readForDisplay(or: false, { throw error })
        }
    }

    /// Tests: forget an item's in-memory state, as quitting would, so the
    /// next restore decides its fate from the durable record and the files.
    func discardInMemoryItem(id: UUID) {
        runs[id]?.task.cancel()
        runs[id] = nil
        queue.removeAll { $0.id == id }
    }

    func retryRestoringQueue() throws {
        try restorePersistedQueue()
        removeOrphanedPartials()
        drainQueue()
    }

    /// Deletes `.part` files left by transfers that no longer exist (crash,
    /// force-quit, record cleared on another profile). Only files carrying
    /// our `.part.json` resume sidecar are touched — other apps (Firefox)
    /// also use `.part` in shared folders like ~/Movies.
    private func removeOrphanedPartials() {
        guard let records: [DownloadRecord] = LibraryStore.shared.readForDisplay(or: nil, { try LibraryStore.shared.downloadRecords() }) else { return }
        let directories = Set([UserPreferences.shared.downloadDirectory] + records.map { $0.destinationURL.deletingLastPathComponent() })
        let live = Set(queue.map { $0.partURL.standardizedFileURL.path })
        Task.detached(priority: .utility) {
            let removed = Self.orphanedPartials(in: Array(directories), live: live)
            for url in removed {
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(at: DirectFileJob.metadataURL(forPart: url))
            }
            if !removed.isEmpty {
                DaemonLog.client("download.orphans_removed", fields: ["count": "\(removed.count)"])
            }
        }
    }

    /// `.part` files in `directories` (non-recursive) that have a valid
    /// resume sidecar and whose path is not in `live`.
    nonisolated static func orphanedPartials(in directories: [URL], live: Set<String>) -> [URL] {
        let manager = FileManager.default
        return directories.flatMap { directory -> [URL] in
            let contents = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            // A resume sidecar can outlive its part (a crash right after the
            // completed video was committed); it is swept with the same proof.
            let parts = Set(contents.filter { $0.pathExtension == "part" }
                + contents.filter { $0.pathExtension == "json" && $0.deletingPathExtension().pathExtension == "part" }
                    .map { $0.deletingPathExtension() })
            return parts.sorted { $0.path < $1.path }.filter { url in
                guard !live.contains(url.standardizedFileURL.path),
                      let data = try? Data(contentsOf: DirectFileJob.metadataURL(forPart: url)),
                      (try? JSONDecoder().decode(DirectFileJob.ResumeMetadata.self, from: data)) != nil else { return false }
                return true
            }
        }
    }

    // MARK: - Queries

    var activeCount: Int {
        queue.filter { $0.state == .downloading || $0.state == .resolving }.count
    }

    var totalActiveOrQueuedCount: Int {
        queue.filter { $0.state.isActive }.count
    }

    /// Transfers that quitting would interrupt (quit confirmation).
    var hasTransfersInFlight: Bool {
        queue.contains { $0.state == .downloading || $0.state == .resolving }
    }

    func queueItem(forProvider provider: String, episodeData: String) -> QueueItem? {
        if let active = queue.last(where: { $0.provider == provider && $0.episodeData == episodeData && $0.state.isActive }) {
            return active
        }
        return queue.last(where: { $0.provider == provider && $0.episodeData == episodeData })
    }

    /// Active (not finished) queue item for an episode, if any.
    func activeItem(forProvider provider: String, episodeData: String) -> QueueItem? {
        queue.last { $0.provider == provider && $0.episodeData == episodeData && $0.state.isActive }
    }

    /// Completed download whose file is still on disk. Backed by an index
    /// rebuilt once per store version — episode rows used to fetch every
    /// record on every render.
    func completedRecord(provider: String, episodeData: String) -> DownloadRecord? {
        let version = LibraryStore.shared.version
        if completedIndexVersion != version {
            var index: [String: DownloadRecord] = [:]
            // Newest first: the most recent completed copy wins.
            guard let records: [DownloadRecord] = LibraryStore.shared.readForDisplay(or: nil, { try LibraryStore.shared.downloadRecords() }) else { return nil }
            for record in records where record.status == .completed {
                let key = Self.key(provider: record.provider, episodeData: record.episodeData)
                if index[key] == nil { index[key] = record }
            }
            completedIndex = index
            completedIndexVersion = version
        }
        guard let record = completedIndex[Self.key(provider: provider, episodeData: episodeData)],
              record.existsOnDisk else { return nil }
        return record
    }

    private static func key(provider: String, episodeData: String) -> String {
        "\(provider)\u{0}\(episodeData)"
    }

    // MARK: - Filename safety (U-49)

    nonisolated static func sanitizedFileName(_ raw: String) -> String {
        DownloadPolicy.sanitizedFileName(raw)
    }

    /// First destination for `baseName` that collides neither with a file on
    /// disk (any video extension or an in-progress `.part`) nor with a path
    /// in `reserved` (base paths without extension).
    nonisolated static func uniqueDestination(
        directory: URL,
        baseName: String,
        reserved: Set<String> = [],
    ) -> URL {
        let base = sanitizedFileName(baseName)
        let fm = FileManager.default
        func isTaken(_ stem: URL) -> Bool {
            if reserved.contains(stem.standardizedFileURL.path) { return true }
            if fm.fileExists(atPath: stem.appendingPathExtension("part").path) { return true }
            return DownloadPolicy.videoExtensions.contains { fm.fileExists(atPath: stem.appendingPathExtension($0).path) }
        }
        var stem = directory.appendingPathComponent(base)
        var counter = 2
        while isTaken(stem) {
            stem = directory.appendingPathComponent("\(base) (\(counter))")
            counter += 1
        }
        return stem.appendingPathExtension("mp4")
    }

    /// Base paths currently claimed by queue items and completed records.
    private func reservedBasePaths(excluding itemID: UUID? = nil) throws -> Set<String> {
        var paths = Set<String>()
        for item in queue where item.id != itemID {
            paths.insert(item.baseURL.standardizedFileURL.path)
        }
        for record in try LibraryStore.shared.downloadRecords() where record.id != itemID && record.status == .completed {
            paths.insert(record.destinationURL.deletingPathExtension().standardizedFileURL.path)
        }
        return paths
    }

    // MARK: - Queueing

    /// Preferred entry point: the service picks a collision-free destination.
    @discardableResult
    func enqueue(_ request: Request, reportDuplicates: Bool = true) -> EnqueueResult {
        let reserved: Set<String>
        do { reserved = try reservedBasePaths() }
        catch { AppState.shared.presentError("Couldn’t read download records: \(error.localizedDescription)"); return .persistenceFailed }
        let destination = Self.uniqueDestination(directory: request.directory, baseName: request.baseName, reserved: reserved)
        return enqueue(
            title: request.title,
            episodeLabel: request.episodeLabel,
            provider: request.provider,
            providerID: request.providerID,
            episodeData: request.episodeData,
            resolvedDestination: destination,
            durationSeconds: request.durationSeconds,
            reportDuplicates: reportDuplicates,
            preferredSource: request.preferredSource,
        )
    }

    /// Queues many episodes (season download). Already-queued and
    /// already-downloaded episodes are skipped silently and summarized once.
    @discardableResult
    func enqueueBatch(_ requests: [Request]) -> (enqueued: Int, skipped: Int) {
        var enqueued = 0
        var skipped = 0
        for request in requests {
            if enqueue(request, reportDuplicates: false) == .enqueued {
                enqueued += 1
            } else {
                skipped += 1
            }
        }
        if enqueued == 0, skipped > 0 {
            AppState.shared.presentError(
                skipped == 1 ? "That episode is already downloaded or queued"
                    : "All \(skipped) episodes are already downloaded or queued",
            )
        }
        return (enqueued, skipped)
    }

    /// Compatibility entry point taking an explicit destination. A
    /// destination that collides with another item is moved to a free name.
    @discardableResult
    func enqueue(
        title: String,
        episodeLabel: String,
        provider: String,
        episodeData: String,
        destinationURL: URL,
        durationSeconds: Double? = nil,
    ) -> Bool {
        let reserved: Set<String>
        do { reserved = try reservedBasePaths() }
        catch { AppState.shared.presentError("Couldn’t read download records: \(error.localizedDescription)"); return false }
        let stem = destinationURL.deletingPathExtension()
        let destination: URL
        if reserved.contains(stem.standardizedFileURL.path)
            || DownloadPolicy.videoExtensions.contains(where: { FileManager.default.fileExists(atPath: stem.appendingPathExtension($0).path) }) {
            destination = Self.uniqueDestination(
                directory: destinationURL.deletingLastPathComponent(),
                baseName: stem.lastPathComponent,
                reserved: reserved,
            )
        } else {
            destination = destinationURL
        }
        return enqueue(
            title: title,
            episodeLabel: episodeLabel,
            provider: provider,
            episodeData: episodeData,
            resolvedDestination: destination,
            durationSeconds: durationSeconds,
            reportDuplicates: true,
        ) == .enqueued
    }

    private func enqueue(
        title: String,
        episodeLabel: String,
        provider: String,
        providerID: String? = nil,
        episodeData: String,
        resolvedDestination: URL,
        durationSeconds: Double?,
        reportDuplicates: Bool,
        preferredSource: DownloadPolicy.SourceChoice? = nil,
    ) -> EnqueueResult {
        // Identity is provider + data: meta-providers can share data strings.
        if activeItem(forProvider: provider, episodeData: episodeData) != nil {
            if reportDuplicates {
                AppState.shared.presentError("“\(episodeLabel)” is already in the download queue")
            }
            return .alreadyQueued
        }
        if completedRecord(provider: provider, episodeData: episodeData) != nil {
            if reportDuplicates {
                AppState.shared.presentError("“\(episodeLabel)” is already downloaded")
            }
            return .alreadyDownloaded
        }

        // Drop a stale finished entry for the same episode from the list;
        // its record goes too unless it's a completed download (which lives
        // on in Downloaded Titles).
        let stale = queue.filter {
            $0.provider == provider && $0.episodeData == episodeData && $0.state.isFinished
        }
        for item in stale {
            if item.state != .completed {
                guard LibraryStore.shared.perform({ try LibraryStore.shared.deleteDownloadRecord(id: item.id) }) else { return .persistenceFailed }
                discardPartialFiles(for: item)
            }
            queue.removeAll { $0.id == item.id }
        }

        let item = QueueItem(
            title: title,
            episodeLabel: episodeLabel,
            provider: provider,
            episodeData: episodeData,
            destinationURL: resolvedDestination,
            durationSeconds: durationSeconds,
            providerID: providerID,
            preferredSource: preferredSource,
            originProfileID: originProfile(),
        )
        queue.append(item)
        activityTrigger += 1
        guard upsertRecord(for: item) else { return .persistenceFailed }
        requestNotificationPermissionIfNeeded()
        drainQueue()
        return .enqueued
    }

    // MARK: - Transport controls

    /// ffmpeg remuxes are frozen with SIGSTOP (keeps the stream position for
    /// short pauses); direct files stop and later resume with HTTP Range.
    /// Either way a paused item frees its concurrency slot.
    func pause(_ item: QueueItem) {
        if item.state == .paused {
            // A user pause of a network-held or resume-pending item sticks.
            guard item.resumeRequested || networkPausedIDs.contains(item.id) else { return }
            item.resumeRequested = false
            networkPausedIDs.remove(item.id)
            item.statusDetail = nil
            activityTrigger += 1
            return
        }
        guard item.state == .downloading, let run = runs[item.id], let job = run.job else { return }
        switch job {
        case .ffmpeg(let ffmpeg):
            guard ffmpeg.suspend() else { return }
            item.state = .paused
        case .direct(let direct):
            item.state = .paused
            direct.cancel()
        }
        item.resumeRequested = false
        item.speedBytesPerSecond = 0
        activityTrigger += 1
        upsertRecord(for: item)
        updatePowerAssertion()
        drainQueue()
    }

    /// Every way back into an active transfer passes admission: a frozen
    /// ffmpeg process stays stopped until `drainQueue` grants it a slot and
    /// the network is available; anything else re-queues.
    func resume(_ item: QueueItem) {
        guard item.state == .paused else { return }
        if let run = runs[item.id], case .ffmpeg? = run.job {
            item.resumeRequested = true
            item.statusDetail = isNetworkSuspended ? "Waiting for network" : "Waiting for a free slot"
        } else {
            // Direct file (resumes from its .part) or restored after relaunch.
            item.state = .queued
            item.statusDetail = isNetworkSuspended ? "Waiting for network" : nil
            upsertRecord(for: item)
        }
        activityTrigger += 1
        updatePowerAssertion()
        drainQueue()
    }

    // MARK: - Connectivity (Offline-Features-Plan Phase 3)

    /// Network path lost: pause every running transfer (direct files keep
    /// their `.part` for a Range resume) and hold the queue. Items the user
    /// paused themselves are not touched and stay paused on reconnect.
    func suspendForNetworkLoss() {
        guard !isNetworkSuspended else { return }
        isNetworkSuspended = true
        let running = queue.filter { $0.state == .downloading }
        for item in running {
            pause(item)
            if item.state == .paused {
                item.statusDetail = "Waiting for network"
                networkPausedIDs.insert(item.id)
            }
        }
        activityTrigger += 1
        DaemonLog.client("downloads.network_suspended", fields: ["paused": String(networkPausedIDs.count)])
    }

    /// Network path back: resume what connectivity loss paused, then drain.
    func resumeAfterNetworkReturn() {
        guard isNetworkSuspended else { return }
        isNetworkSuspended = false
        let ids = networkPausedIDs
        networkPausedIDs.removeAll()
        for item in queue where ids.contains(item.id) && item.state == .paused {
            item.statusDetail = nil
            resume(item)
        }
        for item in queue where item.statusDetail == "Waiting for network" { item.statusDetail = nil }
        activityTrigger += 1
        drainQueue()
        DaemonLog.client("downloads.network_resumed", fields: ["resumed": String(ids.count)])
    }

    /// Cancels an *active* item. Finished items are never touched — a
    /// completed download must not lose its file to a bulk cancel.
    func cancel(_ item: QueueItem) {
        guard item.state.isActive else { return }
        item.state = .cancelled
        item.statusDetail = nil
        item.speedBytesPerSecond = 0
        activityTrigger += 1
        upsertRecord(for: item)
        stopRun(for: item, discardPartial: true)
        updatePowerAssertion()
        drainQueue()
    }

    func cancelAll() {
        // Snapshot first: cancelling drains the queue, and draining must not
        // start items we are about to cancel.
        let targets = queue.filter { $0.state.isActive }
        for item in targets {
            item.state = .cancelled
            item.statusDetail = nil
            upsertRecord(for: item)
        }
        for item in targets {
            stopRun(for: item, discardPartial: true)
        }
        activityTrigger += 1
        updatePowerAssertion()
        drainQueue()
    }

    /// "Download Next": moves a waiting item ahead of every other waiting
    /// item (Android queue reordering). Persisted via its queue timestamp.
    func moveToFront(_ item: QueueItem) {
        guard item.state == .queued, let index = queue.firstIndex(where: { $0.id == item.id }) else { return }
        let waiting = queue.filter { $0.state == .queued && $0.id != item.id }
        if let earliest = waiting.map(\.createdAt).min(), earliest <= item.createdAt {
            item.createdAt = earliest.addingTimeInterval(-1)
        }
        queue.remove(at: index)
        let insertAt = queue.firstIndex { $0.state == .queued } ?? queue.count
        queue.insert(item, at: insertAt)
        activityTrigger += 1
        upsertRecord(for: item)
    }

    func retry(_ item: QueueItem) {
        guard item.state == .failed || item.state == .cancelled else { return }
        // A finished transfer whose rename failed: retry the rename, never the
        // download (a re-download would delete the finished part first).
        if case .finalizeFailed = item.failureReason {
            reconcileFinalizing(item)
            return
        }
        // Its destination may have been taken while it sat failed.
        let reserved: Set<String>
        do { reserved = try reservedBasePaths(excluding: item.id) }
        catch { AppState.shared.presentError("Couldn’t read download records: \(error.localizedDescription)"); return }
        let stem = item.baseURL
        if reserved.contains(stem.standardizedFileURL.path)
            || DownloadPolicy.videoExtensions.contains(where: { FileManager.default.fileExists(atPath: stem.appendingPathExtension($0).path) }) {
            item.destinationURL = Self.uniqueDestination(
                directory: stem.deletingLastPathComponent(),
                baseName: stem.lastPathComponent,
                reserved: reserved,
            )
        }
        item.resetForRetry()
        item.state = .queued
        activityTrigger += 1
        upsertRecord(for: item)
        drainQueue()
    }

    /// Removes an item from the Active Queue list. For a completed item this
    /// only hides the row — the file and its Downloaded Titles entry stay.
    func removeFromQueue(_ item: QueueItem) {
        if item.state.isActive {
            cancel(item)
        }
        if item.state != .completed {
            guard LibraryStore.shared.perform({ try LibraryStore.shared.deleteDownloadRecord(id: item.id) }) else { return }
            if teardowns[item.id] == nil { discardPartialFiles(for: item) }
        }
        queue.removeAll { $0.id == item.id }
        activityTrigger += 1
        drainQueue()
    }

    enum DeletionResult: Equatable {
        /// File and records removed; sidecars that could not be removed are named.
        case deleted(sidecarFailures: [String])
        /// An active transfer is still producing this file.
        case busy
        /// The file is not there, but its folder is: nothing was changed.
        /// `forgetMissingDownload` removes the record if the user wants that.
        case fileMissing
        /// The volume is not mounted: the file may still exist.
        case volumeUnavailable
        /// Nothing was removed, or the records could not be updated afterwards.
        case failed(String)

        var message: String? {
            switch self {
            case .deleted(let failures):
                return failures.isEmpty ? nil : "The video was deleted, but these subtitle files could not be removed: \(failures.joined(separator: ", "))"
            case .busy: return "This download is still in progress. Cancel it first."
            case .fileMissing: return "The downloaded file is no longer at its saved location. You can remove it from the list instead."
            case .volumeUnavailable: return "The disk that holds this download is not connected. Connect it and try again."
            case .failed(let detail): return "Couldn’t delete the download: \(detail)"
            }
        }
    }

    enum FileAvailability: Equatable { case present, missing, volumeUnavailable }

    /// An unplugged volume is "unavailable", never "definitely absent".
    nonisolated static func availability(of url: URL) -> FileAvailability {
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) { return .present }
        let components = url.standardizedFileURL.pathComponents
        if components.count > 2, components[1] == "Volumes",
           !manager.fileExists(atPath: "/Volumes/" + components[2]) { return .volumeUnavailable }
        return .missing
    }

    /// Deletes a completed download: file, subtitle sidecars, library entry,
    /// and record. The record goes only after the video is really gone.
    @discardableResult
    func deleteCompleted(recordID: UUID, provider: String, destinationURL: URL) -> DeletionResult {
        let result = performDeletion(recordID: recordID, provider: provider, destinationURL: destinationURL)
        if let message = result.message { AppState.shared.presentError(message) }
        return result
    }

    private func performDeletion(recordID: UUID, provider: String, destinationURL: URL) -> DeletionResult {
        if let item = queue.first(where: { $0.id == recordID }), item.state.isActive {
            return .busy // never delete a file an active transfer is producing
        }
        switch Self.availability(of: destinationURL) {
        case .volumeUnavailable: return .volumeUnavailable
        case .missing: return .fileMissing
        case .present: break
        }
        // 1. Durable intent first; without it nothing is touched.
        do { try LibraryStore.shared.setDownloadDeletionIntent(id: recordID, at: Date()) }
        catch { return .failed(error.localizedDescription) }
        // 2. The video. On failure the download is still intact: withdraw the intent.
        do { try FileManager.default.removeItem(at: destinationURL) }
        catch {
            try? LibraryStore.shared.setDownloadDeletionIntent(id: recordID, at: nil)
            return .failed(error.localizedDescription)
        }
        // 3. Sidecars, reported individually.
        var sidecarFailures: [String] = []
        for sidecar in Self.sidecarSubtitleFiles(for: destinationURL) {
            do { try FileManager.default.removeItem(at: sidecar) }
            catch { sidecarFailures.append(sidecar.lastPathComponent) }
        }
        // 4. Records. If this fails the saved intent finishes the job at the
        // next launch; the file is already gone, so the record is not kept as
        // a playable download.
        do { try removeRecords(recordID: recordID, provider: provider, path: destinationURL.path) }
        catch { return .failed("The video was deleted, but its entry could not be removed yet (\(error.localizedDescription)). It will be removed the next time CloudStream starts.") }
        return .deleted(sidecarFailures: sidecarFailures)
    }

    private func removeRecords(recordID: UUID, provider: String, path: String) throws {
        let origin = try LibraryStore.shared.downloadRecord(id: recordID)?.originProfileID
        try LibraryStore.shared.removeDownloadedEntry(downloadID: recordID, provider: provider, url: path)
        if let origin, let store = profileStoreName(origin) {
            try LibraryStore.shared.removeDownloadedEntry(downloadID: recordID, inProfileStore: store)
        }
        try LibraryStore.shared.deleteDownloadRecord(id: recordID)
        queue.removeAll { $0.id == recordID }
        activityTrigger += 1
    }

    /// Explicit "remove from the list" for a download whose file is already
    /// gone. Refuses while the file exists or its volume is merely unplugged.
    @discardableResult
    func forgetMissingDownload(recordID: UUID, provider: String, destinationURL: URL) -> DeletionResult {
        guard Self.availability(of: destinationURL) == .missing else {
            let result: DeletionResult = Self.availability(of: destinationURL) == .volumeUnavailable ? .volumeUnavailable
                : .failed("The file still exists. Delete it instead.")
            if let message = result.message { AppState.shared.presentError(message) }
            return result
        }
        do { try removeRecords(recordID: recordID, provider: provider, path: destinationURL.path) }
        catch {
            AppState.shared.presentError("Couldn’t remove the download from the list: \(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }
        return .deleted(sidecarFailures: [])
    }

    /// Finishes or withdraws deletions interrupted after their intent was saved.
    private func reconcileDeletionIntents(_ records: [DownloadRecord]) {
        for record in records where record.deletionRequestedAt != nil {
            let (id, provider, url) = (record.id, record.provider, record.destinationURL)
            switch Self.availability(of: url) {
            case .missing:
                // The video was removed; only the records were left behind.
                for sidecar in Self.sidecarSubtitleFiles(for: url) { try? FileManager.default.removeItem(at: sidecar) }
                try? removeRecords(recordID: id, provider: provider, path: url.path)
                DaemonLog.client("download.deletion_reconciled", fields: ["item": id.uuidString, "outcome": "removed"])
            case .present:
                // Interrupted before the file was touched: the download stays.
                try? LibraryStore.shared.setDownloadDeletionIntent(id: id, at: nil)
                DaemonLog.client("download.deletion_reconciled", fields: ["item": id.uuidString, "outcome": "kept"])
            case .volumeUnavailable:
                continue // decide when the volume is back
            }
        }
    }

    func deleteCompleted(_ item: QueueItem) {
        deleteCompleted(recordID: item.id, provider: item.provider, destinationURL: item.destinationURL)
    }

    func clearFinished() {
        let finished = queue.filter { $0.state.isFinished }
        let nonCompleted = finished.filter { $0.state != .completed }
        guard LibraryStore.shared.perform({ try LibraryStore.shared.deleteDownloadRecords(ids: nonCompleted.map(\.id)) }) else { return }
        for item in nonCompleted where teardowns[item.id] == nil {
            discardPartialFiles(for: item)
        }
        queue.removeAll { $0.state.isFinished }
        activityTrigger += 1
        drainQueue()
    }

    /// App quit: stop every transfer *without* changing persisted states, so
    /// the next launch restores them (direct files resume from `.part`).
    func prepareForTermination() {
        isTerminating = true
        for run in runs.values {
            run.job?.stop()
            run.task.cancel()
        }
        watchdogTask?.cancel()
        endPowerAssertion()
    }

    private func stopRun(for item: QueueItem, discardPartial: Bool) {
        guard let run = runs.removeValue(forKey: item.id) else {
            if discardPartial, teardowns[item.id] == nil { discardPartialFiles(for: item) }
            return
        }
        run.job?.stop()
        run.task.cancel()
        let itemID = item.id
        // The next attempt of this item waits until the old job has fully
        // exited, and only then are its partial files removed.
        teardowns[itemID] = Task { @MainActor [weak self] in
            await run.task.value
            guard let self else { return }
            self.teardowns[itemID] = nil
            // Skip if the user already retried: the new attempt owns the path.
            let stillListed = self.queue.contains { $0.id == itemID }
            if discardPartial, item.state == .cancelled || !stillListed {
                self.discardPartialFiles(for: item)
            }
            self.drainQueue()
        }
    }

    private func discardPartialFiles(for item: QueueItem) {
        try? FileManager.default.removeItem(at: item.partURL)
        try? FileManager.default.removeItem(at: DirectFileJob.metadataURL(forPart: item.partURL))
    }

    // MARK: - Persistence

    static func persistedStatus(for item: QueueItem) -> ItemState {
        if item.state == .failed, case .finalizeFailed = item.failureReason { return .finalizing }
        return item.state
    }

    @discardableResult
    private func upsertRecord(for item: QueueItem) -> Bool {
        do {
            try LibraryStore.shared.upsertDownloadRecord(
                id: item.id,
                title: item.title,
                episodeLabel: item.episodeLabel,
                provider: item.provider,
                episodeData: item.episodeData,
                destinationPath: item.destinationURL.path,
                // Deliberate mismatch: a failed rename shows as failed, but is
                // stored as `finalizing` so the next launch (or Retry) goes
                // through reconcileFinalizing and retries it; the finished
                // part is never downloaded again. Older builds also reconcile
                // `finalizing`, so no new persisted status exists (audit M2).
                statusRaw: Self.persistedStatus(for: item).rawValue,
                bytesWritten: item.bytesWritten,
                durationSeconds: item.durationSeconds,
                failureReason: item.failureReason?.label,
                completedAt: item.state == .completed ? Date() : nil,
                createdAt: item.createdAt,
                providerID: item.providerID,
                preferredSource: item.preferredSource?.storage,
                originProfileID: item.originProfileID,
            )
            return true
        } catch {
            item.state = .failed
            item.failureReason = .unknown("Couldn’t save download state: \(error.localizedDescription)")
            AppState.shared.presentError(item.failureReason?.label ?? "Couldn’t save download state.")
            stopRun(for: item, discardPartial: false)
            return false
        }
    }

    /// Restores the queue after a restart, oldest first. Unfinished items
    /// re-queue (JIT resolution makes them safe to retry; direct files resume
    /// from their `.part`), paused items stay paused, and failed/cancelled
    /// items come back visible so they can be retried or cleared instead of
    /// lingering invisibly in the store.
    private func restorePersistedQueue() throws {
        let savedRecords = try LibraryStore.shared.downloadRecords()
        reconcileDeletionIntents(savedRecords)
        let records = savedRecords.filter { $0.status != .completed }
            .sorted { $0.createdAt < $1.createdAt }
        let knownIDs = Set(queue.map(\.id))
        for record in records where !knownIDs.contains(record.id) {
            let item = QueueItem(
                id: record.id,
                title: record.title,
                episodeLabel: record.episodeLabel,
                provider: record.provider,
                episodeData: record.episodeData,
                destinationURL: record.destinationURL,
                durationSeconds: record.durationSeconds,
                createdAt: record.createdAt,
                providerID: record.providerID,
                preferredSource: DownloadPolicy.SourceChoice(storage: record.preferredSource),
                originProfileID: record.originProfileID,
            )
            item.bytesWritten = record.bytesWritten
            switch record.status {
            case .finalizing:
                reconcileFinalizing(item)
            case .paused:
                item.state = .paused
                item.statusDetail = "Paused"
            case .failed:
                item.state = .failed
                item.failureReason = .unknown(record.failureReason ?? "Download failed")
            case .cancelled:
                item.state = .cancelled
            default:
                item.state = .queued
            }
            queue.append(item)
        }
        if queue.contains(where: { $0.state == .queued }) {
            drainQueue()
        }
    }

    // MARK: - Queue processing (bounded concurrency)

    /// Starts as many queued items as the global and per-provider budgets
    /// allow. An item never starts while a previous run of it is still
    /// alive or tearing down.
    func drainQueue() {
        guard !isTerminating, !isNetworkSuspended else { return }
        let preferences = UserPreferences.shared
        let maxConcurrent = max(1, preferences.maxConcurrentDownloads)
        let maxPerProvider = max(1, preferences.maxDownloadsPerProvider)

        var busyByProvider: [String: Int] = [:]
        var busyTotal = 0
        for item in queue where runs[item.id] != nil && (item.state == .resolving || item.state == .downloading) {
            busyTotal += 1
            busyByProvider[item.provider, default: 0] += 1
        }

        // Frozen transfers asking to continue take free slots first; they
        // were admitted before anything still waiting in the queue.
        for item in queue where item.state == .paused && item.resumeRequested {
            guard busyTotal < maxConcurrent else { break }
            guard busyByProvider[item.provider, default: 0] < maxPerProvider else { continue }
            item.resumeRequested = false
            if let run = runs[item.id], case .ffmpeg(let ffmpeg)? = run.job, ffmpeg.resume() {
                item.state = .downloading
                item.statusDetail = nil
                item.lastSampleAt = nil
                item.lastSampleBytes = 0
                item.lastProgressAt = Date()
                busyTotal += 1
                busyByProvider[item.provider, default: 0] += 1
            } else {
                // The process is gone: start over through the ordinary queue.
                stopRun(for: item, discardPartial: false)
                item.state = .queued
                item.statusDetail = nil
            }
            activityTrigger += 1
            upsertRecord(for: item)
        }

        for item in queue where item.state == .queued {
            guard busyTotal < maxConcurrent else { break }
            guard runs[item.id] == nil, teardowns[item.id] == nil else { continue }
            guard busyByProvider[item.provider, default: 0] < maxPerProvider else { continue }

            busyTotal += 1
            busyByProvider[item.provider, default: 0] += 1
            item.state = .resolving
            item.statusDetail = nil
            activityTrigger += 1
            guard upsertRecord(for: item) else { continue }

            let token = UUID()
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.runItem(item, token: token)
            }
            runs[item.id] = ActiveRun(token: token, task: task, job: nil)
        }
        updatePowerAssertion()
        ensureWatchdog()
    }

    private func isCurrent(_ item: QueueItem, _ token: UUID) -> Bool {
        !isTerminating && !Task.isCancelled && runs[item.id]?.token == token
    }

    /// One item's lifecycle: resolve → pick mirror → attempt → classify →
    /// retry/failover/finish, re-resolving stale links before each attempt.
    private func runItem(_ item: QueueItem, token: UUID) async {
        defer {
            if runs[item.id]?.token == token {
                runs[item.id] = nil
            }
            updatePowerAssertion()
            drainQueue()
        }

        while isCurrent(item, token), item.state == .resolving || item.state == .downloading {
            // 1. Fresh links (JIT) — first attempt, retries, and failovers.
            let stale = item.linksResolvedAt.map { Date().timeIntervalSince($0) > Self.linkFreshness } ?? true
            if item.orderedLinks.isEmpty || stale || item.forceResolve {
                item.state = .resolving
                switch await resolveLinks(for: item, token: token) {
                case .ready: break
                case .stopped: return
                case .failed(let reason):
                    fail(item, reason)
                    return
                }
            }
            guard isCurrent(item, token) else { return }
            // The network went away while links were resolving: do not start
            // IO. The item waits in the queue until the path returns.
            if isNetworkSuspended {
                item.state = .queued
                item.statusDetail = "Waiting for network"
                activityTrigger += 1
                upsertRecord(for: item)
                return
            }

            // 2. Choose the mirror: the current one when retrying it,
            //    otherwise the first not yet given up on.
            guard let (link, mirrorKey) = selectMirror(for: item) else {
                fail(item, item.lastFailure ?? .unknown("all mirrors exhausted"))
                return
            }
            if mirrorKey != item.currentMirrorKey {
                item.retriedCurrentMirror = false
                item.useMatroska = false
            }
            item.currentMirrorKey = mirrorKey
            if let choice = item.preferredSource, choice.matchRank(link) == nil {
                item.fallbackSourceName = link.name.isEmpty ? link.source : link.name
            } else {
                item.fallbackSourceName = nil
            }

            // 3. Destination checks: local problems are terminal.
            if let failure = preflightDestination(for: item) {
                fail(item, failure)
                return
            }

            // 4. Attempt.
            item.resetTransferMetrics()
            item.state = .downloading
            item.statusDetail = nil
            item.startedAt = Date()
            item.lastProgressAt = Date()
            activityTrigger += 1
            guard upsertRecord(for: item) else { return }

            let result = await attempt(item, link: link, mirrorKey: mirrorKey, token: token)
            guard isCurrent(item, token), item.state == .downloading else { return }

            switch result {
            case .stopped:
                return
            case .completed(let partURL):
                await finalize(item, partURL: partURL, token: token)
                return
            case .failed(let reason):
                item.lastFailure = reason
                DaemonLog.client("download.attempt_failed", fields: [
                    "item": item.id.uuidString,
                    "mirror": "\(item.activeLinkIndex + 1)",
                    "reason": reason.label,
                ])
                switch reason.disposition {
                case .terminal:
                    fail(item, reason)
                    return
                case .retrySameMirror where reason == .incompatibleContainer && !item.useMatroska:
                    // Stream codecs MP4 can't hold (DTS, TrueHD, PGS…): same
                    // mirror, Matroska output. Doesn't consume the retry.
                    item.useMatroska = true
                    item.statusDetail = "Retrying as MKV…"
                case .retrySameMirror where !item.retriedCurrentMirror:
                    item.retriedCurrentMirror = true
                    item.forceResolve = true
                    item.statusDetail = "Retrying…"
                case .retrySameMirror, .nextMirror:
                    item.triedMirrorKeys.insert(mirrorKey)
                    item.activeLinkIndex += 1
                    item.retriedCurrentMirror = false
                    item.useMatroska = false
                    item.forceResolve = true
                    item.statusDetail = "Trying next mirror…"
                }
                item.state = .resolving
                guard upsertRecord(for: item) else { return }
            }
        }
    }

    // MARK: - Link resolution

    /// The sources a download of this episode can use, in automatic order
    /// (for the "Download from…" picker).
    func availableSources(provider: String, providerID: String?, episodeData: String) async throws -> [StreamLinkDto] {
        let response = try await linkResolver(providerID ?? provider, episodeData)
        return DownloadPolicy.orderedCandidates(
            response.links,
            preferredQuality: UserPreferences.shared.preferredQuality,
            sources: UserPreferences.shared.sourcePreferences,
        )
    }

    enum ResolutionError: Equatable {
        case transient(String)
        /// The engine's own sentence saying why (turned off, failed to start, ambiguous…), when it gave one.
        case providerMissing(String?)
        case fatal(String)
        case cancelled
    }

    private func resolveLinks(for item: QueueItem, token: UUID) async -> ResolutionOutcome {
        // Never fail a download because the engine is still booting (restored
        // queue at launch) or restarting: wait for it instead.
        if !isEngineReady() {
            item.statusDetail = "Waiting for streaming engine…"
            if let outcome = await awaitEngine(for: item, token: token) { return outcome }
        }
        item.statusDetail = "Resolving links…"

        var lastError = ""
        let backoff: [UInt64] = [2, 4, 8, 16]
        for attempt in 0...backoff.count {
            guard isCurrent(item, token) else { return .stopped }
            do {
                let response = try await linkResolver(item.providerID ?? item.provider, item.episodeData)
                guard isCurrent(item, token) else { return .stopped }
                let ordered = DownloadPolicy.orderedCandidates(
                    response.links,
                    preferredQuality: UserPreferences.shared.preferredQuality,
                    sources: UserPreferences.shared.sourcePreferences,
                    choice: item.preferredSource,
                )
                if ordered.isEmpty {
                    // Keep previously resolved mirrors if a re-resolve comes
                    // back empty (transient scrape failure).
                    if item.orderedLinks.isEmpty { return .failed(.noLinks) }
                } else {
                    item.orderedLinks = ordered
                    item.orderedMirrorKeys = DownloadPolicy.mirrorKeys(for: ordered)
                    item.subtitles = response.subtitles
                    item.linksResolvedAt = Date()
                }
                item.forceResolve = false
                item.statusDetail = nil
                return .ready
            } catch {
                switch Self.classifyResolutionError(error) {
                case .cancelled:
                    return .stopped
                case .providerMissing(let reason):
                    return .failed(.providerUnavailable(provider: item.provider, reason: reason))
                case .fatal(let detail):
                    if !item.orderedLinks.isEmpty { item.forceResolve = false; return .ready }
                    return .failed(.linkResolution(detail))
                case .transient(let detail):
                    lastError = detail
                    guard attempt < backoff.count else { break }
                    item.statusDetail = "Engine busy — retrying…"
                    do {
                        try await Task.sleep(for: .seconds(backoff[attempt]))
                    } catch {
                        return .stopped
                    }
                    // A restart mid-backoff: wait for readiness again.
                    if let outcome = await awaitEngine(for: item, token: token) { return outcome }
                }
            }
        }
        // Out of retries: fall back to the last known mirrors if we have any.
        if !item.orderedLinks.isEmpty {
            item.forceResolve = false
            return .ready
        }
        return .failed(.linkResolution(lastError))
    }

    private func awaitEngine(for item: QueueItem, token: UUID) async -> ResolutionOutcome? {
        do {
            if !isEngineReady(), let engineWait { try await engineWait() }
            while !isEngineReady() {
                if let failure = engineFailure() { return .failed(.linkResolution(failure)) }
                try await Task.sleep(for: .milliseconds(500))
                guard isCurrent(item, token) else { return .stopped }
            }
            return isCurrent(item, token) ? nil : .stopped
        } catch is CancellationError { return .stopped }
        catch { return .failed(.linkResolution(error.localizedDescription)) }
    }

    static func classifyResolutionError(_ error: Error) -> ResolutionError {
        if error is CancellationError { return .cancelled }
        if let urlError = error as? URLError {
            return urlError.code == .cancelled ? .cancelled : .transient(urlError.localizedDescription)
        }
        if let daemonError = error as? DaemonClient.DaemonError {
            switch daemonError {
            case .notReady:
                return .transient("engine not ready")
            case .operationFailure(let failure):
                // The engine's own retryable flag decides (capacity, timeout,
                // worker exit, network); the message is presentation only.
                return failure.retryable ? .transient(failure.publicMessage) : .fatal(failure.publicMessage)
            case .http(let status, let detail):
                if status == 422 || status == 400 { return .providerMissing(detail) }
                if status == 408 || status == 429 || status >= 500 {
                    return .transient("HTTP \(status)")
                }
                return .fatal(detail ?? "HTTP \(status)")
            default:
                return .fatal(daemonError.localizedDescription)
            }
        }
        return .fatal(error.localizedDescription)
    }

    private func selectMirror(for item: QueueItem) -> (StreamLinkDto, String)? {
        let pairs = zip(item.orderedLinks, item.orderedMirrorKeys)
        if item.retriedCurrentMirror || item.useMatroska,
           let current = item.currentMirrorKey,
           !item.triedMirrorKeys.contains(current),
           let match = pairs.first(where: { $0.1 == current }) {
            return match
        }
        return pairs.first { !item.triedMirrorKeys.contains($0.1) }
    }

    // MARK: - Destination preflight

    private func preflightDestination(for item: QueueItem) -> FailureReason? {
        let directory = item.destinationURL.deletingLastPathComponent()
        let fm = FileManager.default

        // An unplugged external drive: /Volumes/<name> is gone. Don't create
        // anything — report it.
        let components = directory.standardizedFileURL.pathComponents
        if components.count >= 3, components[1] == "Volumes" {
            let volumeRoot = "/Volumes/\(components[2])"
            var isDirectory: ObjCBool = false
            if !fm.fileExists(atPath: volumeRoot, isDirectory: &isDirectory) || !isDirectory.boolValue {
                return .destinationUnavailable("drive “\(components[2])” is not connected")
            }
        }

        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return DirectFileJob.fileSystemFailure(error)
        }
        guard fm.isWritableFile(atPath: directory.path) else {
            return .permissionDenied
        }
        if let capacity = DownloadPolicy.volumeCapacity(for: directory),
           capacity.free < Self.minimumFreeBytes {
            return .diskFull
        }
        return nil
    }

    // MARK: - Attempt

    private func attempt(_ item: QueueItem, link: StreamLinkDto, mirrorKey: String, token: UUID) async -> AttemptResult {
        let verifierID = await startVerifierIfNeeded(for: link)
        defer {
            if let verifierID {
                Task { await DaemonClient.shared.stopExtractorVerifier(jobId: verifierID) }
            }
        }

        if DownloadPolicy.isDirectFile(link) {
            let direct = await attemptDirect(item, link: link, mirrorKey: mirrorKey, token: token)
            switch direct {
            case .notDirect:
                // The "direct" link served an HLS playlist: remux it instead.
                guard isCurrent(item, token), item.state == .downloading else { return .stopped }
                return await attemptFFmpeg(item, link: link, token: token)
            case .result(let result):
                return result
            }
        }
        return await attemptFFmpeg(item, link: link, token: token)
    }

    private enum DirectAttempt {
        case result(AttemptResult)
        case notDirect
    }

    private func attemptDirect(_ item: QueueItem, link: StreamLinkDto, mirrorKey: String, token: UUID) async -> DirectAttempt {
        guard let url = URL(string: link.url) else { return .result(.failed(.protocolUnsupported)) }
        let headers: [(name: String, value: String)]
        do {
            try MediaResourcePolicy.validate(link)
            headers = try DownloadPolicy.sanitizedHeaders(link.headers)
        } catch { return .result(.failed(.invalidMedia)) }
        let itemID = item.id
        let job = DirectFileJob(
            url: url,
            headers: headers,
            partURL: item.partURL,
            mirrorKey: mirrorKey,
        ) { written, total in
            Task { @MainActor in
                DownloadService.shared.applyDirectProgress(written: written, total: total, itemID: itemID, token: token)
            }
        }
        runs[item.id]?.job = .direct(job)
        let outcome = await job.run()
        if runs[item.id]?.token == token { runs[item.id]?.job = nil }

        switch outcome {
        case .completed(let bytes, let mimeType):
            let ext = DownloadPolicy.directFileExtension(url: url, mimeType: mimeType)
            item.destinationURL = item.baseURL.appendingPathExtension(ext)
            item.bytesWritten = bytes
            return .result(.completed(item.partURL))
        case .failed(let reason):
            if item.stallDetected { return .result(.failed(.stalled)) }
            return .result(.failed(reason))
        case .notDirect:
            return .notDirect
        case .cancelled:
            // Pause, cancel, or quit — or the watchdog stopping a stall.
            if item.stallDetected, isCurrent(item, token), item.state == .downloading {
                return .result(.failed(.stalled))
            }
            if isCurrent(item, token), item.state == .downloading {
                return .result(.failed(.network("transfer interrupted")))
            }
            return .result(.stopped)
        }
    }

    private func attemptFFmpeg(_ item: QueueItem, link: StreamLinkDto, token: UUID) async -> AttemptResult {
        guard let ffmpegPath = Self.ffmpegBinaryPath() else {
            return .failed(.unknown("bundled ffmpeg missing"))
        }
        let partURL = item.partURL
        let format = item.useMatroska ? "matroska" : "mp4"
        try? FileManager.default.removeItem(at: partURL)
        try? FileManager.default.removeItem(at: DirectFileJob.metadataURL(forPart: partURL))

        // Input kinds come from the original addresses: a relay URL has no extension.
        let hlsInputs = [DownloadPolicy.isHLS(url: link.url, type: link.type)]
            + link.audioTracks.map { DownloadPolicy.isHLS(url: $0.url, type: nil) }
        var activeLink = link
        var relaySessionID: String? = nil
        // Credentials never travel in ffmpeg's argv, where any same-user process
        // (an extension worker included) could read them: such a stream,
        // playlist or manifest included, is read through the engine relay,
        // which adds each resource's headers itself (audit A2, security M2).
        if Self.needsRelay(link) {
            let resources = MediaResourcePolicy.relayResources(video: link.url, headers: link.headers, orderedAudio: link.audioTracks)
            let revoke = relayRevoker
            guard let session = await registerRelayShielded(resources) else {
                return .failed(.relayUnavailable) // Fail closed: never fall back to argv headers.
            }
            guard session.urls.count == resources.count, let primary = session.urls.first else {
                await revoke(session.sessionID)
                return .failed(.relayUnavailable)
            }
            // A pause or cancel during registration revokes the session instead of leaking it (audit M6b).
            guard isCurrent(item, token), item.state == .downloading, !Task.isCancelled else {
                await revoke(session.sessionID)
                return .stopped
            }
            relaySessionID = session.sessionID
            let relayedAudio = link.audioTracks.enumerated().map { index, track in
                AudioTrackDto(url: session.urls[index + 1], label: track.label, language: track.language, headers: [:])
            }
            activeLink = StreamLinkDto(url: primary, name: link.name, source: link.source, quality: link.quality,
                                       type: link.type, headers: [:], isPlaylist: link.isPlaylist,
                                       playlist: link.playlist, audioTracks: relayedAudio)
        }
        defer {
            if let relaySessionID {
                let revoke = relayRevoker
                Task { await revoke(relaySessionID) }
            }
        }

        let itemID = item.id
        let arguments: [String]
        do { arguments = try Self.ffmpegArguments(link: activeLink, outputPath: partURL.path, format: format, hlsInputs: hlsInputs) }
        catch { return .failed(.invalidMedia) }
        let job = FFmpegJob(
            executableURL: URL(fileURLWithPath: ffmpegPath),
            arguments: arguments,
            onProgress: { block in
                Task { @MainActor in
                    DownloadService.shared.applyProgressBlock(block, itemID: itemID, token: token)
                }
            },
            onInputDuration: { duration in
                Task { @MainActor in
                    DownloadService.shared.applyInputDuration(duration, itemID: itemID, token: token)
                }
            },
        )
        runs[item.id]?.job = .ffmpeg(job)
        let outcome = await job.run { process in
            Task { @MainActor in DaemonSupervisor.shared.track(child: process) }
        }
        if runs[item.id]?.token == token { runs[item.id]?.job = nil }
        untrackFinishedChildren()

        if let launchError = outcome.launchError {
            return .failed(.unknown("ffmpeg failed to start: \(launchError)"))
        }
        if outcome.wasTerminated {
            if item.stallDetected, isCurrent(item, token), item.state == .downloading {
                return .failed(.stalled)
            }
            return .stopped
        }
        if outcome.exitStatus != 0 {
            return .failed(DownloadPolicy.classifyFFmpegFailure(exitStatus: outcome.exitStatus, stderrTail: outcome.stderrTail))
        }

        // ffmpeg exits 0 on a playlist that died mid-way; verify.
        let size = (try? FileManager.default.attributesOfItem(atPath: partURL.path)[.size] as? Int64) ?? 0
        guard size >= 64 * 1024 else { return .failed(.invalidMedia) }
        if DownloadPolicy.isTruncated(written: outcome.lastOutTimeSeconds, expected: outcome.inputDurationSeconds) {
            return .failed(.truncated)
        }
        item.destinationURL = item.baseURL.appendingPathExtension(item.useMatroska ? "mkv" : "mp4")
        item.bytesWritten = size
        return .completed(partURL)
    }

    /// Header names that are credentials: such a link is only downloaded through the relay.
    nonisolated static func needsRelay(_ link: StreamLinkDto) -> Bool { MediaResourcePolicy.carriesCredentials(link) }

    /// Registration runs in its own task, so a cancelled caller still receives
    /// the session and can revoke it, rather than abandoning a live one (M6b).
    private func registerRelayShielded(_ resources: [MediaRelayResourceDto]) async -> DaemonClient.MediaRelaySession? {
        let register = relayRegistrar
        let registration = Task { try await register(resources) }
        do { return try await registration.value } catch {
            DaemonLog.client("download.relay_unavailable", fields: ["error": "\(type(of: error))"])
            return nil
        }
    }

    /// Removes ffmpeg processes that have exited from the supervisor's list.
    private func untrackFinishedChildren() {
        DaemonSupervisor.shared.untrackExitedChildren()
    }

    /// An engine restart ends this keep-alive with the old engine. Unlike the
    /// player (audit M7), a download does not restart it: a link that then
    /// expires fails over and is resolved again, which also renews its job.
    private func startVerifierIfNeeded(for link: StreamLinkDto) async -> String? {
        guard let data = link.extractorData, !data.isEmpty else { return nil }
        return try? await DaemonClient.shared.startExtractorVerifier(source: link.source, extractorData: data)
    }

    // MARK: - Completion

    private func finalize(_ item: QueueItem, partURL: URL, token: UUID) async {
        // Final name: the planned stem with the real extension; if something
        // else appeared there meanwhile, take the next free name.
        var final = item.destinationURL
        let fm = FileManager.default
        if fm.fileExists(atPath: final.path) {
            let reserved: Set<String>
            do { reserved = try reservedBasePaths(excluding: item.id) }
            catch {
                item.state = .failed
                item.failureReason = .unknown("Couldn’t read download records: \(error.localizedDescription)")
                upsertRecord(for: item)
                AppState.shared.presentError(item.failureReason?.label ?? "Couldn’t prepare the completed download.")
                return
            }
            let unique = Self.uniqueDestination(
                directory: final.deletingLastPathComponent(),
                baseName: final.deletingPathExtension().lastPathComponent,
                reserved: reserved,
            )
            final = unique.deletingPathExtension().appendingPathExtension(final.pathExtension)
        }

        // 1. Journal the intent: planned final path and byte count, before
        // the rename. If this cannot be saved the part stays recoverable.
        item.destinationURL = final
        item.state = .finalizing
        item.statusDetail = nil
        item.speedBytesPerSecond = 0
        activityTrigger += 1
        guard upsertRecord(for: item) else { return }
        if finalizationFault?(.intentSaved) == true { return }

        // 2. Rename within the folder (same filesystem). A name taken in the
        // meantime gets one more unique name; any other failure keeps the
        // finished part and the journal, so Retry or the next launch can
        // complete the rename instead of downloading again (audit M2).
        do {
            try renamePart(partURL, to: final)
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            do {
                let reserved = try reservedBasePaths(excluding: item.id)
                let unique = Self.uniqueDestination(directory: final.deletingLastPathComponent(),
                    baseName: final.deletingPathExtension().lastPathComponent, reserved: reserved)
                final = unique.deletingPathExtension().appendingPathExtension(final.pathExtension)
                item.destinationURL = final
                guard upsertRecord(for: item) else { return }
                try renamePart(partURL, to: final)
            } catch {
                failFinalization(item, error)
                return
            }
        } catch {
            failFinalization(item, error)
            return
        }
        if finalizationFault?(.renamed) == true { return }

        // 3. Commit the completed video immediately. Sidecars, the library
        // entry and the notification follow the committed state.
        guard commitFinalization(item, part: partURL) else { return }
        if finalizationFault?(.completionSaved) == true { return }
        notify(title: "Download complete", body: "\(item.title) — \(item.episodeLabel)", id: item.id)

        // 4. Subtitle sidecars (Android parity): bounded, best effort, and
        // unable to turn the saved video back into an unrecorded transfer.
        let wanted = DownloadPolicy.subtitlesToDownload(
            item.subtitles,
            preferredLanguage: UserPreferences.shared.subtitleLanguage,
        )
        if !wanted.isEmpty {
            await Self.downloadSubtitles(wanted, for: final)
        }
    }

    private func renamePart(_ part: URL, to final: URL) throws {
        if let injected = finalizationRenameFault?() { throw injected }
        try FileManager.default.moveItem(at: part, to: final)
    }

    /// The rename is done: record the completed video and tidy its sidecar.
    /// Shared by [finalize] and [reconcileFinalizing].
    @discardableResult
    private func commitFinalization(_ item: QueueItem, part: URL) -> Bool {
        item.state = .completed
        item.progress = 1
        item.failureReason = nil
        item.statusDetail = nil
        activityTrigger += 1
        guard upsertRecord(for: item) else { return false }
        try? FileManager.default.removeItem(at: DirectFileJob.metadataURL(forPart: part))
        autoAddToLibraryIfEnabled(item)
        return true
    }

    /// The finished part stays where it is; the record stays `finalizing`.
    private func failFinalization(_ item: QueueItem, _ error: Error) {
        let reason = FailureReason.finalizeFailed(DirectFileJob.fileSystemFailure(error).label)
        item.state = .failed
        item.failureReason = reason
        item.statusDetail = nil
        item.speedBytesPerSecond = 0
        activityTrigger += 1
        upsertRecord(for: item)
        DaemonLog.client("download.finalize_failed", fields: ["item": item.id.uuidString, "reason": reason.label])
        notify(title: "Download couldn’t be saved", body: "\(item.title) — \(item.episodeLabel): \(reason.label)", id: item.id)
    }

    /// Launch reconciliation for a record left in `finalizing`: the transfer
    /// was complete, so the outcome is decided from the files — never by
    /// downloading again over, or overwriting, something that is there.
    private func reconcileFinalizing(_ item: QueueItem) {
        let fm = FileManager.default
        let final = item.destinationURL
        let part = item.partURL
        func size(_ url: URL) -> Int64? { (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil }
        let expected = item.bytesWritten
        let finalSize = size(final), partSize = size(part)
        switch (finalSize, partSize) {
        case (let bytes?, nil) where expected <= 0 || bytes == expected:
            // Crash after the rename, before the completion was saved.
            guard commitFinalization(item, part: part) else { return }
            DaemonLog.client("download.finalize_reconciled", fields: ["item": item.id.uuidString, "outcome": "completed"])
        case (nil, let bytes?) where expected <= 0 || bytes == expected:
            // Crash before the rename (or a rename that failed): the finished part is still ours.
            do { try renamePart(part, to: final) }
            catch {
                failFinalization(item, error)
                return
            }
            guard commitFinalization(item, part: part) else { return }
            DaemonLog.client("download.finalize_reconciled", fields: ["item": item.id.uuidString, "outcome": "renamed"])
        case (nil, nil) where Self.availability(of: final) == .volumeUnavailable:
            // Unplugged, not absent: keep the journal and decide next launch.
            item.state = .paused
            item.statusDetail = "The download’s disk is not connected"
        default:
            // Missing, a different size, or both a part and a final file:
            // something else owns one of them. Report it; never overwrite.
            item.state = .failed
            item.failureReason = .unknown(finalSize == nil && partSize == nil
                ? "The finished file is missing from its folder."
                : "The finished file does not match what was downloaded. Check the folder, then retry.")
            upsertRecord(for: item)
            DaemonLog.client("download.finalize_reconciled", fields: ["item": item.id.uuidString, "outcome": "conflict"])
        }
    }

    private func fail(_ item: QueueItem, _ reason: FailureReason) {
        item.state = .failed
        item.failureReason = reason
        item.statusDetail = nil
        item.speedBytesPerSecond = 0
        // A remux partial is worthless; a direct partial stays so Retry can
        // resume it (its sidecar metadata proves which file it belongs to).
        // A finished part whose rename failed is never deleted (audit M2).
        let finishedPart: Bool = { if case .finalizeFailed = reason { true } else { false } }()
        if !finishedPart, !FileManager.default.fileExists(atPath: DirectFileJob.metadataURL(forPart: item.partURL).path) {
            try? FileManager.default.removeItem(at: item.partURL)
        }
        activityTrigger += 1
        upsertRecord(for: item)
        DaemonLog.client("download.failed", fields: ["item": item.id.uuidString, "reason": reason.label])
        notify(title: "Download failed", body: "\(item.title) — \(item.episodeLabel): \(reason.label)", id: item.id)
    }

    // MARK: - Progress delivery

    private func applyProgressBlock(_ block: [String: String], itemID: UUID, token: UUID) {
        guard runs[itemID]?.token == token, let item = queue.first(where: { $0.id == itemID }) else { return }
        for key in ["out_time_us", "total_size", "speed", "progress"] {
            if let value = block[key] {
                item.ingest(progressKey: key, value: value)
            }
        }
    }

    private func applyInputDuration(_ duration: Double, itemID: UUID, token: UUID) {
        guard runs[itemID]?.token == token, let item = queue.first(where: { $0.id == itemID }) else { return }
        item.inputDurationSeconds = duration
    }

    private func applyDirectProgress(written: Int64, total: Int64?, itemID: UUID, token: UUID) {
        guard runs[itemID]?.token == token, let item = queue.first(where: { $0.id == itemID }) else { return }
        item.ingestDirect(written: written, total: total)
    }

    // MARK: - Watchdog & power

    private func ensureWatchdog() {
        guard watchdogTask == nil, !isTerminating else { return }
        watchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let interval = self?.watchdogInterval ?? 15
                try? await Task.sleep(for: .seconds(interval))
                guard let self else { return }
                self.checkForStalls()
                if self.runs.isEmpty {
                    self.watchdogTask = nil
                    return
                }
            }
        }
    }

    private func checkForStalls() {
        let now = Date()
        for item in queue where item.state == .downloading {
            guard let run = runs[item.id], let job = run.job,
                  let last = item.lastProgressAt, now.timeIntervalSince(last) > stallTimeout,
                  !item.stallDetected else { continue }
            item.stallDetected = true
            DaemonLog.client("download.stalled", fields: ["item": item.id.uuidString])
            job.stop()
        }
    }

    /// Keeps the Mac from idle-sleeping mid-download (the supervisor's own
    /// activity deliberately allows idle sleep).
    private func updatePowerAssertion() {
        let busy = queue.contains { $0.state == .downloading || $0.state == .resolving }
        if busy, powerActivity == nil, !isTerminating {
            powerActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .userInitiated],
                reason: "Downloading videos",
            )
        } else if !busy {
            endPowerAssertion()
        }
    }

    private func endPowerAssertion() {
        if let activity = powerActivity {
            ProcessInfo.processInfo.endActivity(activity)
            powerActivity = nil
        }
    }

    // MARK: - Failure taxonomy (plan WS-3.6)

    nonisolated static func classifyFailure(exitStatus: Int32, stderrTail: String) -> FailureReason {
        DownloadPolicy.classifyFFmpegFailure(exitStatus: exitStatus, stderrTail: stderrTail)
    }

    // MARK: - Notifications (plan WS-3.6)

    private func requestNotificationPermissionIfNeeded() {
        guard !notificationPermissionRequested else { return }
        notificationPermissionRequested = true
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(title: String, body: String, id: UUID) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// The optional library entry belongs to the profile that queued the
    /// download, not to whichever profile is selected when it finishes.
    private func autoAddToLibraryIfEnabled(_ item: QueueItem) {
        guard UserPreferences.shared.autoAddDownloadsToLibrary else { return }
        // Legacy records carry no owner: the download stays shared and is
        // filed only when someone adds it to their library explicitly.
        guard let origin = item.originProfileID else { return }
        guard let store = profileStoreName(origin) else {
            AppState.shared.presentError("“\(item.title)” was downloaded, but the profile that queued it no longer exists, so it was not added to a library. It is available in Downloads.")
            return
        }
        do {
            try LibraryStore.shared.markDownloaded(downloadID: item.id, provider: item.provider,
                url: item.destinationURL.path, title: item.title, inProfileStore: store)
        } catch {
            AppState.shared.presentError("“\(item.title)” was downloaded, but could not be added to its profile’s library: \(error.localizedDescription)")
        }
    }

    /// Explicit "Add to Library" for a completed download (e.g. a legacy one
    /// with no recorded owner): files it into the selected profile.
    func addCompletedToCurrentLibrary(_ record: DownloadRecord) {
        LibraryStore.shared.perform { try LibraryStore.shared.markDownloaded(
            downloadID: record.id, provider: record.provider, url: record.destinationPath, title: record.title) }
    }

    // MARK: - Subtitle sidecars

    /// Files named `<video base>.<lang>.<ext>` next to the video.
    nonisolated static func sidecarSubtitleFiles(for videoURL: URL) -> [URL] {
        let directory = videoURL.deletingLastPathComponent()
        let prefix = videoURL.deletingPathExtension().lastPathComponent + "."
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles],
        )) ?? []
        return contents.filter { url in
            url.lastPathComponent.hasPrefix(prefix)
                && DownloadPolicy.subtitleExtensions.contains(url.pathExtension.lowercased())
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Sidecars as player subtitle tracks for local playback.
    nonisolated static func sidecarSubtitles(for videoURL: URL) -> [SubtitleDto] {
        let base = videoURL.deletingPathExtension().lastPathComponent
        return sidecarSubtitleFiles(for: videoURL).map { file in
            let middle = file.deletingPathExtension().lastPathComponent.dropFirst(base.count + 1)
            let language = middle.split(separator: ".").first.map(String.init) ?? "und"
            return SubtitleDto(url: file.path, language: language, label: language.uppercased(), mimeType: nil)
        }
    }

    /// Optional enrichment: a sidecar that is unavailable or over its byte
    /// budget is skipped and never fails the saved video.
    nonisolated static func downloadSubtitles(_ subtitles: [SubtitleDto], for videoURL: URL,
                                              maxBytes: Int = BoundedHTTPResource.subtitleBytes) async {
        var usedNames = Set<String>()
        for subtitle in subtitles {
            guard !Task.isCancelled, let url = URL(string: subtitle.url), DownloadPolicy.isAllowedRemoteURL(subtitle.url) else { continue }
            var request = URLRequest(url: url)
            request.setValue(defaultUserAgent, forHTTPHeaderField: "User-Agent")
            // The limit holds while bytes arrive, not after a full body is buffered.
            guard let data = try? await BoundedHTTPResource.load(request, maxBytes: maxBytes) else { continue }
            let language = DownloadPolicy.sanitizedFileName(subtitle.language)
                .replacing(".", with: "_")
                .replacing(" ", with: "_")
            var name = language.isEmpty ? "und" : language
            var counter = 2
            while usedNames.contains(name) {
                name = "\(language)_\(counter)"
                counter += 1
            }
            usedNames.insert(name)
            let target = videoURL.deletingPathExtension()
                .appendingPathExtension(name)
                .appendingPathExtension(DownloadPolicy.subtitleExtension(for: subtitle))
            try? data.write(to: target, options: .atomic)
        }
    }

    // MARK: - ffmpeg

    nonisolated static func ffmpegBinaryPath() -> String? {
        if let path = Bundle.main.path(forResource: "ffmpeg", ofType: nil, inDirectory: "Binaries") {
            return path
        }
        let bundleBin = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Binaries/ffmpeg")
        if FileManager.default.isExecutableFile(atPath: bundleBin.path) {
            return bundleBin.path
        }
        // Development fallback: Homebrew/system ffmpeg
        #if DEBUG
        if FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg") {
            return "/opt/homebrew/bin/ffmpeg"
        }
        if FileManager.default.isExecutableFile(atPath: "/usr/local/bin/ffmpeg") {
            return "/usr/local/bin/ffmpeg"
        }
        #endif
        return nil
    }

    /// Test/compat wrapper: arguments for an item's final destination.
    static func ffmpegArguments(for item: QueueItem, link: StreamLinkDto) throws -> [String] {
        try ffmpegArguments(link: link, outputPath: item.destinationURL.path, format: "mp4")
    }

    /// ffmpeg invocation for one input (+ separate audio tracks).
    ///
    /// Security: `-protocol_whitelist` confines the input and everything it
    /// references (segments, keys, nested playlists) to http(s); header
    /// values are stripped of control characters so they can't inject
    /// header lines. Headers travel in argv, which other processes of the
    /// same user can read, so a link with credentials never reaches here
    /// with them: [attemptFFmpeg] relays it and passes no headers at all.
    /// [hlsInputs]: whether each input (video, then audio) is HLS, taken from
    /// the original addresses when the inputs are relay URLs.
    nonisolated static func ffmpegArguments(link: StreamLinkDto, outputPath: String, format: String,
                                            hlsInputs: [Bool]? = nil) throws -> [String] {
        try MediaResourcePolicy.validate(link)
        if needsRelay(link) { throw MediaResourcePolicy.Rejection.unsupportedURL }
        var arguments = [
            "-hide_banner",
            "-nostdin",
            "-y",
            "-loglevel", "info",
            "-progress", "pipe:1",
            "-nostats",
        ]

        func inputOptions(headers rawHeaders: [String: String], hls: Bool) throws -> [String] {
            let headers = try DownloadPolicy.sanitizedHeaders(rawHeaders)
            var options = [
                "-protocol_whitelist", DownloadPolicy.ffmpegProtocolWhitelist,
            ]
            // Only an HLS input consumes these; ffmpeg rejects options the
            // chosen demuxer leaves unused.
            if hls { options.append(contentsOf: DownloadPolicy.ffmpegHLSInputOptions) }
            options += [
                "-reconnect", "1",
                "-reconnect_streamed", "1",
                "-reconnect_on_network_error", "1",
                "-reconnect_delay_max", "10",
                "-rw_timeout", "30000000", // 30 s without I/O → error
            ]
            let excluded: Set<String> = ["range", "user-agent", "referer"]
            let extra = headers
                .filter { !excluded.contains($0.name.lowercased()) }
                .map { "\($0.name): \($0.value)" }
                .joined(separator: "\r\n")
            if !extra.isEmpty {
                options.append(contentsOf: ["-headers", extra + "\r\n"])
            }
            if let referer = DownloadPolicy.header("Referer", in: headers), !referer.isEmpty {
                options.append(contentsOf: ["-referer", referer])
            }
            let userAgent = DownloadPolicy.header("User-Agent", in: headers).flatMap { $0.isEmpty ? nil : $0 }
                ?? defaultUserAgent
            options.append(contentsOf: ["-user_agent", userAgent])
            return options
        }

        func isHLS(_ index: Int, url: String, type: String?) -> Bool {
            if let hlsInputs, hlsInputs.indices.contains(index) { return hlsInputs[index] }
            return DownloadPolicy.isHLS(url: url, type: type)
        }
        arguments.append(contentsOf: try inputOptions(headers: link.headers, hls: isHLS(0, url: link.url, type: link.type)))
        arguments.append(contentsOf: ["-i", link.url])

        // Split audio (separate audio renditions): add each as an input and
        // map video + all audio explicitly. Otherwise ffmpeg's default
        // selection keeps the best video and best audio stream.
        let audioTracks = link.audioTracks
        if !audioTracks.isEmpty {
            for (index, track) in audioTracks.enumerated() {
                arguments.append(contentsOf: try inputOptions(headers: track.headers.isEmpty ? link.headers : track.headers,
                                                              hls: isHLS(index + 1, url: track.url, type: nil)))
                arguments.append(contentsOf: ["-i", track.url])
            }
            // Separate tracks map first so output audio stream N is track N
            // (language tags line up); any audio muxed into input 0 follows.
            arguments.append(contentsOf: ["-map", "0:v:0"])
            for index in audioTracks.indices {
                arguments.append(contentsOf: ["-map", "\(index + 1):a:0"])
            }
            arguments.append(contentsOf: ["-map", "0:a?"])
            for (index, track) in audioTracks.enumerated() {
                if let language = track.language, !language.isEmpty {
                    arguments.append(contentsOf: ["-metadata:s:a:\(index)", "language=\(language)"])
                }
            }
        }

        arguments.append(contentsOf: [
            "-c", "copy",
            "-sn",
            "-dn",
        ])
        if format == "mp4" {
            arguments.append(contentsOf: ["-movflags", "+faststart"])
        }
        arguments.append(contentsOf: ["-f", format, outputPath])
        return arguments
    }
}
