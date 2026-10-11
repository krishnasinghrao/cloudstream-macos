import Foundation

/// One readiness authority for client/UI/provider gates. Supervisor state is
/// process diagnostics; it cannot make an unverified client/provider usable.
struct EngineConnection: Sendable {
    struct Unavailable: LocalizedError, Sendable {
        let message: String
        var errorDescription: String? { message }
    }

    /// AsyncStream finishes when its consuming task is cancelled. Never turn
    /// that end into a successful readiness result.
    static func awaitUsable(in changes: AsyncStream<EngineConnection>) async throws {
        for await connection in changes {
            try Task.checkCancellation()
            if case .failed(let message) = connection.phase { throw Unavailable(message: message) }
            if connection.isUsable { return }
        }
        throw CancellationError()
    }
    enum Phase: Equatable, Sendable {
        case launching, verifying, restoring, usable, recovering
        case failed(String)
    }
    private(set) var generation: UInt64 = 0
    private(set) var phase: Phase = .launching
    private(set) var endpoint: DaemonEndpoint?
    private(set) var health: HealthDto?

    var isReady: Bool { phase == .restoring || phase == .usable }
    var isUsable: Bool { phase == .usable }
    var providersRestored: Bool { ["ready", "safe_mode"].contains(health?.extensions?.phase ?? "") }
    var daemonState: DaemonState {
        switch phase {
        case .launching, .verifying: return .initializing
        case .recovering: return .restarting
        case .restoring, .usable: return endpoint.map { .ready(port: $0.port) } ?? .initializing
        case .failed(let message): return .error(message)
        }
    }

    mutating func invalidate(_ state: DaemonState) {
        generation &+= 1
        endpoint = nil
        health = nil
        switch state {
        case .initializing: phase = .launching
        case .restarting: phase = .recovering
        case .error(let message): phase = .failed(message)
        case .ready: phase = .verifying
        }
    }

    mutating func beginVerification(_ endpoint: DaemonEndpoint) {
        generation &+= 1
        self.endpoint = endpoint
        health = nil
        phase = .verifying
    }

    @discardableResult
    mutating func acceptHealth(_ health: HealthDto, generation: UInt64) -> Bool {
        guard generation == self.generation, endpoint != nil else { return false }
        guard health.ipcVersion == HealthDto.expectedIpcVersion, health.status == "ok" else {
            phase = .failed("The engine's IPC contract is incompatible with this client.")
            return false
        }
        self.health = health
        if let error = health.recoveryError { phase = .failed(error); return false }
        phase = .restoring
        return true
    }

    @discardableResult
    mutating func markUsable(generation: UInt64) -> Bool {
        guard generation == self.generation, (phase == .restoring || phase == .usable), providersRestored else { return false }
        phase = .usable
        return true
    }

    mutating func fail(_ message: String, generation: UInt64) {
        guard generation == self.generation else { return }
        phase = .failed(message)
    }
}
