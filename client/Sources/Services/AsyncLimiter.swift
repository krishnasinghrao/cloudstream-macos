import Foundation

/// Bounds how many callers run at once; the rest wait in arrival order.
actor AsyncLimiter {
    private let limit: Int
    private var inUse = 0
    private var waiting: [(id: UUID, cost: Int, continuation: CheckedContinuation<Bool, Never>)] = []
    private(set) var peak = 0

    init(limit: Int) { self.limit = max(1, limit) }

    /// Runs `operation` once `cost` units are free, first come first served.
    /// A cost above the limit is treated as the whole limit, so one oversized
    /// job runs alone instead of never.
    /// A caller cancelled while it waits throws `CancellationError` and never runs.
    func run<T: Sendable>(cost: Int = 1, _ operation: @Sendable () async throws -> T) async throws -> T {
        let cost = min(max(1, cost), limit)
        let id = UUID()
        var admitted = false
        if !waiting.isEmpty || inUse + cost > limit {
            admitted = await withTaskCancellationHandler {
                await withCheckedContinuation { cont in
                    waiting.append((id, cost, cont))
                }
            } onCancel: {
                Task { [weak self] in
                    await self?.cancelWait(id: id)
                }
            }
        } else {
            inUse += cost
            admitted = true
        }
        guard admitted else { throw CancellationError() }
        peak = max(peak, inUse)
        defer { release(cost) }
        return try await operation()
    }

    private func cancelWait(id: UUID) {
        if let index = waiting.firstIndex(where: { $0.id == id }) {
            let item = waiting.remove(at: index)
            item.continuation.resume(returning: false)
            drain()
        }
    }

    private func release(_ cost: Int) {
        inUse -= cost
        drain()
    }

    private func drain() {
        while let next = waiting.first, inUse + next.cost <= limit {
            waiting.removeFirst()
            inUse += next.cost
            next.continuation.resume(returning: true)
        }
    }
}
