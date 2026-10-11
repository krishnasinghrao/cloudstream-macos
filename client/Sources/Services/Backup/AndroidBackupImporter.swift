import Foundation

/// Imports the CloudStream **Android** backup (Settings ▸ Backup on the phone)
/// into the Mac library — bookmarks with their watch status, favorites, and
/// Continue Watching positions (Offline-Features-Plan Phase 7).
///
/// Android layout (`BackupUtils.BackupFile`): `datastore._String` maps
/// `"<account>/<folder>/<id>"` to JSON strings:
/// * `result_watch_state_data/<id>` — `BookmarkedData` (name, url, apiName…)
/// * `result_watch_state/<id>` — watch status (Android ids: 0 watching,
///   1 completed, 2 on hold, 3 dropped, 4 plan to watch, 5 none)
/// * `result_favorites_state_data/<id>` — `FavoritesData`
/// * `result_resume_watching_2/<parentId>` — `{parentId, episodeId, episode, season, updateTime}`
/// * `video_pos_dur/<episodeId>` — `{position, duration}` in milliseconds
///
/// Android episode ids are app-internal hashes, so per-episode history can't
/// be mapped to provider episode data; the title-level resume position
/// (season/episode/position) is imported instead.
enum AndroidBackupImporter {
    enum ImportError: LocalizedError, Equatable {
        case notAnAndroidBackup
        case nothingToImport

        var errorDescription: String? {
            switch self {
            case .notAnAndroidBackup: return "This file isn't a CloudStream Android backup."
            case .nothingToImport: return "The Android backup contains no library entries."
            }
        }
    }

    /// Quick sniff used to route a chosen file to the right importer.
    static func looksLikeAndroidBackup(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let datastore = object["datastore"] as? [String: Any] else { return false }
        return datastore["_String"] != nil || datastore["_Int"] != nil || datastore["_Bool"] != nil
    }

    private struct Bookmark: Decodable {
        let name: String
        let url: String
        let apiName: String
        let type: String?
        let posterUrl: String?
        let latestUpdatedTime: Int64?
        let bookmarkedTime: Int64?
        let favoritesTime: Int64?
    }

    private struct Resume: Decodable {
        let parentId: Int?
        let episodeId: Int?
        let episode: Int?
        let season: Int?
        let updateTime: Int64?
    }

    private struct PosDur: Decodable {
        let position: Int64
        let duration: Int64
    }

    /// Android `WatchType.internalId` → macOS `WatchType`.
    static func watchType(androidID: Int) -> WatchType? {
        switch androidID {
        case 0: return .watching
        case 1: return .completed
        case 2: return .onHold
        case 3: return .dropped
        case 4: return .planToWatch
        default: return nil
        }
    }

    /// What importing found beyond the snapshot itself.
    struct Report: Equatable, Sendable {
        /// Android account numbers present in the file, ascending.
        var accounts: [Int] = []
        /// Titles whose accounts disagreed and no timestamp could order them.
        var unresolvedConflicts: [String] = []
        /// Titles whose accounts disagreed; the newer account's value was used.
        var resolvedConflicts = 0

        var warnings: [String] {
            var result: [String] = []
            if resolvedConflicts > 0 {
                result.append("\(resolvedConflicts) titles differed between Android accounts; the more recently changed entry was used.")
            }
            if !unresolvedConflicts.isEmpty {
                let names = unresolvedConflicts.prefix(3).joined(separator: ", ")
                let more = unresolvedConflicts.count > 3 ? " and \(unresolvedConflicts.count - 3) more" : ""
                result.append("\(unresolvedConflicts.count) titles differed between Android accounts without a usable date (\(names)\(more)); the lowest-numbered account’s entry was kept. Import a single account to choose another.")
            }
            return result
        }
    }

    /// Account numbers in an Android backup (for the import account choice).
    static func accounts(in data: Data) -> [Int] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let datastore = object["datastore"] as? [String: Any],
              let strings = datastore["_String"] as? [String: String] else { return [] }
        return Set(strings.keys.compactMap { key -> Int? in
            let parts = key.split(separator: "/", maxSplits: 2)
            return parts.count == 3 ? Int(parts[0]) : nil
        }).sorted()
    }

    static func snapshot(from data: Data, now: Date = Date()) throws -> LibraryStore.LibrarySnapshot {
        try plan(from: data, account: nil, now: now).snapshot
    }

    /// - Parameter account: one Android account, or nil for all of them (the
    ///   default, as before). Each account is converted on its own; titles that
    ///   appear in several are then merged with an explicit rule.
    static func plan(from data: Data, account: Int?, now: Date = Date()) throws -> (snapshot: LibraryStore.LibrarySnapshot, report: Report) {
        guard data.count <= BackupDocument.maxFileBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let datastore = object["datastore"] as? [String: Any] else {
            throw ImportError.notAnAndroidBackup
        }
        let strings = datastore["_String"] as? [String: String] ?? [:]
        let decoder = JSONDecoder()

        // "<account>/<folder>/<id>" → account → folder → id → value. The same
        // numeric id in two accounts is two different records.
        var byAccount: [Int: [String: [String: String]]] = [:]
        for (key, value) in strings {
            let parts = key.split(separator: "/", maxSplits: 2).map(String.init)
            guard parts.count == 3, let owner = Int(parts[0]) else { continue }
            byAccount[owner, default: [:]][parts[1], default: [:]][parts[2]] = value
        }
        var report = Report(accounts: byAccount.keys.sorted())

        func decode<T: Decodable>(_ type: T.Type, _ json: String?) -> T? {
            guard let json, let bytes = json.data(using: .utf8) else { return nil }
            return try? decoder.decode(T.self, from: bytes)
        }

        func date(_ millis: Int64?) -> Date? {
            guard let millis, millis > 0 else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
        }

        /// One account's view of a title, with the dates that can order it.
        struct Entry {
            var item: BackupDocument.Item
            var statusDate: Date?
            var resumeDate: Date?
        }

        func entries(for folders: [String: [String: String]]) -> [String: Entry] {
            var entries: [String: Entry] = [:]
            /// Android numeric id → macOS item id, within this account only.
            var byAndroidID: [String: String] = [:]

            func upsert(androidID: String, bookmark: Bookmark, watchType: WatchType?, favorite: Bool) {
                guard !bookmark.url.isEmpty, !bookmark.apiName.isEmpty else { return }
                let id = "\(bookmark.apiName)|\(bookmark.url)"
                byAndroidID[androidID] = id
                let known = date(bookmark.latestUpdatedTime) ?? date(bookmark.bookmarkedTime) ?? date(bookmark.favoritesTime)
                let changed = known ?? now
                let created = date(bookmark.bookmarkedTime) ?? date(bookmark.favoritesTime) ?? changed
                var entry = entries[id] ?? Entry(item: BackupDocument.Item(
                    id: id, title: bookmark.name, posterURL: bookmark.posterUrl, bannerURL: nil,
                    providerName: bookmark.apiName, providerURL: bookmark.url, mediaType: bookmark.type ?? "Others",
                    watchTypeRaw: -1, isFavorite: false, lastEpisodeData: nil, lastSeason: nil, lastEpisode: nil,
                    progressSeconds: 0, totalDurationSeconds: 0, lastUpdated: changed, createdAt: created,
                    knownEpisodeCount: nil, userNote: nil, userRating: nil,
                ))
                if let watchType { entry.item.watchTypeRaw = watchType.rawValue }
                if favorite { entry.item.isFavorite = true }
                if let known { entry.statusDate = max(entry.statusDate ?? known, known) }
                entry.item.lastUpdated = max(entry.item.lastUpdated, changed)
                entry.item.createdAt = min(entry.item.createdAt, created)
                entries[id] = entry
            }

            let statuses = folders["result_watch_state"] ?? [:]
            for (androidID, json) in (folders["result_watch_state_data"] ?? [:]).sorted(by: { $0.key < $1.key }) {
                guard let bookmark = decode(Bookmark.self, json) else { continue }
                let status = statuses[androidID].flatMap { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))) }
                upsert(androidID: androidID, bookmark: bookmark, watchType: status.flatMap(watchType(androidID:)), favorite: false)
            }
            for (androidID, json) in (folders["result_favorites_state_data"] ?? [:]).sorted(by: { $0.key < $1.key }) {
                guard let bookmark = decode(Bookmark.self, json) else { continue }
                upsert(androidID: androidID, bookmark: bookmark, watchType: nil, favorite: true)
            }

            let positions = folders["video_pos_dur"] ?? [:]
            for (parentID, json) in (folders["result_resume_watching_2"] ?? folders["result_resume_watching"] ?? [:]).sorted(by: { $0.key < $1.key }) {
                guard let resume = decode(Resume.self, json),
                      let itemID = byAndroidID[resume.parentId.map(String.init) ?? parentID],
                      var entry = entries[itemID] else { continue }
                entry.item.lastSeason = resume.season
                entry.item.lastEpisode = resume.episode
                if let episodeID = resume.episodeId, let pos = decode(PosDur.self, positions[String(episodeID)]) {
                    entry.item.progressSeconds = Double(max(0, pos.position)) / 1000
                    entry.item.totalDurationSeconds = Double(max(0, pos.duration)) / 1000
                }
                if let updated = date(resume.updateTime) {
                    entry.resumeDate = updated
                    entry.item.lastUpdated = max(entry.item.lastUpdated, updated)
                }
                entries[itemID] = entry
            }
            return entries
        }

        var merged: [String: Entry] = [:]
        var resolved = Set<String>(), unresolved = Set<String>()
        for owner in report.accounts where account == nil || account == owner {
            for (id, incoming) in entries(for: byAccount[owner] ?? [:]).sorted(by: { $0.key < $1.key }) {
                guard var current = merged[id] else { merged[id] = incoming; continue }
                // Favorites: a title any account favorited stays a favorite.
                current.item.isFavorite = current.item.isFavorite || incoming.item.isFavorite
                current.item.createdAt = min(current.item.createdAt, incoming.item.createdAt)
                current.item.lastUpdated = max(current.item.lastUpdated, incoming.item.lastUpdated)
                current.item.posterURL = current.item.posterURL ?? incoming.item.posterURL

                // List status: the more recently changed account wins.
                if incoming.item.watchTypeRaw != current.item.watchTypeRaw {
                    if current.item.watchTypeRaw < 0 {
                        current.item.watchTypeRaw = incoming.item.watchTypeRaw
                        current.statusDate = incoming.statusDate
                    } else if incoming.item.watchTypeRaw >= 0 {
                        if let theirs = incoming.statusDate, let ours = current.statusDate, theirs != ours {
                            if theirs > ours { current.item.watchTypeRaw = incoming.item.watchTypeRaw; current.statusDate = theirs }
                            resolved.insert(id)
                        } else { unresolved.insert(id) }
                    }
                }

                // Resume position: likewise, as one unit.
                let theirResume = (incoming.item.lastSeason, incoming.item.lastEpisode, incoming.item.progressSeconds)
                let ourResume = (current.item.lastSeason, current.item.lastEpisode, current.item.progressSeconds)
                let theyHave = incoming.resumeDate != nil || incoming.item.progressSeconds > 0 || incoming.item.lastEpisode != nil
                let weHave = current.resumeDate != nil || current.item.progressSeconds > 0 || current.item.lastEpisode != nil
                func takeResume() {
                    current.item.lastSeason = incoming.item.lastSeason
                    current.item.lastEpisode = incoming.item.lastEpisode
                    current.item.progressSeconds = incoming.item.progressSeconds
                    current.item.totalDurationSeconds = incoming.item.totalDurationSeconds
                    current.resumeDate = incoming.resumeDate
                }
                if theyHave, !weHave { takeResume() }
                else if theyHave, theirResume != ourResume {
                    if let theirs = incoming.resumeDate, let ours = current.resumeDate, theirs != ours {
                        if theirs > ours { takeResume() }
                        resolved.insert(id)
                    } else { unresolved.insert(id) }
                }
                merged[id] = current
            }
        }
        report.resolvedConflicts = resolved.subtracting(unresolved).count
        report.unresolvedConflicts = unresolved.compactMap { merged[$0]?.item.title }.sorted()

        guard !merged.isEmpty else { throw ImportError.nothingToImport }
        let snapshot = LibraryStore.LibrarySnapshot(
            items: merged.values.map(\.item).sorted { ($0.lastUpdated, $0.id) > ($1.lastUpdated, $1.id) },
            episodes: [],
            playback: [],
            formatVersion: 1,
        )
        return (snapshot, report)
    }
}
