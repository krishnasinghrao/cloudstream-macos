import CryptoKit
import XCTest
@testable import CloudStream

// MARK: - Versions, release feed, trust rules

final class UpdateFeedTests: XCTestCase {
    func testSemanticVersionParsingAndPrecedence() throws {
        XCTAssertEqual(SemanticVersion("v1.2.3"), SemanticVersion(major: 1, minor: 2, patch: 3))
        XCTAssertEqual(SemanticVersion("macos-v1.0.0")?.description, "1.0.0")
        XCTAssertEqual(SemanticVersion("1.0.0+build.7")?.description, "1.0.0")
        for invalid in ["", "1", "1.2", "1.2.3.4", "1.2.x", "v", "1..2", "1.2.3-", "1.2.3-be ta", "١.٢.٣"] {
            XCTAssertNil(SemanticVersion(invalid), invalid)
        }
        // semver.org §11 example ordering.
        let ordered = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2",
                       "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "1.0.1", "1.1.0", "2.0.0", "10.0.0"]
            .compactMap(SemanticVersion.init)
        XCTAssertEqual(ordered.count, 12)
        XCTAssertEqual(ordered, ordered.sorted())
        for (lower, higher) in zip(ordered, ordered.dropFirst()) { XCTAssertLessThan(lower, higher) }
        XCTAssertTrue(try XCTUnwrap(SemanticVersion("1.0.0-rc.1")).isPrerelease)
    }

    private func releaseJSON(tag: String = "v1.2.0", draft: Bool = false, prerelease: Bool = false,
                             dmgURL: String = "https://github.com/o/r/releases/download/v1.2.0/CloudStream.dmg",
                             size: Int = 90_000_000, digest: String? = "sha256:" + String(repeating: "ab", count: 32),
                             includeChecksum: Bool = true, page: String = "https://github.com/o/r/releases/tag/v1.2.0") -> Data {
        var assets: [[String: Any]] = [[
            "name": "CloudStream.dmg", "browser_download_url": dmgURL, "size": size, "state": "uploaded",
        ]]
        if let digest { assets[0]["digest"] = digest }
        if includeChecksum {
            assets.append(["name": "CloudStream.dmg.sha256", "size": 82, "state": "uploaded",
                           "browser_download_url": "https://github.com/o/r/releases/download/v1.2.0/CloudStream.dmg.sha256"])
        }
        let object: [String: Any] = ["tag_name": tag, "html_url": page, "draft": draft, "prerelease": prerelease,
                                     "published_at": "2026-11-01T10:00:00Z", "assets": assets]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    func testDecodesAReleaseWithItsDiskImageDigestAndChecksumFile() throws {
        let release = try XCTUnwrap(UpdateFeed.decode(releaseJSON()))
        XCTAssertEqual(release.version.description, "1.2.0")
        XCTAssertEqual(release.dmg.size, 90_000_000)
        XCTAssertEqual(release.dmg.sha256, String(repeating: "ab", count: 32))
        XCTAssertEqual(release.checksumAsset?.name, "CloudStream.dmg.sha256")
        XCTAssertNotNil(release.publishedAt)
    }

    func testDraftsPrereleasesAndNonSemverTagsAreNotUpdates() throws {
        XCTAssertNil(try UpdateFeed.decode(releaseJSON(draft: true)))
        XCTAssertNil(try UpdateFeed.decode(releaseJSON(prerelease: true)))
        XCTAssertNil(try UpdateFeed.decode(releaseJSON(tag: "v1.2.0-beta.1")))
        XCTAssertNil(try UpdateFeed.decode(releaseJSON(tag: "nightly")))
    }

    func testRejectsMissingOversizedOrForeignDiskImages() {
        XCTAssertThrowsError(try UpdateFeed.decode(releaseJSON(size: 0)))
        XCTAssertThrowsError(try UpdateFeed.decode(releaseJSON(size: Int(UpdateFeed.maximumDMGBytes) + 1)))
        XCTAssertThrowsError(try UpdateFeed.decode(releaseJSON(dmgURL: "https://evil.example/CloudStream.dmg"))) {
            XCTAssertEqual($0 as? UpdateFeed.FeedError, .untrustedURL("https://evil.example/CloudStream.dmg"))
        }
        XCTAssertThrowsError(try UpdateFeed.decode(releaseJSON(dmgURL: "http://github.com/o/r/CloudStream.dmg")))
        XCTAssertThrowsError(try UpdateFeed.decode(releaseJSON(page: "https://evil.example/release")))
        XCTAssertThrowsError(try UpdateFeed.decode(Data("{".utf8))) { XCTAssertEqual($0 as? UpdateFeed.FeedError, .malformed) }
        // A malformed API digest is ignored rather than trusted.
        XCTAssertNil(try UpdateFeed.decode(releaseJSON(digest: "sha256:xyz"))?.dmg.sha256)
    }

    func testOnlyGitHubHostsOverHTTPSAreTrusted() {
        XCTAssertTrue(UpdateFeed.isTrusted(URL(string: "https://api.github.com/repos/o/r/releases/latest")))
        XCTAssertTrue(UpdateFeed.isTrusted(URL(string: "https://release-assets.githubusercontent.com/x")))
        XCTAssertTrue(UpdateFeed.isTrusted(URL(string: "https://objects.githubusercontent.com/x")))
        XCTAssertFalse(UpdateFeed.isTrusted(URL(string: "http://github.com/x")))
        XCTAssertFalse(UpdateFeed.isTrusted(URL(string: "https://github.com.evil.example/x")))
        XCTAssertFalse(UpdateFeed.isTrusted(URL(string: "https://user:pass@github.com/x")))
        XCTAssertFalse(UpdateFeed.isTrusted(URL(string: "https://github.com:8443/x")))
        XCTAssertFalse(UpdateFeed.isTrusted(URL(string: "http://127.0.0.1/x")), "loopback only with an explicit test host list")
        XCTAssertTrue(UpdateFeed.isTrusted(URL(string: "http://127.0.0.1:9/x"), hosts: ["127.0.0.1"]))
        XCTAssertFalse(UpdateFeed.isTrusted(nil))
    }

    func testRepositoryComesFromInfoPlistAndIsValidated() {
        XCTAssertEqual(UpdateFeed.repository(["CSUpdateRepository": "owner/repo-name.mac"]), "owner/repo-name.mac")
        for invalid in ["owner", "owner/", "/repo", "a/b/c", "../x", "o/..", "owner/re po", "owner/repo?x=1"] {
            XCTAssertNil(UpdateFeed.repository(["CSUpdateRepository": invalid]), invalid)
        }
        XCTAssertNil(UpdateFeed.repository([:]))
        XCTAssertEqual(UpdateFeed.latestReleaseURL(repository: "o/r")?.absoluteString,
                       "https://api.github.com/repos/o/r/releases/latest")
    }

    func testChecksumFileParsing() {
        let hex = String(repeating: "0f", count: 32)
        XCTAssertEqual(UpdateFeed.checksum(fromShasumOutput: "\(hex)  CloudStream.dmg\n", for: "CloudStream.dmg"), hex)
        XCTAssertEqual(UpdateFeed.checksum(fromShasumOutput: "\(hex.uppercased()) *CloudStream.dmg", for: "CloudStream.dmg"), hex)
        XCTAssertNil(UpdateFeed.checksum(fromShasumOutput: "\(hex)  Other.dmg", for: "CloudStream.dmg"))
        XCTAssertNil(UpdateFeed.checksum(fromShasumOutput: "abc  CloudStream.dmg", for: "CloudStream.dmg"))
    }

    func testExpectedDigestRequiresAgreeingSources() throws {
        let a = String(repeating: "a", count: 64), b = String(repeating: "b", count: 64)
        XCTAssertEqual(try UpdateInstaller.expectedDigest(apiDigest: a, checksumFile: a), a)
        XCTAssertEqual(try UpdateInstaller.expectedDigest(apiDigest: a, checksumFile: nil), a)
        XCTAssertEqual(try UpdateInstaller.expectedDigest(apiDigest: nil, checksumFile: b), b)
        XCTAssertThrowsError(try UpdateInstaller.expectedDigest(apiDigest: a, checksumFile: b)) {
            XCTAssertEqual($0 as? UpdateInstaller.InstallError, .checksumMismatch)
        }
        XCTAssertThrowsError(try UpdateInstaller.expectedDigest(apiDigest: nil, checksumFile: nil)) {
            XCTAssertEqual($0 as? UpdateInstaller.InstallError, .checksumUnavailable)
        }
    }

    func testSignatureRequirementPinsTheTeamOfADeveloperIDBuild() {
        XCTAssertEqual(UpdateInstaller.requirement(bundleIdentifier: "com.x.App", teamIdentifier: nil), "identifier \"com.x.App\"")
        XCTAssertEqual(UpdateInstaller.requirement(bundleIdentifier: "com.x.App", teamIdentifier: "ABCDE12345"),
                       "identifier \"com.x.App\" and anchor apple generic and certificate leaf[subject.OU] = \"ABCDE12345\"")
    }
}

// MARK: - Install location and the swap

final class UpdateInstallLocationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cs-update-loc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
    }

    func testWritableLocationIsSupportedAndOthersFallBackToManual() throws {
        let app = root.appendingPathComponent("CloudStream.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        XCTAssertEqual(UpdateInstaller.location(of: app), .supported)

        let translocated = URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/CloudStream.app")
        guard case .manualOnly = UpdateInstaller.location(of: translocated) else { return XCTFail("translocated must be manual") }

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        guard case .manualOnly(let reason) = UpdateInstaller.location(of: app) else { return XCTFail("read-only parent must be manual") }
        XCTAssertTrue(reason.contains("permission"))
    }

    func testSwapExchangesTheAppsAndKeepsThePreviousOneAtTheStagedPath() throws {
        let installed = root.appendingPathComponent("Applications/CloudStream.app")
        let staged = root.appendingPathComponent("Staging/CloudStream.app")
        for (folder, marker) in [(installed, "old"), (staged, "new")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try marker.write(to: folder.appendingPathComponent("marker"), atomically: true, encoding: .utf8)
        }
        try UpdateInstaller.swap(staged: staged, installed: installed)
        XCTAssertEqual(try String(contentsOf: installed.appendingPathComponent("marker"), encoding: .utf8), "new")
        XCTAssertEqual(try String(contentsOf: staged.appendingPathComponent("marker"), encoding: .utf8), "old")
    }

    func testSwapFailureLeavesTheInstalledAppInPlace() throws {
        let installed = root.appendingPathComponent("CloudStream.app")
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        XCTAssertThrowsError(try UpdateInstaller.swap(staged: root.appendingPathComponent("missing/CloudStream.app"), installed: installed))
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.path))
    }
}

// MARK: - Download over HTTP (loopback stands in for GitHub)

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Double] = []
    func append(_ value: Double) { lock.withLock { recorded.append(value) } }
    var values: [Double] { lock.withLock { recorded } }
}

final class UpdateDownloadTests: XCTestCase {
    func testDownloadsWithProgressAndRejectsTheWrongSize() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cs-update-dl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let payload = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try payload.write(to: folder.appendingPathComponent("CloudStream.dmg"))
        let server = try HeaderLoggingServer(directory: folder.path)
        defer { server.stop() }

        let network = UpdateNetwork(trustedHosts: ["127.0.0.1"], version: "1.0.0")
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)/CloudStream.dmg"))
        let destination = folder.appendingPathComponent("downloaded.dmg")
        let fractions = ProgressRecorder()
        try await network.download(.init(name: "CloudStream.dmg", url: url, size: Int64(payload.count), sha256: nil),
                                   to: destination) { fractions.append($0) }
        XCTAssertEqual(try Data(contentsOf: destination), payload)
        let reported = fractions.values
        XCTAssertEqual(reported.last, 1)
        XCTAssertEqual(reported, reported.sorted(), "progress never goes backwards")

        do {
            try await network.download(.init(name: "CloudStream.dmg", url: url, size: Int64(payload.count) + 1, sha256: nil),
                                       to: destination) { _ in }
            XCTFail("a size mismatch must fail")
        } catch {
            XCTAssertEqual(error as? UpdateNetwork.NetworkError, .sizeMismatch(expected: Int64(payload.count) + 1, actual: Int64(payload.count)))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "a failed download leaves no file")

        let foreign = UpdateNetwork(trustedHosts: ["github.com"], version: "1.0.0")
        do {
            try await foreign.download(.init(name: "x", url: url, size: 1, sha256: nil), to: destination) { _ in }
            XCTFail("an untrusted host must be refused")
        } catch { XCTAssertTrue(error is UpdateFeed.FeedError) }
    }
}

// MARK: - Verifying and staging a real disk image

final class UpdatePreparationTests: XCTestCase {
    private var root: URL!
    private let identifier = "com.lagradost.cloudstream.updatetest"

    /// A tool that writes more than a pipe buffer (64 KiB) before exiting
    /// must not deadlock: its output is drained while it runs.
    func testToolOutputLargerThanThePipeBufferIsReadWithoutHanging() async throws {
        let result = try await withThrowingTaskGroup(of: (status: Int32, output: Data)?.self) { group in
            group.addTask { try await UpdateInstaller.run("/bin/sh", ["-c", "head -c 1048576 /dev/zero"]) }
            group.addTask { try await Task.sleep(for: .seconds(20)); return nil }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
        let finished = try XCTUnwrap(result, "the tool's output was not drained; it never exited")
        XCTAssertEqual(finished.status, 0)
        XCTAssertEqual(finished.output.count, 1_048_576)
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cs-update-prep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// A minimal app bundle, ad-hoc signed unless `sign` is false, packed in
    /// a disk image the way package_app.sh does. Returns the image.
    private func makeDiskImage(version: String, identifier: String? = nil, minimumSystem: String = "15.0",
                               sign: Bool = true) throws -> URL {
        let source = root.appendingPathComponent("dmg-root-\(UUID().uuidString)")
        let app = source.appendingPathComponent("CloudStream.app/Contents")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": identifier ?? self.identifier, "CFBundleShortVersionString": version,
                                   "CFBundleExecutable": "CloudStream", "CFBundlePackageType": "APPL",
                                   "LSMinimumSystemVersion": minimumSystem]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: app.appendingPathComponent("MacOS/CloudStream").path)
        if sign {
            XCTAssertEqual(try run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", identifier ?? self.identifier,
                                                         source.appendingPathComponent("CloudStream.app").path]), 0)
        } else {
            _ = try run("/usr/bin/codesign", ["--remove-signature", app.appendingPathComponent("MacOS/CloudStream").path])
        }
        let image = root.appendingPathComponent("CloudStream-\(UUID().uuidString).dmg")
        XCTAssertEqual(try run("/usr/bin/hdiutil", ["create", "-volname", "CloudStream", "-srcfolder", source.path,
                                                    "-ov", "-format", "UDZO", "-quiet", image.path]), 0)
        return image
    }

    private func run(_ tool: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func request(_ image: URL, release: String = "1.2.0", digest: String? = nil) throws -> UpdateInstaller.Request {
        let staging = root.appendingPathComponent("staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let version = try XCTUnwrap(SemanticVersion(release))
        let asset = UpdateRelease.Asset(name: "CloudStream.dmg", url: URL(string: "https://github.com/o/r/CloudStream.dmg")!, size: 1, sha256: nil)
        return .init(release: UpdateRelease(version: version, tag: "v\(release)", pageURL: URL(string: "https://github.com/o/r")!,
                                            publishedAt: nil, dmg: asset, checksumAsset: nil),
                     diskImage: image, expectedDigest: try digest ?? SHA256.hexDigest(ofFileAt: image),
                     installedApp: root.appendingPathComponent("Installed/CloudStream.app"), stagingDirectory: staging,
                     bundleIdentifier: identifier, currentVersion: SemanticVersion(major: 1, minor: 0, patch: 0), teamIdentifier: nil)
    }

    private func assertFails(_ request: UpdateInstaller.Request, with expected: UpdateInstaller.InstallError,
                             file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await UpdateInstaller.prepare(request)
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? UpdateInstaller.InstallError, expected, file: file, line: line)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: request.diskImage.path), "the image is always deleted", file: file, line: line)
        XCTAssertFalse(mountedVolumes().contains { $0.hasPrefix(request.stagingDirectory.path) }, "the image is detached", file: file, line: line)
    }

    private func mountedVolumes() -> [String] {
        (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []).map { $0.resolvingSymlinksInPath().path }
    }

    func testAVerifiedImageIsStagedAsAValidlySignedApp() async throws {
        let request = try request(try makeDiskImage(version: "1.2.0"))
        let staged = try await UpdateInstaller.prepare(request)
        XCTAssertEqual(staged, request.stagingDirectory.appendingPathComponent("CloudStream.app"))
        XCTAssertNoThrow(try UpdateInstaller.verifySignature(of: staged, requirement: "identifier \"\(identifier)\""))
        XCTAssertFalse(FileManager.default.fileExists(atPath: request.diskImage.path))
        XCTAssertFalse(mountedVolumes().contains { $0.hasPrefix(request.stagingDirectory.resolvingSymlinksInPath().path) })
    }

    func testTamperedWrongOrUnsignedImagesAreRefused() async throws {
        await assertFails(try request(try makeDiskImage(version: "1.2.0"), digest: String(repeating: "0", count: 64)), with: .checksumMismatch)
        await assertFails(try request(try makeDiskImage(version: "1.2.0", identifier: "com.other.app")), with: .wrongApp("com.other.app"))
        await assertFails(try request(try makeDiskImage(version: "1.3.0")), with: .wrongVersion(expected: "1.2.0", found: "1.3.0"))
        await assertFails(try request(try makeDiskImage(version: "1.0.0"), release: "1.0.0"), with: .notNewer("1.0.0"))
        await assertFails(try request(try makeDiskImage(version: "1.2.0", minimumSystem: "99.0")), with: .requiresNewerMacOS("99.0"))
        do {
            _ = try await UpdateInstaller.prepare(try request(try makeDiskImage(version: "1.2.0", sign: false)))
            XCTFail("an unsigned app must be refused")
        } catch {
            guard case .signature = error as? UpdateInstaller.InstallError else { return XCTFail("\(error)") }
        }
    }

    func testDeveloperIDPinningRefusesAnAdHocUpdate() async throws {
        let image = try makeDiskImage(version: "1.2.0")
        var pinned = try request(image)
        pinned = .init(release: pinned.release, diskImage: pinned.diskImage, expectedDigest: pinned.expectedDigest,
                       installedApp: pinned.installedApp, stagingDirectory: pinned.stagingDirectory,
                       bundleIdentifier: pinned.bundleIdentifier, currentVersion: pinned.currentVersion, teamIdentifier: "ABCDE12345")
        do {
            _ = try await UpdateInstaller.prepare(pinned)
            XCTFail("an ad-hoc update must not replace a Developer ID build")
        } catch {
            XCTAssertEqual(error as? UpdateInstaller.InstallError, .signature("it isn’t signed by CloudStream’s developer"))
        }
    }
}

// MARK: - The controller's states (fake environment)

@MainActor
final class SoftwareUpdaterTests: XCTestCase {
    private final class Fake {
        var latest: UpdateRelease?
        var fetchError: Error?
        var fetches = 0
        var downloadError: Error?
        var prepareError: Error?
        var downloadGates: [CheckedContinuation<Void, Never>] = []
        var holdDownload = false
        var swapError: Error?
        var location: UpdateInstaller.Location = .supported
        var swaps: [(URL, URL)] = []
        var relaunches = 0
        var terminations = 0
        var opened: [URL] = []
        var preparedRequests: [UpdateInstaller.Request] = []
        var checksumText = ""
    }

    private var defaults: UserDefaults!
    private var suite: String!
    private var staging: URL!

    override func setUp() async throws {
        // One fixed domain, emptied around every test (no per-test plist files).
        suite = "com.lagradost.cloudstream.update-tests"
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        staging = FileManager.default.temporaryDirectory.appendingPathComponent("cs-update-ctl-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: staging)
    }

    private func release(_ version: String, digest: String? = String(repeating: "c", count: 64), checksum: Bool = false) -> UpdateRelease {
        let v = SemanticVersion(version)!
        return UpdateRelease(version: v, tag: "v\(version)", pageURL: URL(string: "https://github.com/o/r/releases/tag/v\(version)")!,
                             publishedAt: nil,
                             dmg: .init(name: "CloudStream.dmg", url: URL(string: "https://github.com/o/r/CloudStream.dmg")!, size: 10, sha256: digest),
                             checksumAsset: checksum ? .init(name: "CloudStream.dmg.sha256", url: URL(string: "https://github.com/o/r/CloudStream.dmg.sha256")!, size: 80, sha256: nil) : nil)
    }

    private func makeUpdater(_ fake: Fake, enabled: Bool = true) -> SoftwareUpdater {
        let staging = staging!
        let environment = SoftwareUpdater.Environment(
            isEnabled: enabled,
            currentVersion: SemanticVersion(major: 1, minor: 0, patch: 0),
            bundleIdentifier: "com.lagradost.CloudStreamMac",
            installedApp: URL(fileURLWithPath: "/Applications/CloudStream.app"),
            defaults: defaults,
            location: { fake.location },
            fetchLatest: {
                fake.fetches += 1
                if let error = fake.fetchError { throw error }
                return fake.latest
            },
            fetchChecksumFile: { _ in fake.checksumText },
            download: { _, destination, progress in
                progress(0.5)
                if fake.holdDownload { await withCheckedContinuation { fake.downloadGates.append($0) } }
                try Task.checkCancellation()
                if let error = fake.downloadError { throw error }
                try Data([1]).write(to: destination)
                progress(1)
            },
            makeStagingDirectory: {
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                return staging
            },
            ensureSpace: { _, _ in },
            prepare: { request in
                fake.preparedRequests.append(request)
                if let error = fake.prepareError { throw error }
                return request.stagingDirectory.appendingPathComponent("CloudStream.app")
            },
            teamIdentifier: { nil },
            swap: {
                if let error = fake.swapError { throw error }
                fake.swaps.append(($0, $1))
            },
            relaunch: { _ in fake.relaunches += 1 },
            openURL: { fake.opened.append($0) },
            terminate: { fake.terminations += 1 },
            now: { Date() })
        return SoftwareUpdater(environment: environment)
    }

    private func waitFor(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "condition not reached", file: file, line: line)
    }

    func testCheckFindsANewerReleaseAndIgnoresOlderOrEqualOnes() async {
        let fake = Fake()
        let updater = makeUpdater(fake)
        fake.latest = release("1.0.0")
        updater.checkNow()
        await waitFor { updater.phase == .upToDate }
        XCTAssertNil(updater.sidebarRelease)
        XCTAssertNotNil(updater.lastCheckedAt)

        fake.latest = release("1.1.0")
        updater.checkNow()
        await waitFor { updater.phase == .available(release("1.1.0")) }
        XCTAssertEqual(updater.sidebarRelease?.version.description, "1.1.0")
    }

    func testManualCheckFailureShowsAndBackgroundFailureStaysQuiet() async {
        let fake = Fake()
        fake.fetchError = URLError(.notConnectedToInternet)
        let updater = makeUpdater(fake)
        updater.checkNow()
        await waitFor { if case .failed("You’re offline.", nil) = updater.phase { true } else { false } }
        XCTAssertNil(updater.sidebarRelease, "a failed check is not an update to show in the sidebar")
    }

    func testSkippingHidesTheVersionUntilANewerOneAndSettingsStillOffersIt() async {
        let fake = Fake()
        fake.latest = release("1.1.0")
        let updater = makeUpdater(fake)
        updater.checkNow()
        await waitFor { updater.sidebarRelease != nil }
        updater.skipThisVersion()
        XCTAssertNil(updater.sidebarRelease)
        XCTAssertEqual(updater.phase, .available(release("1.1.0")), "Settings still offers it")

        // The skip survives a relaunch.
        let relaunched = makeUpdater(fake)
        relaunched.checkNow()
        await waitFor { relaunched.phase == .available(release("1.1.0")) }
        XCTAssertNil(relaunched.sidebarRelease)

        fake.latest = release("1.2.0")
        relaunched.checkNow()
        await waitFor { relaunched.sidebarRelease?.version.description == "1.2.0" }
    }

    func testDownloadPreparesThenInstallsAtQuitAndRelaunchesOnlyAfterRestart() async throws {
        let fake = Fake()
        fake.latest = release("1.1.0")
        let updater = makeUpdater(fake)
        updater.checkNow()
        await waitFor { updater.phase == .available(release("1.1.0")) }
        updater.download()
        await waitFor { updater.phase == .ready(release("1.1.0")) }
        XCTAssertEqual(fake.preparedRequests.first?.expectedDigest, String(repeating: "c", count: 64))
        XCTAssertEqual(defaults.string(forKey: "CSUpdateStagingDirectory"), staging.path)

        // Restart, but the quit is cancelled (e.g. Keep Open): no relaunch later.
        updater.restartToUpdate()
        XCTAssertEqual(fake.terminations, 1)
        updater.terminationCancelled()
        updater.installAtTermination()
        XCTAssertEqual(fake.swaps.count, 1)
        XCTAssertEqual(fake.swaps.first?.1.path, "/Applications/CloudStream.app")
        XCTAssertEqual(fake.relaunches, 0, "an ordinary quit installs without relaunching")

        updater.restartToUpdate()
        updater.installAtTermination()
        XCTAssertEqual(fake.relaunches, 1)
    }

    func testChecksumFileMustNameTheImageAndAgreeWithTheAPIDigest() async {
        let fake = Fake()
        fake.latest = release("1.1.0", digest: String(repeating: "c", count: 64), checksum: true)
        fake.checksumText = String(repeating: "d", count: 64) + "  CloudStream.dmg\n"
        let updater = makeUpdater(fake)
        updater.checkNow()
        await waitFor { updater.sidebarRelease != nil }
        updater.download()
        await waitFor { if case .failed(_, release: .some) = updater.phase { true } else { false } }
        XCTAssertEqual(updater.phase, .failed(UpdateInstaller.InstallError.checksumMismatch.errorDescription!, release: release("1.1.0", checksum: true)))
        XCTAssertTrue(fake.preparedRequests.isEmpty, "nothing is downloaded or opened when the checksums disagree")
        XCTAssertNotNil(updater.sidebarRelease, "the failure stays visible with Retry")

        fake.checksumText = "garbage"
        updater.download()
        await waitFor { updater.phase == .failed(UpdateInstaller.InstallError.checksumUnavailable.errorDescription!, release: release("1.1.0", checksum: true)) }
    }

    func testCancellingADownloadReturnsToAvailableAndRemovesTheStagingFolder() async {
        let fake = Fake()
        fake.latest = release("1.1.0")
        fake.holdDownload = true
        let updater = makeUpdater(fake)
        updater.checkNow()
        await waitFor { updater.sidebarRelease != nil }
        updater.download()
        await waitFor { if case .downloading(_, 0.5) = updater.phase { true } else { false } }
        updater.cancelDownload()
        XCTAssertEqual(updater.phase, .available(release("1.1.0")))
        fake.downloadGates.forEach { $0.resume() }
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(updater.phase, .available(release("1.1.0")), "the cancelled task doesn't overwrite the state")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertNil(defaults.string(forKey: "CSUpdateStagingDirectory"))
    }

    func testARetryAfterCancelIsNotDisturbedByTheSupersededDownload() async {
        let fake = Fake()
        fake.latest = release("1.1.0")
        fake.holdDownload = true
        let updater = makeUpdater(fake)
        updater.checkNow()
        await waitFor { updater.sidebarRelease != nil }
        updater.download()
        await waitFor { fake.downloadGates.count == 1 }
        updater.cancelDownload()
        updater.download()
        await waitFor { fake.downloadGates.count == 2 }
        // The cancelled download finishes late: nothing about the new one changes.
        fake.downloadGates[0].resume()
        try? await Task.sleep(for: .milliseconds(100))
        guard case .downloading = updater.phase else { return XCTFail("superseded download changed the state: \(updater.phase)") }
        XCTAssertTrue(fake.preparedRequests.isEmpty)
        fake.downloadGates[1].resume()
        await waitFor { updater.phase == .ready(release("1.1.0")) }
        XCTAssertEqual(fake.preparedRequests.count, 1)
    }

    func testAFailedInstallStillRelaunchesAndIsExplainedAtTheNextLaunch() async {
        let fake = Fake()
        fake.latest = release("1.1.0")
        fake.swapError = UpdateInstaller.InstallError.swapFailed(EACCES)
        let updater = makeUpdater(fake)
        updater.checkNow()
        await waitFor { updater.sidebarRelease != nil }
        updater.download()
        await waitFor { updater.phase == .ready(release("1.1.0")) }
        updater.restartToUpdate()
        updater.installAtTermination()
        XCTAssertEqual(fake.relaunches, 1, "Restart brings CloudStream back even when the update couldn’t be installed")

        let next = makeUpdater(fake)
        next.automaticallyChecks = false
        next.start()
        XCTAssertTrue(next.lastBackgroundError?.contains("couldn’t be installed") == true, next.lastBackgroundError ?? "nil")
    }

    func testFailedPreparationOffersRetryAndNothingInstalls() async {
        let fake = Fake()
        fake.latest = release("1.1.0")
        fake.prepareError = UpdateInstaller.InstallError.signature("bad")
        let updater = makeUpdater(fake)
        updater.checkNow()
        await waitFor { updater.sidebarRelease != nil }
        updater.download()
        await waitFor { if case .failed(_, .some) = updater.phase { true } else { false } }
        updater.installAtTermination()
        XCTAssertTrue(fake.swaps.isEmpty)

        fake.prepareError = nil
        updater.download()
        await waitFor { updater.phase == .ready(release("1.1.0")) }
    }

    func testALocationThatCantBeReplacedOpensTheReleasePageInstead() async {
        let fake = Fake()
        fake.latest = release("1.1.0")
        fake.location = .manualOnly("read-only")
        let updater = makeUpdater(fake)
        updater.checkNow()
        await waitFor { updater.sidebarRelease != nil }
        updater.download()
        XCTAssertEqual(fake.opened, [release("1.1.0").pageURL])
        XCTAssertEqual(updater.phase, .available(release("1.1.0")))
    }

    func testDisabledBuildsNeverCheckOrInstall() async {
        let fake = Fake()
        fake.latest = release("9.0.0")
        let updater = makeUpdater(fake, enabled: false)
        updater.start()
        updater.checkNow()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fake.fetches, 0)
        XCTAssertEqual(updater.phase, .idle)
        XCTAssertGreaterThan(updater.settingsFocusRequest, 0, "the menu command still opens Settings")
    }

    func testLeftoverStagingFromAnEarlierRunIsRemovedAtLaunch() throws {
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("CloudStream.app"), withIntermediateDirectories: true)
        defaults.set(staging.path, forKey: "CSUpdateStagingDirectory")
        let updater = makeUpdater(Fake())
        updater.automaticallyChecks = false
        updater.start()
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertNil(defaults.string(forKey: "CSUpdateStagingDirectory"))
    }

    func testRemovingAStagingFolderFreesItsPathAtOnceAndDeletesItsContentsLater() async throws {
        let folder = staging.appendingPathComponent("leftover", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("CloudStream.app/Contents"), withIntermediateDirectories: true)
        SoftwareUpdater.removeDirectory(folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "the path is free for a new download immediately")
        // A new folder at the same path is not touched by the background delete.
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        await waitFor {
            ((try? FileManager.default.contentsOfDirectory(atPath: self.staging.path)) ?? []).filter { $0.contains(".removing-") }.isEmpty
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }

    func testAutomaticCheckingPreferencePersists() {
        let updater = makeUpdater(Fake())
        XCTAssertTrue(updater.automaticallyChecks, "on by default")
        updater.automaticallyChecks = false
        XCTAssertFalse(makeUpdater(Fake()).automaticallyChecks)
    }
}
