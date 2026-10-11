import Darwin
import XCTest
@testable import CloudStream

/// The app trusts only the engine it started (audit M1).
final class EngineHandshakeTests: XCTestCase {
    private let nonce = String(repeating: "ab", count: 32)

    private func health(proof: String?) throws -> Data {
        var object: [String: Any] = ["status": "ok", "version": "1", "ipcVersion": HealthDto.expectedIpcVersion,
                                     "uptimeMs": 1, "providersLoaded": 0]
        if let proof { object["proof"] = proof }
        return try JSONSerialization.data(withJSONObject: object)
    }

    func testProofIsAnHMACOfTheTokenOverTheNonce() {
        // Same construction as the engine's EngineHandshake.proof (cross-checked in EngineHandshakeTest.kt).
        let proof = EngineHealthProbe.proof(token: "token-0123456789", nonce: nonce)
        XCTAssertEqual(proof.count, 64)
        XCTAssertNotEqual(proof, EngineHealthProbe.proof(token: "token-0123456780", nonce: nonce))
        XCTAssertNotEqual(proof, EngineHealthProbe.proof(token: "token-0123456789", nonce: String(nonce.reversed())))
        XCTAssertTrue(EngineHealthProbe.matches(proof, expected: proof))
        XCTAssertFalse(EngineHealthProbe.matches(nil, expected: proof))
        XCTAssertFalse(EngineHealthProbe.matches(String(proof.dropLast()), expected: proof))
        XCTAssertEqual(EngineHealthProbe.makeNonce().count, 64)
        XCTAssertNotEqual(EngineHealthProbe.makeNonce(), EngineHealthProbe.makeNonce())
    }

    func testOnlyAListenerThatProvesTheTokenIsHealthyAndTheTokenIsNeverSent() async throws {
        let token = "launch-token-0123456789"
        let genuine = try RangeHTTPServer()
        genuine.set("/health", .init(body: try health(proof: EngineHealthProbe.proof(token: token, nonce: nonce)), contentType: "application/json"))
        let outcome = await EngineHealthProbe.probe(port: genuine.port, token: token, nonce: nonce)
        XCTAssertTrue(outcome.isHealthy)
        XCTAssertFalse(genuine.requests.joined().contains(token), "the token never goes to /health")
        XCTAssertFalse(genuine.requests.joined().contains("Authorization"))
        XCTAssertTrue(genuine.requests.joined().contains("X-CloudStream-Nonce: \(nonce)"))

        // A port squatter answering like an engine, without the proof or with a guess.
        for proof in [nil, String(repeating: "0", count: 64), EngineHealthProbe.proof(token: "other-token", nonce: nonce)] {
            let squatter = try RangeHTTPServer()
            squatter.set("/health", .init(body: try health(proof: proof), contentType: "application/json"))
            guard case .impostor = await EngineHealthProbe.probe(port: squatter.port, token: token, nonce: nonce) else {
                return XCTFail("an unproven listener must be refused")
            }
            let accepted = await DaemonSupervisor.isHealthy(.init(port: squatter.port, token: token))
            XCTAssertFalse(accepted)
        }
    }

    func testConnectAndVerifyRefusesAnUnprovenEngine() async throws {
        let squatter = try RangeHTTPServer()
        squatter.set("/health", .init(body: try health(proof: nil), contentType: "application/json"))
        let client = DaemonClient()
        await client.updateEndpoint(.init(port: squatter.port, token: "secret-token-0123456789"))
        do {
            _ = try await client.connectAndVerify()
            XCTFail("expected untrustedEngine")
        } catch {
            guard case DaemonClient.DaemonError.untrustedEngine = error else { return XCTFail("unexpected \(error)") }
        }
        XCTAssertFalse(squatter.requests.joined().contains("secret-token-0123456789"))
    }

    func testPortAnnouncementReadsTheFirstAnnouncedPortAndTeesOutput() async throws {
        let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("announce-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? FileManager.default.removeItem(at: logURL) }
        let announcement = EnginePortAnnouncement(log: log)
        let writer = announcement.pipe.fileHandleForWriting
        try writer.write(contentsOf: Data(#"{"event":"daemon.starting"}"#.utf8 + [0x0A]))
        try writer.write(contentsOf: Data("CLOUDSTREAM-ENGINE-LIST".utf8))
        try writer.write(contentsOf: Data(#"ENING {"port":51515,"pid":1}"#.utf8 + [0x0A]))
        try writer.write(contentsOf: Data(#"CLOUDSTREAM-ENGINE-LISTENING {"port":60000}"#.utf8 + [0x0A]))
        let port = await announcement.port(timeout: 5)
        XCTAssertEqual(port, 51515, "split lines are reassembled and the first announcement wins")
        let again = await announcement.port(timeout: 1)
        XCTAssertEqual(again, 51515)
        try writer.close()
        announcement.close()
        try log.close()
        let text = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(text.contains("daemon.starting") && text.contains("51515"), "stdout is still logged")
    }

    func testPortAnnouncementGivesUpOnTimeoutEndOfOutputOrCancellation() async throws {
        let silent = EnginePortAnnouncement(log: nil)
        let timedOut = await silent.port(timeout: 0.2)
        XCTAssertNil(timedOut)
        let ended = EnginePortAnnouncement(log: nil)
        try ended.pipe.fileHandleForWriting.write(contentsOf: Data("no announcement\n".utf8))
        try ended.pipe.fileHandleForWriting.close()
        let none = await ended.port(timeout: 10)
        XCTAssertNil(none, "an engine that exits without announcing is not waited on")
        let cancelled = EnginePortAnnouncement(log: nil)
        let task = Task { await cancelled.port(timeout: 30) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let value = await task.value
        XCTAssertNil(value)
        XCTAssertNil(EnginePortAnnouncement.announcedPort(in: #"CLOUDSTREAM-ENGINE-LISTENING {"port":70000}"#))
        XCTAssertNil(EnginePortAnnouncement.announcedPort(in: #"{"port":5000}"#))
        silent.close(); ended.close(); cancelled.close()
    }

    func testSocketOwnershipFindsOnlyTheProcessesOwnListener() throws {
        let server = try RangeHTTPServer()
        XCTAssertTrue(EngineSocketOwnership.process(getpid(), listensOn: server.port))
        XCTAssertFalse(EngineSocketOwnership.process(getpid(), listensOn: server.port == 65_535 ? 65_534 : server.port + 1))
        XCTAssertFalse(EngineSocketOwnership.process(1, listensOn: server.port), "another process does not own it")
        XCTAssertFalse(EngineSocketOwnership.process(-1, listensOn: server.port))
    }
}
