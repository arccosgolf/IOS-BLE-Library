//
//  CentralManagerTests.swift
//  
//
//  Created by Nick Kibysh on 18/08/2023.
//
import XCTest
@testable import iOS_BLE_Library_Mock
import CoreBluetoothMock_Collection
import CoreBluetoothMock
import Combine

final class CentralManagerTests: XCTestCase {
    
    var cancelables: Set<AnyCancellable>!
    var central: CentralManager!
    var rs: RunningSpeedAndCadence!
    
    override func setUpWithError() throws {
        try super.setUpWithError()
        
        self.rs = RunningSpeedAndCadence()
        
        CBMCentralManagerMock.simulateInitialState(.poweredOn)
        CBMCentralManagerMock.simulatePeripherals([rs.peripheral])
        
        let cmd = ReactiveCentralManagerDelegate()
        let cm = CBCentralManagerFactory.instance(delegate: cmd, queue: .main, forceMock: true)
        self.central = try CentralManager(centralManager: cm)
        
        cancelables = Set()
    }

    override func tearDownWithError() throws {
        cancelables.removeAll()
        cancelables = nil
        central = nil
        rs = nil
        CBMCentralManagerMock.tearDownSimulation()
        
        try super.tearDownWithError()
    }
    
    func testCentralManagerCreation() throws {
        let cm1 = CBCentralManager(true)
        XCTAssertThrowsError(try CentralManager(centralManager: cm1), "Error should be thrown, as delegate is not ReactiveCentralManagerDelegate")
        
        let d = ReactiveCentralManagerDelegate()
        let cm2 = CBCentralManagerFactory.instance(delegate: d, queue: .main)
        XCTAssertNoThrow(try CentralManager(centralManager: cm2), "No error should be thrown")
    }

    func testScan() async {
        let valueExpectation = XCTestExpectation(description: "Receive at least 1 value (ScanResult)")
        let completionExpectation = XCTestExpectation(description: "Publisher finished")
        
        central.scanForPeripherals(withServices: nil)
            .prefix(1)
            .sink(receiveCompletion: { completion in
                switch completion {
                case .finished:
                    completionExpectation.fulfill()
                case .failure(let error):
                    XCTFail(error.localizedDescription)
                }
            }, receiveValue: { _ in
                valueExpectation.fulfill()
            })
            .store(in: &cancelables)
        
        await fulfillment(of: [valueExpectation, completionExpectation], timeout: 15)
    }
    
    func testFailedStateScan() async {
        CBMCentralManagerMock.simulatePowerOff()
        
        let expectation = XCTestExpectation(description: "Scan for peripherals")

        central.scanForPeripherals(withServices: nil)
            .sink(receiveCompletion: { completion in
                switch completion {
                case .finished:
                    XCTFail("Failure completion is expeted")
                case .failure(let error) where error is CentralManager.Err:
                    guard case CentralManager.Err.badState(let s) = error else {
                        XCTFail("Expected `badState` error. Found: \(error.localizedDescription)")
                        break
                    }
                    
                    XCTAssertEqual(s, .poweredOff)
                case .failure(let e):
                    XCTFail("Should be CentralManager.Error.badState. Found \(e.localizedDescription)")
                }
                expectation.fulfill()
            }, receiveValue: { _ in
                XCTFail("No peripherals are expected. Failure completion is expeted")
            })
            .store(in: &cancelables)
        
        await fulfillment(of: [expectation], timeout: 5)
    }

    func testStopScan() async {
        let firstExp = XCTestExpectation(description: "First scan for peripherals")
        let valueExpectation1 = XCTestExpectation(description: "1: Receive at least 1 value (ScanResult)")

        central.scanForPeripherals(withServices: nil)
            .sink(receiveCompletion: { completion in
                switch completion {
                case .finished:
                    firstExp.fulfill()
                case .failure(let e):
                    XCTFail("Found error: \(e.localizedDescription), instead of success result")
                }
                firstExp.fulfill()
            }, receiveValue: { _ in
                valueExpectation1.fulfill()
                self.central.stopScan()
            })
            .store(in: &cancelables)
        
        await fulfillment(of: [firstExp, valueExpectation1], timeout: 15)
        
        let valueExpectation2 = XCTestExpectation(description: "2: Receive at least 1 value (ScanResult)")
        let secondExp = XCTestExpectation(description: "Repeated scan for peripherals")
        
        central.scanForPeripherals(withServices: nil)
            .sink(receiveCompletion: { completion in
                switch completion {
                case .finished:
                    secondExp.fulfill()
                case .failure(let e):
                    XCTFail("Found error: \(e.localizedDescription), instead of success result")
                }
                secondExp.fulfill()
            }, receiveValue: { _ in
                valueExpectation2.fulfill()
                self.central.stopScan()
            })
            .store(in: &cancelables)
        
        await fulfillment(of: [secondExp, valueExpectation2], timeout: 15)
    }
    
    func testConnect() async throws {
        let connectionPeripheral = try await central.scanForPeripherals(withServices: nil)
            .firstValue
            .peripheral
        
        let connectionExpectation = XCTestExpectation(description: "Connection expectation")
        let disconnectionExpectation = XCTestExpectation(description: "Disconnection expectation")
        central.connect(connectionPeripheral)
            .sink { completion in
                switch completion {
                case .finished:
                    disconnectionExpectation.fulfill()
                case .failure(let e):
                    XCTFail(e.localizedDescription)
                }
            } receiveValue: { peripheral in
                XCTAssertEqual(peripheral.identifier, connectionPeripheral.identifier)
                connectionExpectation.fulfill()
            }
            .store(in: &cancelables)

        await fulfillment(of: [connectionExpectation], timeout: 3)
        
        central.cancelPeripheralConnection(connectionPeripheral)
            .sink { completion in
                if case .failure(let e) = completion {
                    XCTFail(e.localizedDescription)
                }
            } receiveValue: { peripheral in
                XCTAssertEqual(peripheral.identifier, connectionPeripheral.identifier)
            }
            .store(in: &cancelables)
        
        await fulfillment(of: [disconnectionExpectation], timeout: 3)
    }
    
    func testDisconnectFromPeripheral() async throws {
        let connectionPeripheral = try await central.scanForPeripherals(withServices: nil)
            .firstValue
            .peripheral
        
        let connectionExpectation = XCTestExpectation(description: "Connection expectation")
        let disconnectionExpectation = XCTestExpectation(description: "Disconnection expectation")
        
        central.connect(connectionPeripheral)
            .sink { completion in
                switch completion {
                case .finished:
                    XCTFail("Should disconnect with error")
                case .failure(let e as CBMError):
                    switch e.code {
                    case .peripheralDisconnected:
                        break
                    default:
                        XCTFail("`peripheralDisconnected` is expected. \(e.code) receiveb")
                    }
                case .failure(let e):
                    XCTFail("CBMError is expected. \(e.localizedDescription) received")
                }
                
                disconnectionExpectation.fulfill()
            } receiveValue: { peripheral in
                XCTAssertEqual(peripheral.identifier, connectionPeripheral.identifier)
                connectionExpectation.fulfill()
            }
            .store(in: &cancelables)

        await fulfillment(of: [connectionExpectation], timeout: 3)
        
        rs.peripheral.simulateDisconnection()

        await fulfillment(of: [disconnectionExpectation], timeout: 3)
    }

    // MARK: - Kill-switch identity (cross-peripheral disconnect isolation)

    /// `connect(_:options:)`'s kill switch listens on the global `disconnectedPeripheralsChannel`,
    /// which carries every peripheral's disconnects. An error-carrying disconnect from an
    /// UNRELATED peripheral must not fail this peripheral's connect publisher — only the
    /// peripheral's own disconnect may end it (that case is covered by
    /// `testDisconnectFromPeripheral`). Regression test for the predicate ordering that let any
    /// peripheral's disconnect error kill every in-flight connect.
    func testConnectSurvivesOtherPeripheralsErrorDisconnect() async throws {
        // Rebuild the simulation with two peripherals: setUp registered only one, and
        // `simulatePeripherals` is a silent no-op while a central manager instance exists.
        cancelables.removeAll()
        central = nil
        CBMCentralManagerMock.tearDownSimulation()

        let deviceA = RunningSpeedAndCadence()
        let deviceB = RunningSpeedAndCadence()
        CBMCentralManagerMock.simulateInitialState(.poweredOn)
        CBMCentralManagerMock.simulatePeripherals([deviceA.peripheral, deviceB.peripheral])
        let cmd = ReactiveCentralManagerDelegate()
        let cm = CBCentralManagerFactory.instance(delegate: cmd, queue: .main, forceMock: true)
        central = try CentralManager(centralManager: cm)

        // Discover both peripherals (RSC specs advertise with a 5s delay — allow the long timeout).
        let bothDiscovered = XCTestExpectation(description: "Both peripherals discovered")
        bothDiscovered.assertForOverFulfill = false
        var discovered: [UUID: CBPeripheral] = [:]
        central.scanForPeripherals(withServices: nil)
            .sink(receiveCompletion: { _ in }, receiveValue: { result in
                discovered[result.peripheral.identifier] = result.peripheral
                if discovered.count == 2 {
                    bothDiscovered.fulfill()
                }
            })
            .store(in: &cancelables)
        await fulfillment(of: [bothDiscovered], timeout: 15)
        central.stopScan()

        let peripheralA = try XCTUnwrap(discovered[deviceA.peripheral.identifier])
        let peripheralB = try XCTUnwrap(discovered[deviceB.peripheral.identifier])

        // Connect A. Its publisher must stay alive until A's own disconnect — and that
        // disconnect is a clean one, so the publisher must complete with `.finished`.
        let aConnected = XCTestExpectation(description: "A connected")
        let aFinishedCleanly = XCTestExpectation(description: "A finished without error")
        central.connect(peripheralA)
            .sink { completion in
                switch completion {
                case .finished:
                    aFinishedCleanly.fulfill()
                case .failure(let e):
                    XCTFail("A's connect must not fail on B's disconnect error. Got: \(e)")
                }
            } receiveValue: { peripheral in
                XCTAssertEqual(peripheral.identifier, peripheralA.identifier)
                aConnected.fulfill()
            }
            .store(in: &cancelables)
        await fulfillment(of: [aConnected], timeout: 3)

        // Connect B, then drop it with an error while A's connect publisher is live.
        let bConnected = XCTestExpectation(description: "B connected")
        let bFailed = XCTestExpectation(description: "B failed with its own error")
        central.connect(peripheralB)
            .sink { completion in
                if case .failure = completion {
                    bFailed.fulfill()
                }
            } receiveValue: { _ in
                bConnected.fulfill()
            }
            .store(in: &cancelables)
        await fulfillment(of: [bConnected], timeout: 3)

        // `.connectionTimeout` matches the field failure this guards against. The mock
        // deliberately delays delivering timeout-flavored disconnects by the supervision
        // timeout (4s, hardcoded in CBMCentralManagerMock) — hence the wide window.
        deviceB.peripheral.simulateDisconnection(withError: CBMError(.connectionTimeout))
        await fulfillment(of: [bFailed], timeout: 10)

        // A must still be connected with a live publisher: a clean cancel completes it
        // with `.finished`. Pre-fix, B's error above already failed A's publisher and
        // the XCTFail in A's completion fired instead.
        central.cancelPeripheralConnection(peripheralA)
            .sink(receiveCompletion: { _ in }, receiveValue: { _ in })
            .store(in: &cancelables)
        await fulfillment(of: [aFinishedCleanly], timeout: 3)
    }
}
