//
//  CancellationSideEffectTests.swift
//
//  Wave C3 (review finding i3, CU-868m1mrjy). Every publisher other than `connect` must undo
//  its CoreBluetooth side effect when its subscription ends, where CoreBluetooth offers a way
//  to: a scan stops the radio, a discovery request that is still queued (not yet issued) is
//  withdrawn. A discovery request already in flight has no cancel in CoreBluetooth; it stays
//  in flight so its reply is attributed correctly and the lane advances.
//

import Combine
import CoreBluetoothMock
import XCTest

@testable import iOS_BLE_Library_Mock

final class CancellationSideEffectTests: CentralManagerTestCase {

    private static let serviceUUIDs = ["1810", "1811", "1812", "1813"].map { CBMUUID(string: $0) }

    /// Four services at a 0.5 s connection interval: the mock answers service discovery
    /// after 2 s, which leaves room to queue and cancel behind the in-flight request.
    private func makeSlowLink() -> SimulatedPeripheral {
        SimulatedPeripheral(
            name: "Link",
            services: Self.serviceUUIDs.map { .primary($0) },
            connectionInterval: 0.5)
    }

    /// A silent peripheral: a scan for it never matches, so the scan publisher stays alive.
    private func makeSilentLink() -> SimulatedPeripheral {
        SimulatedPeripheral(name: "Link", services: [.primary(CBMUUID(string: "180D"))], advertisingInterval: nil)
    }

    // MARK: Scan

    func testCancellingTheScanSubscriptionStopsTheRadio() async throws {
        let central = try makeCentral(peripherals: [makeSilentLink()])
        try await waitForPowerOn(central)

        let subscription = central.scanForPeripherals(withServices: nil)
            .sink(receiveCompletion: { _ in }, receiveValue: { _ in })
        try await waitUntil(2, "scan started") { central.centralManager.isScanning }

        subscription.cancel()

        XCTAssertFalse(central.centralManager.isScanning, "an unsubscribed scan must not keep the radio on")
    }

    func testCancellingTheScanningTaskStopsTheRadio() async throws {
        // The app's scanner shape: `for try await` over `.values`, ended by cancelling the task.
        let central = try makeCentral(peripherals: [makeSilentLink()])
        try await waitForPowerOn(central)

        // The library's own async wrapper, spelled out: under `@testable import` its `values`
        // extension makes the bare `.values` the app uses ambiguous, and Combine's wrapper
        // needs iOS 15 while the package targets iOS 13. Both cancel the subscription when
        // the task is cancelled, which is the behaviour under test.
        let scanning = Task {
            for try await _ in iOS_BLE_Library_Mock.AsyncThrowingPublisher(central.scanForPeripherals(withServices: nil)) {}
        }
        try await waitUntil(2, "scan started") { central.centralManager.isScanning }

        scanning.cancel()

        try await waitUntil(1, "radio stopped") { !central.centralManager.isScanning }
    }

    func testTakingTheFirstScanResultStopsTheRadio() async throws {
        let link = SimulatedPeripheral(name: "Link", services: [.primary(CBMUUID(string: "180D"))])
        let central = try makeCentral(peripherals: [link])
        try await waitForPowerOn(central)

        let result = try await withTimeout(3, "first scan result") {
            try await central.scanForPeripherals(withServices: nil).firstValue
        }

        XCTAssertEqual(result.peripheral.identifier, link.identifier)
        XCTAssertFalse(central.centralManager.isScanning, "`firstValue` ended the subscription, so the scan must be over")
    }

    func testStopScanStillFinishesTheScanPublisherWithoutRestartingIt() async throws {
        // `stopScan()` finishes the publisher (the pre-C3 contract the app's scanner relies
        // on); the cancel hook must not interfere with that route or leave the radio on.
        let central = try makeCentral(peripherals: [makeSilentLink()])
        try await waitForPowerOn(central)

        let finished = XCTestExpectation(description: "scan publisher finished")
        central.scanForPeripherals(withServices: nil)
            .sink(receiveCompletion: { completion in
                if case .finished = completion { finished.fulfill() }
            }, receiveValue: { _ in })
            .store(in: &cancellables)
        try await waitUntil(2, "scan started") { central.centralManager.isScanning }

        central.stopScan()

        await fulfillment(of: [finished], timeout: 1)
        XCTAssertFalse(central.centralManager.isScanning)
    }

    // MARK: Discovery: a queued request is withdrawn, an in-flight one is not

    /// Connects `device` and starts a service discovery that the mock has received but not yet
    /// answered (it answers after `serviceDiscoveryLatency`).
    private func connectAndStartSlowServiceDiscovery(
        _ device: SimulatedPeripheral, on central: CentralManager
    ) async throws -> (Peripheral, Task<[CBService], Error>) {
        let cbPeripheral = try await discover(device, on: central)
        try await connect(cbPeripheral, on: central)
        let peripheral = Peripheral(peripheral: cbPeripheral)

        let requestSeen = expectation(description: "mock received the first service discovery request")
        device.onServiceDiscoveryRequest = { _ in requestSeen.fulfill() }
        let inFlight = Task { try await peripheral.discoverServices(serviceUUIDs: nil).firstValue }
        await fulfillment(of: [requestSeen], timeout: 2)
        device.onServiceDiscoveryRequest = nil
        return (peripheral, inFlight)
    }

    func testCancellingAQueuedServiceDiscoveryWithdrawsItBeforeItIsIssued() async throws {
        let link = makeSlowLink()
        let central = try makeCentral(peripherals: [link])
        let (peripheral, inFlight) = try await connectAndStartSlowServiceDiscovery(link, on: central)
        let lanes = peripheral.peripheralDelegate.serviceDiscovery

        let queued = peripheral.discoverServices(serviceUUIDs: nil)
            .sink(receiveCompletion: { _ in XCTFail("a withdrawn request must not complete") },
                  receiveValue: { _ in XCTFail("a withdrawn request must not emit") })
        XCTAssertEqual(lanes.pendingCount, 2, "second request queued behind the in-flight one")

        queued.cancel()

        XCTAssertEqual(lanes.pendingCount, 1, "the queued request is withdrawn on cancel")
        let services = try await withTimeout(link.serviceDiscoveryLatency + 1, "in-flight discovery") {
            try await inFlight.value
        }
        XCTAssertEqual(services.count, Self.serviceUUIDs.count)

        // Give the lane a beat: with the head gone, a still-queued request would be issued now.
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(link.serviceDiscoveryRequests, 1, "the withdrawn request must never reach the mock")
        XCTAssertTrue(lanes.isEmpty)
    }

    func testCancellingTheInFlightServiceDiscoveryLeavesItInFlightAndTheLaneAdvances() async throws {
        let link = makeSlowLink()
        let central = try makeCentral(peripherals: [link])
        let cbPeripheral = try await discover(link, on: central)
        try await connect(cbPeripheral, on: central)
        let peripheral = Peripheral(peripheral: cbPeripheral)
        let lanes = peripheral.peripheralDelegate.serviceDiscovery

        let requestSeen = expectation(description: "mock received the first request")
        link.onServiceDiscoveryRequest = { _ in requestSeen.fulfill() }
        let inFlight = peripheral.discoverServices(serviceUUIDs: nil)
            .sink(receiveCompletion: { _ in }, receiveValue: { _ in })
        await fulfillment(of: [requestSeen], timeout: 2)
        link.onServiceDiscoveryRequest = nil

        let queued = Task { try await peripheral.discoverServices(serviceUUIDs: nil).firstValue }
        try await waitUntil(1, "second request queued") { lanes.pendingCount == 2 }

        inFlight.cancel()

        XCTAssertEqual(lanes.pendingCount, 2, "an in-flight request cannot be withdrawn; it stays until its reply")
        let services = try await withTimeout(2 * link.serviceDiscoveryLatency + 1, "queued discovery") {
            try await queued.value
        }
        XCTAssertEqual(services.count, Self.serviceUUIDs.count)
        XCTAssertEqual(link.serviceDiscoveryRequests, 2, "the reply to the abandoned request advanced the lane")
        XCTAssertTrue(lanes.isEmpty)
    }

    func testCancellingAQueuedCharacteristicDiscoveryWithdrawsIt() async throws {
        // Same lane semantics for the second discovery type: same-service requests serialise.
        let characteristics = ["2A19", "2A1A", "2A1B", "2A1C"].map {
            CBMCharacteristicMock(type: CBMUUID(string: $0), properties: .read)
        }
        let service = CBMServiceMock.primary(CBMUUID(string: "180F"), characteristics: characteristics)
        let link = SimulatedPeripheral(name: "Link", services: [service], connectionInterval: 0.5)
        let central = try makeCentral(peripherals: [link])
        let cbPeripheral = try await discover(link, on: central)
        try await connect(cbPeripheral, on: central)
        let peripheral = Peripheral(peripheral: cbPeripheral)
        let discovered = try await withTimeout(3, "discoverServices") {
            try await peripheral.discoverServices(serviceUUIDs: nil).firstValue
        }
        let cbService = try XCTUnwrap(discovered.first)
        let lanes = peripheral.peripheralDelegate.characteristicDiscovery

        let requestSeen = expectation(description: "mock received the first characteristic request")
        link.onCharacteristicDiscoveryRequest = { _, _ in requestSeen.fulfill() }
        let inFlight = Task { try await peripheral.discoverCharacteristics(nil, for: cbService).firstValue }
        await fulfillment(of: [requestSeen], timeout: 2)
        link.onCharacteristicDiscoveryRequest = nil

        let queued = peripheral.discoverCharacteristics(nil, for: cbService)
            .sink(receiveCompletion: { _ in XCTFail("withdrawn") }, receiveValue: { _ in XCTFail("withdrawn") })
        XCTAssertEqual(lanes.pendingCount, 2)

        queued.cancel()

        XCTAssertEqual(lanes.pendingCount, 1)
        let result = try await withTimeout(link.characteristicDiscoveryLatency(for: service) + 1, "in-flight") {
            try await inFlight.value
        }
        XCTAssertEqual(result.count, characteristics.count)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(link.characteristicDiscoveryRequests, 1)
    }

    func testCancellingAQueuedDescriptorDiscoveryWithdrawsIt() async throws {
        let descriptors = ["2900", "2901", "2902", "2904"].map { CBMDescriptorMock(type: CBMUUID(string: $0)) }
        let characteristic = CBMCharacteristicMock(
            type: CBMUUID(string: "2A19"), properties: .read,
            descriptors: descriptors[0], descriptors[1], descriptors[2], descriptors[3])
        let service = CBMServiceMock.primary(CBMUUID(string: "180F"), characteristics: [characteristic])
        let link = SimulatedPeripheral(name: "Link", services: [service], connectionInterval: 0.5)
        let central = try makeCentral(peripherals: [link])
        let cbPeripheral = try await discover(link, on: central)
        try await connect(cbPeripheral, on: central)
        let peripheral = Peripheral(peripheral: cbPeripheral)
        let services = try await withTimeout(3, "discoverServices") {
            try await peripheral.discoverServices(serviceUUIDs: nil).firstValue
        }
        let cbService = try XCTUnwrap(services.first)
        let cbCharacteristics = try await withTimeout(3, "discoverCharacteristics") {
            try await peripheral.discoverCharacteristics(nil, for: cbService).firstValue
        }
        let cbCharacteristic = try XCTUnwrap(cbCharacteristics.first)
        let lanes = peripheral.peripheralDelegate.descriptorDiscovery

        let requestSeen = expectation(description: "mock received the first descriptor request")
        link.onDescriptorDiscoveryRequest = { _, _ in requestSeen.fulfill() }
        let inFlight = Task { try await peripheral.discoverDescriptors(for: cbCharacteristic).firstValue }
        await fulfillment(of: [requestSeen], timeout: 2)
        link.onDescriptorDiscoveryRequest = nil

        let queued = peripheral.discoverDescriptors(for: cbCharacteristic)
            .sink(receiveCompletion: { _ in XCTFail("withdrawn") }, receiveValue: { _ in XCTFail("withdrawn") })
        XCTAssertEqual(lanes.pendingCount, 2)

        queued.cancel()

        XCTAssertEqual(lanes.pendingCount, 1)
        let result = try await withTimeout(link.descriptorDiscoveryLatency(for: characteristic) + 1, "in-flight") {
            try await inFlight.value
        }
        XCTAssertEqual(result.count, descriptors.count)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(link.descriptorDiscoveryRequests, 1)
    }
}
