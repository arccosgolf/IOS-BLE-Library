//
//  BluetoothPublisherDiagnostics.swift
//  iOS-BLE-Library
//
//  Arccos (Wave C4, CU-868m1mrny). The request publishers in this library are cold: the
//  CoreBluetooth request is issued when the first subscriber arrives, not when the publisher
//  is created. A publisher that is created and released unsubscribed
//  (`let _ = centralManager.connect(...)`) therefore compiles, logs nothing, and issues
//  nothing. That shape lived in the app's background-monitoring connect path for its whole
//  life. This file makes the mistake loud: a Bluetooth publisher that is released without
//  ever having been connected reports itself here.
//

import Foundation

/// Reports Bluetooth publishers that were released without ever being subscribed.
///
/// ## Which publishers are guarded
///
/// The guard covers every publisher built on the library's `BluetoothPublisher`, which is every
/// operation whose CoreBluetooth request is issued on the **first subscription**, never on
/// creation: ``CentralManager/connect(_:options:keepPendingOnAbandon:)``,
/// ``CentralManager/cancelPeripheralConnection(_:)``,
/// ``CentralManager/scanForPeripherals(withServices:options:)``,
/// ``Peripheral/discoverServices(serviceUUIDs:)``, ``Peripheral/discoverCharacteristics(_:for:)``,
/// ``Peripheral/discoverDescriptors(for:)``, ``Peripheral/writeValueWithResponse(_:for:)``,
/// ``Peripheral/setNotifyValue(_:for:)`` (when the state has to change), ``Peripheral/readRSSI()``
/// and ``Peripheral/isReadyToSendWriteWithoutResponse()``. Creating one of these and letting it
/// go unsubscribed is always a bug: nothing was sent to the radio and no error was raised.
///
/// Not covered, because they are not cold: `readValue(for:)` (characteristic and descriptor)
/// and ``Peripheral/writeValue(_:for:)`` return a `Future` whose request is queued when the
/// method is called, ``Peripheral/writeValueWithoutResponse(_:for:)`` is a plain call, and
/// ``Peripheral/listenValues(for:)`` issues no request at all.
///
/// ## What happens
///
/// When a guarded publisher is deallocated without ever having been subscribed,
/// ``onDroppedUnsubscribed`` is called with a ``DroppedUnsubscribed`` report, synchronously, on
/// the thread that released the publisher. The default handler (``defaultHandler``) logs the
/// report at fault level through `Logger.shared` and then calls `assertionFailure`, so a debug
/// build stops on the mistake and a release build only logs. Two things to know about the
/// release path: the log line only goes anywhere once the app has called
/// `Logger.shared.configure(with:)`, and `assertionFailure` compiles out under `-O`, so a release
/// build never traps on this.
///
/// Replace the handler at launch to route reports into your own logging or telemetry. Compose
/// with ``defaultHandler`` to keep the debug trap; replacing it outright gives the trap up:
///
/// ```swift
/// BluetoothPublisherDiagnostics.onDroppedUnsubscribed = { report in
///     telemetry.record("ble_publisher_dropped", report.operation)
///     BluetoothPublisherDiagnostics.defaultHandler(report)   // fault log + debug trap
/// }
/// ```
///
/// ## When a report is not a bug in your code
///
/// A publisher that was subscribed is never reported, whether its subscription is still
/// live, was cancelled, or completed; the check runs only when the publisher is deallocated.
/// `firstValue`, `sink`, `values` (even inside a task that is already cancelled) and the
/// Combine operators that subscribe their inputs (`flatMap`, `switchToLatest`, `merge`, `zip`)
/// all count as subscribing. What does trip the guard is a chain that *builds* a publisher it
/// may never reach: `connectA.append(connectB)` builds `connectB` immediately, and if
/// `connectA` fails, `connectB` is released unsubscribed and reported. Build such steps lazily
/// so they only exist once they are reached:
///
/// ```swift
/// connectA.append(Deferred { centralManager.connect(b, keepPendingOnAbandon: true) })
/// ```
public enum BluetoothPublisherDiagnostics {

	/// A Bluetooth publisher was released without ever being subscribed, so the CoreBluetooth
	/// request it stood for was never issued.
	public struct DroppedUnsubscribed: CustomStringConvertible, Equatable, Sendable {
		/// The operation the publisher stood for. `CentralManager` operations name the
		/// peripheral and, for `connect`, the policy: `connect(2F1A…, keepPendingOnAbandon: true)`;
		/// `Peripheral` operations name the function and the peripheral:
		/// `readRSSI() on 2F1A…`.
		public let operation: String
		/// How long the publisher existed before it was released, from a monotonic clock.
		/// Microseconds means a `let _ =` or an unused return value; longer means it was stored
		/// and never used.
		public let heldFor: TimeInterval

		public init(operation: String, heldFor: TimeInterval) {
			self.operation = operation
			self.heldFor = heldFor
		}

		/// Starts with the fixed token `dropped-unsubscribed:` so logs can be filtered on it.
		public var description: String {
			"dropped-unsubscribed: Bluetooth publisher for \(operation) was released without ever "
				+ "being subscribed (held \(Self.format(heldFor))); the request it stood for was never "
				+ "issued. Subscribe where you create it (sink, firstValue, values), build it lazily "
				+ "(Deferred) if a chain may skip it, or do not create it."
		}

		static func format(_ seconds: TimeInterval) -> String {
			if seconds < 0.001 { return String(format: "%.0f µs", seconds * 1_000_000) }
			if seconds < 1 { return String(format: "%.1f ms", seconds * 1_000) }
			return String(format: "%.1f s", seconds)
		}
	}

	public typealias Handler = @Sendable (DroppedUnsubscribed) -> Void

	/// Receives every ``DroppedUnsubscribed`` report. Called synchronously on the thread that
	/// released the publisher, which can be any thread, including a CoreBluetooth queue; the
	/// handler must be thread-safe, must not block on the main thread, and must not re-enter
	/// Combine. Set it once at launch. Defaults to ``defaultHandler``.
	public static var onDroppedUnsubscribed: Handler {
		get { box.current() }
		set { box.replace(with: newValue) }
	}

	/// Logs the report at fault level (category `BluetoothPublisher`) and stops a debug build
	/// with `assertionFailure`; in a release build (`-O`) the assertion compiles out and only
	/// the log line remains, and that line is silent until `Logger.shared.configure(with:)`.
	public static let defaultHandler: Handler = { report in
		Logger.shared.f(report.description, category: "BluetoothPublisher")
		assertionFailure(report.description)
	}

	static func report(_ report: DroppedUnsubscribed) {
		onDroppedUnsubscribed(report)
	}

	private static let box = HandlerBox(defaultHandler)

	/// Lock-guarded holder for the handler. A class in a `static let`, rather than a `static
	/// var`, so the global stays valid under strict concurrency checking.
	private final class HandlerBox: @unchecked Sendable {
		private let lock = NSLock()
		private var handler: Handler

		init(_ handler: @escaping Handler) {
			self.handler = handler
		}

		func current() -> Handler {
			lock.lock()
			defer { lock.unlock() }
			return handler
		}

		func replace(with newHandler: @escaping Handler) {
			lock.lock()
			let previous = handler
			handler = newHandler
			lock.unlock()
			// Released here, outside the lock: a previous handler whose captures hold the last
			// reference to an unsubscribed publisher would otherwise report from inside it.
			withExtendedLifetime(previous) {}
		}
	}
}
