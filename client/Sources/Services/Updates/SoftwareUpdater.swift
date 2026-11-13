import AppKit
import Foundation
import Observation

/// In-app updates from the project's GitHub Releases (ADR-0007): check,
/// download with progress, verify, and install when CloudStream restarts or
/// quits. Nothing installs without the person choosing Download.
///
/// Shown in the sidebar (above the profile button) while an update needs
/// attention, in Settings ▸ General ▸ Software Update, and in the app menu
/// (CloudStream ▸ Check for Updates…).
@MainActor
@Observable
final class SoftwareUpdater {
    static let shared = SoftwareUpdater()

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(UpdateRelease)
        case downloading(UpdateRelease, fraction: Double)
        case preparing(UpdateRelease)
        /// Verified and staged; installs at the next quit.
        case ready(UpdateRelease)
        /// `release` is set when downloading or preparing that release failed.
        case failed(String, release: UpdateRelease?)
    }

    /// Everything that touches the network, the disk or the process.
    struct Environment {
        var isEnabled: Bool
        var currentVersion: SemanticVersion
        var bundleIdentifier: String
        var installedApp: URL
        var defaults: UserDefaults
        var location: () -> UpdateInstaller.Location
        var fetchLatest: () async throws -> UpdateRelease?
        var fetchChecksumFile: (UpdateRelease.Asset) async throws -> String
        var download: (UpdateRelease.Asset, URL, @escaping @Sendable (Double) -> Void) async throws -> Void
        var makeStagingDirectory: () throws -> URL
        var ensureSpace: (Int64, URL) throws -> Void
        var prepare: (UpdateInstaller.Request) async throws -> URL
        var teamIdentifier: () -> String?
        var swap: (URL, URL) throws -> Void
        var relaunch: (URL) throws -> Void
        var openURL: (URL) -> Void
        /// Quits through the app's normal termination path.
        var terminate: () -> Void
        var now: () -> Date
        /// The first automatic check after launch.
        var launchDelay: Duration = SoftwareUpdater.launchDelay
    }

    nonisolated static let checkInterval: TimeInterval = 12 * 60 * 60
    nonisolated static let launchDelay: Duration = .seconds(20)

    private(set) var phase: Phase = .idle
    /// The last automatic check's failure; shown in Settings only.
    private(set) var lastBackgroundError: String?
    private(set) var lastCheckedAt: Date?
    /// Bumped by CloudStream ▸ Check for Updates… so Settings shows General.
    private(set) var settingsFocusRequest = 0

    var automaticallyChecks: Bool {
        didSet {
            environment.defaults.set(automaticallyChecks, forKey: Keys.automatic)
            scheduleAutomaticChecks()
        }
    }

    var currentVersion: SemanticVersion { environment.currentVersion }
    var isAvailable: Bool { environment.isEnabled }
    /// Whether this copy can replace itself; refreshed at launch, at each
    /// check and before a download (not on every view update).
    private(set) var location: UpdateInstaller.Location = .supported

    @ObservationIgnored private var environment: Environment
    @ObservationIgnored private var schedule: Task<Void, Never>?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var check: Task<Void, Never>?
    @ObservationIgnored private var staged: (app: URL, directory: URL)?
    @ObservationIgnored private var relaunchRequested = false
    /// Bumped by every download and cancel: a superseded task (still
    /// unwinding after Cancel) must not touch the state or the files of the
    /// download that replaced it.
    @ObservationIgnored private var downloadGeneration = 0
    private var skippedVersion: String?

    private enum Keys {
        static let automatic = "CSUpdateAutomaticallyChecks"
        static let skipped = "CSUpdateSkippedVersion"
        static let lastChecked = "CSUpdateLastChecked"
        static let staging = "CSUpdateStagingDirectory"
        static let installFailure = "CSUpdateInstallFailure"
    }

    init(environment: Environment = .live()) {
        self.environment = environment
        let defaults = environment.defaults
        automaticallyChecks = defaults.object(forKey: Keys.automatic) as? Bool ?? true
        skippedVersion = defaults.string(forKey: Keys.skipped)
        lastCheckedAt = defaults.object(forKey: Keys.lastChecked) as? Date
    }

    // MARK: Derived state for the views

    /// The release the sidebar row is about, if it should show at all. A
    /// skipped version stays out of the sidebar (Settings still offers it).
    var sidebarRelease: UpdateRelease? {
        switch phase {
        case .available(let release): release.version.description == skippedVersion ? nil : release
        case .downloading(let release, _), .preparing(let release), .ready(let release): release
        case .failed(_, let release?): release
        default: nil
        }
    }

    var isBusy: Bool {
        switch phase {
        case .checking, .downloading, .preparing: true
        default: false
        }
    }

    // MARK: Lifecycle

    /// At launch: removes what an earlier install left behind and starts
    /// automatic checks.
    func start() {
        guard environment.isEnabled else { return }
        location = environment.location()
        removeLeftoverStaging()
        if let failure = environment.defaults.string(forKey: Keys.installFailure) {
            environment.defaults.removeObject(forKey: Keys.installFailure)
            lastBackgroundError = failure
        }
        scheduleAutomaticChecks()
    }

    private func scheduleAutomaticChecks() {
        schedule?.cancel()
        schedule = nil
        guard environment.isEnabled, automaticallyChecks else { return }
        schedule = Task { [weak self] in
            guard let self else { return }
            let elapsed = lastCheckedAt.map { environment.now().timeIntervalSince($0) } ?? .infinity
            let first = max(environment.launchDelay, .seconds(max(0, Self.checkInterval - elapsed)))
            do { try await Task.sleep(for: first) } catch { return }
            while !Task.isCancelled {
                await runCheck(userInitiated: false)
                do { try await Task.sleep(for: .seconds(Self.checkInterval)) } catch { return }
            }
        }
    }

    // MARK: Actions

    /// Settings' and the menu's Check for Updates. Shows the result in
    /// Settings; never interrupts a download or a staged update.
    func checkNow() {
        settingsFocusRequest += 1
        guard environment.isEnabled, !isBusy else { return }
        if case .ready = phase { return }
        check = Task { await runCheck(userInitiated: true) }
    }

    func download() {
        guard environment.isEnabled else { return }
        let release: UpdateRelease
        switch phase {
        case .available(let candidate), .failed(_, let candidate?): release = candidate
        default: return
        }
        location = environment.location()
        guard location == .supported else {
            environment.openURL(release.pageURL)
            return
        }
        // Choosing to download un-skips the version.
        setSkipped(nil)
        work?.cancel()
        downloadGeneration += 1
        let generation = downloadGeneration
        phase = .downloading(release, fraction: 0)
        work = Task { await runDownload(release, generation: generation) }
    }

    func cancelDownload() {
        guard case .downloading(let release, _) = phase else { return }
        work?.cancel()
        work = nil
        downloadGeneration += 1
        discardStaged()
        phase = .available(release)
    }

    /// Hides this version from the sidebar until a newer one appears.
    func skipThisVersion() {
        guard case .available(let release) = phase else { return }
        setSkipped(release.version.description)
    }

    func openReleaseNotes() {
        let release: UpdateRelease? = switch phase {
        case .available(let r), .downloading(let r, _), .preparing(let r), .ready(let r): r
        case .failed(_, let r): r
        default: nil
        }
        if let release { environment.openURL(release.pageURL) }
    }

    /// Quits through the normal path (downloads prompt, progress save,
    /// engine shutdown); the swap happens in `installAtTermination()`.
    func restartToUpdate() {
        guard case .ready = phase else { return }
        relaunchRequested = true
        environment.terminate()
    }

    /// The quit was cancelled (a prompt chose Keep Open/Cancel): a later,
    /// ordinary quit must not relaunch.
    func terminationCancelled() {
        relaunchRequested = false
    }

    /// From `applicationWillTerminate`: installs a staged update (any quit),
    /// relaunching only if Restart was chosen. Never throws; a failure keeps
    /// the current app, and the update is offered again next time.
    func installAtTermination() {
        work?.cancel()
        guard case .ready(let release) = phase, let staged else { return }
        do {
            try environment.swap(staged.app, environment.installedApp)
            DaemonLog.client("update.installed", fields: ["version": release.version.description])
            if relaunchRequested { try? environment.relaunch(environment.installedApp) }
        } catch {
            let message = Self.describe(error)
            DaemonLog.client("update.install_failed", fields: ["version": release.version.description, "error": message])
            environment.defaults.set("Version \(release.version.description) couldn’t be installed: \(message)", forKey: Keys.installFailure)
            // Restart was chosen: come back, as this version, rather than not at all.
            if relaunchRequested { try? environment.relaunch(environment.installedApp) }
        }
    }

    // MARK: Work

    private func runCheck(userInitiated: Bool) async {
        if case .ready = phase { return }
        if case .downloading = phase { return }
        if case .preparing = phase { return }
        let previous = phase
        location = environment.location()
        if userInitiated { phase = .checking }
        do {
            let latest = try await environment.fetchLatest()
            lastCheckedAt = environment.now()
            environment.defaults.set(lastCheckedAt, forKey: Keys.lastChecked)
            lastBackgroundError = nil
            if let latest, latest.version > environment.currentVersion {
                // A newer release than the skipped one shows again.
                if let skippedVersion, let skipped = SemanticVersion(skippedVersion), latest.version > skipped { setSkipped(nil) }
                phase = .available(latest)
            } else {
                phase = .upToDate
            }
        } catch is CancellationError {
            phase = previous
        } catch {
            let message = Self.describe(error)
            DaemonLog.client("update.check_failed", fields: ["error": message, "manual": userInitiated ? "1" : "0"])
            if userInitiated { phase = .failed(message, release: nil) } else { lastBackgroundError = message; phase = previous }
        }
    }

    private func runDownload(_ release: UpdateRelease, generation: Int) async {
        var directory: URL?
        do {
            discardStaged()
            let created = try environment.makeStagingDirectory()
            directory = created
            environment.defaults.set(created.path, forKey: Keys.staging)
            staged = (created.appendingPathComponent("CloudStream.app"), created)
            try environment.ensureSpace(release.dmg.size, created)

            var checksumFile: String?
            if let asset = release.checksumAsset {
                let text = try await environment.fetchChecksumFile(asset)
                checksumFile = UpdateFeed.checksum(fromShasumOutput: text, for: release.dmg.name)
                // A published checksum file that doesn't name the image is a broken release.
                if checksumFile == nil { throw UpdateInstaller.InstallError.checksumUnavailable }
            }
            let digest = try UpdateInstaller.expectedDigest(apiDigest: release.dmg.sha256, checksumFile: checksumFile)

            let image = created.appendingPathComponent(release.dmg.name)
            try await environment.download(release.dmg, image) { [weak self] fraction in
                Task { @MainActor [weak self] in self?.reportProgress(fraction, generation: generation) }
            }
            try checkCurrent(generation)
            phase = .preparing(release)
            let request = UpdateInstaller.Request(
                release: release, diskImage: image, expectedDigest: digest, installedApp: environment.installedApp,
                stagingDirectory: created, bundleIdentifier: environment.bundleIdentifier,
                currentVersion: environment.currentVersion, teamIdentifier: environment.teamIdentifier())
            let app = try await environment.prepare(request)
            try checkCurrent(generation)
            staged = (app, created)
            phase = .ready(release)
            DaemonLog.client("update.ready", fields: ["version": release.version.description])
        } catch {
            // A superseded download only removes its own folder: Cancel already
            // set the phase, and a newer download owns `staged`.
            guard generation == downloadGeneration, !Task.isCancelled,
                  !(error is CancellationError), (error as? URLError)?.code != .cancelled else {
                if let directory, directory != staged?.directory { Self.removeDirectory(directory) }
                return
            }
            discardStaged()
            let message = Self.describe(error)
            DaemonLog.client("update.download_failed", fields: ["version": release.version.description, "error": message])
            phase = .failed(message, release: release)
        }
    }

    private func checkCurrent(_ generation: Int) throws {
        if Task.isCancelled || generation != downloadGeneration { throw CancellationError() }
    }

    private func reportProgress(_ fraction: Double, generation: Int) {
        guard generation == downloadGeneration, case .downloading(let release, let current) = phase, fraction >= current else { return }
        phase = .downloading(release, fraction: fraction)
    }

    private func setSkipped(_ version: String?) {
        skippedVersion = version
        environment.defaults.set(version, forKey: Keys.skipped)
    }

    private func discardStaged() {
        if let directory = staged?.directory { Self.removeDirectory(directory) }
        staged = nil
        environment.defaults.removeObject(forKey: Keys.staging)
    }

    /// An earlier run's staging directory holds the previous app after an
    /// install, or an unused download. Only the recorded directory is removed,
    /// and never one that contains the running app.
    private func removeLeftoverStaging() {
        guard let path = environment.defaults.string(forKey: Keys.staging) else { return }
        environment.defaults.removeObject(forKey: Keys.staging)
        let directory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let running = environment.installedApp.resolvingSymlinksInPath().path
        guard directory.path.count > 1, !running.hasPrefix(directory.path + "/") else { return }
        Self.removeDirectory(directory)
    }

    /// Removes a staging folder without blocking the main actor: after an
    /// install it holds the whole previous app (thousands of files). The
    /// rename beside it is one metadata operation and frees the path at once,
    /// so a new download may reuse it; the contents are deleted on a utility
    /// thread. A folder that can't be renamed is removed in place.
    nonisolated static func removeDirectory(_ directory: URL) {
        let fileManager = FileManager.default
        let doomed = directory.deletingLastPathComponent()
            .appendingPathComponent(".\(directory.lastPathComponent).removing-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.moveItem(at: directory, to: doomed)
        } catch {
            // Nothing there: nothing to delete (and nothing to race a reuse of the path).
            guard fileManager.fileExists(atPath: directory.path) else { return }
            try? fileManager.removeItem(at: directory)
            return
        }
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: doomed) }
    }

    static func describe(_ error: Error) -> String {
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost: return "You’re offline."
            case .timedOut: return "GitHub didn’t respond in time."
            case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost: return "GitHub couldn’t be reached."
            default: break
            }
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

extension SoftwareUpdater.Environment {
    /// The real app: GitHub Releases for `CSUpdateRepository` in Info.plist.
    /// Disabled in debug builds and isolated (test) runs, and when the build
    /// names no repository or has no valid version.
    @MainActor
    static func live() -> Self {
        #if DEBUG
        if AppEnvironment.isIsolated(), ProcessInfo.processInfo.environment["CS_UPDATE_FIXTURE"] == "1" { return fixture() }
        #endif
        let bundle = Bundle.main
        let versionText = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let version = SemanticVersion(versionText)
        let repository = UpdateFeed.repository(bundle.infoDictionary)
        #if DEBUG
        let buildAllows = false
        #else
        let buildAllows = true
        #endif
        let enabled = buildAllows && !AppEnvironment.isIsolated() && version != nil && repository != nil
            && bundle.bundleIdentifier != nil
        let network = UpdateNetwork(version: versionText)
        let installed = bundle.bundleURL
        return Self(
            isEnabled: enabled,
            currentVersion: version ?? SemanticVersion(major: 0, minor: 0, patch: 0),
            bundleIdentifier: bundle.bundleIdentifier ?? "",
            installedApp: installed,
            defaults: .standard,
            location: { UpdateInstaller.location(of: installed) },
            fetchLatest: {
                guard let repository, let url = UpdateFeed.latestReleaseURL(repository: repository) else { return nil }
                do {
                    return try UpdateFeed.decode(try await network.data(from: url))
                } catch UpdateNetwork.NetworkError.status(404) {
                    return nil   // no published release yet
                }
            },
            fetchChecksumFile: { asset in
                String(decoding: try await network.data(from: asset.url, accept: "application/octet-stream"), as: UTF8.self)
            },
            download: { asset, destination, progress in
                try await network.download(asset, to: destination, progress: progress)
            },
            makeStagingDirectory: { try UpdateInstaller.makeStagingDirectory(near: installed) },
            ensureSpace: { try UpdateInstaller.ensureSpace(for: $0, at: $1) },
            prepare: { try await UpdateInstaller.prepare($0) },
            teamIdentifier: { UpdateInstaller.currentTeamIdentifier() },
            swap: { try UpdateInstaller.swap(staged: $0, installed: $1) },
            relaunch: { try UpdateInstaller.relaunch($0, afterExitOf: ProcessInfo.processInfo.processIdentifier) },
            openURL: { NSWorkspace.shared.open($0) },
            terminate: { NSApp.terminate(nil) },
            now: { Date() })
    }
}

#if DEBUG
extension SoftwareUpdater.Environment {
    /// UI tests and previews (`CS_UPDATE_FIXTURE=1` in an isolated debug run):
    /// version 99.0.0 is available at once; Download simulates progress and
    /// verification. Nothing is fetched, written, installed or quit.
    @MainActor
    static func fixture() -> Self {
        let page = URL(string: "https://github.com/krishnasinghrao/cloudstream-macos/releases")!
        let asset = UpdateRelease.Asset(name: UpdateFeed.dmgName, url: page, size: 90_000_000, sha256: String(repeating: "0", count: 64))
        let release = UpdateRelease(version: SemanticVersion(major: 99, minor: 0, patch: 0), tag: "v99.0.0", pageURL: page,
                                    publishedAt: Date(), dmg: asset, checksumAsset: nil)
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("cs-update-fixture", isDirectory: true)
        // A fresh file each launch: no skip or schedule leaks between runs, and
        // nothing in ~/Library/Preferences.
        let preferences = staging.appendingPathComponent("preferences")
        try? FileManager.default.removeItem(at: preferences.appendingPathExtension("plist"))
        let defaults = AppEnvironment.fileDefaults(at: preferences)
        return Self(
            isEnabled: true,
            currentVersion: SemanticVersion(major: 1, minor: 0, patch: 0),
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "",
            installedApp: Bundle.main.bundleURL,
            defaults: defaults,
            location: { .supported },
            fetchLatest: { release },
            fetchChecksumFile: { _ in "" },
            download: { _, _, progress in
                for step in 1...20 {
                    try await Task.sleep(for: .milliseconds(100))
                    progress(Double(step) / 20)
                }
            },
            makeStagingDirectory: { staging },
            ensureSpace: { _, _ in },
            prepare: { request in
                try await Task.sleep(for: .milliseconds(400))
                return request.stagingDirectory.appendingPathComponent("CloudStream.app")
            },
            teamIdentifier: { nil },
            swap: { _, _ in },
            relaunch: { _ in },
            openURL: { _ in },
            terminate: { DaemonLog.client("update.fixture_restart") },
            now: { Date() },
            launchDelay: .milliseconds(200))
    }
}
#endif
