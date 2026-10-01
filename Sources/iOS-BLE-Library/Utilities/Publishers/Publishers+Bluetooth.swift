//
//  File.swift
//
//
//  Created by Nick Kibysh on 05/05/2023.
//

import Combine
import Foundation

extension Publisher {
	/// Wraps this publisher in a ``Publishers/BluetoothPublisher``.
	///
	/// - Parameters:
	///   - fire: Issues the CoreBluetooth request. Runs once, when the publisher is connected
	///     (with `autoconnect()`, when the first subscriber arrives).
	///   - onCancel: Arccos (Wave C3): undoes the request's side effect, if CoreBluetooth offers
	///     a way to. Runs once, when the connection is cancelled. Under `autoconnect()` that is
	///     when the last subscriber cancels, which includes `firstValue` taking its value and a
	///     cancelled `for await` task; it does **not** run when the upstream completes, because
	///     `Autoconnect` then releases the connection without cancelling it. Leave it `nil` when
	///     the request has no revocable side effect, or when revoking it is the caller's decision
	///     (see ``CentralManager/connect(_:options:keepPendingOnAbandon:)``).
	///   - operation: Arccos (Wave C4): names the operation in a
	///     ``BluetoothPublisherDiagnostics/DroppedUnsubscribed`` report, should the publisher be
	///     released without ever being connected. Defaults to the calling function; pass a
	///     string when the peripheral or the policy matters to whoever reads the report.
	func bluetooth(
		_ fire: @escaping () -> Void, onCancel: (() -> Void)? = nil, operation: String = #function
	) -> Publishers.BluetoothPublisher<Output, Failure> {
		Publishers.BluetoothPublisher<Output, Failure>(
			self, fire: fire, onCancel: onCancel, operation: operation)
	}
}

extension Publishers {
    
    /**
     A publisher that is used for most of the Bluetooth operations.
     
     # Overview
     This publisher conforms to the `ConnectablePublisher` protocol because most of the Bluetooth operations have to be set up before they can be used.
     
	 It means that the publisher will not emit any values until it is connected. The connection is established by calling the `connect()` or `autoconnect()` methods.
	 To learn more about the `ConnectablePublisher` protocol, see [Apple's documentation](https://developer.apple.com/documentation/combine/connectablepublisher).
     
     ```swift
     let publisher = centralManager.scanForPeripherals(withServices: nil)
         .autoconnect()
         // chain of publishers
         .sink {
            // . . .
          }
         .store(in: &cancellables)
     ```

     Arccos (Wave C4, CU-868m1mrny): the public API hands these out behind `autoconnect()`, so the
     CoreBluetooth request is issued when the first subscriber arrives and never on creation. A
     publisher released without ever being connected reports itself to
     ``BluetoothPublisherDiagnostics`` from its `deinit`, because nothing was issued for it.
    */
	class BluetoothPublisher<Output, Failure: Error>: ConnectablePublisher {

		private let inner: BaseConnectable<Output, Failure>
		private let operation: String
		private let createdAt = Date()
		/// Set by ``connect()``; read only in `deinit`, which runs once the last reference is
		/// gone and therefore after any `connect()` call. No lock needed.
		private var wasConnected = false

		init<PublisherType: Publisher>(
			_ publisher: PublisherType, fire: @escaping () -> Void, onCancel: (() -> Void)? = nil,
			operation: String = #function
		) where Output == PublisherType.Output, Failure == PublisherType.Failure {
			self.inner = ClosureConnectablePublisher(upstream: publisher, fire: fire, onCancel: onCancel)
			self.operation = operation
		}

		deinit {
			guard !wasConnected else { return }
			BluetoothPublisherDiagnostics.report(
				.init(operation: operation, heldFor: Date().timeIntervalSince(createdAt)))
		}

		public func receive<S>(subscriber: S)
		where S: Subscriber, Failure == S.Failure, Output == S.Input {
			inner.receive(subscriber: subscriber)
		}

		public func connect() -> Cancellable {
			wasConnected = true
			return inner.connect()
		}
	}
}
