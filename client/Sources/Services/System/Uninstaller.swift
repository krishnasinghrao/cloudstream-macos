import AppKit
import CoreSpotlight
import Foundation
import UserNotifications

/// Settings ▸ General ▸ Delete CloudStream (ADR-0023): removes everything the
/// app keeps on this Mac, then moves the app itself to the Trash.
///
/// CloudStream is not sandboxed, so its data is spread over the user's
/// Library and the engine's home. `UninstallFootprint` names every location
/// the app writes; nothing outside that list is ever touched.
///
/// Order, so nothing is recreated behind the deletion and nothing is lost
/// if a step fails early:
/// 1. Stop everything (player, downloads, schedulers, engine and workers).
/// 2. Start `UninstallScript`, detached. It waits for the app to exit, then
///    deletes the preference domain through `defaults` (so cfprefsd forgets
///    it too) and removes the listed files and folders. If it can't start,
///    nothing has been deleted.
/// 3. Remove what only this process can: Keychain items (their access
///    belongs to the app), Spotlight entries and delivered notifications.
/// 4. Move the app bundle to the Trash (Finder's Put Back still works).
/// 5. Exit without the normal quit path, which would save progress and
///    preferences again.

/// One location CloudStream keeps data in.
struct UninstallItem: Hashable, Sendable {
    enum Category: String, Sendable, CaseIterable {
        case library = "Library, history and profiles"
        case extensions = "Extensions and engine data"
        case caches = "Caches"
        case logs = "Logs"
        case settings = "Settings and window state"
        case downloads = "Downloaded videos"
    }

    let url: URL
    let category: Category
}

/// Every place CloudStream writes, for one home folder. Pure: computing it
/// touches nothing, and tests build it for a temporary home.
struct UninstallFootprint: Sendable {
    let home: URL
    let bundleIdentifier: String
    let items: [UninstallItem]

    /// What exists now under `home`. Downloads are listed only when asked for,
    /// and only the files CloudStream recorded downloading (never whole folders).
    static func scan(home: URL, bundleIdentifier: String, downloadedFiles: [URL] = [],
                     fileManager: FileManager = .default) -> UninstallFootprint {
        let library = home.appendingPathComponent("Library", isDirectory: true)
        let support = library.appendingPathComponent("Application Support", isDirectory: true)
        let caches = library.appendingPathComponent("Caches", isDirectory: true)
        var candidates: [UninstallItem] = [
            .init(url: home.appendingPathComponent(".cloudstream-macos", isDirectory: true), category: .extensions),
            .init(url: support.appendingPathComponent("CloudStream", isDirectory: true), category: .library),
            .init(url: caches.appendingPathComponent("CloudStreamMac", isDirectory: true), category: .caches),
            .init(url: caches.appendingPathComponent(bundleIdentifier, isDirectory: true), category: .caches),
            .init(url: library.appendingPathComponent("HTTPStorages/\(bundleIdentifier)", isDirectory: true), category: .caches),
            .init(url: library.appendingPathComponent("HTTPStorages/\(bundleIdentifier).binarycookies"), category: .caches),
            .init(url: library.appendingPathComponent("WebKit/\(bundleIdentifier)", isDirectory: true), category: .caches),
            .init(url: library.appendingPathComponent("Logs/CloudStreamMac", isDirectory: true), category: .logs),
            .init(url: library.appendingPathComponent("Preferences/\(bundleIdentifier).plist"), category: .settings),
            .init(url: library.appendingPathComponent("Saved Application State/\(bundleIdentifier).savedState", isDirectory: true), category: .settings),
        ]
        // SwiftData stores: the default profile's and one per added profile.
        let names = (try? fileManager.contentsOfDirectory(atPath: support.path)) ?? []
        for name in names.sorted() where isLibraryStoreName(name) {
            candidates.append(.init(url: support.appendingPathComponent(name), category: .library))
        }
        // Pre-migration copies of those stores (SQLiteRecoverySnapshot). The
        // folder name is generic, so it is listed only when it holds nothing
        // but CloudStream snapshot folders.
        let recovery = support.appendingPathComponent("IdentityRecovery", isDirectory: true)
        if isRecoverySnapshotFolder(recovery, fileManager: fileManager) {
            candidates.append(.init(url: recovery, category: .library))
        }
        for file in downloadedFiles {
            candidates.append(.init(url: file, category: .downloads))
        }

        var seen = Set<String>()
        let items = candidates.filter { item in
            let path = item.url.standardizedFileURL.path
            guard isSafeToDelete(item.url, home: home), seen.insert(path).inserted else { return false }
            // `fileExists` follows links; a dangling or present link is still listed.
            return (try? item.url.checkResourceIsReachable()) == true
                || (try? fileManager.destinationOfSymbolicLink(atPath: path)) != nil
        }
        // A listed folder already covers anything inside it.
        let folders = items.map { $0.url.standardizedFileURL.path + "/" }
        let outermost = items.filter { item in
            let path = item.url.standardizedFileURL.path
            return !folders.contains { path.hasPrefix($0) }
        }
        return UninstallFootprint(home: home, bundleIdentifier: bundleIdentifier, items: outermost)
    }

    /// `CloudStreamMac.store`, `CloudStreamMac-Profile-<UUID>.store`, their
    /// `-shm`/`-wal` files and SwiftData's hidden `_SUPPORT` folders.
    static func isLibraryStoreName(_ name: String) -> Bool {
        let pattern = #"^\.?CloudStreamMac(-Profile-[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})?(\.store(-shm|-wal)?|_SUPPORT)$"#
        return name.range(of: pattern, options: .regularExpression) != nil
    }

    static func isRecoverySnapshotFolder(_ folder: URL, fileManager: FileManager = .default) -> Bool {
        guard let children = try? fileManager.contentsOfDirectory(atPath: folder.path) else { return false }
        let visible = children.filter { $0 != ".DS_Store" }
        return !visible.isEmpty && visible.allSatisfy { name in
            guard UUID(uuidString: name) != nil else { return false }
            let snapshot = folder.appendingPathComponent(name, isDirectory: true)
            return fileManager.fileExists(atPath: snapshot.appendingPathComponent("manifest.json").path)
                || fileManager.fileExists(atPath: snapshot.appendingPathComponent("recovery.store").path)
        }
    }

    /// The last line of defence: an absolute, normalised path at least two
    /// levels inside the home folder (downloads: anywhere but a system or
    /// top-level folder), never the home, its Library or a standard folder.
    static func isSafeToDelete(_ url: URL, home: URL) -> Bool {
        guard url.isFileURL else { return false }
        let raw = url.path
        guard raw.hasPrefix("/"), !raw.contains("/../"), !raw.hasSuffix("/.."), !raw.contains("/./") else { return false }
        let path = url.standardizedFileURL.path
        let homePath = home.standardizedFileURL.path
        let components = URL(fileURLWithPath: path).pathComponents
        guard components.count >= 4 else { return false } // "/", "Users", "<name>", ...
        let protected: Set<String> = Set([
            "", "Library", "Library/Application Support", "Library/Caches", "Library/Preferences", "Library/Logs",
            "Library/HTTPStorages", "Library/WebKit", "Library/Saved Application State", "Movies", "Downloads",
            "Desktop", "Documents", "Pictures", "Music", "Public", ".Trash",
        ].map { $0.isEmpty ? homePath : homePath + "/" + $0 })
        guard !protected.contains(path) else { return false }
        for system in ["/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/private", "/etc", "/var", "/opt", "/Volumes"]
            where path == system { return false }
        if path.hasPrefix(homePath + "/") { return true }
        // Outside home only recorded downloads can live (an external drive).
        return path.hasPrefix("/Volumes/") && components.count >= 4
    }

    func items(in category: UninstallItem.Category) -> [UninstallItem] {
        items.filter { $0.category == category }
    }

    /// Bytes on disk per category (folders are walked). Run off the main actor.
    func measuredSizes() -> [UninstallItem.Category: Int64] {
        var totals: [UninstallItem.Category: Int64] = [:]
        for item in items {
            totals[item.category, default: 0] += Self.allocatedSize(of: item.url)
        }
        return totals
    }

    static func allocatedSize(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        if values.isSymbolicLink == true { return 0 }
        guard values.isDirectory == true else { return Int64(values.totalFileAllocatedSize ?? 0) }
        var total: Int64 = 0
        let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: nil)
        while let child = walker?.nextObject() as? URL {
            total += Int64((try? child.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

/// The files CloudStream downloaded: each video, its subtitle sidecars, and
/// unfinished `.part` files with their resume record. Folders are never listed.
enum DownloadedFiles {
    static func files(for destinations: [URL], fileManager: FileManager = .default) -> [URL] {
        var files: [URL] = []
        for destination in destinations {
            let part = destination.appendingPathExtension("part")
            var related = [destination, part, DirectFileJob.metadataURL(forPart: part)]
            related += DownloadService.sidecarSubtitleFiles(for: destination)
            for url in related {
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
                files.append(url)
            }
        }
        return files
    }
}

/// Where the app bundle is, and whether it can be moved to the Trash.
struct InstalledAppLocation: Equatable, Sendable {
    enum Disposal: Equatable, Sendable {
        /// Moved to the Trash after the data is removed.
        case trash
        /// Run from a disk image, a translocated copy or a read-only folder:
        /// the person drags it to the Trash afterwards.
        case manual(reason: String)
    }

    let bundleURL: URL
    let disposal: Disposal

    static func evaluate(_ bundleURL: URL, fileManager: FileManager = .default) -> InstalledAppLocation {
        let path = bundleURL.standardizedFileURL.path
        func manual(_ reason: String) -> InstalledAppLocation { .init(bundleURL: bundleURL, disposal: .manual(reason: reason)) }
        guard bundleURL.pathExtension == "app" else { return manual("CloudStream isn’t running from an app bundle.") }
        if path.contains("/AppTranslocation/") {
            return manual("macOS is running CloudStream from a temporary copy. Drag CloudStream from Applications to the Trash afterwards.")
        }
        if (try? bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true {
            return manual("CloudStream is running from a disk image. Eject it and delete the disk image afterwards.")
        }
        guard fileManager.isWritableFile(atPath: bundleURL.deletingLastPathComponent().path) else {
            return manual("You don’t have permission to move CloudStream to the Trash. Drag it to the Trash in Finder afterwards.")
        }
        return .init(bundleURL: bundleURL, disposal: .trash)
    }
}

/// The detached helper that finishes the deletion after CloudStream exits.
/// Paths are passed as arguments, never pasted into the script text.
enum UninstallScript {
    /// argv: pid, preference domain ("" for none), then the paths to remove.
    static let source = #"""
    pid="$1"; domain="$2"; shift 2
    waited=0
    while kill -0 "$pid" 2>/dev/null; do
      waited=$((waited + 1))
      [ "$waited" -ge 6000 ] && exit 3
      sleep 0.1
    done
    if [ -n "$domain" ]; then
      /usr/bin/defaults delete "$domain" >/dev/null 2>&1
    fi
    status=0
    for path in "$@"; do
      case "$path" in
        /*) ;;
        *) continue ;;
      esac
      /bin/rm -rf -- "$path" || status=1
    done
    exit "$status"
    """#

    static func arguments(pid: Int32, preferenceDomain: String?, paths: [URL]) -> [String] {
        ["-c", source, "cloudstream-uninstall", String(pid), preferenceDomain ?? ""] + paths.map { $0.standardizedFileURL.path }
    }

    /// Starts the helper in its own session, so it outlives the app.
    @discardableResult
    static func launch(pid: Int32, preferenceDomain: String?, paths: [URL]) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = arguments(pid: pid, preferenceDomain: preferenceDomain, paths: paths)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.qualityOfService = .utility
        try process.run()
        return process
    }
}

/// Runs the deletion. The flow in `DeleteCloudStreamView` gathers consent;
/// this type only executes it.
@MainActor
final class Uninstaller {
    static let shared = Uninstaller()

    struct Options: Equatable, Sendable {
        var deleteDownloads = false
    }

    enum UninstallError: LocalizedError, Equatable {
        case locked
        case isolatedEnvironment
        case helperFailed(String)

        var errorDescription: String? {
            switch self {
            case .locked: "Unlock CloudStream before deleting it."
            case .isolatedEnvironment: "CloudStream can’t delete itself while running tests."
            case .helperFailed(let reason): "Nothing was deleted: CloudStream couldn’t start its cleanup helper (\(reason)). Quit and reopen CloudStream to keep using it."
            }
        }
    }

    static var bundleIdentifier: String { Bundle.main.bundleIdentifier ?? "com.lagradost.CloudStreamMac" }

    static var keychainServices: [String] { [ProviderCredentialStore.service, ProfileLockSecurity.service] }

    /// Recorded download destinations, read from the shared downloads store.
    func recordedDownloadDestinations(store: LibraryStore = .shared) -> [URL] {
        let records = store.readForDisplay(or: [], { try store.downloadRecords() })
        return records.map(\.destinationURL)
    }

    func footprint(options: Options, store: LibraryStore = .shared) -> UninstallFootprint {
        // Test and UI-test launches look only at their own private root.
        let home = AppEnvironment.root() ?? FileManager.default.homeDirectoryForCurrentUser
        let downloads = options.deleteDownloads ? DownloadedFiles.files(for: recordedDownloadDestinations(store: store)) : []
        return UninstallFootprint.scan(home: home, bundleIdentifier: Self.bundleIdentifier, downloadedFiles: downloads)
    }

    /// Irreversible from the Keychain step on. Never returns on success: the
    /// process exits once the helper is running.
    func perform(options: Options, store: LibraryStore = .shared) async throws {
        guard !AppEnvironment.isIsolated() else { throw UninstallError.isolatedEnvironment }
        guard !AppLock.shared.isLocked else { throw UninstallError.locked }
        DaemonLog.client("uninstall.started", fields: ["downloads": options.deleteDownloads ? "1" : "0"])

        // Read the downloads list while the store is still open.
        let footprint = footprint(options: options, store: store)
        let location = InstalledAppLocation.evaluate(Bundle.main.bundleURL)

        // 1. Stop everything that writes; progress is not saved (it is being deleted).
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            ApplicationShutdown.shared.begin(persistProgress: false) { continuation.resume() }
        }
        SoftwareUpdater.shared.cancelDownload()

        // 2. The helper removes the files once this process has exited. Started
        // before anything is deleted: if it can't start, nothing has been.
        do {
            try UninstallScript.launch(pid: ProcessInfo.processInfo.processIdentifier,
                                       preferenceDomain: Self.bundleIdentifier,
                                       paths: footprint.items.map(\.url))
        } catch {
            DaemonLog.client("uninstall.helper_failed", fields: ["error": error.localizedDescription])
            throw UninstallError.helperFailed(error.localizedDescription)
        }

        // 3. What only this process can remove.
        for service in Self.keychainServices {
            for account in GenericPasswordKeychain.accounts(service: service) {
                GenericPasswordKeychain.delete(service: service, account: account)
            }
        }
        try? await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [SpotlightIndexer.domain])
        let notifications = UNUserNotificationCenter.current()
        notifications.removeAllDeliveredNotifications()
        notifications.removeAllPendingNotificationRequests()

        // 4. The app itself. The binary stays mapped, so moving it is safe now
        // that nothing else will be loaded from the bundle.
        var leftover: String?
        switch location.disposal {
        case .trash:
            do { try FileManager.default.trashItem(at: location.bundleURL, resultingItemURL: nil) }
            catch { leftover = "CloudStream couldn’t move itself to the Trash (\(error.localizedDescription)). Drag it from \(location.bundleURL.deletingLastPathComponent().path) to the Trash to finish." }
        case .manual(let reason):
            leftover = reason
        }
        if let leftover {
            let alert = NSAlert()
            alert.messageText = "CloudStream removes its data when it quits"
            alert.informativeText = leftover
            alert.addButton(withTitle: "Quit")
            alert.runModal()
        }
        // Skip the normal quit path: it would save progress and preferences again.
        exit(0)
    }
}
