//
//  BluetoothPublisherDiagnostics.swift
//  iOS-BLE-Library
//
//  Arccos (Wave C4, CU-868m1mrny). Every operation in this library returns a cold publisher:
//  the CoreBluetooth request is issued when the first subscriber arrives, not when the
//  publisher is created. A publisher that is created and released unsubscribed
//  (`let _ = centralManager.connect(...)`) therefore compiles, logs nothing, and issues
//  nothing. That shape lived in the app's background-monitoring connect path for its whole
//  life. This file makes the mistake loud: a Bluetooth publisher that is released without
//  ever having been connected reports itself here.
//

import Foundation

/// Reports Bluetooth publishers that were released without ever being subscribed.
///
/// Every publisher returned by ``CentralManager`` (`connect`, `cancelPeripheralConnection`,
/// `scanForPeripherals`) and by ``Peripheral`` (discovery, reads, writes, notifications, RSSI)
/// issues its CoreBluetooth request on the **first subscription**, never on creation. Creating
/// one and letting it go unsubscribed is always a bug: nothing was sent to the radio and no
/// error was raised. When that happens, ``onDroppedUnsubscribed`` is called with a
/// ``DroppedUnsubscribed`` report, on the thread that released the publisher.
///
/// The default handler logs the report at fault level through `Logger.shared` and then calls
/// `assertionFailure`, so a debug build stops on the mistake and a release build only logs
/// it. Replace the handler at launch to route reports into your own logging or telemetry:
///
/// ```swift
/// BluetoothPublisherDiagnostics.onDroppedUnsubscribed = { report in
///     log.fault("\(report)")
/// }
/// ```
///
/// A report is never a false alarm for a publisher that was subscribed later: the check runs
/// only when the publisher is deallocated, and a publisher that was ever subscribed stays
/// silent whether its subscription is still live, was cancelled, or completed.
public enum BluetoothPublisherDiagnostics {

	/// A Bluetooth publisher was released without ever being subscribed, so the CoreBluetooth
	/// request it stood for was never issued.
	public struct DroppedUnsubscribed: CustomStringConvertible, Sendable {
		/// The operation the publisher stood for, for example
		/// `connect(2F1A…, keepPendingOnAbandon: true)` or `discoverServices(serviceUUIDs:)`.
		public let operation: String
		/// How long the publisher existed before it was released. Microseconds means a
		/// `let _ =` or an unused return value; longer means it was stored and never used.
		public let heldFor: TimeInterval

		public var description: String {
			let held = heldFor < 0.001
				? String(format: "%.0f µs", heldFor * 1_000_000)
				: String(format: "%.1f ms", heldFor * 1_000)
			return "Bluetooth publisher for \(operation) was released without ever being subscribed "
				+ "(held \(held)); its CoreBluetooth request was never issued. Subscribe where you "
				+ "create it (sink, firstValue, values) or do not create it."
		}
	}

	/// Receives every ``DroppedUnsubscribed`` report. Called synchronously on the thread that
	/// released the publisher, which can be any thread; the handler must be thread-safe.
	/// Set it once at launch. Defaults to ``defaultHandler``.
	public static var onDroppedUnsubscribed: @Sendable (DroppedUnsubscribed) -> Void {
		get {
			lock.lock()
			defer { lock.unlock() }
			return handler
		}
		set {
			lock.lock()
			defer { lock.unlock() }
			handler = newValue
		}
	}

	/// Logs the report at fault level (category `BluetoothPublisher`) and stops a debug build
	/// with `assertionFailure`; in a release build (`-O`) the assertion compiles out and only
	/// the log line remains.
	public static let defaultHandler: @Sendable (DroppedUnsubscribed) -> Void = { report in
		Logger.shared.f(report.description, category: "BluetoothPublisher")
		assertionFailure(report.description)
	}

	private static let lock = NSLock()
	private static var handler: @Sendable (DroppedUnsubscribed) -> Void = defaultHandler

	static func report(_ report: DroppedUnsubscribed) {
		onDroppedUnsubscribed(report)
	}
}
