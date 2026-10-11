import Foundation
import Network

/// System network reachability (Offline-Features-Plan Phase 3).
///
/// Drives the offline banner and pauses/resumes the download queue. Path
/// updates are debounced: Wi-Fi hand-offs and VPN reconnects flap the path
/// for a fraction of a second, and pausing a whole season's downloads for
/// that would cost more than it saves.
@MainActor
@Observable
final class ConnectivityMonitor {
    static let shared = ConnectivityMonitor()

    private(set) var isOnline = true
    private(set) var isExpensive = false
    private(set) var isConstrained = false

    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var pendingChange: Task<Void, Never>?
    @ObservationIgnored private var started = false

    /// Offline must persist this long before the app reacts.
    static let offlineDebounce: Duration = .seconds(2)

    func start() {
        guard !started else { return }
        started = true
        let monitor = NWPathMonitor()
        self.monitor = monitor
        let current = UUID()
        generation = current
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let expensive = path.isExpensive
            let constrained = path.isConstrained
            Task { @MainActor in
                guard let self, self.started, self.generation == current else { return }
                self.handle(online: online, expensive: expensive, constrained: constrained)
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.lagradost.cloudstream.connectivity", qos: .utility))
    }

    func stop() {
        started = false
        generation = UUID()
        pendingChange?.cancel()
        pendingChange = nil
        monitor?.cancel()
        monitor = nil
    }

    /// Internal for tests: feeds a path update through the debounce logic.
    func handle(online: Bool, expensive: Bool, constrained: Bool, debounce: Duration = ConnectivityMonitor.offlineDebounce) {
        isExpensive = expensive
        isConstrained = constrained
        pendingChange?.cancel()
        guard online != isOnline else { return }
        if online {
            // Coming back is applied at once — no reason to make users wait.
            apply(online: true)
        } else {
            pendingChange = Task { [weak self] in
                try? await Task.sleep(for: debounce)
                guard !Task.isCancelled else { return }
                self?.apply(online: false)
            }
        }
    }

    private func apply(online: Bool) {
        guard online != isOnline else { return }
        isOnline = online
        DaemonLog.client("network.path_changed", fields: ["online": String(online)])
        if online {
            DownloadService.shared.resumeAfterNetworkReturn()
        } else {
            DownloadService.shared.suspendForNetworkLoss()
        }
    }
}
