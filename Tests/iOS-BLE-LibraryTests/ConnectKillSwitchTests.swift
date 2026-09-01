//
//  ConnectKillSwitchTests.swift
//
//  Regression test: an error-carrying disconnect from an UNRELATED peripheral
//  must not kill another peripheral's in-flight `connect()` publisher.
//

import XCTest
import Combine
import CoreBluetoothMock

@testable import iOS_BLE_Library_Mock

private extension CBMUUID {
    static let serviceA = CBMUUID(string: "180D")
    static let serviceB = CBMUUID(string: "180F")
}

private class MockDevice: CBMPeripheralSpecDelegate {
    let name: String
    let serviceUUID: CBMUUID

    private(set) lazy var peripheral = CBMPeripheralSpec
        .simulatePeripheral(proximity: .near)
        .advertising(
            advertisementData: [
                CBMAdvertisementDataIsConnectable: true as NSNumber,
                CBMAdvertisementDataLocalNameKey: name,
                CBMAdvertisementDataServiceUUIDsKey: [serviceUUID],
            ],
            withInterval: 0.25
        )
        .connectable(
            name: name,
            services: [CBMServiceMock(type: serviceUUID, primary: true)],
            delegate: self
        )
        .build()

    init(name: String, serviceUUID: CBMUUID) {
        self.name = name
        self.serviceUUID = serviceUUID
    }

    func peripheral(
        _ peripheral: CBMPeripheralSpec,
        didReceiveServiceDiscoveryRequest serviceUUIDs: [CBMUUID]?
    ) -> Result<Void, Error> {
        return .success(())
    }
}

final class ConnectKillSwitchTests: XCTestCase {

    var cancelables: Set<AnyCancellable>!
    var central: CentralManager!
    private var deviceA: MockDevice!
    private var deviceB: MockDevice!

    override func setUpWithError() throws {
        try super.setUpWithError()

        deviceA = MockDevice(name: "Device A", serviceUUID: .serviceA)
        deviceB = MockDevice(name: "Device B", serviceUUID: .serviceB)

        CBMCentralManagerMock.simulateInitialState(.poweredOn)
        CBMCentralManagerMock.simulatePeripherals([deviceA.peripheral, deviceB.peripheral])

        let cmd = ReactiveCentralManagerDelegate()
        let cm = CBCentralManagerFactory.instance(delegate: cmd, queue: .main, forceMock: true)
        central = try CentralManager(centralManager: cm)

        cancelables = Set()
    }

    override func tearDownWithError() throws {
        cancelables.removeAll()
        cancelables = nil
        central = nil
        deviceA = nil
        deviceB = nil
        CBMCentralManagerMock.tearDownSimulation()

        try super.tearDownWithError()
    }

    private func discover(service: CBMUUID) async throws -> CBPeripheral {
        let peripheral = try await central.scanForPeripherals(withServices: [service])
            .firstValue
            .peripheral
        central.stopScan()
        return peripheral
    }

    func testConnectSurvivesOtherPeripheralsErrorDisconnect() async throws {
        let a = try await discover(service: .serviceA)
        let b = try await discover(service: .serviceB)

        // Connect B and keep it connected.
        let bConnected = XCTestExpectation(description: "B connected")
        central.connect(b)
            .sink(receiveCompletion: { _ in }, receiveValue: { _ in bConnected.fulfill() })
            .store(in: &cancelables)
        await fulfillment(of: [bConnected], timeout: 5)

        // Start A's connect and keep its publisher alive.
        let aConnected = XCTestExpectation(description: "A connected")
        let aCompleted = XCTestExpectation(
            description: "A's connect publisher must stay alive after B's error disconnect")
        aCompleted.isInverted = true
        central.connect(a)
            .sink(receiveCompletion: { _ in
                // Any completion (failure OR finished) while A is still connected is the bug.
                aCompleted.fulfill()
            }, receiveValue: { _ in
                aConnected.fulfill()
            })
            .store(in: &cancelables)
        await fulfillment(of: [aConnected], timeout: 5)

        // B drops with an error. The mock delivers .connectionTimeout disconnects
        // after its simulated supervision timeout (~4s), hence the wide window.
        let bDropObserved = XCTestExpectation(description: "B's error disconnect observed")
        central.disconnectedPeripheralsChannel
            .filter { $0.0.identifier == b.identifier }
            .sink { _ in bDropObserved.fulfill() }
            .store(in: &cancelables)
        deviceB.peripheral.simulateDisconnection(withError: CBMError(.connectionTimeout))
        await fulfillment(of: [bDropObserved], timeout: 10)

        // Broken kill switch fired synchronously with the disconnect; give it a beat.
        await fulfillment(of: [aCompleted], timeout: 1)
        XCTAssertEqual(a.state, .connected, "A must remain connected after B's error disconnect")
    }
}
