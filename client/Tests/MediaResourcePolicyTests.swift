import AppKit
import XCTest
@testable import CloudStream

@MainActor
final class MediaResourcePolicyTests: XCTestCase {
    private func link(_ url: String = "https://cdn.example/video.mp4", playlist: [String] = [],
                      audio: [AudioTrackDto] = [], headers: [String: String] = [:]) -> StreamLinkDto {
        StreamLinkDto(url: url, name: "Fixture", source: "fixture", quality: 720, type: "VIDEO",
            headers: headers, isPlaylist: !playlist.isEmpty, playlist: playlist, audioTracks: audio)
    }

    private func details() -> DetailsDto {
        DetailsDto(provider: "Fixture", url: "https://provider.example/title", name: "Fixture", type: "Movie",
            posterUrl: nil, backgroundPosterUrl: nil, logoUrl: nil, plot: nil, year: nil, durationMinutes: nil,
            score: nil, tags: [], actors: [], contentRating: nil, comingSoon: false, episodes: [], movieData: "movie")
    }

    func testRemoteURLsKeepSignedBytesAndRejectNativeProtocolsUserinfoAndControls() throws {
        let signed = "https://cdn.example/v.mp4?sparams=a,b;c&sig=A%2fb+Z%3D&x=%26%3b"
        XCTAssertEqual(try PlaybackResource.remote(signed).url, signed)
        XCTAssertEqual(try PlaybackResource.remote("HTTP://127.0.0.1/video").origin, .providerRemote)
        for bad in ["/tmp/movie.mp4", "file:///tmp/movie.mp4", "edl://%5%file:", "concat:https://a|https://b",
            "subfile,,start,0,end,0,,:/etc/hosts", "data:abc", "magnet:?xt=urn:x", "pipe:0",
            "https://user:secret@cdn.example/video", "https:///video", "https://cdn.example/%zz",
            "https://cdn.example/video\r\nX-Header:yes", " https://cdn.example/video", "https://cdn.example/v\0"] {
            XCTAssertThrowsError(try PlaybackResource.remote(bad), bad)
        }
    }

    func testHeaderValidationRejectsWholeRequestAndPreservesScopedCredentials() throws {
        let valid = ["Cookie": "login=1; clearance=2", "Authorization": "Bearer fixture", "Referer": "https://provider.example/",
            "User-Agent": "Fixture/1", "X-Comma": "a, b"]
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: try MediaResourcePolicy.headers(valid).map { ($0.name, $0.value) }), valid)
        for headers in [["Cookie": "secret\r\nInjected:1"], ["Cookie": "secret\0"], ["Bad Name": "1"],
            ["Host": "localhost"], ["Content-Length": "10"], ["Transfer-Encoding": "chunked"],
            ["Connection": "keep-alive"], ["Cookie": "one", "cookie": "two"]] {
            XCTAssertThrowsError(try MediaResourcePolicy.headers(headers))
            XCTAssertThrowsError(try DownloadPolicy.sanitizedHeaders(headers))
            XCTAssertThrowsError(try ExternalPlayer.mpv.arguments(url: "https://cdn.example/video", headers: headers, title: nil, startAt: nil))
        }
    }

    func testInvalidNestedResourcesCannotBecomeAGeneratedOrDownloadablePlan() throws {
        for unsafe in [link(playlist: ["https://cdn.example/first.ts", "file:///tmp/sentinel.ts"]),
            link(audio: [.init(url: "edl://file:///tmp/sentinel")]),
            link(audio: [.init(url: "https://cdn.example/audio", headers: ["Cookie": "bad\nheader"])])] {
            XCTAssertThrowsError(try PlayerViewModel.loadPlan(for: unsafe))
            XCTAssertThrowsError(try PlayerViewModel.playableURL(for: unsafe))
            XCTAssertThrowsError(try DownloadService.ffmpegArguments(link: unsafe, outputPath: "/tmp/unused.part", format: "mp4"))
            XCTAssertFalse(DownloadPolicy.isDownloadable(unsafe))
        }
        let generated = try PlayerViewModel.loadPlan(for: link(playlist: ["https://cdn.example/first.ts", "https://cdn.example/second.ts?a=b;c"]))
        XCTAssertEqual(generated.resource.origin, .generatedRemote)
        XCTAssertThrowsError(try PlaybackResource.remote(generated.url), "A provider cannot claim the app-generated plan's privileges")
    }

    func testGeneratedPlansEnforceTheSameCardinalityBoundsAsTheWorker() throws {
        let segment = "https://cdn.example/segment.ts"
        let audio = AudioTrackDto(url: "https://cdn.example/audio.m4a")
        XCTAssertNoThrow(try PlaybackResource.playlist(Array(repeating: segment, count: 500)))
        XCTAssertThrowsError(try PlaybackResource.playlist(Array(repeating: segment, count: 501)))
        XCTAssertNoThrow(try PlaybackResource.split(video: segment, orderedAudio: Array(repeating: audio, count: 32)))
        XCTAssertThrowsError(try PlaybackResource.split(video: segment, orderedAudio: Array(repeating: audio, count: 33)))
        XCTAssertThrowsError(try MediaResourcePolicy.validate(link(playlist: Array(repeating: segment, count: 501))))
        XCTAssertThrowsError(try MediaResourcePolicy.validate(link(audio: Array(repeating: audio, count: 33))))
    }

    func testRejectedProviderRootSubtitleAndRawTrailerNeverCreateANativeLoad() async throws {
        let player = PlayerViewModel()
        defer { player.close() }
        player.playResolved(details: details(), episode: nil, links: [link("/tmp/sentinel.mp4")])
        XCTAssertEqual(player.phase, .failed)
        XCTAssertNil(player.loadRequest)
        player.playResolved(details: details(), episode: nil, links: [link()],
            subtitles: [SubtitleDto(url: "/tmp/sentinel.srt", language: "en", label: nil, mimeType: nil)])
        XCTAssertEqual(player.phase, .failed)
        XCTAssertNil(player.loadRequest)
        // The raw-trailer path enters through the same rejecting consumer.
        let trailer = TrailerDto(url: "file:///tmp/sentinel.mp4", referer: nil, raw: true, headers: [:])
        await player.playTrailer(trailer, for: details())
        XCTAssertEqual(player.phase, .failed)
        XCTAssertNil(player.loadRequest)
    }

    func testAuthorizedLocalMediaAndSubtitlesRemainExplicitAcrossMirrorChanges() async throws {
        let local = URL(fileURLWithPath: "/tmp/selected movie.mp4")
        let resource = try PlaybackResource.authorizedLocal(local)
        XCTAssertEqual(resource.origin, .authorizedLocal)
        XCTAssertEqual(resource.url, local.path)
        XCTAssertThrowsError(try PlaybackResource.authorizedLocal(URL(string: "https://cdn.example/video")!))
        let player = PlayerViewModel()
        defer { player.close() }
        await player.play(details: details(), episode: nil, preferences: .shared, localMediaURL: local)
        XCTAssertEqual(player.loadRequest?.resource.origin, .authorizedLocal)
        player.playResolved(details: details(), episode: nil, links: [link(), link("https://cdn.example/mirror.mp4")])
        let subtitle = URL(fileURLWithPath: "/tmp/user-selected.srt")
        XCTAssertTrue(player.addLocalSubtitleFile(subtitle))
        XCTAssertEqual(player.loadRequest?.subtitles.last?.resource.origin, .authorizedLocal)
        player.handlePlaybackError()
        XCTAssertEqual(player.loadRequest?.subtitles.last?.resource.url, subtitle.path)
        XCTAssertEqual(player.loadRequest?.subtitles.last?.resource.origin, .authorizedLocal)
    }

    func testNativeRawEntryPointRejectsLocalPathsBeforeCreatingEngine() {
        let view = MetalVideoView(frame: .zero)
        var failures = 0
        view.onPlaybackFailed = { failures += 1 }
        view.setup(streamURL: "/tmp/sentinel.mp4", headers: [:], subtitles: [], startAt: nil)
        XCTAssertFalse(view.isInitialized)
        XCTAssertEqual(failures, 1)
        view.setup(streamURL: "https://cdn.example/video", headers: ["Cookie": "bad\r\nInjected:1"], subtitles: [], startAt: nil)
        XCTAssertFalse(view.isInitialized)
        XCTAssertEqual(failures, 2)
    }

    // MARK: Split-stream header scope (audit A35)

    func testSplitHeadersMustBeExpressibleAndNeverLeakCredentialsAcrossOrigins() throws {
        func audio(_ url: String, _ headers: [String: String] = [:]) -> AudioTrackDto { AudioTrackDto(url: url, label: nil, language: nil, headers: headers) }
        let video = "https://video.example/v.mp4"
        // Same headers, or none needed on the same origin: the merged request set is correct.
        XCTAssertNoThrow(try MediaResourcePolicy.validateSplitHeaders(video: video, headers: ["Cookie": "s=1"],
            audio: [audio("https://audio.example/a.m4a", ["cookie": "s=1"]), audio("https://video.example/b.m4a")]))
        // No credentials in the set: repeating Referer/User-Agent elsewhere is fine (the common extractor shape).
        XCTAssertNoThrow(try MediaResourcePolicy.validateSplitHeaders(video: video, headers: ["Referer": "https://site/", "User-Agent": "UA"],
            audio: [audio("https://audio.example/a.m4a")]))
        XCTAssertNoThrow(try MediaResourcePolicy.validateSplitHeaders(video: video, headers: [:], audio: [audio("https://audio.example/a.m4a")]))
        // Audio needs its own headers: not expressible, so not silently dropped.
        XCTAssertThrowsError(try MediaResourcePolicy.validateSplitHeaders(video: video, headers: ["Cookie": "video=1"],
            audio: [audio("https://audio.example/a.m4a", ["Cookie": "audio=2"])])) {
            XCTAssertEqual($0 as? MediaResourcePolicy.Rejection, .unsupportedSplitHeaders)
        }
        XCTAssertThrowsError(try MediaResourcePolicy.validateSplitHeaders(video: video, headers: [:],
            audio: [audio("https://audio.example/a.m4a", ["Referer": "https://other/"])]))
        // The video's credential would be sent to another origin: refused.
        XCTAssertThrowsError(try MediaResourcePolicy.validateSplitHeaders(video: video, headers: ["Authorization": "Bearer t"],
            audio: [audio("https://audio.example/a.m4a")]))
        XCTAssertThrowsError(try MediaResourcePolicy.validateSplitHeaders(video: video, headers: ["X-Token": "t"],
            audio: [audio("http://video.example/a.m4a")]), "another scheme is another origin")
    }

    private var splitLink: StreamLinkDto {
        StreamLinkDto(url: "https://video.example/v.mp4", name: "split", source: "s", quality: 1080, type: "video",
            headers: ["Cookie": "video=1", "Referer": "https://site/"], audioTracks: [
                AudioTrackDto(url: "https://audio.example/a.webm?mime=audio/webm", label: "English", language: "en", headers: ["Cookie": "audio=2"]),
                AudioTrackDto(url: "https://other.example/b.m4a", label: nil, language: "fr", headers: [:]),
                AudioTrackDto(url: "https://video.example/c.m4a", label: nil, language: "de", headers: [:]),
            ])
    }

    private func settle(timeout: Double = 1, _ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int(timeout * 1000)))
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    }

    func testRelayResourcesGiveEachTrackItsOwnHeadersAndNeverTheVideoCredentialElsewhere() {
        let link = splitLink
        let resources = MediaResourcePolicy.relayResources(video: link.url, headers: link.headers, orderedAudio: link.audioTracks)
        XCTAssertEqual(resources, [
            MediaRelayResourceDto(url: link.url, headers: ["Cookie": "video=1", "Referer": "https://site/"]),
            MediaRelayResourceDto(url: link.audioTracks[0].url, headers: ["Cookie": "audio=2"]),
            // No headers of its own on another origin: the video's, without its credential.
            MediaRelayResourceDto(url: link.audioTracks[1].url, headers: ["Referer": "https://site/"]),
            // Same origin as the video: the video's full set, as before.
            MediaRelayResourceDto(url: link.audioTracks[2].url, headers: ["Cookie": "video=1", "Referer": "https://site/"]),
        ])
    }

    func testRelayedSplitPlanUsesOnlyLoopbackAddressesAndKeepsTrackDescriptions() throws {
        let link = splitLink
        let relayed = (0...3).map { "http://127.0.0.1:4100/media/relay/\(String(repeating: String($0), count: 64))" }
        let plan = try PlaybackResource.split(video: link.url, orderedAudio: link.audioTracks, relayed: relayed)
        XCTAssertEqual(plan.origin, .generatedRemote)
        for address in relayed { XCTAssertTrue(plan.url.contains(PlaybackResource.edlQuoted(address))) }
        XCTAssertFalse(plan.url.contains("example"), "no provider address is loaded directly")
        XCTAssertTrue(plan.url.contains("lang=%2%fr"))
        XCTAssertTrue(plan.url.contains("codec=aac"), "the codec is still guessed from the provider's description")
        // Anything but this Mac's listener, or a wrong count, is not a relay.
        XCTAssertThrowsError(try PlaybackResource.split(video: link.url, orderedAudio: link.audioTracks, relayed: Array(relayed.dropLast())))
        XCTAssertThrowsError(try PlaybackResource.split(video: link.url, orderedAudio: link.audioTracks,
            relayed: ["https://evil.example/x"] + relayed.dropFirst()))
        XCTAssertThrowsError(try PlaybackResource.split(video: link.url, orderedAudio: link.audioTracks,
            relayed: ["file:///etc/hosts"] + relayed.dropFirst()))
    }

    @MainActor
    func testSplitStreamWithDifferentAudioHeadersLoadsThroughTheRelayAndReleasesIt() async {
        let link = splitLink
        let player = PlayerViewModel()
        var registered: [[MediaRelayResourceDto]] = []
        var revoked: [String] = []
        player.registerRelay = { resources in
            registered.append(resources)
            return .init(sessionID: "session-\(registered.count)",
                urls: resources.indices.map { "http://127.0.0.1:4100/media/relay/\(String(repeating: "a", count: 63))\($0)" })
        }
        player.revokeRelay = { revoked.append($0) }
        player.playResolved(details: details(), episode: nil, links: [link], persistsProgress: false)
        XCTAssertEqual(player.phase, .loading)
        XCTAssertNil(player.loadRequest, "nothing is loaded before the relay exists")
        await settle { player.loadRequest != nil }
        let request = try? XCTUnwrap(player.loadRequest)
        XCTAssertEqual(registered.count, 1)
        XCTAssertEqual(registered.first?.count, 4)
        XCTAssertEqual(registered.first?.first?.headers, link.headers)
        XCTAssertEqual(request?.resource.origin, .generatedRemote)
        XCTAssertFalse(request?.url.contains("example") ?? true)
        XCTAssertTrue(request?.audioTracks.isEmpty ?? false)
        XCTAssertNil(player.error)
        // Reloading the mirror replaces the relay; closing releases the last one.
        player.failover(to: 0)
        await settle { registered.count == 2 && player.loadRequest != nil }
        await settle { revoked == ["session-1"] }
        XCTAssertEqual(revoked, ["session-1"])
        player.close()
        await settle { revoked.count == 2 }
        XCTAssertEqual(revoked, ["session-1", "session-2"])
    }

    @MainActor
    func testARelayedStreamIsRegisteredAgainAfterAnEngineRestartAndResumes() async {
        let player = PlayerViewModel()
        defer { player.close() }
        var registered = 0
        var revoked: [String] = []
        player.registerRelay = { resources in
            registered += 1
            return .init(sessionID: "session-\(registered)",
                urls: resources.indices.map { "http://127.0.0.1:4100/media/relay/\(String(repeating: "b", count: 63))\($0)" })
        }
        player.revokeRelay = { revoked.append($0) }
        player.playResolved(details: details(), episode: nil, links: [splitLink], persistsProgress: false)
        await settle { player.loadRequest != nil }
        player.handleProgress(elapsed: 321, duration: 3000)
        let first = player.loadRequest?.id
        player.engineReconnected()
        await settle { registered == 2 && player.loadRequest?.id != first }
        XCTAssertEqual(registered, 2)
        XCTAssertEqual(player.loadRequest?.startAt, 321, "resumes where it was")
        XCTAssertTrue(revoked.isEmpty, "the old engine's session is not revoked on the new engine")
        XCTAssertNotNil(player.notice)

        // A stream that does not use the relay is left alone.
        let plain = PlayerViewModel()
        defer { plain.close() }
        plain.playResolved(details: details(), episode: nil,
            links: [StreamLinkDto(url: "https://cdn.example/plain.mp4", name: "plain", source: "p", quality: 720, type: "video")],
            persistsProgress: false)
        let request = plain.loadRequest?.id
        plain.engineReconnected()
        XCTAssertEqual(plain.loadRequest?.id, request)
    }

    @MainActor
    func testRelayRegistrationThatReturnsAfterTheLoadWasReplacedIsRevokedNotUsed() async {
        let plain = StreamLinkDto(url: "https://cdn.example/plain.mp4", name: "plain", source: "p", quality: 720, type: "video")
        let player = PlayerViewModel()
        defer { player.close() }
        var release: CheckedContinuation<Void, Never>?
        var revoked: [String] = []
        player.registerRelay = { resources in
            await withCheckedContinuation { release = $0 }
            return .init(sessionID: "late", urls: resources.indices.map { "http://127.0.0.1:4100/media/relay/\(String(repeating: "b", count: 63))\($0)" })
        }
        player.revokeRelay = { revoked.append($0) }
        player.playResolved(details: details(), episode: nil, links: [splitLink, plain], persistsProgress: false)
        await settle { release != nil }
        player.failover(to: 1)
        XCTAssertEqual(player.loadRequest?.url, plain.url)
        release?.resume()
        await settle { revoked == ["late"] }
        XCTAssertEqual(revoked, ["late"])
        XCTAssertEqual(player.loadRequest?.url, plain.url, "the late relay did not replace the chosen mirror")
    }

    @MainActor
    func testFailoverReportsWhetherTheLoadWasIssuedAndKeepsALastMirrorsFailure() async {
        // Q1: failover clears the error and resumes only for a load it actually issued.
        struct Unavailable: Error {}
        // Ranked above the 1080p split mirror, so the split one is the last mirror.
        let plain = StreamLinkDto(url: "https://cdn.example/plain.mp4", name: "plain", source: "p", quality: 2160, type: "video")
        let player = PlayerViewModel()
        defer { player.close() }
        player.registerRelay = { _ in throw Unavailable() }
        player.playResolved(details: details(), episode: nil, links: [plain, splitLink], persistsProgress: false)
        XCTAssertEqual(player.loadRequest?.url, plain.url, "the plain mirror plays first")
        XCTAssertFalse(player.failover(to: 7), "no such mirror")
        XCTAssertTrue(player.failover(to: 0))
        XCTAssertNil(player.error)
        XCTAssertTrue(player.isPlaying)
        _ = player.failover(to: 1) // The last mirror: its relay cannot be registered.
        await settle { player.phase == .failed }
        XCTAssertEqual(player.phase, .failed)
        XCTAssertNotNil(player.error, "the failure of the last mirror stays visible")
    }

    @MainActor
    func testARelayedFirstMirrorStartsTheSession() async {
        // Q1: a session whose first mirror needs the relay is presented and playing.
        let player = PlayerViewModel()
        defer { player.close() }
        player.registerRelay = { resources in
            .init(sessionID: "first", urls: resources.indices.map { "http://127.0.0.1:4100/media/relay/\(String(repeating: "e", count: 63))\($0)" })
        }
        player.revokeRelay = { _ in }
        player.playResolved(details: details(), episode: nil, links: [splitLink], persistsProgress: false)
        XCTAssertTrue(player.isPlaying, "started although the load request waits for the relay")
        await settle { player.loadRequest != nil }
        XCTAssertNotNil(player.loadRequest)
        XCTAssertNil(player.error)
    }

    @MainActor
    func testRapidRelayedMirrorSwitchesLeaveAtMostOneLiveSession() async {
        // M6a: switches while registrations are in flight never leak a session.
        let player = PlayerViewModel()
        var issued: [String] = []
        var revoked: [String] = []
        var count = 0
        player.registerRelay = { resources in
            count += 1
            let id = "s\(count)"
            try await Task.sleep(for: .milliseconds(30))
            issued.append(id)
            return .init(sessionID: id, urls: resources.indices.map { "http://127.0.0.1:4100/media/relay/\(String(repeating: "c", count: 63))\($0)" })
        }
        player.revokeRelay = { revoked.append($0) }
        player.playResolved(details: details(), episode: nil, links: [splitLink], persistsProgress: false)
        for _ in 0..<5 { player.failover(to: 0) }
        await settle(timeout: 5) { issued.count == 6 && revoked.count == 5 }
        XCTAssertEqual(issued.count, 6)
        XCTAssertEqual(Set(issued).subtracting(revoked).count, 1, "exactly one live session: the current load's")
        player.close()
        await settle { revoked.count == 6 }
        XCTAssertEqual(Set(revoked), Set(issued), "closing releases the last one")
    }

    @MainActor
    func testRegistrationInFlightWhenThePlayerClosesIsRevoked() async {
        let player = PlayerViewModel()
        var release: CheckedContinuation<Void, Never>?
        var revoked: [String] = []
        player.registerRelay = { resources in
            await withCheckedContinuation { release = $0 }
            return .init(sessionID: "closing", urls: resources.indices.map { "http://127.0.0.1:4100/media/relay/\(String(repeating: "d", count: 63))\($0)" })
        }
        player.revokeRelay = { revoked.append($0) }
        player.playResolved(details: details(), episode: nil, links: [splitLink], persistsProgress: false)
        await settle { release != nil }
        player.close()
        release?.resume()
        await settle { revoked == ["closing"] }
        XCTAssertEqual(revoked, ["closing"], "a cancelled registration still revokes what it obtained")
    }

    @MainActor
    func testSplitMirrorIsSkippedWhenTheRelayIsUnavailableAndExplainedOnlyWhenNothingElseIsLeft() async {
        struct Unavailable: Error {}
        let split = splitLink
        let plain = StreamLinkDto(url: "https://cdn.example/plain.mp4", name: "plain", source: "p", quality: 720, type: "video")
        XCTAssertThrowsError(try PlayerViewModel.loadPlan(for: split))
        let player = PlayerViewModel()
        defer { player.close() }
        player.registerRelay = { _ in throw Unavailable() }
        player.playResolved(details: details(), episode: nil, links: [split, plain], persistsProgress: false)
        await settle { player.loadRequest != nil }
        XCTAssertEqual(player.loadRequest?.url, plain.url, "the next mirror plays instead of a stream with broken or leaked audio headers")
        XCTAssertNil(player.error)
        let alone = PlayerViewModel()
        defer { alone.close() }
        alone.registerRelay = { _ in throw Unavailable() }
        alone.playResolved(details: details(), episode: nil, links: [split], persistsProgress: false)
        await settle { alone.phase == .failed }
        XCTAssertEqual(alone.phase, .failed)
        XCTAssertEqual(alone.error, MediaResourcePolicy.Rejection.unsupportedSplitHeaders.localizedDescription)
    }

    // MARK: - ClearKey streams (L4)

    func testClearKeyLinksDecodeValidateAndBecomePerFileDemuxerOptions() throws {
        let json = #"{"url":"https://live.example/a.mpd","name":"Live","source":"live","quality":1080,"type":"DASH","#
            + #""drm":{"kid":"9eb4050de44b4802932e27d75083e266","key":"166634c675823c235a4a9446fad52e4d"}}"#
        let decoded = try JSONDecoder().decode(StreamLinkDto.self, from: Data(json.utf8))
        let drm = try XCTUnwrap(decoded.drm)
        XCTAssertNoThrow(try MediaResourcePolicy.validate(decoded))
        let options = MetalVideoView.demuxerOptions(decryption: drm)
        XCTAssertTrue(options.hasPrefix(MetalVideoView.demuxerOptions), "the per-file value keeps the protocol confinement")
        XCTAssertTrue(options.contains("cenc_decryption_keys=%65%9eb4050de44b4802932e27d75083e266=166634c675823c235a4a9446fad52e4d"))
        XCTAssertTrue(options.contains("decryption_keys=%65%9eb4050de44b4802932e27d75083e266=166634c675823c235a4a9446fad52e4d"))
        let defaultKey = MetalVideoView.demuxerOptions(decryption: ClearKeyDto(kid: nil, key: drm.key))
        XCTAssertTrue(defaultKey.hasSuffix(",cenc_decryption_key=166634c675823c235a4a9446fad52e4d,decryption_key=166634c675823c235a4a9446fad52e4d"))
        // Links without the field (older engines) still decode.
        let plain = try JSONDecoder().decode(StreamLinkDto.self, from: Data(#"{"url":"https://a.example/v","name":"n","source":"s","quality":0,"type":"VIDEO"}"#.utf8))
        XCTAssertNil(plain.drm)
    }

    /// Remediation 3.3: request headers reach FFmpeg's demuxer as one
    /// length-prefixed `headers` value, so delimiters in values are inert.
    func testRequestHeadersBecomeALengthPrefixedPerFileDemuxerOption() throws {
        let split = MetalVideoView.splitHeaders(["Referer": "https://ref.example/a,b=c", "Origin": "https://ref.example",
                                                 "User-Agent": "Agent/1.0 (x; y)"])
        let options = MetalVideoView.demuxerOptions(headers: split, defaultUserAgent: "mpv", decryption: nil)
        let lines = "Origin: https://ref.example\r\nReferer: https://ref.example/a,b=c\r\nUser-Agent: Agent/1.0 (x; y)\r\n"
        XCTAssertEqual(options, MetalVideoView.demuxerOptions + ",headers=%\(lines.utf8.count)%\(lines)")
        // Without a stream User-Agent, mpv's default is named so FFmpeg does not add a second one.
        let noAgent = MetalVideoView.demuxerOptions(headers: MetalVideoView.splitHeaders(["Referer": "https://r.example/"]),
                                                    defaultUserAgent: "mpv/0.40", decryption: nil)
        XCTAssertTrue(noAgent.hasSuffix("Referer: https://r.example/\r\nUser-Agent: mpv/0.40\r\n"))
        // No headers: the global option already applies, so nothing per file.
        XCTAssertEqual(MetalVideoView.demuxerOptions(headers: MetalVideoView.splitHeaders([:]), defaultUserAgent: "mpv", decryption: nil),
                       MetalVideoView.demuxerOptions)
        // Headers and a ClearKey share the one per-file value.
        let both = MetalVideoView.demuxerOptions(headers: split, defaultUserAgent: nil,
                                                 decryption: ClearKeyDto(kid: nil, key: "166634c675823c235a4a9446fad52e4d"))
        XCTAssertTrue(both.contains("decryption_key=166634c675823c235a4a9446fad52e4d,headers=%"))
    }

    func testDecryptionKeysThatCouldCarryOptionSeparatorsAreRejected() {
        for bad in ["166634c675823c235a4a9446fad52e4", "166634C675823C235A4A9446FAD52E4D", "166634c675823c235a4a9446fad52e4d,x",
                    "166634c675823c235a4a9446fad52e:d", ""] {
            let link = StreamLinkDto(url: "https://live.example/a.mpd", name: "n", source: "s", quality: 0, type: "DASH",
                                     drm: ClearKeyDto(kid: nil, key: bad))
            XCTAssertThrowsError(try MediaResourcePolicy.validate(link), bad)
        }
        let badKid = StreamLinkDto(url: "https://live.example/a.mpd", name: "n", source: "s", quality: 0, type: "DASH",
                                   drm: ClearKeyDto(kid: "x=y", key: "166634c675823c235a4a9446fad52e4d"))
        XCTAssertThrowsError(try MediaResourcePolicy.validate(badKid))
    }
}
