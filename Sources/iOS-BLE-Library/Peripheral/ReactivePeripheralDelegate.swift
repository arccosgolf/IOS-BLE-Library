//
//  File.swift
//
//
//  Created by Nick Kibysh on 28/04/2023.
//

import Combine
#if MOCK_TRANSPORT
import CoreBluetoothMock
#else
import CoreBluetooth
#endif
import Foundation

struct BluetoothOperationResult<T> {
    let value: T
    let error: Error?
    let id: UUID
}

open class ReactivePeripheralDelegate: NSObject, CBPeripheralDelegate {
	let l = L(category: #file)
    
    typealias NonFailureSubject<T> = PassthroughSubject<T, Never>
    
    // MARK: Pending discovery operations (Arccos, Wave C1)

    /// Key for descriptor-discovery lanes: a characteristic within its service.
    struct CharacteristicKey: Hashable {
        let service: CBUUID?
        let characteristic: CBUUID

        init(_ characteristic: CBCharacteristic) {
            self.service = characteristic.service?.uuid
            self.characteristic = characteristic.uuid
        }
    }

    /// Identifier of the peripheral this delegate is attached to, set by `Peripheral.init`.
    /// Used only to label log lines: with two peripherals flapping at once, a failure line
    /// without it can only be attributed by timing.
    var peripheralIdentifier: UUID?

    private var peripheralLabel: String {
        peripheralIdentifier?.uuidString ?? "unattached peripheral"
    }

    /// One lane: `didDiscoverServices` does not say which request it answers.
    let serviceDiscovery = DiscoveryLanes<SingleLane>()
    /// One lane per service: `didDiscoverCharacteristicsFor:` names the service.
    let characteristicDiscovery = DiscoveryLanes<CBUUID>()
    /// One lane per characteristic: `didDiscoverDescriptorsFor:` names the characteristic.
    let descriptorDiscovery = DiscoveryLanes<CharacteristicKey>()

    /// Fails every pending discovery operation on this peripheral with `error` and leaves the
    /// lanes empty. `Peripheral` calls this when the peripheral disconnects, and
    /// ``Peripheral/cleanupQueueOnError()`` calls it on the caller's behalf.
    func failPendingOperations(with error: Error) {
        let failed = serviceDiscovery.failAll(with: error)
            + characteristicDiscovery.failAll(with: error)
            + descriptorDiscovery.failAll(with: error)
        if failed > 0 {
            Logger.shared.i("Failed \(failed) pending discovery operation(s) for \(peripheralLabel): \(error)", category: "ReactivePeripheralDelegate")
        }
    }
    
    // MARK: Discovering Services
	let discoveredServicesSubject = NonFailureSubject<
        BluetoothOperationResult<[CBService]?>
    >()
    
    /*
	let discoveredIncludedServicesSubject = PassthroughSubject<
        BluetoothOperationResult<(CBService, [CBService]?)>, Never
	>()
     */
    
    // MARK: Discovering Characteristics and their Descriptors
	let discoveredCharacteristicsSubject = NonFailureSubject<
        BluetoothOperationResult<(CBService, [CBCharacteristic]?)>
	>()
	let discoveredDescriptorsSubject = NonFailureSubject<
        BluetoothOperationResult<(CBCharacteristic, [CBDescriptor]?)>
	>()

	// MARK: Retrieving Characteristic and Descriptor Values
	let updatedCharacteristicValuesSubject = PassthroughSubject<
		(CBCharacteristic, Error?), Never
	>()
	let updatedDescriptorValuesSubject = PassthroughSubject<
		(CBDescriptor, Error?), Never
	>()
    
    let isReadyToSendWriteWithoutResponseSubject = PassthroughSubject<Void, Never>() 

	let writtenCharacteristicValuesSubject = PassthroughSubject<
		(CBCharacteristic, Error?), Never
	>()
	let writtenDescriptorValuesSubject = PassthroughSubject<
		(CBDescriptor, Error?), Never
	>()

	// MARK: Managing Notifications for a Characteristic’s Value
	let notificationStateSubject = PassthroughSubject<
		(CBCharacteristic, Error?), Never
	>()

	// MARK: Monitoring Changes to a Peripheral’s Name or Services
	let updateNameSubject = PassthroughSubject<String?, Never>()
    let modifyServicesSubject = PassthroughSubject<[CBService], Never>()
    
    let readRSSISubject = PassthroughSubject<(NSNumber, Error?), Never>()
    
    // MARK: - Channels
    
    
	// MARK: Discovering Services

	open func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let id = serviceDiscovery.complete(key: SingleLane()) else {
            Logger.shared.i("Ignoring didDiscoverServices for \(peripheral.identifier.uuidString): no service discovery in flight", category: "ReactivePeripheralDelegate")
            return
        }

        let result = BluetoothOperationResult<[CBService]?>(value: peripheral.services, error: error, id: id)
        discoveredServicesSubject.send(result)
	}

    // MARK: Discovering Characteristics and their Descriptors

	open func peripheral(
		_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
		error: Error?
    ) {
        guard let operationId = characteristicDiscovery.complete(key: service.uuid) else {
            Logger.shared.i("Ignoring didDiscoverCharacteristicsFor \(service.uuid) on \(peripheral.identifier.uuidString): no discovery in flight for that service", category: "ReactivePeripheralDelegate")
            return
        }
        
        let result = BluetoothOperationResult<(CBService, [CBCharacteristic]?)>(value: (service, service.characteristics), error: error, id: operationId)
        
		discoveredCharacteristicsSubject.send(result)
	}

	open func peripheral(
		_ peripheral: CBPeripheral,
		didDiscoverDescriptorsFor characteristic: CBCharacteristic, error: Error?
	) {
        guard let operationId = descriptorDiscovery.complete(key: CharacteristicKey(characteristic)) else {
            Logger.shared.i("Ignoring didDiscoverDescriptorsFor \(characteristic.uuid) on \(peripheral.identifier.uuidString): no discovery in flight for that characteristic", category: "ReactivePeripheralDelegate")
            return
        }
        let result = BluetoothOperationResult<(CBCharacteristic, [CBDescriptor]?)>(value: (characteristic, characteristic.descriptors), error: error, id: operationId)
        
		discoveredDescriptorsSubject.send(result)
	}

	// MARK: Retrieving Characteristic and Descriptor Values

	open func peripheral(
		_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
		error: Error?
	) {
		updatedCharacteristicValuesSubject.send((characteristic, error))
	}

	open func peripheral(
		_ peripheral: CBPeripheral, didUpdateValueFor descriptor: CBDescriptor,
		error: Error?
	) {
		updatedDescriptorValuesSubject.send((descriptor, error))
	}

	// MARK: Writing Characteristic and Descriptor Values

	open func peripheral(
		_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
		error: Error?
	) {
		writtenCharacteristicValuesSubject.send((characteristic, error))
	}

	open func peripheral(
		_ peripheral: CBPeripheral, didWriteValueFor descriptor: CBDescriptor, error: Error?
	) {
		writtenDescriptorValuesSubject.send((descriptor, error))
	}

	open func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        isReadyToSendWriteWithoutResponseSubject.send(())
    }

	// MARK: Managing Notifications for a Characteristic’s Value

	open func peripheral(
		_ peripheral: CBPeripheral,
		didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?
	) {
		notificationStateSubject.send((characteristic, error))
	}

	// MARK: Retrieving a Peripheral’s RSSI Data

	open func peripheral(
		_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?
	) {
        readRSSISubject.send((RSSI, error))
	}

	// MARK: Monitoring Changes to a Peripheral’s Name or Services

	open func peripheralDidUpdateName(_ peripheral: CBPeripheral) {
		updateNameSubject.send(peripheral.name)
	}

	open func peripheral(
		_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]
	) {
        modifyServicesSubject.send(invalidatedServices)
	}

	/// Arccos: recovery hook for a discovery reply that will never arrive (e.g. the caller's
	/// own timeout expired). Fails every pending discovery operation on this peripheral, in all
	/// three lanes, with ``PeripheralError/operationCancelled`` so their publishers terminate,
	/// and leaves the lanes empty so the next request is issued immediately.
	///
	/// A reply that arrives afterwards is dropped only if nothing is pending in its lane. If a
	/// new request is already in flight for the same key, the late reply completes it (see
	/// ``Peripheral/cleanupQueueOnError()``): CoreBluetooth replies carry no request identity,
	/// and swallowing "the next reply" instead would hang the retry whenever the abandoned
	/// request truly never gets answered, which is this hook's documented use case.
	func cleanupQueueOnError() {
		Logger.shared.i("Cancelling pending discovery operations on error for \(peripheralLabel)", category: "ReactivePeripheralDelegate")
		failPendingOperations(with: PeripheralError.operationCancelled)
	}

	// MARK: Monitoring L2CAP Channels
/*
	public func peripheral(
		_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?
	) {
		l.i(#function)
		fatalError()
	}
*/
}
