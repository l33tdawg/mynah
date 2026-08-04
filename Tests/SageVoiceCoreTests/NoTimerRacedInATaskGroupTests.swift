import XCTest
@testable import SageVoiceCore

/// One mistake, made three times, each time in something that only fails when it
/// is needed.
///
/// ## The shape
///
/// ```swift
/// try await withThrowingTaskGroup(of: T.self) { group in
///     group.addTask { try await somethingThatMightNeverFinish() }
///     group.addTask { try await Task.sleep(...); throw TimedOut() }
///     let first = try await group.next()   // take whichever wins
///     group.cancelAll()
///     return first
/// }
/// ```
///
/// It reads as "whichever finishes first", and it is not. **A task group cannot
/// leave its scope until every child has finished.** When the timer wins, the
/// group cancels the work and then waits for it — so the timeout only works when
/// the work was cancellable, which is exactly when it was going to finish
/// anyway. Against the thing it was written for, it hangs.
///
/// ## Where it shipped
///
/// - `withDeadline`, the turn watchdog. Never fired once, through four releases.
///   Caught in production: a turn parked at 10:42:41 was still parked at 10:51,
///   three minutes past a 360-second ceiling.
/// - `BrowserSearchBackend.load`, the page-load timeout. Every Signal question
///   that reached for a search died silently on the daemon's ceiling instead —
///   three in a row on 4 August, with no `[web_search]` line in the log at all.
/// - `LoopbackCallbackListener.awaitCallback`, the Google sign-in redirect.
///   Never reported, and only because nobody left the consent tab open.
///
/// All three parked on a `CheckedContinuation` resumed by somebody else — a
/// delegate, a socket, a pipe. Cancellation does not resume a continuation.
///
/// ## The rule
///
/// A timeout must **resume the wait**, not race it. One continuation, one place
/// that ends it, first outcome wins.
final class NoTimerRacedInATaskGroupTests: XCTestCase {

    /// Work that cannot be interrupted, which is what all three real cases were.
    private func uninterruptible(seconds: TimeInterval) async -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            DispatchQueue.global().async {
                Thread.sleep(forTimeInterval: seconds)
                continuation.resume(returning: "late")
            }
        }
    }

    /// The property all three were supposed to have, stated once.
    func testADeadlineReturnsWithoutWaitingForUninterruptibleWork() async {
        let started = Date()

        _ = try? await withDeadline(0.1, label: "wedged") {
            await self.uninterruptible(seconds: 4)
        }

        XCTAssertLessThan(
            Date().timeIntervalSince(started), 2,
            "the deadline waited for work it had already given up on"
        )
    }

    /// **The source guard.** Fixing three sites does not stop a fourth, and a
    /// fourth would be as invisible as these were — the symptom is silence.
    ///
    /// Looks for a task group that adds a `Task.sleep` child, which is the
    /// signature of racing a timer. A group that fans work out and collects it —
    /// `EnvironmentProbe`, `MCPAgentDirectory` — has no sleeping child and is
    /// not what this is about.
    func testNothingRacesATimerInsideATaskGroup() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)

        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty, "found no Swift sources, so this guard is checking nothing")

        var offenders: [String] = []
        for file in files {
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            // Comments stripped first. Every one of the three sites now carries a
            // long comment *about* this mistake, naming both `withThrowingTaskGroup`
            // and `Task.sleep` — so a guard that reads prose flags the very
            // fixes it exists to protect, and would have to be deleted to go
            // green. Which is how a guard becomes a comment.
            for group in Self.taskGroupBodies(in: Self.code(in: source))
            where group.contains("Task.sleep") {
                offenders.append(file.lastPathComponent)
                break
            }
        }

        XCTAssertEqual(
            offenders, [],
            """
            these race a sleeping timer against work inside a task group, which \
            cannot return until the work finishes — so the timeout does nothing \
            in exactly the case it exists for: \(offenders.joined(separator: ", "))
            """
        )
    }

    /// The source with `//` comments removed, line by line.
    ///
    /// Blank-padded rather than deleted, so brace depth and line structure are
    /// untouched — a comment containing a stray brace must not shift where a
    /// group is thought to end.
    static func code(in source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            guard let comment = line.range(of: "//") else { return String(line) }
            return String(line[..<comment.lowerBound])
        }.joined(separator: "\n")
    }

    /// The text of each `with*TaskGroup { … }` body, matched by brace depth.
    ///
    /// Crude on purpose. It only has to be right about where a group ends, and a
    /// false positive here costs a comment rewrite rather than a wrong release.
    static func taskGroupBodies(in source: String) -> [String] {
        var bodies: [String] = []
        var search = source.startIndex..<source.endIndex

        while let opening = source.range(of: "TaskGroup", range: search) {
            guard let brace = source.range(of: "{", range: opening.upperBound..<source.endIndex) else { break }
            var depth = 0
            var index = brace.lowerBound
            var end = brace.lowerBound
            while index < source.endIndex {
                if source[index] == "{" { depth += 1 }
                if source[index] == "}" {
                    depth -= 1
                    if depth == 0 { end = index; break }
                }
                index = source.index(after: index)
            }
            bodies.append(String(source[brace.lowerBound...end]))
            search = source.index(after: end)..<source.endIndex
        }
        return bodies
    }
}
