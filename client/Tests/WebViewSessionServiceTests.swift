import XCTest
@testable import CloudStream

/// Plan RT-14: extension-created WebViews run in real WebKit. The engine side
/// is a fake that records what the app reports.
@MainActor
final class WebViewSessionServiceTests: XCTestCase {
    private actor FakeEngine: WebViewSessionClient {
        private(set) var results: [String: WebViewResultDto] = [:]
        private(set) var events: [WebViewEventPayload] = []
        func completeWebView(_ result: WebViewResultDto) async throws { results[result.commandId] = result }
        func reportWebView(_ event: WebViewEventDto) async throws { events.append(event.event) }
    }

    private func waitUntil(_ timeout: TimeInterval = 10, _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("timed out")
    }

    private func eval(_ service: WebViewSessionService, _ engine: FakeEngine, session: String, _ script: String) async throws -> String? {
        let id = UUID().uuidString
        service.handle(WebViewCommandDto(commandId: id, session: session, op: "eval", script: script), client: engine)
        try await waitUntil { await engine.results[id] != nil }
        return await engine.results[id]?.result
    }

    func testPagesCallRegisteredInterfacesAndScriptsReturnAndroidStyleJSON() async throws {
        let service = WebViewSessionService.shared
        let engine = FakeEngine()
        let session = UUID().uuidString
        defer { service.handle(WebViewCommandDto(commandId: UUID().uuidString, session: session, op: "destroy"), client: engine) }
        let load = UUID().uuidString
        service.handle(WebViewCommandDto(commandId: load, session: session, op: "load",
            html: "<html><body><script>Bridge.deliver('hello', 42); window.secret = 'k' + 'ey';</script></body></html>",
            baseUrl: "https://example.test/", interfaces: ["Bridge"]), client: engine)
        try await waitUntil { await engine.events.contains { $0.kind == "finished" } }
        let load_ = await engine.results[load]
        XCTAssertNil(load_?.error)
        let call = await engine.events.first { $0.kind == "call" }
        XCTAssertEqual(call?.name, "Bridge")
        XCTAssertEqual(call?.method, "deliver")
        XCTAssertEqual(call?.args, ["hello", "42"])

        let sum = try await eval(service, engine, session: session, "1 + 1")
        XCTAssertEqual(sum, "2")
        let text = try await eval(service, engine, session: session, "window.secret")
        XCTAssertEqual(text, "\"key\"", "strings are JSON-encoded, as on Android")
        let object = try await eval(service, engine, session: session, "({a: 1})")
        XCTAssertEqual(object, "{\"a\":1}")
        let missing = try await eval(service, engine, session: session, "notDefinedAnywhere")
        XCTAssertEqual(missing, "null", "a throwing script reports null")
    }

    func testOnlyWebURLsLoadAndDestroyDropsTheView() async throws {
        let service = WebViewSessionService.shared
        let engine = FakeEngine()
        let session = UUID().uuidString
        let before = service.sessionCount
        let refused = UUID().uuidString
        service.handle(WebViewCommandDto(commandId: refused, session: session, op: "load", url: "file:///etc/hosts"), client: engine)
        try await waitUntil { await engine.results[refused] != nil }
        let result = await engine.results[refused]
        XCTAssertNotNil(result?.error)
        service.handle(WebViewCommandDto(commandId: UUID().uuidString, session: session, op: "destroy"), client: engine)
        XCTAssertEqual(service.sessionCount, before)
    }
}
