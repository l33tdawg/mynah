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
/// **Cancellation is best-effort and that is fine.** Cancelling `work` does not
/// necessarily unblock a synchronous read already in flight inside it. What this
/// guarantees is that the *caller* stops waiting, which is what unwedges the
/// appliance — the abandoned work finishes into nothing whenever it finishes.
public func withDeadline<T: Sendable>(
    _ seconds: TimeInterval,
    label: String,
    work: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw DeadlineExceeded(label: label, seconds: seconds)
        }
        // Whichever finishes first. `next()` rethrows, so a deadline that fires
        // before the work lands throws out of here with the timer's error.
        guard let first = try await group.next() else {
            throw DeadlineExceeded(label: label, seconds: seconds)
        }
        group.cancelAll()
        return first
    }
}
