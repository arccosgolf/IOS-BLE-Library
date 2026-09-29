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
        on central: CentralManager
    ) async throws -> (Peripheral, Task<[CBService], Error>) {
        let cbPeripheral = try await discover(device, on: central)
        try await connect(cbPeripheral, on: central)
        let peripheral = Peripheral(peripheral: cbPeripheral)

        let requestSeen = expectation(description: "mock received the service discovery request")
        device.onServiceDiscoveryRequest = { _ in requestSeen.fulfill() }
        let discovery = Task { try await peripheral.discoverServices(serviceUUIDs: nil).firstValue }
        await fulfillment(of: [requestSeen], timeout: 2)
        device.onServiceDiscoveryRequest = nil

        return (peripheral, discovery)
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
}
