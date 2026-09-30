//
//  FirstValueBridgeTests.swift
//
//  Wave C2 (review finding i12). `Publisher.firstValue` bridges Combine into async/await
//  through `ContinuationSubscriber`. A publisher that finishes without emitting used to leave
//  the awaiting task suspended forever; it now throws `FirstValueError.finishedWithoutValue`.
//
//  `FirstValueBridgeTests` exercises the bridge on plain Combine publishers.
//  `FirstValueLibraryPathTests` drives the two library publishers that finish empty in the
//  field (a connect cancelled before it completes, a scan stopped before it matches), the
//  auto-reconnect and restored-handle variants the C1 review asked for, and documents the one
//  disconnect await the bridge cannot help with (nothing ever completes it).
//

import Combine
import CoreBluetoothMock
import XCTest

@testable import iOS_BLE_Library_Mock

private struct UpstreamError: Error, Equatable {}

/// Fails unless `result` is `FirstValueError.finishedWithoutValue`. A `TimeoutError` here means
/// the bridge hung, which is the defect this file exists to catch.
private func assertFinishedWithoutValue<T>(
    _ result: Result<T, Error>, file: StaticString = #filePath, line: UInt = #line
) {
    switch result {
    case .success(let value):
        XCTFail("expected FirstValueError.finishedWithoutValue, got value \(value)", file: file, line: line)
    case .failure(let error):
        XCTAssertEqual(
            error as? FirstValueError, .finishedWithoutValue,
            "expected FirstValueError.finishedWithoutValue, got \(error)", file: file, line: line)
    }
}

// MARK: - The bridge alone

final class FirstValueBridgeTests: XCTestCase {

    private var cancellables = Set<AnyCancellable>()

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    func testEmptyPublisherThrowsFinishedWithoutValue() async throws {
        let result = await outcome {
            try await withTimeout(1) { try await Empty<Int, Error>().firstValue }
        }
        assertFinishedWithoutValue(result)
    }

    func testEmptyNeverFailingPublisherThrowsFinishedWithoutValue() async throws {
        // `isPoweredOn()` awaits a `Never`-failing channel; the bridge is generic over Failure.
        let result = await outcome {
            try await withTimeout(1) { try await Empty<Int, Never>().firstValue }
        }
        assertFinishedWithoutValue(result)
    }

    func testFinishAfterSubscriptionThrowsFinishedWithoutValue() async throws {
        let subject = PassthroughSubject<Int, Error>()
        let subscribed = XCTestExpectation(description: "subscribed")
        let awaiting = Task {
            try await subject
                .handleEvents(receiveSubscription: { _ in subscribed.fulfill() })
                .firstValue
        }
        await fulfillment(of: [subscribed], timeout: 1)

        subject.send(completion: .finished)

        let result = await outcome { try await withTimeout(1) { try await awaiting.value } }
        assertFinishedWithoutValue(result)
    }

    func testValueThenFinishReturnsTheValue() async throws {
        // `Just` emits and finishes synchronously on subscribe: the finish after a value must
        // neither throw nor resume the continuation a second time.
        let value = try await withTimeout(1) { try await Just(5).setFailureType(to: Error.self).firstValue }
        XCTAssertEqual(value, 5)
    }

    func testFirstOfSeveralValuesIsReturned() async throws {
        let value = try await withTimeout(1) { try await [1, 2, 3].publisher.firstValue }
        XCTAssertEqual(value, 1)
    }

    func testValueThenFinishOnSubjectReturnsTheValue() async throws {
        let subject = PassthroughSubject<Int, Error>()
        let subscribed = XCTestExpectation(description: "subscribed")
        let awaiting = Task {
            try await subject
                .handleEvents(receiveSubscription: { _ in subscribed.fulfill() })
                .firstValue
        }
        await fulfillment(of: [subscribed], timeout: 1)

        subject.send(7)
        subject.send(completion: .finished)

        let value = try await withTimeout(1) { try await awaiting.value }
        XCTAssertEqual(value, 7)
    }

    func testUpstreamFailureIsForwardedUnchanged() async throws {
        let result = await outcome {
            try await withTimeout(1) { try await Fail<Int, UpstreamError>(error: UpstreamError()).firstValue }
        }
        guard case .failure(let error) = result else {
            return XCTFail("expected UpstreamError, got \(result)")
        }
        XCTAssertEqual(error as? UpstreamError, UpstreamError(), "got \(error)")
    }

    func testFailureAfterSubscriptionIsForwardedUnchanged() async throws {
        let subject = PassthroughSubject<Int, Error>()
        let subscribed = XCTestExpectation(description: "subscribed")
        let awaiting = Task {
            try await subject
                .handleEvents(receiveSubscription: { _ in subscribed.fulfill() })
                .firstValue
        }
        await fulfillment(of: [subscribed], timeout: 1)

        subject.send(completion: .failure(UpstreamError()))

        let result = await outcome { try await withTimeout(1) { try await awaiting.value } }
        guard case .failure(let error) = result else {
            return XCTFail("expected UpstreamError, got \(result)")
        }
        XCTAssertEqual(error as? UpstreamError, UpstreamError(), "got \(error)")
    }
}

// MARK: - The library publishers that finish empty

final class FirstValueLibraryPathTests: CentralManagerTestCase {

    private let serviceUUID = CBMUUID(string: "180D")

    private func makeLink(
        advertisingInterval: TimeInterval? = 0.25,
        connectionInterval: TimeInterval = 0.045,
        initiallyConnected: Bool = false
    ) -> SimulatedPeripheral {
        SimulatedPeripheral(
            name: "Link",
            services: [.primary(serviceUUID)],
            advertisingInterval: advertisingInterval,
            connectionInterval: connectionInterval,
            initiallyConnected: initiallyConnected)
    }

    // MARK: Scan stopped before a match

    func testStoppedScanThrowsInsteadOfHanging() async throws {
        // A silent peripheral keeps the scan from ever matching; `stopScan()` then finishes
        // the scan publisher without a value.
        let silent = makeLink(advertisingInterval: nil)
        let central = try makeCentral(peripherals: [silent])
        try await waitForPowerOn(central)

        let scan = Task { try await central.scanForPeripherals(withServices: [serviceUUID]).firstValue }
        try await waitUntil(2, "scan started") { central.centralManager.isScanning }

        central.stopScan()

        let result = await outcome { try await withTimeout(2, "stopped scan") { try await scan.value } }
        assertFinishedWithoutValue(result)
    }

    // MARK: Connect cancelled before it completes

    /// Issues `connect()`, cancels it while the mock is still `.connecting`, and asserts the
    /// awaited connect throws `finishedWithoutValue`: the cancel is reported as an error-free
    /// disconnect, which is the connect publisher's clean completion. The app's
    /// `firstValueOrThrow` guard exists for exactly this path (ClickUp 868jcw9u1).
    private func assertCancelledConnectThrows(options: [String: Any]?) async throws {
        // A long connection interval keeps the mock in `.connecting` while we cancel.
        let link = makeLink(connectionInterval: 1)
        let central = try makeCentral(peripherals: [link])
        let peripheral = try await discover(link, on: central)

        let connect = Task { try await central.connect(peripheral, options: options).firstValue }
        try await waitUntil(2, "connect issued") { peripheral.state == .connecting }

        let cancelled = try await withTimeout(2, "cancel while connecting") {
            try await central.cancelPeripheralConnection(peripheral).firstValue
        }
        XCTAssertEqual(cancelled.identifier, peripheral.identifier)

        let result = await outcome { try await withTimeout(2, "cancelled connect") { try await connect.value } }
        assertFinishedWithoutValue(result)
        XCTAssertEqual(peripheral.state, .disconnected)
    }

    func testConnectCancelledWhileConnectingThrowsInsteadOfHanging() async throws {
        try await assertCancelledConnectThrows(options: nil)
    }

    func testConnectCancelledWhileConnectingUnderAutoReconnectThrowsInsteadOfHanging() async throws {
        guard #available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *) else {
            throw XCTSkip("auto-reconnect needs iOS 17 / macOS 14")
        }
        // The app connects Links with auto-reconnect; cancelling drops that too and reports
        // the same error-free disconnect.
        try await assertCancelledConnectThrows(
            options: [CBMConnectPeripheralOptionEnableAutoReconnect: true])
    }

    // MARK: Disconnect awaits the app's `UartDevice.disconnect()` relies on

    func testCancelOnRestoredConnectedHandleCompletesWithThePeripheral() async throws {
        // State restoration hands back a handle the system still holds connected; the app
        // connects it and later disconnects it through the same publisher as a scanned one.
        let link = makeLink(advertisingInterval: nil, initiallyConnected: true)
        CBMCentralManagerMock.simulateStateRestoration = { _ in
            [CBMCentralManagerRestoredStatePeripheralsKey: [link.spec]]
        }
        let central = try makeCentral(peripherals: [link], restoreIdentifier: "com.arccos.ble.tests.c2")

        let (events, first) = collectRestorationEvents(on: central)
        central.markRestorationSubscribersReady()
        await fulfillment(of: [first], timeout: 1)
        let restored = try XCTUnwrap(
            (events.values.first?[CBMCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first)
        try await connect(restored, on: central)
        XCTAssertEqual(restored.state, .connected)

        let disconnected = try await withTimeout(2, "cancel restored handle") {
            try await central.cancelPeripheralConnection(restored).firstValue
        }
        XCTAssertEqual(disconnected.identifier, restored.identifier)
        XCTAssertEqual(restored.state, .disconnected)
    }

    func testCancelOnConnectedPeripheralCompletesWithThePeripheral() async throws {
        let link = makeLink()
        let central = try makeCentral(peripherals: [link])
        let peripheral = try await discover(link, on: central)
        try await connect(peripheral, on: central)

        let disconnected = try await withTimeout(2, "cancel connected peripheral") {
            try await central.cancelPeripheralConnection(peripheral).firstValue
        }
        XCTAssertEqual(disconnected.identifier, peripheral.identifier)
        XCTAssertEqual(peripheral.state, .disconnected)
    }

    func testCancelOnAlreadyDisconnectedPeripheralIsNeverAnswered() async throws {
        // Documents the contract, not a defect the bridge can fix: CoreBluetooth answers
        // `cancelPeripheralConnection` on a peripheral that is not connected or connecting with
        // nothing at all, so the publisher neither emits nor finishes. A caller that awaits it
        // must bound the await itself (the app's `UartDevice.disconnect()` does), or skip it
        // when the peripheral is already `.disconnected`.
        let link = makeLink()
        let central = try makeCentral(peripherals: [link])
        let peripheral = try await discover(link, on: central)
        XCTAssertEqual(peripheral.state, .disconnected)

        let result = await outcome {
            try await withTimeout(0.5, "cancel on disconnected peripheral") {
                try await central.cancelPeripheralConnection(peripheral).firstValue
            }
        }
        guard case .failure(let error) = result, error is TimeoutError else {
            return XCTFail("expected the await to still be pending after 0.5 s, got \(result)")
        }
    }
}
