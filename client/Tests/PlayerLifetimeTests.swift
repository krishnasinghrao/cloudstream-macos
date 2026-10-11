import XCTest
@testable import CloudStream

@MainActor
final class PlayerLifetimeTests: XCTestCase {
    func testQueuedEventsAreInvalidatedBeforeMainActorDelivery() async {
        var deliveries = 0
        let sink = MpvEventSink(onProperty: { _, _ in deliveries += 1 },
                                onEndFile: { _ in }, onTracks: { _ in })
        let queue = DispatchQueue(label: "player-lifetime-fixture")
        // This test only exercises the core's queue/delivery/stop path; none
        // of those paths dereference or call mpv with the inert handle.
        let core = MpvCore(handle: OpaquePointer(bitPattern: 1)!, queue: queue, sink: sink)
        queue.sync {
            core.deliver { $0.onProperty?("time-pos", .double(1)) }
            core.stop()
            core.deliver { $0.onProperty?("time-pos", .double(2)) }
        }
        let drained = expectation(description: "main delivery queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
        XCTAssertEqual(deliveries, 0)
        XCTAssertFalse(sink.acceptsEvents)
        XCTAssertNil(sink.onProperty)
    }

    func testConcurrentInvalidationDoesNotMutateActorOwnedHandlers() {
        let sink = MpvEventSink(onProperty: { _, _ in }, onEndFile: { _ in }, onTracks: { _ in })
        DispatchQueue.concurrentPerform(iterations: 500) { _ in
            sink.invalidate()
            XCTAssertFalse(sink.acceptsEvents)
        }
        XCTAssertNotNil(sink.onProperty, "the cross-thread fence must not clear actor-owned closures")
        sink.clear()
        XCTAssertNil(sink.onProperty)
    }
}
