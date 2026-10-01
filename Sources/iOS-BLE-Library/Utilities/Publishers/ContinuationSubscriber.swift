//
//  File.swift
//
//
//  Created by Nick Kibysh on 05/05/2023.
//

import Combine
import Foundation

/// Bridges a publisher's first value into a `CheckedContinuation` (see `Publisher.firstValue`).
///
/// Arccos (Wave C2, review finding i12): a completion that arrives before any value resumes the
/// continuation by throwing. Upstream ignored `.finished`, which left the awaiting task suspended
/// forever whenever a publisher finished empty (a connect cancelled before it completed, a scan
/// stopped before it matched). The continuation is resumed exactly once: `state` goes
/// `.terminated` under the lock before any resume, and every later event is dropped.
class ContinuationSubscriber<Upstream: Publisher>: Subscriber {

	typealias Input = Upstream.Output
	typealias Failure = Upstream.Failure

	private let continuation: CheckedContinuation<Input, Error>
	private var state: State = .waitingForSubscription
	private var lock = NSLock()
	private var subscription: Subscription?

	enum State {
		case waitingForSubscription
		case receivedSubscription
		case terminated
	}

	init(continuation: CheckedContinuation<Input, Error>) {
		self.continuation = continuation
	}

	func receive(subscription: Subscription) {
		lock.lock()
		guard case .waitingForSubscription = state else {
			lock.unlock()
			return
		}

		self.state = .receivedSubscription
		self.subscription = subscription
		lock.unlock()

		subscription.request(.max(1))
	}

	func receive(_ input: Upstream.Output) -> Subscribers.Demand {
		lock.lock()
		guard case .receivedSubscription = state else {
			lock.unlock()
			return .none
		}
		self.state = .terminated
		// Arccos (Wave C4): cancel BEFORE resuming. `resume` hands the awaiting task to the
		// executor, which may run it on another core at once; cancelling afterwards let that
		// task observe the request's side effect still in place (a scan still running after
		// `scanForPeripherals(...).firstValue` returned, seen on the 2-core CI runner). With the
		// cancel first, every cancel-side effect (`onCancel`: scan stopped, queued discovery
		// withdrawn) has run by the time `firstValue` returns.
		self.subscription?.cancel()
		continuation.resume(returning: input)
		lock.unlock()

		return .none
	}

	func receive(completion: Subscribers.Completion<Upstream.Failure>) {
		lock.lock()
		if case .terminated = state {
			lock.unlock()
			return
		}

		self.state = .terminated
		self.subscription = nil
		lock.unlock()

		switch completion {
		case .finished:
			// Arccos (Wave C2): no value is coming. Throw so the caller can retry or report,
			// instead of holding its task (and, in the app, the reconnection lock) forever.
			continuation.resume(throwing: FirstValueError.finishedWithoutValue)
		case .failure(let failure):
			continuation.resume(throwing: failure)
		}
	}
}

extension ContinuationSubscriber {
	
    static func withCheckedContinuation(_ upstream: Upstream) async throws -> Input where Upstream.Output == Input, Upstream.Failure == Failure {
            
		try await withCheckedThrowingContinuation { c in
			upstream.subscribe(ContinuationSubscriber(continuation: c))
		}
	}
}
