import CryptoKit
import Darwin
import Foundation

/// Dedicated URL sessions for the loopback engine (audit A1, M3). Engine
/// traffic never shares `URLSession.shared`: that session's disk cache kept
/// engine responses (links, per-link headers, keys, viewing history) and the
/// bearer-token request headers in `Cache.db`, and its small per-host pool
/// let long polls starve health checks into false engine restarts.
enum EngineTransport {
    /// Application traffic: long polls, NDJSON streams and ordinary requests.
    static let ipcSession = URLSession(configuration: configuration(maximumConnections: 24, timeout: nil))

    /// Health probes only, so they never queue behind application traffic.
    static let healthSession = URLSession(configuration: configuration(maximumConnections: 2, timeout: 5))

    static func configuration(maximumConnections: Int, timeout: TimeInterval?) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = maximumConnections
        // Loopback never goes through a proxy or PAC file.
        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: false,
            kCFNetworkProxiesHTTPSEnable as String: false,
            kCFNetworkProxiesProxyAutoConfigEnable as String: false,
            kCFNetworkProxiesProxyAutoDiscoveryEnable as String: false,
            kCFNetworkProxiesSOCKSEnable as String: false,
        ]
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.waitsForConnectivity = false
        if let timeout {
            configuration.timeoutIntervalForRequest = timeout
            configuration.timeoutIntervalForResource = timeout
        }
        return configuration
    }

    private static let purgeMarker = "engineHTTPCachePurged-v1"

    /// One-time removal of engine responses earlier builds left in the app's
    /// shared HTTP cache (audit M3). The app keeps no other data there that a
    /// purge could lose; it is only a cache. Returns whether it purged now.
    @discardableResult
    static func purgeLegacyResponseCache(defaults: UserDefaults = AppEnvironment.defaults,
                                         cache: URLCache = .shared) -> Bool {
        guard !defaults.bool(forKey: purgeMarker) else { return false }
        cache.removeAllCachedResponses()
        defaults.set(true, forKey: purgeMarker)
        return true
    }
}

/// How the app authenticates its engine before trusting it (audit M1). The
/// engine binds port 0 and announces the port on its own stdout pipe; each
/// health probe sends a fresh nonce and accepts the listener only if it
/// answers `HMAC-SHA256(token, "cloudstream-health-v1:" + nonce)`. The token
/// itself is never sent to /health, so a process squatting on the port learns
/// nothing and cannot pass.
enum EngineHealthProbe {
    static let nonceHeader = "X-CloudStream-Nonce"

    enum Outcome: Sendable {
        case healthy(HealthDto)
        /// Something answered, but not our engine (no or wrong proof).
        case impostor
        case unavailable

        var isHealthy: Bool { if case .healthy = self { true } else { false } }
    }

    static func makeNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            // SystemRandomNumberGenerator is also cryptographically secure on Darwin.
            var generator = SystemRandomNumberGenerator()
            bytes = bytes.map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func proof(token: String, nonce: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data("cloudstream-health-v1:\(nonce)".utf8),
                                                  using: SymmetricKey(data: Data(token.utf8)))
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    /// Constant time over equal-length hex strings.
    static func matches(_ received: String?, expected: String) -> Bool {
        guard let received, received.utf8.count == expected.utf8.count else { return false }
        return zip(received.utf8, expected.utf8).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    static func probe(port: Int, token: String, session: URLSession = EngineTransport.healthSession,
                      nonce: String = makeNonce()) async -> Outcome {
        guard (1...65_535).contains(port), let url = URL(string: "http://127.0.0.1:\(port)/health") else { return .unavailable }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 5
        request.setValue(nonce, forHTTPHeaderField: nonceHeader)
        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let health = try? JSONDecoder().decode(HealthDto.self, from: data) else { return .impostor }
            guard matches(health.proof, expected: proof(token: token, nonce: nonce)) else { return .impostor }
            guard health.ipcVersion == HealthDto.expectedIpcVersion, health.status == "ok" else { return .unavailable }
            return .healthy(health)
        } catch {
            return .unavailable
        }
    }
}

/// Confirms a TCP listener belongs to a given process (audit M1, optional
/// check): the engine is our child, so the port it announced must be one of
/// its own listening sockets.
enum EngineSocketOwnership {
    static func process(_ pid: Int32, listensOn port: Int) -> Bool {
        guard pid > 0, (1...65_535).contains(port) else { return false }
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return false }
        let stride = MemoryLayout<proc_fdinfo>.stride
        // Room for descriptors opened between the two calls.
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 16)
        let filled = descriptors.withUnsafeMutableBytes { buffer in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard filled > 0 else { return false }
        for descriptor in descriptors.prefix(Int(filled) / stride) where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            let localPort = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)))
            if localPort == port, tcp.tcpsi_state == TSI_S_LISTEN { return true }
        }
        return false
    }
}

/// Reads the engine's stdout pipe: every line is appended to the engine's
/// stdout log, and the first `CLOUDSTREAM-ENGINE-LISTENING {"port":…}` line
/// supplies the port it bound (audit M1). Nothing else can write to this pipe.
final class EnginePortAnnouncement: @unchecked Sendable {
    static let prefix = "CLOUDSTREAM-ENGINE-LISTENING "
    /// Bounds a line without a newline, so a misbehaving engine cannot grow memory.
    static let maxLineBytes = 64 * 1024

    let pipe = Pipe()
    private let log: FileHandle?
    private let lock = NSLock()
    private var port: Int?
    private var finished = false
    private var waiters: [UUID: CheckedContinuation<Int?, Never>] = [:]
    private var buffer = Data()

    init(log: FileHandle?) {
        self.log = log
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                self.finish()
            } else {
                self.consume(chunk)
            }
        }
    }

    /// Parses one stdout line; nil when it is not an announcement.
    static func announcedPort(in line: String) -> Int? {
        guard line.hasPrefix(prefix),
              let object = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(prefix.count).utf8)) as? [String: Any],
              let port = object["port"] as? Int, (1...65_535).contains(port) else { return nil }
        return port
    }

    private func consume(_ chunk: Data) {
        if let log { try? log.write(contentsOf: chunk) }
        lock.lock()
        buffer.append(chunk)
        var announced: Int?
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...newline)
            if port == nil, let value = Self.announcedPort(in: line) {
                port = value
                announced = value
            }
        }
        if buffer.count > Self.maxLineBytes { buffer.removeAll(keepingCapacity: false) }
        let resumed = announced == nil ? [] : Array(waiters.values)
        if announced != nil { waiters.removeAll() }
        lock.unlock()
        resumed.forEach { $0.resume(returning: announced) }
    }

    private func finish() {
        lock.lock()
        finished = true
        let resumed = Array(waiters.values)
        waiters.removeAll()
        let value = port
        lock.unlock()
        resumed.forEach { $0.resume(returning: value) }
    }

    /// The announced port; nil once stdout closes without one, [timeout]
    /// passes or the caller is cancelled. Each wait is resumed exactly once:
    /// whichever of announcement, end of output, expiry or cancellation first
    /// removes it under the lock.
    func port(timeout: TimeInterval) async -> Int? {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Int?, Never>) in
                lock.lock()
                if let port {
                    lock.unlock()
                    continuation.resume(returning: port)
                    return
                }
                if finished || Task.isCancelled {
                    lock.unlock()
                    continuation.resume(returning: nil)
                    return
                }
                waiters[id] = continuation
                lock.unlock()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self] in self?.expire(id) }
            }
        } onCancel: {
            expire(id)
        }
    }

    private func expire(_ id: UUID) {
        lock.lock()
        let continuation = waiters.removeValue(forKey: id)
        lock.unlock()
        continuation?.resume(returning: nil)
    }

    /// Stops reading; called when the launch is released.
    func close() {
        pipe.fileHandleForReading.readabilityHandler = nil
        try? pipe.fileHandleForReading.close()
        finish()
    }
}
