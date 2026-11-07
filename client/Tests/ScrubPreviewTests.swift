import CoreGraphics
import Synchronization
import XCTest
@testable import CloudStream

/// Timeline thumbnails: bucketing, the native frame conversion, and (gated
/// like the other engine tests) the headless decoder on a real file.
@MainActor
final class ScrubPreviewTests: XCTestCase {
    func testBucketIntervalScalesWithDuration() {
        XCTAssertEqual(ScrubPreviewStore.bucketInterval(forDuration: 24 * 60), 5)
        XCTAssertEqual(ScrubPreviewStore.bucketInterval(forDuration: 2 * 3600), 24)
        XCTAssertEqual(ScrubPreviewStore.bucketInterval(forDuration: 30), 2)
        XCTAssertEqual(ScrubPreviewStore.bucketInterval(forDuration: .nan), 2)
        XCTAssertEqual(ScrubPreviewStore.bucketInterval(forDuration: 0), 2)
    }

    func testKeysFloorAndRejectUntrustedNumbers() {
        XCTAssertEqual(ScrubPreviewStore.key(for: 9.9, interval: 5), 1)
        XCTAssertEqual(ScrubPreviewStore.key(for: 10, interval: 5), 2)
        XCTAssertEqual(ScrubPreviewStore.key(for: -3, interval: 5), 0)
        XCTAssertEqual(ScrubPreviewStore.key(for: .infinity, interval: 5), 0)
        XCTAssertEqual(ScrubPreviewStore.key(for: 1e300, interval: 1), Int(Int32.max))
    }

    func testNearestKey() {
        XCTAssertEqual(ScrubPreviewStore.nearestKey(to: 10, in: [1, 8, 14]), 8)
        XCTAssertNil(ScrubPreviewStore.nearestKey(to: 10, in: [Int]()))
    }

    func testBGR0ConversionKeepsChannelOrder() throws {
        // One row of two pixels: pure red, then pure blue (bytes B, G, R, X).
        let bytes: [UInt8] = [0, 0, 255, 0, 255, 0, 0, 0]
        let image = try XCTUnwrap(bytes.withUnsafeBytes {
            ScrubPreviewDecoder.image(bgr0: $0, width: 2, height: 1, stride: 8)
        })
        XCTAssertEqual(image.width, 2)
        let pixels = try rgba(image)
        XCTAssertEqual(Array(pixels[0..<3]), [255, 0, 0])
        XCTAssertEqual(Array(pixels[4..<7]), [0, 0, 255])
    }

    func testBGR0ConversionRejectsShortOrOversizedBuffers() {
        let bytes = [UInt8](repeating: 0, count: 16)
        bytes.withUnsafeBytes { buffer in
            XCTAssertNil(ScrubPreviewDecoder.image(bgr0: buffer, width: 2, height: 4, stride: 8))
            XCTAssertNil(ScrubPreviewDecoder.image(bgr0: buffer, width: 4, height: 1, stride: 8))
            XCTAssertNil(ScrubPreviewDecoder.image(bgr0: buffer, width: 0, height: 1, stride: 8))
            XCTAssertNil(ScrubPreviewDecoder.image(bgr0: buffer, width: 5000, height: 1, stride: 20000))
        }
    }

    func testStoreWithoutSourceIsUnavailable() {
        let store = ScrubPreviewStore()
        XCTAssertFalse(store.isAvailable)
        store.preview(at: 10, duration: 100)
        XCTAssertNil(store.image)
    }

    func testDecoderRunsWithThePlaybackResourceBoundary() {
        let names = Set(ScrubPreviewDecoder.options.map(\.0))
        for required in ["config", "load-scripts", "autoload-files", "load-unsafe-playlists", "demuxer-lavf-o", "stream-lavf-o"] {
            XCTAssertTrue(names.contains(required), required)
        }
        XCTAssertTrue(ScrubPreviewDecoder.options.contains { $0 == ("vo", "null") })
        XCTAssertTrue(ScrubPreviewDecoder.options.contains { $0 == ("audio", "no") })
    }

    // MARK: - Live engine

    /// White top half, black bottom half (scripts/make_player_fixtures.sh).
    private static let fixture = "/tmp/test_orientation.mp4"

    func testStoreDecodesFramesFromALocalFile() async throws {
        guard ProcessInfo.processInfo.environment["CS_MPV_ENGINE_TESTS"] == "1" else {
            throw XCTSkip("Set CS_MPV_ENGINE_TESTS=1 to run live mpv engine tests")
        }
        guard FileManager.default.fileExists(atPath: Self.fixture) else { throw XCTSkip("Missing fixture \(Self.fixture)") }
        let store = ScrubPreviewStore()
        defer { store.shutdown() }
        store.configure(source: ScrubPreviewSource(id: 1, resource: try .authorizedLocal(URL(fileURLWithPath: Self.fixture)), headers: [:]))
        XCTAssertTrue(store.isAvailable)
        store.preview(at: 1, duration: 3)

        let deadline = ContinuousClock.now + .seconds(15)
        while store.image == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let image = try XCTUnwrap(store.image, "no preview frame within 15 s")
        XCTAssertEqual(image.width, ScrubPreviewDecoder.frameWidth)
        XCTAssertEqual(image.height, ScrubPreviewDecoder.frameWidth * 9 / 16)
        let pixels = try rgba(image)
        let top = Int(pixels[(image.height / 4 * image.width + image.width / 2) * 4])
        let bottom = Int(pixels[(image.height * 3 / 4 * image.width + image.width / 2) * 4])
        XCTAssertGreaterThan(top, 200, "top half should be white (not flipped)")
        XCTAssertLessThan(bottom, 50, "bottom half should be black")
    }

    func testFramesForAReplacedSourceAreDropped() async throws {
        guard ProcessInfo.processInfo.environment["CS_MPV_ENGINE_TESTS"] == "1" else {
            throw XCTSkip("Set CS_MPV_ENGINE_TESTS=1 to run live mpv engine tests")
        }
        guard FileManager.default.fileExists(atPath: Self.fixture) else { throw XCTSkip("Missing fixture \(Self.fixture)") }
        let store = ScrubPreviewStore()
        defer { store.shutdown() }
        store.configure(source: ScrubPreviewSource(id: 1, resource: try .authorizedLocal(URL(fileURLWithPath: Self.fixture)), headers: [:]))
        store.preview(at: 1, duration: 3)
        store.configure(source: nil)
        try await Task.sleep(for: .seconds(2))
        XCTAssertNil(store.image)
        XCTAssertFalse(store.isAvailable)
    }

    func testIdleDecoderReleasesItsEngineAndReopensOnTheNextRequest() async throws {
        guard ProcessInfo.processInfo.environment["CS_MPV_ENGINE_TESTS"] == "1" else {
            throw XCTSkip("Set CS_MPV_ENGINE_TESTS=1 to run live mpv engine tests")
        }
        guard FileManager.default.fileExists(atPath: Self.fixture) else { throw XCTSkip("Missing fixture \(Self.fixture)") }
        let frames = Mutex(0)
        let decoder = ScrubPreviewDecoder(idleRelease: 0.5) { _, _, _ in frames.withLock { $0 += 1 } }
        defer { decoder.close() }
        decoder.setSource(ScrubPreviewSource(id: 1, resource: try .authorizedLocal(URL(fileURLWithPath: Self.fixture)), headers: [:]))

        func waitForFrames(_ count: Int) async throws {
            let deadline = ContinuousClock.now + .seconds(15)
            while frames.withLock({ $0 }) < count, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
            XCTAssertGreaterThanOrEqual(frames.withLock { $0 }, count, "no preview frame within 15 s")
        }
        decoder.request(key: 0, seconds: 1)
        try await waitForFrames(1)
        XCTAssertTrue(decoder.hasEngine, "the engine stays open while previews are in use")

        try await Task.sleep(for: .seconds(1.5))
        XCTAssertFalse(decoder.hasEngine, "an idle decoder holds no engine, stream or hardware decoder")

        decoder.request(key: 1, seconds: 2)
        try await waitForFrames(2)
    }

    private func rgba(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drawn else { throw XCTSkip("no bitmap context") }
        return pixels
    }
}
