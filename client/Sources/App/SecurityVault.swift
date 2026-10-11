import Foundation
import Security

/// SEC-02: Ephemeral bearer token generation.
///
/// The token is 32 cryptographically secure random bytes (64 hex chars),
/// generated in Swift at every app launch via `SecRandomCopyBytes`, passed to
/// the daemon over **stdin** (never argv — `ps` is world-readable), kept
/// strictly in memory, and never written to persistent disk, defaults, or
/// logs.
enum SecurityVault {
    static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return bytes.map { String(format: "%02hhx", $0) }.joined()
    }
}
