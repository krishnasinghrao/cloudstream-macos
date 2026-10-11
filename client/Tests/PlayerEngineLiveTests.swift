import AppKit
import XCTest
@testable import CloudStream

/// Live libmpv pipeline checks for Player-Remediation-Plan (A1, R1–R4, T1,
/// T4, T9). Gated like the other engine tests: set CS_MPV_ENGINE_TESTS=1 and
/// provide /tmp/test_stereo.mp4 (a few seconds of H.264 + AAC), e.g.
///   ffmpeg -f lavfi -i testsrc2=size=1280x720:rate=30 -f lavfi -i sine \
///          -t 4 -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest /tmp/test_stereo.mp4
@MainActor
final class PlayerEngineLiveTests: XCTestCase {
    private static let fixture = "/tmp/test_stereo.mp4"

    private var window: NSWindow?
    private var view: MetalVideoView?

    private func requireEngine() throws {
        guard ProcessInfo.processInfo.environment["CS_MPV_ENGINE_TESTS"] == "1" else {
            throw XCTSkip("Set CS_MPV_ENGINE_TESTS=1 to run live mpv engine tests")
        }
        guard FileManager.default.fileExists(atPath: Self.fixture) else {
            throw XCTSkip("Missing fixture \(Self.fixture)")
        }
    }

    /// Hosts the view in an on-screen window so the display link and
    /// occlusion state behave as in the app.
    private func makeHostedView(width: CGFloat = 640, height: CGFloat = 360) -> MetalVideoView {
        let view = MetalVideoView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: width, height: height),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false,
        )
        window.isReleasedWhenClosed = false
        // Keep the window unoccluded: an occluded window intentionally skips
        // rasterization (R4), which would make frame counting meaningless.
        window.level = .floating
        window.contentView = view
        window.orderFrontRegardless()
        self.window = window
        self.view = view
        return view
    }

    override func tearDown() async throws {
        view?.shutdown()
        window?.close()
        view = nil
        window = nil
        // Let the off-main teardown chain finish before the next test.
        try await Task.sleep(for: .milliseconds(300))
    }

    func testPlaybackAdvancesAndReportsVideoSize() async throws {
        try requireEngine()
        let view = makeHostedView()
        var positions: [Double] = []
        var width: Int64 = 0
        var restarted = false
        view.onPropertyChange = { name, value in
            switch name {
            case "time-pos": if let time = value.doubleValue { positions.append(time) }
            case "dwidth": width = value.int64Value ?? 0
            default: break
            }
        }
        view.onPlaybackRestart = { restarted = true }

        view.setup(resource: try .authorizedLocal(URL(fileURLWithPath: Self.fixture)), headers: [:], subtitles: [], audioTracks: [], startAt: nil)
        XCTAssertTrue(view.isInitialized)

        try await waitUntil(timeout: 5) { restarted && (positions.last ?? 0) > 1.0 }
        XCTAssertTrue(restarted, "FILE_LOADED / PLAYBACK_RESTART must reach the main actor")
        XCTAssertGreaterThan(positions.last ?? 0, 1.0, "Frames must be consumed for the clock to advance")
        XCTAssertEqual(width, 1280, "dwidth drives native-resolution rendering (A1)")
        XCTAssertEqual(positions, positions.sorted(), "Events are delivered in order (T6)")

        // R1/R2: frames reach the drawable at (close to) the source rate —
        // 30 fps fixture, measured over one second of steady playback.
        let before = view.presentedFrameCount
        try await Task.sleep(for: .seconds(1))
        let presented = view.presentedFrameCount - before
        let visible = window?.occlusionState.contains(.visible) ?? false
        XCTAssertGreaterThanOrEqual(presented, 24, "Display-link pacing must present ~30 frames/s (got \(presented), window visible: \(visible))")
        XCTAssertLessThanOrEqual(presented, 40, "Frames are presented only when mpv has a new one (R3) (got \(presented))")
    }

    /// Audit A36: command outcomes come back from the real engine, tagged.
    /// Latest rendered frame, sampled as BGRA at fractional positions.
    private final class FrameProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var latest: CVPixelBuffer?
        func store(_ buffer: CVPixelBuffer) { lock.withLock { latest = buffer } }
        var hasFrame: Bool { lock.withLock { latest != nil } }
        /// (blue, green, red) at (x, y) in 0...1, top-left origin.
        func pixel(x: Double, y: Double) -> (Int, Int, Int)? {
            guard let buffer = lock.withLock({ latest }) else { return nil }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
            let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
            let row = min(height - 1, Int(Double(height) * y)), column = min(width - 1, Int(Double(width) * x))
            let pointer = base.advanced(by: row * CVPixelBufferGetBytesPerRow(buffer) + column * 4).assumingMemoryBound(to: UInt8.self)
            return (Int(pointer[0]), Int(pointer[1]), Int(pointer[2]))
        }
    }

    private func renderedFrame(of fixture: String, software: Bool = false,
                               size: CGSize = CGSize(width: 640, height: 360)) async throws -> (MetalVideoView, FrameProbe) {
        guard FileManager.default.fileExists(atPath: fixture) else { throw XCTSkip("Missing fixture \(fixture)") }
        if software { setenv("CS_PLAYER_RENDERER", "sw", 1) }
        defer { if software { unsetenv("CS_PLAYER_RENDERER") } }
        let view = makeHostedView(width: size.width, height: size.height)
        let probe = FrameProbe()
        view.renderedFrameObserverForTesting = { probe.store($0) }
        var restarted = false
        view.onPlaybackRestart = { restarted = true }
        view.setup(resource: try .authorizedLocal(URL(fileURLWithPath: fixture)), headers: [:], subtitles: [], audioTracks: [], startAt: nil)
        try await waitUntil(timeout: 5) { restarted && probe.hasFrame }
        try await Task.sleep(for: .milliseconds(400)) // a steady frame, not the first
        return (view, probe)
    }

    /// GPU path (default): zero-copy VideoToolbox decode, upright output.
    /// /tmp/test_orientation.mp4: white top half, black bottom half.
    func testGPURendererDecodesWithVideoToolboxAndRendersUpright() async throws {
        try requireEngine()
        let (view, probe) = try await renderedFrame(of: "/tmp/test_orientation.mp4")
        XCTAssertEqual(view.rendererName, "gpu")
        XCTAssertEqual(view.diagnosticProperty("hwdec-current"), "videotoolbox")
        let top = try XCTUnwrap(probe.pixel(x: 0.5, y: 0.25)), bottom = try XCTUnwrap(probe.pixel(x: 0.5, y: 0.75))
        XCTAssertGreaterThan(top.1, 200, "top half is white: \(top)")
        XCTAssertLessThan(bottom.1, 60, "bottom half is black: \(bottom)")
    }

    func testSoftwareFallbackStillRendersUpright() async throws {
        try requireEngine()
        let (view, probe) = try await renderedFrame(of: "/tmp/test_orientation.mp4", software: true)
        XCTAssertEqual(view.rendererName, "software")
        let top = try XCTUnwrap(probe.pixel(x: 0.5, y: 0.25)), bottom = try XCTUnwrap(probe.pixel(x: 0.5, y: 0.75))
        XCTAssertGreaterThan(top.1, 200, "\(top)")
        XCTAssertLessThan(bottom.1, 60, "\(bottom)")
    }

    /// The pale-4K cause: an HDR10 (BT.2020, PQ) frame shown without
    /// conversion. /tmp/test_hdr10.mp4 is a mid-grey PQ signal (~92 nits);
    /// tone-mapped to SDR (reference white 203 nits) it is a light grey
    /// (sRGB ~0.7), while the raw signal reads as a flat mid grey (~0.5).
    func testHDR10IsToneMappedToSDROnTheGPUPath() async throws {
        try requireEngine()
        let (gpuView, gpu) = try await renderedFrame(of: "/tmp/test_hdr10.mp4")
        XCTAssertEqual(gpuView.diagnosticProperty("video-params/gamma"), "pq")
        XCTAssertEqual(gpuView.diagnosticProperty("video-params/primaries"), "bt.2020")
        let mapped = try XCTUnwrap(gpu.pixel(x: 0.5, y: 0.5))
        gpuView.shutdown()
        try await Task.sleep(for: .milliseconds(300))
        let (_, software) = try await renderedFrame(of: "/tmp/test_hdr10.mp4", software: true)
        let raw = try XCTUnwrap(software.pixel(x: 0.5, y: 0.5))
        print("HDR10 mid-grey: GPU \(mapped), software \(raw)")
        XCTAssertGreaterThan(mapped.1, 150, "tone-mapped PQ grey: \(mapped)")
        XCTAssertGreaterThan(mapped.1, raw.1 + 20, "the GPU path converts PQ instead of showing the raw signal (\(mapped) vs \(raw))")
    }

    /// Section 4/5 measurement: CPU time per second of 4K HDR10 playback on
    /// each renderer (/tmp/test_4k_hdr10.mp4: 3840×2160 HEVC Main10, PQ).
    func testFourKHDRPlaybackCostsLessCPUOnTheGPUPath() async throws {
        try requireEngine()
        let results = try await measurePlayback("/tmp/test_4k_hdr10.mp4", label: "4K HDR10")
        let gpu = try XCTUnwrap(results["gpu"]), software = try XCTUnwrap(results["software"])
        XCTAssertGreaterThanOrEqual(gpu.frames, 20, "the GPU path keeps up with 24 fps 4K")
        XCTAssertLessThan(gpu.cpu, software.cpu, "\(results)")
    }

    /// Section 4 measurement: the same for 1080p SDR (/tmp/test_1080p.mp4:
    /// 1920×1080 H.264 High, BT.709, 24 fps).
    func testFullHDPlaybackCost() async throws {
        try requireEngine()
        guard FileManager.default.fileExists(atPath: "/tmp/test_1080p.mp4") else { throw XCTSkip("/tmp/test_1080p.mp4 missing") }
        let results = try await measurePlayback("/tmp/test_1080p.mp4", label: "1080p SDR")
        let gpu = try XCTUnwrap(results["gpu"])
        XCTAssertGreaterThanOrEqual(gpu.frames, 20, "the GPU path keeps up with 24 fps 1080p")
    }

    /// Plays `path` for 3 s on each renderer in a full-screen-sized view and
    /// returns CPU seconds per second and frames per second by renderer.
    private func measurePlayback(_ path: String, label: String) async throws -> [String: (cpu: Double, frames: Int)] {
        func cpuSeconds() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        func footprintMB() -> Double {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
            }
            return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
        }
        let baseline = footprintMB()
        var results: [String: (cpu: Double, frames: Int)] = [:]
        for software in [false, true] {
            // A full-screen-sized window: what the renderers really pay for.
            let (view, _) = try await renderedFrame(of: path, software: software, size: CGSize(width: 1728, height: 972))
            XCTAssertEqual(view.diagnosticProperty("hwdec-current"), software ? "videotoolbox-copy" : "videotoolbox")
            let startCPU = cpuSeconds(), startFrames = view.presentedFrameCount
            try await Task.sleep(for: .seconds(3))
            results[view.rendererName] = ((cpuSeconds() - startCPU) / 3, (view.presentedFrameCount - startFrames) / 3)
            print("\(label) playback (\(view.rendererName)): footprint \(Int(footprintMB())) MB, \(Int(footprintMB() - baseline)) MB above the idle test host")
            view.shutdown()
            try await Task.sleep(for: .milliseconds(300))
        }
        print("\(label) playback, CPU seconds per second (frames/s): \(results)")
        return results
    }

    /// Section 7 preload: a queued next file is not played by itself at the
    /// end (keep-open=always), and switching to it uses the prefetched entry.
    func testQueuedNextEpisodeWaitsForThePlayerAndSwitchesFast() async throws {
        try requireEngine()
        guard FileManager.default.fileExists(atPath: "/tmp/test_orientation.mp4") else { throw XCTSkip("Missing /tmp/test_orientation.mp4") }
        let view = makeHostedView()
        var width: Int64 = 0
        var ended = false
        var restarts = 0
        view.onPropertyChange = { name, value in if name == "dwidth" { width = value.int64Value ?? 0 } }
        view.onEndOfFile = { ended = true }
        view.onPlaybackRestart = { restarts += 1 }
        view.setup(resource: try .authorizedLocal(URL(fileURLWithPath: Self.fixture)), headers: [:], subtitles: [], audioTracks: [], startAt: nil)
        try await waitUntil(timeout: 5) { restarts > 0 && width == 1280 }
        view.queueNext(url: try PlaybackResource.authorizedLocal(URL(fileURLWithPath: "/tmp/test_orientation.mp4")).url)
        try await waitUntil(timeout: 8) { ended }
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(width, 1280, "the queued file must not start by itself")

        let before = restarts
        let started = ContinuousClock.now
        view.loadStream(resource: try .authorizedLocal(URL(fileURLWithPath: "/tmp/test_orientation.mp4")), headers: [:], startAt: nil, usesQueuedNext: true)
        try await waitUntil(timeout: 5) { restarts > before && width == 640 }
        print("Switch to the queued episode took \(ContinuousClock.now - started)")
    }

    /// RT-17: streams resolved by extensions in an engine worker (exported to
    /// /tmp/cs_live_links.json) through the app's own load plan and player.
    /// `scripts/run_full_client_tests.sh` provisions it with LocalMediaLinksTest:
    /// an Android-compiled extension in a sandboxed worker resolving links to a
    /// local CDN, every one of which must play. Links exported from real
    /// providers work the same way; there, at least one must play.
    /// Gated: CS_LIVE_PLAYBACK_TESTS=1. Writes /tmp/cs_live_playback.json.
    func testLiveExtensionStreamsReachTheirFirstFrame() async throws {
        try requireEngine()
        guard ProcessInfo.processInfo.environment["CS_LIVE_PLAYBACK_TESTS"] == "1",
              let data = FileManager.default.contents(atPath: "/tmp/cs_live_links.json") else {
            throw XCTSkip("Set CS_LIVE_PLAYBACK_TESTS=1 and export links to /tmp/cs_live_links.json")
        }
        struct Entry: Decodable { let provider: String; let link: StreamLinkDto }
        var rows: [[String: String]] = []
        for entry in try JSONDecoder().decode([Entry].self, from: data) {
            var row = ["provider": entry.provider, "name": entry.link.name, "quality": String(entry.link.quality)]
            defer { rows.append(row) }
            let plan: PlayerViewModel.LoadPlan
            do {
                try MediaResourcePolicy.validate(entry.link)
                plan = try PlayerViewModel.loadPlan(for: entry.link)
            } catch {
                row["outcome"] = "not loadable here: \(error.localizedDescription)"
                continue
            }
            let view = makeHostedView(width: 960, height: 540)
            var position = 0.0
            var failed = false
            var info = StreamInfo()
            view.onPropertyChange = { name, value in
                if name == "time-pos" { position = value.doubleValue ?? 0 }
                info.apply(name, value)
            }
            view.onPlaybackFailed = { failed = true }
            view.setup(resource: plan.resource, headers: entry.link.headers, subtitles: [],
                       audioTracks: try plan.audioTracks.map(PlaybackAudio.remote), startAt: nil)
            let started = ContinuousClock.now
            let deadline = started.advanced(by: .seconds(25))
            while ContinuousClock.now < deadline, !failed, !(position > 1 && view.presentedFrameCount > 10) {
                try await Task.sleep(for: .milliseconds(200))
            }
            if position > 1 && view.presentedFrameCount > 10 {
                info.renderer = view.rendererName
                row["outcome"] = "playing"
                row["firstSecondAfter"] = String(format: "%.1f s", Double((ContinuousClock.now - started) / .milliseconds(1)) / 1000)
                row["stream"] = info.summary
            } else {
                row["outcome"] = failed ? "failed to open" : "no frames within 25 s"
            }
            view.shutdown()
            window?.close()
            try await Task.sleep(for: .milliseconds(300))
        }
        let json = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: URL(fileURLWithPath: "/tmp/cs_live_playback.json"))
        let entries = try JSONDecoder().decode([Entry].self, from: data)
        if !entries.isEmpty, entries.allSatisfy({ $0.provider.hasSuffix(":LocalMediaProvider") }) {
            XCTAssertEqual(rows.count, entries.count)
            XCTAssertTrue(rows.allSatisfy { $0["outcome"] == "playing" }, "every link the local extension resolved plays: \(rows)")
        } else {
            XCTAssertTrue(rows.contains { $0["outcome"] == "playing" }, "at least one live extension stream plays: \(rows)")
        }
    }

    func testScreenshotAndSeekRepliesReportRealOutcomes() async throws {
        try requireEngine()
        let view = makeHostedView()
        var replies: [MpvCommandReply] = []
        var restarted = false
        view.onCommandReply = { replies.append($0) }
        view.onPlaybackRestart = { restarted = true }
        view.setup(resource: try .authorizedLocal(URL(fileURLWithPath: Self.fixture)), headers: [:], subtitles: [], audioTracks: [], startAt: nil)
        try await waitUntil(timeout: 5) { restarted }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let saved = directory.appendingPathComponent("frame.png")
        view.takeScreenshot(to: saved)
        try await waitUntil(timeout: 5) { replies.contains { $0.kind == .screenshot } }
        let success = try XCTUnwrap(replies.first { $0.kind == .screenshot })
        XCTAssertNil(success.error)
        XCTAssertEqual(success.url, saved)
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path), "the reply follows the written file")

        // A destination that cannot be written is reported as a failure.
        replies.removeAll()
        let refused = directory.appendingPathComponent("missing-folder/frame.png")
        view.takeScreenshot(to: refused)
        try await waitUntil(timeout: 5) { replies.contains { $0.kind == .screenshot } }
        let failure = try XCTUnwrap(replies.first { $0.kind == .screenshot })
        XCTAssertNotNil(failure.error)
        XCTAssertEqual(failure.url, refused)
        XCTAssertFalse(FileManager.default.fileExists(atPath: refused.path))

        // An ordinary seek succeeds and is not reported as a failure.
        replies.removeAll()
        view.seek(to: 1.5)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(replies.contains { $0.error != nil }, "\(replies)")
        XCTAssertTrue(replies.contains { $0.kind == .seek && $0.error == nil })
    }

    func testEngineThatCannotStartReportsEngineFailureNotAFailedMirror() async throws {
        try requireEngine()
        let view = makeHostedView()
        var engineFailures: [String] = [], playbackFailures = 0
        view.onEngineFailed = { engineFailures.append($0) }
        view.onPlaybackFailed = { playbackFailures += 1 }
        // The core reports an initialization error (this build rejects bad
        // option values when they are set, so the status is injected).
        MetalVideoView.initializationFaultForTesting = MPV_ERROR_INVALID_PARAMETER.rawValue
        defer { MetalVideoView.initializationFaultForTesting = nil }
        view.setup(resource: try .authorizedLocal(URL(fileURLWithPath: Self.fixture)), headers: [:], subtitles: [], audioTracks: [], startAt: nil)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(view.isInitialized)
        XCTAssertEqual(engineFailures.count, 1)
        XCTAssertEqual(playbackFailures, 0)
    }

    func testStartOptionOpensAtResumePoint() async throws {
        try requireEngine()
        let view = makeHostedView()
        var firstPosition: Double?
        view.onPropertyChange = { name, value in
            if name == "time-pos", firstPosition == nil, let time = value.doubleValue, time > 0 {
                firstPosition = time
            }
        }
        view.setup(resource: try .authorizedLocal(URL(fileURLWithPath: Self.fixture)), headers: [:], subtitles: [], audioTracks: [], startAt: 2.5)
        try await waitUntil(timeout: 5) { firstPosition != nil }
        XCTAssertGreaterThanOrEqual(firstPosition ?? 0, 2.0, "loadfile start= must open at the resume point, not 0:00 (T9)")
    }

    func testEndOfFileFiresOnceUnderKeepOpen() async throws {
        try requireEngine()
        let view = makeHostedView()
        var eofCount = 0
        view.onEndOfFile = { eofCount += 1 }
        view.setup(resource: try .authorizedLocal(URL(fileURLWithPath: Self.fixture)), headers: [:], subtitles: [], audioTracks: [], startAt: 3.0)
        try await waitUntil(timeout: 6) { eofCount > 0 }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(eofCount, 1, "keep-open=yes suppresses END_FILE(eof); eof-reached must fire exactly once (T4)")
    }

    func testLoadStreamReplacesWithoutStaleFailure() async throws {
        try requireEngine()
        let view = makeHostedView()
        var failures = 0
        var restarts = 0
        view.onPlaybackFailed = { failures += 1 }
        view.onPlaybackRestart = { restarts += 1 }
        view.setup(resource: try .authorizedLocal(URL(fileURLWithPath: Self.fixture)), headers: ["Referer": "https://a.example/"], subtitles: [], audioTracks: [], startAt: nil)
        try await waitUntil(timeout: 5) { restarts > 0 }

        view.loadStream(resource: try .authorizedLocal(URL(fileURLWithPath: Self.fixture)), headers: [:], startAt: 1.0)
        try await waitUntil(timeout: 5) { restarts > 1 }
        XCTAssertEqual(failures, 0, "Replacing a file must not surface a failover (T6)")
    }

    func testTransportCallsNeverBlockTheMainThread() async throws {
        try requireEngine()
        let view = makeHostedView()
        var restarted = false
        view.onPlaybackRestart = { restarted = true }
        view.setup(resource: try .authorizedLocal(URL(fileURLWithPath: Self.fixture)), headers: [:], subtitles: [], audioTracks: [], startAt: nil)
        try await waitUntil(timeout: 5) { restarted }

        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for index in 0..<50 {
                view.seek(to: Double(index % 3))
                view.setPlaying(index.isMultiple(of: 2))
                view.setVolume(Double(index))
                view.togglePlayPause()
            }
        }
        XCTAssertLessThan(elapsed, .milliseconds(50), "200 async commands must not wait on the playback core (T1)")
    }

    func testShutdownReturnsImmediately() async throws {
        try requireEngine()
        let view = makeHostedView()
        var restarted = false
        view.onPlaybackRestart = { restarted = true }
        view.setup(resource: try .authorizedLocal(URL(fileURLWithPath: Self.fixture)), headers: [:], subtitles: [], audioTracks: [], startAt: nil)
        try await waitUntil(timeout: 5) { restarted }

        let clock = ContinuousClock()
        let elapsed = clock.measure { view.shutdown() }
        XCTAssertFalse(view.isInitialized)
        XCTAssertLessThan(elapsed, .milliseconds(20), "mpv_terminate_destroy must run off the main thread (T1)")
        view.shutdown() // idempotent
    }

    func testRenderTeardownAndReplacementGenerationStayIndependent() async throws {
        try requireEngine()
        let view = makeHostedView()
        for generation in 0..<12 {
            view.setup(resource: try .authorizedLocal(URL(fileURLWithPath: Self.fixture)), headers: [:], subtitles: [], audioTracks: [], startAt: nil)
            XCTAssertTrue(view.isInitialized)
            let before = view.presentedFrameCount
            try await waitUntil(timeout: 5) { view.presentedFrameCount > before }
            // Resize with frames in flight, replace the load, then reuse the
            // same view before its previous off-main destroy has completed.
            window?.setContentSize(NSSize(width: 640 + generation * 7, height: 360 + generation * 4))
            view.loadStream(resource: try .authorizedLocal(URL(fileURLWithPath: Self.fixture)), headers: [:], startAt: 0.5)
            await Task.yield()
            view.shutdown()
            view.shutdown()
            XCTAssertFalse(view.isInitialized)
        }
        view.setup(resource: try .authorizedLocal(URL(fileURLWithPath: Self.fixture)), headers: [:], subtitles: [], audioTracks: [], startAt: nil)
        let before = view.presentedFrameCount
        try await waitUntil(timeout: 5) { view.presentedFrameCount > before }
        XCTAssertTrue(view.isInitialized, "Old cleanup must not invalidate the replacement generation")
    }

    func testSetupOptionsAreAllAccepted() async throws {
        try requireEngine()
        let view = makeHostedView()
        view.setup(resource: try .authorizedLocal(URL(fileURLWithPath: Self.fixture)), headers: [:], subtitles: [], audioTracks: [], startAt: nil)
        XCTAssertEqual(view.rejectedOptions, [], "mpv silently ignores unknown options — every one must apply")
    }

    /// T7/T8 on the wire: Referer (mpv option `referrer`), User-Agent, and a
    /// comma-containing header reach the server; a later load without headers
    /// must not inherit them. Serves the fixture from a local header-logging
    /// HTTP server.
    func testRequestHeadersReachTheServerAndDoNotLeak() async throws {
        try requireEngine()
        let server = try HeaderLoggingServer(directory: "/tmp")
        defer { server.stop() }
        let url = "http://127.0.0.1:\(server.port)/test_stereo.mp4"

        let view = makeHostedView()
        var restarts = 0
        var failures = 0
        view.onPlaybackRestart = { restarts += 1 }
        view.onPlaybackFailed = { failures += 1 }
        view.setup(
            streamURL: url,
            headers: [
                "Referer": "https://ref.example/",
                "User-Agent": "Mozilla/5.0 (KHTML, like Gecko) CSTest",
                "X-Custom": "a, b",
            ],
            subtitles: [],
            audioTracks: [],
            startAt: nil,
        )
        try await waitUntil(timeout: 5) { restarts > 0 || failures > 0 }
        XCTAssertEqual(failures, 0)
        let first = try XCTUnwrap(server.requests().first, "server saw no request")
        XCTAssertEqual(first["Referer"], "https://ref.example/", "Referer must be sent — its absence 403s protected CDNs")
        XCTAssertEqual(first["User-Agent"], "Mozilla/5.0 (KHTML, like Gecko) CSTest")
        XCTAssertEqual(first["X-Custom"], "a, b", "commas inside a header value must survive")

        let before = server.requests().count
        view.loadStream(url: url, headers: [:], startAt: nil)
        try await waitUntil(timeout: 5) { server.requests().count > before }
        let second = try XCTUnwrap(server.requests().dropFirst(before).first, "no request for the second load")
        XCTAssertNil(second["Referer"], "Referer leaked into a load without headers")
        XCTAssertNil(second["X-Custom"], "custom header leaked into a load without headers")
        XCTAssertNotEqual(second["User-Agent"], "Mozilla/5.0 (KHTML, like Gecko) CSTest", "User-Agent leaked")
    }

    /// Plan RT-17: most extensions return HLS. A segmented stream with a caption plays, seeks, and its
    /// segment requests — not only the playlist — carry the headers the provider required.
    func testHlsStreamPlaysSeeksAndSendsHeadersOnSegments() async throws {
        try requireEngine()
        let ffmpeg = ProcessInfo.processInfo.environment["CS_FIXTURE_FFMPEG"] ?? "/opt/homebrew/bin/ffmpeg"
        guard FileManager.default.isExecutableFile(atPath: ffmpeg) else { throw XCTSkip("ffmpeg not available to build the HLS fixture") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cs-hls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let segmenter = Process()
        segmenter.executableURL = URL(fileURLWithPath: ffmpeg)
        segmenter.arguments = ["-hide_banner", "-loglevel", "error", "-y", "-i", Self.fixture, "-c", "copy", "-f", "hls",
                               "-hls_time", "1", "-hls_playlist_type", "vod",
                               "-hls_segment_filename", directory.appendingPathComponent("seg%02d.ts").path,
                               directory.appendingPathComponent("master.m3u8").path]
        try segmenter.run()
        segmenter.waitUntilExit()
        guard segmenter.terminationStatus == 0 else { throw XCTSkip("HLS fixture generation failed") }
        try "WEBVTT\n\n00:00:00.000 --> 00:00:04.000\nFixture caption\n".write(
            to: directory.appendingPathComponent("en.vtt"), atomically: true, encoding: .utf8)

        let server = try HeaderLoggingServer(directory: directory.path)
        defer { server.stop() }
        let base = "http://127.0.0.1:\(server.port)"

        let view = makeHostedView()
        var positions: [Double] = []
        var width: Int64 = 0
        var restarts = 0
        var failures = 0
        view.onPropertyChange = { name, value in
            switch name {
            case "time-pos": if let time = value.doubleValue { positions.append(time) }
            case "dwidth": width = value.int64Value ?? 0
            default: break
            }
        }
        view.onPlaybackRestart = { restarts += 1 }
        view.onPlaybackFailed = { failures += 1 }
        view.setup(streamURL: "\(base)/master.m3u8", headers: ["Referer": "https://ref.example/"],
                   subtitles: [SubtitleDto(url: "\(base)/en.vtt", language: "en", label: "English", mimeType: "text/vtt")],
                   audioTracks: [], startAt: nil)

        try await waitUntil(timeout: 10) { failures > 0 || (restarts > 0 && (positions.last ?? 0) > 1.0) }
        XCTAssertEqual(failures, 0)
        XCTAssertGreaterThan(positions.last ?? 0, 1.0, "HLS segments are fetched and decoded")
        XCTAssertEqual(width, 1280)

        positions.removeAll()
        view.seek(to: 3.0)
        try await waitUntil(timeout: 5) { (positions.last ?? 0) >= 3.0 }
        XCTAssertGreaterThanOrEqual(positions.last ?? 0, 3.0, "seeking within the HLS stream lands at the requested time")

        let requests = server.requests()
        XCTAssertGreaterThan(requests.count, 2, "playlist and segments were requested over HTTP")
        XCTAssertTrue(requests.allSatisfy { $0["Referer"] == "https://ref.example/" },
                      "every request, including segments and the caption, carries the required Referer")
        XCTAssertTrue(requests.allSatisfy { $0["_repeated"] == "" }, "no header is sent twice: \(requests)")
        XCTAssertEqual(Set(requests.compactMap { $0["User-Agent"] }).count, 1, "one User-Agent on every request")
    }

    /// Remediation 3.3: the DASH demuxer opens each segment through its own
    /// nested HTTP context; the stream's request headers must reach those too.
    func testDashStreamSendsHeadersOnEverySegment() async throws {
        try requireEngine()
        let ffmpeg = ProcessInfo.processInfo.environment["CS_FIXTURE_FFMPEG"] ?? "/opt/homebrew/bin/ffmpeg"
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: ffmpeg), "ffmpeg builds the DASH fixture")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cs-dash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let packager = Process()
        packager.executableURL = URL(fileURLWithPath: ffmpeg)
        // One-second keyframes, so the manifest names several media segments per stream.
        packager.arguments = ["-hide_banner", "-loglevel", "error", "-y", "-i", Self.fixture,
                              "-c:v", "libx264", "-preset", "ultrafast", "-g", "30", "-keyint_min", "30", "-sc_threshold", "0",
                              "-c:a", "copy", "-f", "dash", "-seg_duration", "1", "-use_template", "1", "-use_timeline", "1",
                              directory.appendingPathComponent("manifest.mpd").path]
        try packager.run()
        packager.waitUntilExit()
        XCTAssertEqual(packager.terminationStatus, 0, "DASH fixture generation")
        let segments = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".m4s") }
        XCTAssertGreaterThan(segments.count, 2, "the manifest names separate media segments")

        let server = try HeaderLoggingServer(directory: directory.path)
        defer { server.stop() }
        let view = makeHostedView()
        var positions: [Double] = []
        var failures = 0
        view.onPropertyChange = { name, value in
            if name == "time-pos", let time = value.doubleValue { positions.append(time) }
        }
        view.onPlaybackFailed = { failures += 1 }
        view.setup(streamURL: "http://127.0.0.1:\(server.port)/manifest.mpd",
                   headers: ["Referer": "https://ref.example/", "X-Stream-Key": "dash-fixture"],
                   subtitles: [], audioTracks: [], startAt: nil)
        try await waitUntil(timeout: 15) { failures > 0 || (positions.last ?? 0) > 1.5 }
        XCTAssertEqual(failures, 0)
        XCTAssertGreaterThan(positions.last ?? 0, 1.5,
            "DASH segments are fetched and decoded (positions: \(positions.suffix(5)), requested: \(server.requests().compactMap { $0["_path"] }))")
        let requests = server.requests()
        XCTAssertGreaterThan(requests.count, 3, "the manifest, the initialization and media segments were requested")
        XCTAssertTrue(requests.allSatisfy { $0["Referer"] == "https://ref.example/" }, "every DASH request carries the Referer: \(requests)")
        XCTAssertTrue(requests.allSatisfy { $0["X-Stream-Key"] == "dash-fixture" }, "and the stream's other headers")
        XCTAssertTrue(requests.allSatisfy { $0["_repeated"] == "" }, "no header is sent twice: \(requests)")
    }

    private func waitUntil(timeout: TimeInterval, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func testValidatedGeneratedPlaylistAndSplitAudioStillPlay() async throws {
        try requireEngine()
        let encoder = ProcessInfo.processInfo.environment["CS_FIXTURE_FFMPEG"] ?? "/opt/homebrew/bin/ffmpeg"
        guard FileManager.default.isExecutableFile(atPath: encoder) else { throw XCTSkip("ffmpeg required for split-media fixtures") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("generated-playback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("video.mp4")
        let audio = directory.appendingPathComponent("audio.m4a")
        let encoderProcess = Process()
        encoderProcess.executableURL = URL(fileURLWithPath: encoder)
        encoderProcess.arguments = ["-hide_banner", "-loglevel", "error", "-y", "-i", Self.fixture,
            "-map", "0:v:0", "-an", "-c", "copy", video.path,
            "-map", "0:a:0", "-vn", "-c", "copy", audio.path]
        try encoderProcess.run()
        encoderProcess.waitUntilExit()
        XCTAssertEqual(encoderProcess.terminationStatus, 0)
        let server = try RangeHTTPServer()
        server.set("/muxed.mp4", .init(body: try Data(contentsOf: URL(fileURLWithPath: Self.fixture)), contentType: "video/mp4"))
        server.set("/video.mp4", .init(body: try Data(contentsOf: video), contentType: "video/mp4"))
        server.set("/audio.m4a", .init(body: try Data(contentsOf: audio), contentType: "audio/mp4"))
        let view = makeHostedView()
        var position = 0.0
        var failed = false
        var tracks: [MpvTrack] = []
        view.onPropertyChange = { name, value in
            if name == "time-pos", let time = value.doubleValue { position = max(position, time) }
        }
        view.onPlaybackFailed = { failed = true }
        view.onTracksChanged = { tracks = $0 }
        let playlist = try PlaybackResource.playlist([server.url("/muxed.mp4"), server.url("/muxed.mp4")])
        view.setup(resource: playlist, headers: [:], subtitles: [], startAt: nil)
        try await waitUntil(timeout: 8) { failed || position > 0.5 }
        XCTAssertFalse(failed)
        XCTAssertGreaterThan(position, 0.5, "Validated playlist EDL must decode under protocol confinement")

        position = 0
        tracks = []
        let split = try PlaybackResource.split(video: server.url("/video.mp4"), orderedAudio: [
            .init(url: server.url("/audio.m4a"), label: "AAC 128", language: "en"),
            .init(url: server.url("/audio.m4a"), label: "AAC; !new_stream,file:///unopened-sentinel", language: "en"),
        ])
        view.loadStream(resource: split, headers: [:], subtitles: [], audioTracks: [], startAt: nil)
        try await waitUntil(timeout: 8) { failed || position > 0.5 && tracks.filter { $0.type == "audio" }.count == 2 }
        XCTAssertFalse(failed)
        XCTAssertGreaterThan(position, 0.5)
        XCTAssertEqual(tracks.filter { $0.type == "audio" }.count, 2, "Eager and lazy audio survive the validated builder")
        XCTAssertTrue(tracks.contains { $0.title == "AAC; !new_stream,file:///unopened-sentinel" }, "Metadata is literal, not EDL syntax")
    }

    func testRemoteManifestsAndRedirectCannotOpenLocalMediaButValidHLSStillPlays() async throws {
        try requireEngine()
        let encoder = ProcessInfo.processInfo.environment["CS_FIXTURE_FFMPEG"] ?? "/opt/homebrew/bin/ffmpeg"
        guard FileManager.default.isExecutableFile(atPath: encoder) else { throw XCTSkip("ffmpeg required for a valid TS sentinel") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("native-boundary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sentinel = directory.appendingPathComponent("sentinel.ts")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: encoder)
        process.arguments = ["-hide_banner", "-loglevel", "error", "-y", "-i", Self.fixture, "-c", "copy", "-f", "mpegts", sentinel.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let server = try RangeHTTPServer()
        server.set("/sentinel.ts", .init(body: try Data(contentsOf: sentinel), contentType: "video/mp2t"))
        let prefix = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:4\n#EXT-X-MEDIA-SEQUENCE:0\n#EXTINF:4.0,\n"
        let suffix = "\n#EXT-X-ENDLIST\n"
        server.set("/control.m3u8", .init(body: Data((prefix + server.url("/sentinel.ts") + suffix).utf8), contentType: "application/vnd.apple.mpegurl"))
        let view = makeHostedView()
        var failed = false
        var position = 0.0
        view.onPlaybackFailed = { failed = true }
        view.onPropertyChange = { name, value in
            if name == "time-pos", let time = value.doubleValue { position = max(position, time) }
        }
        view.setup(streamURL: server.url("/control.m3u8"), headers: [:], subtitles: [], startAt: nil)
        try await waitUntil(timeout: 8) { failed || position > 0.5 }
        XCTAssertFalse(failed, "Protocol restrictions must preserve valid HLS")
        XCTAssertGreaterThan(position, 0.5, "The control media is valid and actually decoded")

        for (index, target) in [sentinel.absoluteString, "crypto:" + sentinel.absoluteString,
            "concat:" + sentinel.absoluteString + "|" + sentinel.absoluteString].enumerated() {
            let path = "/evil\(index).m3u8"
            server.set(path, .init(body: Data((prefix + target + suffix).utf8), contentType: "application/vnd.apple.mpegurl"))
            failed = false
            position = 0
            view.loadStream(url: server.url(path), headers: [:], startAt: nil)
            try await waitUntil(timeout: 5) { failed || position > 0.5 }
            XCTAssertTrue(failed, "Remote HLS must reject nested \(target)")
            XCTAssertLessThanOrEqual(position, 0.5)
        }
        server.set("/evil.m3u", .init(body: Data(("#EXTM3U\n" + URL(fileURLWithPath: Self.fixture).absoluteString + "\n").utf8), contentType: "audio/x-mpegurl"))
        server.set("/redirect.mp4", .init(body: Data(), redirectLocation: URL(fileURLWithPath: Self.fixture).absoluteString))
        for path in ["/evil.m3u", "/redirect.mp4"] {
            failed = false
            position = 0
            view.loadStream(url: server.url(path), headers: [:], startAt: nil)
            try await waitUntil(timeout: 5) { failed || position > 0.5 }
            XCTAssertTrue(failed, "Remote playlist/redirect cannot open the local sentinel")
            XCTAssertLessThanOrEqual(position, 0.5)
        }
    }
}

/// End-to-end view-model flows over the real window + engine with a local
/// file (no daemon). Also requires CS_IN_MEMORY_DB=1 so progress writes never
/// touch the user's library.
@MainActor
final class PlayerViewModelLiveTests: XCTestCase {
    private static let fixture = URL(fileURLWithPath: "/tmp/test_stereo.mp4")
    private var player: PlayerViewModel?

    private func requireEngine() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["CS_MPV_ENGINE_TESTS"] == "1" else {
            throw XCTSkip("Set CS_MPV_ENGINE_TESTS=1 to run live mpv engine tests")
        }
        guard env["CS_IN_MEMORY_DB"] == "1" else {
            throw XCTSkip("Set CS_IN_MEMORY_DB=1 so live playback cannot write the real library")
        }
        guard FileManager.default.fileExists(atPath: Self.fixture.path) else {
            throw XCTSkip("Missing fixture \(Self.fixture.path)")
        }
    }

    private func movie() -> DetailsDto {
        DetailsDto(
            provider: "local",
            url: "fixture",
            name: "Fixture",
            type: "movie",
            posterUrl: nil,
            backgroundPosterUrl: nil,
            logoUrl: nil,
            plot: nil,
            year: nil,
            durationMinutes: nil,
            score: nil,
            tags: [],
            actors: [],
            contentRating: nil,
            comingSoon: false,
            episodes: [],
            movieData: nil,
        )
    }

    override func tearDown() async throws {
        player?.close()
        player = nil
        try await Task.sleep(for: .milliseconds(400))
    }

    private func startPlaying(resumeAt: Double? = nil) async throws -> PlayerViewModel {
        let player = PlayerViewModel()
        self.player = player
        await player.play(details: movie(), episode: nil, resumeAt: resumeAt, preferences: .shared, localMediaURL: Self.fixture)
        try await waitUntil(timeout: 5) { player.phase == .ready }
        XCTAssertEqual(player.phase, .ready, "Local playback must reach .ready")
        return player
    }

    func testLocalPlaybackReachesReadyAndAdvances() async throws {
        try requireEngine()
        let player = try await startPlaying()
        XCTAssertTrue(player.isPlaying)
        try await waitUntil(timeout: 3) { player.elapsed > 0.5 }
        XCTAssertGreaterThan(player.elapsed, 0.5)
        XCTAssertGreaterThan(player.duration, 3.5)
        XCTAssertNil(player.error)
    }

    /// T2: replacing a playing session (episode change) used to receive the
    /// old session's late `pause=true` echo and start the new one paused.
    func testReplayingStartsUnpaused() async throws {
        try requireEngine()
        let player = try await startPlaying()
        try await waitUntil(timeout: 3) { player.elapsed > 0.5 }

        await player.play(details: movie(), episode: nil, preferences: .shared, localMediaURL: Self.fixture)
        try await waitUntil(timeout: 5) { player.phase == .ready }
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertTrue(player.isPlaying, "The replacement session must not start paused")
        XCTAssertGreaterThan(player.elapsed, 0.3, "…and its clock must advance")
    }

    /// U4: after a seek, stale pre-seek ticks must not snap the clock back.
    func testSeekDoesNotSnapBack() async throws {
        try requireEngine()
        let player = try await startPlaying()
        player.setPlaying(false)
        player.seek(to: 3.0)
        var samples: [Double] = []
        for _ in 0..<10 {
            samples.append(player.elapsed)
            try await Task.sleep(for: .milliseconds(60))
        }
        XCTAssertTrue(samples.allSatisfy { $0 >= 2.5 }, "Clock snapped back after seek: \(samples)")
    }

    /// T4 end-to-end: a movie reaching EOF under keep-open closes the player.
    func testMovieEndClosesPlayer() async throws {
        try requireEngine()
        let player = try await startPlaying(resumeAt: 2.5)
        try await waitUntil(timeout: 6) { player.phase == .idle }
        XCTAssertEqual(player.phase, .idle, "EOF must close a movie (auto-advance/close was dead under keep-open)")
        XCTAssertNil(player.session)
    }

    private func waitUntil(timeout: TimeInterval, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

private extension FileHandle {
    /// Bytes up to the first newline (or EOF).
    func availableLine() -> Data {
        var line = Data()
        while let byte = try? read(upToCount: 1), let first = byte.first, first != UInt8(ascii: "\n") { line.append(first) }
        return line
    }
}

/// Minimal local HTTP file server (python3) that records each request's
/// headers as JSON lines. Test-only.
final class HeaderLoggingServer {
    let port: Int
    private let process: Process
    private let logURL: URL

    struct StartFailure: Error, CustomStringConvertible { let description: String }

    init(directory: String) throws {
        logURL = FileManager.default.temporaryDirectory.appendingPathComponent("cs-headers-\(UUID().uuidString).jsonl")
        // Records every request's headers, plus the names sent more than once
        // (`_repeated`), which a header dictionary would hide. Binds port 0 and
        // prints the port it got, so parallel runs never collide.
        let script = """
        import http.server, json, os, sys
        log = sys.argv[1]
        class H(http.server.SimpleHTTPRequestHandler):
            def log_request(self, *a): pass
            def record(self):
                names = [k.lower() for k in self.headers.keys()]
                repeated = sorted({n for n in names if names.count(n) > 1})
                with open(log, 'a') as f: f.write(json.dumps({**dict(self.headers), '_path': self.path, '_repeated': ','.join(repeated)}) + "\\n")
            def do_GET(self): self.record(); super().do_GET()
            def do_HEAD(self): self.record(); super().do_HEAD()
        os.chdir(sys.argv[2])
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), H)
        print(server.server_address[1], flush=True)
        server.serve_forever()
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script, logURL.path, directory]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let line = String(decoding: output.fileHandleForReading.availableLine(), as: UTF8.self)
        guard let port = Int(line.trimmingCharacters(in: .whitespacesAndNewlines)), port > 0 else {
            process.terminate()
            throw StartFailure(description: "the header-logging server did not start (python3 output: \(line))")
        }
        self.port = port
        self.process = process
    }

    func requests() -> [[String: String]] {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: String]
        }
    }

    func stop() {
        process.terminate()
        try? FileManager.default.removeItem(at: logURL)
    }
}
