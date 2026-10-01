//
//  SimulatedPeripheral.swift
//
//  Arccos test support.
//
//  One reusable simulated peripheral, so a test describes its scenario instead of
//  re-declaring a CBMPeripheralSpec builder chain. Every knob the Wave C scenarios need
//  lives here:
//
//  - `connectionInterval` scales the mock's service-discovery latency
//    (`interval × number of services`), which is how a test opens a window to
//    disconnect *during* discovery;
//  - `connectionResult` fails a connect from the peripheral side (`didFailToConnect`), the
//    `*DiscoveryResult` fields fail a discovery;
//  - `onServiceDiscoveryRequest` fires synchronously when the mock receives the
//    request, so a test can act at exactly that moment, and the request counters make
//    ordering assertable;
//  - `initiallyConnected` builds a peripheral the system already holds a connection to,
//    which is what state restoration hands back.
//

import CoreBluetoothMock
import Foundation

final class SimulatedPeripheral: CBMPeripheralSpecDelegate {

    let name: String
    let services: [CBMServiceMock]
    let proximity: CBMProximity
    /// Advertising interval; `nil` means the peripheral does not advertise at all
    /// (it can then only be reached through restoration or `retrievePeripherals`).
    let advertisingInterval: TimeInterval?
    let connectionInterval: TimeInterval
    let initiallyConnected: Bool
    private let requestedIdentifier: UUID

    /// What the mock answers a connect request with; a failure is delivered as
    /// `didFailToConnect` after `connectionInterval`, with the peripheral back at `.disconnected`.
    var connectionResult: Result<Void, Error> = .success(())
    var serviceDiscoveryResult: Result<Void, Error> = .success(())
    var characteristicDiscoveryResult: Result<Void, Error> = .success(())
    var descriptorDiscoveryResult: Result<Void, Error> = .success(())

    /// Called on the thread that issued `discoverServices`, before the mock schedules its reply.
    var onServiceDiscoveryRequest: ((CBMPeripheralSpec) -> Void)?
    /// Called on the thread that issued `discoverCharacteristics`, before the mock schedules its reply.
    var onCharacteristicDiscoveryRequest: ((CBMPeripheralSpec, CBMServiceMock) -> Void)?
    /// Called on the thread that issued `discoverDescriptors`, before the mock schedules its reply.
    var onDescriptorDiscoveryRequest: ((CBMPeripheralSpec, CBMCharacteristicMock) -> Void)?

    /// Connect requests the mock has received for this peripheral (Wave C4: proves that an
    /// unsubscribed connect publisher issued nothing).
    private(set) var connectionRequests = 0
    private(set) var serviceDiscoveryRequests = 0
    private(set) var characteristicDiscoveryRequests = 0
    private(set) var descriptorDiscoveryRequests = 0

    /// The CoreBluetoothMock specification. Register it with
    /// `CBMCentralManagerMock.simulatePeripherals(_:)` (``CentralManagerTestCase/makeCentral``
    /// does) and drive it with the `simulate*` methods.
    private(set) lazy var spec: CBMPeripheralSpec = {
        var builder = CBMPeripheralSpec.simulatePeripheral(
            identifier: requestedIdentifier, proximity: proximity)

        if let advertisingInterval {
            builder = builder.advertising(
                advertisementData: [
                    CBMAdvertisementDataIsConnectable: true as NSNumber,
                    CBMAdvertisementDataLocalNameKey: name,
                    CBMAdvertisementDataServiceUUIDsKey: services.map { $0.uuid },
                ],
                withInterval: advertisingInterval
            )
        }

        if initiallyConnected {
            builder = builder.connected(
                name: name, services: services, delegate: self,
                connectionInterval: connectionInterval)
        } else {
            builder = builder.connectable(
                name: name, services: services, delegate: self,
                connectionInterval: connectionInterval)
        }

        return builder.allowForRetrieval().build()
    }()

    var identifier: UUID { spec.identifier }

    /// How long CoreBluetoothMock waits before answering a full service discovery
    /// (`connectionInterval × services.count`).
    ///
    /// The mock does not cancel that reply timer on disconnect; it only suppresses the
    /// reply if the peripheral is not `.connected` when the timer fires. A test that
    /// reconnects inside this window would receive a reply real CoreBluetooth never
    /// delivers, so wait it out first.
    var serviceDiscoveryLatency: TimeInterval { connectionInterval * Double(services.count) }

    /// How long CoreBluetoothMock waits before answering a full characteristic discovery on
    /// `service` (`connectionInterval × characteristic count`). Same caveat as above.
    func characteristicDiscoveryLatency(for service: CBMServiceMock) -> TimeInterval {
        connectionInterval * Double(service.characteristics?.count ?? 0)
    }

    /// How long CoreBluetoothMock waits before answering a full descriptor discovery on
    /// `characteristic` (`connectionInterval × descriptor count`). Same caveat as above.
    func descriptorDiscoveryLatency(for characteristic: CBMCharacteristicMock) -> TimeInterval {
        connectionInterval * Double(characteristic.descriptors?.count ?? 0)
    }

    /// - Parameters:
    ///   - name: Advertised local name and connected name.
    ///   - services: The GATT database. Discovery latency in the mock is
    ///     `connectionInterval × services.count`.
    ///   - proximity: `.near` by default so scans see it immediately.
    ///   - advertisingInterval: `0.25` by default; pass `nil` for a silent peripheral.
    ///   - connectionInterval: The mock's per-operation latency (CoreBluetoothMock's default is 45 ms).
    ///   - initiallyConnected: Build the peripheral as already connected to the system.
    ///   - identifier: Fixed identifier, for tests that retrieve by id.
    init(
        name: String,
        services: [CBMServiceMock],
        proximity: CBMProximity = .near,
        advertisingInterval: TimeInterval? = 0.25,
        connectionInterval: TimeInterval = 0.045,
        initiallyConnected: Bool = false,
        identifier: UUID = UUID()
    ) {
        self.name = name
        self.services = services
        self.proximity = proximity
        self.advertisingInterval = advertisingInterval
        self.connectionInterval = connectionInterval
        self.initiallyConnected = initiallyConnected
        self.requestedIdentifier = identifier
    }

    // MARK: CBMPeripheralSpecDelegate

    func peripheralDidReceiveConnectionRequest(_ peripheral: CBMPeripheralSpec) -> Result<Void, Error> {
        connectionRequests += 1
        return connectionResult
    }

    func peripheral(
        _ peripheral: CBMPeripheralSpec,
        didReceiveServiceDiscoveryRequest serviceUUIDs: [CBMUUID]?
    ) -> Result<Void, Error> {
        serviceDiscoveryRequests += 1
        onServiceDiscoveryRequest?(peripheral)
        return serviceDiscoveryResult
    }

    func peripheral(
        _ peripheral: CBMPeripheralSpec,
        didReceiveCharacteristicsDiscoveryRequest characteristicUUIDs: [CBMUUID]?,
        for service: CBMServiceMock
    ) -> Result<Void, Error> {
        characteristicDiscoveryRequests += 1
        onCharacteristicDiscoveryRequest?(peripheral, service)
        return characteristicDiscoveryResult
    }

    func peripheral(
        _ peripheral: CBMPeripheralSpec,
        didReceiveDescriptorsDiscoveryRequestFor characteristic: CBMCharacteristicMock
    ) -> Result<Void, Error> {
        descriptorDiscoveryRequests += 1
        onDescriptorDiscoveryRequest?(peripheral, characteristic)
        return descriptorDiscoveryResult
    }
}

// MARK: - GATT shorthands

extension CBMServiceMock {
    /// A primary service with the given characteristics.
    static func primary(_ uuid: CBMUUID, characteristics: [CBMCharacteristicMock] = []) -> CBMServiceMock {
        CBMServiceMock(type: uuid, primary: true, characteristics: characteristics)
    }
}
