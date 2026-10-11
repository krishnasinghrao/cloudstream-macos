import XCTest
@testable import CloudStream

@MainActor
final class ApplicationShutdownTests: XCTestCase {
    func testRepeatedRequestsShareOneOrderedShutdownAndCompleteAfterExit() async {
        var events: [String] = []
        var exited: (@Sendable () -> Void)?
        let shutdown = ApplicationShutdown(persist: { events.append("persist") },
            quiesce: { events.append("quiesce") }, terminate: { completion in
                events.append("terminate")
                exited = completion
            })
        let first = expectation(description: "first caller")
        let second = expectation(description: "second caller")
        shutdown.begin { first.fulfill() }
        shutdown.begin { second.fulfill() }
        XCTAssertEqual(events, ["persist", "quiesce", "terminate"])
        exited?()
        await fulfillment(of: [first, second], timeout: 2)
        let later = expectation(description: "already stopped")
        shutdown.begin { later.fulfill() }
        await fulfillment(of: [later], timeout: 2)
        XCTAssertEqual(events, ["persist", "quiesce", "terminate"])
    }

    func testFailedSignalFlushStillQuiescesAndStopsWithVisibleError() async {
        var quiesced = false
        let shutdown = ApplicationShutdown(persist: {
            throw NSError(domain: "fixture", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Fixture disk unavailable"])
        }, quiesce: { quiesced = true }, terminate: { $0() })
        let finished = expectation(description: "terminated despite save failure")
        shutdown.begin { finished.fulfill() }
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertTrue(quiesced)
        XCTAssertEqual(shutdown.persistenceError, "Fixture disk unavailable")
    }

    func testConfirmedOrdinaryQuitDoesNotRepeatItsCompletedFlush() async {
        var flushes = 0
        let shutdown = ApplicationShutdown(persist: { flushes += 1 },
            quiesce: {}, terminate: { $0() })
        let finished = expectation(description: "ordinary quit")
        shutdown.begin(persistProgress: false) { finished.fulfill() }
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(flushes, 0)
        XCTAssertNil(shutdown.persistenceError)
    }
}
