//
//  DiscoveryLanes.swift
//  iOS-BLE-Library
//
//  Arccos (Wave C1, CU-868m1mrcy). Replaces the reply-driven queues in
//  ReactivePeripheralDelegate, which could only advance when CoreBluetooth answered:
//  a disconnect mid-discovery left the head operation in place forever and every later
//  request queued behind it, silently.
//

import Foundation

/// Serialises CoreBluetooth discovery requests and correlates their replies.
///
/// CoreBluetooth replies carry no request identity: `didDiscoverServices` answers whichever
/// `discoverServices` is outstanding, `didDiscoverCharacteristicsFor:` answers the outstanding
/// request for *that service*, and so on. Requests are therefore queued in lanes keyed by
/// whatever the reply does identify. Only the head of a lane is in flight; its reply completes
/// it and starts the next.
///
/// A lane never advances on its own, which is why ``failAll(with:)`` exists: when the
/// peripheral disconnects, or the caller gives up, every pending operation is failed so its
/// publisher terminates instead of hanging, and the lanes are left empty for the next request.
///
/// Thread-safe. Operation closures run outside the lock.
final class DiscoveryLanes<Key: Hashable> {

    struct Operation {
        let id: UUID
        let key: Key
        /// Issues the CoreBluetooth request. Runs once, when the operation reaches the head of
        /// its lane.
        let start: () -> Void
        /// Publishes a failure for this operation. Runs when the lane is drained.
        let fail: (Error) -> Void
    }

    private let lock = NSLock()
    private var lanes: [Key: [Operation]] = [:]
    /// Enqueue order across lanes, so ``failAll(with:)`` fails operations in the order they
    /// were requested.
    private var sequence: [UUID: Int] = [:]
    private var nextSequence = 0

    /// Queues `operation` and starts it now if nothing is in flight for its key.
    func enqueue(_ operation: Operation) {
        lock.lock()
        nextSequence += 1
        sequence[operation.id] = nextSequence
        lanes[operation.key, default: []].append(operation)
        let startsNow = lanes[operation.key]?.count == 1
        lock.unlock()

        if startsNow {
            operation.start()
        }
    }

    /// Records the CoreBluetooth reply for `key`: the in-flight operation is removed and the
    /// next one in the lane, if any, is started.
    ///
    /// - Returns: The completed operation's id, or `nil` when nothing was in flight for `key`.
    ///   That is an unsolicited reply, for example one arriving after ``failAll(with:)``
    ///   already failed the operation it belonged to; the caller should drop it.
    func complete(key: Key) -> UUID? {
        lock.lock()
        guard var lane = lanes[key], let done = lane.first else {
            lock.unlock()
            return nil
        }
        lane.removeFirst()
        sequence[done.id] = nil
        lanes[key] = lane.isEmpty ? nil : lane
        let next = lane.first
        lock.unlock()

        next?.start()
        return done.id
    }

    /// Removes an operation that is still queued, i.e. has not been issued to CoreBluetooth.
    ///
    /// An in-flight operation is left alone: its reply is still coming and must be attributed
    /// to it, not to its successor. The reply then completes it with nobody listening.
    ///
    /// - Returns: `true` if the operation was queued and has been removed.
    @discardableResult
    func removeIfQueued(id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        for (key, lane) in lanes {
            guard let index = lane.firstIndex(where: { $0.id == id }) else { continue }
            guard index > 0 else { return false }
            var lane = lane
            lane.remove(at: index)
            lanes[key] = lane
            sequence[id] = nil
            return true
        }
        return false
    }

    /// Fails every pending operation, in flight and queued, in the order they were enqueued,
    /// and empties the lanes. Replies arriving afterwards are unsolicited.
    ///
    /// - Returns: The number of operations failed.
    @discardableResult
    func failAll(with error: Error) -> Int {
        lock.lock()
        let pending = lanes.values
            .flatMap { $0 }
            .sorted { (sequence[$0.id] ?? 0) < (sequence[$1.id] ?? 0) }
        lanes.removeAll()
        sequence.removeAll()
        lock.unlock()

        pending.forEach { $0.fail(error) }
        return pending.count
    }

    /// Operations pending across all lanes, in flight plus queued.
    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return lanes.values.reduce(0) { $0 + $1.count }
    }

    var isEmpty: Bool { pendingCount == 0 }
}

/// Key for a discovery whose reply identifies nothing (service discovery): one lane per
/// peripheral.
struct SingleLane: Hashable {
    init() {}
}
