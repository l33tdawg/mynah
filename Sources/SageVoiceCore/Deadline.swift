import Foundation

/// Thrown by `withDeadline` when the work did not finish in time.
public struct DeadlineExceeded: Error, CustomStringConvertible, Equatable {
    public let label: String
    public let seconds: TimeInterval

    public init(label: String, seconds: TimeInterval) {
        self.label = label
        self.seconds = seconds
    }

    public var description: String {
        "\(label) did not finish within \(Int(seconds))s"
    }
}

/// The first answer wins, and every later one is dropped.
///
/// A plain `CheckedContinuation` cannot be used directly here because two
/// independent tasks race to resume it and resuming twice is a crash. This holds
/// the first outcome whether or not anybody is waiting yet, which also closes the
/// window where the work finishes before the caller reaches its `await`.
private final class DeadlineGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var settled = false
    private var stored: Result<T, Error>?
    private var waiting: CheckedContinuation<T, Error>?

    func finish(_ outcome: Result<T, Error>) {
        lock.lock()
        guard !settled else {
            lock.unlock()
            return
        }
        settled = true
        if let waiting {
            self.waiting = nil
            lock.unlock()
            waiting.resume(with: outcome)
        } else {
            stored = outcome
            lock.unlock()
        }
    }

    func value() async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let stored {
                self.stored = nil
                lock.unlock()
                continuation.resume(with: stored)
            } else {
                waiting = continuation
                lock.unlock()
            }
        }
    }
}

/// Runs `work`, giving up after `seconds`.
///
/// **A backstop against waits nobody bounded.** Every individual network call in
/// this appliance has a timeout — the model's is 120s, web search sets one on
/// its session — and the tool loop has its own deadline. None of that was
/// enough, because the loop's deadline is checked *between* iterations and
/// never during one, and `MCPClient` reads the node's pipe with no deadline at
/// all. So a single call that never returns parks the turn forever.
///
/// Which is what happened, and the shape of it matters: turns are serialised, so
/// one wedged turn stops the appliance answering Signal entirely. The owner
/// asked a question at 22:00, was told "I'll come back when it's all done", sent
/// two more messages a minute later, and got nothing for the next fourteen
/// minutes. The daemon was alive the whole time and using no CPU — parked in an
/// await. Nothing was logged, because none of the waits that could cause it
/// write anything down.
///
/// This does not fix any particular hang. It makes every hang finite, which is
/// the property that was missing: whatever new way a turn finds to never come
/// back, the owner gets told and the queue is freed.
///
/// ## Why this is not a task group, having been one
///
/// The first version raced the work against a sleeping timer inside
/// `withThrowingTaskGroup`, and it **did not work at all for the case it was
/// written for**. A task group cannot leave its scope until every child has
/// finished. So when the timer won, the group cancelled the work and then sat
/// waiting for it — and if that work was parked in something cancellation cannot
/// interrupt, which is precisely the blocking pipe read named above, the group
/// waited forever. The watchdog was structurally incapable of firing in the one
/// situation it existed for, while looking, in the log and in the source, as
/// though it were armed.
///
/// It shipped in 1.5.4 and was caught on 4 August 2026, when a turn that started
/// at 10:42:41 was still parked at 10:51 — three minutes past a 360-second
/// ceiling — with the appliance answering nothing on Signal and its other loops
/// ticking away happily beside it.
///
/// So the work runs in an **unstructured** task, which nobody has to await. When
/// the deadline wins, the caller is handed `DeadlineExceeded` and walks away
/// while the orphan is still parked. That is the whole point, and it is what
/// "the caller stops waiting" always meant.
///
/// **Cancellation is still best-effort**, and still fine. The abandoned work is
/// cancelled on the way out and finishes into nothing whenever it finishes. What
/// is no longer conditional on cancellation working is the appliance answering
/// the next message.
public func withDeadline<T: Sendable>(
    _ seconds: TimeInterval,
    label: String,
    work: @escaping @Sendable () async throws -> T
) async throws -> T {
    let gate = DeadlineGate<T>()

    let worker = Task {
        do {
            gate.finish(.success(try await work()))
        } catch {
            gate.finish(.failure(error))
        }
    }
    let timer = Task {
        // `try?`, because a cancelled timer is the ordinary case: the work
        // landed first and this is being torn down.
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        guard !Task.isCancelled else { return }
        gate.finish(.failure(DeadlineExceeded(label: label, seconds: seconds)))
    }
    defer {
        worker.cancel()
        timer.cancel()
    }

    return try await withTaskCancellationHandler {
        try await gate.value()
    } onCancel: {
        // The caller gave up. Without this the gate would still be waiting on a
        // race neither side has won, which is the same hang one level out.
        gate.finish(.failure(CancellationError()))
    }
}
