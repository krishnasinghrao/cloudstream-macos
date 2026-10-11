import Darwin
import Foundation

/// Recovers from an orphaned engine that still holds the data-root lock after
/// the app that started it went away (Remediation 1.4). The lock is an OS file
/// lock, so it is only ever held by a live process; the engine writes its pid
/// into `daemon.lock`. That process is stopped only when everything about it
/// says it is an engine for this exact data root that nothing owns any more:
/// same user, its parent is launchd, its command line runs the CloudStream
/// engine with `-Dcs.cloudstream.home=<root>`. A second copy of the app, or
/// any process that merely reused the pid, is never touched.
enum StaleEngineReaper {
    enum Outcome: Equatable, Sendable {
        /// An orphaned engine was stopped; the lock is free.
        case reaped(pid: Int32)
        /// Something else holds the lock (another running copy of the app).
        case heldByAnotherOwner
        /// No pid recorded, or the recorded process is gone.
        case nothingToReap
    }

    static func lockedPid(root: URL) -> Int32? {
        guard let text = try? String(contentsOf: root.appendingPathComponent("daemon.lock"), encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return nil }
        return pid
    }

    /// Whether the command line belongs to a CloudStream engine for [root].
    static func isEngineCommandLine(_ arguments: [String], root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let runsEngine = arguments.contains { $0.hasSuffix("daemon.jar") } || arguments.contains("com.lagradost.macos.MainKt")
        return runsEngine && arguments.contains("-Dcs.cloudstream.home=\(rootPath)") && !arguments.contains("--worker")
    }

    static func assess(pid: Int32, root: URL) -> Outcome {
        guard kill(pid, 0) == 0 || errno == EPERM else { return .nothingToReap }
        guard let info = bsdInfo(pid), info.pbi_uid == getuid() else { return .heldByAnotherOwner }
        guard info.pbi_ppid == 1, let arguments = arguments(of: pid), isEngineCommandLine(arguments, root: root) else {
            return .heldByAnotherOwner
        }
        return .reaped(pid: pid)
    }

    /// Stops an orphaned engine holding [root]'s lock: SIGTERM, then SIGKILL.
    static func reap(root: URL, grace: TimeInterval = 3) async -> Outcome {
        guard let pid = lockedPid(root: root) else { return .nothingToReap }
        let outcome = assess(pid: pid, root: root)
        guard case .reaped = outcome else { return outcome }
        DaemonLog.client("daemon.orphan_reaped", fields: ["pid": "\(pid)"])
        kill(pid, SIGCONT)
        kill(pid, SIGTERM)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(grace))
        while kill(pid, 0) == 0, clock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        if kill(pid, 0) == 0 {
            // Re-check identity right before escalating, in case the pid changed hands.
            guard case .reaped = assess(pid: pid, root: root) else { return .nothingToReap }
            kill(pid, SIGKILL)
            let killDeadline = clock.now.advanced(by: .seconds(grace))
            while kill(pid, 0) == 0, clock.now < killDeadline { try? await Task.sleep(for: .milliseconds(50)) }
        }
        return kill(pid, 0) == 0 ? .heldByAnotherOwner : outcome
    }

    private static func bsdInfo(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    /// argv of a same-user process via `KERN_PROCARGS2`.
    static func arguments(of pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        // Executable path, then padding NULs, then argc arguments.
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments.count == Int(argc) ? arguments : nil
    }
}
