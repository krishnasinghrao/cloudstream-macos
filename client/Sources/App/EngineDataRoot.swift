import Foundation

/// The engine's private data root (matches the daemon's default). Extension
/// code runs in per-extension sandboxed worker processes that the engine
/// launches (ADR-0016); each worker may write only its own directory here.
enum EngineDataRoot {
    /// When the app runs as the unit-test host (the scheme sets
    /// `CS_IN_MEMORY_DB`), the engine gets an isolated temporary root so tests
    /// never read, migrate or write the developer's real extension state.
    static func url(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let root = AppEnvironment.root(environment: environment) {
            return root.appendingPathComponent("engine", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cloudstream-macos", isDirectory: true)
    }
}
