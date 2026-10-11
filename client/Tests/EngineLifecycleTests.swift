import Synchronization
import XCTest
@testable import CloudStream

private actor EngineTestGate {
    private var open = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !open { await withCheckedContinuation { waiting.append($0) } } }
    func release() { open = true; let held = waiting; waiting.removeAll(); held.forEach { $0.resume() } }
}

@MainActor
final class EngineLifecycleTests: XCTestCase {
    private var supervisors: [DaemonSupervisor] = []
    private var roots: [URL] = []
    private var processes: [Process] = []

    override func tearDown() async throws {
        for supervisor in supervisors { await stop(supervisor) }
        for process in processes where process.isRunning { process.terminate() }
        for root in roots { try? FileManager.default.removeItem(at: root) }
        supervisors = []; processes = []; roots = []
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("engine-lifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.script.write(to: root.appendingPathComponent("engine.py"), atomically: true, encoding: .utf8)
        roots.append(root)
        return root
    }

    private func prepared(root: URL, index: Int, mode: String = "normal", safeMode: Bool = false) -> EngineLaunchConfiguration {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [root.appendingPathComponent("engine.py").path, root.path, mode, "\(index)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        processes.append(process)
        return EngineLaunchConfiguration(process: process, endpoint: .init(port: 50_000 + index, token: "fixture-token-\(index)"), safeMode: safeMode)
    }

    private func fastConfiguration() -> DaemonSupervisor.Configuration {
        var config = DaemonSupervisor.Configuration()
        config.startupTimeout = 0.25
        config.startupPoll = 0.01
        config.heartbeatInterval = 0.03
        config.idleHeartbeatInterval = 0.03
        config.terminateGrace = 0.4
        config.forceWait = 1
        config.recovery.initialDelay = 0.02
        config.recovery.maximumDelay = 0.05
        return config
    }

    private func own(_ supervisor: DaemonSupervisor) -> DaemonSupervisor { supervisors.append(supervisor); return supervisor }
    private func stop(_ supervisor: DaemonSupervisor) async {
        await withCheckedContinuation { continuation in supervisor.stop { continuation.resume() } }
    }
    private func until(timeout: TimeInterval = 5, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while !predicate() {
            if ContinuousClock.now >= deadline { XCTFail("Engine fixture condition timed out"); throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private func exists(_ root: URL, _ file: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(file).path) }

    func testRestartWaitsForDataLockReleaseAndCoalescesRequests() async throws {
        let root = try fixture()
        var launched = 0
        let supervisor = own(DaemonSupervisor(configuration: fastConfiguration(), makeLaunch: { [self] safe in
            launched += 1
            return prepared(root: root, index: launched, mode: launched == 1 ? "slow-stop" : "normal", safeMode: safe)
        }, healthProbe: { _ in true }, activitiesEnabled: false))
        supervisor.start()
        try await until { exists(root, "started-1") && supervisor.endpoint != nil }
        let first = processes[0]
        supervisor.restart()
        supervisor.restart()
        supervisor.restart(safeMode: true)
        try await until { exists(root, "started-2") && supervisor.endpoint?.port == 50_002 }
        XCTAssertEqual(launched, 2)
        XCTAssertFalse(first.isRunning)
        XCTAssertEqual(first.terminationStatus, 0)
        XCTAssertTrue(exists(root, "exited-1"))
        XCTAssertFalse(exists(root, "lock-failure-2"), "Replacement must not overlap the old data-root lock")
        XCTAssertTrue(supervisor.safeModeActive)
    }

    func testNeverHealthyLiveEngineIsStoppedAndRecoveryIsBounded() async throws {
        let root = try fixture()
        var config = fastConfiguration(); config.recovery.maximumRetries = 2
        var launched = 0
        let supervisor = own(DaemonSupervisor(configuration: config, makeLaunch: { [self] safe in
            launched += 1
            return prepared(root: root, index: launched, safeMode: safe)
        }, healthProbe: { _ in false }, activitiesEnabled: false))
        supervisor.start()
        try await until { if case .error = supervisor.state { return supervisor.launchID == nil }; return false }
        XCTAssertEqual(launched, 3)
        XCTAssertTrue(processes.allSatisfy { !$0.isRunning })
        XCTAssertNil(supervisor.endpoint)
    }

    func testFailedSpawnUsesTheSameBudgetAndExplicitRetryClearsIt() async throws {
        var config = fastConfiguration(); config.recovery.maximumRetries = 1
        var attempts = 0
        let supervisor = own(DaemonSupervisor(configuration: config, makeLaunch: { _ in
            attempts += 1
            throw CocoaError(.fileNoSuchFile)
        }, activitiesEnabled: false))
        supervisor.start()
        try await until { if case .error = supervisor.state { return true }; return false }
        XCTAssertEqual(attempts, 2)
        supervisor.restart()
        try await until { attempts == 4 && { if case .error = supervisor.state { return true }; return false }() }
        XCTAssertNil(supervisor.launchID)
    }

    func testDataRootInUseStopsRecoveryWithAnActionableMessage() async throws {
        let root = try fixture()
        var config = fastConfiguration(); config.recovery.maximumRetries = 5
        config.startupTimeout = 10 // the fixture must exit on its own, not be stopped at the deadline
        var launched = 0
        let supervisor = own(DaemonSupervisor(configuration: config, makeLaunch: { [self] safe in
            launched += 1
            return prepared(root: root, index: launched, mode: "in-use", safeMode: safe)
        }, healthProbe: { _ in false }, activitiesEnabled: false))
        supervisor.start()
        try await until { if case .error = supervisor.state { return supervisor.launchID == nil }; return false }
        XCTAssertEqual(launched, 1, "retrying cannot help while another copy owns the data")
        guard case .error(let message) = supervisor.state else { return XCTFail("expected an error") }
        XCTAssertTrue(message.contains("Another copy of CloudStream"), message)
    }

    func testAnOrphanedEngineHoldingTheLockIsStoppedOnceThenTheEngineStarts() async throws {
        let root = try fixture()
        var launched = 0
        let reaps = Mutex(0)
        let supervisor = own(DaemonSupervisor(configuration: fastConfiguration(), makeLaunch: { [self] safe in
            launched += 1
            return prepared(root: root, index: launched, mode: launched == 1 ? "in-use" : "normal", safeMode: safe)
        }, healthProbe: { _ in true }, reapOrphan: { reaps.withLock { $0 += 1 }; return .reaped(pid: 4242) }, activitiesEnabled: false))
        supervisor.start()
        try await until { supervisor.endpoint?.port == 50_002 }
        XCTAssertEqual(launched, 2)
        XCTAssertEqual(reaps.withLock { $0 }, 1)
    }

    func testOrphanReapIsAttemptedOnlyOncePerStart() async throws {
        let root = try fixture()
        var launched = 0
        let reaps = Mutex(0)
        let supervisor = own(DaemonSupervisor(configuration: fastConfiguration(), makeLaunch: { [self] safe in
            launched += 1
            return prepared(root: root, index: launched, mode: "in-use", safeMode: safe)
        }, healthProbe: { _ in false }, reapOrphan: { reaps.withLock { $0 += 1 }; return .reaped(pid: 4242) }, activitiesEnabled: false))
        supervisor.start()
        try await until { if case .error = supervisor.state { return supervisor.launchID == nil }; return false }
        XCTAssertEqual(launched, 2, "one retry after the reap, then the lock is someone else's")
        XCTAssertEqual(reaps.withLock { $0 }, 1)
    }

    func testStaleEngineIdentificationIsStrict() throws {
        let root = URL(fileURLWithPath: "/Users/someone/.cloudstream-macos")
        XCTAssertTrue(StaleEngineReaper.isEngineCommandLine(["/x/java", "-Dcs.cloudstream.home=/Users/someone/.cloudstream-macos", "-jar", "tools/daemon.jar", "0"], root: root))
        XCTAssertFalse(StaleEngineReaper.isEngineCommandLine(["/x/java", "-Dcs.cloudstream.home=/Users/other/.cloudstream-macos", "-jar", "tools/daemon.jar", "0"], root: root),
            "another data root's engine is not ours to stop")
        XCTAssertFalse(StaleEngineReaper.isEngineCommandLine(["/usr/bin/python3", "-Dcs.cloudstream.home=/Users/someone/.cloudstream-macos"], root: root))
        XCTAssertFalse(StaleEngineReaper.isEngineCommandLine(["/x/java", "-Dcs.cloudstream.home=/Users/someone/.cloudstream-macos", "-cp", "daemon.jar", "com.lagradost.macos.MainKt", "--worker"], root: root),
            "a worker is never targeted")
        // This test process: alive, same user, but its parent is not launchd and it is not an engine.
        XCTAssertEqual(StaleEngineReaper.assess(pid: getpid(), root: root), .heldByAnotherOwner)
        XCTAssertEqual(StaleEngineReaper.assess(pid: 99_999_999, root: root), .nothingToReap)
        let arguments = try XCTUnwrap(StaleEngineReaper.arguments(of: getpid()))
        XCTAssertEqual(arguments.first.map { URL(fileURLWithPath: $0).lastPathComponent }, ProcessInfo.processInfo.arguments.first.map { URL(fileURLWithPath: $0).lastPathComponent })
        let lockRoot = FileManager.default.temporaryDirectory.appendingPathComponent("reaper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: lockRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: lockRoot) }
        XCTAssertNil(StaleEngineReaper.lockedPid(root: lockRoot))
        try "\(getpid())\n".write(to: lockRoot.appendingPathComponent("daemon.lock"), atomically: true, encoding: .utf8)
        XCTAssertEqual(StaleEngineReaper.lockedPid(root: lockRoot), getpid())
    }

    func testSafeModeStaysLatchedAcrossCrashesUntilExplicitClear() async throws {
        let root = try fixture()
        var config = fastConfiguration(); config.recovery.maximumRetries = 3
        var modes: [Bool] = []
        let supervisor = own(DaemonSupervisor(configuration: config, makeLaunch: { [self] safe in
            modes.append(safe)
            return prepared(root: root, index: modes.count, mode: modes.count <= 4 ? "crash" : "normal", safeMode: safe)
        }, healthProbe: { _ in true }, activitiesEnabled: false))
        supervisor.start()
        try await until { modes.count == 4 && supervisor.launchID == nil }
        XCTAssertEqual(modes, [false, false, true, true])
        supervisor.restart(safeMode: false)
        try await until { modes.count == 5 && exists(root, "started-5") && supervisor.endpoint != nil }
        XCTAssertEqual(modes.last, false)
        XCTAssertFalse(supervisor.safeModeActive)
        XCTAssertNil(supervisor.safeModeReason)
    }

    func testLateOldHealthCannotPublishOverAReplacement() async throws {
        let root = try fixture()
        let oldHealth = EngineTestGate()
        var launched = 0
        let supervisor = own(DaemonSupervisor(configuration: fastConfiguration(), makeLaunch: { [self] safe in
            launched += 1
            return prepared(root: root, index: launched, safeMode: safe)
        }, healthProbe: { endpoint in
            if endpoint.port == 50_001 { await oldHealth.wait() }
            return true
        }, activitiesEnabled: false))
        supervisor.start()
        try await until { exists(root, "started-1") }
        supervisor.restart()
        try await until { supervisor.endpoint?.port == 50_002 }
        let current = supervisor.launchID
        await oldHealth.release()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(supervisor.endpoint?.port, 50_002)
        XCTAssertEqual(supervisor.launchID, current)
        XCTAssertFalse(processes[0].isRunning)
    }

    func testStopDuringPreparationNeverLaunchesOrPublishesLateReady() async throws {
        let root = try fixture()
        let preparedGate = EngineTestGate()
        var entered = false
        let supervisor = own(DaemonSupervisor(configuration: fastConfiguration(), makeLaunch: { [self] safe in
            entered = true
            await preparedGate.wait()
            return prepared(root: root, index: 1, safeMode: safe)
        }, healthProbe: { _ in true }, activitiesEnabled: false))
        supervisor.start()
        try await until { entered }
        let stopped = expectation(description: "ordered stop completed")
        supervisor.stop { stopped.fulfill() }
        await preparedGate.release()
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertTrue(processes.allSatisfy { !$0.isRunning })
        XCTAssertNil(supervisor.endpoint)
        XCTAssertNil(supervisor.launchID)
    }

    func testIndependentSubscriptionsReplayCurrentEndpointAfterCancellation() async throws {
        let root = try fixture()
        let supervisor = own(DaemonSupervisor(configuration: fastConfiguration(), makeLaunch: { [self] safe in
            prepared(root: root, index: 1, safeMode: safe)
        }, healthProbe: { _ in true }, activitiesEnabled: false))
        let old = Task { for await _ in supervisor.stateChanges { if Task.isCancelled { break } } }
        old.cancel()
        await old.value
        supervisor.start()
        try await until { supervisor.endpoint != nil }
        var first = supervisor.endpointChanges.makeAsyncIterator()
        var second = supervisor.endpointChanges.makeAsyncIterator()
        let firstEndpoint = await first.next()
        let secondEndpoint = await second.next()
        XCTAssertEqual(firstEndpoint, supervisor.endpoint)
        XCTAssertEqual(secondEndpoint, supervisor.endpoint)
        var state = supervisor.stateChanges.makeAsyncIterator()
        let initialState = await state.next()
        XCTAssertEqual(initialState, supervisor.state)
        let cancelled = Task { for await _ in supervisor.connectionChanges { if Task.isCancelled { break } } }
        cancelled.cancel()
        await cancelled.value
        var connection = supervisor.connectionChanges.makeAsyncIterator()
        let ready = await connection.next()
        XCTAssertEqual(ready, supervisor.connectionSnapshot)
        XCTAssertEqual(ready?.endpoint, firstEndpoint)
        XCTAssertNotNil(ready?.launchID)
        await stop(supervisor)
        let disconnected = await connection.next()
        XCTAssertEqual(disconnected, supervisor.connectionSnapshot)
        XCTAssertNil(disconnected?.endpoint)
        XCTAssertNil(disconnected?.launchID)
    }

    func testForcedStopKeepsOwnershipUntilIgnoredTermProcessExits() async throws {
        let root = try fixture()
        var config = fastConfiguration(); config.terminateGrace = 0.05
        let supervisor = own(DaemonSupervisor(configuration: config, makeLaunch: { [self] safe in
            prepared(root: root, index: 1, mode: "ignore-stop", safeMode: safe)
        }, healthProbe: { _ in true }, activitiesEnabled: false))
        supervisor.start()
        try await until { exists(root, "started-1") }
        await stop(supervisor)
        XCTAssertFalse(processes[0].isRunning)
        XCTAssertNil(supervisor.launchID)
        XCTAssertNil(supervisor.endpoint)
    }

    func testEngineRestartPreservesIndependentTransferAndApplicationStopReapsIt() async throws {
        let root = try fixture()
        var launched = 0
        let supervisor = own(DaemonSupervisor(configuration: fastConfiguration(), makeLaunch: { [self] safe in
            launched += 1
            return prepared(root: root, index: launched, safeMode: safe)
        }, healthProbe: { _ in true }, activitiesEnabled: false))
        let transfer = Process()
        transfer.executableURL = URL(fileURLWithPath: "/bin/sleep")
        transfer.arguments = ["60"]
        try transfer.run()
        processes.append(transfer)
        supervisor.track(child: transfer)
        supervisor.start()
        try await until { exists(root, "started-1") }
        supervisor.restart()
        try await until { exists(root, "started-2") && supervisor.endpoint != nil }
        XCTAssertTrue(transfer.isRunning)
        await stop(supervisor)
        XCTAssertFalse(transfer.isRunning)
    }

    func testSustainedHealthResetsRetryBudgetButPreservesDesiredSafeMode() async throws {
        let root = try fixture()
        var config = fastConfiguration()
        config.recovery.maximumRetries = 2
        config.stableHealthWindow = 0.1
        var modes: [Bool] = []
        let supervisor = own(DaemonSupervisor(configuration: config, makeLaunch: { [self] safe in
            modes.append(safe)
            return prepared(root: root, index: modes.count, mode: modes.count <= 2 ? "crash" : "normal", safeMode: safe)
        }, healthProbe: { _ in true }, activitiesEnabled: false))
        supervisor.start()
        try await until { exists(root, "started-3") && supervisor.endpoint?.port == 50_003 }
        try await Task.sleep(for: .milliseconds(350))
        processes[2].terminate()
        try await until { exists(root, "started-4") && supervisor.endpoint?.port == 50_004 }
        XCTAssertEqual(modes, [false, false, true, true])
        XCTAssertTrue(supervisor.safeModeActive)
    }

    private static let script = """
    import fcntl, os, signal, sys, time
    root, mode, index = sys.argv[1:4]
    lock = open(os.path.join(root, 'data.lock'), 'a')
    try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        open(os.path.join(root, 'lock-failure-' + index), 'w').close()
        sys.exit(73)
    def stop(*args):
        if mode == 'ignore-stop': return
        if mode == 'slow-stop': time.sleep(0.2)
        lock.close()
        open(os.path.join(root, 'exited-' + index), 'w').close()
        sys.exit(0)
    signal.signal(signal.SIGTERM, stop)
    open(os.path.join(root, 'started-' + index), 'w').close()
    if mode == 'crash':
        time.sleep(0.03)
        sys.exit(23)
    if mode == 'in-use':
        time.sleep(0.03)
        sys.exit(75)
    while True: time.sleep(0.01)
    """
}
