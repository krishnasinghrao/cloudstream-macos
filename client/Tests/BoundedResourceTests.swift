import AppKit
import Synchronization
import XCTest
import zlib
@testable import CloudStream

/// Physical memory footprint of this process, as Activity Monitor reports it.
private func footprint() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
}

/// A reference-backed lock for state shared between concurrent test tasks. A
/// local `Mutex` is noncopyable, and Swift 6.2 rejects capturing one in the
/// `sending` closures of a task group.
private final class Locked<Value: Sendable>: @unchecked Sendable {
    private let mutex: Mutex<Value>
    init(_ initial: Value) { self.mutex = Mutex(initial) }
    func withLock<R: Sendable>(_ body: (inout Value) throws -> R) rethrows -> R {
        try mutex.withLock { try body(&$0) }
    }
}

/// Audit A32: artwork and subtitle bodies are bounded while they arrive, and
/// image dimensions cannot dictate decode memory.
final class BoundedResourceTests: XCTestCase {
    private var server: RangeHTTPServer!
    private var directory: URL!

    override func setUpWithError() throws {
        server = try RangeHTTPServer()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("bounded-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        server = nil
    }

    private func load(_ path: String, maxBytes: Int = 4096, headers: [String: String] = [:]) async throws -> Data {
        var request = URLRequest(url: URL(string: server.url(path))!)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        return try await BoundedHTTPResource.load(request, maxBytes: maxBytes)
    }

    private func assertFailure(_ expected: BoundedHTTPResource.Failure, _ path: String, maxBytes: Int = 4096,
                               file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await load(path, maxBytes: maxBytes)
            XCTFail("expected \(expected)", file: file, line: line)
        } catch { XCTAssertEqual(error as? BoundedHTTPResource.Failure, expected, file: file, line: line) }
    }

    private func gzip(_ data: Data) throws -> Data {
        let deflated = try (data as NSData).compressed(using: .zlib) as Data
        var result = Data([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3]) + deflated
        var crc = data.withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count))) }.littleEndian
        var size = UInt32(truncatingIfNeeded: data.count).littleEndian
        withUnsafeBytes(of: &crc) { result.append(contentsOf: $0) }
        withUnsafeBytes(of: &size) { result.append(contentsOf: $0) }
        return result
    }

    private func png(width: Int, height: Int) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    func testBodyWithinBudgetLoadsAndOversizedDeclaredLengthIsRefusedBeforeTheBody() async throws {
        let body = Data(repeating: 7, count: 4096)
        server.set("/ok", .init(body: body))
        let loaded = try await load("/ok")
        XCTAssertEqual(loaded, body)
        server.set("/declared", .init(body: Data(repeating: 7, count: 4097)))
        await assertFailure(.tooLarge, "/declared")
        server.set("/missing-status", .init(body: body, status: 503))
        await assertFailure(.status(503), "/missing-status")
        await assertFailure(.status(404), "/absent")
    }

    func testUndeclaredSlowAndCompressedBodiesStopAtTheBudget() async throws {
        // No Content-Length: only counting received bytes can stop this.
        server.set("/undeclared", .init(body: Data(repeating: 1, count: 3 * 1_048_576), chunkDelay: 0.01, omitContentLength: true))
        let started = ContinuousClock.now
        await assertFailure(.tooLarge, "/undeclared", maxBytes: 100_000)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5), "the load is cancelled at the cap, not after the whole body")

        // 4 MiB of zeros arrive as a few KiB; the decoded size is what counts.
        let compressed = try gzip(Data(count: 4 * 1_048_576))
        XCTAssertLessThan(compressed.count, 64 * 1024)
        server.set("/gzip", .init(body: compressed, extraHeaders: ["Content-Encoding": "gzip"]))
        await assertFailure(.tooLarge, "/gzip", maxBytes: 256 * 1024)
        let inflated = try await load("/gzip", maxBytes: 8 * 1_048_576)
        XCTAssertEqual(inflated.count, 4 * 1_048_576)
    }

    func testRedirectsStayOnHTTPAndDropHeadersForAnotherOrigin() async throws {
        // The URL loading system refuses an http-to-file redirect by itself.
        server.set("/local", .init(body: Data(), redirectLocation: "file:///etc/hosts"))
        do { _ = try await load("/local"); XCTFail("a redirect to a local file returned data") }
        catch { XCTAssertNotNil(error as? BoundedHTTPResource.Failure) }
        server.set("/target", .init(body: Data("ok".utf8)))
        // An HTTP target the media policy forbids is refused by this loader.
        server.set("/userinfo", .init(body: Data(), redirectLocation: "http://user:secret@127.0.0.1:\(server.port)/target"))
        await assertFailure(.redirectRejected, "/userinfo")
        XCTAssertFalse(server.requests.contains { $0.hasPrefix("GET /target") }, "the rejected redirect was never requested")
        server.set("/same", .init(body: Data(), redirectLocation: server.url("/target")))
        let loaded = try await load("/same", headers: ["Cookie": "session=1"])
        XCTAssertEqual(loaded, Data("ok".utf8))
        XCTAssertTrue(server.requests.last { $0.hasPrefix("GET /target") }?.contains("Cookie: session=1") ?? false,
                      "the same origin keeps its authorized header")
        // "localhost" is a different origin than 127.0.0.1 for header purposes.
        server.set("/cross", .init(body: Data(), redirectLocation: "http://localhost:\(server.port)/target"))
        _ = try await load("/cross", headers: ["Cookie": "session=1", "X-Token": "t"])
        let crossed = try XCTUnwrap(server.requests.last { $0.hasPrefix("GET /target") })
        XCTAssertFalse(crossed.contains("session=1"))
        XCTAssertFalse(crossed.contains("X-Token"))
    }

    func testNonHTTPRequestsAndCancellationAreRejected() async throws {
        do {
            _ = try await BoundedHTTPResource.load(URLRequest(url: URL(fileURLWithPath: "/etc/hosts")), maxBytes: 10)
            XCTFail("a local file is not a remote resource")
        } catch { XCTAssertEqual(error as? BoundedHTTPResource.Failure, .invalidURL) }
        server.set("/slow", .init(body: Data(repeating: 1, count: 2 * 1_048_576), chunkDelay: 0.05))
        let slow = URLRequest(url: URL(string: server.url("/slow"))!)
        let task = Task { try await BoundedHTTPResource.load(slow, maxBytes: 8 * 1_048_576) }
        try await Task.sleep(for: .milliseconds(120))
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled load returned data") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
    }

    func testDecoderRejectsHugeDimensionsAndDownsamplesLargeArtwork() throws {
        // A few KiB of PNG that would decode to ~400 MB of pixels.
        let bomb = try png(width: 10_000, height: 10_000)
        XCTAssertLessThan(bomb.count, 2 * 1_048_576)
        XCTAssertNil(BoundedImageDecoder.decode(bomb), "over the pixel budget: rejected before allocation")
        let backdrop = try XCTUnwrap(BoundedImageDecoder.decode(try png(width: 5000, height: 2500)))
        XCTAssertEqual(backdrop.pixelWidth, BoundedImageDecoder.maxRenditionDimension)
        XCTAssertEqual(backdrop.pixelHeight, BoundedImageDecoder.maxRenditionDimension / 2)
        let poster = try XCTUnwrap(BoundedImageDecoder.decode(try png(width: 300, height: 450)))
        XCTAssertEqual([poster.pixelWidth, poster.pixelHeight], [300, 450], "ordinary artwork is not rescaled")
        XCTAssertNil(BoundedImageDecoder.decode(Data("<html>not an image</html>".utf8)))
        // Card renditions: a full-size poster is decoded at display size, never upscaled.
        let card = try XCTUnwrap(BoundedImageDecoder.decode(try png(width: 2000, height: 3000),
                                                             maxDimension: ArtworkRendition.thumbnail.maxDimension))
        XCTAssertEqual([card.pixelWidth, card.pixelHeight], [427, 640])
        let small = try XCTUnwrap(BoundedImageDecoder.decode(try png(width: 300, height: 450),
                                                              maxDimension: ArtworkRendition.thumbnail.maxDimension))
        XCTAssertEqual([small.pixelWidth, small.pixelHeight], [300, 450])
    }

    @MainActor
    func testImageCacheBoundsBodiesScopesHeadersAndStillCaches() async throws {
        let cache = ImageCache(directory: directory, maxResponseBytes: 200_000)
        let poster = try png(width: 64, height: 96)
        server.set("/poster.png", .init(body: poster, contentType: "image/png"))
        let first = await cache.image(for: server.url("/poster.png"))
        XCTAssertNotNil(first)
        let before = server.requests.count
        let again = await cache.image(for: server.url("/poster.png"))
        XCTAssertNotNil(again)
        XCTAssertEqual(server.requests.count, before, "memory hit")
        XCTAssertNotNil(cache.synchronousMemoryImage(for: server.url("/poster.png")))
        // A card rendition is its own memory entry, decoded from the same disk file.
        XCTAssertNil(cache.synchronousMemoryImage(for: server.url("/poster.png"), rendition: .thumbnail))
        let thumbnail = await cache.image(for: server.url("/poster.png"), rendition: .thumbnail)
        XCTAssertNotNil(thumbnail)
        XCTAssertEqual(server.requests.count, before, "disk hit")
        XCTAssertNotNil(cache.synchronousMemoryImage(for: server.url("/poster.png"), rendition: .thumbnail))

        // Oversized, mislabelled and unavailable artwork are simply absent.
        server.set("/huge.png", .init(body: Data(repeating: 0, count: 300_000), contentType: "image/png"))
        let huge = await cache.image(for: server.url("/huge.png"))
        XCTAssertNil(huge)
        server.set("/page", .init(body: poster, contentType: "text/html"))
        let page = await cache.image(for: server.url("/page"))
        XCTAssertNil(page)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(files.count, 1, "rejected bodies are not written to the disk cache")

        // The same URL under different credentials is a different entry.
        server.set("/private.png", .init(body: poster, contentType: "image/png", requiredHeader: "Cookie: user=a"))
        let allowed = await cache.image(for: server.url("/private.png"), headers: ["Cookie": "user=a"])
        XCTAssertNotNil(allowed)
        let other = await cache.image(for: server.url("/private.png"), headers: ["Cookie": "user=b"])
        XCTAssertNil(other, "another credential does not receive the cached artwork")
        XCTAssertNil(cache.synchronousMemoryImage(for: server.url("/private.png")))
        XCTAssertNotEqual(ImageCache.cacheKey(for: "u", headers: ["Cookie": "a"]), ImageCache.cacheKey(for: "u", headers: ["Cookie": "b"]))
        XCTAssertEqual(ImageCache.cacheKey(for: "u", headers: nil), "u")

        // Concurrent requests for one key share a single load.
        server.set("/shared.png", .init(body: poster, contentType: "image/png", chunkDelay: 0.05))
        let shared = server.url("/shared.png")
        async let one = cache.image(for: shared)
        async let two = cache.image(for: shared)
        let pair = await [one, two]
        XCTAssertEqual(pair.compactMap { $0 }.count, 2)
        XCTAssertEqual(server.requests.filter { $0.hasPrefix("GET /shared.png") }.count, 1)

        cache.clearAll()
        XCTAssertNil(cache.synchronousMemoryImage(for: server.url("/poster.png")))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    /// Peak process memory while many large backdrops load at once (plan N01
    /// acceptance). A measurement with a ceiling derived from the design:
    /// the memory cache's cost limit plus what the in-flight loads may hold.
    @MainActor
    func testPeakMemoryUnderSimultaneousLargeArtworkLoads() async throws {
        guard ProcessInfo.processInfo.environment["CS_LARGE_LIBRARY_TESTS"] == "1" else {
            throw XCTSkip("Set CS_LARGE_LIBRARY_TESTS=1 to run memory measurements")
        }
        // A 4000x3000 photo-like JPEG: noise, so it neither compresses to nothing nor decodes cheaply.
        let (width, height) = (4000, 3000)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        var seed: UInt32 = 12345
        for index in 0..<(bitmap.bytesPerRow * height) {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            pixels[index] = UInt8(truncatingIfNeeded: (seed >> 24) / 4 + UInt32(index % 191))
        }
        let body = try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]))
        let loads = 24
        for index in 0..<loads { server.set("/backdrop-\(index).jpg", .init(body: body, contentType: "image/jpeg")) }

        let cache = ImageCache(directory: directory)
        let baseline = footprint()
        let peak = Mutex(baseline)
        let sampling = Mutex(true)
        let sampler = Thread {
            while sampling.withLock({ $0 }) {
                let now = footprint()
                peak.withLock { $0 = max($0, now) }
                Thread.sleep(forTimeInterval: 0.002)
            }
        }
        sampler.start()
        let started = ContinuousClock.now
        let loaded = await withTaskGroup(of: Bool.self) { group in
            let addresses = (0..<loads).map { server.url("/backdrop-\($0).jpg") }
            for address in addresses { group.addTask { await cache.image(for: address) != nil } }
            var succeeded = 0
            for await success in group where success { succeeded += 1 }
            return succeeded
        }
        let elapsed = ContinuousClock.now - started
        sampling.withLock { $0 = false }
        while !sampler.isFinished { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertEqual(loaded, loads)

        let megabyte = 1_048_576.0
        let peakDelta = Double(peak.withLock { $0 } - baseline) / megabyte
        let settled = Double(footprint() - baseline) / megabyte
        let rendition = 2560.0 * 1920.0 * 4 / megabyte
        print(String(format: "IMAGE-MEMORY %d x %dx%d JPEG (%.1f MB each): peak +%.0f MB, settled +%.0f MB, %.2f s; one rendition %.1f MB",
                     loads, width, height, Double(body.count) / megabyte, peakDelta, settled, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18, rendition))
        // Ceiling: everything the cache may retain, the decode budget, and
        // for each concurrent load its response body (once in the transport,
        // once delivered) and its finished rendition.
        let decoding = Double(ImageCache.maxConcurrentDecodePixels * 4) / megabyte
        let inFlight = Double(ImageCache.maxConcurrentLoads) * (2 * Double(body.count) / megabyte + rendition)
        XCTAssertLessThan(peakDelta, 256 + decoding + inFlight)
        cache.clearAll()
    }

    func testLimiterNeverExceedsItsLimitAndServesEveryCaller() async {
        let limiter = AsyncLimiter(limit: 3)
        let finished = await withTaskGroup(of: Int.self) { group -> Int in
            for index in 0..<24 {
                group.addTask {
                    (try? await limiter.run { try? await Task.sleep(for: .milliseconds(5)); return index }) ?? -1
                }
            }
            return await group.reduce(0) { count, _ in count + 1 }
        }
        XCTAssertEqual(finished, 24)
        let peak = await limiter.peak
        XCTAssertEqual(peak, 3)
    }

    func testWeightedLimiterKeepsTotalCostWithinTheLimitAndRunsAnOversizedJobAlone() async {
        let limiter = AsyncLimiter(limit: 10)
        let running = Locked(0), worst = Locked(0)
        let finished = await withTaskGroup(of: Int.self) { group -> Int in
            // Costs 1...7 repeated, plus two jobs larger than the whole limit.
            for cost in (0..<28).map({ $0 % 7 + 1 }) + [25, 400] {
                group.addTask {
                    (try? await limiter.run(cost: cost) {
                        let effective = min(cost, 10)
                        let now = running.withLock { $0 += effective; return $0 }
                        worst.withLock { $0 = max($0, now) }
                        try? await Task.sleep(for: .milliseconds(3))
                        running.withLock { $0 -= effective }
                        return cost
                    }) ?? -1
                }
            }
            return await group.reduce(0) { count, _ in count + 1 }
        }
        XCTAssertEqual(finished, 30, "every job ran, including the oversized ones")
        XCTAssertLessThanOrEqual(worst.withLock { $0 }, 10)
        let peak = await limiter.peak
        XCTAssertLessThanOrEqual(peak, 10)
        XCTAssertGreaterThan(peak, 7, "small jobs do run together")
    }

    func testSubtitleSidecarsRespectTheirBudgetWhileReceiving() async throws {
        let video = directory.appendingPathComponent("Video.mp4")
        server.set("/small.vtt", .init(body: Data("WEBVTT\n".utf8), contentType: "text/vtt"))
        server.set("/big.vtt", .init(body: Data(repeating: 0x20, count: 2 * 1_048_576), chunkDelay: 0.01, omitContentLength: true))
        func subtitle(_ path: String, _ language: String) -> SubtitleDto {
            SubtitleDto(url: server.url(path), language: language, label: nil, mimeType: nil)
        }
        await DownloadService.downloadSubtitles([subtitle("/big.vtt", "Big"), subtitle("/small.vtt", "English")],
                                                for: video, maxBytes: 64 * 1024)
        let saved = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(saved.count, 1, "the oversized sidecar is skipped; the valid one is still saved: \(saved)")
        XCTAssertTrue(saved[0].hasPrefix("Video.English."))
    }
}
