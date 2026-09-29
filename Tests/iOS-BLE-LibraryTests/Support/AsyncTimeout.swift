//
//  AsyncTimeout.swift
//
//  Arccos test support.
//
//  The library's known defect class is "awaits that never resume" (a publisher that
//  completes empty, a discovery op wedged behind a disconnect). A test for that class
//  must be able to *fail* on a hang instead of hanging the whole suite, and XCTest has
//  no per-test deadline under `swift test`. `withTimeout` is that deadline.
//

import Foundation

/// Thrown by ``withTimeout(_:_:operation:)`` when the deadline passes first.
struct TimeoutError: Error, CustomStringConvertible {
    let seconds: TimeInterval
    let label: String

    var description: String {
        "'\(label)' did not complete within \(seconds)s"
    }
}

/// Races `operation` against a deadline.
///
/// The operation runs in an unstructured task on purpose: a structured task group would
/// wait for the child to finish, and an operation that ignores cancellation (which is exactly
/// the defect these tests exist to catch) would then hang the group too. On timeout the
/// operation's task is cancelled and abandoned; the test proceeds with `TimeoutError`.
///
/// - Parameters:
///   - seconds: The deadline.
///   - label: Shown in the error; defaults to the calling function.
///   - operation: The work to bound.
func withTimeout<T>(
    _ seconds: TimeInterval,
    _ label: String = #function,
    operation: @escaping () async throws -> T
) async throws -> T {
    let gate = ResumeOnce<T>()

    let work = Task {
        do {
            gate.resume(.success(try await operation()))
        } catch {
            gate.resume(.failure(error))
        }
    }

    let timer = Task {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        if gate.resume(.failure(TimeoutError(seconds: seconds, label: label))) {
            work.cancel()
        }
    }
    defer { timer.cancel() }

    return try await withCheckedThrowingContinuation { continuation in
        gate.attach(continuation)
    }
}

/// Captures an async operation's outcome so it can be asserted on synchronously, for example
/// inside an `XCTExpectFailure { }` closure: expected-failure matching is thread-scoped and
/// does not survive an `await`, so assertions must not sit directly after one.
func outcome<T>(of operation: () async throws -> T) async -> Result<T, Error> {
    do {
        return .success(try await operation())
    } catch {
        return .failure(error)
    }
}

/// Resumes a continuation exactly once, whichever side (work or timer) gets there first,
/// and regardless of whether the result arrives before or after the continuation is attached.
private final class ResumeOnce<T> {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var early: Result<T, Error>?
    private var resumed = false

    func attach(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        if let early {
            self.early = nil
            lock.unlock()
            continuation.resume(with: early)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    /// - Returns: `true` if this call won the race.
    @discardableResult
    func resume(_ result: Result<T, Error>) -> Bool {
        lock.lock()
        guard !resumed else {
            lock.unlock()
            return false
        }
        resumed = true
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
        } else {
            early = result
            lock.unlock()
        }
        return true
    }
}
