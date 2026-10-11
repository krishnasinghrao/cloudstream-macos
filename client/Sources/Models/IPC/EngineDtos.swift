// IPC JSON values mirrored by the engine (ipc-api.md, contract v6).

struct IsolationHealthDto: Codable, Sendable, Hashable {
    /// `worker` (one sandboxed process per extension) or `in-process`.
    let mode: String
    let sandboxed: Bool
    var runningWorkers: Int = 0

    /// Why extension code is not confined, or nil when it is.
    var warning: String? {
        if mode != "worker" { return "Extensions run inside the engine process." }
        return sandboxed ? nil : "The macOS sandbox is not available on this Mac."
    }
}

struct HealthDto: Codable, Sendable {
    let status: String
    let version: String
    let ipcVersion: Int
    let uptimeMs: Int
    let providersLoaded: Int
    var recoveryError: String? = nil
    /// Background extension restore (the daemon serves requests before it finishes).
    var extensions: ExtensionHealthDto? = nil
    var safeMode: Bool? = nil
    var policyManaged: Bool? = nil
    /// How extension code is hosted (ADR-0016).
    var isolation: IsolationHealthDto? = nil
    /// HMAC of the launch token over the probe's nonce (audit M1).
    var proof: String? = nil

    /// The IPC contract this client build speaks.
    static let expectedIpcVersion = 6
}

struct ExtensionHealthDto: Codable, Sendable, Hashable {
    let phase: String
    let restored: Int
    let failed: Int
    let quarantined: Int
}

struct OperationFailureDto: Codable, Sendable {
    let code: String
    let stage: String
    let requestId: String
    let publicMessage: String
    let retryable: Bool
    let installationId: String?
    let providerId: String?
    let redactedCause: String?
    let remoteStatus: Int?
    let elapsedMs: Int
}

struct ErrorResponseDto: Codable, Sendable {
    let error: String
    let detail: String?
    var failure: OperationFailureDto? = nil
}

/// Typed daemon error (IPC v4): `code` is stable, `error` is user-presentable.
struct ExtensionErrorDto: Codable, Sendable {
    let error: String
    let code: String
    let detail: String?
}

struct AppLockRequestDto: Codable, Sendable {
    let locked: Bool
}

struct AppLockResponseDto: Codable, Sendable {
    let locked: Bool
}
