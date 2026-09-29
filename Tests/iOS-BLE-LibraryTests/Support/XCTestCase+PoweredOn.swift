//
//  XCTestCase+PoweredOn.swift
//
//  Arccos test support.
//
//  CoreBluetoothMock reports `.poweredOn` asynchronously after a manager is created, and
//  `CentralManager.scanForPeripherals` issues the CoreBluetooth scan the moment it is
//  subscribed, whether or not the manager is powered on yet. A scan issued too early is
//  rejected by the mock ("can only accept this command while in the powered on state"),
//  never starts, and the awaiting test hangs. That race is what hung the macOS CI job in
//  `PeripheralMultitaskingTests.testDiscoverServices` on 2026-09-29 (the CI log shows the
//  rejection logged twice in the hung test, once in the passing one). Upstream's tests scan
//  straight after `setUp`, so their `setUp` waits here first; `CentralManagerTestCase`
//  scenarios use the async `waitForPowerOn` instead.
//

import Combine
import XCTest

@testable import iOS_BLE_Library_Mock

extension XCTestCase {
    /// Blocks until `central` reports `.poweredOn`, pumping the main run loop so the mock can
    /// deliver the state change. Records a test failure if it does not arrive within `timeout`.
    func waitUntilPoweredOn(_ central: CentralManager, timeout: TimeInterval = 2) {
        let poweredOn = XCTestExpectation(description: "central powered on")
        let subscription = central.stateChannel
            .filter { $0 == .poweredOn }
            .first()
            .sink { _ in poweredOn.fulfill() }
        wait(for: [poweredOn], timeout: timeout)
        subscription.cancel()
    }
}
