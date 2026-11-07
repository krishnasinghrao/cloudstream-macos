import CryptoKit
import Darwin
import Foundation
import Security

/// Turns a downloaded release disk image into a verified app beside the
/// installed one, and swaps it in when CloudStream quits.
///
/// Trust: the disk image must match GitHub's SHA-256 for it (the API's asset
/// digest and/or the release's `.sha256` file, which must agree when both
/// exist). The app inside must be this app (bundle identifier), exactly the
/// release's version and newer than this one, runnable on this macOS, and
/// validly signed. When this app is signed with a Developer ID, the update
/// must be signed by the same team; an ad-hoc build accepts any valid
/// signature for its own identifier (it has no identity to pin).
enum UpdateInstaller {
    enum InstallError: LocalizedError, Equatable {
        case checksumUnavailable
        case checksumMismatch
        case mountFailed
        case appMissing
        case wrongApp(String)
        case wrongVersion(expected: String, found: String)
        case notNewer(String)
        case requiresNewerMacOS(String)
        case signature(String)
        case copyFailed
        case notEnoughSpace(needed: Int64)
        case swapFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .checksumUnavailable: "The release has no checksum to verify the download with."
            case .checksumMismatch: "The download doesn’t match the release’s checksum."
            case .mountFailed: "The downloaded disk image couldn’t be opened."
            case .appMissing: "The disk image doesn’t contain CloudStream."
            case .wrongApp(let identifier): "The disk image contains a different app (\(identifier))."
            case .wrongVersion(let expected, let found): "The disk image contains version \(found), not \(expected)."
            case .notNewer(let version): "Version \(version) isn’t newer than this one."
            case .requiresNewerMacOS(let version): "This update requires macOS \(version) or later."
            case .signature(let reason): "The update’s code signature isn’t valid: \(reason)"
            case .copyFailed: "The update couldn’t be copied next to CloudStream."
            case .notEnoughSpace(let needed): "Not enough disk space for the update (\(needed.formatted(.byteCount(style: .file))) needed)."
            case .swapFailed(let code): "The update couldn’t replace CloudStream (\(String(cString: strerror(code))))."
            }
        }
    }

    // MARK: Where this app can be updated

    enum Location: Equatable, Sendable {
        case supported
        /// Updates are offered as a download page instead, with the reason.
        case manualOnly(String)
    }

    static func location(of bundle: URL, fileManager: FileManager = .default) -> Location {
        let path = bundle.resolvingSymlinksInPath().path
        if path.contains("/AppTranslocation/") {
            return .manualOnly("Move CloudStream to the Applications folder to install updates from inside the app.")
        }
        if (try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == true {
            return .manualOnly("CloudStream is running from a disk image. Copy it to the Applications folder to install updates from inside the app.")
        }
        let parent = bundle.resolvingSymlinksInPath().deletingLastPathComponent().path
        guard fileManager.isWritableFile(atPath: parent), fileManager.isWritableFile(atPath: path) else {
            return .manualOnly("You don’t have permission to replace CloudStream in \(parent). Download the update and install it yourself.")
        }
        return .supported
    }

    // MARK: Verification

    /// The digest the download must have, from the API digest and/or the
    /// release's checksum file. Disagreeing sources are an error.
    static func expectedDigest(apiDigest: String?, checksumFile: String?) throws -> String {
        switch (apiDigest, checksumFile) {
        case let (api?, file?):
            guard api == file else { throw InstallError.checksumMismatch }
            return api
        case let (api?, nil): return api
        case let (nil, file?): return file
        case (nil, nil): throw InstallError.checksumUnavailable
        }
    }

    private static func escapeRequirementLiteral(_ string: String) -> String {
        string.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// The code requirement an update must satisfy. With a Developer ID the
    /// update must come from the same team; nil team = ad-hoc build.
    static func requirement(bundleIdentifier: String, teamIdentifier: String?) -> String {
        let identifier = "identifier \"\(escapeRequirementLiteral(bundleIdentifier))\""
        guard let team = teamIdentifier else { return identifier }
        return "\(identifier) and anchor apple generic and certificate leaf[subject.OU] = \"\(escapeRequirementLiteral(team))\""
    }

    /// The running app's signing team, nil when ad-hoc or unsigned.
    static func currentTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        return teamIdentifier(of: staticCode)
    }

    private static func teamIdentifier(of code: SecStaticCode) -> String? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Strict, deep validation of `app` against `requirement`.
    static func verifySignature(of app: URL, requirement text: String) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw InstallError.signature("the app couldn’t be read")
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else {
            throw InstallError.signature("invalid requirement")
        }
        let flags = SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures) | UInt32(kSecCSStrictValidate)
            | UInt32(kSecCSCheckNestedCode) | UInt32(kSecCSRestrictSymlinks))
        var error: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(code, flags, requirement, &error)
        guard status == errSecSuccess else {
            let reason = (error?.takeRetainedValue()).map { CFErrorCopyDescription($0) as String } ?? "OSStatus \(status)"
            throw InstallError.signature(status == errSecCSReqFailed ? "it isn’t signed by CloudStream’s developer" : reason)
        }
    }

    /// Checks the app's Info.plist against the release and this Mac.
    static func verifyBundle(_ app: URL, bundleIdentifier: String, release: SemanticVersion, current: SemanticVersion,
                             systemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) throws {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any] else {
            throw InstallError.appMissing
        }
        let identifier = info["CFBundleIdentifier"] as? String ?? "unknown"
        guard identifier == bundleIdentifier else { throw InstallError.wrongApp(identifier) }
        let found = info["CFBundleShortVersionString"] as? String ?? "unknown"
        guard let version = SemanticVersion(found), version == release else {
            throw InstallError.wrongVersion(expected: release.description, found: found)
        }
        guard version > current else { throw InstallError.notNewer(found) }
        if let minimum = info["LSMinimumSystemVersion"] as? String {
            let parts = minimum.split(separator: ".").map { Int($0) ?? 0 }
            let required = OperatingSystemVersion(majorVersion: parts.first ?? 0, minorVersion: parts.count > 1 ? parts[1] : 0,
                                                  patchVersion: parts.count > 2 ? parts[2] : 0)
            let system = systemVersion
            let satisfied = (system.majorVersion, system.minorVersion, system.patchVersion)
                >= (required.majorVersion, required.minorVersion, required.patchVersion)
            guard satisfied else { throw InstallError.requiresNewerMacOS(minimum) }
        }
    }

    // MARK: Preparing

    struct Request: Sendable {
        let release: UpdateRelease
        let diskImage: URL
        let expectedDigest: String
        let installedApp: URL
        let stagingDirectory: URL
        let bundleIdentifier: String
        let currentVersion: SemanticVersion
        let teamIdentifier: String?
    }

    /// Verifies the downloaded disk image and copies its app into
    /// `stagingDirectory` (same volume as the installed app). Returns the
    /// staged app. The disk image is always detached; it is deleted here.
    static func prepare(_ request: Request) async throws -> URL {
        defer { try? FileManager.default.removeItem(at: request.diskImage) }
        let actual = try SHA256.hexDigest(ofFileAt: request.diskImage)
        guard actual == request.expectedDigest else { throw InstallError.checksumMismatch }
        try Task.checkCancellation()

        let mountPoint = try await attach(request.diskImage, under: request.stagingDirectory)
        defer { detach(mountPoint) }
        let source = mountPoint.appendingPathComponent("CloudStream.app", isDirectory: true)
        let values = try? source.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values?.isDirectory == true, values?.isSymbolicLink != true else { throw InstallError.appMissing }
        let requirement = requirement(bundleIdentifier: request.bundleIdentifier, teamIdentifier: request.teamIdentifier)
        try verifyBundle(source, bundleIdentifier: request.bundleIdentifier, release: request.release.version,
                         current: request.currentVersion)
        try verifySignature(of: source, requirement: requirement)
        try Task.checkCancellation()

        let staged = request.stagingDirectory.appendingPathComponent("CloudStream.app", isDirectory: true)
        try? FileManager.default.removeItem(at: staged)
        let copy = try await run("/usr/bin/ditto", [source.path, staged.path])
        guard copy.status == 0 else { throw InstallError.copyFailed }
        // What gets installed is the copy: check it again.
        try verifyBundle(staged, bundleIdentifier: request.bundleIdentifier, release: request.release.version,
                         current: request.currentVersion)
        try verifySignature(of: staged, requirement: requirement)
        return staged
    }

    private static func attach(_ image: URL, under directory: URL) async throws -> URL {
        let result = try await run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen",
                                                        "-mountrandom", directory.path, "-plist", image.path])
        guard result.status == 0,
              let plist = try? PropertyListSerialization.propertyList(from: result.output, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let path = entities.compactMap({ $0["mount-point"] as? String }).first
        else { throw InstallError.mountFailed }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func detach(_ mountPoint: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["detach", mountPoint.path, "-force", "-quiet"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    static func run(_ tool: String, _ arguments: [String]) async throws -> (status: Int32, output: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        // Stdout goes to a private temporary file, not a pipe. A pipe fails
        // both ways: read after exit, a tool that writes more than its buffer
        // (64 KiB) blocks and never exits; read to end of file, `hdiutil
        // attach` never delivers one, because the diskimages-helper it starts
        // inherits stdout and lives as long as the image is mounted. A file
        // neither fills nor waits for other holders; it is read once the tool
        // itself has exited.
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloudstream-tool-\(UUID().uuidString).out")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let output = try FileHandle(forWritingTo: outputURL)
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let status: Int32 = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    continuation.resume(returning: finished.terminationStatus)
                }
                do { try process.run() } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        try? output.close()
        return (status, (try? Data(contentsOf: outputURL)) ?? Data())
    }

    /// Free space needed beside the installed app: the disk image plus the
    /// unpacked app (about three times the image), with headroom.
    static func ensureSpace(for imageBytes: Int64, at directory: URL) throws {
        let needed = imageBytes * 4
        let available = (try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage) ?? Int64.max
        guard available >= needed else { throw InstallError.notEnoughSpace(needed: needed) }
    }

    /// A fresh directory on the installed app's volume, so the final swap
    /// is a rename rather than a copy.
    static func makeStagingDirectory(near installedApp: URL) throws -> URL {
        try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                    appropriateFor: installedApp, create: true)
    }

    // MARK: Installing

    /// Atomically exchanges the staged app and the installed one, leaving the
    /// old app at `staged` (removed with the staging directory later). Falls
    /// back to two renames, restoring the original on failure, where the
    /// volume can't swap.
    static func swap(staged: URL, installed: URL) throws {
        if renamex_np(staged.path, installed.path, UInt32(RENAME_SWAP)) == 0 { return }
        let swapError = errno
        guard swapError == ENOTSUP || swapError == EINVAL else { throw InstallError.swapFailed(swapError) }
        let aside = staged.deletingLastPathComponent().appendingPathComponent("Previous-CloudStream.app", isDirectory: true)
        try? FileManager.default.removeItem(at: aside)
        guard rename(installed.path, aside.path) == 0 else { throw InstallError.swapFailed(errno) }
        guard rename(staged.path, installed.path) == 0 else {
            let failure = errno
            _ = rename(aside.path, installed.path)
            throw InstallError.swapFailed(failure)
        }
        _ = rename(aside.path, staged.path)
    }

    /// Opens `app` once process `pid` has exited (at most a minute later).
    static func relaunch(_ app: URL, afterExitOf pid: Int32) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Arguments are passed positionally, never interpolated into the script.
        process.arguments = ["-c", """
            i=0
            while kill -0 "$1" 2>/dev/null && [ "$i" -lt 600 ]; do sleep 0.1; i=$((i+1)); done
            exec /usr/bin/open "$2"
            """, "cloudstream-relaunch", String(pid), app.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}
