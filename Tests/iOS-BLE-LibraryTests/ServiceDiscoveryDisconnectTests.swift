//
//  ServiceDiscoveryDisconnectTests.swift
//
//  Arccos: the "connects but never becomes usable" family (review finding i10,
//  Wave C1 / CU-868m1mrcy).
//
//  A disconnect, or the caller giving up, must fail every pending discovery operation on
//  the peripheral promptly, and the next request must reach CoreBluetooth. These are the
//  card's acceptance tests plus the correlation cases the fix rests on.
//

import Combine
import CoreBluetoothMock
import XCTest

@testable import iOS_BLE_Library_Mock

final class ServiceDiscoveryDisconnectTests: CentralManagerTestCase {

    private static let serviceUUIDs = ["1810", "1811", "1812", "1813"].map { CBMUUID(string: $0) }

    /// Four services at a 0.5 s connection interval: the mock answers service discovery
    /// after `interval × count` = 2 s, which leaves room to act mid-discovery.
    private func makeSlowLink() -> SimulatedPeripheral {
        SimulatedPeripheral(
            name: "Link",
            services: Self.serviceUUIDs.map { .primary($0) },
            connectionInterval: 0.5)
    }

    private func characteristics(_ uuids: [String]) -> [CBMCharacteristicMock] {
        uuids.map { CBMCharacteristicMock(type: CBMUUID(string: $0), properties: .read) }
    }

    /// Connects `device` and starts service discovery; returns once the mock has received the
    /// request, with the discovery still pending.
    private func startSlowServiceDiscovery(
        _ device: SimulatedPeripheral,
        on central: CentralManager,
        connectOptions: [String: Any]? = nil
    ) async throws -> (Peripheral, Task<[CBService], Error>) {
        let cbPeripheral = try await discover(device, on: central)
        try await connect(cbPeripheral, on: central, options: connectOptions)
        let peripheral = Peripheral(peripheral: cbPeripheral)

        let requestSeen = expectation(description: "mock received the service discovery request")
        device.onServiceDiscoveryRequest = { _ in requestSeen.fulfill() }
        let discovery = Task { try await peripheral.discoverServices(serviceUUIDs: nil).firstValue }
        await fulfillment(of: [requestSeen], timeout: 2)
        device.onServiceDiscoveryRequest = nil

        return (peripheral, discovery)
    }

    /// Connects `device`, wraps it, and discovers its first service.
    private func connectAndDiscoverFirstService(
        _ device: SimulatedPeripheral,
        on central: CentralManager
    ) async throws -> (Peripheral, CBService) {
        let cbPeripheral = try await discover(device, on: central)
        try await connect(cbPeripheral, on: central)
        let peripheral = Peripheral(peripheral: cbPeripheral)
        let services = try await withTimeout(3, "discoverServices") {
            try await peripheral.discoverServices(serviceUUIDs: nil).firstValue
        }
        return (peripheral, try XCTUnwrap(services.first))
    }

    /// A service with one characteristic carrying four descriptors, so descriptor discovery
    /// takes `connectionInterval × 4` in the mock.
    private static let descriptorUUIDs = ["2900", "2901", "2902", "2904"]

    private func makeDescriptorLink(connectionInterval: TimeInterval) -> SimulatedPeripheral {
        let descriptors = Self.descriptorUUIDs.map { CBMDescriptorMock(type: CBMUUID(string: $0)) }
        let characteristic = CBMCharacteristicMock(
            type: CBMUUID(string: "2A19"), properties: .read,
            descriptors: descriptors[0], descriptors[1], descriptors[2], descriptors[3])
        let service = CBMServiceMock.primary(CBMUUID(string: "180F"), characteristics: [characteristic])
        return SimulatedPeripheral(name: "Link", services: [service], connectionInterval: connectionInterval)
    }

    private func dropLink(
        _ device: SimulatedPeripheral,
        _ peripheral: Peripheral,
        on central: CentralManager
    ) async {
        let dropped = expectDisconnect(of: peripheral.peripheral.identifier, on: central)
        device.spec.simulateDisconnection(withError: CBMError(.peripheralDisconnected))
        await fulfillment(of: [dropped], timeout: 3)
    }

    private func assertFailed<T>(
        _ result: Result<T, Error>,
        withCBErrorCode code: CBError.Code,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch result {
        case .success:
            XCTFail("expected a failure with CBError.\(code), got a value", file: file, line: line)
        case .failure(let error as TimeoutError):
            XCTFail("hung: \(error)", file: file, line: line)
        case .failure(let error):
            XCTAssertEqual((error as? CBError)?.code, code, "unexpected error: \(error)", file: file, line: line)
        }
    }

    // MARK: Disconnect fails pending operations (C1 acceptance)

    func testDisconnectDuringServiceDiscoveryFailsThePendingOperation() async throws {
        let link = makeSlowLink()
        let central = try makeCentral(peripherals: [link])
        let (peripheral, discovery) = try await startSlowServiceDiscovery(link, on: central)

        await dropLink(link, peripheral, on: central)

        let result = await outcome {
            try await withTimeout(1, "discoverServices after disconnect") { try await discovery.value }
        }
        assertFailed(result, withCBErrorCode: .peripheralDisconnected)
        XCTAssertTrue(peripheral.peripheralDelegate.serviceDiscovery.isEmpty)
        XCTAssertEqual(
            peripheral.peripheralDelegate.peripheralIdentifier, peripheral.peripheral.identifier,
            "the delegate labels its log lines with the peripheral it is attached to")
    }

    func testDisconnectDuringCharacteristicDiscoveryFailsThePendingOperation() async throws {
        let service = CBMServiceMock.primary(
            CBMUUID(string: "1810"), characteristics: characteristics(["2A00", "2A01", "2A02", "2A03"]))
        let link = SimulatedPeripheral(name: "Link", services: [service], connectionInterval: 0.5)
        let central = try makeCentral(peripherals: [link])
        let cbPeripheral = try await discover(link, on: central)
        try await connect(cbPeripheral, on: central)
        let peripheral = Peripheral(peripheral: cbPeripheral)
        let services = try await withTimeout(3, "discoverServices") {
            try await peripheral.discoverServices(serviceUUIDs: nil).firstValue
        }
        let cbService = try XCTUnwrap(services.first)

        let requestSeen = expectation(description: "mock received the characteristic discovery request")
        link.onCharacteristicDiscoveryRequest = { _, _ in requestSeen.fulfill() }
        let discovery = Task { try await peripheral.discoverCharacteristics(nil, for: cbService).firstValue }
        await fulfillment(of: [requestSeen], timeout: 2)
        link.onCharacteristicDiscoveryRequest = nil

        await dropLink(link, peripheral, on: central)

        let result = await outcome {
            try await withTimeout(1, "discoverCharacteristics after disconnect") { try await discovery.value }
        }
        assertFailed(result, withCBErrorCode: .peripheralDisconnected)
        XCTAssertTrue(peripheral.peripheralDelegate.characteristicDiscovery.isEmpty)
    }

    func testDisconnectFailsQueuedOperationsBehindTheInFlightOne() async throws {
        let link = makeSlowLink()
        let central = try makeCentral(peripherals: [link])
        let (peripheral, first) = try await startSlowServiceDiscovery(link, on: central)

        let second = Task { try await peripheral.discoverServices(serviceUUIDs: nil).firstValue }
        try await waitUntil(1, "second discovery queued") {
            peripheral.peripheralDelegate.serviceDiscovery.pendingCount == 2
        }
        XCTAssertEqual(link.serviceDiscoveryRequests, 1, "the second request waits behind the in-flight one")

        await dropLink(link, peripheral, on: central)

        let firstResult = await outcome { try await withTimeout(1, "first discovery") { try await first.value } }
        let secondResult = await outcome { try await withTimeout(1, "second discovery") { try await second.value } }
        assertFailed(firstResult, withCBErrorCode: .peripheralDisconnected)
        assertFailed(secondResult, withCBErrorCode: .peripheralDisconnected)
        XCTAssertEqual(link.serviceDiscoveryRequests, 1, "a queued request is never issued to a disconnected peripheral")
    }

    // MARK: The next request is not stuck behind the failed one

    func testDiscoveryAfterReconnectStartsFreshAndSucceeds() async throws {
        let link = makeSlowLink()
        let central = try makeCentral(peripherals: [link])
        let (peripheral, discovery) = try await startSlowServiceDiscovery(link, on: central)

        await dropLink(link, peripheral, on: central)
        _ = await outcome { try await withTimeout(1, "discovery failed by disconnect") { try await discovery.value } }

        // Let the mock's reply timer for the first discovery fire while we are disconnected
        // (see `SimulatedPeripheral.serviceDiscoveryLatency`); real CoreBluetooth would never
        // answer that request after a reconnect.
        try await Task.sleep(nanoseconds: UInt64((link.serviceDiscoveryLatency + 0.25) * 1_000_000_000))

        try await connect(peripheral.peripheral, on: central)
        let requestsBeforeRetry = link.serviceDiscoveryRequests

        let services = try await withTimeout(4, "discoverServices after reconnect") {
            try await peripheral.discoverServices(serviceUUIDs: nil).firstValue
        }
        XCTAssertEqual(services.map { $0.uuid }, Self.serviceUUIDs)
        XCTAssertEqual(link.serviceDiscoveryRequests, requestsBeforeRetry + 1, "the retry reaches CoreBluetooth")
    }

    // MARK: cleanupQueueOnError publishes errors and cannot double-fire

    func testCleanupQueueOnErrorFailsPendingOperationsWithoutIssuingMore() async throws {
        let link = makeSlowLink()
        let central = try makeCentral(peripherals: [link])
        let (peripheral, first) = try await startSlowServiceDiscovery(link, on: central)
        let second = Task { try await peripheral.discoverServices(serviceUUIDs: nil).firstValue }
        try await waitUntil(1, "second discovery queued") {
            peripheral.peripheralDelegate.serviceDiscovery.pendingCount == 2
        }

        peripheral.cleanupQueueOnError()

        for (label, task) in [("first", first), ("second", second)] {
            let result = await outcome { try await withTimeout(1, "\(label) discovery after cleanup") { try await task.value } }
            guard case .failure(let error) = result, case PeripheralError.operationCancelled = error else {
                XCTFail("\(label) discovery: expected PeripheralError.operationCancelled, got \(result)")
                continue
            }
        }
        XCTAssertTrue(peripheral.peripheralDelegate.serviceDiscovery.isEmpty)
        XCTAssertEqual(link.serviceDiscoveryRequests, 1, "cleanup must not start the queued request (the old double-fire)")

        // The abandoned request's reply still arrives, since the peripheral is connected. It
        // must be dropped, and nothing new may be issued because of it.
        try await Task.sleep(nanoseconds: UInt64((link.serviceDiscoveryLatency + 0.25) * 1_000_000_000))
        XCTAssertEqual(link.serviceDiscoveryRequests, 1)
        XCTAssertTrue(peripheral.peripheralDelegate.serviceDiscovery.isEmpty)

        // The next request starts immediately and completes normally.
        let services = try await withTimeout(4, "discoverServices after cleanup") {
            try await peripheral.discoverServices(serviceUUIDs: nil).firstValue
        }
        XCTAssertEqual(services.map { $0.uuid }, Self.serviceUUIDs)
        XCTAssertEqual(link.serviceDiscoveryRequests, 2)
    }

    // MARK: Replies are correlated by what they identify

    func testConcurrentCharacteristicDiscoveryOnDifferentServicesIsCorrelatedByService() async throws {
        let first = CBMServiceMock.primary(CBMUUID(string: "1810"), characteristics: characteristics(["2A00", "2A01"]))
        let second = CBMServiceMock.primary(CBMUUID(string: "1811"), characteristics: characteristics(["2A02", "2A03", "2A04"]))
        let link = SimulatedPeripheral(name: "Link", services: [first, second], connectionInterval: 0.1)
        let central = try makeCentral(peripherals: [link])
        let cbPeripheral = try await discover(link, on: central)
        try await connect(cbPeripheral, on: central)
        let peripheral = Peripheral(peripheral: cbPeripheral)
        let services = try await withTimeout(3, "discoverServices") {
            try await peripheral.discoverServices(serviceUUIDs: nil).firstValue
        }
        let cbFirst = try XCTUnwrap(services.first { $0.uuid == first.uuid })
        let cbSecond = try XCTUnwrap(services.first { $0.uuid == second.uuid })

        async let firstCharacteristics = withTimeout(3, "characteristics of 1810") {
            try await peripheral.discoverCharacteristics(nil, for: cbFirst).firstValue
        }
        async let secondCharacteristics = withTimeout(3, "characteristics of 1811") {
            try await peripheral.discoverCharacteristics(nil, for: cbSecond).firstValue
        }
        let (ofFirst, ofSecond) = try await (firstCharacteristics, secondCharacteristics)

        XCTAssertEqual(ofFirst.map { $0.uuid.uuidString }, ["2A00", "2A01"])
        XCTAssertEqual(ofSecond.map { $0.uuid.uuidString }, ["2A02", "2A03", "2A04"])
        XCTAssertEqual(link.characteristicDiscoveryRequests, 2, "both requests were issued without waiting on each other")
    }

    // MARK: Disconnects that never read .disconnected (review finding 3)

    func testDisconnectUnderAutoReconnectFailsThePendingOperation() async throws {
        guard #available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *) else {
            throw XCTSkip("auto-reconnect needs iOS 17 / macOS 14")
        }
        let link = makeSlowLink()
        let central = try makeCentral(peripherals: [link])
        let (peripheral, discovery) = try await startSlowServiceDiscovery(
            link, on: central, connectOptions: [CBMConnectPeripheralOptionEnableAutoReconnect: true])

        // With auto-reconnect the drop leaves a pending connect: the peripheral reads
        // `.connecting` and never passes through `.disconnected`.
        await dropLink(link, peripheral, on: central)
        XCTAssertEqual(peripheral.peripheral.state, .connecting)

        let result = await outcome {
            try await withTimeout(1, "discoverServices after auto-reconnect drop") { try await discovery.value }
        }
        assertFailed(result, withCBErrorCode: .peripheralDisconnected)
        XCTAssertTrue(peripheral.peripheralDelegate.serviceDiscovery.isEmpty)
    }

    // MARK: Discovery requested while not connected (review finding 1)

    func testDiscoveryRequestedWhileDisconnectedFailsImmediatelyAndReconnectRecovers() async throws {
        let link = makeSlowLink()
        let central = try makeCentral(peripherals: [link])
        let cbPeripheral = try await discover(link, on: central)
        try await connect(cbPeripheral, on: central)
        let peripheral = Peripheral(peripheral: cbPeripheral)
        await dropLink(link, peripheral, on: central)
        XCTAssertEqual(cbPeripheral.state, .disconnected)

        // No state transition is coming, so the request must fail at the call, not wedge.
        let result = await outcome {
            try await withTimeout(1, "discoverServices while disconnected") {
                try await peripheral.discoverServices(serviceUUIDs: nil).firstValue
            }
        }
        assertFailed(result, withCBErrorCode: .peripheralDisconnected)
        XCTAssertTrue(peripheral.peripheralDelegate.serviceDiscovery.isEmpty)
        XCTAssertEqual(link.serviceDiscoveryRequests, 0, "nothing reaches CoreBluetooth while disconnected")

        try await connect(cbPeripheral, on: central)
        let services = try await withTimeout(4, "discoverServices after reconnect") {
            try await peripheral.discoverServices(serviceUUIDs: nil).firstValue
        }
        XCTAssertEqual(services.map { $0.uuid }, Self.serviceUUIDs)
        XCTAssertEqual(link.serviceDiscoveryRequests, 1)
    }

    // MARK: Retrying right after cleanup (review finding 2, documented behaviour)

    func testImmediateRetryAfterCleanupIsIssuedAndCompletes() async throws {
        let link = makeSlowLink()
        let central = try makeCentral(peripherals: [link])
        let (peripheral, first) = try await startSlowServiceDiscovery(link, on: central)

        peripheral.cleanupQueueOnError()
        let cancelled = await outcome { try await withTimeout(1, "first discovery") { try await first.value } }
        guard case .failure(let error) = cancelled, case PeripheralError.operationCancelled = error else {
            return XCTFail("expected PeripheralError.operationCancelled, got \(cancelled)")
        }

        // Retry before the abandoned request's reply can arrive: it is issued immediately
        // and completes with the current services.
        let services = try await withTimeout(4, "immediate retry") {
            try await peripheral.discoverServices(serviceUUIDs: nil).firstValue
        }
        XCTAssertEqual(services.map { $0.uuid }, Self.serviceUUIDs)
        XCTAssertEqual(link.serviceDiscoveryRequests, 2)

        // Whatever the abandoned reply lands on, the lane ends empty and nothing else is issued.
        try await Task.sleep(nanoseconds: UInt64((link.serviceDiscoveryLatency + 0.25) * 1_000_000_000))
        XCTAssertTrue(peripheral.peripheralDelegate.serviceDiscovery.isEmpty)
        XCTAssertEqual(link.serviceDiscoveryRequests, 2)
    }

    // MARK: cleanupQueueOnError covers every lane (review finding 4)

    func testCleanupQueueOnErrorCancelsPendingCharacteristicDiscovery() async throws {
        let service = CBMServiceMock.primary(
            CBMUUID(string: "1810"), characteristics: characteristics(["2A00", "2A01", "2A02", "2A03"]))
        let link = SimulatedPeripheral(name: "Link", services: [service], connectionInterval: 0.5)
        let central = try makeCentral(peripherals: [link])
        let (peripheral, cbService) = try await connectAndDiscoverFirstService(link, on: central)

        let requestSeen = expectation(description: "mock received the characteristic discovery request")
        link.onCharacteristicDiscoveryRequest = { _, _ in requestSeen.fulfill() }
        let discovery = Task { try await peripheral.discoverCharacteristics(nil, for: cbService).firstValue }
        await fulfillment(of: [requestSeen], timeout: 2)
        link.onCharacteristicDiscoveryRequest = nil

        peripheral.cleanupQueueOnError()

        let result = await outcome {
            try await withTimeout(1, "discoverCharacteristics after cleanup") { try await discovery.value }
        }
        guard case .failure(let error) = result, case PeripheralError.operationCancelled = error else {
            return XCTFail("expected PeripheralError.operationCancelled, got \(result)")
        }
        XCTAssertTrue(peripheral.peripheralDelegate.characteristicDiscovery.isEmpty)
    }

    // MARK: Descriptor lane (review finding 5)

    func testDescriptorDiscoveryReturnsTheDescriptors() async throws {
        let link = makeDescriptorLink(connectionInterval: 0.1)
        let central = try makeCentral(peripherals: [link])
        let (peripheral, cbService) = try await connectAndDiscoverFirstService(link, on: central)
        let characteristics = try await withTimeout(3, "discoverCharacteristics") {
            try await peripheral.discoverCharacteristics(nil, for: cbService).firstValue
        }
        let cbCharacteristic = try XCTUnwrap(characteristics.first)

        let descriptors = try await withTimeout(3, "discoverDescriptors") {
            try await peripheral.discoverDescriptors(for: cbCharacteristic).firstValue
        }

        XCTAssertEqual(Set(descriptors.map { $0.uuid.uuidString }), Set(Self.descriptorUUIDs))
        XCTAssertEqual(link.descriptorDiscoveryRequests, 1)
        XCTAssertTrue(peripheral.peripheralDelegate.descriptorDiscovery.isEmpty)
    }

    func testDisconnectDuringDescriptorDiscoveryFailsThePendingOperation() async throws {
        let link = makeDescriptorLink(connectionInterval: 0.5)
        let central = try makeCentral(peripherals: [link])
        let (peripheral, cbService) = try await connectAndDiscoverFirstService(link, on: central)
        let characteristics = try await withTimeout(3, "discoverCharacteristics") {
            try await peripheral.discoverCharacteristics(nil, for: cbService).firstValue
        }
        let cbCharacteristic = try XCTUnwrap(characteristics.first)

        let requestSeen = expectation(description: "mock received the descriptor discovery request")
        link.onDescriptorDiscoveryRequest = { _, _ in requestSeen.fulfill() }
        let discovery = Task { try await peripheral.discoverDescriptors(for: cbCharacteristic).firstValue }
        await fulfillment(of: [requestSeen], timeout: 2)
        link.onDescriptorDiscoveryRequest = nil

        await dropLink(link, peripheral, on: central)

        let result = await outcome {
            try await withTimeout(1, "discoverDescriptors after disconnect") { try await discovery.value }
        }
        assertFailed(result, withCBErrorCode: .peripheralDisconnected)
        XCTAssertTrue(peripheral.peripheralDelegate.descriptorDiscovery.isEmpty)
    }

    // MARK: Error replies and same-lane serialisation (review finding 6)

    func testPeripheralSideDiscoveryErrorFailsTheHeadAndIssuesTheNext() async throws {
        let link = makeSlowLink()
        link.serviceDiscoveryResult = .failure(CBMError(.connectionFailed))
        let central = try makeCentral(peripherals: [link])
        let (peripheral, first) = try await startSlowServiceDiscovery(link, on: central)
        let second = Task { try await peripheral.discoverServices(serviceUUIDs: nil).firstValue }
        try await waitUntil(1, "second discovery queued") {
            peripheral.peripheralDelegate.serviceDiscovery.pendingCount == 2
        }
        XCTAssertEqual(link.serviceDiscoveryRequests, 1)

        let firstResult = await outcome { try await withTimeout(3, "first discovery") { try await first.value } }
        assertFailed(firstResult, withCBErrorCode: .connectionFailed)

        try await waitUntil(1, "second discovery issued after the error reply") {
            link.serviceDiscoveryRequests == 2
        }
        let secondResult = await outcome { try await withTimeout(3, "second discovery") { try await second.value } }
        assertFailed(secondResult, withCBErrorCode: .connectionFailed)
        XCTAssertTrue(peripheral.peripheralDelegate.serviceDiscovery.isEmpty)
    }

    func testSameServiceCharacteristicDiscoveriesAreSerialised() async throws {
        let service = CBMServiceMock.primary(
            CBMUUID(string: "1810"), characteristics: characteristics(["2A00", "2A01", "2A02", "2A03"]))
        let link = SimulatedPeripheral(name: "Link", services: [service], connectionInterval: 0.5)
        let central = try makeCentral(peripherals: [link])
        let (peripheral, cbService) = try await connectAndDiscoverFirstService(link, on: central)

        let requestSeen = expectation(description: "mock received the first characteristic discovery request")
        link.onCharacteristicDiscoveryRequest = { _, _ in requestSeen.fulfill() }
        let first = Task { try await peripheral.discoverCharacteristics(nil, for: cbService).firstValue }
        await fulfillment(of: [requestSeen], timeout: 2)
        link.onCharacteristicDiscoveryRequest = nil

        let second = Task { try await peripheral.discoverCharacteristics(nil, for: cbService).firstValue }
        try await waitUntil(1, "second characteristic discovery queued") {
            peripheral.peripheralDelegate.characteristicDiscovery.pendingCount == 2
        }
        XCTAssertEqual(link.characteristicDiscoveryRequests, 1, "the second request waits for the first reply")

        let ofFirst = try await withTimeout(4, "first characteristic discovery") { try await first.value }
        XCTAssertEqual(ofFirst.count, 4)
        try await waitUntil(1, "second request issued after the first reply") {
            link.characteristicDiscoveryRequests == 2
        }
        let ofSecond = try await withTimeout(4, "second characteristic discovery") { try await second.value }
        XCTAssertEqual(ofSecond.count, 4)
        XCTAssertTrue(peripheral.peripheralDelegate.characteristicDiscovery.isEmpty)
    }
}
