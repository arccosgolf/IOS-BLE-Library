//
//  File.swift
//
//
//  Created by Nick Kibysh on 24/03/2023.
//

import Combine
import Foundation

extension Publisher where Failure == Never {

	var values: AsyncPublisher<Self> {
		return .init(self)
	}
}

/// Arccos (Wave C2): errors raised by ``Publisher/firstValue`` itself, as opposed to errors
/// forwarded from the publisher.
public enum FirstValueError: LocalizedError, Equatable {
	/// The publisher finished without emitting a value, so there is no first value to return.
	///
	/// Reachable from ``CentralManager/connect(_:options:keepPendingOnAbandon:)`` when the peripheral is disconnected
	/// (with no error) before it connects, and from ``CentralManager/scanForPeripherals(withServices:options:)``
	/// when ``CentralManager/stopScan()`` ends the scan before a match. Before Wave C2 an empty
	/// completion left the awaiting task suspended forever.
	case finishedWithoutValue

	public var errorDescription: String? {
		switch self {
		case .finishedWithoutValue:
			return "The publisher finished without emitting a value."
		}
	}
}

extension Publisher {
	/// The publisher's first value, bridged into async/await.
	///
	/// Subscribes on first access, returns the first emitted value and cancels the
	/// subscription. The cancel runs before this returns, so whatever the publisher undoes on
	/// cancel (a scan stops, a queued discovery is withdrawn) has happened by then.
	/// Throws the publisher's failure, or ``FirstValueError/finishedWithoutValue``
	/// if the publisher finishes without emitting. A publisher that never completes keeps this
	/// suspended, so bound it with Combine's `timeout(_:scheduler:options:customError:)` and pass
	/// `customError`: without one, `timeout` finishes the publisher and this throws
	/// ``FirstValueError/finishedWithoutValue``, indistinguishable from an empty completion.
	public var firstValue: Output {
		get async throws {
			try await ContinuationSubscriber<Self>.withCheckedContinuation(self)
		}
	}
}

//extension Publishers.Autoconnect where Upstream == Publishers.Peripheral {
//    public var value: Output {
//        get async throws {
//            try await ContinuationSubscriber<Self>.withCheckedContinuation(self)
//        }
//    }
//}

public struct AsyncPublisher<Upstream: Publisher>: AsyncSequence where Upstream.Failure == Never {
	public typealias Element = Upstream.Output

	public struct Iterator: AsyncIteratorProtocol {
		public typealias Element = Upstream.Output
		fileprivate let inner: Inner

		public mutating func next() async -> Element? {
			return await withTaskCancellationHandler {
				[inner] in
				await inner.next()
			} onCancel: {
				[inner] in
				inner.cancel()
			}
		}
	}

	public typealias AsyncIterator = Iterator

	private let publisher: Upstream

	public init(_ publisher: Upstream) {
		self.publisher = publisher
	}

	public func makeAsyncIterator() -> Iterator {
		let inner = Iterator.Inner()
		publisher.subscribe(inner)
		return Iterator(inner: inner)
	}
}

extension AsyncPublisher.Iterator {
	fileprivate final class Inner: Subscriber, Cancellable {
		typealias Input = Upstream.Output
		typealias Failure = Upstream.Failure

		private enum State {
			case awaitingSubscription
			case subscribed(Subscription)
			case terminal
		}

		private let lock = NSLock()
		private var pending: [UnsafeContinuation<Input?, Never>] = []
		private var state = State.awaitingSubscription
		private var pendingDemand = Subscribers.Demand.none

		func receive(subscription: Subscription) {
			lock.lock()
			guard case .awaitingSubscription = state else {
				lock.unlock()
				subscription.cancel()
				return
			}
			state = .subscribed(subscription)
			let pendingDemand = self.pendingDemand
			self.pendingDemand = .none
			lock.unlock()
			if pendingDemand != .none {
				subscription.request(pendingDemand)
			}
		}

		func receive(_ input: Input) -> Subscribers.Demand {
			lock.lock()
			guard case .subscribed = state else {
				let pending = self.pending
				lock.unlock()
				pending.resumeAllWithNil()
				return .none
			}
			precondition(
				!pending.isEmpty, "Received an output without requesting demand")
			let continuation = pending.removeFirst()
			lock.unlock()
			continuation.resume(returning: input)
			return .none
		}

		func receive(completion: Subscribers.Completion<Failure>) {
			lock.lock()
			state = .terminal
			let pending = self.pending
			lock.unlock()
			pending.resumeAllWithNil()
		}

		func cancel() {
			lock.lock()
			let pending = self.pending
			guard case .subscribed(let subscription) = state else {
				state = .terminal
				lock.unlock()
				pending.resumeAllWithNil()
				return
			}
			state = .terminal
			lock.unlock()
			subscription.cancel()
			pending.resumeAllWithNil()
		}

		fileprivate func next() async -> Input? {
			return await withUnsafeContinuation { continuation in
				lock.lock()
				switch state {
				case .awaitingSubscription:
					pending.append(continuation)
					pendingDemand += 1
					lock.unlock()
				case .subscribed(let subscription):
					pending.append(continuation)
					lock.unlock()
					subscription.request(.max(1))
				case .terminal:
					lock.unlock()
					continuation.resume(returning: nil)
				}
			}
		}
	}
}

extension Publisher {
	var values: AsyncThrowingPublisher<Self> {
		return .init(self)
	}
}

public struct AsyncThrowingPublisher<Upstream: Publisher>: AsyncSequence {
	public typealias Element = Upstream.Output

	public struct Iterator: AsyncIteratorProtocol {

		public typealias Element = Upstream.Output

		fileprivate let inner: Inner

		public mutating func next() async throws -> Element? {
			try await withTaskCancellationHandler {
				[inner] in
				try await inner.next()
			} onCancel: {
				[inner] in
				inner.cancel()
			}
		}
	}

	public typealias AsyncIterator = Iterator

	private let publisher: Upstream

	public init(_ publisher: Upstream) {
		self.publisher = publisher
	}

	public func makeAsyncIterator() -> Iterator {
		let inner = Iterator.Inner()
		publisher.subscribe(inner)
		return Iterator(inner: inner)
	}
}

extension AsyncThrowingPublisher.Iterator {

	fileprivate final class Inner: Subscriber, Cancellable {
		typealias Input = Upstream.Output
		typealias Failure = Upstream.Failure

		private enum State {
			case awaitingSubscription
			case subscribed(Subscription)
			case terminal(Error?)
		}

		private let lock = NSLock()
		private var pending: [UnsafeContinuation<Input?, Error>] = []
		private var state = State.awaitingSubscription
		private var pendingDemand = Subscribers.Demand.none

		func receive(subscription: Subscription) {
			lock.lock()
			guard case .awaitingSubscription = state else {
				lock.unlock()
				subscription.cancel()
				return
			}
			state = .subscribed(subscription)
			let pendingDemand = self.pendingDemand
			self.pendingDemand = .none
			lock.unlock()
			if pendingDemand != .none {
				subscription.request(pendingDemand)
			}
		}

		func receive(_ input: Input) -> Subscribers.Demand {
			lock.lock()
			guard case .subscribed = state else {
				let pending = self.pending
				lock.unlock()
				pending.resumeAllWithNil()
				return .none
			}
			precondition(
				!pending.isEmpty, "Received an output without requesting demand")
			let continuation = pending.removeFirst()
			lock.unlock()
			continuation.resume(returning: input)
			return .none
		}

		func receive(completion: Subscribers.Completion<Failure>) {
			lock.lock()
			switch state {
			case .awaitingSubscription, .subscribed:
				if let continuation = pending.first {
					state = .terminal(nil)
					let remaining = pending.dropFirst()
					lock.unlock()
					switch completion {
					case .finished:
						continuation.resume(returning: nil)
					case .failure(let error):
						continuation.resume(throwing: error)
					}
					remaining.resumeAllWithNil()
				} else if case .failure(let e) = completion {
					state = .terminal(e)
					lock.unlock()
				} else {
					state = .terminal(nil)
					lock.unlock()
				}
			case .terminal:
				let pending = self.pending
				lock.unlock()
				pending.resumeAllWithNil()
			}
		}

		func cancel() {
			lock.lock()
			let pending = self.pending
			guard case .subscribed(let subscription) = state else {
				state = .terminal(nil)
				lock.unlock()
				pending.resumeAllWithNil()
				return
			}
			state = .terminal(nil)
			lock.unlock()
			subscription.cancel()
			pending.resumeAllWithNil()
		}

		func next() async throws -> Input? {
			return try await withUnsafeThrowingContinuation { continuation in
				lock.lock()
				switch state {
				case .awaitingSubscription:
					pending.append(continuation)
					pendingDemand += 1
					lock.unlock()
				case .subscribed(let subscription):
					pending.append(continuation)
					lock.unlock()
					subscription.request(.max(1))
				case .terminal(nil):
					lock.unlock()
					continuation.resume(returning: nil)
				case .terminal(let error?):
					state = .terminal(nil)
					lock.unlock()
					continuation.resume(throwing: error)
				}
			}
		}
	}
}

extension Sequence {
	fileprivate func resumeAllWithNil<Output, Failure: Error>()
	where Element == UnsafeContinuation<Output?, Failure> {
		for continuation in self {
			continuation.resume(returning: nil)
		}
	}
}
