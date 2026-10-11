import Foundation

/// A message shown at most once per engine generation (audit Q8): bootstrap
/// retries the legacy repository import on every pass, but a failure is
/// reported once for each engine, not on every retry.
struct OncePerGeneration: Equatable, Sendable {
    private(set) var shownGeneration: UInt64?

    /// True the first time it is asked for [generation]; false after that.
    mutating func shouldShow(generation: UInt64) -> Bool {
        guard shownGeneration != generation else { return false }
        shownGeneration = generation
        return true
    }
}
