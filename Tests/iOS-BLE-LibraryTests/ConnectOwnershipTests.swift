//
//  ConnectOwnershipTests.swift
//
//  Wave C3 (review finding i3, CU-868m1mrjy). `CentralManager.connect` never cancelled the
//  CoreBluetooth connect request when its publisher went away, and the app relied on that
//  leak: its connect-timeout path gives up on the publisher but wants the OS connect (and
//  auto-reconnect) to finish the job. `connect(_:options:keepPendingOnAbandon:)` makes the
//  choice explicit. These tests pin both policies, the app's own timeout shape, the
//  auto-reconnect variants the C1 review asked for, and the connect inventory.
//

import Combine
import CoreBluetoothMock
import XCTest

@testable import iOS_BLE_Library_Mock

private struct ConnectTimedOut: Error, Equatable {}

final class ConnectOwnershipTests: CentralManagerTestCase {

    private let serviceUUID = CBMUUID(string: "180D")

    /// A link whose connect takes `connectionInterval` in the mock, so a test can act while
    /// the peripheral is still `.connecting`.
    private func makeLink(
        connectionInterval: TimeInterval = 0.045,
        advertisingInterval: TimeInterval? = 0.25,
        initiallyConnected: Bool = false
    ) -> SimulatedPeripheral {
        SimulatedPeripheral(
            name: "Link",
            services: [.primary(serviceUUID)],
            advertisingInterval: advertisingInterval,
            connectionInterval: connectionInterval,
            initiallyConnected: initiallyConnected)
    }

    /// Subscribes *now* and returns an expectation fulfilled when the central reports
    /// `identifier` connected. Not registered with the test case.
    private func expectConnect(of identifier: UUID, on central: CentralManager) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "connect of \(identifier)")
        central.connectedPeripheralChannel
            .filter { $0.0.identifier == identifier && $0.1 == nil }
            .first()
            .sink { _ in expectation.fulfill() }
            .store(in: &cancellables)
        return expectation
    }

    /// Issues a connect through a held `sink`, waits until the mock reports `.connecting`, and
    /// returns the subscription so the test can cancel it mid-connect.
    private func startConnect(
        _ peripheral: CBPeripheral, on central: CentralManager,
        options: [String: Any]? = nil, keepPendingOnAbandon: Bool
    ) async throws -> AnyCancellable {
        try await waitForPowerOn(central)
        let subscription = central
            .connect(peripheral, options: options, keepPendingOnAbandon: keepPendingOnAbandon)
            .sink(receiveCompletion: { _ in }, receiveValue: { _ in })
        try await waitUntil(2, "connect issued") { peripheral.state == .connecting }
        return subscription
    }

    // MARK: keepPendingOnAbandon: true (the app's contract)

    func testKeepPendingLeavesTheOSConnectPendingWhenTheSubscriptionIsCancelled() async throws {
        let link = makeLink(connectionInterval: 1)
        let central = try makeCentral(peripherals: [link])
        let peripheral = try await discover(link, on: central)
        let connected = expectConnect(of: peripheral.identifier, on: central)

        let subscription = try await startConnect(peripheral, on: central, keepPendingOnAbandon: true)
        subscription.cancel()

        XCTAssertEqual(peripheral.state, .connecting, "the OS connect must survive the subscription")
        XCTAssertEqual(central.pendingConnects.map { $0.identifier }, [peripheral.identifier])

        await fulfillment(of: [connected], timeout: 3)
        XCTAssertEqual(peripheral.state, .connected)
        XCTAssertEqual(central.connectInventory.map { $0.state }, [.connected])
        XCTAssertTrue(central.pendingConnects.isEmpty, "a connected peripheral is no longer pending")
    }

    func testKeepPendingWithFirstValueLeavesThePeripheralConnected() async throws {
        // `firstValue` ends the subscription the moment the value arrives; this is how the
        // harness, and the app, connect. Pre-C3 behaviour, now spelled out.
        let link = makeLink()
        let central = try makeCentral(peripherals: [link])
        let peripheral = try await discover(link, on: central)
        let dropped = expectDisconnect(of: peripheral.identifier, on: central)
        dropped.isInverted = true

        try await connect(peripheral, on: central)

        XCTAssertEqual(peripheral.state, .connected)
        await fulfillment(of: [dropped], timeout: 0.5)
        XCTAssertEqual(peripheral.state, .connected, "taking the first value must not disconnect")
        XCTAssertEqual(central.connectInventory.map { $0.identifier }, [peripheral.identifier])
        XCTAssertEqual(central.connectInventory.first?.origin, .connect(keepPendingOnAbandon: true))
    }

    func testKeepPendingSurvivesTheAppsConnectTimeoutAndCompletesLater() async throws {
        // The field scenario (ClickUp 868jcw9u1): the app bounds the connect with a Combine
        // `timeout` and gives up, but the OS connect stays pending and lands afterwards.
        let link = makeLink(connectionInterval: 1)
        let central = try makeCentral(peripherals: [link])
        let peripheral = try await discover(link, on: central)
        let connected = expectConnect(of: peripheral.identifier, on: central)

        let result = await outcome {
            try await withTimeout(2, "bounded connect") {
                try await central.connect(peripheral, keepPendingOnAbandon: true)
                    .timeout(.milliseconds(200), scheduler: DispatchQueue.main, customError: { ConnectTimedOut() })
                    .firstValue
            }
        }
        guard case .failure(let error) = result, error is ConnectTimedOut else {
            return XCTFail("expected the caller's timeout, got \(result)")
        }

        XCTAssertEqual(peripheral.state, .connecting, "the OS connect outlives the caller's timeout")
        XCTAssertEqual(central.pendingConnects.map { $0.identifier }, [peripheral.identifier])

        await fulfillment(of: [connected], timeout: 3)
        XCTAssertEqual(peripheral.state, .connected)
    }

    // MARK: keepPendingOnAbandon: false (the subscription owns the connection)

    func testCancellingPolicyWithdrawsThePendingConnectWhenTheSubscriptionIsCancelled() async throws {
        let link = makeLink(connectionInterval: 1)
        let central = try makeCentral(peripherals: [link])
        let peripheral = try await discover(link, on: central)
        let connected = expectConnect(of: peripheral.identifier, on: central)
        connected.isInverted = true

        let subscription = try await startConnect(peripheral, on: central, keepPendingOnAbandon: false)
        subscription.cancel()

        try await waitUntil(1, "pending connect withdrawn") { peripheral.state == .disconnected }
        XCTAssertTrue(central.connectInventory.isEmpty, "nothing is held for a withdrawn connect")

        await fulfillment(of: [connected], timeout: 1.5)
        XCTAssertEqual(peripheral.state, .disconnected, "a withdrawn connect must not land later")
    }

    func testCancellingPolicyDisconnectsWhenTheSubscriptionIsCancelledAfterConnecting() async throws {
        let link = makeLink()
        let central = try makeCentral(peripherals: [link])
        let peripheral = try await discover(link, on: central)
        try await waitForPowerOn(central)

        let connected = expectConnect(of: peripheral.identifier, on: central)
        let subscription = central.connect(peripheral, keepPendingOnAbandon: false)
            .sink(receiveCompletion: { _ in }, receiveValue: { _ in })
        await fulfillment(of: [connected], timeout: 2)
        XCTAssertEqual(peripheral.state, .connected)

        let dropped = expectDisconnect(of: peripheral.identifier, on: central)
        subscription.cancel()

        await fulfillment(of: [dropped], timeout: 2)
        XCTAssertEqual(peripheral.state, .disconnected)
        XCTAssertTrue(central.connectInventory.isEmpty)
    }

    func testCancellingPolicyWithFirstValueDisconnectsTheJustConnectedPeripheral() async throws {
        // Pins the documented foot-gun: `firstValue` ends the subscription, so with this
        // policy the peripheral is disconnected right after it connects. Callers that await
        // the connect must use `keepPendingOnAbandon: true`.
        let link = makeLink()
        let central = try makeCentral(peripherals: [link])
        let peripheral = try await discover(link, on: central)
        try await waitForPowerOn(central)
        let dropped = expectDisconnect(of: peripheral.identifier, on: central)

        let connected = try await withTimeout(2, "connect") {
            try await central.connect(peripheral, keepPendingOnAbandon: false).firstValue
        }
        XCTAssertEqual(connected.identifier, peripheral.identifier)

        await fulfillment(of: [dropped], timeout: 2)
        XCTAssertEqual(peripheral.state, .disconnected)
    }

    // MARK: Connect failure (didFailToConnect) under both policies

    /// Issues a connect that the mock refuses, waits for the publisher to fail with the mock's
    /// error, and returns the disconnect events the central published meanwhile.
    private func assertConnectFailure(keepPendingOnAbandon: Bool) async throws -> (CBPeripheral, EventBox<Bool>) {
        let link = makeLink(connectionInterval: 0.2)
        link.connectionResult = .failure(CBMError(.connectionFailed))
        let central = try makeCentral(peripherals: [link])
        let peripheral = try await discover(link, on: central)
        try await waitForPowerOn(central)

        let disconnects = EventBox<Bool>()
        central.disconnectedPeripheralsChannel
            .filter { $0.0.identifier == peripheral.identifier }
            .sink { disconnects.append($0.1) }
            .store(in: &cancellables)

        let failed = XCTestExpectation(description: "connect publisher failed")
        central.connect(peripheral, keepPendingOnAbandon: keepPendingOnAbandon)
            .sink(receiveCompletion: { completion in
                guard case .failure(let error) = completion else {
                    return XCTFail("a refused connect must fail the publisher, got \(completion)")
                }
                XCTAssertEqual((error as? CBMError)?.code, .connectionFailed, "the mock's error must surface verbatim, got \(error)")
                failed.fulfill()
            }, receiveValue: { _ in XCTFail("a refused connect must not emit a peripheral") })
            .store(in: &cancellables)
        await fulfillment(of: [failed], timeout: 2)

        XCTAssertEqual(peripheral.state, .disconnected)
        XCTAssertTrue(central.connectInventory.isEmpty, "a failed connect is not something CoreBluetooth holds")
        return (peripheral, disconnects)
    }

    func testKeepPendingConnectFailureFailsThePublisherAndLeavesNothingPending() async throws {
        let (_, disconnects) = try await assertConnectFailure(keepPendingOnAbandon: true)
        // `didFailToConnect` is not a disconnect; nothing else may be published for it.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(disconnects.isEmpty, "a connect failure must not be reported as a disconnect")
    }

    func testCancellingPolicyConnectFailureWithdrawsNothingAndPublishesNoDisconnect() async throws {
        // The completion hook runs `cancelPeripheralConnection` on a handle CoreBluetooth already
        // holds nothing for; that must be a silent no-op, not a second event.
        let (_, disconnects) = try await assertConnectFailure(keepPendingOnAbandon: false)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(disconnects.isEmpty, "the withdrawal after a failed connect must produce no disconnect event")
    }

    // MARK: Auto-reconnect variants (C1 review: link loss reports `.connecting`, never `.disconnected`)

    private var autoReconnectOptions: [String: Any] {
        [CBMConnectPeripheralOptionEnableAutoReconnect: true]
    }

    /// Connects `link` with auto-reconnect through a held subscription, drops the link with an
    /// error, and returns once the publisher has failed.
    private func connectWithAutoReconnectThenDrop(
        _ link: SimulatedPeripheral, on central: CentralManager, keepPendingOnAbandon: Bool
    ) async throws -> (CBPeripheral, AnyCancellable) {
        let peripheral = try await discover(link, on: central)
        try await waitForPowerOn(central)

        let connected = expectConnect(of: peripheral.identifier, on: central)
        let failed = XCTestExpectation(description: "connect publisher failed on the drop")
        let subscription = central
            .connect(peripheral, options: autoReconnectOptions, keepPendingOnAbandon: keepPendingOnAbandon)
            .sink(receiveCompletion: { completion in
                if case .failure = completion { failed.fulfill() }
            }, receiveValue: { _ in })
        await fulfillment(of: [connected], timeout: 2)

        link.spec.simulateDisconnection(withError: CBMError(.peripheralDisconnected))
        await fulfillment(of: [failed], timeout: 2)
        return (peripheral, subscription)
    }

    func testKeepPendingLeavesTheOSReconnectArmedAfterAnErrorDisconnect() async throws {
        let link = makeLink()
        let central = try makeCentral(peripherals: [link])

        let (peripheral, subscription) = try await connectWithAutoReconnectThenDrop(
            link, on: central, keepPendingOnAbandon: true)
        defer { subscription.cancel() }

        XCTAssertEqual(peripheral.state, .connecting, "iOS keeps reconnecting after the publisher failed")
        XCTAssertEqual(central.pendingConnects.map { $0.identifier }, [peripheral.identifier],
                       "the armed reconnect is a pending connect iOS holds for us")
    }

    func testCancellingPolicyWithdrawsTheOSReconnectAfterAnErrorDisconnect() async throws {
        let link = makeLink()
        let central = try makeCentral(peripherals: [link])

        let (peripheral, subscription) = try await connectWithAutoReconnectThenDrop(
            link, on: central, keepPendingOnAbandon: false)
        defer { subscription.cancel() }

        // The failure ended the subscription, and the subscription owned the connection.
        try await waitUntil(1, "reconnect withdrawn") { peripheral.state == .disconnected }
        XCTAssertTrue(central.connectInventory.isEmpty)
    }

    // MARK: Inventory

    func testInventoryListsARestoredPendingConnectBeforeAnyConnectCall() async throws {
        // The app was relaunched with an OS connect still pending for a device out of reach:
        // the handle comes back `.connecting` and nothing in this process issued it.
        let link = makeLink(initiallyConnected: false)
        CBMCentralManagerMock.simulateStateRestoration = { _ in
            [CBMCentralManagerRestoredStatePeripheralsKey: [link.spec]]
        }
        let central = try makeCentral(peripherals: [link], restoreIdentifier: "com.arccos.ble.tests.c3")

        let (events, first) = collectRestorationEvents(on: central)
        central.markRestorationSubscribersReady()
        await fulfillment(of: [first], timeout: 1)
        let restored = try XCTUnwrap(
            (events.values.first?[CBMCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first)
        XCTAssertEqual(restored.state, .connecting)

        let pending = central.pendingConnects
        XCTAssertEqual(pending.map { $0.identifier }, [restored.identifier])
        XCTAssertEqual(pending.first?.origin, .restoration)
        XCTAssertNil(pending.first?.options)
    }

    func testInventoryKeepsOneRecordPerPeripheralAndReflectsTheLatestConnect() async throws {
        let link = makeLink(connectionInterval: 1)
        let central = try makeCentral(peripherals: [link])
        let peripheral = try await discover(link, on: central)

        let first = try await startConnect(peripheral, on: central, keepPendingOnAbandon: true)
        first.cancel()
        let issuedAt = try XCTUnwrap(central.pendingConnects.first?.issuedAt)

        // Re-issuing a connect for the same peripheral replaces the record.
        try await waitForPowerOn(central)
        let second = central
            .connect(peripheral, options: [CBMConnectPeripheralOptionNotifyOnConnectionKey: true],
                     keepPendingOnAbandon: false)
            .sink(receiveCompletion: { _ in }, receiveValue: { _ in })
        defer { second.cancel() }

        let records = central.pendingConnects
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.origin, .connect(keepPendingOnAbandon: false))
        XCTAssertNotNil(records.first?.options?[CBMConnectPeripheralOptionNotifyOnConnectionKey])
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(records.first?.issuedAt), issuedAt)
        XCTAssertEqual(records.first?.name, "Link")
    }

    func testInventoryDropsAPeripheralOnceItIsDisconnected() async throws {
        let link = makeLink()
        let central = try makeCentral(peripherals: [link])
        let peripheral = try await discover(link, on: central)
        try await connect(peripheral, on: central)
        XCTAssertEqual(central.connectInventory.count, 1)

        _ = try await withTimeout(2, "cancel connected peripheral") {
            try await central.cancelPeripheralConnection(peripheral).firstValue
        }

        XCTAssertEqual(peripheral.state, .disconnected)
        XCTAssertTrue(central.connectInventory.isEmpty)
    }

    func testInventoryIsEmptyForAManagerThatNeverConnected() throws {
        let central = try makeCentral(peripherals: [makeLink()])
        XCTAssertTrue(central.connectInventory.isEmpty)
        XCTAssertTrue(central.pendingConnects.isEmpty)
    }
}
