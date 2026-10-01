//
//  UnsubscribedPublisherGuardTests.swift
//
//  Wave C4 (CU-868m1mrny). Every publisher the library returns is cold: the CoreBluetooth
//  request is issued when the first subscriber arrives, not when the publisher is created.
//  `let _ = centralManager.connect(...)` compiled, logged nothing and issued nothing, and
//  that shape sat in the app's background-monitoring connect path for its entire life (A9,
//  app PR #1824). These tests pin the guard: a Bluetooth publisher released without ever
//  being subscribed is reported through `BluetoothPublisherDiagnostics`, and a publisher that
//  was subscribed, by any route, never is.
//

import Combine
import CoreBluetoothMock
import XCTest

@testable import iOS_BLE_Library_Mock

final class UnsubscribedPublisherGuardTests: CentralManagerTestCase {

    private typealias Report = BluetoothPublisherDiagnostics.DroppedUnsubscribed

    private let serviceUUID = CBMUUID(string: "180D")
    private var reports: EventBox<Report>!
    private var previousHandler: (@Sendable (Report) -> Void)!

    override func setUp() {
        super.setUp()
        // The default handler traps a debug build (`assertionFailure`), which is the point of
        // the guard but not something XCTest can observe; capture the reports instead.
        let box = EventBox<Report>()
        reports = box
        previousHandler = BluetoothPublisherDiagnostics.onDroppedUnsubscribed
        BluetoothPublisherDiagnostics.onDroppedUnsubscribed = { box.append($0) }
    }

    override func tearDown() {
        BluetoothPublisherDiagnostics.onDroppedUnsubscribed = previousHandler
        super.tearDown()
    }

    private func makeLink() -> SimulatedPeripheral {
        SimulatedPeripheral(name: "Link", services: [.primary(serviceUUID)], connectionInterval: 0.045)
    }

    /// A central and a discovered handle, with the mock powered on and no report so far (the
    /// harness's own scan and connect are subscribed, so they must not have produced one).
    private func makeCentralAndPeripheral() async throws -> (SimulatedPeripheral, CentralManager, CBPeripheral) {
        let link = makeLink()
        let central = try makeCentral(peripherals: [link])
        let peripheral = try await discover(link, on: central)
        try await waitForPowerOn(central)
        XCTAssertTrue(reports.isEmpty, "the harness's subscribed publishers must not be reported")
        return (link, central, peripheral)
    }

    private func waitForReport(_ label: String = "report") async throws -> Report {
        try await waitUntil(1, label) { !self.reports.isEmpty }
        return try XCTUnwrap(reports.values.first)
    }

    // MARK: connect: the shape that neutered the app's background-monitoring path

    func testDroppingAConnectPublisherUnsubscribedIsReportedAndIssuesNothing() async throws {
        let (link, central, peripheral) = try await makeCentralAndPeripheral()

        _ = central.connect(peripheral, keepPendingOnAbandon: true)

        let report = try await waitForReport()
        XCTAssertEqual(report.operation, "connect(\(peripheral.identifier.uuidString), keepPendingOnAbandon: true)")
        XCTAssertLessThan(report.heldFor, 1, "a `let _ =` holds the publisher for microseconds")

        // Nothing was issued: not to the mock, not into the inventory, and nothing lands later.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(link.connectionRequests, 0, "the mock must never see a connect for an unsubscribed publisher")
        XCTAssertEqual(peripheral.state, .disconnected)
        XCTAssertTrue(central.connectInventory.isEmpty)
        XCTAssertEqual(reports.count, 1, "one release, one report")
    }

    func testAStoredConnectPublisherIsReportedWhenItsOwnerLetsGo() async throws {
        // Stored in a property "for later" and never subscribed: silent while held, reported
        // when the owner is released, with `heldFor` telling the two shapes apart.
        final class Owner { var publisher: AnyPublisher<CBPeripheral, Error>? }
        let (link, central, peripheral) = try await makeCentralAndPeripheral()

        var owner: Owner? = Owner()
        owner?.publisher = central.connect(peripheral, keepPendingOnAbandon: false)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(reports.isEmpty, "a publisher that is still held may yet be subscribed")
        XCTAssertEqual(link.connectionRequests, 0)

        owner = nil

        let report = try await waitForReport()
        XCTAssertEqual(report.operation, "connect(\(peripheral.identifier.uuidString), keepPendingOnAbandon: false)")
        XCTAssertGreaterThanOrEqual(report.heldFor, 0.05, "held across the 100 ms sleep")
        XCTAssertEqual(link.connectionRequests, 0)
    }

    // MARK: Subscribed publishers are never reported, whatever ended the subscription

    func testAConnectPublisherWhoseSubscriptionWasCancelledIsNotReported() async throws {
        let (link, central, peripheral) = try await makeCentralAndPeripheral()

        let connected = XCTestExpectation(description: "connected")
        var subscription: AnyCancellable? = central.connect(peripheral, keepPendingOnAbandon: true)
            .sink(receiveCompletion: { _ in }, receiveValue: { _ in connected.fulfill() })
        await fulfillment(of: [connected], timeout: 2)
        XCTAssertEqual(link.connectionRequests, 1)

        subscription = nil
        _ = subscription

        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(reports.isEmpty, "a subscribed publisher is silent when its subscription is cancelled")
    }

    func testAConnectPublisherThatCompletedIsNotReported() async throws {
        // The completion route releases the publisher without a cancel (Combine's
        // `Autoconnect` only releases the connection on completion); it fired, so it is silent.
        let link = makeLink()
        link.connectionResult = .failure(CBMError(.connectionFailed))
        let central = try makeCentral(peripherals: [link])
        let peripheral = try await discover(link, on: central)
        try await waitForPowerOn(central)

        let failed = XCTestExpectation(description: "connect failed")
        central.connect(peripheral, keepPendingOnAbandon: true)
            .sink(receiveCompletion: { if case .failure = $0 { failed.fulfill() } }, receiveValue: { _ in })
            .store(in: &cancellables)
        await fulfillment(of: [failed], timeout: 2)
        cancellables.removeAll()

        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(link.connectionRequests, 1)
        XCTAssertTrue(reports.isEmpty, "a publisher that completed is silent")
    }

    func testAwaitingTheFirstValueIsASubscription() async throws {
        // `firstValue` (the app's and the harness's connect shape) subscribes, takes the value
        // and cancels; the publisher fired, so it is silent.
        let (link, central, peripheral) = try await makeCentralAndPeripheral()

        try await connect(peripheral, on: central)

        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(link.connectionRequests, 1)
        XCTAssertEqual(peripheral.state, .connected)
        XCTAssertTrue(reports.isEmpty)
    }

    func testAPublisherHeldAndSubscribedLaterIsNotReported() async throws {
        // Holding a publisher is fine as long as it is eventually subscribed; the connect is
        // issued at that moment, not before.
        let (link, central, peripheral) = try await makeCentralAndPeripheral()

        do {
            let publisher = central.connect(peripheral, keepPendingOnAbandon: true)
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertEqual(link.connectionRequests, 0, "cold until subscribed")
            XCTAssertEqual(peripheral.state, .disconnected)

            let connected = try await withTimeout(2, "late subscription") { try await publisher.firstValue }
            XCTAssertEqual(connected.identifier, peripheral.identifier)
            XCTAssertEqual(link.connectionRequests, 1)
        }
        // The publisher is released at the end of the block above; silence is asserted after.
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(reports.isEmpty)
    }

    func testASecondSubscriberSharesTheConnectInsteadOfIssuingAnother() async throws {
        // The documented sharing contract: the first subscriber issues the connect, a second
        // subscriber to the same publisher does not issue another.
        let (link, central, peripheral) = try await makeCentralAndPeripheral()

        let first = XCTestExpectation(description: "first subscriber connected")
        let second = XCTestExpectation(description: "second subscriber connected")
        do {
            let publisher = central.connect(peripheral, keepPendingOnAbandon: true)
            publisher.sink(receiveCompletion: { _ in }, receiveValue: { _ in first.fulfill() }).store(in: &cancellables)
            publisher.sink(receiveCompletion: { _ in }, receiveValue: { _ in second.fulfill() }).store(in: &cancellables)
        }
        await fulfillment(of: [first, second], timeout: 2)

        XCTAssertEqual(link.connectionRequests, 1, "one connect for two subscribers")
        cancellables.removeAll()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(reports.isEmpty)
    }

    // MARK: Chains that build a step they never reach

    /// Two links the harness can connect to; `a` refuses its connect.
    private func makeRefusingAndSpareLinks() -> (SimulatedPeripheral, SimulatedPeripheral) {
        let a = makeLink()
        a.connectionResult = .failure(CBMError(.connectionFailed))
        return (a, makeLink())
    }

    func testAStepNeverReachedByAnAppendChainIsReported() async throws {
        // `connectA.append(connectB)` builds B right away; when A fails, B is released without
        // ever being subscribed. That is a real report (nothing was issued for B).
        let (a, b) = makeRefusingAndSpareLinks()
        let central = try makeCentral(peripherals: [a, b])
        let pa = try await discover(a, on: central)
        let pb = try await discover(b, on: central)
        try await waitForPowerOn(central)

        let failed = XCTestExpectation(description: "chain failed on A")
        central.connect(pa, keepPendingOnAbandon: true)
            .append(central.connect(pb, keepPendingOnAbandon: true))
            .sink(receiveCompletion: { if case .failure = $0 { failed.fulfill() } }, receiveValue: { _ in })
            .store(in: &cancellables)
        await fulfillment(of: [failed], timeout: 2)
        cancellables.removeAll()

        let report = try await waitForReport()
        XCTAssertEqual(report.operation, "connect(\(pb.identifier.uuidString), keepPendingOnAbandon: true)")
        XCTAssertEqual(a.connectionRequests, 1)
        XCTAssertEqual(b.connectionRequests, 0, "B was never subscribed, so never issued")
    }

    func testDeferredBuildsTheLaterStepOnlyWhenItIsReached() async throws {
        // The documented remedy: wrap the later step in `Deferred` so nothing exists for B
        // until the chain reaches it. A fails, B is never built, nothing is reported.
        let (a, b) = makeRefusingAndSpareLinks()
        let central = try makeCentral(peripherals: [a, b])
        let pa = try await discover(a, on: central)
        let pb = try await discover(b, on: central)
        try await waitForPowerOn(central)

        let failed = XCTestExpectation(description: "chain failed on A")
        central.connect(pa, keepPendingOnAbandon: true)
            .append(Deferred { central.connect(pb, keepPendingOnAbandon: true) })
            .sink(receiveCompletion: { if case .failure = $0 { failed.fulfill() } }, receiveValue: { _ in })
            .store(in: &cancellables)
        await fulfillment(of: [failed], timeout: 2)
        cancellables.removeAll()

        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(reports.isEmpty, "a step that was never built cannot be dropped")
        XCTAssertEqual(b.connectionRequests, 0)
    }

    // MARK: The same guard covers every other Bluetooth publisher

    func testDroppingACancelPeripheralConnectionPublisherUnsubscribedIsReportedAndDisconnectsNothing() async throws {
        let (_, central, peripheral) = try await makeCentralAndPeripheral()
        try await connect(peripheral, on: central)
        XCTAssertEqual(peripheral.state, .connected)

        _ = central.cancelPeripheralConnection(peripheral)

        let report = try await waitForReport()
        XCTAssertEqual(report.operation, "cancelPeripheralConnection(\(peripheral.identifier.uuidString))")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(peripheral.state, .connected, "an unsubscribed cancel disconnects nothing")
    }

    func testDroppingAScanPublisherUnsubscribedIsReportedAndScansNothing() async throws {
        let central = try makeCentral(peripherals: [makeLink()])
        try await waitForPowerOn(central)

        _ = central.scanForPeripherals(withServices: [serviceUUID])

        let report = try await waitForReport()
        XCTAssertEqual(report.operation, "scanForPeripherals(withServices: [\"180D\"])")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(central.centralManager.isScanning, "an unsubscribed scan never starts the radio")
    }

    func testDroppingADiscoveryPublisherUnsubscribedIsReportedAndSendsNoRequest() async throws {
        let (link, central, cbPeripheral) = try await makeCentralAndPeripheral()
        try await connect(cbPeripheral, on: central)
        let peripheral = Peripheral(peripheral: cbPeripheral)

        _ = peripheral.discoverServices(serviceUUIDs: nil)

        let report = try await waitForReport()
        XCTAssertEqual(report.operation, "discoverServices(serviceUUIDs:) on \(cbPeripheral.identifier.uuidString)")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(link.serviceDiscoveryRequests, 0, "nothing was queued, nothing was sent")
        XCTAssertTrue(peripheral.peripheralDelegate.serviceDiscovery.isEmpty)
    }

    func testDroppingAReadRSSIPublisherUnsubscribedIsReportedWithThePeripheral() async throws {
        // A second Peripheral operation, to pin the `#function on <peripheral>` label shape.
        let (_, central, cbPeripheral) = try await makeCentralAndPeripheral()
        try await connect(cbPeripheral, on: central)
        let peripheral = Peripheral(peripheral: cbPeripheral)

        _ = peripheral.readRSSI()

        let report = try await waitForReport()
        XCTAssertEqual(report.operation, "readRSSI() on \(cbPeripheral.identifier.uuidString)")
    }

    // MARK: The mechanism itself, with deallocation proven

    func testASubscribedPublisherDeallocatesSilentlyOnceItsSubscriptionIsGone() {
        weak var probe: Publishers.BluetoothPublisher<Int, Never>?
        let fired = EventBox<Void>()
        do {
            let publisher = PassthroughSubject<Int, Never>().bluetooth({ fired.append(()) }, operation: "probe")
            probe = publisher
            let subscription = publisher.autoconnect().sink { _ in }
            XCTAssertEqual(fired.count, 1, "autoconnect fires on the first subscriber")
            subscription.cancel()
        }
        XCTAssertNil(probe, "nothing retains the publisher once its subscription is gone")
        XCTAssertTrue(reports.isEmpty, "it fired, so it is silent")
    }

    func testAnUnsubscribedPublisherDeallocatesAndReportsExactlyOnce() {
        weak var probe: Publishers.BluetoothPublisher<Int, Never>?
        do {
            let publisher = PassthroughSubject<Int, Never>().bluetooth({ XCTFail("must not fire") }, operation: "probe")
            probe = publisher
            _ = publisher.autoconnect().eraseToAnyPublisher()  // the public API's shape, never subscribed
        }
        XCTAssertNil(probe)
        XCTAssertEqual(reports.values.map(\.operation), ["probe"])
    }

    // MARK: The report

    func testTheReportNamesTheOperationAndWhatToDo() {
        let quick = Report(operation: "connect(X, keepPendingOnAbandon: true)", heldFor: 0.0000421)
        XCTAssertTrue(quick.description.hasPrefix("dropped-unsubscribed: "), "fixed token first, for log filters: \(quick.description)")
        XCTAssertTrue(quick.description.contains("connect(X, keepPendingOnAbandon: true)"), quick.description)
        XCTAssertTrue(quick.description.contains("never issued"), quick.description)
        XCTAssertTrue(quick.description.contains("held 42 µs"), quick.description)
        XCTAssertTrue(quick.description.contains("Subscribe where you create it"), quick.description)

        XCTAssertTrue(Report(operation: "readRSSI()", heldFor: 0.0123).description.contains("held 12.3 ms"))
        XCTAssertTrue(Report(operation: "readRSSI()", heldFor: 12.3456).description.contains("held 12.3 s"))
        XCTAssertEqual(quick, Report(operation: "connect(X, keepPendingOnAbandon: true)", heldFor: 0.0000421),
                       "Equatable, so an app can assert on the report its handler received")
    }

    func testTheHandlerCanBeReplacedAndRestored() {
        // The app routes reports into its own logging; the default stays available to restore.
        let seen = EventBox<String>()
        BluetoothPublisherDiagnostics.onDroppedUnsubscribed = { seen.append($0.operation) }

        BluetoothPublisherDiagnostics.report(Report(operation: "probe", heldFor: 0))

        XCTAssertEqual(seen.values, ["probe"])
        BluetoothPublisherDiagnostics.onDroppedUnsubscribed = BluetoothPublisherDiagnostics.defaultHandler
    }
}
