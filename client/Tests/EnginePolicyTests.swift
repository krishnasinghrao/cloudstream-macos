import XCTest
@testable import CloudStream

final class EnginePolicyTests: XCTestCase {
    @MainActor
    func testConnectionWaitRequiresCompletedBootstrapAndPropagatesFailure() async throws {
        let (changes, continuation) = AsyncStream<EngineConnection>.makeStream()
        let waiting = Task { try await EngineConnection.awaitUsable(in: changes) }
        var connection = EngineConnection()
        connection.beginVerification(.init(port: 50_001, token: "fixture"))
        let generation = connection.generation
        var health = HealthDto(status: "ok", version: "fixture", ipcVersion: HealthDto.expectedIpcVersion, uptimeMs: 1, providersLoaded: 0)
        health.extensions = .init(phase: "restoring", restored: 0, failed: 0, quarantined: 0)
        connection.acceptHealth(health, generation: generation)
        continuation.yield(connection)
        connection.fail("Fixture restore failed", generation: generation)
        continuation.yield(connection)
        do { try await waiting.value; XCTFail("Restoring was incorrectly treated as usable") }
        catch let error as EngineConnection.Unavailable { XCTAssertEqual(error.message, "Fixture restore failed") }
        continuation.finish()
    }

    func testConnectionWaitAcceptsUsableSafeModeAndCancelsWithoutAnEvent() async throws {
        let (changes, continuation) = AsyncStream<EngineConnection>.makeStream()
        let waiting = Task { try await EngineConnection.awaitUsable(in: changes) }
        waiting.cancel()
        do { try await waiting.value; XCTFail("Cancellation became readiness") }
        catch is CancellationError { }
        continuation.finish()

        var connection = EngineConnection()
        connection.beginVerification(.init(port: 50_001, token: "fixture"))
        var health = HealthDto(status: "ok", version: "fixture", ipcVersion: HealthDto.expectedIpcVersion, uptimeMs: 1, providersLoaded: 0)
        health.extensions = .init(phase: "safe_mode", restored: 0, failed: 0, quarantined: 0)
        connection.acceptHealth(health, generation: connection.generation)
        XCTAssertTrue(connection.markUsable(generation: connection.generation))
        let ready = AsyncStream<EngineConnection> { $0.yield(connection); $0.finish() }
        try await EngineConnection.awaitUsable(in: ready)
    }
    func testRecoveryUsesCappedBackoffFiniteBudgetAndMonotonicCrashWindow() {
        var policy = EngineRecoveryPolicy()
        policy.maximumRetries = 4
        policy.initialDelay = 0.5
        policy.maximumDelay = 1
        let first = policy.recordFailure(at: 100)
        XCTAssertEqual(first.delay, 0.5)
        XCTAssertFalse(first.engageSafeMode)
        XCTAssertEqual(policy.recordFailure(at: 101), .init(delay: 1, engageSafeMode: true))
        XCTAssertEqual(policy.recordFailure(at: 200), .init(delay: 1, engageSafeMode: false))
        XCTAssertEqual(policy.recordFailure(at: 201).delay, 1)
        XCTAssertNil(policy.recordFailure(at: 202).delay)
        policy.reset()
        XCTAssertEqual(policy.recordFailure(at: 300).delay, 0.5)
    }

    func testReadinessRequiresVerifiedIPCCompletedRestoreAndCurrentGeneration() {
        var connection = EngineConnection()
        let endpoint = DaemonEndpoint(port: 50_001, token: "fixture")
        connection.beginVerification(endpoint)
        let generation = connection.generation
        XCTAssertFalse(connection.isReady)
        var health = HealthDto(status: "ok", version: "fixture", ipcVersion: HealthDto.expectedIpcVersion, uptimeMs: 1, providersLoaded: 0)
        health.extensions = .init(phase: "idle", restored: 0, failed: 0, quarantined: 0)
        XCTAssertTrue(connection.acceptHealth(health, generation: generation))
        XCTAssertTrue(connection.isReady)
        XCTAssertFalse(connection.markUsable(generation: generation), "An early idle snapshot cannot release provider work")
        health.extensions = .init(phase: "restoring", restored: 0, failed: 0, quarantined: 0)
        XCTAssertTrue(connection.acceptHealth(health, generation: generation))
        XCTAssertFalse(connection.markUsable(generation: generation))
        health.extensions = .init(phase: "ready", restored: 2, failed: 1, quarantined: 1)
        XCTAssertTrue(connection.acceptHealth(health, generation: generation))
        XCTAssertTrue(connection.markUsable(generation: generation), "Partial restore must not block healthy providers")
        connection.invalidate(.restarting)
        XCTAssertFalse(connection.isReady)
        XCTAssertNil(connection.endpoint)
        XCTAssertFalse(connection.acceptHealth(health, generation: generation))
        XCTAssertFalse(connection.markUsable(generation: generation))
        connection.fail("old failure", generation: generation)
        XCTAssertEqual(connection.phase, .recovering)
    }

    func testSafeModeIsCompletedButIncompatibleOrRecoveryHealthCannotBecomeReady() {
        var connection = EngineConnection()
        connection.beginVerification(.init(port: 50_001, token: "fixture"))
        let generation = connection.generation
        var health = HealthDto(status: "ok", version: "fixture", ipcVersion: HealthDto.expectedIpcVersion, uptimeMs: 1, providersLoaded: 0)
        health.extensions = .init(phase: "safe_mode", restored: 0, failed: 0, quarantined: 0)
        health.safeMode = true
        XCTAssertTrue(connection.acceptHealth(health, generation: generation))
        XCTAssertTrue(connection.markUsable(generation: generation))
        health.recoveryError = "The data store needs recovery"
        XCTAssertFalse(connection.acceptHealth(health, generation: generation))
        XCTAssertFalse(connection.isReady)
        let wrong = HealthDto(status: "ok", version: "fixture", ipcVersion: -1, uptimeMs: 1, providersLoaded: 0)
        XCTAssertFalse(connection.acceptHealth(wrong, generation: generation))
        XCTAssertFalse(connection.markUsable(generation: generation))
    }

    func testCDSRequiresMatchingJarRuntimeArchiveAndSupportedMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cds-consumer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let java = root.appendingPathComponent("runtime/bin/java")
        let modules = root.appendingPathComponent("runtime/lib/modules")
        let jar = root.appendingPathComponent("daemon.jar")
        let archive = root.appendingPathComponent("daemon.jsa")
        let metadata = root.appendingPathComponent("daemon.cds.json")
        try FileManager.default.createDirectory(at: java.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: modules.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("java".utf8).write(to: java)
        try Data("modules".utf8).write(to: modules)
        try Data("jar".utf8).write(to: jar)
        try Data("archive".utf8).write(to: archive)
        func writeMetadata(version: Int = 1) throws {
            try JSONSerialization.data(withJSONObject: ["version": version,
                "jarSha256": CDSArchivePolicy.digest(jar), "modulesSha256": CDSArchivePolicy.digest(modules),
                "archiveSha256": CDSArchivePolicy.digest(archive)]).write(to: metadata)
        }
        XCTAssertNil(CDSArchivePolicy.validatedArchive(archive: archive, jar: jar, java: java))
        try writeMetadata()
        XCTAssertEqual(CDSArchivePolicy.validatedArchive(archive: archive, jar: jar, java: java), archive)
        for changed in [jar, modules, archive] {
            let original = try Data(contentsOf: changed)
            try Data("changed".utf8).write(to: changed)
            XCTAssertNil(CDSArchivePolicy.validatedArchive(archive: archive, jar: jar, java: java))
            try original.write(to: changed)
        }
        try writeMetadata(version: 99)
        XCTAssertNil(CDSArchivePolicy.validatedArchive(archive: archive, jar: jar, java: java))
        try Data(repeating: 32, count: 65_537).write(to: metadata)
        XCTAssertNil(CDSArchivePolicy.validatedArchive(archive: archive, jar: jar, java: java))
    }

    // MARK: Engine output logs (audit A53)

    private func launch(_ script: String, in directory: URL, id: UUID, maxBytes: UInt64 = EngineOutputLog.maxBytes) throws -> EngineLaunchConfiguration {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        let handles = EngineOutputLog.open(in: directory, launchID: id, safeMode: false, maxBytes: maxBytes)
        XCTAssertEqual(handles.count, 2)
        process.standardOutput = handles[0]
        process.standardError = handles[1]
        let configuration = EngineLaunchConfiguration(process: process, endpoint: .init(port: 1, token: "t"), outputHandles: handles, logID: id)
        try process.run()
        process.waitUntilExit()
        return configuration
    }

    func testTwoEngineLaunchesAppendInOrderWithDistinctMarkers() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("engine-logs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = UUID(), second = UUID(), third = UUID()
        // A long first launch followed by a short one: the old code rewrote
        // the start of the file and left the first launch's tail behind.
        try launch("echo first-ready; echo first-long-tail-that-must-stay-before-the-second-launch; echo first-error >&2; exit 3", in: directory, id: first).closeHandles()
        try launch("echo second-ready", in: directory, id: second).closeHandles()
        // A launch that never starts still closes its segment.
        let unstarted = Process()
        unstarted.executableURL = URL(fileURLWithPath: "/bin/sh")
        EngineLaunchConfiguration(process: unstarted, endpoint: .init(port: 1, token: "t"),
            outputHandles: EngineOutputLog.open(in: directory, launchID: third, safeMode: true), logID: third).closeHandles()

        let output = try String(contentsOf: directory.appendingPathComponent(EngineOutputLog.names[0]), encoding: .utf8)
        let lines = output.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 9)
        XCTAssertTrue(lines[0].hasPrefix("=== engine launch \(first.uuidString) started"))
        XCTAssertEqual(Array(lines[1...2]), ["first-ready", "first-long-tail-that-must-stay-before-the-second-launch"])
        XCTAssertTrue(lines[3].hasPrefix("=== engine launch \(first.uuidString) ended") && lines[3].hasSuffix("status=3 ==="))
        XCTAssertTrue(lines[4].hasPrefix("=== engine launch \(second.uuidString) started"))
        XCTAssertEqual(lines[5], "second-ready")
        XCTAssertTrue(lines[6].hasSuffix("status=0 ==="))
        XCTAssertTrue(lines[7].contains(third.uuidString) && lines[7].hasSuffix("safeMode=true ==="))
        XCTAssertTrue(lines[8].hasSuffix("status=not-started ==="))
        let errors = try String(contentsOf: directory.appendingPathComponent(EngineOutputLog.names[1]), encoding: .utf8)
        XCTAssertTrue(errors.contains("first-error"))
        XCTAssertEqual(errors.components(separatedBy: "=== engine launch").count - 1, 6, "stderr carries the same launch markers")
    }

    func testOversizedEngineLogRotatesOnceAndStaysBounded() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("engine-logs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(EngineOutputLog.names[0])
        try launch("head -c 4096 /dev/zero | tr '\\0' a; echo", in: directory, id: UUID(), maxBytes: 1024).closeHandles()
        let old = try Data(contentsOf: url)
        XCTAssertGreaterThan(old.count, 4096)
        let next = UUID()
        try launch("echo fresh", in: directory, id: next, maxBytes: 1024).closeHandles()
        XCTAssertEqual(try Data(contentsOf: EngineOutputLog.rotatedURL(for: url)), old, "the previous file is kept once, whole")
        let current = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(current.hasPrefix("=== engine launch \(next.uuidString) started"), "a new file never begins with a stale tail")
        XCTAssertTrue(current.contains("fresh"))
        // A second rotation replaces the kept file rather than accumulating.
        try launch("head -c 4096 /dev/zero | tr '\\0' b; echo", in: directory, id: UUID(), maxBytes: 16).closeHandles()
        try launch("echo last", in: directory, id: UUID(), maxBytes: 16).closeHandles()
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(EngineOutputLog.names[0]) }
        XCTAssertEqual(files.sorted(), [EngineOutputLog.names[0], EngineOutputLog.names[0] + ".1"])
    }

    // MARK: Demand-aware bridge polling (measured idle cost)

    func testBridgePollsRunAtFullSpeedOnlyWhileTheEngineIsInUse() {
        EngineDemand.reset()
        defer { EngineDemand.reset() }
        let now = ContinuousClock.now
        func interval(_ at: ContinuousClock.Instant) -> Duration {
            EngineDemand.pollInterval(active: .milliseconds(500), idle: .seconds(3), now: at)
        }
        XCTAssertEqual(interval(now), .seconds(3), "idle: no request has been made")
        // The polls themselves, and health checks, are not demand.
        for path in EngineDemand.passivePaths { EngineDemand.begin(path).end() }
        XCTAssertFalse(EngineDemand.isActive(now: now))

        let search = EngineDemand.begin("search/stream")
        let details = EngineDemand.begin("details")
        XCTAssertEqual(interval(now.advanced(by: .seconds(600))), .milliseconds(500), "a long request keeps the bridges fast throughout")
        search.end()
        XCTAssertTrue(EngineDemand.isActive(now: now.advanced(by: .seconds(600))), "another request is still in flight")
        details.end()
        let ended = ContinuousClock.now
        XCTAssertEqual(interval(ended.advanced(by: .seconds(5))), .milliseconds(500), "just finished: follow-up work is likely")
        XCTAssertEqual(interval(ended.advanced(by: EngineDemand.lingering + .seconds(1))), .seconds(3), "then the app is idle again")
    }
}
