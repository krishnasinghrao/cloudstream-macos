import Foundation

/// One idempotent path for normal quit and signals. Ordinary quit confirms
/// download interruption/save failure before entering this irreversible phase.
@MainActor
final class ApplicationShutdown {
    static let shared = ApplicationShutdown(persist: {
        AppState.shared.player.close()
        try LibraryStore.shared.flushPendingProgress()
    }, quiesce: {
        DownloadService.shared.prepareForTermination()
        AppState.shared.stopApplicationTasks()
        EpisodeUpdateChecker.shared.stop()
        BackupService.shared.stopScheduling()
        ConnectivityMonitor.shared.stop()
    }, terminate: { completion in DaemonSupervisor.shared.stop(completion: completion) })

    private enum State { case idle, stopping, finished }
    private var state = State.idle
    private var completions: [@MainActor @Sendable () -> Void] = []
    private let persist: @MainActor () throws -> Void
    private let quiesce: @MainActor () -> Void
    private let terminate: @MainActor (@escaping @Sendable () -> Void) -> Void
    private(set) var persistenceError: String?

    init(persist: @escaping @MainActor () throws -> Void,
         quiesce: @escaping @MainActor () -> Void,
         terminate: @escaping @MainActor (@escaping @Sendable () -> Void) -> Void) {
        self.persist = persist; self.quiesce = quiesce; self.terminate = terminate
    }

    func begin(persistProgress: Bool = true, completion: @escaping @MainActor @Sendable () -> Void = {}) {
        if state == .finished { completion(); return }
        completions.append(completion)
        guard state == .idle else { return }
        state = .stopping
        if persistProgress {
            do { try persist() }
            catch {
                persistenceError = error.localizedDescription
                DaemonLog.client("store.shutdown_flush_failed", fields: ["error": error.localizedDescription])
            }
        }
        quiesce()
        terminate { [weak self] in Task { @MainActor in self?.finish() } }
    }

    private func finish() {
        guard state == .stopping else { return }
        state = .finished
        let callbacks = completions
        completions.removeAll()
        callbacks.forEach { $0() }
    }
}
