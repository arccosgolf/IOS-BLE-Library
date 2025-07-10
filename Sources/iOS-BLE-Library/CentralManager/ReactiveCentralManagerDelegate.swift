//
//  File.swift
//
//
//  Created by Nick Kibysh on 18/04/2023.
//

import Combine
//CG_REPLACE
import CoreBluetooth
//CG_WITH
/*
import CoreBluetoothMock
*/
//CG_END
import Foundation

// MARK: - ReactiveCentralManagerDelegate

open class ReactiveCentralManagerDelegate: NSObject, CBCentralManagerDelegate {
	enum BluetoothError: Error {
		case failedToConnect
	}

	let stateSubject = CurrentValueSubject<CBManagerState, Never>(.unknown)
	let scanResultSubject = PassthroughSubject<ScanResult, Never>()
	let connectedPeripheralSubject = PassthroughSubject<(CBPeripheral, Error?), Never>()
	let disconnectedPeripheralsSubject = PassthroughSubject<(CBPeripheral, Bool, Error?), Never>()
	let connectionEventSubject = PassthroughSubject<(CBPeripheral, CBConnectionEvent), Never>()
    let restoredPeripheralsSubject = PassthroughSubject<[String: Any], Never>()
    
	// MARK: Monitoring Connections with Peripherals
	open func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
		connectedPeripheralSubject.send((peripheral, nil))
	}

	open func centralManager(
		_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
		error: Error?
	) {
        disconnectedPeripheralsSubject.send((peripheral, false, error))
	}

	open func centralManager(
		_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
		error: Error?
	) {
		connectedPeripheralSubject.send((peripheral, error))
	}

	#if !os(macOS)
		open func centralManager(
			_ central: CBCentralManager,
			connectionEventDidOccur event: CBConnectionEvent,
			for peripheral: CBPeripheral
		) {
			connectionEventSubject.send((peripheral, event))
		}
	#endif

	// MARK: Discovering and Retrieving Peripherals

	open func centralManager(
		_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
		advertisementData: [String: Any], rssi RSSI: NSNumber
	) {
		let scanResult = ScanResult(
			peripheral: peripheral,
			rssi: RSSI,
			advertisementData: advertisementData
		)
		scanResultSubject.send(scanResult)
	}

	// MARK: Monitoring the Central Manager’s State

	open func centralManagerDidUpdateState(_ central: CBCentralManager) {
		stateSubject.send(central.state)
	}

	// MARK: Monitoring the Central Manager’s Authorization
	#if !os(macOS)
		public func centralManager(
			_ central: CBCentralManager,
			didUpdateANCSAuthorizationFor peripheral: CBPeripheral
		) {
			unimplementedError()
		}
	#endif

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, timestamp: CFAbsoluteTime, isReconnecting: Bool, error: (any Error)?) {
        disconnectedPeripheralsSubject.send((peripheral, isReconnecting, error))
    }
    
    open func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        Logger.shared.i("willRestoreState called with keys: \(dict.keys.sorted())", category: "ReactiveCentralManagerDelegate")
        
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
            Logger.shared.i("Restoring \(peripherals.count) peripherals: \(peripherals.map { $0.identifier.uuidString })", category: "ReactiveCentralManagerDelegate")
        }
        
        if let scanServices = dict[CBCentralManagerRestoredStateScanServicesKey] as? [CBUUID] {
            Logger.shared.i("Restoring scan services: \(scanServices)", category: "ReactiveCentralManagerDelegate")
        }
        
        if let scanOptions = dict[CBCentralManagerRestoredStateScanOptionsKey] as? [String: Any] {
            Logger.shared.i("Restoring scan options: \(scanOptions)", category: "ReactiveCentralManagerDelegate")
        }
        
        restoredPeripheralsSubject.send(dict)
    }
}
