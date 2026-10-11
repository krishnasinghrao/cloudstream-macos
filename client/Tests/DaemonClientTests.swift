import Network
import Synchronization
import XCTest
@testable import CloudStream

/// Real loopback transport tests, including UTF-8 splits and batch fallback.
@MainActor
final class DaemonClientTests: XCTestCase {
    func testDaemonClientValidateExtractsErrorWhenDetailIsNil() {
        let json = "{\"error\":\"Plugin installation failed\"}".data(using: .utf8)!
        let response = HTTPURLResponse(url: URL(string: "http://127.0.0.1/test")!, statusCode: 500, httpVersion: nil, headerFields: nil)!

        XCTAssertThrowsError(try DaemonClient.validate(response, data: json)) { error in
            guard case let DaemonClient.DaemonError.http(statusCode, detail) = error else {
                XCTFail("Expected DaemonClient.DaemonError.http, got \(error)")
                return
            }
            XCTAssertEqual(statusCode, 500)
            XCTAssertEqual(detail, "Plugin installation failed")
        }
    }

    // MARK: - NDJSON decoding

    /// Splits a payload at byte offsets that deliberately cut multi-byte
    /// sequences in half — exactly what a TCP segment boundary can do and
    /// what the old byte-wise decoder corrupted into U+FFFD.
    private func chunkedPayload() -> [Data] {
        let line1 = "{\"type\":\"provider_result\",\"provider\":\"AnimeProvider\",\"results\":[{\"name\":\"東京リベンジャーズ\",\"url\":\"https://e.example/tokyo\",\"provider\":\"AnimeProvider\",\"type\":\"anime\",\"isMovie\":false}]}\n"
        let line2 = "{\"type\":\"provider_result\",\"provider\":\"EuroProvider\",\"results\":[{\"name\":\"Café Déjà Vu 🎬\",\"url\":\"https://e.example/cafe\",\"provider\":\"EuroProvider\",\"type\":\"movie\",\"isMovie\":true}]}\n"
        let line3 = "\nnot-json\n{\"type\":\"done\",\"results\":[]}\n"
        let all = Data(line1.utf8) + Data(line2.utf8) + Data(line3.utf8)

        // Chunk on every other byte: guarantees é / 東 / 🎬 sequences are cut mid-codepoint.
        return stride(from: 0, to: all.count, by: 2).map { all.subdata(in: $0..<min($0 + 2, all.count)) }
    }

    func testSearchStreamDecodesMultiByteUTF8AcrossChunkBoundaries() async throws {
        // Local stub server feeding the real bytes (with a bearer token so
        // the stream path is hit, mirroring production auth).
        let payloadChunks = chunkedPayload()
        let listener = try NWListenerMock(body: payloadChunks)
        let port = listener.port

        let client = DaemonClient()
        await client.updateEndpoint(.init(port: port, token: "test-token"))
        defer { listener.stop() }

        var names: [String] = []
        var sawDone = false
        var sawProviderError: String?
        for try await event in client.searchStream("query") {
            switch event.type {
            case "provider_result":
                names.append(contentsOf: event.results.map(\.name))
            case "provider_error":
                sawProviderError = event.error
            case "done":
                sawDone = true
            default:
                break
            }
        }
        XCTAssertTrue(sawDone, "the stream must decode its valid done event")
        if sawProviderError != nil { XCTFail("provider_error must not fire for a well-formed stream") }
        XCTAssertEqual(names.count, 2, "both provider results must decode")
        XCTAssertEqual(names.first, "東京リベンジャーズ", "CJK title must survive chunked decoding without U+FFFD")
        XCTAssertEqual(names.last, "Café Déjà Vu 🎬", "accented Latin + emoji must survive chunked decoding without U+FFFD")
        for name in names {
            XCTAssertFalse(name.contains("\u{FFFD}"), "replacement character found — multi-byte sequence was split")
        }
    }

    func testPostStreamsDecodeEventsAndStopAtDone() async throws {
        let linksBody = """
        {"type":"link","link":{"url":"https://example.com/video","name":"東京 🎬","source":"test","quality":720,"type":"video"}}
        invalid-json
        {"type":"done"}
        {"type":"error","error":"must not be yielded after done"}

        """
        let linksServer = try NWListenerMock(body: [Data(linksBody.utf8)])
        defer { linksServer.stop() }
        let client = DaemonClient()
        await client.updateEndpoint(.init(port: linksServer.port, token: "links-token"))
        var links: [LinksStreamEventDto] = []
        for try await event in client.linksStream(provider: "inst:Provider", data: "episode") { links.append(event) }
        XCTAssertEqual(links.map(\.type), ["link", "done"])
        XCTAssertEqual(links.first?.link?.name, "東京 🎬")

        let testsBody = """
        {"type":"result","result":{"provider":"Café","status":"ok","steps":[]}}
        {"type":"done","total":1}
        {"type":"result","result":{"provider":"late","status":"ok","steps":[]}}

        """
        let testsServer = try NWListenerMock(body: [Data(testsBody.utf8)])
        defer { testsServer.stop() }
        await client.updateEndpoint(.init(port: testsServer.port, token: "tests-token"))
        var events: [ProviderTestEventDto] = []
        for try await event in client.providerTestStream(providers: ["inst:Provider"], query: "Café") { events.append(event) }
        XCTAssertEqual(events.map(\.type), ["result", "done"])
        XCTAssertEqual(events.first?.result?.provider, "Café")
    }

    func testLinksStreamFallsBackOnlyForUnsupportedEndpoints() async throws {
        for status in [404, 405, 403] {
            let server = try RangeHTTPServer()
            server.set("/links/stream", .init(body: Data(), status: status))
            let batch = LinksResponseDto(provider: "inst:Provider", links: [
                StreamLinkDto(url: "https://example.com/video", name: "mirror", source: "test", quality: 720, type: "video")
            ], subtitles: [SubtitleDto(url: "https://example.com/subtitle", language: "English", label: nil, mimeType: nil)])
            server.set("/links", .init(body: try JSONEncoder().encode(batch), contentType: "application/json", requiredHeader: "Authorization: Bearer fallback-token"))
            let client = DaemonClient()
            await client.updateEndpoint(.init(port: server.port, token: "fallback-token"))
            var events: [LinksStreamEventDto] = []
            do {
                for try await event in client.linksStream(provider: "inst:Provider", data: "episode") { events.append(event) }
                XCTAssertNotEqual(status, 403)
                XCTAssertEqual(events.map(\.type), ["link", "subtitle", "done"])
                XCTAssertEqual(events.first?.link?.name, "mirror")
                XCTAssertEqual(server.requests.count, 2)
                XCTAssertTrue(server.requests.allSatisfy { $0.hasPrefix("POST ") && $0.contains("Authorization: Bearer fallback-token") && $0.contains("Content-Type: application/json") })
                for body in server.requestBodies {
                    let request = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
                    XCTAssertEqual(request["plugin"], "inst:Provider")
                    XCTAssertEqual(request["data"], "episode")
                }
            } catch {
                guard case DaemonClient.DaemonError.http(let code, _) = error else { throw error }
                XCTAssertEqual(status, 403)
                XCTAssertEqual(code, 403)
                XCTAssertEqual(server.requests.count, 1, "authorization failures must not call the batch endpoint")
            }
        }
    }

    // MARK: - Stream completion (audit M1)

    private struct Lines: AsyncSequence, Sendable {
        typealias Element = String
        let values: [String]
        struct AsyncIterator: AsyncIteratorProtocol {
            var values: [String]
            mutating func next() async -> String? { values.isEmpty ? nil : values.removeFirst() }
        }
        func makeAsyncIterator() -> AsyncIterator { AsyncIterator(values: values) }
    }

    func testConsumeEventsReportsWhetherDoneArrived() async throws {
        let (stream, continuation) = AsyncThrowingStream<SearchStreamEventDto, Error>.makeStream()
        let complete = try await DaemonClient.consumeEvents(Lines(values: [
            #"{"type":"provider_result","provider":"P","results":[]}"#, "garbage", #"{"type":"done","results":[]}"#,
        ]), into: continuation) { $0.type == "done" }
        XCTAssertTrue(complete)
        let truncated = try await DaemonClient.consumeEvents(Lines(values: [
            #"{"type":"provider_result","provider":"P","results":[]}"#,
        ]), into: continuation) { $0.type == "done" }
        XCTAssertFalse(truncated, "a stream that closes without done is incomplete")
        continuation.finish()
        var types: [String] = []
        for try await event in stream { types.append(event.type) }
        XCTAssertEqual(types, ["provider_result", "done", "provider_result"])
        XCTAssertNoThrow(try DaemonClient.requireDone(true))
        XCTAssertThrowsError(try DaemonClient.requireDone(false)) { error in
            guard case DaemonClient.DaemonError.streamEnded = error else { return XCTFail("unexpected \(error)") }
        }
    }

    func testCancelledStreamThatEndsEarlyIsNotAnError() async {
        let task = Task<Bool, Never> {
            withUnsafeCurrentTask { $0?.cancel() }
            return (try? DaemonClient.requireDone(false)) != nil
        }
        let passed = await task.value
        XCTAssertTrue(passed, "the consumer's own cancellation is not reported as a failure")
    }

    func testSearchStreamWithoutDoneFailsWithStreamEnded() async throws {
        let body = #"{"type":"provider_result","provider":"P","results":[{"name":"Partial","url":"https://e.example/p","provider":"P","type":"movie","isMovie":true}]}"# + "\n"
        let server = try NWListenerMock(body: [Data(body.utf8)])
        defer { server.stop() }
        let client = DaemonClient()
        await client.updateEndpoint(.init(port: server.port, token: "t"))
        var names: [String] = []
        do {
            for try await event in client.searchStream("q") { names.append(contentsOf: event.results.map(\.name)) }
            XCTFail("an engine that stops before done must not look like a finished search")
        } catch {
            guard case DaemonClient.DaemonError.streamEnded = error else { return XCTFail("unexpected \(error)") }
        }
        XCTAssertEqual(names, ["Partial"], "partial results are still delivered before the failure")
    }

    func testEngineSessionsAreEphemeralCachelessAndProxyFree() {
        for session in [EngineTransport.ipcSession, EngineTransport.healthSession] {
            let configuration = session.configuration
            XCTAssertNil(configuration.urlCache, "engine responses are never written to an HTTP cache (M3)")
            XCTAssertNil(configuration.httpCookieStorage)
            XCTAssertFalse(configuration.httpShouldSetCookies)
            XCTAssertEqual(configuration.connectionProxyDictionary?[kCFNetworkProxiesHTTPEnable as String] as? Bool, false)
            XCTAssertEqual(configuration.connectionProxyDictionary?[kCFNetworkProxiesProxyAutoConfigEnable as String] as? Bool, false)
            XCTAssertFalse(configuration.waitsForConnectivity)
        }
        XCTAssertEqual(EngineTransport.ipcSession.configuration.httpMaximumConnectionsPerHost, 24)
        XCTAssertEqual(EngineTransport.healthSession.configuration.httpMaximumConnectionsPerHost, 2)
        XCTAssertEqual(EngineTransport.healthSession.configuration.timeoutIntervalForRequest, 5)
        XCTAssertTrue(DaemonClient.session === EngineTransport.ipcSession)
    }

    func testLegacyResponseCacheIsPurgedOnce() throws {
        let suite = "engine-cache-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = URLCache(memoryCapacity: 1_000_000, diskCapacity: 0)
        let request = URLRequest(url: URL(string: "http://127.0.0.1:50000/links")!)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        cache.storeCachedResponse(CachedURLResponse(response: response, data: Data("secret".utf8)), for: request)
        XCTAssertNotNil(cache.cachedResponse(for: request))
        EngineTransport.purgeLegacyResponseCache(defaults: defaults, cache: cache)
        XCTAssertNil(cache.cachedResponse(for: request))
        cache.storeCachedResponse(CachedURLResponse(response: response, data: Data("later".utf8)), for: request)
        EngineTransport.purgeLegacyResponseCache(defaults: defaults, cache: cache)
        XCTAssertNotNil(cache.cachedResponse(for: request), "the migration runs once")
    }

    func testDisconnectedStreamsFinishWithNotReady() async {
        let client = DaemonClient()
        do {
            for try await _ in client.searchStream("query") { XCTFail("a disconnected client cannot yield data") }
            XCTFail("expected notReady")
        } catch {
            guard case DaemonClient.DaemonError.notReady = error else { return XCTFail("unexpected error: \(error)") }
        }
    }
}

/// Minimal local HTTP/1.1 responder that writes the given chunks with small
/// delays (forcing multi-byte splits across `AsyncBytes` reads) and closes.
/// No FoundationNetworking, no daemon jar — pure loopback.
final class NWListenerMock: @unchecked Sendable {
    private let listener: NWListener
    let port: Int

    init(body: [Data]) throws {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        let ready = DispatchSemaphore(value: 0)
        let acceptedPort = Mutex<Int>(0)

        let length = body.reduce(0) { $0 + $1.count }
        listener.newConnectionHandler = { [body] connection in
            connection.start(queue: .global())
            connection.send(content: "HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nContent-Length: \(length)\r\nConnection: close\r\n\r\n".data(using: .utf8), completion: .contentProcessed { _ in
                let sender = ChunkSender(chunks: body, connection: connection)
                sender.sendNext()
            })
        }

        listener.stateUpdateHandler = { state in
            if case .ready = state {
                if let p = listener.port { acceptedPort.withLock { $0 = Int(p.rawValue) } }
                ready.signal()
            }
        }
        listener.start(queue: .global())
        guard ready.wait(timeout: .now() + 5) == .success else {
            listener.cancel()
            throw URLError(.timedOut)
        }
        self.port = acceptedPort.withLock { $0 }
    }

    func stop() {
        listener.cancel()
    }
}

/// Sends the payload chunks sequentially, 10 ms apart, so multi-byte UTF-8
/// sequences are split across `AsyncBytes` reads.
// Only one completion or scheduled send mutates the index at a time.
private final class ChunkSender: @unchecked Sendable {
    private let chunks: [Data]
    private let connection: NWConnection
    private var index = 0

    init(chunks: [Data], connection: NWConnection) {
        self.chunks = chunks
        self.connection = connection
    }

    func sendNext() {
        guard index < chunks.count else {
            connection.cancel()
            return
        }
        let chunk = chunks[index]
        index += 1
        connection.send(content: chunk, completion: .contentProcessed { _ in
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(10)) {
                self.sendNext()
            }
        })
    }
}
