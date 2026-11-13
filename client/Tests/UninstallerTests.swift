import XCTest
@testable import CloudStream

/// Delete CloudStream (ADR-0023): what is listed, what is never touched, and
/// the post-quit helper's behaviour. Everything runs in a temporary home.
final class UninstallerTests: XCTestCase {
    private let bundleID = "com.lagradost.CloudStreamMac"
    private var root: URL!
    private var home: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("uninstall-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("Users/person", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func make(_ relative: String, directory: Bool = false) throws -> URL {
        let url = home.appendingPathComponent(relative, isDirectory: directory)
        if directory {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        return url
    }

    private func relativePaths(_ footprint: UninstallFootprint) -> Set<String> {
        let prefix = home.standardizedFileURL.path + "/"
        return Set(footprint.items.map { String($0.url.standardizedFileURL.path.dropFirst(prefix.count)) })
    }

    // MARK: Footprint

    func testListsEveryExistingLocationAndNothingElse() throws {
        try make(".cloudstream-macos/state/extensions.json")
        try make("Library/Application Support/CloudStream/Backups/auto.daily.json")
        try make("Library/Application Support/CloudStreamMac.store")
        try make("Library/Application Support/CloudStreamMac.store-wal")
        try make("Library/Application Support/CloudStreamMac-Profile-040D57E3-6E57-4520-8F6D-FB61BD99E841.store")
        try make("Library/Application Support/.CloudStreamMac_SUPPORT", directory: true)
        try make("Library/Caches/CloudStreamMac/images/a.jpg")
        try make("Library/Caches/\(bundleID)/Cache.db")
        try make("Library/HTTPStorages/\(bundleID)", directory: true)
        try make("Library/WebKit/\(bundleID)", directory: true)
        try make("Library/Logs/CloudStreamMac/client.log")
        try make("Library/Preferences/\(bundleID).plist")
        // Other apps' data beside ours stays.
        try make("Library/Application Support/OtherApp/data")
        try make("Library/Application Support/CloudStreamMacOther.store")
        try make("Library/Preferences/com.example.other.plist")
        try make("Library/Caches/com.lagradost.cloudstream.other/x")

        let footprint = UninstallFootprint.scan(home: home, bundleIdentifier: bundleID)
        XCTAssertEqual(relativePaths(footprint), [
            ".cloudstream-macos",
            "Library/Application Support/CloudStream",
            "Library/Application Support/CloudStreamMac.store",
            "Library/Application Support/CloudStreamMac.store-wal",
            "Library/Application Support/CloudStreamMac-Profile-040D57E3-6E57-4520-8F6D-FB61BD99E841.store",
            "Library/Application Support/.CloudStreamMac_SUPPORT",
            "Library/Caches/CloudStreamMac",
            "Library/Caches/\(bundleID)",
            "Library/HTTPStorages/\(bundleID)",
            "Library/WebKit/\(bundleID)",
            "Library/Logs/CloudStreamMac",
            "Library/Preferences/\(bundleID).plist",
        ])
        XCTAssertFalse(footprint.items(in: .library).isEmpty)
        XCTAssertTrue(footprint.items(in: .downloads).isEmpty, "Downloads are only listed when asked for")
    }

    func testEmptyHomeListsNothing() {
        XCTAssertTrue(UninstallFootprint.scan(home: home, bundleIdentifier: bundleID).items.isEmpty)
    }

    func testStoreNamesAreMatchedExactly() {
        for name in ["CloudStreamMac.store", "CloudStreamMac.store-shm", "CloudStreamMac.store-wal", ".CloudStreamMac_SUPPORT",
                     "CloudStreamMac-Profile-040D57E3-6E57-4520-8F6D-FB61BD99E841.store-wal"] {
            XCTAssertTrue(UninstallFootprint.isLibraryStoreName(name), name)
        }
        for name in ["CloudStreamMac", "CloudStreamMac.store.bak", "CloudStreamMac-Profile-nope.store", "MyCloudStreamMac.store",
                     "CloudStreamMac.store/../x", "default.store"] {
            XCTAssertFalse(UninstallFootprint.isLibraryStoreName(name), name)
        }
    }

    func testRecoveryFolderIsListedOnlyWhenItHoldsOnlySnapshots() throws {
        let snapshot = "Library/Application Support/IdentityRecovery/\(UUID().uuidString)"
        try make(snapshot + "/manifest.json")
        try make(snapshot + "/recovery.store")
        XCTAssertTrue(relativePaths(UninstallFootprint.scan(home: home, bundleIdentifier: bundleID))
            .contains("Library/Application Support/IdentityRecovery"))

        try make("Library/Application Support/IdentityRecovery/someone-elses-file.txt")
        XCTAssertFalse(relativePaths(UninstallFootprint.scan(home: home, bundleIdentifier: bundleID))
            .contains("Library/Application Support/IdentityRecovery"), "A folder with foreign content is never deleted")
    }

    func testProtectedAndSystemPathsAreNeverDeleted() {
        let unsafe = ["", "Library", "Library/Application Support", "Library/Caches", "Library/Preferences",
                      "Movies", "Downloads", "Documents", "Desktop", "Pictures", ".Trash"]
        for relative in unsafe {
            let url = relative.isEmpty ? home! : home.appendingPathComponent(relative)
            XCTAssertFalse(UninstallFootprint.isSafeToDelete(url, home: home), relative)
        }
        for path in ["/", "/Applications", "/System", "/Library", "/usr", "/Users", "/Volumes", "/Volumes/Drive"] {
            XCTAssertFalse(UninstallFootprint.isSafeToDelete(URL(fileURLWithPath: path), home: home), path)
        }
        XCTAssertFalse(UninstallFootprint.isSafeToDelete(URL(fileURLWithPath: home.path + "/Library/../Movies"), home: home))
        XCTAssertFalse(UninstallFootprint.isSafeToDelete(URL(string: "https://example.com/a")!, home: home))
        XCTAssertFalse(UninstallFootprint.isSafeToDelete(URL(fileURLWithPath: "/Users/Shared/CloudStream/a.mp4"), home: home))

        XCTAssertTrue(UninstallFootprint.isSafeToDelete(home.appendingPathComponent(".cloudstream-macos"), home: home))
        XCTAssertTrue(UninstallFootprint.isSafeToDelete(home.appendingPathComponent("Movies/Show/E01.mp4"), home: home))
        XCTAssertTrue(UninstallFootprint.isSafeToDelete(URL(fileURLWithPath: "/Volumes/Drive/Movies/E01.mp4"), home: home))
    }

    // MARK: Downloads

    func testDownloadsListOnlyRecordedFilesAndTheirCompanions() throws {
        let video = try make("Movies/Show/Show S01E01.mp4")
        try make("Movies/Show/Show S01E01.en.srt")
        try make("Movies/Show/Show S01E02.mp4.part")
        try make("Movies/Show/Show S01E02.mp4.part.json")
        try make("Movies/Show/Unrelated Home Video.mov")
        try make("Movies/Show/Show S01E01.mp4.folder", directory: true)
        let unfinished = home.appendingPathComponent("Movies/Show/Show S01E02.mp4")
        let missing = home.appendingPathComponent("Movies/Gone.mp4")

        let files = DownloadedFiles.files(for: [video, unfinished, missing])
        let footprint = UninstallFootprint.scan(home: home, bundleIdentifier: bundleID, downloadedFiles: files)
        XCTAssertEqual(relativePaths(footprint), [
            "Movies/Show/Show S01E01.mp4",
            "Movies/Show/Show S01E01.en.srt",
            "Movies/Show/Show S01E02.mp4.part",
            "Movies/Show/Show S01E02.mp4.part.json",
        ])
        XCTAssertEqual(footprint.items(in: .downloads).count, 4)
    }

    func testSizesAreMeasuredPerCategory() throws {
        let file = try make("Library/Logs/CloudStreamMac/client.log")
        try Data(repeating: 1, count: 64 * 1024).write(to: file)
        let sizes = UninstallFootprint.scan(home: home, bundleIdentifier: bundleID).measuredSizes()
        XCTAssertGreaterThanOrEqual(sizes[.logs] ?? 0, 64 * 1024)
        XCTAssertNil(sizes[.library])
    }

    // MARK: App location

    func testAppLocationDecidesWhetherTheBundleIsTrashed() throws {
        let app = try make("Applications/CloudStream.app", directory: true)
        XCTAssertEqual(InstalledAppLocation.evaluate(app).disposal, .trash)

        let translocated = URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/CloudStream.app")
        guard case .manual = InstalledAppLocation.evaluate(translocated).disposal else { return XCTFail("Translocated copy must not be trashed") }
        let binary = try make("bin/CloudStream")
        guard case .manual = InstalledAppLocation.evaluate(binary).disposal else { return XCTFail("Only an .app bundle is trashed") }
    }

    // MARK: Helper script

    private func runScript(pid: Int32, domain: String? = nil, paths: [URL]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = UninstallScript.arguments(pid: pid, preferenceDomain: domain, paths: paths)
        process.currentDirectoryURL = home
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func exitedPID() throws -> Int32 {
        let done = Process()
        done.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try done.run()
        done.waitUntilExit()
        return done.processIdentifier
    }

    func testScriptRemovesListedPathsButNotWhatLinksPointTo() throws {
        let folder = try make(".cloudstream-macos/state", directory: true)
        try make(".cloudstream-macos/state/a.json")
        let file = try make("Library/Logs/CloudStreamMac/client.log")
        let outside = try make("Documents/Keep/precious.txt")
        let link = home.appendingPathComponent("Library/Caches/CloudStreamMac")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside.deletingLastPathComponent())

        let status = try runScript(pid: exitedPID(), paths: [folder.deletingLastPathComponent(), file, link])
        XCTAssertEqual(status, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path), "The link itself is removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path), "A link's target is never followed")
    }

    func testScriptTreatsPathsAsDataNotShellCode() throws {
        let marker = home.appendingPathComponent("pwned")
        // The script runs in `home`, so a command that ran would create `pwned` there.
        let sibling = try make("Library/Logs/CloudStreamMac/keep.log")
        let hostile = try make("Library/Logs/CloudStreamMac/a $(touch pwned) `touch pwned`; b \"q\" 'q' * .log")
        XCTAssertEqual(try runScript(pid: exitedPID(), paths: [hostile]), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: hostile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path), "A * in a name is not expanded")
    }

    func testScriptWaitsForTheAppToExit() throws {
        let file = try make(".cloudstream-macos/daemon.lock")
        let app = Process()
        app.executableURL = URL(fileURLWithPath: "/bin/sleep")
        app.arguments = ["1.5"]
        try app.run()

        let helper = try UninstallScript.launch(pid: app.processIdentifier, preferenceDomain: nil, paths: [file])
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "Nothing is removed while the app runs")
        app.waitUntilExit()
        helper.waitUntilExit()
        XCTAssertEqual(helper.terminationStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testScriptDeletesThePreferenceDomain() throws {
        // A file-path domain, so the test leaves nothing in ~/Library/Preferences.
        let domain = root.appendingPathComponent("uninstall-preferences").path
        func defaults(_ arguments: [String]) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
        XCTAssertEqual(try defaults(["write", domain, "probe", "-string", "1"]), 0)
        defer { _ = try? defaults(["delete", domain]) }
        XCTAssertEqual(try runScript(pid: exitedPID(), domain: domain, paths: []), 0)
        XCTAssertNotEqual(try defaults(["read", domain, "probe"]), 0, "The preference domain is gone")
    }
}
