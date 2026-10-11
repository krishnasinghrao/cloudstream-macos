import XCTest
@testable import CloudStream

/// Offline-Features-Plan Phase 3: path debounce and the offline download hold.
@MainActor
final class ConnectivityTests: XCTestCase {
    func testBriefDropIsIgnored() async throws {
        let monitor = ConnectivityMonitor()
        monitor.handle(online: false, expensive: false, constrained: false, debounce: .milliseconds(200))
        monitor.handle(online: true, expensive: false, constrained: false)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(monitor.isOnline, "a flap shorter than the debounce must not go offline")
    }

    func testSustainedDropGoesOfflineAndRecoversImmediately() async throws {
        let monitor = ConnectivityMonitor()
        monitor.handle(online: false, expensive: false, constrained: false, debounce: .milliseconds(20))
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertFalse(monitor.isOnline)
        XCTAssertTrue(DownloadService.shared.isNetworkSuspended)

        monitor.handle(online: true, expensive: true, constrained: false)
        XCTAssertTrue(monitor.isOnline)
        XCTAssertTrue(monitor.isExpensive)
        XCTAssertFalse(DownloadService.shared.isNetworkSuspended)
    }

    func testDoHURLValidation() {
        XCTAssertTrue(NetworkSettingsView.isValidDoHURL("https://dns.example/dns-query"))
        XCTAssertFalse(NetworkSettingsView.isValidDoHURL("http://dns.example/dns-query"))
        XCTAssertFalse(NetworkSettingsView.isValidDoHURL("dns.example"))
    }

    func testNetworkSettingsDecodes() throws {
        let json = #"{"dns":"quad9","customDohUrl":null,"httpCacheMb":50,"retryOnNetworkError":true,"resolvers":[{"id":"system","label":"System"}],"cacheSizeBytes":1024}"#
        let settings = try JSONDecoder().decode(NetworkSettingsDto.self, from: Data(json.utf8))
        XCTAssertEqual(settings.dns, "quad9")
        XCTAssertEqual(settings.resolvers.first?.id, "system")
        XCTAssertEqual(settings.cacheSizeBytes, 1024)
    }
}
