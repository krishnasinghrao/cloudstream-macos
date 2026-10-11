import Foundation

/// Immutable dry-run input/output. No display-name collision can silently
/// select an installation or merge durable rows.
enum LibraryIdentityMigration {
    struct Provider: Sendable, Hashable { let id: String; let name: String }
    struct Item: Sendable {
        let id: String
        let providerID: String?
        let providerName: String
        let url: String
        let isDownload: Bool
    }
    struct Change: Sendable, Equatable {
        let oldID: String
        let newID: String
        let providerID: String
    }
    struct Download: Sendable { let id: UUID; let path: String }
    struct LocalChange: Sendable, Equatable {
        let oldID: String
        let newID: String
        let downloadID: UUID
    }
    struct Report: Sendable {
        var localChanges: [LocalChange] = []
        var changes: [Change] = []
        var unresolved: [String: String] = [:]
        var conflicts: [String] = []
        var recoverySnapshot: URL?
        var canApply: Bool { conflicts.isEmpty }
    }

    static func catalog(plugins: [PluginDto]) -> [Provider] {
        plugins.flatMap { plugin in
            guard let ids = plugin.providerIds, ids.count == plugin.providers.count else { return [Provider]() }
            return zip(ids, plugin.providers).map { Provider(id: $0.0, name: $0.1) }
        }
    }

    static func plan(items: [Item], providers: [Provider], assignments: [String: Provider] = [:], downloads: [Download] = []) -> Report {
        var report = Report()
        var owners: [String: String] = [:]
        for item in items.sorted(by: { $0.id < $1.id }) where !item.isDownload {
            let providerID: String
            if let selected = assignments[item.id] { providerID = selected.id }
            else if let known = item.providerID, !known.isEmpty { providerID = known }
            else {
                let candidates = Set(providers.filter { $0.name == item.providerName && !$0.id.isEmpty }.map(\.id))
                guard candidates.count == 1, let candidate = candidates.first else {
                    report.unresolved[item.id] = candidates.isEmpty ? "Provider unavailable" : "Multiple providers have this name"
                    continue
                }
                providerID = candidate
            }
            let newID = LibraryIdentity.remote(providerID: providerID, url: item.url)
            if let owner = owners[newID], owner != item.id {
                report.conflicts.append("Two stored titles resolve to the same provider identity.")
            } else { owners[newID] = item.id }
            if (assignments.isEmpty || assignments[item.id] != nil),
               newID != item.id || item.providerID != providerID {
                report.changes.append(.init(oldID: item.id, newID: newID, providerID: providerID))
            }
        }
        // A path is only legacy evidence, not durable identity. Never guess
        // when two shared records claim it. Explicit remote reassignment does
        // not also migrate unrelated local rows.
        if assignments.isEmpty {
            var localOwners: [UUID: String] = [:]
            for item in items.sorted(by: { $0.id < $1.id }) where item.isDownload {
                let candidates = Set(downloads.filter { $0.path == item.url }.map(\.id))
                let known = LibraryIdentity.downloadID(from: item.id)
                guard let downloadID = known ?? (candidates.count == 1 ? candidates.first : nil) else {
                    report.unresolved[item.id] = candidates.isEmpty ? "Download record unavailable" : "Multiple downloads have this path"
                    continue
                }
                if let owner = localOwners[downloadID], owner != item.id {
                    report.conflicts.append("Two local titles resolve to the same download identity.")
                } else { localOwners[downloadID] = item.id }
                let newID = LibraryIdentity.localDownload(downloadID)
                if newID != item.id { report.localChanges.append(.init(oldID: item.id, newID: newID, downloadID: downloadID)) }
            }
        }
        return report
    }
}
