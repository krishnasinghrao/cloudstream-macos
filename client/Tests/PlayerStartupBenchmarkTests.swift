import AppKit
import XCTest
@testable import CloudStream

/// Startup / resume / A-V sync measurements against a local CDN simulator.
/// Gated: CS_MPV_BENCH=1 and CS_BENCH_BASE=http://127.0.0.1:<port> serving
/// muxed.mp4, v.mp4 (video-only), a1.m4a, a2.m4a (audio-only), hls/index.m3u8.
@MainActor
final class PlayerStartupBenchmarkTests: XCTestCase {
    struct Sample {
        let t: Double
        let pos: Double?
        let audioPts: Double?
        let avsync: Double?
        let aid: String?
        let cache: Bool
        let ahead: Double?
    }

    struct Result: CustomStringConvertible {
        let name: String
        let restartAt: Double?
        let firstPos: Double?
        let firstAudioAt: Double?
        let maxAbsAvsync: Double
        let posRateFirst2s: Double?
        let drops: String
        let samples: [Sample]
        var stalls: Int { samples.filter(\.cache).count }
        var endAhead: Double? { samples.last?.ahead }
        /// First sample time at which the clock is advancing past the start.
        var playingAt: Double? {
            guard let p0 = samples.first(where: { $0.pos != nil })?.pos else { return nil }
            return samples.first(where: { ($0.pos ?? p0) > p0 + 0.2 })?.t
        }

        var description: String {
            func f(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "—" }
            return "BENCH \(name): restart=\(f(restartAt))s firstPos=\(f(firstPos)) firstAudio=\(f(firstAudioAt))s "
                + "max|avsync|=\(String(format: "%.3f", maxAbsAvsync)) posRate(2s)=\(f(posRateFirst2s))x drops=\(drops) "
                + "playingAt=\(f(playingAt))s stallSamples=\(stalls) aheadAtEnd=\(f(endAhead))s"
        }
    }

    private var base: String {
        ProcessInfo.processInfo.environment["CS_BENCH_BASE"] ?? ""
    }

    private func requireBench() throws {
        guard ProcessInfo.processInfo.environment["CS_MPV_BENCH"] == "1", !base.isEmpty else {
            throw XCTSkip("Set CS_MPV_BENCH=1 and CS_BENCH_BASE to run startup benchmarks")
        }
    }

    private func run(
        _ name: String,
        url: String,
        audio: [AudioTrackDto] = [],
        resourceOverride: PlaybackResource? = nil,
        start: Double?,
        seconds: Double = 6,
        configure: ((MetalVideoView) -> Void)? = nil,
    ) async throws -> Result {
        let view = MetalVideoView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 640, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.contentView = view
        window.orderFrontRegardless()
        defer {
            view.shutdown()
            window.close()
        }

        let clock = ContinuousClock()
        let t0 = clock.now
        func now() -> Double {
            let d = clock.now - t0
            return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        }
        var restartAt: Double?
        view.onPlaybackRestart = { if restartAt == nil { restartAt = now() } }
        configure?(view)
        view.setup(resource: try resourceOverride ?? .remote(url), headers: [:], subtitles: [], audioTracks: try audio.map(PlaybackAudio.remote), startAt: start)

        var samples: [Sample] = []
        while now() < seconds {
            try await Task.sleep(for: .milliseconds(100))
            samples.append(Sample(
                t: now(),
                pos: view.diagnosticProperty("time-pos").flatMap(Double.init),
                audioPts: view.diagnosticProperty("audio-pts").flatMap(Double.init),
                avsync: view.diagnosticProperty("avsync").flatMap(Double.init),
                aid: view.diagnosticProperty("aid"),
                cache: view.diagnosticProperty("paused-for-cache") == "yes",
                ahead: view.diagnosticProperty("demuxer-cache-duration").flatMap(Double.init),
            ))
        }
        let drops = "\(view.diagnosticProperty("frame-drop-count") ?? "?")/\(view.diagnosticProperty("decoder-frame-drop-count") ?? "?")"

        let afterRestart = samples.filter { $0.t >= (restartAt ?? .infinity) }
        let firstPos = afterRestart.first(where: { $0.pos != nil })?.pos
        let firstAudio = samples.first(where: { $0.audioPts != nil })?.t
        let maxAv = samples.compactMap(\.avsync).map(abs).max() ?? 0
        var rate: Double?
        if let first = afterRestart.first(where: { $0.pos != nil }),
           let later = afterRestart.last(where: { $0.pos != nil && $0.t <= first.t + 2 }),
           later.t > first.t, let p0 = first.pos, let p1 = later.pos {
            rate = (p1 - p0) / (later.t - first.t)
        }
        let result = Result(name: name, restartAt: restartAt, firstPos: firstPos, firstAudioAt: firstAudio,
                            maxAbsAvsync: maxAv, posRateFirst2s: rate, drops: drops, samples: samples)
        print(result)
        for s in samples.prefix(30) where s.t < 3.2 {
            print(String(format: "  t=%.1f pos=%@ apts=%@ av=%@ aid=%@ cache=%@",
                         s.t, s.pos.map { String(format: "%.2f", $0) } ?? "—",
                         s.audioPts.map { String(format: "%.2f", $0) } ?? "—",
                         s.avsync.map { String(format: "%.3f", $0) } ?? "—",
                         s.aid ?? "—", s.cache ? "Y" : "n"))
        }
        try await Task.sleep(for: .milliseconds(300))
        return result
    }

    func testMuxedFreshAndResume() async throws {
        try requireBench()
        _ = try await run("muxed fresh", url: "\(base)/muxed.mp4", start: nil)
        _ = try await run("muxed resume600", url: "\(base)/muxed.mp4", start: 600)
    }

    func testHLSFreshAndResume() async throws {
        try requireBench()
        _ = try await run("hls fresh", url: "\(base)/hls/index.m3u8", start: nil)
        _ = try await run("hls resume600", url: "\(base)/hls/index.m3u8", start: 600)
    }

    /// Current production path for split (DASH-style) streams: video-only
    /// loadfile + `audio-add` for every audio format after FILE_LOADED.
    func testSplitCurrentFreshAndResume() async throws {
        try requireBench()
        let audio = [
            AudioTrackDto(url: "\(base)/a1.m4a", label: "AAC 128", language: "en"),
            AudioTrackDto(url: "\(base)/a2.m4a", label: "AAC 64", language: "en"),
        ]
        _ = try await run("split-current fresh", url: "\(base)/v.mp4", audio: audio, start: nil)
        _ = try await run("split-current resume600", url: "\(base)/v.mp4", audio: audio, start: 600)
    }

    /// Sources mpv cannot seek: a server that ignores Range, and an MP4 whose
    /// index (moov) sits at the end of the file.
    func testUnseekableSourcesResume() async throws {
        try requireBench()
        let noRange = ProcessInfo.processInfo.environment["CS_BENCH_BASE_NORANGE"] ?? ""
        _ = try await run("moovend resume600", url: "\(base)/muxed_moovend.mp4", start: 600, seconds: 8)
        guard !noRange.isEmpty else { return }
        _ = try await run("norange muxed resume600", url: "\(noRange)/muxed.mp4", start: 600, seconds: 12)
        _ = try await run("norange split resume600", url: "\(noRange)/v.mp4",
                          audio: [AudioTrackDto(url: "\(noRange)/a1.m4a", label: "AAC", language: "en")],
                          start: 600, seconds: 12)
    }

    // MARK: - Real YouTube split stream (URLs from CS_YT_DIR/yt_video.txt, yt_audio*.txt)

    private func youtubeInputs() throws -> (video: String, audio: [String]) {
        guard let dir = ProcessInfo.processInfo.environment["CS_YT_DIR"] else { throw XCTSkip("CS_YT_DIR not set") }
        let video = try String(contentsOfFile: "\(dir)/yt_video.txt", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        var audio: [String] = []
        for index in 0..<8 {
            guard let url = try? String(contentsOfFile: "\(dir)/yt_audio\(index).txt", encoding: .utf8) else { break }
            audio.append(url.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (video, audio)
    }

    static let chunkedHTTP = ("stream-lavf-o", "request_size=4194304,multiple_requests=1,reconnect=1,reconnect_streamed=1,reconnect_on_network_error=1,reconnect_delay_max=4")

    func testYouTubeStrategies() async throws {
        try requireBench()
        let yt = try youtubeInputs()
        let audioDtos = yt.audio.map { AudioTrackDto(url: $0, label: nil, language: nil) }
        // Current production path (before this change): plain HTTP, audio-add ×N.
        MetalVideoView.optionOverridesForTesting = [("stream-lavf-o", "")]
        _ = try await run("yt current fresh", url: yt.video, audio: audioDtos, start: nil, seconds: 10)
        _ = try await run("yt current resume300", url: yt.video, audio: audioDtos, start: 300, seconds: 10)
        // Chunked HTTP only.
        MetalVideoView.optionOverridesForTesting = [Self.chunkedHTTP]
        _ = try await run("yt chunked fresh", url: yt.video, audio: audioDtos, start: nil, seconds: 10)
        _ = try await run("yt chunked resume300", url: yt.video, audio: audioDtos, start: 300, seconds: 10)
        // Chunked HTTP + EDL-merged video/audio (m4a 128k first, others delay_open).
        let ordered = [yt.audio[1]] + yt.audio.enumerated().filter { $0.offset != 1 }.map(\.element)
        let mergedResource = try PlaybackResource.split(video: yt.video, orderedAudio: ordered.map { AudioTrackDto(url: $0) })
        let merged = mergedResource.url
        _ = try await run("yt edl+chunked fresh", url: merged, resourceOverride: mergedResource, start: nil, seconds: 10)
        _ = try await run("yt edl+chunked resume300", url: merged, resourceOverride: mergedResource, start: 300, seconds: 10)
        MetalVideoView.optionOverridesForTesting = []
    }

    /// The shipping path: `PlayerViewModel.loadPlan` (EDL-merged split stream)
    /// with production engine options, plus switching to a lazily opened
    /// alternate audio track.
    func testYouTubeProductionPath() async throws {
        try requireBench()
        MetalVideoView.optionOverridesForTesting = []
        let yt = try youtubeInputs()
        let labels = ["m4a (48 kbps)", "m4a (128 kbps)", "WebM Opus (50 kbps)", "WebM Opus (70 kbps)", "WebM Opus (160 kbps)"]
        let audio = yt.audio.enumerated().map { AudioTrackDto(url: $1, label: labels[min($0, labels.count - 1)], language: nil) }
        let link = StreamLinkDto(url: yt.video, name: "YouTube", source: "yt", quality: 720, type: "VIDEO", audioTracks: audio)
        let plan = try PlayerViewModel.loadPlan(for: link)
        XCTAssertTrue(plan.url.hasPrefix("edl://"))
        XCTAssertTrue(plan.audioTracks.isEmpty)

        _ = try await run("yt production fresh", url: plan.url, resourceOverride: plan.resource, start: nil, seconds: 10)
        var tracks: [MpvTrack] = []
        let result = try await run("yt production resume300", url: plan.url, resourceOverride: plan.resource, start: 300, seconds: 10) { view in
            view.onTracksChanged = { tracks = $0 }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                // Switch to the second (delay_open) audio track mid-playback.
                if let alternate = tracks.filter({ $0.type == "audio" }).dropFirst().first {
                    print("BENCH switching audio to \(alternate.id) \(alternate.label)")
                    view.selectAudioTrack(alternate.id)
                }
            }
        }
        let audioTracks = tracks.filter { $0.type == "audio" }
        print("BENCH audio tracks listed: \(audioTracks.map(\.label))")
        XCTAssertEqual(audioTracks.count, audio.count, "every audio format is listed in the menu")
        XCTAssertEqual(audioTracks.first?.label.contains("128"), true, "AAC 128 kbps is preferred and opened first")
        let late = result.samples.filter { $0.t > 6 }
        XCTAssertTrue(late.contains { $0.audioPts != nil }, "audio keeps playing after switching to a lazily opened track")
    }

    func testAudioOutputStartupLatency() async throws {
        try requireBench()
        for ao in ["avfoundation", "coreaudio"] {
            for attempt in 1...2 {
                MetalVideoView.optionOverridesForTesting = [("ao", ao)]
                _ = try await run("ao=\(ao) #\(attempt) muxed fresh", url: "\(base)/muxed.mp4", start: nil, seconds: 4)
            }
        }
        MetalVideoView.optionOverridesForTesting = []
    }

    func testEDLDelayOpenMetadataVariants() async throws {
        try requireBench()
        // Exercise metadata through the same closed EDL builder as playback.
        // Arbitrary preassembled manifests cannot cross the native boundary.
        let variants: [(String, [AudioTrackDto])] = [
            ("label-and-language", [.init(url: "\(base)/a1.m4a", label: "AAC 128", language: "en"),
                                    .init(url: "\(base)/a2.m4a", label: "AAC 64", language: "en")]),
            ("codec-only", [.init(url: "\(base)/a1.m4a"), .init(url: "\(base)/a2.m4a")]),
        ]
        for (name, audio) in variants {
            let resource = try PlaybackResource.split(video: "\(base)/v.mp4", orderedAudio: audio)
            var tracks: [MpvTrack] = []
            _ = try await run("edl \(name)", url: resource.url, resourceOverride: resource, start: nil, seconds: 2.5) { view in
                view.onTracksChanged = { tracks = $0 }
            }
            XCTAssertEqual(tracks.filter { $0.type == "audio" }.count, audio.count)
            if name == "label-and-language" {
                XCTAssertTrue(tracks.contains { $0.type == "audio" && $0.title == "AAC 64" && $0.lang == "en" })
            }
        }
    }

    /// Resume on a mirror that cannot seek must fail over to one that can,
    /// keeping the resume point; with no seekable mirror, the user is told.
    func testUnseekableResumeFailsOverToSeekableMirror() async throws {
        try requireBench()
        let noRange = ProcessInfo.processInfo.environment["CS_BENCH_BASE_NORANGE"] ?? ""
        guard !noRange.isEmpty else { throw XCTSkip("CS_BENCH_BASE_NORANGE not set") }
        let details = DetailsDto(provider: "bench", url: "u", name: "Bench", type: "movie", posterUrl: nil, backgroundPosterUrl: nil,
                                 logoUrl: nil, plot: nil, year: nil, durationMinutes: nil, score: nil, tags: [], actors: [],
                                 contentRating: nil, comingSoon: false, episodes: [], movieData: nil)
        let unseekable = StreamLinkDto(url: "\(noRange)/muxed.mp4", name: "NoRange", source: "a", quality: 1080, type: "VIDEO")
        let seekable = StreamLinkDto(url: "\(base)/muxed.mp4", name: "Range", source: "b", quality: 720, type: "VIDEO")

        let player = PlayerViewModel()
        player.playResolved(details: details, episode: nil, links: [unseekable, seekable], resumeAt: 300)
        for _ in 0..<80 where !(player.session?.selectedLinkIndex == 1 && player.phase == .ready && player.elapsed > 299) {
            try await Task.sleep(for: .milliseconds(100))
        }
        print("BENCH failover: index=\(player.session?.selectedLinkIndex ?? -1) phase=\(player.phase) elapsed=\(player.elapsed)")
        XCTAssertEqual(player.session?.selectedLinkIndex, 1, "must fail over to the seekable mirror")
        XCTAssertGreaterThan(player.elapsed, 299, "…and resume at the saved position")
        player.close()
        try await Task.sleep(for: .milliseconds(400))

        let only = PlayerViewModel()
        only.playResolved(details: details, episode: nil, links: [unseekable], resumeAt: 300)
        for _ in 0..<60 where only.notice == nil { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertNotNil(only.notice, "no seekable mirror → tell the user instead of silently starting at 0:00")
        only.close()
        try await Task.sleep(for: .milliseconds(400))
    }
}

