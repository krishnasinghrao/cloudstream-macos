import Network
import XCTest
@testable import CloudStream

/// Plan RT-11: the capture script and navigation delegate report the requests real
/// WebKit pages make, served deterministically from a loopback HTTP server.
@MainActor
final class MediaResolverServiceTests: XCTestCase {
    /// Stands in for the engine: records reports, stops at the intercept, receives completion.
    private actor FakeEngine: MediaResolveClient {
        private(set) var observed: [String] = []
        private(set) var completion: MediaCompleteRequestDto?
        let stopOn: String

        init(stopOn: String) { self.stopOn = stopOn }

        func observeMedia(taskId: String, requests: [MediaObservedRequestDto]) async throws -> MediaObserveResponseDto {
            observed += requests.map(\.url)
            return MediaObserveResponseDto(known: true, stop: observed.contains { $0.contains(stopOn) })
        }

        func completeMedia(_ request: MediaCompleteRequestDto) async throws { completion = request }
    }

    /// Minimal HTTP/1.1 server on 127.0.0.1 serving fixed bodies by path.
    private final class FixtureServer: @unchecked Sendable {
        private let listener: NWListener
        private let pages: [String: (String, String)]
        private let queue = DispatchQueue(label: "fixture-server")
        var port: UInt16 { listener.port?.rawValue ?? 0 }

        init(pages: [String: (String, String)]) throws {
            self.pages = pages
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        }

        func start() async throws {
            let ready = AsyncStream<Void> { continuation in
                listener.stateUpdateHandler = { if case .ready = $0 { continuation.yield(); continuation.finish() } }
            }
            listener.start(queue: queue)
            for await _ in ready { return }
        }

        func stop() { listener.cancel() }

        private func serve(_ connection: NWConnection) {
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [pages] data, _, _, _ in
                let line = data.flatMap { String(data: $0, encoding: .utf8) }?.split(separator: "\r\n").first ?? ""
                let path = line.split(separator: " ").dropFirst().first.map(String.init)?.components(separatedBy: "?").first ?? "/"
                let (type, body) = pages[path] ?? ("text/plain", "")
                let status = pages[path] == nil ? "404 Not Found" : "200 OK"
                let response = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.utf8.count)\r\n" +
                    "Access-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    private func task(_ url: String, script: String? = nil, timeoutMs: Int64 = 15_000) -> MediaPendingDto {
        MediaPendingDto(taskId: UUID().uuidString, url: url, method: "GET", headers: [:], userAgent: nil, script: script,
                        timeoutMs: timeoutMs, ageMs: 0)
    }

    private func waitForCompletion(_ engine: FakeEngine, seconds: Double = 20) async -> MediaCompleteRequestDto? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let done = await engine.completion { return done }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    func testScriptGeneratedAndMediaRequestsAreReportedUntilTheEngineStops() async throws {
        let html = """
        <html><head><title>Fixture Player</title></head><body>
        <video id="v"></video>
        <iframe src="/frame"></iframe>
        <script>
          fetch('/api/source.json').then(r => r.text()).then(() => {
            const x = new XMLHttpRequest(); x.open('GET', '/subs/en.vtt'); x.send();
            document.getElementById('v').src = '/media/fallback.mp4';
          });
        </script></body></html>
        """
        let frame = "<html><body><script>setTimeout(() => fetch('/hls/master.m3u8'), 300)</script></body></html>"
        let server = try FixtureServer(pages: [
            "/embed": ("text/html", html), "/frame": ("text/html", frame),
            "/api/source.json": ("application/json", "{}"), "/subs/en.vtt": ("text/vtt", "WEBVTT"),
            "/media/fallback.mp4": ("video/mp4", ""), "/hls/master.m3u8": ("application/vnd.apple.mpegurl", "#EXTM3U"),
        ])
        try await server.start()
        defer { server.stop() }
        let base = "http://127.0.0.1:\(server.port)"

        let engine = FakeEngine(stopOn: ".m3u8")
        MediaResolverService.shared.start(task("\(base)/embed", script: "document.title"), client: engine)
        let completion = await waitForCompletion(engine)
        XCTAssertNotNil(completion, "the session completes once the engine says stop")
        let observed = await engine.observed
        for path in ["/embed", "/frame", "/api/source.json", "/subs/en.vtt", "/media/fallback.mp4", "/hls/master.m3u8"] {
            XCTAssertTrue(observed.contains("\(base)\(path)"), "\(path) was not reported; got \(observed)")
        }
        XCTAssertTrue(MediaResolverService.shared.activeTaskIds.isEmpty, "the session is torn down")
    }

    func testScriptResultIsJsonEncodedLikeAndroid() {
        typealias S = MediaResolverService.Session
        XCTAssertEqual(S.jsonValue("He said \"hi\""), #""He said \"hi\"""#)
        XCTAssertEqual(S.jsonValue(NSNumber(value: 3)), "3")
        XCTAssertEqual(S.jsonValue(NSNumber(value: true)), "true")
        XCTAssertEqual(S.jsonValue(nil), "null")
        XCTAssertEqual(S.jsonValue(["a": 1]), #"{"a":1}"#)
    }

    func testOnlyWebURLsAreLoadedAndConcurrencyIsBounded() async {
        let engine = FakeEngine(stopOn: "never")
        MediaResolverService.shared.start(task("file:///etc/passwd"), client: engine)
        MediaResolverService.shared.start(task("javascript:alert(1)"), client: engine)
        XCTAssertTrue(MediaResolverService.shared.activeTaskIds.isEmpty)
        for _ in 0..<(MediaResolverService.maxConcurrent + 2) {
            MediaResolverService.shared.start(task("http://127.0.0.1:9/never", timeoutMs: 60_000), client: engine)
        }
        XCTAssertEqual(MediaResolverService.shared.activeTaskIds.count, MediaResolverService.maxConcurrent)
        MediaResolverService.shared.reset()
        XCTAssertTrue(MediaResolverService.shared.activeTaskIds.isEmpty)
    }
}
