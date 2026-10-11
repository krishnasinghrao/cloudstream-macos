import Network
import XCTest
@testable import CloudStream

// Regression coverage for the download-system audit: failure taxonomy,
// link/header/URL hygiene, resumable direct transfers, ffmpeg remux and
// protocol confinement, and end-to-end queue behavior (failover, pause,
// cancel, terminal failures, destination reservation) against a local
// HTTP server — no daemon, no network.

// MARK: - Policy (pure)

final class DownloadPolicyTests: XCTestCase {
    func testClassifierIgnoresNumbersAndUnrelatedNotFound() {
        // "1403 kb/s" used to classify as 403; "Encoder not found" as 404.
        let stderr = """
        Input #0, hls, from 'https://x/master.m3u8':
          Duration: 00:42:10.12, start: 0.000000, bitrate: 1403 kb/s
        Encoder not found
        """
        XCTAssertEqual(DownloadPolicy.classifyFFmpegFailure(exitStatus: 1, stderrTail: stderr), .unknown("ffmpeg exit 1"))
    }

    /// Non-APFS volumes (exFAT/HFS+ externals) report 0 for the
    /// important-usage key; that must not read as a full disk.
    func testFreeBytesFallsBackWhenImportantUsageIsUnsupported() {
        XCTAssertEqual(DownloadPolicy.freeBytes(importantUsage: 0, available: 900_000_000_000), 900_000_000_000)
        XCTAssertEqual(DownloadPolicy.freeBytes(importantUsage: nil, available: 5_000), 5_000)
        XCTAssertEqual(DownloadPolicy.freeBytes(importantUsage: 7_000, available: 5_000), 7_000)
        XCTAssertEqual(DownloadPolicy.freeBytes(importantUsage: 0, available: 0), 0)
        XCTAssertNil(DownloadPolicy.freeBytes(importantUsage: nil, available: nil))

        let capacity = DownloadPolicy.volumeCapacity(for: FileManager.default.temporaryDirectory)
        XCTAssertNotNil(capacity?.name)
        XCTAssertGreaterThan(capacity?.total ?? 0, 0)
    }

    /// The body shape is pinned by the daemon's OperationFailureTest
    /// (`capacity is a typed retryable 503 and incompatibility a terminal 422`).
    private func typedFailure(status: Int, code: String, retryable: Bool) throws -> Error {
        let body = """
        {"error":"public","detail":null,"failure":{"code":"\(code)","stage":"extraction","requestId":"r-1",
        "publicMessage":"public","retryable":\(retryable),"installationId":null,"providerId":"P","redactedCause":"X",
        "remoteStatus":null,"elapsedMs":12}}
        """
        let response = try XCTUnwrap(HTTPURLResponse(url: URL(string: "http://127.0.0.1/links")!, statusCode: status, httpVersion: nil, headerFields: nil))
        do { try DaemonClient.validate(response, data: Data(body.utf8)) }
        catch { return error }
        XCTFail("a failure status must throw")
        return URLError(.unknown)
    }

    @MainActor
    func testTypedRetryableFailuresRetryAndTypedTerminalOnesDoNot() throws {
        // Typed 503 capacity / 504 timeout responses retry like plain 5xx.
        for (status, code) in [(503, "capacity"), (503, "worker_terminated"), (504, "timeout"), (502, "network_failure")] {
            let error = try typedFailure(status: status, code: code, retryable: true)
            guard case DaemonClient.DaemonError.operationFailure = error else { return XCTFail("typed failure was not decoded: \(error)") }
            XCTAssertEqual(DownloadService.classifyResolutionError(error), .transient("public"), code)
        }
        // A typed 422 is terminal for this attempt but is not a missing provider.
        for code in ["runtime_incompatibility", "unsupported_capability", "rejected_media_resource"] {
            XCTAssertEqual(DownloadService.classifyResolutionError(try typedFailure(status: 422, code: code, retryable: false)), .fatal("public"), code)
        }
        // The flag decides, not the status or the message text.
        XCTAssertEqual(DownloadService.classifyResolutionError(try typedFailure(status: 502, code: "provider_failure", retryable: false)), .fatal("public"))
        // Untyped responses keep their existing classification.
        XCTAssertEqual(DownloadService.classifyResolutionError(DaemonClient.DaemonError.http(statusCode: 503, detail: nil)), .transient("HTTP 503"))
        XCTAssertEqual(DownloadService.classifyResolutionError(DaemonClient.DaemonError.http(statusCode: 422, detail: nil)), .providerMissing(nil))
        // The engine's reason (E2) reaches the download list instead of a generic sentence.
        let reason = "The extension “MovieBox” is turned off. Turn it on in Settings ▸ Extensions."
        XCTAssertEqual(DownloadService.classifyResolutionError(DaemonClient.DaemonError.http(statusCode: 422, detail: reason)), .providerMissing(reason))
        XCTAssertEqual(DownloadPolicy.FailureReason.providerUnavailable(provider: "MovieBox", reason: reason).label, reason)
    }

    func testClassifierRecognizesRealHTTPErrors() {
        XCTAssertEqual(DownloadPolicy.classifyFFmpegFailure(exitStatus: 1, stderrTail: "[https @ 0x1] HTTP error 403 Forbidden"), .forbidden)
        XCTAssertEqual(DownloadPolicy.classifyFFmpegFailure(exitStatus: 1, stderrTail: "Server returned 404 Not Found"), .notFound)
        XCTAssertEqual(DownloadPolicy.classifyFFmpegFailure(exitStatus: 1, stderrTail: "Server returned 503 Service Unavailable"), .httpStatus(503))
        XCTAssertEqual(DownloadPolicy.classifyFFmpegFailure(exitStatus: 1, stderrTail: "Protocol 'file' not on whitelist 'http,https'!"), .protocolUnsupported)
        XCTAssertEqual(DownloadPolicy.classifyFFmpegFailure(exitStatus: 1, stderrTail: "Could not find tag for codec dts in stream #1"), .incompatibleContainer)
        XCTAssertEqual(DownloadPolicy.classifyFFmpegFailure(exitStatus: 1, stderrTail: "x.part: Permission denied"), .permissionDenied)
        XCTAssertEqual(DownloadPolicy.classifyFFmpegFailure(exitStatus: 1, stderrTail: "Connection reset by peer"), .network("connection reset"))
    }

    func testLocalFailuresAreTerminalAndTransientsRetrySameMirror() {
        XCTAssertEqual(DownloadPolicy.FailureReason.diskFull.disposition, .terminal)
        XCTAssertEqual(DownloadPolicy.FailureReason.permissionDenied.disposition, .terminal)
        XCTAssertEqual(DownloadPolicy.FailureReason.providerUnavailable(provider: "p", reason: nil).disposition, .terminal)
        XCTAssertEqual(DownloadPolicy.FailureReason.stalled.disposition, .retrySameMirror)
        XCTAssertEqual(DownloadPolicy.FailureReason.truncated.disposition, .retrySameMirror)
        XCTAssertEqual(DownloadPolicy.FailureReason.httpStatus(503).disposition, .retrySameMirror)
        XCTAssertEqual(DownloadPolicy.FailureReason.forbidden.disposition, .nextMirror)
        XCTAssertEqual(DownloadPolicy.FailureReason.httpStatus(410).disposition, .nextMirror)
    }

    func testOnlyWebURLsAreAllowed() {
        XCTAssertTrue(DownloadPolicy.isAllowedRemoteURL("https://cdn.example/v.mp4"))
        XCTAssertTrue(DownloadPolicy.isAllowedRemoteURL("http://cdn.example/v.m3u8"))
        XCTAssertFalse(DownloadPolicy.isAllowedRemoteURL("file:///etc/passwd"))
        XCTAssertFalse(DownloadPolicy.isAllowedRemoteURL("concat:https://a|https://b"))
        XCTAssertFalse(DownloadPolicy.isAllowedRemoteURL("subfile,,start,0,end,0,,:/etc/hosts"))
        XCTAssertFalse(DownloadPolicy.isAllowedRemoteURL("magnet:?xt=urn:btih:abc"))
        XCTAssertFalse(DownloadPolicy.isAllowedRemoteURL(""))
    }

    private func link(_ url: String, quality: Int, type: String = "VIDEO", source: String = "s") -> StreamLinkDto {
        StreamLinkDto(url: url, name: "n", source: source, quality: quality, type: type)
    }

    func testCandidatesDropUndownloadableAndHonorPreferredQuality() {
        let links = [
            link("https://a/2160.mp4", quality: 2160),
            link("magnet:?xt=urn:btih:abc", quality: 1080, type: "MAGNET"),
            link("https://a/t.torrent", quality: 1080, type: "TORRENT"),
            link("file:///etc/hosts", quality: 1080),
            link("https://a/720.mp4", quality: 720),
            link("https://a/1080.mp4", quality: 1080),
            link("https://a/unknown.mp4", quality: 0),
        ]
        let best = DownloadPolicy.orderedCandidates(links, preferredQuality: 0).map(\.quality)
        XCTAssertEqual(best, [2160, 1080, 720, 0])

        let preferred = DownloadPolicy.orderedCandidates(links, preferredQuality: 1080).map(\.quality)
        XCTAssertEqual(preferred, [1080, 720, 2160, 0], "at-or-below preferred first, then higher, unknown last")
    }

    func testChosenSourceLeadsAndTheRestStayAsFallbacks() {
        func link(_ source: String, _ name: String, _ quality: Int) -> StreamLinkDto {
            StreamLinkDto(url: "https://cdn.example/\(source)/\(quality).mp4", name: name, source: source, quality: quality, type: "VIDEO")
        }
        let links = [link("Alpha", "Alpha EN", 1080), link("Beta", "Beta FR", 1080), link("Beta", "Beta EN", 720), link("Beta", "Beta EN", 480)]
        let choice = DownloadPolicy.SourceChoice(source: "Beta", name: "Beta EN", quality: 480)

        let ordered = DownloadPolicy.orderedCandidates(links, preferredQuality: 0, choice: choice)
        XCTAssertEqual(ordered.map(\.name), ["Beta EN", "Beta EN", "Beta FR", "Alpha EN"])
        XCTAssertEqual(ordered.map(\.quality), [480, 720, 1080, 1080], "exact pick, then same name, same source, then the rest")

        // A source the episode doesn't have changes nothing: automatic order.
        let missing = DownloadPolicy.SourceChoice(source: "Gamma", name: "Gamma", quality: 1080)
        XCTAssertEqual(
            DownloadPolicy.orderedCandidates(links, preferredQuality: 0, choice: missing),
            DownloadPolicy.orderedCandidates(links, preferredQuality: 0),
        )
        XCTAssertNil(missing.matchRank(links[0]))

        XCTAssertEqual(DownloadPolicy.SourceChoice(storage: choice.storage), choice)
        XCTAssertNil(DownloadPolicy.SourceChoice(storage: nil))
    }

    func testMirrorKeysAreStableAndDisambiguated() {
        let a = link("https://a/1?token=1", quality: 720)
        let b = link("https://a/2?token=2", quality: 720)
        let keys = DownloadPolicy.mirrorKeys(for: [a, b])
        XCTAssertNotEqual(keys[0], keys[1])
        // Rotated token → same identity.
        let rotated = link("https://a/1?token=999", quality: 720)
        XCTAssertEqual(DownloadPolicy.mirrorKeys(for: [rotated, b]), keys)
    }

    func testHeaderSanitizationBlocksInjection() throws {
        XCTAssertThrowsError(try DownloadPolicy.sanitizedHeaders(["Cookie": "a=1\r\nX-Injected: evil"]))
        XCTAssertThrowsError(try DownloadPolicy.sanitizedHeaders(["Bad Name": "x"]))
        let headers = try DownloadPolicy.sanitizedHeaders(["REFERER": "https://ref.example/", "Cookie": "a=1"])
        XCTAssertEqual(DownloadPolicy.header("cookie", in: headers), "a=1")
        XCTAssertEqual(DownloadPolicy.header("Referer", in: headers), "https://ref.example/", "lookup is case-insensitive")
    }

    func testFileNamesAreVisibleAndBounded() {
        XCTAssertEqual(DownloadPolicy.sanitizedFileName(".hack//Sign"), "hack__Sign")
        let long = String(repeating: "日本", count: 200)
        let sanitized = DownloadPolicy.sanitizedFileName(long)
        XCTAssertLessThanOrEqual(sanitized.utf8.count, DownloadPolicy.maxBaseNameBytes)
        XCTAssertFalse(sanitized.contains("\u{FFFD}"))
    }

    func testDurationParsingAndTruncationCheck() {
        XCTAssertEqual(DownloadPolicy.parseInputDuration("  Duration: 01:02:03.50, start: 0"), 3723.5)
        XCTAssertNil(DownloadPolicy.parseInputDuration("  Duration: N/A, start: 0"))
        XCTAssertTrue(DownloadPolicy.isTruncated(written: 600, expected: 2400))
        XCTAssertFalse(DownloadPolicy.isTruncated(written: 2398, expected: 2400))
        XCTAssertFalse(DownloadPolicy.isTruncated(written: 10, expected: nil))
    }

    func testSubtitleSelectionFollowsPreferredLanguage() {
        let subs = [
            SubtitleDto(url: "https://s/en.vtt", language: "en", label: nil, mimeType: "text/vtt"),
            SubtitleDto(url: "https://s/english.srt", language: "English", label: nil, mimeType: nil),
            SubtitleDto(url: "https://s/fr.vtt", language: "fr", label: nil, mimeType: nil),
            SubtitleDto(url: "file:///etc/hosts", language: "en", label: nil, mimeType: nil),
        ]
        let picked = DownloadPolicy.subtitlesToDownload(subs, preferredLanguage: "en")
        XCTAssertEqual(picked.map(\.url), ["https://s/en.vtt", "https://s/english.srt"])
        XCTAssertEqual(DownloadPolicy.subtitleExtension(for: picked[1]), "srt")
        XCTAssertTrue(DownloadPolicy.subtitlesToDownload(subs, preferredLanguage: "").isEmpty)
    }

    func testFFmpegArgumentsConfineProtocolsAndBoundIO() throws {
        let link = StreamLinkDto(
            url: "https://cdn.example/master.m3u8", name: "n", source: "s", quality: 1080, type: "M3U8",
            headers: ["referer": "https://r.example/", "user-agent": "UA/1"],
        )
        let args = try DownloadService.ffmpegArguments(link: link, outputPath: "/tmp/x.part", format: "matroska")
        let whitelist = args.firstIndex(of: "-protocol_whitelist").map { args[$0 + 1] }
        XCTAssertEqual(whitelist, DownloadPolicy.ffmpegProtocolWhitelist)
        XCTAssertFalse(whitelist?.contains("file") ?? true)
        XCTAssertTrue(args.contains("-rw_timeout"))
        XCTAssertEqual(args.firstIndex(of: "-referer").map { args[$0 + 1] }, "https://r.example/")
        XCTAssertEqual(args.firstIndex(of: "-user_agent").map { args[$0 + 1] }, "UA/1")
        XCTAssertFalse(args.contains("+faststart"), "faststart is MP4-only")
        XCTAssertEqual(Array(args.suffix(3)), ["-f", "matroska", "/tmp/x.part"])
        // Protocol options precede -i so they apply to the input.
        XCTAssertLessThan(args.firstIndex(of: "-protocol_whitelist")!, args.firstIndex(of: "-i")!)
        // HLS accepts disguised segment extensions; the whitelist still confines them.
        XCTAssertEqual(args.firstIndex(of: "-extension_picky").map { args[$0 + 1] }, "0")
        XCTAssertEqual(args.firstIndex(of: "-allowed_extensions").map { args[$0 + 1] }, "ALL")
        XCTAssertLessThan(args.firstIndex(of: "-extension_picky")!, args.firstIndex(of: "-i")!)
    }

    func testHLSOptionsOnlyApplyToHLSInputs() throws {
        // ffmpeg rejects demuxer options the chosen demuxer leaves unused.
        let file = StreamLinkDto(url: "https://cdn.example/movie.mp4", name: "n", source: "s", quality: 1080, type: "VIDEO")
        let args = try DownloadService.ffmpegArguments(link: file, outputPath: "/tmp/x.part", format: "mp4")
        XCTAssertFalse(args.contains("-extension_picky"))
        XCTAssertTrue(DownloadPolicy.isHLS(url: "https://cdn.example/a/index.m3u8?token=1", type: "VIDEO"))
        XCTAssertTrue(DownloadPolicy.isHLS(url: "https://cdn.example/play", type: "M3U8"))
        XCTAssertFalse(DownloadPolicy.isHLS(url: "https://cdn.example/manifest.mpd", type: "DASH"))
    }

    func testSeparateAudioTracksAreMappedInOrder() throws {
        let unsafe = StreamLinkDto(
            url: "https://cdn.example/video.m3u8", name: "n", source: "s", quality: 1080, type: "M3U8",
            audioTracks: [
                AudioTrackDto(url: "https://cdn.example/ja.m3u8", label: "Japanese", language: "ja", headers: [:]),
                AudioTrackDto(url: "file:///etc/hosts", label: "bad", language: "xx", headers: [:]),
            ],
        )
        XCTAssertFalse(DownloadPolicy.isDownloadable(unsafe), "An invalid nested resource rejects the link instead of silently dropping a track")
        XCTAssertThrowsError(try DownloadService.ffmpegArguments(link: unsafe, outputPath: "/tmp/x.part", format: "mp4"))
        let link = StreamLinkDto(url: unsafe.url, name: unsafe.name, source: unsafe.source, quality: unsafe.quality,
            type: unsafe.type, audioTracks: [unsafe.audioTracks[0]])
        let args = try DownloadService.ffmpegArguments(link: link, outputPath: "/tmp/x.part", format: "mp4")
        XCTAssertEqual(args.filter { $0 == "-i" }.count, 2)
        XCTAssertTrue(args.contains("1:a:0"))
        XCTAssertTrue(args.contains("language=ja"))
    }

    func testSplitDirectVideoUsesRemuxWithEachInputsHeaders() throws {
        let split = StreamLinkDto(url: "https://cdn.example/video.mp4", name: "n", source: "s", quality: 1080, type: "VIDEO",
            headers: ["X-Video": "video=1"],
            audioTracks: [AudioTrackDto(url: "https://audio.example/a.m4a", label: "English", language: "en", headers: ["X-Audio": "audio=2"])])
        XCTAssertFalse(DownloadPolicy.isDirectFile(split))
        XCTAssertTrue(DownloadPolicy.isDirectFile(link("https://cdn.example/video.mp4", quality: 1080)))
        let args = try DownloadService.ffmpegArguments(link: split, outputPath: "/tmp/split.part", format: "mp4")
        let inputs = args.indices.filter { args[$0] == "-i" }
        XCTAssertEqual(inputs.count, 2)
        XCTAssertTrue(args[..<inputs[0]].contains { $0.contains("X-Video: video=1") })
        XCTAssertTrue(args[(inputs[0] + 2)..<inputs[1]].contains { $0.contains("X-Audio: audio=2") })
        XCTAssertTrue(args.contains("1:a:0"))
        XCTAssertTrue(args.contains("-c"))
        XCTAssertTrue(args.contains("copy"))
    }

    func testCredentialedLinksNeverPutHeadersInFFmpegArgv() throws {
        // Any same-user process can read argv (security M2), so credentials go through the relay (A2).
        for (headers, audio) in [(["Cookie": "c=1"], [String: String]()), (["Authorization": "Bearer t"], [:]),
                                 (["Proxy-Authorization": "Basic x"], [:]), ([:], ["cookie": "a=2"])] {
            let link = StreamLinkDto(url: "https://cdn.example/master.m3u8", name: "n", source: "s", quality: 1080, type: "M3U8",
                headers: headers, audioTracks: [AudioTrackDto(url: "https://cdn.example/a.m3u8", label: "a", language: "en", headers: audio)])
            XCTAssertTrue(DownloadService.needsRelay(link))
            XCTAssertThrowsError(try DownloadService.ffmpegArguments(link: link, outputPath: "/tmp/x.part", format: "mp4"),
                "credentials must never be handed to ffmpeg directly")
        }
        XCTAssertFalse(DownloadService.needsRelay(StreamLinkDto(url: "https://cdn.example/v.mp4", name: "n", source: "s", quality: 1,
            type: "VIDEO", headers: ["Referer": "https://r.example/"])))
    }

    func testRelayedInputsKeepTheirOriginalKindAndCarryNoHeaders() throws {
        // A relay URL has no extension: the HLS options come from the original address (A2).
        let relayed = StreamLinkDto(url: "http://127.0.0.1:50000/media/relay/\(String(repeating: "a", count: 64))", name: "n",
            source: "s", quality: 1080, type: "M3U8",
            audioTracks: [AudioTrackDto(url: "http://127.0.0.1:50000/media/relay/\(String(repeating: "b", count: 64))", label: "a", language: "en", headers: [:])])
        let args = try DownloadService.ffmpegArguments(link: relayed, outputPath: "/tmp/x.part", format: "mp4", hlsInputs: [true, false])
        let inputs = args.indices.filter { args[$0] == "-i" }
        XCTAssertTrue(args[..<inputs[0]].contains("-extension_picky"), "the video input is HLS")
        XCTAssertFalse(args[(inputs[0] + 2)..<inputs[1]].contains("-extension_picky"), "the audio input is not")
        XCTAssertFalse(args.contains("-headers"))
        XCTAssertFalse(args.contains { $0.lowercased().contains("cookie") || $0.lowercased().contains("authorization") })
    }

    func testCrossOriginRedirectsDropCredentialsButKeepRangeHeaders() throws {
        let original = URL(string: "https://host.example/video.mp4")!
        var request = URLRequest(url: URL(string: "https://host.example/moved.mp4")!)
        for (name, value) in ["Cookie": "c=1", "Authorization": "Bearer t", "Range": "bytes=10-", "If-Range": "\"v1\"",
                              "Accept-Encoding": "identity", "Referer": "https://r.example/", "User-Agent": "UA", "X-Token": "t"] {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let same = try XCTUnwrap(DownloadFileJobRedirect.follow(request, from: original))
        XCTAssertEqual(same.value(forHTTPHeaderField: "Cookie"), "c=1", "same origin keeps credentials")
        XCTAssertEqual(same.value(forHTTPHeaderField: "Authorization"), "Bearer t")

        request.url = URL(string: "https://cdn.example/video.mp4")
        let cross = try XCTUnwrap(DownloadFileJobRedirect.follow(request, from: original))
        XCTAssertNil(cross.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(cross.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(cross.value(forHTTPHeaderField: "X-Token"), "unknown headers are treated as credentials")
        XCTAssertEqual(cross.value(forHTTPHeaderField: "Range"), "bytes=10-")
        XCTAssertEqual(cross.value(forHTTPHeaderField: "If-Range"), "\"v1\"")
        XCTAssertEqual(cross.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
        XCTAssertEqual(cross.value(forHTTPHeaderField: "Referer"), "https://r.example/")
        XCTAssertEqual(cross.value(forHTTPHeaderField: "User-Agent"), "UA")

        request.url = URL(string: "https://host.example:8443/video.mp4")
        XCTAssertNil(try XCTUnwrap(DownloadFileJobRedirect.follow(request, from: original)).value(forHTTPHeaderField: "Cookie"),
            "a different port is a different origin")
        request.url = URL(string: "file:///etc/hosts")
        XCTAssertNil(DownloadFileJobRedirect.follow(request, from: original), "a disallowed scheme is refused")
    }

    func testDASHManifestsLabelledAsFilesAreNotDownloadedDirectly() {
        let mpd = Data(#"<?xml version="1.0" encoding="UTF-8"?>\n<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static">"#.utf8)
        XCTAssertTrue(DownloadFileJobRedirect.isDASH(mpd))
        XCTAssertTrue(DownloadFileJobRedirect.isDASH(Data("  <mpd type=\"dynamic\">".utf8)))
        XCTAssertTrue(DownloadFileJobRedirect.isDASH(Data("<!-- generated --><MPD>".utf8)))
        XCTAssertFalse(DownloadFileJobRedirect.isDASH(Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70]) + Data("<MPD".utf8)),
            "media bytes before the marker are not a manifest")
        XCTAssertFalse(DownloadFileJobRedirect.isDASH(Data(repeating: 0x41, count: 600) + Data("<MPD".utf8)), "only the first 512 bytes count")
    }
}

// MARK: - Local HTTP server with Range support

/// Loopback HTTP/1.1 file server: byte ranges, ETags, status overrides,
/// deliberate mid-body disconnects, and throttled bodies. One request per
/// connection (`Connection: close`).
final class RangeHTTPServer: @unchecked Sendable {
    struct Route {
        var body: Data
        var contentType = "application/octet-stream"
        var status = 200
        var acceptRanges = true
        var etag: String? = "\"v1\""
        var lastModified: String? = nil
        var responseDate: String? = nil
        var requiredHeader: String? = nil
        var redirectLocation: String? = nil
        /// Deliberately hostile 206, used for Range requests or unsolicited
        /// responses. Otherwise a fresh request returns the normal full body.
        var partial: Partial? = nil
        var unsolicitedPartial = false
        /// Close the connection after this many body bytes (once).
        var cutAfterBytes: Int?
        /// Send the body in 64 KB chunks this far apart.
        var chunkDelay: TimeInterval = 0
        /// Sent as-is (e.g. Content-Encoding); may also drop Content-Length.
        var extraHeaders: [String: String] = [:]
        var omitContentLength = false
    }

    struct Partial {
        var contentRange: String
        var body: Data
        var omitContentLength = false
    }

    private let listener: NWListener
    private let lock = NSLock()
    private var routes: [String: Route] = [:]
    private var requestLog: [String] = []
    private var requestBodyLog: [Data] = []
    private(set) var port: Int = 0

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.port = Int(self?.listener.port?.rawValue ?? 0)
                ready.signal()
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global())
            self?.receiveRequest(on: connection, buffer: Data())
        }
        listener.start(queue: .global())
        _ = ready.wait(timeout: .now() + 5)
    }

    deinit { listener.cancel() }

    func url(_ path: String) -> String { "http://127.0.0.1:\(port)\(path)" }

    func set(_ path: String, _ route: Route) {
        lock.lock(); routes[path] = route; lock.unlock()
    }

    var requests: [String] {
        lock.lock(); defer { lock.unlock() }
        return requestLog
    }

    var requestBodies: [Data] {
        lock.lock(); defer { lock.unlock() }
        return requestBodyLog
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                let length = head.components(separatedBy: "\r\n")
                    .first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
                let bodyEnd = end.upperBound + length
                guard buffer.count >= bodyEnd else {
                    if isComplete || error != nil { connection.cancel() }
                    else { self.receiveRequest(on: connection, buffer: buffer) }
                    return
                }
                self.respond(to: head, body: buffer.subdata(in: end.upperBound..<bodyEnd), on: connection)
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receiveRequest(on: connection, buffer: buffer)
            }
        }
    }

    private func respond(to head: String, body: Data, on connection: NWConnection) {
        let lines = head.components(separatedBy: "\r\n")
        let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        let rangeHeader = lines.first { $0.lowercased().hasPrefix("range:") }
            .map { $0.dropFirst("range:".count).trimmingCharacters(in: .whitespaces) }

        lock.lock()
        requestLog.append(head)
        requestBodyLog.append(body)
        let route = routes[path]
        if route?.cutAfterBytes != nil { routes[path]?.cutAfterBytes = nil } // cut once
        lock.unlock()

        guard let route else {
            send(status: "404 Not Found", headers: ["Content-Length": "9"], body: Data("Not Found".utf8), cut: nil, delay: 0, on: connection)
            return
        }
        if let required = route.requiredHeader, !lines.contains(required) {
            send(status: "403 Forbidden", headers: ["Content-Length": "0"], body: Data(), cut: nil, delay: 0, on: connection)
            return
        }
        if let location = route.redirectLocation {
            send(status: "302 Found", headers: ["Content-Length": "0", "Location": location], body: Data(), cut: nil, delay: 0, on: connection)
            return
        }
        if route.status != 200 {
            let body = Data("error".utf8)
            send(status: "\(route.status) Error", headers: ["Content-Length": "\(body.count)"], body: body, cut: nil, delay: 0, on: connection)
            return
        }

        var headers = ["Content-Type": route.contentType]
        if route.acceptRanges { headers["Accept-Ranges"] = "bytes" }
        if let etag = route.etag { headers["ETag"] = etag }
        if let modified = route.lastModified { headers["Last-Modified"] = modified }
        if let date = route.responseDate { headers["Date"] = date }
        if let partial = route.partial, rangeHeader != nil || route.unsolicitedPartial {
            headers["Content-Range"] = partial.contentRange
            if !partial.omitContentLength { headers["Content-Length"] = "\(partial.body.count)" }
            send(status: "206 Partial Content", headers: headers, body: partial.body,
                cut: route.cutAfterBytes, delay: route.chunkDelay, on: connection)
            return
        }

        let total = route.body.count
        if route.acceptRanges, let rangeHeader, rangeHeader.hasPrefix("bytes="),
           let start = Int(rangeHeader.dropFirst("bytes=".count).split(separator: "-").first ?? ""), start < total {
            let slice = route.body.subdata(in: start..<total)
            headers["Content-Range"] = "bytes \(start)-\(total - 1)/\(total)"
            headers["Content-Length"] = "\(slice.count)"
            send(status: "206 Partial Content", headers: headers, body: slice, cut: route.cutAfterBytes, delay: route.chunkDelay, on: connection)
        } else {
            if !route.omitContentLength { headers["Content-Length"] = "\(total)" }
            headers.merge(route.extraHeaders) { $1 }
            send(status: "200 OK", headers: headers, body: route.body, cut: route.cutAfterBytes, delay: route.chunkDelay, on: connection)
        }
    }

    private func send(status: String, headers: [String: String], body: Data, cut: Int?, delay: TimeInterval, on connection: NWConnection) {
        var head = "HTTP/1.1 \(status)\r\nConnection: close\r\n"
        for (key, value) in headers { head += "\(key): \(value)\r\n" }
        head += "\r\n"
        let payload = cut.map { body.prefix($0) } ?? body
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in
            self.sendChunks(Data(payload), offset: 0, delay: delay, on: connection) {
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        })
    }

    private func sendChunks(_ data: Data, offset: Int, delay: TimeInterval, on connection: NWConnection, done: @escaping @Sendable () -> Void) {
        guard offset < data.count else { done(); return }
        let size = delay > 0 ? 65_536 : data.count
        let end = min(offset + size, data.count)
        connection.send(content: data.subdata(in: offset..<end), completion: .contentProcessed { error in
            guard error == nil else { connection.cancel(); return }
            if delay > 0 {
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                    self.sendChunks(data, offset: end, delay: delay, on: connection, done: done)
                }
            } else {
                self.sendChunks(data, offset: end, delay: delay, on: connection, done: done)
            }
        })
    }
}

private func randomVideoBytes(_ count: Int) -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
    bytes[0] = 0 // never "#EXTM3U" / "<html"
    return Data(bytes)
}

private func makeTempDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cs-dl-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// ffmpeg used only to *create* test media. The bundled ffmpeg ships without
/// encoders or the lavfi test sources (the app only remuxes), so fixtures come
/// from `CS_FIXTURE_FFMPEG` or a Homebrew ffmpeg when available; the code
/// under test still runs the bundled binary.
private func fixtureFFmpeg(fallback: URL) -> URL {
    let candidates = [ProcessInfo.processInfo.environment["CS_FIXTURE_FFMPEG"], "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
    let path = candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
    return path.map(URL.init(fileURLWithPath:)) ?? fallback
}

/// Generates an H.264/AAC HLS rendition and serves every file under
/// `/hls/`. Returns the local folder.
@discardableResult
private func serveGeneratedHLS(ffmpeg: URL, in directory: URL, server: RangeHTTPServer, seconds: Int = 12, size: String = "160x120") throws -> URL {
    let hls = directory.appendingPathComponent("hls", isDirectory: true)
    try FileManager.default.createDirectory(at: hls, withIntermediateDirectories: true)
    let process = Process()
    process.executableURL = fixtureFFmpeg(fallback: ffmpeg)
    process.arguments = [
        "-hide_banner", "-loglevel", "error", "-y",
        "-f", "lavfi", "-i", "testsrc=size=\(size):rate=10:duration=\(seconds)",
        "-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds)",
        "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest",
        "-f", "hls", "-hls_time", "4", "-hls_list_size", "0",
        "-hls_segment_filename", hls.appendingPathComponent("seg%d.ts").path,
        hls.appendingPathComponent("index.m3u8").path,
    ]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw XCTSkip("test media generation failed — set CS_FIXTURE_FFMPEG to an ffmpeg with lavfi, libx264 and aac")
    }
    for file in try FileManager.default.contentsOfDirectory(at: hls, includingPropertiesForKeys: nil) {
        let type = file.pathExtension == "m3u8" ? "application/vnd.apple.mpegurl" : "video/mp2t"
        server.set("/hls/\(file.lastPathComponent)", .init(body: try Data(contentsOf: file), contentType: type))
    }
    return hls
}

private func serveSplitFiles(ffmpeg: URL, in directory: URL, server: RangeHTTPServer) throws -> StreamLinkDto {
    let video = directory.appendingPathComponent("video.mp4")
    let audio = directory.appendingPathComponent("audio.m4a")
    let fixture = fixtureFFmpeg(fallback: ffmpeg)
    for arguments in [
        ["-f", "lavfi", "-i", "testsrc=size=1280x720:rate=10:duration=4", "-an", "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-movflags", "+faststart", video.path],
        ["-f", "lavfi", "-i", "sine=frequency=440:duration=4", "-vn", "-c:a", "aac", "-movflags", "+faststart", audio.path],
    ] {
        let process = Process()
        process.executableURL = fixture
        process.arguments = ["-hide_banner", "-loglevel", "error", "-y"] + arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw XCTSkip("Split fixture requires lavfi/libx264/aac in CS_FIXTURE_FFMPEG") }
    }
    server.set("/split-video.mp4", .init(body: try Data(contentsOf: video), contentType: "video/mp4", requiredHeader: "Cookie: video=1"))
    server.set("/split-audio.m4a", .init(body: try Data(contentsOf: audio), contentType: "audio/mp4", requiredHeader: "Cookie: audio=2"))
    return StreamLinkDto(url: server.url("/split-video.mp4"), name: "Split", source: "s", quality: 720, type: "VIDEO",
        headers: ["Cookie": "video=1"], audioTracks: [AudioTrackDto(url: server.url("/split-audio.m4a"),
            label: "English", language: "en", headers: ["Cookie": "audio=2"])])
}

// MARK: - Direct file transfers

final class DirectFileJobTests: XCTestCase {
    private var server: RangeHTTPServer!
    private var directory: URL!

    override func setUpWithError() throws {
        server = try RangeHTTPServer()
        directory = try makeTempDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        server = nil
    }

    private func job(_ path: String, part: URL, key: String = "k") -> DirectFileJob {
        DirectFileJob(url: URL(string: server.url(path))!, headers: [], partURL: part, mirrorKey: key) { _, _ in }
    }

    private func seedPartial(_ body: Data, count: Int, part: URL, tag: String? = "\"v1\"",
                             modified: String? = nil, date: String? = nil, completed: Bool? = nil) throws {
        try body.prefix(count).write(to: part)
        let metadata = DirectFileJob.ResumeMetadata(mirrorKey: "k", totalBytes: Int64(body.count),
            entityTag: tag, lastModified: modified, mimeType: "video/mp4", responseDate: date, completed: completed)
        try JSONEncoder().encode(metadata).write(to: DirectFileJob.metadataURL(forPart: part))
    }

    func testWrongResumeTailIsDiscardedBeforeOneFreshRequest() async throws {
        let body = randomVideoBytes(2 * 1_048_576)
        let offset = 512 * 1024
        let wrongStart = 1_048_576
        var route = RangeHTTPServer.Route(body: body, contentType: "video/mp4")
        route.partial = .init(contentRange: "bytes \(wrongStart)-\(body.count - 1)/\(body.count)", body: body.suffix(from: wrongStart))
        server.set("/wrong.mp4", route)
        let part = directory.appendingPathComponent("wrong.part")
        try seedPartial(body, count: offset, part: part)
        let outcome = await job("/wrong.mp4", part: part).run()
        XCTAssertEqual(outcome, .completed(bytes: Int64(body.count), mimeType: "video/mp4"))
        XCTAssertEqual(try Data(contentsOf: part), body, "Never label the wrong 1 MiB tail as a complete video")
        XCTAssertEqual(server.requests.count, 2)
        XCTAssertTrue(server.requests[0].contains("Range: bytes=\(offset)-"))
        XCTAssertFalse(server.requests[1].contains("Range:"))
    }

    func testMalformedChangedOrUnknownRangesRestartInsteadOfBeingAppended() async throws {
        let body = randomVideoBytes(1_048_576)
        let offset = 512 * 1024
        let invalidRanges = ["bytes \(offset)-\(body.count - 1)/*", "bytes \(offset)-\(body.count - 2)/\(body.count)",
            "bytes \(offset)-\(body.count)/\(body.count + 1)", "bytes \(offset)-bad/\(body.count)",
            "bytes \(offset)-\(body.count - 1)/999999999999999999999999"]
        for (index, range) in invalidRanges.enumerated() {
            var route = RangeHTTPServer.Route(body: body, contentType: "video/mp4")
            route.partial = .init(contentRange: range, body: body.suffix(from: offset))
            let path = "/malformed\(index).mp4"
            server.set(path, route)
            let part = directory.appendingPathComponent("malformed\(index).part")
            try seedPartial(body, count: offset, part: part)
            let outcome = await job(path, part: part).run()
            XCTAssertEqual(outcome, .completed(bytes: Int64(body.count), mimeType: "video/mp4"))
            XCTAssertEqual(try Data(contentsOf: part), body)
            XCTAssertFalse(server.requests.last?.contains("Range:") == true)
        }
    }

    func testCancellationDuringFreshFallbackStopsAndCanResumeWithoutTwoWriters() async throws {
        let body = randomVideoBytes(2 * 1_048_576)
        var route = RangeHTTPServer.Route(body: body, contentType: "video/mp4")
        route.partial = .init(contentRange: "bytes 1048576-2097151/2097152", body: body.suffix(from: 1_048_576))
        route.chunkDelay = 0.03
        server.set("/cancel-fallback.mp4", route)
        let part = directory.appendingPathComponent("cancel-fallback.part")
        try seedPartial(body, count: 524288, part: part)
        let transfer = job("/cancel-fallback.mp4", part: part)
        let running = Task { await transfer.run() }
        let deadline = Date().addingTimeInterval(5)
        while server.requests.count < 2, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(server.requests.count, 2)
        try await Task.sleep(for: .milliseconds(100))
        transfer.cancel()
        let cancelled = await running.value
        XCTAssertEqual(cancelled, .cancelled)
        route.partial = nil
        route.chunkDelay = 0
        server.set("/cancel-fallback.mp4", route)
        let resumed = await job("/cancel-fallback.mp4", part: part).run()
        XCTAssertEqual(resumed, .completed(bytes: Int64(body.count), mimeType: "video/mp4"))
        XCTAssertEqual(try Data(contentsOf: part), body)
    }

    func testUnsolicitedPartialRetriesOnceAndNeverPublishesATail() async throws {
        let body = randomVideoBytes(1_048_576)
        var route = RangeHTTPServer.Route(body: body, contentType: "video/mp4")
        route.unsolicitedPartial = true
        route.partial = .init(contentRange: "bytes 524288-1048575/1048576", body: body.suffix(from: 524288))
        server.set("/unsolicited.mp4", route)
        let part = directory.appendingPathComponent("unsolicited.part")
        let outcome = await job("/unsolicited.mp4", part: part).run()
        XCTAssertEqual(outcome, .failed(.invalidMedia))
        XCTAssertEqual(server.requests.count, 2, "A broken host cannot create an unbounded retry loop")
        XCTAssertFalse(FileManager.default.fileExists(atPath: part.path))
    }

    func testCompleteUnsolicitedRangeRequiresItsExactBodyLength() async throws {
        let body = randomVideoBytes(1_048_576)
        for (index, count) in [body.count, body.count - 1, body.count + 1].enumerated() {
            var served = body
            if count < body.count { served.removeLast() }
            if count > body.count { served.append(42) }
            var route = RangeHTTPServer.Route(body: body, contentType: "video/mp4")
            route.unsolicitedPartial = true
            route.partial = .init(contentRange: "bytes 0-\(body.count - 1)/\(body.count)", body: served, omitContentLength: true)
            let path = "/complete\(index).mp4"
            server.set(path, route)
            let part = directory.appendingPathComponent("complete\(index).part")
            let outcome = await job(path, part: part).run()
            if count == body.count {
                XCTAssertEqual(outcome, .completed(bytes: Int64(count), mimeType: "video/mp4"))
                XCTAssertEqual(try Data(contentsOf: part), body)
            } else {
                guard case .failed = outcome else { XCTFail("Wrong body length was accepted: \(outcome)"); continue }
            }
        }
    }

    func testMissingWeakChangedAndAmbiguousValidatorsCannotSpliceEqualSizeContent() async throws {
        let old = randomVideoBytes(1_048_576)
        let replacement = randomVideoBytes(old.count)
        for (index, tag) in [nil, "W/\"v1\"", "\"old\"", "\"v1\", \"v2\""].enumerated() {
            let path = "/changed\(index).mp4"
            server.set(path, .init(body: replacement, contentType: "video/mp4"))
            let part = directory.appendingPathComponent("changed\(index).part")
            try seedPartial(old, count: 524288, part: part, tag: tag)
            let outcome = await job(path, part: part).run()
            XCTAssertEqual(outcome, .completed(bytes: Int64(replacement.count), mimeType: "video/mp4"))
            XCTAssertEqual(try Data(contentsOf: part), replacement)
            if index != 2 { XCTAssertFalse(server.requests.last?.contains("Range:") == true) }
        }
    }

    func testOnlyProvenDateValidatorsResumeAndLegacyFullPartsRefetch() async throws {
        let body = randomVideoBytes(1_048_576)
        let modified = "Thu, 01 Oct 2026 08:00:00 GMT"
        let date = "Thu, 01 Oct 2026 08:02:00 GMT"
        let path = "/dated.mp4"
        server.set(path, .init(body: body, contentType: "video/mp4", etag: nil, lastModified: modified, responseDate: date))
        let part = directory.appendingPathComponent("dated.part")
        try seedPartial(body, count: 524288, part: part, tag: nil, modified: modified, date: date)
        let first = await job(path, part: part).run()
        XCTAssertEqual(first, .completed(bytes: Int64(body.count), mimeType: "video/mp4"))
        XCTAssertTrue(server.requests.last?.contains("If-Range: \(modified)") == true)
        XCTAssertEqual(try Data(contentsOf: part), body)
        let requestsBefore = server.requests.count
        let recovered = await job(path, part: part).run()
        XCTAssertEqual(recovered, first)
        XCTAssertEqual(server.requests.count, requestsBefore, "Validated completion marker permits local recovery")
        try seedPartial(body, count: body.count, part: part, tag: nil, modified: modified)
        _ = await job(path, part: part).run()
        XCTAssertEqual(server.requests.count, requestsBefore + 1, "Legacy full-size sidecars do not prove completed validation")
        XCTAssertFalse(server.requests.last?.contains("Range:") == true)
    }

    func testContentRangeParserRejectsAmbiguousOrOverflowingBounds() {
        let valid = DirectFileJob.parseContentRange("bytes 100-199/1000")
        XCTAssertEqual(valid?.start, 100)
        XCTAssertEqual(valid?.end, 199)
        XCTAssertEqual(valid?.total, 1000)
        for header in ["bytes 100/1000", "bytes 199-100/1000", "bytes -1-99/1000", "bytes 0-99/99",
            "bytes 0-1/garbage", "bytes 0-1/2/3", "bytes +0-1/2", "bytes 0-9223372036854775808/*"] {
            XCTAssertNil(DirectFileJob.parseContentRange(header), header)
        }
    }

    func testCompleteDownload() async throws {
        let body = randomVideoBytes(2 * 1_048_576)
        server.set("/v.mp4", .init(body: body, contentType: "video/mp4"))
        let part = directory.appendingPathComponent("a.part")

        let outcome = await job("/v.mp4", part: part).run()

        XCTAssertEqual(outcome, .completed(bytes: Int64(body.count), mimeType: "video/mp4"))
        XCTAssertEqual(try Data(contentsOf: part), body)
    }

    func testInterruptedTransferResumesWithRange() async throws {
        let body = randomVideoBytes(3 * 1_048_576)
        var route = RangeHTTPServer.Route(body: body, contentType: "video/mp4")
        route.cutAfterBytes = 1_048_576
        server.set("/v.mp4", route)
        let part = directory.appendingPathComponent("b.part")

        let first = await job("/v.mp4", part: part).run()
        guard case .failed = first else { return XCTFail("a cut transfer must fail, got \(first)") }
        let partial = (try? Data(contentsOf: part))?.count ?? 0
        XCTAssertGreaterThan(partial, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: DirectFileJob.metadataURL(forPart: part).path))

        let second = await job("/v.mp4", part: part).run()
        XCTAssertEqual(second, .completed(bytes: Int64(body.count), mimeType: "video/mp4"))
        XCTAssertEqual(try Data(contentsOf: part), body, "resumed file must be byte-identical")
        XCTAssertTrue(server.requests.last?.contains("Range: bytes=\(partial)-") == true, "second run must request only the rest")
    }

    func testResumeRefusedForADifferentMirror() async throws {
        let body = randomVideoBytes(2 * 1_048_576)
        var route = RangeHTTPServer.Route(body: body)
        route.cutAfterBytes = 700_000
        server.set("/v.mp4", route)
        let part = directory.appendingPathComponent("c.part")

        _ = await job("/v.mp4", part: part, key: "mirror-A").run()
        let outcome = await job("/v.mp4", part: part, key: "mirror-B").run()

        XCTAssertEqual(outcome, .completed(bytes: Int64(body.count), mimeType: "application/octet-stream"))
        XCTAssertFalse(server.requests.last?.contains("Range:") == true, "a different mirror must restart from zero")
        XCTAssertEqual(try Data(contentsOf: part), body)
    }

    func testPlaylistServedAsVideoIsHandedToFFmpeg() async throws {
        var body = Data("#EXTM3U\n#EXT-X-VERSION:3\n".utf8)
        body.append(randomVideoBytes(600_000))
        server.set("/fake.mp4", .init(body: body))
        let outcome = await job("/fake.mp4", part: directory.appendingPathComponent("d.part")).run()
        XCTAssertEqual(outcome, .notDirect)
    }

    func testDASHManifestServedAsFileIsHandedToFFmpeg() async throws {
        // Q6: by content type, and by its first bytes when mislabelled.
        var mpd = Data(#"<?xml version="1.0"?><MPD xmlns="urn:mpeg:dash:schema:mpd:2011"><Period/></MPD>"#.utf8)
        mpd.append(Data(repeating: 0x20, count: 600_000))
        server.set("/typed.mpd", .init(body: mpd, contentType: "application/dash+xml"))
        server.set("/disguised.bin", .init(body: mpd, contentType: "application/octet-stream"))
        let typed = await job("/typed.mpd", part: directory.appendingPathComponent("mpd-a.part")).run()
        XCTAssertEqual(typed, .notDirect)
        let disguised = await job("/disguised.bin", part: directory.appendingPathComponent("mpd-b.part")).run()
        XCTAssertEqual(disguised, .notDirect)
    }

    func testHTMLAndHTTPErrorsAreClassified() async throws {
        server.set("/page", .init(body: Data("<html>blocked</html>".utf8), contentType: "text/html"))
        server.set("/denied", .init(body: Data(), status: 403))
        let html = await job("/page", part: directory.appendingPathComponent("e.part")).run()
        XCTAssertEqual(html, .failed(.invalidMedia))
        let denied = await job("/denied", part: directory.appendingPathComponent("f.part")).run()
        XCTAssertEqual(denied, .failed(.forbidden))
        let missing = await job("/missing", part: directory.appendingPathComponent("g.part")).run()
        XCTAssertEqual(missing, .failed(.notFound))
    }

    func testTinyBodyIsNotAVideo() async throws {
        server.set("/tiny.mp4", .init(body: randomVideoBytes(10_000)))
        let outcome = await job("/tiny.mp4", part: directory.appendingPathComponent("h.part")).run()
        XCTAssertEqual(outcome, .failed(.invalidMedia))
    }

    func testCancellationKeepsPartialForResume() async throws {
        var route = RangeHTTPServer.Route(body: randomVideoBytes(4 * 1_048_576))
        route.chunkDelay = 0.05
        server.set("/slow.mp4", route)
        let part = directory.appendingPathComponent("i.part")
        let transfer = job("/slow.mp4", part: part)

        let task = Task { await transfer.run() }
        try await Task.sleep(for: .milliseconds(400))
        transfer.cancel()
        let outcome = await task.value

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: part.path))
        route.chunkDelay = 0
        server.set("/slow.mp4", route)
        let resumed = await job("/slow.mp4", part: part).run()
        XCTAssertEqual(resumed, .completed(bytes: Int64(route.body.count), mimeType: "application/octet-stream"))
        XCTAssertEqual(try Data(contentsOf: part), route.body)
        XCTAssertTrue(server.requests.last?.contains("Range: bytes=") == true)
    }
}

// MARK: - ffmpeg remux (real bundled binary)

final class FFmpegJobTests: XCTestCase {
    private var server: RangeHTTPServer!
    private var directory: URL!
    private var ffmpeg: URL!

    override func setUpWithError() throws {
        guard let path = DownloadService.ffmpegBinaryPath() else { throw XCTSkip("ffmpeg not bundled") }
        ffmpeg = URL(fileURLWithPath: path)
        server = try RangeHTTPServer()
        directory = try makeTempDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        server = nil
    }

    private func serveHLS(seconds: Int = 12, size: String = "160x120") throws {
        try serveGeneratedHLS(ffmpeg: ffmpeg, in: directory, server: server, seconds: seconds, size: size)
    }

    private func run(_ url: String, format: String = "mp4", allowUnsafeTestInput: Bool = false) async throws -> (FFmpegJob.Outcome, URL) {
        let output = directory.appendingPathComponent("out-\(UUID().uuidString).part")
        let link = StreamLinkDto(url: allowUnsafeTestInput ? "https://fixture.invalid/placeholder.m3u8" : url, name: "n", source: "s", quality: 720, type: "M3U8")
        var arguments = try DownloadService.ffmpegArguments(link: link, outputPath: output.path, format: format)
        if allowUnsafeTestInput, let index = arguments.firstIndex(of: "-i") { arguments[index + 1] = url }
        let job = FFmpegJob(
            executableURL: ffmpeg,
            arguments: arguments,
            onProgress: { _ in },
            onInputDuration: { _ in },
        )
        return (await job.run { _ in }, output)
    }

    func testRemuxesHLSAndReportsDuration() async throws {
        try serveHLS()
        let (outcome, output) = try await run(server.url("/hls/index.m3u8"))
        XCTAssertEqual(outcome.exitStatus, 0, outcome.stderrTail)
        XCTAssertEqual(outcome.inputDurationSeconds ?? 0, 12, accuracy: 1)
        XCTAssertEqual(outcome.lastOutTimeSeconds, 12, accuracy: 1)
        XCTAssertFalse(DownloadPolicy.isTruncated(written: outcome.lastOutTimeSeconds, expected: outcome.inputDurationSeconds))
        let size = (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int64) ?? 0
        XCTAssertGreaterThan(size, 10_000)
    }

    func testPlaylistCannotReachLocalFiles() async throws {
        // A hostile playlist pointing a segment at the local filesystem.
        let playlist = "#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4.0,\nfile:///etc/hosts\n#EXT-X-ENDLIST\n"
        server.set("/evil.m3u8", .init(body: Data(playlist.utf8), contentType: "application/vnd.apple.mpegurl"))
        let (outcome, output) = try await run(server.url("/evil.m3u8"))
        let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int64) ?? 0
        XCTAssertTrue(outcome.exitStatus != 0 || size == 0, "file:// must never be read")
        let hosts = (try? Data(contentsOf: URL(fileURLWithPath: "/etc/hosts"))) ?? Data()
        if let written = try? Data(contentsOf: output), !hosts.isEmpty {
            XCTAssertNil(written.range(of: hosts.prefix(32)), "local file content leaked into the output")
        }
    }

    /// The whitelist itself (ffmpeg's HLS extension check above is a second,
    /// independent layer): a `file:` input must be refused outright even if
    /// it slipped past `isAllowedRemoteURL`.
    func testWhitelistRefusesLocalFileInput() async throws {
        let (outcome, output) = try await run("file:///etc/hosts", allowUnsafeTestInput: true)
        XCTAssertNotEqual(outcome.exitStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path) &&
            ((try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int64) ?? 0) > 0)
    }

    func testMissingStreamClassifiesAsNotFound() async throws {
        let (outcome, _) = try await run(server.url("/nope.m3u8"))
        XCTAssertNotEqual(outcome.exitStatus, 0)
        XCTAssertEqual(DownloadPolicy.classifyFFmpegFailure(exitStatus: outcome.exitStatus, stderrTail: outcome.stderrTail), .notFound)
    }

    func testTerminateStopsAPausedProcess() async throws {
        try serveHLS(seconds: 12, size: "640x480")
        // Throttle segments so the run is still going when we pause.
        let hls = directory.appendingPathComponent("hls", isDirectory: true)
        for file in try FileManager.default.contentsOfDirectory(at: hls, includingPropertiesForKeys: nil)
            where file.pathExtension == "ts" {
            var route = RangeHTTPServer.Route(body: try Data(contentsOf: file), contentType: "video/mp2t")
            route.chunkDelay = 0.3
            server.set("/hls/\(file.lastPathComponent)", route)
        }
        let output = directory.appendingPathComponent("p.part")
        let link = StreamLinkDto(url: server.url("/hls/index.m3u8"), name: "n", source: "s", quality: 720, type: "M3U8")
        let job = FFmpegJob(
            executableURL: ffmpeg,
            arguments: try DownloadService.ffmpegArguments(link: link, outputPath: output.path, format: "mp4"),
            onProgress: { _ in },
            onInputDuration: { _ in },
        )
        let task = Task { await job.run { _ in } }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(job.suspend())
        job.terminate() // must SIGCONT first or the stopped process ignores SIGTERM
        let started = Date()
        let outcome = await task.value
        XCTAssertTrue(outcome.wasTerminated)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "a paused process must still stop promptly")
    }
}

// MARK: - Queue behavior (end-to-end, injected resolver)

@MainActor
final class DownloadQueueEndToEndTests: XCTestCase {
    private var server: RangeHTTPServer!
    private var directory: URL!
    private var savedReady: (() -> Bool)!
    private var savedEngineFailure: (() -> String?)!
    private var savedEngineWait: (() async throws -> Void)?
    private var savedResolver: ((String, String) async throws -> LinksResponseDto)!
    private var resolveCount = 0

    override func setUp() async throws {
        server = try RangeHTTPServer()
        directory = try makeTempDirectory()
        let service = DownloadService.shared
        savedReady = service.isEngineReady
        savedEngineFailure = service.engineFailure
        savedEngineWait = service.engineWait
        service.engineWait = nil
        savedResolver = service.linkResolver
        service.isEngineReady = { true }
    }

    override func tearDown() async throws {
        let service = DownloadService.shared
        for item in service.queue where item.provider.hasPrefix("E2E") {
            if item.state == .completed {
                service.deleteCompleted(item)
            } else {
                service.removeFromQueue(item)
            }
        }
        service.isEngineReady = savedReady
        service.engineFailure = savedEngineFailure
        service.engineWait = savedEngineWait
        service.linkResolver = savedResolver
        try? FileManager.default.removeItem(at: directory)
        server = nil
    }

    private func resolve(to links: [StreamLinkDto], subtitles: [SubtitleDto] = []) {
        DownloadService.shared.linkResolver = { [weak self] provider, _ in
            await MainActor.run { self?.resolveCount += 1 }
            return LinksResponseDto(provider: provider, links: links, subtitles: subtitles)
        }
    }

    private func request(_ name: String, provider: String = "E2E") -> DownloadService.Request {
        DownloadService.Request(
            title: name, episodeLabel: "Movie", provider: provider,
            episodeData: "data-\(UUID().uuidString)", directory: directory, baseName: name, durationSeconds: nil,
        )
    }

    private func item(for request: DownloadService.Request) -> DownloadService.QueueItem? {
        DownloadService.shared.activeItem(forProvider: request.provider, episodeData: request.episodeData)
            ?? DownloadService.shared.queueItem(forProvider: request.provider, episodeData: request.episodeData)
    }

    private func waitFor(_ item: DownloadService.QueueItem, timeout: TimeInterval = 20, _ condition: (DownloadService.QueueItem) -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition(item) {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    func testAdmissionSaveFailureDoesNotStartResolutionOrClaimEnqueued() throws {
        enum Fault: Error { case save }
        let store = LibraryStore.shared
        let oldFault = store.persistenceFault
        defer { store.persistenceFault = oldFault }
        resolve(to: [])
        store.persistenceFault = { if $0 == .mutationCommit { throw Fault.save } }
        let req = request("Admission failure")
        XCTAssertEqual(DownloadService.shared.enqueue(req), .persistenceFailed)
        let item = try XCTUnwrap(item(for: req))
        XCTAssertEqual(item.state, .failed)
        XCTAssertEqual(resolveCount, 0)
        XCTAssertFalse(try store.downloadRecords().contains { $0.id == item.id })
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.partURL.path))
    }

    func testCompletionSaveFailureDoesNotClaimDurableCompletion() async throws {
        enum Fault: Error { case save }
        let store = LibraryStore.shared
        let service = DownloadService.shared
        let oldFault = store.persistenceFault
        defer { store.persistenceFault = oldFault }
        let body = randomVideoBytes(1_000_000)
        server.set("/saved.mp4", .init(body: body))
        resolve(to: [StreamLinkDto(url: server.url("/saved.mp4"), name: "fixture", source: "s", quality: 720, type: "VIDEO")])
        let req = request("Completion persistence failure")
        store.persistenceFault = { boundary in
            if boundary == .mutationCommit,
               service.queue.first(where: { $0.episodeData == req.episodeData })?.state == .completed {
                throw Fault.save
            }
        }
        XCTAssertEqual(service.enqueue(req), .enqueued)
        let item = try XCTUnwrap(item(for: req))
        await waitFor(item) { $0.state.isFinished }
        XCTAssertEqual(item.state, .failed)
        XCTAssertTrue(item.failureReason?.label.contains("save download state") == true)
        XCTAssertNotEqual(try store.downloadRecords().first { $0.id == item.id }?.status, .completed)
        XCTAssertEqual(try Data(contentsOf: item.destinationURL), body, "A failed commit must not discard the playable final file")
    }

    /// Credentialed downloads go through a real engine's relay (audit A2); the
    /// seam is restored afterwards.
    private func useRelay(of engine: LiveEngine) {
        let client = engine.client
        DownloadService.shared.relayRegistrar = { try await client.registerMediaRelay($0) }
        DownloadService.shared.relayRevoker = { await client.revokeMediaRelay(sessionID: $0) }
        addTeardownBlock { @MainActor in
            DownloadService.shared.relayRegistrar = { try await DaemonClient.shared.registerMediaRelay($0) }
            DownloadService.shared.relayRevoker = { await DaemonClient.shared.revokeMediaRelay(sessionID: $0) }
        }
    }

    func testDirectVideoWithSeparateAudioCompletesThroughRealRemux() async throws {
        guard let binary = DownloadService.ffmpegBinaryPath() else { throw XCTSkip("ffmpeg not bundled") }
        let split = try serveSplitFiles(ffmpeg: URL(fileURLWithPath: binary), in: directory, server: server)
        let engine = try await LiveEngine.start()
        defer { engine.stop() }
        useRelay(of: engine)
        resolve(to: [split])
        let req = request("Split Direct Movie")
        XCTAssertEqual(DownloadService.shared.enqueue(req), .enqueued)
        let item = try XCTUnwrap(item(for: req))
        await waitFor(item) { $0.state.isFinished }
        XCTAssertEqual(item.state, .completed, item.failureReason?.label ?? "")
        // The relay, not ffmpeg, sends each input's own credentials.
        XCTAssertTrue(server.requests.contains { $0.hasPrefix("GET /split-video.mp4") && $0.contains("Cookie: video=1") })
        XCTAssertTrue(server.requests.contains { $0.hasPrefix("GET /split-audio.m4a") && $0.contains("Cookie: audio=2") })
        // Inspect the saved container, not only the invocation or queue state.
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: binary)
        probe.arguments = ["-hide_banner", "-i", item.destinationURL.path]
        let stderr = Pipe()
        probe.standardError = stderr
        try probe.run()
        let inspection = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        probe.waitUntilExit()
        XCTAssertTrue(inspection.contains("Video: h264"), inspection)
        XCTAssertTrue(inspection.contains("Audio: aac"), "Saved direct video must retain separate audio: \(inspection)")
    }

    func testCredentialedHLSDownloadsThroughTheRelayWithoutCredentialsInArgv() async throws {
        // A2: a cookie-protected playlist, its segments and key all come through the engine relay.
        guard let binary = DownloadService.ffmpegBinaryPath() else { throw XCTSkip("ffmpeg not bundled") }
        let hls = try serveGeneratedHLS(ffmpeg: URL(fileURLWithPath: binary), in: directory, server: server, seconds: 8)
        for file in try FileManager.default.contentsOfDirectory(at: hls, includingPropertiesForKeys: nil) {
            let type = file.pathExtension == "m3u8" ? "application/vnd.apple.mpegurl" : "video/mp2t"
            server.set("/hls/\(file.lastPathComponent)", .init(body: try Data(contentsOf: file), contentType: type, requiredHeader: "Cookie: session=s3cret"))
        }
        let engine = try await LiveEngine.start()
        defer { engine.stop() }
        useRelay(of: engine)
        resolve(to: [StreamLinkDto(url: server.url("/hls/index.m3u8"), name: "Protected", source: "s", quality: 720, type: "M3U8",
                                   headers: ["Cookie": "session=s3cret", "Referer": "https://site.example/"])])
        let req = request("Protected HLS")
        XCTAssertEqual(DownloadService.shared.enqueue(req), .enqueued)
        let item = try XCTUnwrap(item(for: req))
        await waitFor(item, timeout: 60) { $0.state.isFinished }
        XCTAssertEqual(item.state, .completed, item.failureReason?.label ?? "")
        let segments = server.requests.filter { $0.hasPrefix("GET /hls/seg") }
        XCTAssertFalse(segments.isEmpty)
        XCTAssertTrue(segments.allSatisfy { $0.contains("Cookie: session=s3cret") }, "every segment was fetched with the provider's cookie")
        XCTAssertTrue(server.requests.allSatisfy { !$0.contains("Lavf") }, "nothing reached the origin from ffmpeg directly")
        DownloadService.shared.deleteCompleted(recordID: item.id, provider: req.provider, destinationURL: item.destinationURL)
    }

    func testCredentialedDownloadFailsClosedWhenTheRelayIsUnavailable() async throws {
        let service = DownloadService.shared
        service.relayRegistrar = { _ in throw DaemonClient.DaemonError.notReady }
        addTeardownBlock { @MainActor in
            DownloadService.shared.relayRegistrar = { try await DaemonClient.shared.registerMediaRelay($0) }
        }
        server.set("/closed.m3u8", .init(body: Data("#EXTM3U\n".utf8), contentType: "application/vnd.apple.mpegurl"))
        resolve(to: [StreamLinkDto(url: server.url("/closed.m3u8"), name: "Closed", source: "s", quality: 720, type: "M3U8",
                                   headers: ["Authorization": "Bearer provider-secret"])])
        let req = request("Relay Closed")
        XCTAssertEqual(service.enqueue(req), .enqueued)
        let item = try XCTUnwrap(item(for: req))
        await waitFor(item, timeout: 60) { $0.state.isFinished }
        XCTAssertEqual(item.state, .failed)
        XCTAssertEqual(item.failureReason, .relayUnavailable)
        XCTAssertTrue(server.requests.isEmpty, "the credentials were never sent anywhere without the relay")
    }

    // MARK: Admission, finalization journal and deletion (audit A29–A31)

    private func downloadingCount() -> Int { DownloadService.shared.queue.filter { $0.state == .downloading && $0.provider.hasPrefix("E2E") }.count }

    func testFrozenTransfersReacquireAdmissionAndRespectTheNetworkHold() async throws {
        guard let binary = DownloadService.ffmpegBinaryPath() else { throw XCTSkip("ffmpeg not bundled") }
        let service = DownloadService.shared
        let preferences = UserPreferences.shared
        let (savedTotal, savedPerProvider) = (preferences.maxConcurrentDownloads, preferences.maxDownloadsPerProvider)
        preferences.maxConcurrentDownloads = 1
        preferences.maxDownloadsPerProvider = 1
        defer {
            preferences.maxConcurrentDownloads = savedTotal
            preferences.maxDownloadsPerProvider = savedPerProvider
            if service.isNetworkSuspended { service.resumeAfterNetworkReturn() }
        }
        _ = try serveGeneratedHLS(ffmpeg: URL(fileURLWithPath: binary), in: directory, server: server, seconds: 12, size: "640x480")
        for file in try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("hls"), includingPropertiesForKeys: nil)
            where file.pathExtension == "ts" {
            var route = RangeHTTPServer.Route(body: try Data(contentsOf: file), contentType: "video/mp2t")
            route.chunkDelay = 0.4
            server.set("/hls/\(file.lastPathComponent)", route)
        }
        resolve(to: [StreamLinkDto(url: server.url("/hls/index.m3u8"), name: "hls", source: "s", quality: 720, type: "M3U8")])

        let first = request("Frozen A"), second = request("Replacement B")
        XCTAssertEqual(service.enqueue(first), .enqueued)
        let a = try XCTUnwrap(item(for: first))
        await waitFor(a) { $0.state == .downloading }
        XCTAssertEqual(a.state, .downloading, "queue: \(service.queue.map { "\($0.provider)/\($0.title)=\($0.state) \($0.statusDetail ?? "")" }), suspended: \(service.isNetworkSuspended)")
        service.pause(a)
        XCTAssertEqual(a.state, .paused, "the remux is frozen, not stopped")

        XCTAssertEqual(service.enqueue(second), .enqueued)
        let b = try XCTUnwrap(item(for: second))
        await waitFor(b) { $0.state == .downloading }
        XCTAssertEqual(b.state, .downloading, "the paused transfer freed its slot")

        // Resuming the frozen process must not exceed the limit of one.
        service.resume(a)
        XCTAssertEqual(a.state, .paused)
        XCTAssertTrue(a.resumeRequested)
        XCTAssertEqual(downloadingCount(), 1)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(downloadingCount(), 1)

        // Its slot arrives when the replacement leaves.
        service.cancel(b)
        await waitFor(a) { $0.state == .downloading }
        XCTAssertEqual(a.state, .downloading)
        XCTAssertFalse(a.resumeRequested)

        // Offline: a manual resume is held until the path returns.
        service.suspendForNetworkLoss()
        XCTAssertEqual(a.state, .paused)
        service.resume(a)
        XCTAssertEqual(a.state, .paused, "no SIGCONT while offline")
        XCTAssertEqual(downloadingCount(), 0)
        service.resumeAfterNetworkReturn()
        await waitFor(a) { $0.state == .downloading }
        XCTAssertEqual(a.state, .downloading)

        // A user pause during a network hold stays paused on reconnect.
        service.suspendForNetworkLoss()
        service.pause(a)
        service.resumeAfterNetworkReturn()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(a.state, .paused)
        XCTAssertFalse(a.resumeRequested)
        service.cancel(a)
    }

    func testResolutionFinishingWhileOfflineDoesNotStartTheTransfer() async throws {
        let service = DownloadService.shared
        defer { if service.isNetworkSuspended { service.resumeAfterNetworkReturn() } }
        let body = randomVideoBytes(700_000)
        server.set("/held.mp4", .init(body: body))
        let link = StreamLinkDto(url: server.url("/held.mp4"), name: "a", source: "s", quality: 720, type: "VIDEO")
        let gate = ResolutionGate()
        service.linkResolver = { provider, _ in
            await gate.wait()
            return LinksResponseDto(provider: provider, links: [link], subtitles: [])
        }
        let req = request("Held Offline")
        XCTAssertEqual(service.enqueue(req), .enqueued)
        let item = try XCTUnwrap(item(for: req))
        await waitFor(item) { $0.state == .resolving }
        service.suspendForNetworkLoss()
        await gate.open()
        await waitFor(item) { $0.state == .queued }
        XCTAssertEqual(item.state, .queued)
        XCTAssertEqual(item.statusDetail, "Waiting for network")
        XCTAssertFalse(server.requests.contains { $0.hasPrefix("GET /held.mp4") }, "no IO started during the hold")
        service.resumeAfterNetworkReturn()
        await waitFor(item) { $0.state.isFinished }
        XCTAssertEqual(item.state, .completed, item.failureReason?.label ?? "")
    }

    func testInterruptedFinalizationRecoversAtEveryBoundaryWithoutDuplicates() async throws {
        let service = DownloadService.shared
        defer { service.finalizationFault = nil }
        for boundary in DownloadService.FinalizationBoundary.allCases {
            let body = randomVideoBytes(700_000)
            server.set("/final-\(boundary).mp4", .init(body: body))
            resolve(to: [StreamLinkDto(url: server.url("/final-\(boundary).mp4"), name: "a", source: "s", quality: 720, type: "VIDEO")])
            service.finalizationFault = { $0 == boundary }
            let req = request("Finalize \(boundary)")
            XCTAssertEqual(service.enqueue(req), .enqueued)
            let item = try XCTUnwrap(item(for: req))
            await waitFor(item) { $0.state == .finalizing || $0.state == .completed }
            try await Task.sleep(for: .milliseconds(100))
            let id = item.id
            let final = item.destinationURL
            let durable = try XCTUnwrap(try LibraryStore.shared.downloadRecord(id: id))
            XCTAssertEqual(durable.status, boundary == .completionSaved ? .completed : .finalizing, "\(boundary)")
            XCTAssertEqual(durable.destinationPath, final.path, "the planned final path is journaled before the rename")

            // "Relaunch": forget the in-memory item, restore from the store.
            service.finalizationFault = nil
            service.discardInMemoryItem(id: id)
            try service.retryRestoringQueue()
            let record = try XCTUnwrap(try LibraryStore.shared.downloadRecord(id: id))
            XCTAssertEqual(record.status, .completed, "\(boundary)")
            XCTAssertEqual(try Data(contentsOf: final), body, "\(boundary): the saved bytes are the downloaded entity")
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("Finalize \(boundary)") }
            XCTAssertEqual(names.filter { !$0.hasSuffix(".json") }, [final.lastPathComponent], "\(boundary): no duplicate, part or re-download")
            XCTAssertEqual(server.requests.filter { $0.hasPrefix("GET /final-\(boundary).mp4") }.count, 1)
            service.deleteCompleted(recordID: id, provider: req.provider, destinationURL: final)
        }
    }

    func testFailedFinalRenameKeepsThePartAndRetryCompletesIt() async throws {
        let service = DownloadService.shared
        defer { service.finalizationRenameFault = nil }
        let body = randomVideoBytes(700_000)
        server.set("/rename-fails.mp4", .init(body: body))
        resolve(to: [StreamLinkDto(url: server.url("/rename-fails.mp4"), name: "a", source: "s", quality: 720, type: "VIDEO")])
        service.finalizationRenameFault = { CocoaError(.fileWriteNoPermission) }
        let req = request("Rename Fails")
        XCTAssertEqual(service.enqueue(req), .enqueued)
        let item = try XCTUnwrap(item(for: req))
        await waitFor(item) { $0.state.isFinished }
        XCTAssertEqual(item.state, .failed)
        guard case .finalizeFailed = item.failureReason else { return XCTFail("unexpected \(String(describing: item.failureReason))") }
        XCTAssertEqual(item.failureReason?.disposition, .terminal, "a finished transfer is not downloaded again")
        XCTAssertEqual(try Data(contentsOf: item.partURL), body, "the finished part survives")
        let durable = try XCTUnwrap(try LibraryStore.shared.downloadRecord(id: item.id))
        XCTAssertEqual(durable.status, .finalizing, "stored as finalizing so a relaunch retries the rename")

        // Retry completes the rename without another request.
        service.finalizationRenameFault = nil
        let requests = server.requests.filter { $0.hasPrefix("GET /rename-fails.mp4") }.count
        service.retry(item)
        XCTAssertEqual(item.state, .completed)
        XCTAssertEqual(try Data(contentsOf: item.destinationURL), body)
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.partURL.path))
        XCTAssertEqual(server.requests.filter { $0.hasPrefix("GET /rename-fails.mp4") }.count, requests, "no re-download")
        XCTAssertEqual(try XCTUnwrap(try LibraryStore.shared.downloadRecord(id: item.id)).status, .completed)
        service.deleteCompleted(recordID: item.id, provider: req.provider, destinationURL: item.destinationURL)
    }

    func testFailedFinalRenameIsReconciledAtTheNextLaunch() async throws {
        let service = DownloadService.shared
        defer { service.finalizationRenameFault = nil }
        let body = randomVideoBytes(700_000)
        server.set("/rename-relaunch.mp4", .init(body: body))
        resolve(to: [StreamLinkDto(url: server.url("/rename-relaunch.mp4"), name: "a", source: "s", quality: 720, type: "VIDEO")])
        service.finalizationRenameFault = { CocoaError(.fileWriteVolumeReadOnly) }
        let req = request("Rename Relaunch")
        XCTAssertEqual(service.enqueue(req), .enqueued)
        let item = try XCTUnwrap(item(for: req))
        await waitFor(item) { $0.state.isFinished }
        let id = item.id
        service.finalizationRenameFault = nil
        service.discardInMemoryItem(id: id)
        try service.retryRestoringQueue()
        let record = try XCTUnwrap(try LibraryStore.shared.downloadRecord(id: id))
        XCTAssertEqual(record.status, .completed)
        XCTAssertEqual(try Data(contentsOf: record.destinationURL), body)
        XCTAssertEqual(server.requests.filter { $0.hasPrefix("GET /rename-relaunch.mp4") }.count, 1)
        service.deleteCompleted(recordID: id, provider: req.provider, destinationURL: record.destinationURL)
    }

    /// The same three boundaries as above, but the process doing the work is
    /// killed with SIGKILL and another process reopens its store. Needs the
    /// separate debug app the compatibility command provisions.
    func testKilledFinalizationIsReconciledByTheNextProcessAtEveryBoundary() async throws {
        guard let app = ProcessInfo.processInfo.environment["CS_IDENTITY_PROCESS_APP"],
              FileManager.default.isExecutableFile(atPath: app) else {
            throw XCTSkip("Run the identity compatibility command to provision a separate debug app process")
        }
        for phase in ["intent-saved", "renamed", "completion-saved"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("download-kill-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let body = randomVideoBytes(700_000)
            server.set("/killed-\(phase).mp4", .init(body: body))

            let killed = try child(app, root: root, phase: phase, url: server.url("/killed-\(phase).mp4"))
            defer { if killed.isRunning { kill(killed.processIdentifier, SIGKILL) } }
            let ready = root.appendingPathComponent("download-process-ready")
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            while !FileManager.default.fileExists(atPath: ready.path) {
                guard killed.isRunning, ContinuousClock.now < deadline else {
                    return XCTFail("\(phase): the download process never reached the boundary (exit \(killed.isRunning ? -1 : killed.terminationStatus))")
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(kill(killed.processIdentifier, SIGKILL), 0)
            killed.waitUntilExit()
            XCTAssertEqual(killed.terminationReason, .uncaughtSignal, phase)

            // What the killed process left on disk.
            let downloads = root.appendingPathComponent("Downloads")
            let final = downloads.appendingPathComponent("Killed.mp4")
            func files() throws -> [String] {
                try FileManager.default.contentsOfDirectory(atPath: downloads.path).filter { !$0.hasSuffix(".json") }.sorted()
            }
            XCTAssertEqual(try files(), [phase == "intent-saved" ? "Killed.part" : "Killed.mp4"], phase)

            // The next launch: a new process reopens the same store.
            let next = try child(app, root: root, phase: "reconcile", url: nil)
            defer { if next.isRunning { kill(next.processIdentifier, SIGKILL) } }
            let exitDeadline = ContinuousClock.now.advanced(by: .seconds(30))
            while next.isRunning, ContinuousClock.now < exitDeadline { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertFalse(next.isRunning, phase)
            XCTAssertEqual(next.terminationStatus, 0, phase)
            let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("reconcile-report.json"))) as? [[String: Any]])
            XCTAssertEqual(report.count, 1, phase)
            XCTAssertEqual(report.first?["status"] as? Int, DownloadService.ItemState.completed.rawValue, "\(phase): \(report)")
            XCTAssertEqual(report.first?["path"] as? String, final.path, phase)
            XCTAssertEqual(try files(), ["Killed.mp4"], "\(phase): no part, duplicate or second copy")
            XCTAssertEqual(try Data(contentsOf: final), body, "\(phase): the saved bytes are the downloaded entity")
            XCTAssertEqual(server.requests.filter { $0.hasPrefix("GET /killed-\(phase).mp4") }.count, 1, "\(phase): nothing was downloaded again")
        }
    }

    private func child(_ app: String, root: URL, phase: String, url: String?) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: app)
        var environment = ["CS_IN_MEMORY_DB": "1", "CS_TEST_ROOT": root.path, "CS_DOWNLOAD_PROCESS_PHASE": phase]
        if let url { environment["CS_DOWNLOAD_PROCESS_URL"] = url }
        process.environment = environment
        let logURL = root.appendingPathComponent("child-\(phase).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        process.standardOutput = log
        process.standardError = log
        process.standardInput = FileHandle.nullDevice
        try process.run()
        return process
    }

    func testFinalizingConflictsAreReportedAndNeverOverwritten() throws {
        let service = DownloadService.shared
        func journal(_ name: String, bytes: Int64, part: Data?, final: Data?) throws -> (UUID, URL) {
            let id = UUID()
            let url = directory.appendingPathComponent(name + ".mp4")
            if let part { try part.write(to: directory.appendingPathComponent(name + ".part")) }
            if let final { try final.write(to: url) }
            try LibraryStore.shared.upsertDownloadRecord(id: id, title: name, episodeLabel: "Movie", provider: "E2E",
                episodeData: "journal-\(id)", destinationPath: url.path, statusRaw: DownloadService.ItemState.finalizing.rawValue, bytesWritten: bytes)
            return (id, url)
        }
        let other = Data("someone else's file".utf8), ours = Data(repeating: 9, count: 2048)
        let (both, bothURL) = try journal("Both", bytes: 2048, part: ours, final: other)
        let (wrong, wrongURL) = try journal("Wrong size", bytes: 2048, part: nil, final: other)
        let (gone, _) = try journal("Gone", bytes: 2048, part: nil, final: nil)
        let (unplugged, _) = (UUID(), ())
        try LibraryStore.shared.upsertDownloadRecord(id: unplugged, title: "Unplugged", episodeLabel: "Movie", provider: "E2E",
            episodeData: "journal-\(unplugged)", destinationPath: "/Volumes/cs-absent-\(UUID().uuidString)/Unplugged.mp4",
            statusRaw: DownloadService.ItemState.finalizing.rawValue, bytesWritten: 2048)
        try service.retryRestoringQueue()
        for id in [both, wrong, gone] {
            XCTAssertEqual(service.queue.first { $0.id == id }?.state, .failed)
            XCTAssertEqual(try LibraryStore.shared.downloadRecord(id: id)?.status, .failed)
        }
        XCTAssertEqual(try Data(contentsOf: bothURL), other, "an existing file at the planned path is not overwritten")
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("Both.part")), ours, "the finished part is kept for the user")
        XCTAssertEqual(try Data(contentsOf: wrongURL), other)
        XCTAssertEqual(service.queue.first { $0.id == unplugged }?.state, .paused, "an unplugged disk is not a missing file")
        XCTAssertEqual(try LibraryStore.shared.downloadRecord(id: unplugged)?.status, .finalizing, "the journal waits for the disk")
    }

    func testDeletionReportsWhatHappenedAndKeepsRecordsUntilTheVideoIsGone() throws {
        let service = DownloadService.shared
        let store = LibraryStore.shared
        func completed(_ name: String, at url: URL, write: Bool = true) throws -> UUID {
            let id = UUID()
            if write { try Data(repeating: 1, count: 128).write(to: url) }
            try store.upsertDownloadRecord(id: id, title: name, episodeLabel: "Movie", provider: "E2E",
                episodeData: "delete-\(id)", destinationPath: url.path, statusRaw: 4)
            addTeardownBlock { @MainActor in try? store.deleteDownloadRecord(id: id) }
            return id
        }
        func exists(_ id: UUID) throws -> Bool { try store.downloadRecord(id: id) != nil }

        // Missing file: nothing is forgotten implicitly; forgetting is explicit.
        let missingURL = directory.appendingPathComponent("missing.mp4")
        let missing = try completed("Missing", at: missingURL, write: false)
        XCTAssertEqual(service.deleteCompleted(recordID: missing, provider: "E2E", destinationURL: missingURL), .fileMissing)
        XCTAssertTrue(try exists(missing))
        XCTAssertEqual(service.forgetMissingDownload(recordID: missing, provider: "E2E", destinationURL: missingURL), .deleted(sidecarFailures: []))
        XCTAssertFalse(try exists(missing))

        // Unplugged volume: unavailable, and it cannot be "forgotten" either.
        let unpluggedURL = URL(fileURLWithPath: "/Volumes/cs-absent-\(UUID().uuidString)/video.mp4")
        let unplugged = try completed("Unplugged", at: unpluggedURL, write: false)
        XCTAssertEqual(service.deleteCompleted(recordID: unplugged, provider: "E2E", destinationURL: unpluggedURL), .volumeUnavailable)
        XCTAssertEqual(service.forgetMissingDownload(recordID: unplugged, provider: "E2E", destinationURL: unpluggedURL), .volumeUnavailable)
        XCTAssertTrue(try exists(unplugged))

        // Read-only folder: the video stays, so does its record, and the intent is withdrawn.
        let locked = directory.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        let lockedURL = locked.appendingPathComponent("video.mp4")
        let readOnly = try completed("Read only", at: lockedURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        guard case .failed = service.deleteCompleted(recordID: readOnly, provider: "E2E", destinationURL: lockedURL) else {
            return XCTFail("a refused removal is a failure")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockedURL.path))
        XCTAssertNil(try store.downloadRecord(id: readOnly)?.deletionRequestedAt)
        XCTAssertEqual(try store.downloadRecord(id: readOnly)?.status, .completed)

        // Intent cannot be saved: neither the file nor the record is touched.
        enum Fault: Error { case save }
        let oldFault = store.persistenceFault
        defer { store.persistenceFault = oldFault }
        let keptURL = directory.appendingPathComponent("kept.mp4")
        let kept = try completed("Kept", at: keptURL)
        store.persistenceFault = { if $0 == .mutationCommit { throw Fault.save } }
        guard case .failed = service.deleteCompleted(recordID: kept, provider: "E2E", destinationURL: keptURL) else { return XCTFail() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: keptURL.path))
        store.persistenceFault = oldFault
        XCTAssertNil(try store.downloadRecord(id: kept)?.deletionRequestedAt)

        // Video removed, record commit fails: the saved intent finishes it later.
        let goneURL = directory.appendingPathComponent("gone.mp4")
        try Data("WEBVTT".utf8).write(to: directory.appendingPathComponent("gone.English.vtt"))
        let gone = try completed("Gone", at: goneURL)
        var commits = 0
        store.persistenceFault = { if $0 == .mutationCommit { commits += 1; if commits > 1 { throw Fault.save } } }
        guard case .failed(let detail) = service.deleteCompleted(recordID: gone, provider: "E2E", destinationURL: goneURL) else { return XCTFail() }
        XCTAssertTrue(detail.contains("was deleted"), detail)
        XCTAssertFalse(FileManager.default.fileExists(atPath: goneURL.path))
        store.persistenceFault = oldFault
        XCTAssertNotNil(try store.downloadRecord(id: gone)?.deletionRequestedAt, "the intent was durable before the file was touched")
        try service.retryRestoringQueue()
        XCTAssertFalse(try exists(gone), "reconciliation completes the interrupted deletion")

        // Intent saved, then interrupted before the file was touched: the download stays.
        let intactURL = directory.appendingPathComponent("intact.mp4")
        let intact = try completed("Intact", at: intactURL)
        try store.setDownloadDeletionIntent(id: intact, at: Date())
        try service.retryRestoringQueue()
        XCTAssertNil(try store.downloadRecord(id: intact)?.deletionRequestedAt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: intactURL.path))

        // The ordinary case removes file, sidecar and record.
        try Data("WEBVTT".utf8).write(to: directory.appendingPathComponent("intact.English.vtt"))
        XCTAssertEqual(service.deleteCompleted(recordID: intact, provider: "E2E", destinationURL: intactURL), .deleted(sidecarFailures: []))
        XCTAssertFalse(try exists(intact))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("intact.English.vtt").path))
    }

    func testCompletedDownloadIsFiledByItsOriginProfileNotTheSelectedOne() async throws {
        let service = DownloadService.shared
        let (savedOrigin, savedStoreName) = (service.originProfile, service.profileStoreName)
        let savedAutoAdd = UserPreferences.shared.autoAddDownloadsToLibrary
        UserPreferences.shared.autoAddDownloadsToLibrary = true
        defer {
            service.originProfile = savedOrigin
            service.profileStoreName = savedStoreName
            UserPreferences.shared.autoAddDownloadsToLibrary = savedAutoAdd
        }
        func download(_ name: String) async throws -> DownloadService.QueueItem {
            server.set("/\(name).mp4", .init(body: randomVideoBytes(700_000)))
            resolve(to: [StreamLinkDto(url: server.url("/\(name).mp4"), name: "a", source: "s", quality: 720, type: "VIDEO")])
            let req = request(name)
            XCTAssertEqual(service.enqueue(req), .enqueued)
            let item = try XCTUnwrap(item(for: req))
            await waitFor(item) { $0.state.isFinished }
            XCTAssertEqual(item.state, .completed, item.failureReason?.label ?? "")
            return item
        }
        let app = AppState.shared
        app.dismissTransientError()

        // The profile that queued it was deleted: shared download kept, no library entry, and the user is told.
        let deleted = UUID()
        service.originProfile = { deleted }
        service.profileStoreName = { _ in nil }
        let orphaned = try await download("origin-deleted")
        XCTAssertEqual(try LibraryStore.shared.downloadRecord(id: orphaned.id)?.originProfileID, deleted)
        XCTAssertNil(try LibraryStore.shared.item(id: LibraryIdentity.localDownload(orphaned.id)))
        XCTAssertTrue(app.transientError?.contains("no longer exists") == true)
        app.dismissTransientError()

        // Legacy/unowned: nothing is filed until someone adds it explicitly.
        service.originProfile = { nil }
        let legacy = try await download("origin-legacy")
        XCTAssertNil(try LibraryStore.shared.item(id: LibraryIdentity.localDownload(legacy.id)))
        XCTAssertNil(app.transientError)
        service.addCompletedToCurrentLibrary(try XCTUnwrap(try LibraryStore.shared.downloadRecord(id: legacy.id)))
        XCTAssertNotNil(try LibraryStore.shared.item(id: LibraryIdentity.localDownload(legacy.id)))
    }

    func testFailedVideoDeletionPreservesDownloadRecord() throws {
        let id = UUID()
        let missing = directory.appendingPathComponent("missing.mp4")
        try LibraryStore.shared.upsertDownloadRecord(id: id, title: "Missing", episodeLabel: "Movie",
            provider: "E2E", episodeData: "missing", destinationPath: missing.path, statusRaw: 4)
        defer { try? LibraryStore.shared.deleteDownloadRecord(id: id) }
        DownloadService.shared.deleteCompleted(recordID: id, provider: "E2E", destinationURL: missing)
        XCTAssertTrue(try LibraryStore.shared.downloadRecords().contains { $0.id == id })
    }

    func testFailsOverToNextMirrorAndFinalizesAtomically() async throws {
        let body = randomVideoBytes(1_500_000)
        server.set("/good.mkv", .init(body: body, contentType: "video/x-matroska"))
        resolve(to: [
            StreamLinkDto(url: server.url("/dead.mp4"), name: "a", source: "s1", quality: 1080, type: "VIDEO"),
            StreamLinkDto(url: server.url("/good.mkv"), name: "b", source: "s2", quality: 720, type: "VIDEO"),
        ])
        let req = request("Failover Movie")
        XCTAssertEqual(DownloadService.shared.enqueue(req), .enqueued)
        let item = try XCTUnwrap(item(for: req))

        await waitFor(item) { $0.state.isFinished }

        XCTAssertEqual(item.state, .completed, item.failureReason?.label ?? "")
        XCTAssertEqual(item.activeLinkIndex, 1, "mirror 1 404'd, mirror 2 delivered")
        XCTAssertEqual(item.destinationURL.pathExtension, "mkv", "direct files keep their real container")
        XCTAssertEqual(try Data(contentsOf: item.destinationURL), body)
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.partURL.path), "no .part left behind")
        let record = DownloadService.shared.completedRecord(provider: req.provider, episodeData: req.episodeData)
        XCTAssertEqual(record?.destinationPath, item.destinationURL.path, "record follows the final path")
    }

    func testTransientErrorRetriesSameMirrorOnceThenFailsOver() async throws {
        server.set("/busy.mp4", .init(body: Data(), status: 503))
        let body = randomVideoBytes(900_000)
        server.set("/ok.mp4", .init(body: body))
        resolve(to: [
            StreamLinkDto(url: server.url("/busy.mp4"), name: "a", source: "s1", quality: 1080, type: "VIDEO"),
            StreamLinkDto(url: server.url("/ok.mp4"), name: "b", source: "s2", quality: 720, type: "VIDEO"),
        ])
        let req = request("Busy Movie")
        DownloadService.shared.enqueue(req)
        let item = try XCTUnwrap(item(for: req))
        await waitFor(item) { $0.state.isFinished }

        XCTAssertEqual(item.state, .completed, item.failureReason?.label ?? "")
        XCTAssertEqual(server.requests.filter { $0.hasPrefix("GET /busy.mp4") }.count, 2, "503 is retried exactly once")
        XCTAssertEqual(server.requests.filter { $0.hasPrefix("GET /ok.mp4") }.count, 1)
        XCTAssertGreaterThanOrEqual(resolveCount, 2, "links are re-resolved before the retry and the failover")
    }

    func testWatchdogStopsAStalledTransferAndRetries() async throws {
        let service = DownloadService.shared
        let savedTimeout = service.stallTimeout, savedInterval = service.watchdogInterval
        service.stallTimeout = 1.5
        service.watchdogInterval = 0.5
        defer { service.stallTimeout = savedTimeout; service.watchdogInterval = savedInterval }

        let body = randomVideoBytes(2 * 1_048_576)
        var stalling = RangeHTTPServer.Route(body: body)
        stalling.chunkDelay = 30 // one chunk, then silence
        server.set("/stall.mp4", stalling)
        resolve(to: [StreamLinkDto(url: server.url("/stall.mp4"), name: "a", source: "s1", quality: 1080, type: "VIDEO")])
        let req = request("Stall Movie")
        service.enqueue(req)
        let item = try XCTUnwrap(item(for: req))

        await waitFor(item) { $0.state == .downloading && $0.bytesWritten > 0 }
        server.set("/stall.mp4", .init(body: body)) // healthy on retry
        await waitFor(item, timeout: 30) { $0.state.isFinished }

        XCTAssertEqual(item.state, .completed, item.failureReason?.label ?? "")
        XCTAssertTrue(item.retriedCurrentMirror, "a stall is retried on the same mirror")
        XCTAssertEqual(try Data(contentsOf: item.destinationURL), body)
    }

    func testTerminalEngineFailureEndsProviderWaitWithoutResolving() async throws {
        let service = DownloadService.shared
        service.isEngineReady = { false }
        service.engineFailure = { "Fixture engine recovery exhausted" }
        resolve(to: [.init(url: server.url("/unused.mp4"), name: "Fixture", source: "fixture", quality: 720, type: "VIDEO")])
        let req = request("EngineFailure", provider: "E2E-engine-failure")
        service.enqueue(req)
        let item = try XCTUnwrap(item(for: req))
        await waitFor(item) { $0.state.isFinished }
        XCTAssertEqual(item.state, .failed)
        XCTAssertEqual(resolveCount, 0)
        XCTAssertTrue(item.failureReason?.label.contains("Fixture engine recovery exhausted") == true)
    }

    func testDownloadNextReordersWaitingItems() async throws {
        DownloadService.shared.isEngineReady = { false }
        let savedPerProvider = UserPreferences.shared.maxDownloadsPerProvider
        UserPreferences.shared.maxDownloadsPerProvider = 1
        defer { UserPreferences.shared.maxDownloadsPerProvider = savedPerProvider }

        let requests = (0..<3).map { request("Order \($0)", provider: "E2E-order") }
        for req in requests { DownloadService.shared.enqueue(req) }
        let last = try XCTUnwrap(item(for: requests[2]))
        XCTAssertEqual(last.state, .queued)

        DownloadService.shared.moveToFront(last)

        let waiting = DownloadService.shared.queue.filter { $0.provider == "E2E-order" && $0.state == .queued }
        XCTAssertEqual(waiting.first?.id, last.id)
    }

    func testHLSDownloadRemuxesToMP4() async throws {
        guard let path = DownloadService.ffmpegBinaryPath() else { throw XCTSkip("ffmpeg not bundled") }
        try serveGeneratedHLS(ffmpeg: URL(fileURLWithPath: path), in: directory, server: server, seconds: 12)
        resolve(to: [StreamLinkDto(url: server.url("/hls/index.m3u8"), name: "a", source: "s1", quality: 720, type: "M3U8")])
        let req = request("HLS Episode")
        DownloadService.shared.enqueue(req)
        let item = try XCTUnwrap(item(for: req))
        await waitFor(item, timeout: 30) { $0.state.isFinished }

        XCTAssertEqual(item.state, .completed, item.failureReason?.label ?? "")
        XCTAssertEqual(item.destinationURL.pathExtension, "mp4")
        XCTAssertEqual(item.inputDurationSeconds ?? 0, 12, accuracy: 1, "progress uses ffmpeg's real duration")
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.partURL.path))
        let size = (try FileManager.default.attributesOfItem(atPath: item.destinationURL.path)[.size] as? Int64) ?? 0
        XCTAssertGreaterThan(size, 10_000)
    }

    func testTerminalLocalFailureDoesNotBurnMirrors() async throws {
        server.set("/v.mp4", .init(body: randomVideoBytes(1_000_000)))
        resolve(to: [
            StreamLinkDto(url: server.url("/v.mp4"), name: "a", source: "s1", quality: 1080, type: "VIDEO"),
            StreamLinkDto(url: server.url("/v.mp4"), name: "b", source: "s2", quality: 720, type: "VIDEO"),
        ])
        // A folder we can't create.
        var req = request("Unwritable")
        req.directory = URL(fileURLWithPath: "/System/cs-downloads-\(UUID().uuidString)")
        DownloadService.shared.enqueue(req)
        let item = try XCTUnwrap(item(for: req))

        await waitFor(item) { $0.state.isFinished }

        XCTAssertEqual(item.state, .failed)
        XCTAssertEqual(item.failureReason?.disposition, .terminal, "\(String(describing: item.failureReason))")
        XCTAssertEqual(item.activeLinkIndex, 0, "a local failure must not try other mirrors")
    }

    func testRetryResolvesFreshLinks() async throws {
        resolve(to: [StreamLinkDto(url: server.url("/gone.mp4"), name: "a", source: "s1", quality: 1080, type: "VIDEO")])
        let req = request("Retry Movie")
        DownloadService.shared.enqueue(req)
        let item = try XCTUnwrap(item(for: req))
        await waitFor(item) { $0.state.isFinished }
        XCTAssertEqual(item.state, .failed)
        let resolvesBefore = resolveCount

        server.set("/fresh.mp4", .init(body: randomVideoBytes(800_000)))
        resolve(to: [StreamLinkDto(url: server.url("/fresh.mp4"), name: "a", source: "s1", quality: 1080, type: "VIDEO")])
        DownloadService.shared.retry(item)
        XCTAssertTrue(item.orderedLinks.isEmpty, "retry must drop stale links")
        await waitFor(item) { $0.state.isFinished }

        XCTAssertEqual(item.state, .completed, item.failureReason?.label ?? "")
        XCTAssertGreaterThan(resolveCount, resolvesBefore)
    }

    func testPauseAndResumeDirectTransferContinuesWithRange() async throws {
        let body = randomVideoBytes(3 * 1_048_576)
        var route = RangeHTTPServer.Route(body: body, contentType: "video/mp4")
        route.chunkDelay = 0.03
        server.set("/slow.mp4", route)
        resolve(to: [StreamLinkDto(url: server.url("/slow.mp4"), name: "a", source: "s1", quality: 1080, type: "VIDEO")])
        let req = request("Pause Movie")
        DownloadService.shared.enqueue(req)
        let item = try XCTUnwrap(item(for: req))

        await waitFor(item) { $0.state == .downloading && $0.bytesWritten > 200_000 }
        DownloadService.shared.pause(item)
        XCTAssertEqual(item.state, .paused)
        try await Task.sleep(for: .milliseconds(300))

        server.set("/slow.mp4", .init(body: body, contentType: "video/mp4"))
        DownloadService.shared.resume(item)
        await waitFor(item) { $0.state.isFinished }

        XCTAssertEqual(item.state, .completed, item.failureReason?.label ?? "")
        XCTAssertEqual(try Data(contentsOf: item.destinationURL), body)
        XCTAssertTrue(server.requests.contains { $0.contains("Range: bytes=") }, "resume must use a byte range")
    }

    func testCancelRemovesPartialAndNeverTheFinishedFile() async throws {
        var route = RangeHTTPServer.Route(body: randomVideoBytes(4 * 1_048_576))
        route.chunkDelay = 0.05
        server.set("/slow.mp4", route)
        resolve(to: [StreamLinkDto(url: server.url("/slow.mp4"), name: "a", source: "s1", quality: 1080, type: "VIDEO")])
        let req = request("Cancel Movie")
        DownloadService.shared.enqueue(req)
        let item = try XCTUnwrap(item(for: req))
        await waitFor(item) { $0.state == .downloading && $0.bytesWritten > 100_000 }

        DownloadService.shared.cancel(item)
        XCTAssertEqual(item.state, .cancelled)
        try await Task.sleep(for: .milliseconds(800)) // teardown
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.partURL.path))

        // A completed item is immune to cancel (the old season-cancel bug).
        let finished = DownloadService.QueueItem(
            title: "Done", episodeLabel: "E1", provider: "E2E", episodeData: "done",
            destinationURL: directory.appendingPathComponent("done.mp4"), durationSeconds: nil,
        )
        try Data("video".utf8).write(to: finished.destinationURL)
        finished.state = .completed
        DownloadService.shared.cancel(finished)
        XCTAssertEqual(finished.state, .completed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: finished.destinationURL.path))
    }

    func testWaitsForEngineInsteadOfFailing() async throws {
        DownloadService.shared.isEngineReady = { false }
        resolve(to: [])
        let req = request("Waiting Movie")
        DownloadService.shared.enqueue(req)
        let item = try XCTUnwrap(item(for: req))
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(item.state, .resolving, "must not fail while the engine boots")
        XCTAssertEqual(item.statusDetail, "Waiting for streaming engine…")
        XCTAssertEqual(resolveCount, 0)
        DownloadService.shared.cancel(item)
    }

    func testSameNameRequestsGetDistinctDestinations() async throws {
        DownloadService.shared.isEngineReady = { false } // keep them queued
        let first = request("Same Name")
        var second = request("Same Name")
        second.provider = "E2E-other"
        DownloadService.shared.enqueue(first)
        DownloadService.shared.enqueue(second)
        let a = try XCTUnwrap(item(for: first))
        let b = try XCTUnwrap(item(for: second))
        XCTAssertNotEqual(a.destinationURL, b.destinationURL, "queued items must reserve their paths")
        XCTAssertEqual(b.destinationURL.lastPathComponent, "Same Name (2).mp4")
    }

    func testDedupeIsPerProvider() async throws {
        DownloadService.shared.isEngineReady = { false }
        var a = request("Shared Data")
        a.episodeData = "shared-\(UUID().uuidString)"
        var b = a
        b.provider = "E2E-meta"
        XCTAssertEqual(DownloadService.shared.enqueue(a), .enqueued)
        XCTAssertEqual(DownloadService.shared.enqueue(b), .enqueued, "another provider with the same data is a different download")
        XCTAssertEqual(DownloadService.shared.enqueue(a, reportDuplicates: false), .alreadyQueued)
    }

    func testRemovingCompletedRowKeepsDownloadedTitle() async throws {
        server.set("/v.mp4", .init(body: randomVideoBytes(700_000)))
        resolve(to: [StreamLinkDto(url: server.url("/v.mp4"), name: "a", source: "s1", quality: 1080, type: "VIDEO")])
        let req = request("Keep Me")
        DownloadService.shared.enqueue(req)
        let item = try XCTUnwrap(item(for: req))
        await waitFor(item) { $0.state.isFinished }
        XCTAssertEqual(item.state, .completed)

        DownloadService.shared.removeFromQueue(item)

        XCTAssertFalse(DownloadService.shared.queue.contains { $0.id == item.id })
        XCTAssertNotNil(DownloadService.shared.completedRecord(provider: req.provider, episodeData: req.episodeData))
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.destinationURL.path))
        DownloadService.shared.deleteCompleted(item)
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.destinationURL.path))
    }

    func testSubtitleSidecarsAreSavedAndDiscoverable() async throws {
        server.set("/v.mp4", .init(body: randomVideoBytes(700_000)))
        server.set("/en.vtt", .init(body: Data("WEBVTT\n\n00:00.000 --> 00:01.000\nHi\n".utf8), contentType: "text/vtt"))
        let previousLanguage = UserPreferences.shared.subtitleLanguage
        UserPreferences.shared.subtitleLanguage = "en"
        defer { UserPreferences.shared.subtitleLanguage = previousLanguage }
        resolve(
            to: [StreamLinkDto(url: server.url("/v.mp4"), name: "a", source: "s1", quality: 1080, type: "VIDEO")],
            subtitles: [SubtitleDto(url: server.url("/en.vtt"), language: "en", label: "English", mimeType: "text/vtt")],
        )
        let req = request("Subbed Movie")
        DownloadService.shared.enqueue(req)
        let item = try XCTUnwrap(item(for: req))
        await waitFor(item) { $0.state.isFinished }

        XCTAssertEqual(item.state, .completed)
        let sidecars = DownloadService.sidecarSubtitles(for: item.destinationURL)
        XCTAssertEqual(sidecars.map(\.language), ["en"])
        DownloadService.shared.deleteCompleted(item)
        XCTAssertTrue(DownloadService.sidecarSubtitleFiles(for: item.destinationURL).isEmpty, "delete removes sidecars")
    }
}


/// Holds link resolution until the test opens it.
actor ResolutionGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

/// Names the DirectFileJob helpers under test.
private enum DownloadFileJobRedirect {
    static func follow(_ request: URLRequest, from original: URL) -> URLRequest? { DirectFileJob.redirectedRequest(request, from: original) }
    static func isDASH(_ data: Data) -> Bool { DirectFileJob.looksLikeDASHManifest(data) }
}
