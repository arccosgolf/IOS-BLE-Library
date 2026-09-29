//
//  CentralManagerRestorationTests.swift
//
//  Arccos: state-restoration coverage for the fork.
//
//  CoreBluetooth delivers `willRestoreState` from *inside* `CBCentralManager.init`, before
//  the app can have attached a subscriber. The fork buffers that event in
//  `ReactiveCentralManagerDelegate` and replays it on `markRestorationSubscribersReady()`.
//  CoreBluetoothMock reproduces the same timing when the manager is created with a restore
//  identifier and `CBMCentralManagerMock.simulateStateRestoration` is set; these are the
//  first tests in the fork to exercise that path.
//

import Combine
import CoreBluetoothMock
import XCTest

@testable import iOS_BLE_Library_Mock

final class CentralManagerRestorationTests: CentralManagerTestCase {

    private static let restoreIdentifier = "com.arccos.ble.tests.restore"
    private let serviceUUID = CBMUUID(string: "180D")

    private func makeLink(
        initiallyConnected: Bool,
        advertisingInterval: TimeInterval? = 0.25
    ) -> SimulatedPeripheral {
        SimulatedPeripheral(
            name: "Link",
            services: [.primary(serviceUUID)],
            advertisingInterval: advertisingInterval,
            initiallyConnected: initiallyConnected)
    }

    /// A manager whose `willRestoreState` (fired inside its initializer) reports `device`
    /// and, optionally, an in-progress scan for `scanServices`.
    private func makeRestoringCentral(
        device: SimulatedPeripheral,
        scanServices: [CBMUUID]? = nil
    ) throws -> CentralManager {
        CBMCentralManagerMock.simulateStateRestoration = { identifier in
            XCTAssertEqual(identifier, Self.restoreIdentifier)
            var state: [String: Any] = [
                CBMCentralManagerRestoredStatePeripheralsKey: [device.spec]
            ]
            if let scanServices {
                state[CBMCentralManagerRestoredStateScanServicesKey] = scanServices
            }
            return state
        }
        return try makeCentral(peripherals: [device], restoreIdentifier: Self.restoreIdentifier)
    }

    private func restoredPeripheral(in event: [String: Any]) throws -> CBPeripheral {
        let peripherals = try XCTUnwrap(
            event[CBMCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
            "restoration event carries no peripherals")
        return try XCTUnwrap(peripherals.first)
    }

    // MARK: Buffering

    func testRestorationEventFromInitIsHeldUntilSubscribersAreReady() async throws {
        let link = makeLink(initiallyConnected: true)
        let central = try makeRestoringCentral(device: link, scanServices: [serviceUUID])
        // `willRestoreState` has already fired inside the initializer above, before any
        // subscriber could exist. Without the buffer it would be gone.

        let (events, first) = collectRestorationEvents(on: central)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(events.isEmpty, "the buffered event must not replay before the app opts in")

        central.markRestorationSubscribersReady()
        await fulfillment(of: [first], timeout: 1)

        XCTAssertEqual(events.count, 1)
        let event = try XCTUnwrap(events.values.first)
        XCTAssertEqual(try restoredPeripheral(in: event).identifier, link.identifier)
        XCTAssertEqual(
            event[CBMCentralManagerRestoredStateScanServicesKey] as? [CBMUUID], [serviceUUID])
    }

    func testRestorationEventAfterReadyIsDeliveredImmediately() throws {
        let central = try makeCentral(peripherals: [])
        central.markRestorationSubscribersReady()
        let (events, _) = collectRestorationEvents(on: central)

        central.centralManagerDelegate.centralManager(
            central.centralManager,
            willRestoreState: [CBMCentralManagerRestoredStateScanServicesKey: [serviceUUID]])

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(
            events.values.first?[CBMCentralManagerRestoredStateScanServicesKey] as? [CBMUUID],
            [serviceUUID])
    }

    func testBufferedEventsReplayOnceInOrder() throws {
        let central = try makeCentral(peripherals: [])
        let delegate = central.centralManagerDelegate
        delegate.centralManager(central.centralManager, willRestoreState: ["order": 1])
        delegate.centralManager(central.centralManager, willRestoreState: ["order": 2])

        let (events, _) = collectRestorationEvents(on: central)
        XCTAssertTrue(events.isEmpty)

        central.markRestorationSubscribersReady()
        XCTAssertEqual(events.values.map { $0["order"] as? Int }, [1, 2])

        central.markRestorationSubscribersReady()
        XCTAssertEqual(events.count, 2, "a second ready call must not replay the buffer")
    }

    // MARK: Using a restored handle (the app's setupDeviceForRestoration path)

    func testRestoredConnectedPeripheralConnectsAndDiscoversWithoutAdvertising() async throws {
        // The system still holds the link and the device is silent: only the restored
        // handle can reach it.
        let link = makeLink(initiallyConnected: true, advertisingInterval: nil)
        let central = try makeRestoringCentral(device: link)

        let (events, first) = collectRestorationEvents(on: central)
        central.markRestorationSubscribersReady()
        await fulfillment(of: [first], timeout: 1)
        let restored = try restoredPeripheral(in: try XCTUnwrap(events.values.first))
        XCTAssertEqual(restored.state, .connected)

        try await connect(restored, on: central)

        let peripheral = Peripheral(peripheral: restored)
        let services = try await withTimeout(3, "discoverServices on restored peripheral") {
            try await peripheral.discoverServices(serviceUUIDs: nil).firstValue
        }
        XCTAssertEqual(services.map { $0.uuid }, [serviceUUID])
    }

    func testRestoredPendingConnectCompletesWhenPeripheralAdvertises() async throws {
        // The app was relaunched with a pending OS connect for a device that was out of
        // reach; the restored handle is `.connecting` and must complete when the device
        // reappears, with no scan involved.
        let link = makeLink(initiallyConnected: false)
        let central = try makeRestoringCentral(device: link)

        let (events, first) = collectRestorationEvents(on: central)
        central.markRestorationSubscribersReady()
        await fulfillment(of: [first], timeout: 1)
        let restored = try restoredPeripheral(in: try XCTUnwrap(events.values.first))
        XCTAssertEqual(restored.state, .connecting, "restoration hands back the pending OS connect")

        try await connect(restored, on: central)
        XCTAssertEqual(restored.state, .connected)
    }
}
