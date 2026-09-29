//
//  DiscoveryLanesTests.swift
//
//  Arccos (Wave C1): the queue that replaces the peripheral delegate's reply-driven queues.
//  Pure unit tests, no CoreBluetoothMock involved.
//

import XCTest

@testable import iOS_BLE_Library_Mock

final class DiscoveryLanesTests: XCTestCase {

    private struct Failure: Error {}

    /// An operation whose `start` and `fail` record "start <name>" / "fail <name>" into `log`.
    private func operation(
        _ name: String, key: String, log: EventBox<String>
    ) -> DiscoveryLanes<String>.Operation {
        DiscoveryLanes<String>.Operation(
            id: UUID(),
            key: key,
            start: { log.append("start \(name)") },
            fail: { _ in log.append("fail \(name)") })
    }

    func testFirstOperationInALaneStartsImmediatelyAndTheRestWait() {
        let lanes = DiscoveryLanes<String>()
        let log = EventBox<String>()

        lanes.enqueue(operation("a", key: "svc", log: log))
        lanes.enqueue(operation("b", key: "svc", log: log))

        XCTAssertEqual(log.values, ["start a"])
        XCTAssertEqual(lanes.pendingCount, 2)
    }

    func testReplyCompletesTheHeadAndStartsTheNext() {
        let lanes = DiscoveryLanes<String>()
        let log = EventBox<String>()
        let a = operation("a", key: "svc", log: log)
        let b = operation("b", key: "svc", log: log)
        lanes.enqueue(a)
        lanes.enqueue(b)

        XCTAssertEqual(lanes.complete(key: "svc"), a.id)
        XCTAssertEqual(log.values, ["start a", "start b"])
        XCTAssertEqual(lanes.complete(key: "svc"), b.id)
        XCTAssertNil(lanes.complete(key: "svc"))
        XCTAssertTrue(lanes.isEmpty)
    }

    func testLanesWithDifferentKeysRunConcurrently() {
        let lanes = DiscoveryLanes<String>()
        let log = EventBox<String>()
        let a = operation("a", key: "svc1", log: log)
        let b = operation("b", key: "svc2", log: log)
        lanes.enqueue(a)
        lanes.enqueue(b)

        XCTAssertEqual(log.values, ["start a", "start b"])
        XCTAssertEqual(lanes.complete(key: "svc2"), b.id, "a reply is matched by key, not by arrival order")
        XCTAssertEqual(lanes.complete(key: "svc1"), a.id)
    }

    func testUnsolicitedReplyIsReportedAsNil() {
        let lanes = DiscoveryLanes<String>()
        XCTAssertNil(lanes.complete(key: "svc"))
    }

    func testFailAllFailsEverythingInEnqueueOrderAndEmptiesTheLanes() {
        let lanes = DiscoveryLanes<String>()
        let log = EventBox<String>()
        lanes.enqueue(operation("a", key: "svc1", log: log))
        lanes.enqueue(operation("b", key: "svc2", log: log))
        lanes.enqueue(operation("c", key: "svc1", log: log))

        XCTAssertEqual(lanes.failAll(with: Failure()), 3)

        XCTAssertEqual(log.values, ["start a", "start b", "fail a", "fail b", "fail c"])
        XCTAssertTrue(lanes.isEmpty)
        XCTAssertNil(lanes.complete(key: "svc1"), "a reply after failAll is unsolicited")
        XCTAssertEqual(lanes.failAll(with: Failure()), 0)
    }

    func testRemoveIfQueuedRemovesOnlyOperationsNotYetIssued() {
        let lanes = DiscoveryLanes<String>()
        let log = EventBox<String>()
        let a = operation("a", key: "svc", log: log)
        let b = operation("b", key: "svc", log: log)
        lanes.enqueue(a)
        lanes.enqueue(b)

        XCTAssertFalse(lanes.removeIfQueued(id: a.id), "the in-flight operation owns the coming reply")
        XCTAssertTrue(lanes.removeIfQueued(id: b.id))
        XCTAssertFalse(lanes.removeIfQueued(id: b.id))
        XCTAssertEqual(lanes.pendingCount, 1)

        XCTAssertEqual(lanes.complete(key: "svc"), a.id)
        XCTAssertEqual(log.values, ["start a"], "the removed operation must never be issued")
    }
}
