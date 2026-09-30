//
//  CentralManagerDelegateHygieneTests.swift
//
//  Wave C3 hygiene fold-ins (CU-868m1mrjy, from the umbrella CU-868kx8b51). Both disconnect
//  delegate selectors used to publish independently, so one disconnect could surface twice
//  with contradictory `isReconnecting` values; and the ANCS authorization callback was a
//  `fatalError`. CoreBluetooth is not consistent about which selector it uses (the mock calls
//  the timestamp one, a device was seen calling the legacy one), so neither may be ignored:
//  whichever arrives first publishes, the other's delivery of the same event is dropped.
//  These tests drive the delegate methods directly to reproduce every ordering.
//

import Combine
import CoreBluetoothMock
import XCTest

@testable import iOS_BLE_Library_Mock

final class CentralManagerDelegateHygieneTests: CentralManagerTestCase {

    private func makeLink() -> SimulatedPeripheral {
        SimulatedPeripheral(name: "Link", services: [.primary(CBMUUID(string: "180D"))])
    }

    /// Subscribes *now* and collects every disconnect the central publishes.
    private func collectDisconnects(on central: CentralManager) -> EventBox<(UUID, Bool, Error?)> {
        let box = EventBox<(UUID, Bool, Error?)>()
        central.disconnectedPeripheralsChannel
            .sink { box.append(($0.0.identifier, $0.1, $0.2)) }
            .store(in: &cancellables)
        return box
    }

    /// Lets the delivery settle: subjects publish synchronously, so one hop is plenty.
    private func settle() async throws {
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    // MARK: One disconnect, one emission

    func testTimestampVariantPublishesOnceWithItsReconnectFlag() async throws {
        let link = makeLink()
        let central = try makeCentral(peripherals: [link])
        let peripheral = try await discover(link, on: central)
        let disconnects = collectDisconnects(on: central)

        central.centralManagerDelegate.centralManager(
            central.centralManager, didDisconnectPeripheral: peripheral,
            timestamp: CFAbsoluteTimeGetCurrent(), isReconnecting: true,
            error: CBMError(.peripheralDisconnected))
        try await settle()

        XCTAssertEqual(disconnects.count, 1)
        XCTAssertEqual(disconnects.values.first?.0, peripheral.identifier)
        XCTAssertEqual(disconnects.values.first?.1, true)
        XCTAssertEqual((disconnects.values.first?.2 as? CBMError)?.code, .peripheralDisconnected)
    }

    func testLegacyVariantAlonePublishesWithReconnectFlagFromTheHandle() async throws {
        // A device that delivers only the legacy selector must still see its disconnects.
        // The legacy selector carries no isReconnecting; it comes from the handle's state.
        let link = makeLink()
        let central = try makeCentral(peripherals: [link])
        let peripheral = try await discover(link, on: central)
        let disconnects = collectDisconnects(on: central)

        central.centralManagerDelegate.centralManager(
            central.centralManager, didDisconnectPeripheral: peripheral, error: CBMError(.peripheralDisconnected))
        try await settle()

        XCTAssertEqual(disconnects.count, 1, "the legacy selector must publish when it is the only delivery")
        XCTAssertEqual(disconnects.values.first?.1, false, "a `.disconnected` handle is not reconnecting")
        XCTAssertEqual((disconnects.values.first?.2 as? CBMError)?.code, .peripheralDisconnected)
    }

    func testBothVariantsForOneDisconnectPublishExactlyOnce() async throws {
        // The field shape behind "duplicate emissions with contradictory isReconnecting": the
        // system delivers the timestamp variant with `true`, then the legacy one for the same event.
        let link = makeLink()
        let central = try makeCentral(peripherals: [link])
        let peripheral = try await discover(link, on: central)
        let disconnects = collectDisconnects(on: central)
        let error = CBMError(.connectionTimeout)

        central.centralManagerDelegate.centralManager(
            central.centralManager, didDisconnectPeripheral: peripheral,
            timestamp: CFAbsoluteTimeGetCurrent(), isReconnecting: true, error: error)
        central.centralManagerDelegate.centralManager(
            central.centralManager, didDisconnectPeripheral: peripheral, error: error)
        try await settle()

        XCTAssertEqual(disconnects.count, 1, "one disconnect, one emission")
        XCTAssertEqual(disconnects.values.first?.1, true, "and it carries the system's isReconnecting, not a derived `false`")
    }

    func testLegacyThenTimestampForOneDisconnectPublishExactlyOnce() async throws {
        // Same event, other order.
        let link = makeLink()
        let central = try makeCentral(peripherals: [link])
        let peripheral = try await discover(link, on: central)
        let disconnects = collectDisconnects(on: central)
        let error = CBMError(.connectionTimeout)

        central.centralManagerDelegate.centralManager(
            central.centralManager, didDisconnectPeripheral: peripheral, error: error)
        central.centralManagerDelegate.centralManager(
            central.centralManager, didDisconnectPeripheral: peripheral,
            timestamp: CFAbsoluteTimeGetCurrent(), isReconnecting: false, error: error)
        try await settle()

        XCTAssertEqual(disconnects.count, 1, "one disconnect, one emission")
    }

    func testADifferentErrorIsANewDisconnectNotADuplicate() async throws {
        // Link loss with an error, then the armed reconnect is cancelled (error-free): two
        // events, even though they arrive through different selectors within the window.
        let link = makeLink()
        let central = try makeCentral(peripherals: [link])
        let peripheral = try await discover(link, on: central)
        let disconnects = collectDisconnects(on: central)

        central.centralManagerDelegate.centralManager(
            central.centralManager, didDisconnectPeripheral: peripheral,
            timestamp: CFAbsoluteTimeGetCurrent(), isReconnecting: true, error: CBMError(.peripheralDisconnected))
        central.centralManagerDelegate.centralManager(
            central.centralManager, didDisconnectPeripheral: peripheral, error: nil)
        try await settle()

        XCTAssertEqual(disconnects.values.map { $0.1 }, [true, false])
    }

    func testTheSameSelectorTwiceIsTwoDisconnects() async throws {
        // Two genuine disconnects always come through the same selector; never dedupe those.
        let link = makeLink()
        let central = try makeCentral(peripherals: [link])
        let peripheral = try await discover(link, on: central)
        let disconnects = collectDisconnects(on: central)
        let error = CBMError(.peripheralDisconnected)

        for _ in 0..<2 {
            central.centralManagerDelegate.centralManager(
                central.centralManager, didDisconnectPeripheral: peripheral, error: error)
        }
        try await settle()

        XCTAssertEqual(disconnects.count, 2)
    }

    func testAConnectInBetweenMakesTheOtherSelectorANewDisconnect() async throws {
        // disconnect (timestamp) -> connect -> disconnect (legacy), all inside the window: the
        // connect resets the pairing, so the second disconnect publishes.
        let link = makeLink()
        let central = try makeCentral(peripherals: [link])
        let peripheral = try await discover(link, on: central)
        let disconnects = collectDisconnects(on: central)
        let error = CBMError(.peripheralDisconnected)

        central.centralManagerDelegate.centralManager(
            central.centralManager, didDisconnectPeripheral: peripheral,
            timestamp: CFAbsoluteTimeGetCurrent(), isReconnecting: false, error: error)
        central.centralManagerDelegate.centralManager(central.centralManager, didConnect: peripheral)
        central.centralManagerDelegate.centralManager(
            central.centralManager, didDisconnectPeripheral: peripheral, error: error)
        try await settle()

        XCTAssertEqual(disconnects.count, 2)
    }

    func testTheOtherSelectorAfterTheWindowIsANewDisconnect() async throws {
        let link = makeLink()
        let central = try makeCentral(peripherals: [link])
        let peripheral = try await discover(link, on: central)
        let disconnects = collectDisconnects(on: central)
        let error = CBMError(.peripheralDisconnected)
        central.centralManagerDelegate.duplicateDisconnectWindow = 0.05

        central.centralManagerDelegate.centralManager(
            central.centralManager, didDisconnectPeripheral: peripheral,
            timestamp: CFAbsoluteTimeGetCurrent(), isReconnecting: false, error: error)
        try await Task.sleep(nanoseconds: 100_000_000)
        central.centralManagerDelegate.centralManager(
            central.centralManager, didDisconnectPeripheral: peripheral, error: error)
        try await settle()

        XCTAssertEqual(disconnects.count, 2)
    }

    func testARealDisconnectFromTheMockIsPublishedOnce() async throws {
        // End to end through CoreBluetoothMock, which calls the timestamp variant.
        let link = makeLink()
        let central = try makeCentral(peripherals: [link])
        let peripheral = try await discover(link, on: central)
        try await connect(peripheral, on: central)
        let disconnects = collectDisconnects(on: central)

        let dropped = expectDisconnect(of: peripheral.identifier, on: central)
        link.spec.simulateDisconnection(withError: CBMError(.peripheralDisconnected))
        await fulfillment(of: [dropped], timeout: 2)
        try await settle()

        XCTAssertEqual(disconnects.count, 1)
        XCTAssertEqual(disconnects.values.first?.1, false)
    }

    // MARK: ANCS

    #if !os(macOS)
    func testANCSAuthorizationChangePublishesInsteadOfCrashing() async throws {
        let link = makeLink()
        let central = try makeCentral(peripherals: [link])
        let peripheral = try await discover(link, on: central)

        let published = XCTestExpectation(description: "ANCS change published")
        central.ancsAuthorizationChannel
            .sink { changed in
                XCTAssertEqual(changed.identifier, peripheral.identifier)
                published.fulfill()
            }
            .store(in: &cancellables)

        central.centralManagerDelegate.centralManager(
            central.centralManager, didUpdateANCSAuthorizationFor: peripheral)

        await fulfillment(of: [published], timeout: 1)
    }
    #endif
}
