//
//  CentralManagerTestCase.swift
//
//  Arccos test support.
//
//  Base class for tests that drive `CentralManager` / `Peripheral` against
//  CoreBluetoothMock. The mock keeps process-wide state (the simulated peripheral
//  list, the manager registry, `simulateStateRestoration`), so tests must run serially
//  and reset all of it; this class owns that lifecycle and the handful of async helpers
//  every scenario starts with (power-on, scan, connect, "expect a disconnect").
//

import Combine
import CoreBluetoothMock
import XCTest

@testable import iOS_BLE_Library_Mock

class CentralManagerTestCase: XCTestCase {

    var cancellables = Set<AnyCancellable>()
    private(set) var devices: [SimulatedPeripheral] = []

    override func setUp() {
        super.setUp()
        CBMCentralManagerMock.simulateInitialState(.poweredOn)
    }

    override func tearDown() {
        cancellables.removeAll()
        devices.removeAll()
        CBMCentralManagerMock.simulateStateRestoration = nil
        CBMCentralManagerMock.tearDownSimulation()
        super.tearDown()
    }

    // MARK: Construction

    /// Registers `peripherals` with the simulation and returns a mock-backed `CentralManager`.
    ///
    /// Always goes through `CBMCentralManagerFactory` with `forceMock: true`: on a macOS host
    /// (where `swift test` runs) the factory would otherwise hand back the *native*
    /// CoreBluetooth manager, and `CentralManager`'s own mock-flavour initializer does not
    /// force the mock.
    ///
    /// - Parameter restoreIdentifier: When set, the manager is created with
    ///   `CBCentralManagerOptionRestoreIdentifierKey`. CoreBluetoothMock then consults
    ///   `CBMCentralManagerMock.simulateStateRestoration` and delivers `willRestoreState`
    ///   **synchronously inside the manager's initializer**, i.e. before this function returns
    ///   and before any subscriber can exist. That is the timing the fork's restoration buffer
    ///   was written for.
    func makeCentral(
        peripherals: [SimulatedPeripheral],
        restoreIdentifier: String? = nil,
        queue: DispatchQueue = .main
    ) throws -> CentralManager {
        devices = peripherals
        CBMCentralManagerMock.simulatePeripherals(peripherals.map { $0.spec })

        var options: [String: Any]?
        if let restoreIdentifier {
            options = [CBMCentralManagerOptionRestoreIdentifierKey: restoreIdentifier]
        }

        let delegate = ReactiveCentralManagerDelegate()
        let manager = CBMCentralManagerFactory.instance(
            delegate: delegate, queue: queue, options: options, forceMock: true)
        return try CentralManager(centralManager: manager)
    }

    // MARK: Scenario helpers

    /// Waits for the mock to report `.poweredOn`. Every await in the harness is bounded, so
    /// a test that stalls names the step it stalled on instead of hanging the suite.
    func waitForPowerOn(_ central: CentralManager, timeout: TimeInterval = 5) async throws {
        try await withTimeout(timeout, "power on") {
            try await central.isPoweredOn()
        }
    }

    /// Scans for `device`'s services until it shows up, then stops the scan.
    func discover(
        _ device: SimulatedPeripheral,
        on central: CentralManager,
        timeout: TimeInterval = 5
    ) async throws -> CBPeripheral {
        try await waitForPowerOn(central)
        let peripheral = try await withTimeout(timeout, "scan for \(device.name)") {
            try await central.scanForPeripherals(withServices: device.services.map { $0.uuid })
                .first { $0.peripheral.identifier == device.identifier }
                .firstValue
                .peripheral
        }
        central.stopScan()
        return peripheral
    }

    /// Issues `connect()` and returns once the central reports the peripheral connected.
    ///
    /// Only the first value is awaited, so the subscription ends the moment the peripheral
    /// connects; `keepPendingOnAbandon: true` is what keeps the OS-level connection up
    /// afterwards (Wave C3). This is the app's own connect shape.
    func connect(
        _ peripheral: CBPeripheral,
        on central: CentralManager,
        options: [String: Any]? = nil,
        timeout: TimeInterval = 5
    ) async throws {
        try await waitForPowerOn(central)
        try await withTimeout(timeout, "connect \(peripheral.identifier)") {
            _ = try await central.connect(peripheral, options: options, keepPendingOnAbandon: true).firstValue
        }
    }

    /// Polls `condition` every 20 ms until it holds, or throws `TimeoutError` after `timeout`.
    func waitUntil(
        _ timeout: TimeInterval = 2,
        _ label: String = "condition",
        _ condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                throw TimeoutError(seconds: timeout, label: label)
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Subscribes *now* and returns an expectation that is fulfilled when the central reports
    /// a disconnect for `identifier`. Subscribe-before-trigger avoids missing a synchronous event.
    ///
    /// The expectation is not registered with the test case, so it only counts when passed to
    /// `fulfillment(of:)`.
    func expectDisconnect(
        of identifier: UUID,
        on central: CentralManager
    ) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "disconnect of \(identifier)")
        central.disconnectedPeripheralsChannel
            .filter { $0.0.identifier == identifier }
            .first()
            .sink { _ in expectation.fulfill() }
            .store(in: &cancellables)
        return expectation
    }

    /// Subscribes *now* to the restoration channel and collects every event into the
    /// returned box; the expectation is fulfilled on the first one. It is not registered
    /// with the test case, so synchronous tests can ignore it.
    func collectRestorationEvents(
        on central: CentralManager
    ) -> (events: EventBox<[String: Any]>, first: XCTestExpectation) {
        let box = EventBox<[String: Any]>()
        let first = XCTestExpectation(description: "first restoration event")
        first.assertForOverFulfill = false
        central.restoredPeripheralsChannel
            .sink { event in
                box.append(event)
                first.fulfill()
            }
            .store(in: &cancellables)
        return (box, first)
    }
}

/// A lock-guarded append-only list for values captured inside a `sink` and read from the
/// test's own task.
final class EventBox<Element> {
    private let lock = NSLock()
    private var storage: [Element] = []

    var values: [Element] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    var count: Int { values.count }
    var isEmpty: Bool { values.isEmpty }

    func append(_ element: Element) {
        lock.lock(); defer { lock.unlock() }
        storage.append(element)
    }
}
