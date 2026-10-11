import AppKit
import Darwin
import Foundation

/// Spawned-daemon identity handed to [DaemonClient] after launch.
struct DaemonEndpoint: Sendable, Equatable {
    let port: Int
    let token: String
}

/// Daemon state surfaced in the sidebar "Engine Status" footer.
enum DaemonState: Equatable, Sendable {
    case initializing
    case ready(port: Int)
    case restarting
    case error(String)
}

/// Owns every engine launch until confirmed exit. Restart requests coalesce;
/// download children retain their independent lifetime until application stop.
@MainActor
@Observable
final class DaemonSupervisor {
    static let shared = DaemonSupervisor()

    struct Configuration: Sendable {
        var startupTimeout: TimeInterval = 20
        var startupPoll: TimeInterval = 0.15
        var heartbeatInterval: TimeInterval = 3
        /// While the app is not using the engine (EngineDemand), health is
        /// checked less often; an exit is noticed at once either way.
        var idleHeartbeatInterval: TimeInterval = 15
        var heartbeatMisses = 4
        var terminateGrace: TimeInterval = 1.5
        var forceWait: TimeInterval = 3
        var stableHealthWindow: TimeInterval = 60
        var recovery = EngineRecoveryPolicy()
    }

    private final class Launch {
        let id = UUID()
        let configuration: EngineLaunchConfiguration
        /// The port becomes known when the engine announces it (audit M1).
        var endpoint: DaemonEndpoint
        var stopping = false
        init(_ configuration: EngineLaunchConfiguration) {
            self.configuration = configuration
            self.endpoint = configuration.endpoint
        }
    }

    private(set) var state: DaemonState = .initializing {
        didSet {
            stateSubscribers.values.forEach { $0.yield(state) }
            publishConnectionSnapshot()
        }
    }
    private(set) var endpoint: DaemonEndpoint? {
        didSet {
            if let endpoint { endpointSubscribers.values.forEach { $0.yield(endpoint) } }
            publishConnectionSnapshot()
        }
    }
    private(set) var launchID: UUID?
    private(set) var restartCount = 0
    private(set) var safeModeActive = false
    private(set) var safeModeReason: String?
    private var safeModeRequested = false
    private var requestedSafeModeReason: String?
    private var recovery: EngineRecoveryPolicy
    private let configuration: Configuration
    @ObservationIgnored private let makeLaunch: (@MainActor (Bool) async throws -> EngineLaunchConfiguration)?
    @ObservationIgnored private let healthProbe: @Sendable (DaemonEndpoint) async -> Bool
    @ObservationIgnored private let now: @Sendable () -> TimeInterval
    @ObservationIgnored private let sleep: @Sendable (TimeInterval) async throws -> Void
    /// Stops an orphaned engine that holds the data-root lock (Remediation 1.4).
    @ObservationIgnored private let reapOrphan: @Sendable () async -> StaleEngineReaper.Outcome
    /// One reap per start request, so a lock held by something else cannot loop.
    private var orphanReapAttempted = false
    private let activitiesEnabled: Bool
    @ObservationIgnored private var stateSubscribers: [UUID: AsyncStream<DaemonState>.Continuation] = [:]
    @ObservationIgnored private var endpointSubscribers: [UUID: AsyncStream<DaemonEndpoint>.Continuation] = [:]
    @ObservationIgnored private var connectionSubscribers: [UUID: AsyncStream<ConnectionSnapshot>.Continuation] = [:]

    struct ConnectionSnapshot: Equatable, Sendable {
        let state: DaemonState
        let endpoint: DaemonEndpoint?
        let launchID: UUID?
    }

    var connectionSnapshot: ConnectionSnapshot {
        .init(state: state, endpoint: endpoint, launchID: launchID)
    }

    /// State and endpoint travel together, including disconnection. Consumers
    /// can reject a queued older snapshot against the current launch snapshot.
    var connectionChanges: AsyncStream<ConnectionSnapshot> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            connectionSubscribers[id] = continuation
            continuation.yield(connectionSnapshot)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.connectionSubscribers.removeValue(forKey: id) }
            }
        }
    }

    private func publishConnectionSnapshot() {
        let snapshot = connectionSnapshot
        connectionSubscribers.values.forEach { $0.yield(snapshot) }
    }

    /// Every access creates an independent subscription and replays current
    /// state. Cancelling one window/consumer cannot terminate another's stream.
    var stateChanges: AsyncStream<DaemonState> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            stateSubscribers[id] = continuation
            continuation.yield(state)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.stateSubscribers.removeValue(forKey: id) }
            }
        }
    }
    var endpointChanges: AsyncStream<DaemonEndpoint> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            endpointSubscribers[id] = continuation
            if let endpoint { continuation.yield(endpoint) }
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.endpointSubscribers.removeValue(forKey: id) }
            }
        }
    }

    private var launch: Launch?
    private var managedProcesses: [Process] = []
    @ObservationIgnored private var controlTask: Task<Void, Never>?
    @ObservationIgnored private var backoffTask: Task<Void, Never>?
    @ObservationIgnored private var healthTask: Task<Void, Never>?
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    @ObservationIgnored private var transportReset: Task<Void, Never>?
    private var requestedRevision: UInt64 = 0
    private var completedRevision: UInt64 = 0
    private var pendingDelay: TimeInterval = 0
    private var wantsEngine = false
    private var stopCompletions: [@Sendable () -> Void] = []
    private var appNapActivity: (any NSObjectProtocol)?

    init(configuration: Configuration = Configuration(),
         makeLaunch: (@MainActor (Bool) async throws -> EngineLaunchConfiguration)? = nil,
         healthProbe: @escaping @Sendable (DaemonEndpoint) async -> Bool = DaemonSupervisor.isHealthy,
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
         reapOrphan: @escaping @Sendable () async -> StaleEngineReaper.Outcome = { await StaleEngineReaper.reap(root: EngineDataRoot.url()) },
         activitiesEnabled: Bool = true) {
        self.configuration = configuration
        self.reapOrphan = reapOrphan
        self.recovery = configuration.recovery
        self.makeLaunch = makeLaunch
        self.healthProbe = healthProbe
        self.now = now
        self.sleep = sleep
        self.activitiesEnabled = activitiesEnabled
    }

    func start() {
        guard !wantsEngine else { return }
        wantsEngine = true
        if activitiesEnabled, appNapActivity == nil {
            appNapActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "CloudStream Daemon Supervisor")
        }
        if activitiesEnabled, NSEvent.modifierFlags.contains(.option) {
            safeModeRequested = true
            requestedSafeModeReason = "user"
        }
        requestTransition()
    }

    func stop(completion: (@Sendable () -> Void)? = nil) {
        if let completion { stopCompletions.append(completion) }
        wantsEngine = false
        if let activity = appNapActivity { ProcessInfo.processInfo.endActivity(activity); appNapActivity = nil }
        requestTransition()
    }

    func restart(safeMode: Bool) {
        safeModeRequested = safeMode
        requestedSafeModeReason = safeMode ? "user" : nil
        restart()
    }

    /// Explicit retry resets the budget. Automatic recovery never clears the
    /// desired safe-mode latch or resets its own failure history.
    func restart() {
        recovery.reset()
        orphanReapAttempted = false
        wantsEngine = true
        restartCount += 1
        requestTransition()
    }

    private func requestTransition(delay: TimeInterval = 0) {
        requestedRevision &+= 1
        pendingDelay = delay
        healthTask?.cancel()
        heartbeatTask?.cancel()
        backoffTask?.cancel()
        endpoint = nil
        state = wantsEngine ? .restarting : .initializing
        transportReset = Task { await DaemonClient.shared.clearEndpoint() }
        guard controlTask == nil else { return }
        controlTask = Task { [weak self] in await self?.driveTransitions() }
    }

    private func driveTransitions() async {
        while completedRevision != requestedRevision {
            let revision = requestedRevision
            if let current = launch {
                current.stopping = true
                let exited = await Self.terminateAndWait(current.configuration.process,
                    grace: configuration.terminateGrace, forceWait: configuration.forceWait)
                guard exited else {
                    state = .error("The previous engine could not be stopped. Close CloudStream before retrying.")
                    completedRevision = requestedRevision
                    controlTask = nil
                    return // Retain ownership; never start over a live process/data lock.
                }
                release(current)
            }
            if !wantsEngine {
                let children = managedProcesses
                var stopped = true
                for child in children {
                    stopped = await Self.terminateAndWait(child, grace: configuration.terminateGrace,
                        forceWait: configuration.forceWait) && stopped
                    if !child.isRunning { untrack(child: child) }
                }
                await transportReset?.value
                if revision != requestedRevision { continue }
                completedRevision = revision
                if stopped {
                    let completions = stopCompletions
                    stopCompletions.removeAll()
                    completions.forEach { $0() }
                } else { state = .error("An owned child process could not be stopped.") }
                continue
            }
            if pendingDelay > 0 {
                let delay = pendingDelay
                backoffTask = Task { [sleep] in try? await sleep(delay) }
                await backoffTask?.value
                backoffTask = nil
                if revision != requestedRevision { continue }
            }
            state = .initializing
            do {
                let prepared: EngineLaunchConfiguration
                if let makeLaunch { prepared = try await makeLaunch(safeModeRequested) }
                else { prepared = try await makeBundledLaunch(safeMode: safeModeRequested) }
                guard revision == requestedRevision, wantsEngine else { prepared.closeHandles(); continue }
                let current = Launch(prepared)
                launch = current
                launchID = current.id
                safeModeActive = prepared.safeMode
                safeModeReason = prepared.policySafeMode ? "policy" : requestedSafeModeReason
                let id = current.id
                prepared.process.terminationHandler = { [weak self] process in
                    Task { @MainActor in self?.processExited(process, id: id) }
                }
                try prepared.process.run()
                track(child: prepared.process)
                if let line = prepared.inputLine, let pipe = prepared.stdin {
                    try pipe.fileHandleForWriting.write(contentsOf: line)
                }
                completedRevision = revision
                healthTask = Task { [weak self] in await self?.awaitHealthy(current) }
            } catch {
                // A failed run has no live process; a token write failure does.
                if let current = launch, !current.configuration.process.isRunning { release(current) }
                completedRevision = revision
                recover("Failed to start engine: \(error.localizedDescription)")
            }
        }
        controlTask = nil
    }

    /// PID of the engine this supervisor currently owns, if it is running.
    var ownedEngineProcessID: Int32? {
        guard let process = launch?.configuration.process, process.isRunning else { return nil }
        return process.processIdentifier
    }

    private func release(_ current: Launch) {
        guard launch === current else { return }
        current.configuration.process.terminationHandler = nil
        untrack(child: current.configuration.process)
        current.configuration.closeHandles()
        launch = nil
        launchID = nil
        endpoint = nil
    }

    private func processExited(_ process: Process, id: UUID) {
        guard let current = launch, current.id == id, current.configuration.process === process else { return }
        guard !current.stopping else { return } // Ordered transition owns release.
        release(current)
        guard wantsEngine else { return }
        if process.terminationReason == .exit, process.terminationStatus == Self.dataRootInUseStatus {
            DaemonLog.client("daemon.data_root_in_use")
            // An engine orphaned by a previous app run may hold the lock: stop
            // it once and start again. Another running copy is left alone.
            let tried = orphanReapAttempted
            orphanReapAttempted = true
            state = .restarting
            let reap = reapOrphan
            Task { [weak self] in
                let outcome: StaleEngineReaper.Outcome = tried ? .heldByAnotherOwner : await reap()
                self?.dataRootInUse(outcome)
            }
            return
        }
        recover("The engine exited unexpectedly (\(Self.describe(process))).")
    }

    private func dataRootInUse(_ outcome: StaleEngineReaper.Outcome) {
        guard wantsEngine, launch == nil else { return }
        if case .reaped = outcome {
            requestTransition()
            return
        }
        // Retrying cannot help while the other copy runs; say what to do.
        wantsEngine = false
        requestTransition()
        state = .error("Another copy of CloudStream is already running and using your library. Quit it, then choose Retry.")
    }

    /// Engine exit status for "another engine owns this data root" (DataRootLock.IN_USE_EXIT_STATUS).
    nonisolated static let dataRootInUseStatus: Int32 = 75

    nonisolated static func describe(_ process: Process) -> String {
        switch process.terminationReason {
        case .uncaughtSignal:
            let name = process.terminationStatus == SIGKILL ? "SIGKILL (macOS may have ended it under memory pressure)"
                : process.terminationStatus == SIGTERM ? "SIGTERM" : "signal \(process.terminationStatus)"
            return "stopped by \(name)"
        default:
            return "code \(process.terminationStatus)"
        }
    }

    private func recover(_ message: String) {
        guard wantsEngine else { return }
        let decision = recovery.recordFailure(at: now())
        if decision.engageSafeMode, !safeModeRequested {
            safeModeRequested = true
            requestedSafeModeReason = "crash-loop"
        }
        DaemonLog.client("daemon.recovery", fields: ["attempt": "\(recovery.attempts)", "reason": message])
        if let delay = decision.delay {
            restartCount += 1
            requestTransition(delay: delay)
        } else {
            wantsEngine = false
            requestTransition()
            state = .error("\(message) Automatic recovery stopped after repeated failures. Use Restart to retry.")
        }
    }

    private func isCurrent(_ current: Launch) -> Bool { wantsEngine && launch === current && !current.stopping && current.configuration.process.isRunning }

    private func awaitHealthy(_ current: Launch) async {
        let deadline = now() + configuration.startupTimeout
        if let announcement = current.configuration.announcement {
            // Port 0 launch: only the engine's own stdout says where it listens.
            guard let port = await announcement.port(timeout: configuration.startupTimeout) else {
                guard !Task.isCancelled, isCurrent(current) else { return }
                recover("The engine did not report its port before its startup deadline.")
                return
            }
            guard !Task.isCancelled, isCurrent(current) else { return }
            if current.configuration.verifiesSocketOwner {
                let pid = current.configuration.process.processIdentifier
                let owned = await Task.detached(priority: .utility) { EngineSocketOwnership.process(pid, listensOn: port) }.value
                guard owned else {
                    DaemonLog.client("daemon.port_not_owned", fields: ["port": "\(port)"])
                    guard !Task.isCancelled, isCurrent(current) else { return }
                    recover("The engine's port is held by another process.")
                    return
                }
            }
            current.endpoint = DaemonEndpoint(port: port, token: current.endpoint.token)
        }
        while now() < deadline, !Task.isCancelled, isCurrent(current) {
            if await healthProbe(current.endpoint) {
                guard !Task.isCancelled, isCurrent(current) else { return }
                await transportReset?.value
                guard !Task.isCancelled, isCurrent(current) else { return }
                // Credentials and the token reach the engine only after it proved itself.
                await DaemonClient.shared.updateEndpoint(.init(port: current.endpoint.port, token: current.endpoint.token))
                if await MainActor.run(body: { AppLock.shared.isLocked }) {
                    _ = try? await DaemonClient.shared.setAppLock(locked: true)
                }
                guard !Task.isCancelled, isCurrent(current) else { return }
                endpoint = current.endpoint
                state = .ready(port: current.endpoint.port)
                orphanReapAttempted = false
                startHeartbeat(current)
                return
            }
            do { try await sleep(configuration.startupPoll) } catch { return }
        }
        guard !Task.isCancelled, isCurrent(current) else { return }
        recover("The engine did not become healthy before its startup deadline.")
    }

    private func startHeartbeat(_ current: Launch) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            guard let self else { return }
            var misses = 0
            var healthySince = now()
            while !Task.isCancelled, isCurrent(current) {
                let interval = EngineDemand.isActive() ? configuration.heartbeatInterval : configuration.idleHeartbeatInterval
                do { try await sleep(interval) } catch { return }
                guard !Task.isCancelled, isCurrent(current) else { return }
                let healthy = await healthProbe(current.endpoint)
                guard !Task.isCancelled, isCurrent(current) else { return }
                if healthy {
                    misses = 0
                    if now() - healthySince >= configuration.stableHealthWindow { recovery.reset() }
                } else {
                    misses += 1
                    healthySince = now()
                    if misses >= configuration.heartbeatMisses { recover("The engine stopped answering health checks."); return }
                }
            }
        }
    }

    func track(child process: Process) {
        guard process.isRunning, !managedProcesses.contains(where: { $0 === process }) else { return }
        managedProcesses.append(process)
    }
    func untrack(child process: Process) { managedProcesses.removeAll { $0 === process } }
    func untrackExitedChildren() { managedProcesses.removeAll { $0 !== launch?.configuration.process && !$0.isRunning } }

    /// Escalation retains the Process object and checks its exit state; no
    /// delayed task targets a remembered bare PID or a broad process pattern.
    nonisolated private static func terminateAndWait(_ process: Process, grace: TimeInterval, forceWait: TimeInterval) async -> Bool {
        await Task.detached(priority: .utility) {
            guard process.isRunning else { return true }
            kill(process.processIdentifier, SIGCONT)
            process.terminate()
            let clock = ContinuousClock()
            let graceDeadline = clock.now.advanced(by: .seconds(grace))
            while process.isRunning, clock.now < graceDeadline { try? await Task.sleep(for: .milliseconds(25)) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            let exitDeadline = clock.now.advanced(by: .seconds(forceWait))
            while process.isRunning, clock.now < exitDeadline { try? await Task.sleep(for: .milliseconds(25)) }
            return !process.isRunning
        }.value
    }

    /// Healthy only when the listener proves it holds this launch's token
    /// (audit M1); the token is never sent. Uses its own connection pool, so
    /// application traffic cannot delay it into a false restart (audit A1).
    nonisolated static func isHealthy(_ endpoint: DaemonEndpoint) async -> Bool {
        let clock = ContinuousClock()
        let started = clock.now
        let outcome = await EngineHealthProbe.probe(port: endpoint.port, token: endpoint.token)
        let elapsed = started.duration(to: clock.now)
        if elapsed > .seconds(1) {
            DaemonLog.client("daemon.health_slow", fields: ["ms": "\(Int(elapsed / .milliseconds(1)))"])
        }
        if case .impostor = outcome { DaemonLog.client("daemon.health_impostor", fields: ["port": "\(endpoint.port)"]) }
        return outcome.isHealthy
    }

    private func makeBundledLaunch(safeMode: Bool) async throws -> EngineLaunchConfiguration {
        guard let java = bundledJavaPath, let jar = bundledDaemonJarPath else {
            throw CocoaError(.fileNoSuchFile)
        }
        let policy = ManagedExtensionPolicy.current()
        let activeSafeMode = safeMode || policy.safeModeOnly
        let token = SecurityVault.makeToken()
        let root = EngineDataRoot.url()
        let temporary = root.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: java)
        // Nothing from the app's own environment reaches the engine, and so its
        // extension workers: no agent sockets, credentials or JVM options (H1).
        process.environment = Self.engineEnvironment(temporary: temporary)
        // JDK 17 matches an AppCDS archive against the class path as written.
        // The packaged archive is recorded as `tools/daemon.jar` relative to
        // Contents/Resources (scripts/lib_artifact.sh record_archive), so the
        // bundled jar is launched the same way and the archive stays valid
        // wherever the app is copied. Workers inherit this directory.
        let jarURL = URL(fileURLWithPath: jar)
        let resources = jarURL.deletingLastPathComponent().deletingLastPathComponent()
        let bundledJar = jarURL.deletingLastPathComponent().lastPathComponent == "tools"
            && resources.standardizedFileURL.path == Bundle.main.resourceURL?.standardizedFileURL.path
        process.currentDirectoryURL = bundledJar ? resources : root
        // Mirrors scripts/lib_artifact.sh selftest_bundle; change both together.
        // F_FULLFSYNC for durable commits goes through JDK 17's foreign-function
        // module (engine FullFsync.java); the CDS archive is recorded with it too.
        var arguments = ["--add-modules=jdk.incubator.foreign", "--enable-native-access=ALL-UNNAMED",
                         "-XX:TieredStopAtLevel=1", "-Xms16m", "-Xmx192m", "-XX:MaxDirectMemorySize=64m", "-XX:+UseSerialGC", "-XX:+ExitOnOutOfMemoryError",
                         "-XX:ErrorFile=\(temporary.path)/hs_err_pid%p.log"]
        if let archivePath = bundledCDSArchivePath {
            let archive = URL(fileURLWithPath: archivePath)
            let javaURL = URL(fileURLWithPath: java)
            let verified = await Task.detached(priority: .utility) {
                CDSArchivePolicy.validatedArchive(archive: archive, jar: jarURL, java: javaURL)
            }.value
            if let verified { arguments.append("-XX:SharedArchiveFile=\(verified.path)") }
        }
        // Follow the Mac's proxy settings (System Settings ▸ Network ▸ Proxies),
        // as Android traffic follows a VPN; workers inherit it (N1).
        arguments += ["-Djava.net.useSystemProxies=true",
                      "-Dcs.cloudstream.home=\(root.path)", "-Djava.io.tmpdir=\(temporary.path)", "-jar", bundledJar ? "tools/daemon.jar" : jar,
                      // The OS picks a free port; the engine reports it on stdout (audit M1).
                      "0"]
        process.arguments = arguments
        let input = Pipe()
        process.standardInput = input
        // Appended, never overwritten: each launch is delimited by markers.
        let logID = UUID()
        let ownedHandles = EngineOutputLog.open(in: Self.logDirectory(), launchID: logID, safeMode: activeSafeMode)
        // stdout is read by the app (port announcement) and still teed into its log.
        let announcement = EnginePortAnnouncement(log: ownedHandles.count == 2 ? ownedHandles[0] : nil)
        process.standardOutput = announcement.pipe
        process.standardError = ownedHandles.count == 2 ? ownedHandles[1] : FileHandle.nullDevice
        return EngineLaunchConfiguration(process: process, endpoint: .init(port: 0, token: token),
            announcement: announcement, verifiesSocketOwner: true, stdin: input,
            inputLine: Data((token + "\n").utf8) + DaemonLaunchOptions(policy: policy, safeMode: activeSafeMode).encodedLine(),
            outputHandles: ownedHandles, safeMode: activeSafeMode, policySafeMode: policy.safeModeOnly, logID: logID)
    }

    /// The engine's complete environment. `HOME` is the user's real home (the
    /// engine's data root is passed explicitly); `TMPDIR` is its private
    /// temporary folder; `LANG` is kept only when it is a plain locale name.
    nonisolated static func engineEnvironment(temporary: URL,
                                              inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        let lang = inherited["LANG"].flatMap { value in
            value.range(of: #"^[A-Za-z]{2,3}(_[A-Za-z]{2})?(\.[A-Za-z0-9-]+)?$"#, options: .regularExpression) != nil ? value : nil
        } ?? "en_US.UTF-8"
        return [
            "HOME": NSHomeDirectory(),
            "TMPDIR": temporary.path + "/",
            "PATH": "/usr/bin:/bin",
            "LANG": lang,
        ]
    }

    // MARK: - Bundle layout

    private var bundledJavaPath: String? {
        // Universal layout: Contents/Resources/runtime-<arch>/bin/java, with
        // plain "runtime" as the single-arch fallback (ADR-0005).
        let arch = Self.hostArchitecture
        for candidate in ["runtime-\(arch)", "runtime"] {
            if let path = Bundle.main.path(forResource: "java", ofType: nil, inDirectory: "\(candidate)/bin") {
                return path
            }
        }
        // Development fallback: system JDK 17+.
        return ProcessInfo.processInfo.environment["CS_DAEMON_JAVA"]
    }

    private var bundledDaemonJarPath: String? {
        if let path = Bundle.main.path(forResource: "daemon", ofType: "jar", inDirectory: "tools") {
            return path
        }
        // Development fallback: the Gradle fat-jar output.
        let dev = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // App/
            .deletingLastPathComponent() // Sources/
            .deletingLastPathComponent() // client/
            .deletingLastPathComponent() // repo root
        return dev.appendingPathComponent("engine/build/libs/daemon.jar").path
    }

    private var bundledCDSArchivePath: String? {
        Bundle.main.path(forResource: "daemon", ofType: "jsa", inDirectory: "tools")
    }

    nonisolated static var hostArchitecture: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let bytes = mirror.children.compactMap { $0.value as? UInt8 }.filter { $0 != 0 }
        return String(bytes: bytes, encoding: .utf8) ?? "arm64"
    }

    nonisolated static func logDirectory() -> URL {
        if let isolated = AppEnvironment.directory("Logs") { return isolated }
        let caches = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("Logs/CloudStreamMac", isDirectory: true)
    }
}

/// Structured client-side log (SEC-03: local only). One JSON object per
/// line — properly escaped — to the unified log and to a rotating file in
/// ~/Library/Logs/CloudStreamMac/client.log (Settings ▸ Diagnostics).
enum DaemonLog {
    static func client(_ event: String, fields: [String: String] = [:]) {
        let line = ClientLogFile.line(event: event, fields: fields)
        NSLog("%@", line)
        ClientLogFile.shared.append(line)
    }
}

/// Size-rotated client log file (2 × 2 MB). Writes happen on a private
/// serial queue; logging never blocks or throws into callers.
final class ClientLogFile: @unchecked Sendable {
    static let shared = ClientLogFile(directory: DaemonSupervisor.logDirectory())
    static let maxBytes: UInt64 = 2 * 1024 * 1024

    let url: URL
    private let queue = DispatchQueue(label: "com.lagradost.cloudstream.client-log", qos: .utility)

    init(directory: URL) {
        url = directory.appendingPathComponent("client.log")
    }

    static func line(event: String, fields: [String: String], date: Date = Date()) -> String {
        var object: [String: String] = fields
        object["event"] = event
        object["ts"] = date.formatted(.iso8601)
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"event\":\"log.encode_failed\"}"
        }
        return text
    }

    func append(_ line: String) {
        let url = url
        queue.async {
            let manager = FileManager.default
            try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? UInt64, size >= Self.maxBytes {
                let rotated = url.appendingPathExtension("1")
                try? manager.removeItem(at: rotated)
                try? manager.moveItem(at: url, to: rotated)
            }
            guard let data = (line + "\n").data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// Waits for queued writes (tests, log export).
    func flush() {
        queue.sync {}
    }
}
