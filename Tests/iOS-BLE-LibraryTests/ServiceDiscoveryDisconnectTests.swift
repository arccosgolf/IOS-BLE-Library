//
//  ServiceDiscoveryDisconnectTests.swift
//
//  Arccos: the "connects but never becomes usable" family (review finding i10,
//  Wave C1 / CU-868m1mrcy).
//
//  These tests pin the *current* behaviour as expected failures. They prove the harness
//  can stage a disconnect in the middle of service discovery and observe the outcome
//  within a deadline; the C1 fix flips them green by removing the `XCTExpectFailure`
//  wrappers, which XCTest enforces (`strict` is the default: an unexpected pass fails).
//
//  Assertions sit inside the synchronous `XCTExpectFailure { }` closure on purpose:
//  expected-failure matching is thread-scoped, so an assertion placed after an `await`
//  is matched only when the continuation happens to resume on the same thread.
//

import Combine
import CoreBluetoothMock
import XCTest

@testable import iOS_BLE_Library_Mock

final class ServiceDiscoveryDisconnectTests: CentralManagerTestCase {

    /// Four services at a 0.5 s connection interval: the mock answers service discovery
    /// after `interval × count` = 2 s, which leaves room to disconnect mid-discovery.
    private func makeSlowLink() -> SimulatedPeripheral {
        SimulatedPeripheral(
            name: "Link",
            services: ["1810", "1811", "1812", "1813"].map { .primary(CBMUUID(string: $0)) },
            connectionInterval: 0.5)
    }

    /// Connects `device`, starts service discovery, waits until the mock has received the
    /// request, then drops the link. Returns the still-pending discovery task.
    private func startDiscoveryThenDisconnect(
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

        let dropped = expectDisconnect(of: cbPeripheral.identifier, on: central)
        device.spec.simulateDisconnection(withError: CBMError(.peripheralDisconnected))
        await fulfillment(of: [dropped], timeout: 3)

        return (peripheral, discovery)
    }

    /// C1 acceptance: "a disconnect mid-discovery fails all pending ops on that peripheral
    /// within 1 s". Today the awaiting publisher never completes.
    func testDisconnectDuringServiceDiscoveryFailsThePendingOperation() async throws {
        let link = makeSlowLink()
        let central = try makeCentral(peripherals: [link])
        let (_, discovery) = try await startDiscoveryThenDisconnect(link, on: central)
        defer { discovery.cancel() }

        let result = await outcome {
            try await withTimeout(1, "discoverServices after disconnect") { try await discovery.value }
        }

        XCTExpectFailure("i10 / CU-868m1mrcy: pending discovery ops are not failed on disconnect yet") {
            switch result {
            case .success:
                XCTFail("discoverServices must fail once the peripheral has disconnected")
            case .failure(is TimeoutError):
                XCTFail("discoverServices hung: the pending op was not failed within 1 s of the disconnect")
            case .failure:
                break  // What C1 delivers: the pending op fails with an error.
            }
        }
    }

    /// The wedge: with the head of the discovery queue never dequeued, the *next*
    /// `discoverServices()` on the same peripheral is enqueued behind it and never reaches
    /// CoreBluetooth, even after the peripheral reconnected.
    func testDiscoveryAfterReconnectIsNotStuckBehindTheWedgedOperation() async throws {
        let link = makeSlowLink()
        let central = try makeCentral(peripherals: [link])
        let (peripheral, discovery) = try await startDiscoveryThenDisconnect(link, on: central)
        defer { discovery.cancel() }

        // Let the mock's reply timer for the first discovery fire while we are disconnected
        // (see `SimulatedPeripheral.serviceDiscoveryLatency`); real CoreBluetooth would never
        // answer that request after a reconnect.
        try await Task.sleep(nanoseconds: UInt64((link.serviceDiscoveryLatency + 0.25) * 1_000_000_000))

        try await connect(peripheral.peripheral, on: central)
        let requestsBeforeRetry = link.serviceDiscoveryRequests

        let result = await outcome {
            try await withTimeout(4, "discoverServices after reconnect") {
                try await peripheral.discoverServices(serviceUUIDs: nil).firstValue
            }
        }
        let requestsAfterRetry = link.serviceDiscoveryRequests

        XCTExpectFailure("i10 / CU-868m1mrcy: the services queue wedges behind the op that never completed") {
            switch result {
            case .success(let services):
                XCTAssertEqual(services.count, 4)
            case .failure(is TimeoutError):
                XCTFail("discoverServices after reconnect hung")
            case .failure(let error):
                XCTFail("discoverServices after reconnect failed: \(error)")
            }
            XCTAssertEqual(
                requestsAfterRetry, requestsBeforeRetry + 1,
                "the retry never reached CoreBluetooth: it is queued behind the wedged op")
        }
    }
}
