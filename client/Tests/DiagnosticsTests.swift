import XCTest
@testable import CloudStream

/// Offline-Features-Plan Phase 8: log handling and test reports.
final class DiagnosticsTests: XCTestCase {
    @MainActor
    func testSupportBundleSerializesMissingEngineValuesAsNull() async throws {
        await DaemonClient.shared.clearEndpoint()
        let state = AppState.shared
        let data = await DiagnosticsExporter.bundle(appState: state)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let application = try XCTUnwrap(root["app"] as? [String: Any])
        XCTAssertEqual(root["format"] as? String, "cloudstream-support-bundle-v1")
        XCTAssertTrue(application["isolationMode"] is NSNull)
        XCTAssertTrue(application["extensionsSandboxed"] is NSNull)
        XCTAssertNotNil(root["engine"], "an unavailable engine must still produce an inspectable support bundle")
    }

    func testRedactorRemovesSecrets() {
        let raw = #"{"event":"x","Authorization":"Bearer abc.def","cookie":"cf_clearance=123; a=b","url":"https://h/p?token=SECRET&x=1"} password=hunter2 Bearer xyz"#
        let clean = LogRedactor.redact(raw)
        for secret in ["abc.def", "cf_clearance=123", "SECRET", "hunter2", "xyz"] {
            XCTAssertFalse(clean.contains(secret), "leaked \(secret) in \(clean)")
        }
        XCTAssertTrue(clean.contains("x=1"), "harmless query parameters survive")
        XCTAssertTrue(clean.contains("\"event\":\"x\""))
    }

    func testLogTailReadsOnlyTheEnd() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tail-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }
        let text = (1...5000).map { "line \($0)" }.joined(separator: "\n")
        try text.write(to: url, atomically: true, encoding: .utf8)
        let lines = LogTail.lines(of: url, maxBytes: 200, maxLines: 10)
        XCTAssertEqual(lines.last, "line 5000")
        XCTAssertLessThanOrEqual(lines.count, 10)
        XCTAssertTrue(lines.allSatisfy { $0.hasPrefix("line ") }, "partial first line is dropped")
        XCTAssertEqual(LogTail.lines(of: url.appendingPathExtension("missing")), [])
    }

    @MainActor
    func testLogFilter() {
        let lines = ["{\"level\":\"INFO\",\"event\":\"a\"}", "{\"level\":\"ERROR\",\"event\":\"b\"}", "{\"level\":\"WARN\",\"event\":\"provider.x\"}"]
        XCTAssertEqual(DiagnosticsView.filter(lines, text: "", problemsOnly: true).count, 2)
        XCTAssertEqual(DiagnosticsView.filter(lines, text: "provider", problemsOnly: false).count, 1)
    }

    @MainActor
    func testReportFormatting() {
        let result = ProviderTestResultDto(provider: "P", status: "partial", steps: [
            ProviderTestStepDto(name: "search", ok: true, latencyMs: 120, detail: "3 results"),
            ProviderTestStepDto(name: "links", ok: false, latencyMs: nil, detail: "0 streams"),
        ])
        let report = DiagnosticsView.report([result])
        XCTAssertTrue(report.contains("P: PARTIAL"))
        XCTAssertTrue(report.contains("✓ search (120 ms): 3 results"))
        XCTAssertTrue(report.contains("✗ links: 0 streams"))
        XCTAssertNil(ProviderStatDto(provider: "x", success: 0, failure: 0, lastError: nil, lastLatencyMs: 0).successRate)
    }

    func testClientLogLinesAreValidEscapedJSON() throws {
        let line = ClientLogFile.line(event: "e\"vil", fields: ["msg": "a \"quoted\"\nline"])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String])
        XCTAssertEqual(object["event"], "e\"vil")
        XCTAssertEqual(object["msg"], "a \"quoted\"\nline")
        XCTAssertNotNil(object["ts"])
    }

    func testClientLogRotates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clientlog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = ClientLogFile(directory: directory)
        let big = String(repeating: "x", count: 1024 * 1024)
        for _ in 0..<3 { log.append(big) }
        log.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: log.url.appendingPathExtension("1").path))
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: log.url.path)[.size] as? UInt64)
        XCTAssertLessThan(size, ClientLogFile.maxBytes + 1024 * 1024 + 10)
    }

    func testBackupTimestampsAreStable() throws {
        for offset in stride(from: 0.0, to: 5.0, by: 0.0137) {
            let date = Date(timeIntervalSince1970: 1_790_760_795 + offset)
            let text = try BackupDocument.timestamp(date)
            let decoded = try BackupDocument.decoder.decode(Date.self, from: Data("\"\(text)\"".utf8))
            XCTAssertEqual(try BackupDocument.timestamp(decoded), text)
        }
    }
}

/// Offline-Features-Plan Phase 10: orphaned partial downloads.
final class OrphanedPartialTests: XCTestCase {
    func testOnlyOurUnreferencedPartialsAreOrphans() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("orphans-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sidecar = try JSONEncoder().encode(DirectFileJob.ResumeMetadata(mirrorKey: "m"))

        let orphan = directory.appendingPathComponent("Old.part")
        let live = directory.appendingPathComponent("Live.part")
        let foreign = directory.appendingPathComponent("firefox.part")
        let badSidecar = directory.appendingPathComponent("Bad.part")
        for url in [orphan, live, foreign, badSidecar] { try Data("x".utf8).write(to: url) }
        try sidecar.write(to: DirectFileJob.metadataURL(forPart: orphan))
        try sidecar.write(to: DirectFileJob.metadataURL(forPart: live))
        try Data("not json".utf8).write(to: DirectFileJob.metadataURL(forPart: badSidecar))

        let result = DownloadService.orphanedPartials(in: [directory, directory.appendingPathComponent("missing")],
                                                      live: [live.standardizedFileURL.path])
        XCTAssertEqual(result.map(\.lastPathComponent), ["Old.part"])
    }
}
