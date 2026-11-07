import WebKit
import XCTest
@testable import CloudStream

/// Security audit 2026-11 (H1, L2): WebKit content an extension asks for, and
/// artwork it names, never reaches this Mac or the local network.
@MainActor
final class WebContentNetworkPolicyTests: XCTestCase {
    private var previousLoopback = false

    override func setUp() async throws {
        previousLoopback = LocalDestination.testingAllowsLoopback.load(ordering: .relaxed)
        LocalDestination.testingAllowsLoopback.store(false, ordering: .relaxed)
        // No engine in unit tests: a proxy that refuses every connection.
        WebContentNetworkPolicy.shared.egressSource = { WebContentEgressDto(host: "127.0.0.1", port: 1, username: "t", password: "t") }
        WebContentNetworkPolicy.shared.reset()
    }

    override func tearDown() async throws {
        LocalDestination.testingAllowsLoopback.store(previousLoopback, ordering: .relaxed)
    }

    func testLocalHostsAreRecognisedInEveryBrowserSpelling() {
        let local = [
            "localhost", "LOCALHOST.", "api.localhost", "127.0.0.1", "2130706433", "0x7f.1", "0177.0.0.1", "127.1", "0.0.0.0",
            "::1", "[::1]", "::ffff:127.0.0.1", "0:0:0:0:0:0:0:1", "10.1.2.3", "192.168.1.1", "172.16.0.1", "172.31.255.255",
            "100.64.0.1", "169.254.169.254", "fe80::1", "fd00::1", "printer.local", "nas.lan", "db.internal",
            "router.home.arpa", "router", "1.2.3.256",
        ]
        for host in local { XCTAssertTrue(LocalDestination.isLocalHost(host), host) }
        let remote = ["example.com", "93.184.216.34", "8.8.8.8", "2606:4700:4700::1111", "10.example.com", "127.0.0.1.nip.io"]
        for host in remote { XCTAssertFalse(LocalDestination.isLocalHost(host), host) }
        XCTAssertEqual(LocalDestination.ipv4("2130706433"), [127, 0, 0, 1])
        XCTAssertEqual(LocalDestination.ipv4("10.258"), [10, 0, 1, 2])
        XCTAssertNil(LocalDestination.ipv4("4294967296"))
    }

    func testLoopbackFixturesAreAllowedOnlyWhenTestsAskForIt() {
        LocalDestination.testingAllowsLoopback.store(true, ordering: .relaxed)
        XCTAssertFalse(LocalDestination.isLocalHost("127.0.0.1"))
        XCTAssertFalse(LocalDestination.isLocalHost("localhost"))
        XCTAssertTrue(LocalDestination.isLocalHost("192.168.1.1"), "only loopback is relaxed")
        XCTAssertTrue(LocalDestination.isLocalHost("169.254.169.254"))
    }

    func testArtworkAndSubtitleLoadsRefuseLocalAddresses() throws {
        XCTAssertFalse(BoundedHTTPResource.isAllowed(try XCTUnwrap(URL(string: "http://127.0.0.1:11434/api/tags"))))
        XCTAssertFalse(BoundedHTTPResource.isAllowed(try XCTUnwrap(URL(string: "http://192.168.1.1/poster.jpg"))))
        XCTAssertFalse(BoundedHTTPResource.isAllowed(try XCTUnwrap(URL(string: "http://169.254.169.254/latest/meta-data/"))))
        XCTAssertTrue(BoundedHTTPResource.isAllowed(try XCTUnwrap(URL(string: "https://image.example.com/p.jpg"))))
    }

    func testRuleListsCompileInWebKit() async throws {
        for blockLoopback in [true, false] {
            let list = try await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "cloudstream.web-content.test-\(blockLoopback)",
                encodedContentRuleList: WebContentNetworkPolicy.rulesJSON(blockLoopback: blockLoopback))
            XCTAssertNotNil(list)
        }
        let patterns = WebContentNetworkPolicy.blockedHostPatterns(blockLoopback: true)
        func blocked(_ url: String) -> Bool {
            patterns.contains { url.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
        }
        for url in ["http://127.0.0.1:8080/x", "http://localhost/", "http://a.localhost/", "http://[::1]:80/", "http://[::ffff:7f00:1]/",
                    "http://169.254.169.254/", "http://[fe80::1]/", "http://192.168.0.1/", "http://user:pw@127.0.0.1/",
                    "http://printer.local/", "http://router/", "ws://127.0.0.1:9/"] {
            XCTAssertTrue(blocked(url), url)
        }
        for url in ["https://example.com/", "https://10.example.com/", "https://cdn.example.org:8443/a?b", "about:blank",
                    "blob:https://example.com/uuid", "data:text/html,x"] {
            XCTAssertFalse(blocked(url), url)
        }
    }

    func testNothingLoadsWithoutTheEngineProxy() async {
        WebContentNetworkPolicy.shared.egressSource = { throw URLError(.cannotConnectToHost) }
        WebContentNetworkPolicy.shared.reset()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let prepared = await WebContentNetworkPolicy.shared.prepare(configuration)
        XCTAssertFalse(prepared)
    }

    func testConfinedViewsUseTheProxyWithoutFailover() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let prepared = await WebContentNetworkPolicy.shared.prepare(configuration)
        XCTAssertTrue(prepared)
        let proxies = configuration.websiteDataStore.proxyConfigurations
        XCTAssertEqual(proxies.count, 1)
        XCTAssertEqual(proxies.first?.allowFailover, false)
    }

    func testExtensionWebViewsRefuseLocalPagesAndOrigins() async throws {
        let service = WebViewSessionService.shared
        let engine = RecordingWebViewEngine()
        let session = UUID().uuidString
        defer { service.handle(WebViewCommandDto(commandId: UUID().uuidString, session: session, op: "destroy"), client: engine) }
        for (url, base) in [("http://127.0.0.1:11434/api/tags", nil), ("http://2130706433/", nil), (nil, "http://169.254.169.254/"),
                            (nil, "http://localhost:8080/")] as [(String?, String?)] {
            let id = UUID().uuidString
            service.handle(WebViewCommandDto(commandId: id, session: session, op: "load", url: url,
                html: url == nil ? "<p>x</p>" : nil, baseUrl: base), client: engine)
            try await waitUntil { await engine.results[id] != nil }
            let result = await engine.results[id]
            XCTAssertNotNil(result?.error, "\(url ?? base ?? "") must be refused")
        }
    }

    /// The decisive check: a page may not read a loopback service with a
    /// subresource request either (fetch/XHR never reach a navigation delegate).
    /// The control run proves the page would otherwise reach it.
    func testPagesCannotFetchLoopbackServices() async throws {
        let server = try RangeHTTPServer()
        server.set("/secret", .init(body: Data("secret".utf8), contentType: "text/plain"))

        LocalDestination.testingAllowsLoopback.store(true, ordering: .relaxed)
        let control = try await fetchOutcome(server.url("/secret"))
        XCTAssertEqual(control, "\"reached\"", "control: without the loopback rules the page reaches the service")
        let reached = server.requests.filter { $0.contains("/secret") }.count
        XCTAssertGreaterThan(reached, 0)

        LocalDestination.testingAllowsLoopback.store(false, ordering: .relaxed)
        let outcome = try await fetchOutcome(server.url("/secret"))
        XCTAssertEqual(outcome, "\"blocked\"")
        XCTAssertEqual(server.requests.filter { $0.contains("/secret") }.count, reached, "the loopback service never saw the request")
    }

    private func fetchOutcome(_ target: String) async throws -> String? {
        let service = WebViewSessionService.shared
        let engine = RecordingWebViewEngine()
        let session = UUID().uuidString
        defer { service.handle(WebViewCommandDto(commandId: UUID().uuidString, session: session, op: "destroy"), client: engine) }
        let html = """
        <script>
        fetch('\(target)', { mode: 'no-cors' }).then(() => { document.title = 'reached' }, () => { document.title = 'blocked' });
        </script>
        """
        let load = UUID().uuidString
        service.handle(WebViewCommandDto(commandId: load, session: session, op: "load", html: html, baseUrl: "http://example.test/"), client: engine)
        try await waitUntil { await engine.results[load] != nil }
        let loadResult = await engine.results[load]
        XCTAssertNil(loadResult?.error)
        var title: String?
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            let id = UUID().uuidString
            service.handle(WebViewCommandDto(commandId: id, session: session, op: "eval", script: "document.title"), client: engine)
            try await waitUntil { await engine.results[id] != nil }
            title = await engine.results[id]?.result
            if title == "\"blocked\"" || title == "\"reached\"" { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        return title
    }

    func testResolverAndSolverRefuseLocalTargets() {
        MediaResolverService.shared.start(MediaPendingDto(taskId: UUID().uuidString, url: "http://127.0.0.1:8080/embed", method: "GET",
            headers: [:], userAgent: nil, script: nil, timeoutMs: 10_000, ageMs: 0))
        XCTAssertTrue(MediaResolverService.shared.activeTaskIds.isEmpty)
        XCTAssertFalse(WebViewSolverService.shared.canSolve(targetUrl: "https://localhost/"))
        XCTAssertFalse(WebViewSolverService.shared.canSolve(targetUrl: "https://192.168.1.1/"))
        XCTAssertTrue(WebViewSolverService.shared.canSolve(targetUrl: "https://example.com/"))
    }

    private func waitUntil(_ timeout: TimeInterval = 10, _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("timed out")
    }
}

private actor RecordingWebViewEngine: WebViewSessionClient {
    private(set) var results: [String: WebViewResultDto] = [:]
    func completeWebView(_ result: WebViewResultDto) async throws { results[result.commandId] = result }
    func reportWebView(_ event: WebViewEventDto) async throws {}
}
