import Foundation
import UserNotifications

/// New-episode checks for titles on the Watching list (Offline-Features-Plan
/// Phase 6). Uses only the installed providers — no tracker API. Runs a small
/// batch at a time, sequentially and spaced out, so a large library never
/// hammers a provider; the daemon's details cache absorbs repeats.
@MainActor
final class EpisodeUpdateChecker {
    static let shared = EpisodeUpdateChecker()

    /// A title is re-checked at most this often.
    static let recheckInterval: TimeInterval = 6 * 60 * 60
    /// Titles per run and the pause between provider requests.
    static let batchSize = 12
    static let spacing: Duration = .seconds(3)
    /// First run after launch waits for the engine and the user's first clicks.
    static let launchDelay: Duration = .seconds(90)
    static let runInterval: Duration = .seconds(60 * 60)

    private let library: LibraryStore
    private let preferences: UserPreferences
    private let loadDetails: @MainActor (String, String) async throws -> DetailsDto
    private let authorization: @MainActor () -> UInt64?
    private let spacingDuration: Duration
    private let requestNotificationAuthorization: @MainActor () async -> Bool
    private let deliverNotification: @MainActor (UNNotificationRequest) async throws -> Void
    private var loop: Task<Void, Never>?
    private var run: Task<Void, Never>?
    var isRunning: Bool { run != nil }

    init(library: LibraryStore = .shared, preferences: UserPreferences = .shared,
         spacing: Duration = EpisodeUpdateChecker.spacing,
         authorization: @escaping @MainActor () -> UInt64? = {
             AppLock.shared.isLocked ? nil : AppLock.shared.generation
         },
         loadDetails: @escaping @MainActor (String, String) async throws -> DetailsDto = {
             try await DaemonClient.shared.details(provider: $0, url: $1)
         },
         requestNotificationAuthorization: @escaping @MainActor () async -> Bool = {
             (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) == true
         },
         deliverNotification: @escaping @MainActor (UNNotificationRequest) async throws -> Void = {
             try await UNUserNotificationCenter.current().add($0)
         }) {
        self.library = library
        self.preferences = preferences
        self.spacingDuration = spacing
        self.authorization = authorization
        self.loadDetails = loadDetails
        self.requestNotificationAuthorization = requestNotificationAuthorization
        self.deliverNotification = deliverNotification
    }

    func start(appState: AppState) {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            do { try await Task.sleep(for: Self.launchDelay) } catch { return }
            while !Task.isCancelled {
                await self?.runOnce(appState: appState)
                do { try await Task.sleep(for: Self.runInterval) } catch { return }
            }
        }
    }

    func cancelCurrentRun() { run?.cancel() }

    func stop() {
        loop?.cancel()
        loop = nil
        cancelCurrentRun()
    }

    /// One batch. Provider-dependent work requires restored, usable providers.
    func runOnce(appState: AppState) async {
        await runOnce(canCheck: { appState.isEngineBootstrapped && ConnectivityMonitor.shared.isOnline },
                      engineGeneration: { appState.connection.generation },
                      reportError: { appState.presentError($0) })
    }

    /// The task belongs to the checker, including manual checks. Value snapshots
    /// and a captured store/lock/engine generation fence every suspension.
    func runOnce(canCheck: @escaping @MainActor () -> Bool, engineGeneration: @escaping @MainActor () -> UInt64,
                 reportError: @escaping @MainActor (String) -> Void) async {
        guard preferences.checkForNewEpisodes, run == nil, canCheck(),
              let lockGeneration = authorization() else { return }
        let owner: LibraryStore.ProfileOperationContext
        let due: [Candidate]
        do {
            owner = try library.captureProfileOperation()
            due = try library.titlesDueForEpisodeCheck(olderThan: Self.recheckInterval, limit: Self.batchSize)
                .map { Candidate(id: $0.id, title: $0.title, provider: $0.providerKey, url: $0.providerURL) }
        } catch { reportError("Couldn’t read the library: \(error.localizedDescription)"); return }
        let engine = engineGeneration()
        let current = {
            !Task.isCancelled && self.library.owns(owner) && self.authorization() == lockGeneration
                && canCheck() && engineGeneration() == engine && self.preferences.checkForNewEpisodes
        }
        let task = Task {
            var found: [(title: String, count: Int)] = []
            for (index, item) in due.enumerated() {
                guard current() else { return }
                if index > 0 {
                    do { try await Task.sleep(for: self.spacingDuration) } catch { return }
                    guard current() else { return }
                }
                let details: DetailsDto
                do { details = try await self.loadDetails(item.provider, item.url) }
                catch {
                    guard current() else { return }
                    try? self.library.recordEpisodeCheckAttempt(itemID: item.id)
                    continue
                }
                guard current() else { return }
                do {
                    // A returned provider payload cannot redirect the check to
                    // a different title. Resolve only the captured durable row.
                    let added = try self.library.recordEpisodeCheck(details: details, itemID: item.id)
                    if added > 0 { found.append((item.title, added)) }
                } catch { reportError("Couldn’t save the episode check: \(error.localizedDescription)") }
            }
            guard current(), !found.isEmpty else { return }
            DaemonLog.client("episodes.new_found", fields: ["titles": String(found.count)])
            if self.preferences.notifyNewEpisodes { await self.notify(found, isCurrent: current) }
        }
        run = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        run = nil
    }

    private struct Candidate {
        let id: String
        let title: String
        let provider: String
        let url: String
    }

    private func notify(_ found: [(title: String, count: Int)], isCurrent: () -> Bool) async {
        let content = UNMutableNotificationContent()
        if found.count == 1, let only = found.first {
            content.title = only.title
            content.body = only.count == 1 ? "A new episode is available." : "\(only.count) new episodes are available."
        } else {
            content.title = "New episodes"
            content.body = found.prefix(3).map { "\($0.title) (+\($0.count))" }.joined(separator: ", ")
                + (found.count > 3 ? " and \(found.count - 3) more" : "")
        }
        content.sound = .default
        let request = UNNotificationRequest(identifier: "new-episodes-\(UUID().uuidString)", content: content, trigger: nil)
        guard await requestNotificationAuthorization(), isCurrent(), preferences.notifyNewEpisodes else { return }
        do {
            try await deliverNotification(request)
            if !isCurrent() {
                let center = UNUserNotificationCenter.current()
                center.removePendingNotificationRequests(withIdentifiers: [request.identifier])
                center.removeDeliveredNotifications(withIdentifiers: [request.identifier])
            }
        } catch {
            if isCurrent() { DaemonLog.client("episodes.notification_failed") }
        }
    }
}
