import XCTest
@testable import CloudStream

/// Filename safety (U-49). "Face/Off" used to produce an invalid path.
final class FileNameSanitizerTests: XCTestCase {
    func testSlashIsReplaced() {
        XCTAssertEqual(DownloadService.sanitizedFileName("Face/Off"), "Face_Off")
    }

    func testColonIsReplaced() {
        XCTAssertEqual(DownloadService.sanitizedFileName("Movie: Subtitle"), "Movie - Subtitle")
    }

    func testTrailingDotsAndSpacesRemoved() {
        XCTAssertEqual(DownloadService.sanitizedFileName("Title... "), "Title")
    }

    func testControlCharactersCollapsed() {
        XCTAssertEqual(DownloadService.sanitizedFileName("A\nB"), "A B")
    }

    func testEmptyBecomesPlaceholder() {
        XCTAssertEqual(DownloadService.sanitizedFileName("/"), "_")
        XCTAssertEqual(DownloadService.sanitizedFileName("..."), "Download")
    }

    func testUniqueDestinationResolvesCollisions() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = DownloadService.uniqueDestination(directory: dir, baseName: "Show S1, E1")
        XCTAssertTrue(first.lastPathComponent.hasSuffix(".mp4"))
        try Data("x".utf8).write(to: first)

        let second = DownloadService.uniqueDestination(directory: dir, baseName: "Show S1, E1")
        XCTAssertEqual(second.lastPathComponent, "Show S1, E1 (2).mp4")
        try Data("x".utf8).write(to: second)

        let third = DownloadService.uniqueDestination(directory: dir, baseName: "Show S1, E1")
        XCTAssertEqual(third.lastPathComponent, "Show S1, E1 (3).mp4")
    }
}

/// QueueItem progress ingestion: speed EMA and honest ETA (U-45).
@MainActor
final class DownloadProgressTests: XCTestCase {
    private func makeItem(durationSeconds: Double?) -> DownloadService.QueueItem {
        DownloadService.QueueItem(
            title: "Show",
            episodeLabel: "S1, E1",
            provider: "provider",
            episodeData: "data",
            destinationURL: URL(fileURLWithPath: "/tmp/x.mp4"),
            durationSeconds: durationSeconds,
        )
    }

    func testStreamPositionAndProgressFromOutTime() {
        let item = makeItem(durationSeconds: 600)
        item.state = .downloading
        item.ingest(progressKey: "out_time_us", value: "300000000")
        XCTAssertEqual(item.streamPositionSeconds, 300, accuracy: 0.001)
        XCTAssertEqual(item.progress, 0.5, accuracy: 0.001)
    }

    func testSpeedMultiplierParsedFromFFmpegNotation() {
        let item = makeItem(durationSeconds: 600)
        item.state = .downloading
        item.ingest(progressKey: "speed", value: "12.4x")
        XCTAssertEqual(item.mediaSpeedMultiplier, 12.4, accuracy: 0.001)
    }

    func testETAFromDurationAndSpeed() {
        let item = makeItem(durationSeconds: 600)
        item.state = .downloading
        item.ingest(progressKey: "out_time_us", value: "300000000") // halfway
        item.ingest(progressKey: "speed", value: "2x")
        // 300 s of stream remaining at 2× realtime = 150 s wall clock.
        XCTAssertEqual(item.etaLabel, "2m 30s")
    }

    func testETAHiddenWithoutKnownDuration() {
        let item = makeItem(durationSeconds: nil)
        item.state = .downloading
        item.ingest(progressKey: "speed", value: "2x")
        XCTAssertNil(item.etaLabel, "ETA without duration would be a guess — it must stay hidden")
    }

    func testETAHiddenWhenNotDownloading() {
        let item = makeItem(durationSeconds: 600)
        item.ingest(progressKey: "out_time_us", value: "300000000")
        item.ingest(progressKey: "speed", value: "2x")
        XCTAssertNil(item.etaLabel)
    }

    func testSpeedEMAFromByteSamples() {
        let item = makeItem(durationSeconds: nil)
        item.state = .downloading
        item.startedAt = Date().addingTimeInterval(-10)

        // One second since the last sample → +1 MB in 1 s ≈ 1 MB/s instant,
        // which seeds the EMA.
        item.lastSampleAt = Date().addingTimeInterval(-1)
        item.lastSampleBytes = 1_000_000

        item.ingest(progressKey: "total_size", value: "2048000")
        XCTAssertGreaterThan(item.speedBytesPerSecond, 500_000)
        XCTAssertLessThan(item.speedBytesPerSecond, 1_500_000)
        XCTAssertEqual(item.bytesWritten, 2_048_000)
    }

    func testIngestIgnoredWhenNotDownloading() {
        let item = makeItem(durationSeconds: 600)
        item.ingest(progressKey: "out_time_us", value: "300000000")
        XCTAssertEqual(item.progress, 0)
    }

    func testFailureClassification() {
        XCTAssertEqual(
            DownloadService.classifyFailure(exitStatus: 1, stderrTail: "HTTP error 403 Forbidden"),
            .forbidden,
        )
        XCTAssertEqual(
            DownloadService.classifyFailure(exitStatus: 1, stderrTail: "Server returned 404 Not Found"),
            .notFound,
        )
        XCTAssertEqual(
            DownloadService.classifyFailure(exitStatus: 1, stderrTail: "No space left on device"),
            .diskFull,
        )
        XCTAssertEqual(
            DownloadService.classifyFailure(exitStatus: 1, stderrTail: "Protocol not found"),
            .protocolUnsupported,
        )
        if case .unknown = DownloadService.classifyFailure(exitStatus: 23, stderrTail: "something else") {
            // expected
        } else {
            XCTFail("unclassified failure must fall through to .unknown")
        }
    }
}

/// Provider quality → label mapping (Android `Qualities` parity).
final class QualityLabelTests: XCTestCase {
    private func link(quality: Int) -> StreamLinkDto {
        StreamLinkDto(
            url: "https://example.com/v",
            name: "fallback",
            source: "src",
            quality: quality,
            type: "video",
            headers: [:],
            extractorData: nil,
            isPlaylist: false,
            playlist: [],
        )
    }

    func testKnownBuckets() {
        XCTAssertEqual(link(quality: 2160).qualityLabel, "4K")
        XCTAssertEqual(link(quality: 1080).qualityLabel, "1080p")
        XCTAssertEqual(link(quality: 720).qualityLabel, "720p")
        XCTAssertEqual(link(quality: 480).qualityLabel, "480p")
        XCTAssertEqual(link(quality: 360).qualityLabel, "360p")
        XCTAssertEqual(link(quality: 144).qualityLabel, "144p")
    }

    func testUnknownFallsBackToName() {
        XCTAssertEqual(link(quality: 0).qualityLabel, "fallback")
        XCTAssertEqual(link(quality: -1).qualityLabel, "fallback")
        XCTAssertEqual(link(quality: 100_000).qualityLabel, "fallback")
    }
}

/// Download queue management, cancellation, arguments, and lifecycle tests.
@MainActor
final class DownloadQueueAndCancellationTests: XCTestCase {
    func testFFmpegArgumentsIncludeStreamCopyAndReconnectFlags() throws {
        let item = DownloadService.QueueItem(
            title: "Test Movie",
            episodeLabel: "Movie",
            provider: "SuperStream",
            episodeData: "data_123",
            destinationURL: URL(fileURLWithPath: "/tmp/movie.mp4"),
            durationSeconds: 3600,
        )
        let link = StreamLinkDto(
            url: "https://cdn.example.com/master.m3u8",
            name: "1080p",
            source: "CDN",
            quality: 1080,
            type: "m3u8",
            headers: [
                "User-Agent": "CustomUA/1.0",
                "Referer": "https://example.com/watch",
                "X-Requested-With": "XMLHttpRequest",
                "Range": "bytes=0-100", // should be filtered out
            ],
            extractorData: nil,
            isPlaylist: false,
            playlist: [],
            audioTracks: [],
        )

        let args = try DownloadService.ffmpegArguments(for: item, link: link)

        // Verify reconnect flags
        XCTAssertTrue(args.contains("-reconnect"))
        XCTAssertTrue(args.contains("-reconnect_streamed"))

        // Verify stream copy and container safety
        XCTAssertTrue(args.contains("-c"))
        XCTAssertEqual(args[args.firstIndex(of: "-c")! + 1], "copy")
        XCTAssertTrue(args.contains("-sn"))
        XCTAssertTrue(args.contains("-dn"))
        XCTAssertTrue(args.contains("+faststart"))

        // Verify user agent and referer extraction
        XCTAssertTrue(args.contains("-user_agent"))
        XCTAssertTrue(args.contains("CustomUA/1.0"))
        XCTAssertTrue(args.contains("-referer"))
        XCTAssertTrue(args.contains("https://example.com/watch"))

        // Verify headers string does not leak Range or User-Agent
        if let headersIdx = args.firstIndex(of: "-headers"), headersIdx + 1 < args.count {
            let headerValue = args[headersIdx + 1]
            XCTAssertTrue(headerValue.contains("X-Requested-With: XMLHttpRequest"))
            XCTAssertFalse(headerValue.lowercased().contains("range:"))
            XCTAssertFalse(headerValue.lowercased().contains("user-agent:"))
        }

        // Verify destination
        XCTAssertEqual(args.last, "/tmp/movie.mp4")
    }

    func testCancelSetsStateAndCleansQueueItem() {
        let item = DownloadService.QueueItem(
            title: "Test Series",
            episodeLabel: "S1:E1",
            provider: "ProviderX",
            episodeData: "ep_data_1",
            destinationURL: URL(fileURLWithPath: "/tmp/nonexistent_\(UUID().uuidString).mp4"),
            durationSeconds: 1800,
        )
        item.state = .downloading
        DownloadService.shared.cancel(item)
        defer { DownloadService.shared.removeFromQueue(item) }

        XCTAssertEqual(item.state, .cancelled)
    }

    func testRetryResetsStateAndMetrics() {
        let item = DownloadService.QueueItem(
            title: "Failed Movie",
            episodeLabel: "Movie",
            provider: "ProviderX",
            episodeData: "ep_data_failed",
            destinationURL: URL(fileURLWithPath: "/tmp/failed.mp4"),
            durationSeconds: 1800,
        )
        item.state = .failed
        item.failureReason = .forbidden
        item.progress = 0.4
        item.bytesWritten = 10_000_000

        DownloadService.shared.retry(item)
        // Retry persists the item; remove it so a later queue restore cannot
        // bring back a stray download that holds an admission slot.
        defer { DownloadService.shared.removeFromQueue(item) }

        XCTAssertEqual(item.state, .queued)
        XCTAssertEqual(item.progress, 0)
        XCTAssertEqual(item.bytesWritten, 0)
        XCTAssertNil(item.failureReason)
    }

    func testCancelAndClearAllowsNextDownloadToStart() {
        DownloadService.shared.cancelAll()
        DownloadService.shared.clearFinished()

        let destA = URL(fileURLWithPath: "/tmp/test_a_\(UUID().uuidString).mp4")
        let destB = URL(fileURLWithPath: "/tmp/test_b_\(UUID().uuidString).mp4")

        let enqueuedA = DownloadService.shared.enqueue(
            title: "Video A",
            episodeLabel: "Ep 1",
            provider: "TestProv",
            episodeData: "data_a_\(UUID().uuidString)",
            destinationURL: destA,
        )
        XCTAssertTrue(enqueuedA)

        // Item A should have advanced to resolving (since slots are available)
        guard let itemA = DownloadService.shared.queue.last else {
            XCTFail("Item A should be in queue")
            return
        }
        XCTAssertEqual(itemA.state, .resolving)

        // Cancel A
        DownloadService.shared.cancel(itemA)
        XCTAssertEqual(itemA.state, .cancelled)

        // Clear finished
        DownloadService.shared.clearFinished()
        XCTAssertFalse(DownloadService.shared.queue.contains { $0.id == itemA.id })

        // Now enqueue Video B
        let enqueuedB = DownloadService.shared.enqueue(
            title: "Video B",
            episodeLabel: "Ep 1",
            provider: "TestProv",
            episodeData: "data_b_\(UUID().uuidString)",
            destinationURL: destB,
        )
        XCTAssertTrue(enqueuedB)

        // Item B must NOT be stuck in .queued — it should advance to .resolving immediately
        guard let itemB = DownloadService.shared.queue.last else {
            XCTFail("Item B should be in queue")
            return
        }
        XCTAssertEqual(itemB.state, .resolving, "Item B must transition to .resolving and not be stuck in .queued")

        // Cleanup
        DownloadService.shared.cancel(itemB)
        DownloadService.shared.clearFinished()
    }

    func testReenqueueCancelledEpisodeReplacesStaleItem() {
        DownloadService.shared.cancelAll()
        DownloadService.shared.clearFinished()

        let epData = "data_repeat_\(UUID().uuidString)"
        let dest = URL(fileURLWithPath: "/tmp/test_repeat_\(UUID().uuidString).mp4")

        DownloadService.shared.enqueue(
            title: "Video Repeat",
            episodeLabel: "Movie",
            provider: "TestProv",
            episodeData: epData,
            destinationURL: dest,
        )

        guard let first = DownloadService.shared.queueItem(forProvider: "TestProv", episodeData: epData) else {
            XCTFail("Should find first enqueued item")
            return
        }

        DownloadService.shared.cancel(first)
        XCTAssertEqual(first.state, .cancelled)

        // Re-enqueue without manually clearing finished
        let enqueuedSecond = DownloadService.shared.enqueue(
            title: "Video Repeat",
            episodeLabel: "Movie",
            provider: "TestProv",
            episodeData: epData,
            destinationURL: dest,
        )
        XCTAssertTrue(enqueuedSecond)

        let retrieved = DownloadService.shared.queueItem(forProvider: "TestProv", episodeData: epData)
        XCTAssertNotNil(retrieved)
        XCTAssertNotEqual(retrieved?.id, first.id, "A fresh QueueItem should replace the old cancelled one")
        XCTAssertEqual(retrieved?.state, .resolving, "The fresh item should be resolving, not stuck cancelled or queued")

        // Cleanup
        if let retrieved { DownloadService.shared.cancel(retrieved) }
        DownloadService.shared.clearFinished()
    }
}
