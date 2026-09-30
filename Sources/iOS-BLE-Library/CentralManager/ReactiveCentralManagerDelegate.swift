//
//  File.swift
//
//
//  Created by Nick Kibysh on 18/04/2023.
//

import Combine
#if MOCK_TRANSPORT
import CoreBluetoothMock
#else
import CoreBluetooth
#endif
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
	#if !os(macOS)
	/// Arccos (Wave C3): ANCS authorization changes, see ``CentralManager/ancsAuthorizationChannel``.
	let ancsAuthorizationSubject = PassthroughSubject<CBPeripheral, Never>()
	#endif

	/// Arccos (Wave C3): the connects CoreBluetooth holds for this app, see
	/// ``CentralManager/connectInventory``. Lives on the delegate rather than on
	/// `CentralManager` because `willRestoreState` is what learns about restored handles.
	let connectInventory = ConnectInventory()

	// MARK: Restoration Event Buffering

	/// Buffer for restoration events that arrive before subscribers are ready.
	private var pendingRestorationEvents: [[String: Any]] = []

	/// Whether restoration subscribers are ready to receive events.
	private var restorationSubscribersReady = false

	/// Guards the restoration buffering state.
	private let restorationLock = NSLock()

	/// Marks that restoration subscribers are ready and flushes any buffered events.
	/// Called by `CentralManager.markRestorationSubscribersReady()` once the app has
	/// attached its `restoredPeripheralsChannel` subscribers.
	public func markRestorationSubscribersReady() {
		restorationLock.lock()
		defer { restorationLock.unlock() }

		Logger.shared.i("Marking restoration subscribers as ready", category: "ReactiveCentralManagerDelegate")
		restorationSubscribersReady = true

		for event in pendingRestorationEvents {
			Logger.shared.i("Flushing buffered restoration event with keys: \(event.keys.sorted())", category: "ReactiveCentralManagerDelegate")
			restoredPeripheralsSubject.send(event)
		}

		if !pendingRestorationEvents.isEmpty {
			Logger.shared.i("Flushed \(pendingRestorationEvents.count) buffered restoration events", category: "ReactiveCentralManagerDelegate")
		}

		pendingRestorationEvents.removeAll()
	}

	// MARK: Monitoring Connections with Peripherals
	open func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
		disconnectDeliveryLock.lock()
		lastDisconnectDelivery[peripheral.identifier] = nil
		disconnectDeliveryLock.unlock()
		connectedPeripheralSubject.send((peripheral, nil))
	}

	// MARK: Disconnects: two selectors, one event (Arccos, Wave C3)

	/// Which delegate selector delivered a disconnect.
	enum DisconnectVariant: Equatable {
		/// `centralManager(_:didDisconnectPeripheral:error:)`
		case legacy
		/// `centralManager(_:didDisconnectPeripheral:timestamp:isReconnecting:error:)`
		case timestamp
	}

	private struct DisconnectDelivery {
		let variant: DisconnectVariant
		let at: Date
		/// Error identity (domain and code), or `nil` for an error-free disconnect.
		let errorKey: String?
	}

	private let disconnectDeliveryLock = NSLock()
	private var lastDisconnectDelivery: [UUID: DisconnectDelivery] = [:]

	/// How long after one selector delivered a disconnect the *other* selector's delivery of
	/// the same error for the same peripheral counts as the same event. Internal so tests can
	/// shorten it; the deliveries CoreBluetooth pairs up arrive within the same run of the
	/// delegate queue.
	var duplicateDisconnectWindow: TimeInterval = 1.0

	/// The pre-iOS 17 disconnect selector.
	///
	/// Arccos (Wave C3): CoreBluetooth may deliver a disconnect through this selector, through
	/// the timestamp/isReconnecting one, or through both for the same event; which one is not
	/// documented and was observed to differ between the simulator's CoreBluetoothMock (the
	/// new one only) and a device (this one). Both therefore publish, through
	/// ``peripheralDidDisconnect(_:isReconnecting:error:variant:)``, which drops the second
	/// delivery of one event. `isReconnecting` is not a parameter here; it is read from the
	/// handle, which CoreBluetooth already holds at `.connecting` when auto-reconnect is armed
	/// (the same signal the app's stuck-connecting detection relies on).
	open func centralManager(
		_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
		error: Error?
	) {
		peripheralDidDisconnect(
			peripheral, isReconnecting: peripheral.state == .connecting, error: error, variant: .legacy)
	}

	/// The iOS 17 / macOS 14 disconnect selector. See the legacy one above.
	public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, timestamp: CFAbsoluteTime, isReconnecting: Bool, error: (any Error)?) {
		peripheralDidDisconnect(peripheral, isReconnecting: isReconnecting, error: error, variant: .timestamp)
	}

	/// Arccos (Wave C3): the single disconnect path. Whichever selector delivers first
	/// publishes and fails the peripheral's pending discovery; a delivery through the *other*
	/// selector, for the same peripheral and the same error, within ``duplicateDisconnectWindow``
	/// and with no connect in between, is the same event and is dropped. A repeat through the
	/// same selector, or with a different error (a cancel of the armed reconnect reports
	/// `nil` after the link-loss error), is a new event and publishes.
	func peripheralDidDisconnect(
		_ peripheral: CBPeripheral, isReconnecting: Bool, error: Error?, variant: DisconnectVariant
	) {
		let errorKey = error.map { "\(($0 as NSError).domain)#\(($0 as NSError).code)" }
		let now = Date()

		disconnectDeliveryLock.lock()
		if let last = lastDisconnectDelivery[peripheral.identifier],
		   last.variant != variant,
		   last.errorKey == errorKey,
		   now.timeIntervalSince(last.at) < duplicateDisconnectWindow {
			disconnectDeliveryLock.unlock()
			Logger.shared.i("Dropping duplicate didDisconnectPeripheral (\(variant)) for \(peripheral.identifier.uuidString): the \(last.variant) selector already published this disconnect", category: "ReactiveCentralManagerDelegate")
			return
		}
		lastDisconnectDelivery[peripheral.identifier] = DisconnectDelivery(variant: variant, at: now, errorKey: errorKey)
		disconnectDeliveryLock.unlock()

		Logger.shared.i("didDisconnectPeripheral (\(variant)) for \(peripheral.identifier.uuidString), isReconnecting: \(isReconnecting), error: \(error?.localizedDescription ?? "nil")", category: "ReactiveCentralManagerDelegate")
		disconnectedPeripheralsSubject.send((peripheral, isReconnecting, error))
		failPendingDiscovery(on: peripheral)
	}

	/// Arccos (Wave C1): fails the peripheral's pending discovery operations from the
	/// documented disconnect signal. `Peripheral` does the same from KVO of
	/// `CBPeripheral.state`, which Apple does not document as KVO-compliant; whichever fires
	/// first drains the lanes and the other is a no-op.
	private func failPendingDiscovery(on peripheral: CBPeripheral) {
		(peripheral.delegate as? ReactivePeripheralDelegate)?
			.failPendingOperations(with: CBError(.peripheralDisconnected))
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
		/// Arccos (Wave C3): was `fatalError("Unimplemented Method")`. The system calls this for
		/// any connected peripheral whose ANCS authorization the user changes in Settings, so
		/// the crash was one Settings toggle away for every user with a connected device.
		open func centralManager(
			_ central: CBCentralManager,
			didUpdateANCSAuthorizationFor peripheral: CBPeripheral
		) {
			Logger.shared.i("ANCS authorization changed for \(peripheral.identifier.uuidString): ancsAuthorized = \(peripheral.ancsAuthorized)", category: "ReactiveCentralManagerDelegate")
			ancsAuthorizationSubject.send(peripheral)
		}
	#endif

	open func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
		restorationLock.lock()
		defer { restorationLock.unlock() }

		Logger.shared.i("willRestoreState called with keys: \(dict.keys.sorted())", category: "ReactiveCentralManagerDelegate")

		if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
			Logger.shared.i("Restoring \(peripherals.count) peripherals: \(peripherals.map { "\($0.identifier.uuidString) (state \($0.state.rawValue))" })", category: "ReactiveCentralManagerDelegate")
			// Arccos (Wave C3): these are connects an earlier launch issued and the OS still
			// holds; they belong in the inventory even if the app never re-issues them.
			for peripheral in peripherals where peripheral.state != .disconnected {
				connectInventory.record(peripheral, options: nil, origin: .restoration)
			}
		}

		if let scanServices = dict[CBCentralManagerRestoredStateScanServicesKey] as? [CBUUID] {
			Logger.shared.i("Restoring scan services: \(scanServices)", category: "ReactiveCentralManagerDelegate")
		}

		if let scanOptions = dict[CBCentralManagerRestoredStateScanOptionsKey] as? [String: Any] {
			Logger.shared.i("Restoring scan options: \(scanOptions)", category: "ReactiveCentralManagerDelegate")
		}

		if restorationSubscribersReady {
			// Normal case: subscribers are ready, send immediately.
			Logger.shared.i("Sending restoration event immediately (subscribers ready)", category: "ReactiveCentralManagerDelegate")
			restoredPeripheralsSubject.send(dict)
		} else {
			// Buffer the event until subscribers are ready.
			Logger.shared.i("Buffering restoration event (subscribers not ready yet)", category: "ReactiveCentralManagerDelegate")
			pendingRestorationEvents.append(dict)
		}
	}
}
