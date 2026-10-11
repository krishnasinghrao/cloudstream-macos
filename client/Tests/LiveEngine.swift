import Foundation
import XCTest
@testable import CloudStream

/// A real engine process for end-to-end client tests: the Gradle-built
/// `engine/build/libs/daemon.jar`, launched the way the app launches it
/// (port 0, token and launch options over stdin, port read from stdout,
/// identity proven over /health). Its media relay may read loopback origins,
/// so test servers on 127.0.0.1 can stand in for CDNs.
final class LiveEngine: @unchecked Sendable {
    let client = DaemonClient()
    private(set) var port = 0
    private let token = SecurityVault.makeToken()
    private let process = Process()
    private let input = Pipe()
    private let announcement = EnginePortAnnouncement(log: nil)
    private let home: URL
    /// Engine stderr, quoted in a failure (kept outside [home], which stop() removes).
    private let stderrLog: URL

    struct Unavailable: LocalizedError {
        let reason: String
        init(reason: String) {
            self.reason = reason
            NSLog("LiveEngine unavailable: %@", reason)
        }
        var errorDescription: String? { reason }
    }

    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    static func javaPath() throws -> String {
        if let configured = ProcessInfo.processInfo.environment["CS_DAEMON_JAVA"], FileManager.default.isExecutableFile(atPath: configured) {
            return configured
        }
        let lookup = Process()
        lookup.executableURL = URL(fileURLWithPath: "/usr/libexec/java_home")
        lookup.arguments = ["-v", "17+"]
        let output = Pipe()
        lookup.standardOutput = output
        lookup.standardError = FileHandle.nullDevice
        try lookup.run()
        lookup.waitUntilExit()
        let home = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let java = home + "/bin/java"
        guard lookup.terminationStatus == 0, FileManager.default.isExecutableFile(atPath: java) else {
            throw Unavailable(reason: "A JDK 17+ is required (set CS_DAEMON_JAVA)")
        }
        return java
    }

    /// Launches the engine and returns once it has announced its port and proven its token.
    static func start() async throws -> LiveEngine {
        let jar = repositoryRoot.appendingPathComponent("engine/build/libs/daemon.jar")
        guard FileManager.default.fileExists(atPath: jar.path) else {
            throw Unavailable(reason: "Build the engine first: ./gradlew :engine:jar (\(jar.path) is missing)")
        }
        let engine = try LiveEngine(java: try javaPath(), jar: jar)
        do {
            try await engine.connect()
            return engine
        } catch {
            engine.stop()
            throw error
        }
    }

    private init(java: String, jar: URL) throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("live-engine-\(UUID().uuidString)", isDirectory: true)
        stderrLog = home.appendingPathExtension("stderr.log")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        process.executableURL = URL(fileURLWithPath: java)
        process.arguments = ["--add-modules=jdk.incubator.foreign", "--enable-native-access=ALL-UNNAMED",
                             "-Xmx192m", "-Dcs.test.relayAllowsLoopback=true", "-Dcs.cloudstream.home=\(home.path)",
                             "-Djava.io.tmpdir=\(home.path)", "-cp", jar.path, "com.lagradost.macos.MainKt", "0"]
        process.environment = DaemonSupervisor.engineEnvironment(temporary: home)
        process.standardInput = input
        process.standardOutput = announcement.pipe
        FileManager.default.createFile(atPath: stderrLog.path, contents: nil)
        process.standardError = try FileHandle(forWritingTo: stderrLog)
        try process.run()
        // The token, then the launch options; stdin then stays open (EOF stops the engine).
        try input.fileHandleForWriting.write(contentsOf: Data((token + "\n").utf8)
            + Data(#"{"policy":{"requireSandbox":false},"safeMode":true,"isolation":"in-process"}"#.utf8) + Data("\n".utf8))
    }

    private func connect() async throws {
        guard let announced = await announcement.port(timeout: 60) else {
            // A JVM that is alive but silent: its thread dump (SIGQUIT goes to stderr) says where it is stuck.
            if process.isRunning {
                kill(process.processIdentifier, SIGQUIT)
                try? await Task.sleep(for: .seconds(2))
            }
            let log = (try? String(contentsOf: home.appendingPathComponent("logs/daemon.log"), encoding: .utf8)).map { String($0.suffix(4_000)) } ?? "none"
            throw Unavailable(reason: "The engine did not announce its port (running: \(process.isRunning); daemon.log: \(log); stderr: \(stderrTail()))")
        }
        guard EngineSocketOwnership.process(process.processIdentifier, listensOn: announced) else {
            throw Unavailable(reason: "The announced port is not the engine's")
        }
        guard case .healthy = await EngineHealthProbe.probe(port: announced, token: token) else {
            throw Unavailable(reason: "The engine did not prove its identity")
        }
        port = announced
        await client.updateEndpoint(.init(port: announced, token: token))
    }

    private func stderrTail() -> String {
        let text = (try? String(contentsOf: stderrLog, encoding: .utf8)) ?? ""
        return text.isEmpty ? "empty" : String(text.suffix(12_000))
    }

    func stop() {
        if process.isRunning { process.terminate() }
        try? input.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        announcement.close()
        try? FileManager.default.removeItem(at: home)
        try? FileManager.default.removeItem(at: stderrLog)
    }
}
