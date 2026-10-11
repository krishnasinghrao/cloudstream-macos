import Synchronization

/// Whether the app is asking the engine for anything. The two bridge polls
/// (anti-bot solve, web-view media) exist to serve engine work, so they run
/// at full speed while a request is in flight or just finished and back off
/// when the app is idle, instead of waking both processes forever.
enum EngineDemand {
    struct Lease: Sendable {
        fileprivate let counted: Bool
        func end() { if counted { EngineDemand.finish() } }
    }

    /// Requests that are themselves polling and say nothing about demand.
    static let passivePaths: Set<String> = ["solve/pending", "media/pending", "webview/pending", "health"]
    /// How long after the last request the bridges stay at full speed.
    static let lingering: Duration = .seconds(20)

    private static let state = Mutex<(inFlight: Int, lastEnded: ContinuousClock.Instant?)>((0, nil))

    static func begin(_ path: String) -> Lease {
        guard !passivePaths.contains(path) else { return Lease(counted: false) }
        state.withLock { $0.inFlight += 1 }
        return Lease(counted: true)
    }

    fileprivate static func finish(now: ContinuousClock.Instant = .now) {
        state.withLock { $0.inFlight = max(0, $0.inFlight - 1); $0.lastEnded = now }
    }

    static func isActive(now: ContinuousClock.Instant = .now) -> Bool {
        state.withLock { $0.inFlight > 0 || ($0.lastEnded.map { now - $0 < lingering } ?? false) }
    }

    /// The interval a bridge poll should wait before its next request.
    static func pollInterval(active: Duration, idle: Duration, now: ContinuousClock.Instant = .now) -> Duration {
        isActive(now: now) ? active : idle
    }

    /// Tests: forget earlier requests.
    static func reset() { state.withLock { $0 = (0, nil) } }
}
