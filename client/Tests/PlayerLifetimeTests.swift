import XCTest
@testable import CloudStream

@MainActor
final class PlayerLifetimeTests: XCTestCase {
    func testReplacementLoadRejectsQueuedOutgoingFileEvents() async {
        var deliveries = 0
        var replies = 0
        let sink = MpvEventSink(onProperty: { _, _ in deliveries += 1 },
                                onEndFile: { _ in deliveries += 1 }, onTracks: { _ in deliveries += 1 },
                                onFileLoaded: { deliveries += 1 }, onPlaybackRestart: { deliveries += 1 },
                                onCommandReply: { _, _ in replies += 1 })
        let queue = DispatchQueue(label: "player-load-fixture")
        let core = MpvCore(handle: OpaquePointer(bitPattern: 1)!, queue: queue, sink: sink)
        queue.sync {
            core.deliver { $0.onProperty?("eof-reached", .flag(1)) }
            core.deliver { $0.onEndFile?(.error) }
            core.deliver { $0.onFileLoaded?() }
            core.deliver { $0.onPlaybackRestart?() }
            // What the user asked for by name outlives the file it was taken from.
            core.deliver(scopedToLoad: false) { $0.onCommandReply?(MpvCommandReply.tag(.screenshot, sequence: 1), nil) }
        }
        // The model moved on to another file before the main queue ran.
        let generation = sink.beginLoad()
        let drained = expectation(description: "outgoing deliveries drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
        XCTAssertEqual(deliveries, 0, "a replaced file's error or restart must not be taken for the new file's")
        XCTAssertEqual(replies, 1)
        XCTAssertTrue(sink.isCurrentLoad(generation))
        XCTAssertTrue(sink.acceptsEvents, "replacing a file must leave the engine alive")
    }

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
