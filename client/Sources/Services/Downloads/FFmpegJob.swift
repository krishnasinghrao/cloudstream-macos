import Foundation

/// One ffmpeg remux run (HLS/DASH → MP4/MKV), wrapped as a single awaitable
/// unit of work.
///
/// Ownership is per *instance*: the queue holds the job it started, and a
/// late termination of an old job can never touch a newer attempt (the old
/// design keyed everything by item ID, so a cancel → quick retry let the
/// dying process unregister and fail over the new one).
///
/// Thread-safety: `@unchecked Sendable`; mutable state is guarded by `lock`,
/// pipe callbacks run on Foundation's handler threads.
final class FFmpegJob: @unchecked Sendable {
    struct Outcome: Sendable {
        var exitStatus: Int32
        var stderrTail: String
        var inputDurationSeconds: Double?
        var lastOutTimeSeconds: Double
        /// True when `terminate()` was requested (pause-to-stop, cancel,
        /// watchdog, app quit) — the exit status is then meaningless.
        var wasTerminated: Bool
        var launchError: String?
    }

    private let process = Process()
    private let lock = NSLock()
    private var launched = false
    private var terminated = false
    private var suspended = false

    private let stdoutSplitter = LineSplitter()
    private let stderrSplitter = LineSplitter()
    private let stderrTail = TailBuffer(capacity: 16_384)
    private var progressBlock: [String: String] = [:]
    private var lastOutTimeSeconds: Double = 0
    private var inputDurationSeconds: Double?

    private let onProgress: @Sendable ([String: String]) -> Void
    private let onInputDuration: @Sendable (Double) -> Void

    init(
        executableURL: URL,
        arguments: [String],
        onProgress: @escaping @Sendable ([String: String]) -> Void,
        onInputDuration: @escaping @Sendable (Double) -> Void,
    ) {
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        self.onProgress = onProgress
        self.onInputDuration = onInputDuration
    }

    var processIdentifier: Int32 { process.processIdentifier }

    /// Runs ffmpeg to completion. Task cancellation terminates the process;
    /// the call still returns only after the process has fully exited, so
    /// the caller never races a still-writing ffmpeg.
    func run(onLaunch: @escaping @Sendable (Process) -> Void) async -> Outcome {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    let data = handle.availableData
                    guard !data.isEmpty else {
                        handle.readabilityHandler = nil
                        return
                    }
                    self?.consumeStdout(data)
                }
                stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    let data = handle.availableData
                    guard !data.isEmpty else {
                        handle.readabilityHandler = nil
                        return
                    }
                    self?.consumeStderr(data)
                }

                process.terminationHandler = { [weak self] process in
                    // Drain whatever the pipes still hold *before* reading the
                    // tail: the final error lines usually arrive last.
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    if let rest = try? stdoutPipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
                        self?.consumeStdout(rest)
                    }
                    if let rest = try? stderrPipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
                        self?.consumeStderr(rest)
                    }
                    self?.consumeStderr(Data("\n".utf8)) // flush a final unterminated line
                    let outcome = self?.makeOutcome(exitStatus: process.terminationStatus, launchError: nil)
                        ?? Outcome(exitStatus: process.terminationStatus, stderrTail: "", inputDurationSeconds: nil,
                                   lastOutTimeSeconds: 0, wasTerminated: true, launchError: nil)
                    continuation.resume(returning: outcome)
                }

                lock.lock()
                if terminated {
                    lock.unlock()
                    process.terminationHandler = nil
                    continuation.resume(returning: makeOutcome(exitStatus: -1, launchError: nil))
                    return
                }
                do {
                    try process.run()
                    launched = true
                    lock.unlock()
                    onLaunch(process)
                } catch {
                    lock.unlock()
                    process.terminationHandler = nil
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(returning: makeOutcome(exitStatus: -1, launchError: error.localizedDescription))
                }
            }
        } onCancel: {
            terminate()
        }
    }

    /// SIGSTOP. Returns false when the process isn't running.
    @discardableResult
    func suspend() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard launched, !terminated, process.isRunning, !suspended else { return false }
        suspended = process.suspend()
        return suspended
    }

    /// SIGCONT.
    @discardableResult
    func resume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard launched, process.isRunning, suspended else { return false }
        suspended = !process.resume()
        return !suspended
    }

    /// Graceful stop: SIGCONT (a stopped process can't act on SIGTERM),
    /// SIGTERM, then SIGKILL after a grace period. The escalation checks the
    /// `Process` object — never a bare PID that the kernel may have reused.
    func terminate() {
        lock.lock()
        let alreadyTerminated = terminated
        terminated = true
        let shouldSignal = launched && process.isRunning
        if shouldSignal, suspended {
            _ = process.resume()
            suspended = false
        }
        lock.unlock()

        guard shouldSignal, !alreadyTerminated else { return }
        process.terminate()
        let process = self.process
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    // MARK: - Stream parsing

    private func consumeStdout(_ data: Data) {
        for line in stdoutSplitter.append(data) {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            lock.lock()
            progressBlock[key] = value
            if key == "out_time_us", let micros = Double(value), micros >= 0 {
                lastOutTimeSeconds = micros / 1_000_000
            }
            var completedBlock: [String: String]?
            if key == "progress" {
                completedBlock = progressBlock
                progressBlock = [:]
            }
            lock.unlock()
            // ffmpeg emits one key=value block per ~0.5 s ending in
            // "progress=": one main-actor hop per block, not per key.
            if let completedBlock {
                onProgress(completedBlock)
            }
        }
    }

    private func consumeStderr(_ data: Data) {
        for line in stderrSplitter.append(data) {
            stderrTail.append(line + "\n")
            lock.lock()
            let needsDuration = inputDurationSeconds == nil
            lock.unlock()
            if needsDuration, let duration = DownloadPolicy.parseInputDuration(line) {
                lock.lock()
                inputDurationSeconds = duration
                lock.unlock()
                onInputDuration(duration)
            }
        }
    }

    private func makeOutcome(exitStatus: Int32, launchError: String?) -> Outcome {
        lock.lock()
        defer { lock.unlock() }
        return Outcome(
            exitStatus: exitStatus,
            stderrTail: stderrTail.contents(),
            inputDurationSeconds: inputDurationSeconds,
            lastOutTimeSeconds: lastOutTimeSeconds,
            wasTerminated: terminated,
            launchError: launchError,
        )
    }
}

/// Byte-level line assembler: splits on `\n` *before* UTF-8 decoding, so a
/// multi-byte character split across two pipe reads is never dropped.
final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private let maxPending = 1_048_576

    func append(_ data: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        pending.append(data)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = pending[pending.startIndex..<newline]
            var line = String(decoding: lineData, as: UTF8.self)
            if line.hasSuffix("\r") { line.removeLast() }
            lines.append(line)
            pending.removeSubrange(pending.startIndex...newline)
        }
        // A newline-free flood can't grow without bound.
        if pending.count > maxPending {
            pending.removeAll(keepingCapacity: false)
        }
        return lines
    }
}

/// Bounded tail of recent text (stderr capture for failure classification).
final class TailBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
    }

    func append(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        buffer += text
        if buffer.utf8.count > capacity * 2 {
            buffer = String(buffer.suffix(capacity))
        }
    }

    func contents() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(buffer.suffix(capacity))
    }
}
