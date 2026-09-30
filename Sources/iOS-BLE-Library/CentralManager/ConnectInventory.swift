//
//  ConnectInventory.swift
//  iOS-BLE-Library
//
//  Arccos (Wave C3, CU-868m1mrjy). CoreBluetooth holds a connect request for a peripheral
//  until it connects, fails, or is cancelled, and never times out. Which requests it holds
//  for this app at a given moment was guesswork in field debugging: the app had to infer it
//  from its own bookkeeping, which drifts from the OS's whenever a publisher is abandoned.
//  This inventory records every connect the library issues (and every handle state
//  restoration hands back) and reads the answer from the handles' own `state`.
//

#if MOCK_TRANSPORT
import CoreBluetoothMock
#else
import CoreBluetooth
#endif
import Foundation

/// One peripheral CoreBluetooth currently holds a connection, or a pending connect, for on
/// this app's behalf. See ``CentralManager/connectInventory``.
public struct ConnectRecord {

	/// How the library came to know about this connect.
	public enum Origin: Equatable {
		/// ``CentralManager/connect(_:options:keepPendingOnAbandon:)`` issued it in this
		/// process, with the given policy.
		case connect(keepPendingOnAbandon: Bool)
		/// State restoration handed the handle back already `.connecting` or `.connected`:
		/// the connect was issued by an earlier launch of the app.
		case restoration
	}

	/// The peripheral. Weak on purpose: CoreBluetooth cancels a pending connect whose
	/// `CBPeripheral` nobody retains ("API MISUSE: Cancelling connection for unused
	/// peripheral"), and the inventory must not keep such a connect alive by observing it.
	public private(set) weak var peripheral: CBPeripheral?
	public let identifier: UUID
	/// The peripheral's name when the record was made.
	public let name: String?
	/// When the library issued the connect, or when restoration handed the handle back.
	public let issuedAt: Date
	/// The options passed to `connect`; `nil` for a restored handle.
	public let options: [String: Any]?
	public let origin: Origin

	/// The peripheral's state when the inventory was read: `.connecting` means CoreBluetooth
	/// still holds a pending connect, `.connected` an established connection.
	public var state: CBPeripheralState { peripheral?.state ?? .disconnected }

	init(peripheral: CBPeripheral, options: [String: Any]?, origin: Origin, issuedAt: Date = Date()) {
		self.peripheral = peripheral
		self.identifier = peripheral.identifier
		self.name = peripheral.name
		self.issuedAt = issuedAt
		self.options = options
		self.origin = origin
	}
}

/// Thread-safe registry behind ``CentralManager/connectInventory``.
///
/// Records are keyed by peripheral identifier; a new connect for the same peripheral replaces
/// the previous record. Nothing here tracks completion: a record is *live* while its handle
/// is `.connecting` or `.connected`, which is CoreBluetooth's own answer to "do you still hold
/// something for this peripheral". A `.disconnected` record is kept, not deleted: the handle
/// may be connected again (through this library or directly on the `CBCentralManager`) and
/// then belongs in the inventory again. Only records whose handle has been deallocated are
/// dropped, since CoreBluetooth cancels those connects itself.
final class ConnectInventory {

	private let lock = NSLock()
	private var records: [UUID: ConnectRecord] = [:]

	/// Records a connect the library just issued, or a handle restoration handed back.
	func record(_ peripheral: CBPeripheral, options: [String: Any]?, origin: ConnectRecord.Origin) {
		let record = ConnectRecord(peripheral: peripheral, options: options, origin: origin)
		lock.lock()
		records[peripheral.identifier] = record
		lock.unlock()
	}

	/// Every record whose peripheral CoreBluetooth currently holds a connect or connection for.
	var live: [ConnectRecord] {
		lock.lock()
		defer { lock.unlock() }
		records = records.filter { $0.value.peripheral != nil }
		return records.values
			.filter { $0.state == .connecting || $0.state == .connected }
			.sorted { $0.issuedAt < $1.issuedAt }
	}
}
