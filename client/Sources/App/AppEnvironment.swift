import Foundation

/// One process-wide isolation boundary for test hosts and explicitly isolated
/// UI/smoke launches. Production locations and preferences remain unchanged.
enum AppEnvironment {
    private static let processID = UUID().uuidString

    static func isIsolated(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["CS_IN_MEMORY_DB"] == "1" || environment["XCTestConfigurationFilePath"] != nil
    }

    static var isUnitTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    static func root(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        guard isIsolated(environment) else { return nil }
        let root: URL
        if let path = environment["CS_TEST_ROOT"], path.hasPrefix("/"), path != "/" {
            root = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("cloudstream-tests-\(processID)", isDirectory: true)
        }
        // Fail closed: an unusable fixture root must never fall back to user data.
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch {
            preconditionFailure("Cannot create isolated application root: \(error.localizedDescription)")
        }
        return root
    }

    static func directory(_ component: String) -> URL? {
        root()?.appendingPathComponent(component, isDirectory: true)
    }

    /// A crash-fixture child process (debug builds only) keeps its stores on
    /// disk under its private root, so a second process can reopen exactly
    /// what the killed one left. Every other isolated run stays in memory.
    static var crashFixtureStoreDirectory: URL? {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        guard environment["CS_DOWNLOAD_PROCESS_PHASE"] != nil, isIsolated(environment), !isUnitTestHost,
              let path = environment["CS_TEST_ROOT"], path.hasPrefix("/"), path != "/" else { return nil }
        return directory("Stores")
        #else
        return nil
        #endif
    }

    static var defaults: UserDefaults {
        guard isIsolated(), let root = root() else { return .standard }
        // Different processes never share preferences, even when a runner
        // deliberately shares a file root for crash/relaunch fixtures. The
        // suite is a file in the isolated root, so nothing is left behind in
        // ~/Library/Preferences.
        return fileDefaults(at: root.appendingPathComponent("Preferences-\(processID)"))
    }

    /// A preference suite kept in one plist file (`<url>.plist`): CFPreferences
    /// treats an absolute path as a file domain, so it never reaches
    /// ~/Library/Preferences or the app's own domain.
    static func fileDefaults(at url: URL) -> UserDefaults {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return UserDefaults(suiteName: url.standardizedFileURL.path)!
    }

    /// Tests: a named, throwaway suite in this process's temporary folder.
    /// Optional, like `UserDefaults(suiteName:)`, so call sites read the same.
    static func scratchDefaults(_ name: String) -> UserDefaults? {
        let safe = name.replacingOccurrences(of: "/", with: "_")
        return fileDefaults(at: FileManager.default.temporaryDirectory
            .appendingPathComponent("cloudstream-defaults-\(processID)", isDirectory: true)
            .appendingPathComponent(safe.isEmpty ? "unnamed" : safe))
    }
}
