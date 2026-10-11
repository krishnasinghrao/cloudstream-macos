import Foundation

/// Monotonic recovery policy, independent of UI/process APIs and wall clocks.
struct EngineRecoveryPolicy: Sendable {
    struct Decision: Equatable, Sendable {
        let delay: TimeInterval?
        let engageSafeMode: Bool
    }
    var maximumRetries = 5
    var initialDelay: TimeInterval = 0.25
    var maximumDelay: TimeInterval = 8
    var crashWindow: TimeInterval = 60
    var safeModeThreshold = 2
    private(set) var attempts = 0
    private var recentFailures: [TimeInterval] = []

    mutating func recordFailure(at now: TimeInterval) -> Decision {
        attempts += 1
        recentFailures = recentFailures.filter { now >= $0 && now - $0 < crashWindow } + [now]
        let delay = attempts <= maximumRetries ? min(maximumDelay, initialDelay * pow(2, Double(min(attempts - 1, 30)))) : nil
        return Decision(delay: delay, engageSafeMode: recentFailures.count >= safeModeThreshold)
    }

    mutating func reset() { attempts = 0; recentFailures.removeAll() }
}

/// Prepared but not yet launched; lifetime belongs to a supervisor launch ID.
struct EngineLaunchConfiguration: Sendable {
    let process: Process
    /// For the bundled engine the port is 0 until [announcement] supplies the one it bound.
    let endpoint: DaemonEndpoint
    /// The engine's stdout pipe reader that learns its port (audit M1); nil
    /// for a launch whose endpoint is known up front (tests).
    var announcement: EnginePortAnnouncement? = nil
    /// Also require the announced port to be one of the child's own listening sockets.
    var verifiesSocketOwner = false
    var stdin: Pipe? = nil
    var inputLine: Data? = nil
    var outputHandles: [FileHandle] = []
    var safeMode = false
    var policySafeMode = false
    /// Names this launch in the engine output logs.
    var logID: UUID? = nil

    /// Marks the end of this launch in its output logs, then releases every
    /// handle. Called once the process is gone or was never started.
    func closeHandles() {
        announcement?.close()
        try? stdin?.fileHandleForWriting.close()
        try? stdin?.fileHandleForReading.close()
        if let logID {
            let status: Int32? = process.processIdentifier != 0 && !process.isRunning ? process.terminationStatus : nil
            let marker = EngineOutputLog.exitMarker(launchID: logID, status: status)
            for handle in outputHandles { try? handle.write(contentsOf: marker) }
        }
        for handle in outputHandles { try? handle.close() }
    }
}

/// The engine's stdout/stderr files. Each launch appends after a start marker
/// and ends with an exit marker, so the files read in order and one launch's
/// output cannot be mistaken for another's. Oversized files rotate once.
enum EngineOutputLog {
    static let names = ["daemon-stdout.log", "daemon-stderr.log"]
    static let maxBytes: UInt64 = 2 * 1_048_576

    static func rotatedURL(for url: URL) -> URL { url.appendingPathExtension("1") }

    static func startMarker(launchID: UUID, safeMode: Bool, now: Date = Date()) -> Data {
        Data("=== engine launch \(launchID.uuidString) started \(ISO8601DateFormatter().string(from: now)) safeMode=\(safeMode) ===\n".utf8)
    }

    static func exitMarker(launchID: UUID, status: Int32?, now: Date = Date()) -> Data {
        Data("=== engine launch \(launchID.uuidString) ended \(ISO8601DateFormatter().string(from: now)) status=\(status.map(String.init) ?? "not-started") ===\n".utf8)
    }

    /// Opens both files for appending and writes the start marker. A file
    /// over the limit becomes `<name>.1` (replacing the previous one) first.
    static func open(in directory: URL, launchID: UUID, safeMode: Bool, maxBytes: UInt64 = EngineOutputLog.maxBytes) -> [FileHandle] {
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        return names.compactMap { name in
            let url = directory.appendingPathComponent(name)
            let size = (try? manager.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
            if size > maxBytes {
                try? manager.removeItem(at: rotatedURL(for: url))
                try? manager.moveItem(at: url, to: rotatedURL(for: url))
            }
            if !manager.fileExists(atPath: url.path) { manager.createFile(atPath: url.path, contents: nil) }
            guard let handle = FileHandle(forWritingAtPath: url.path) else { return nil }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: startMarker(launchID: launchID, safeMode: safeMode))
            return handle
        }
    }
}
