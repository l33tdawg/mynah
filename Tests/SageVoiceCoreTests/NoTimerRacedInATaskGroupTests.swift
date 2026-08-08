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
    /// Looks for a task group that adds a *waiting* child, which is the
    /// signature of racing a timer. A group that fans work out and collects it —
    /// `EnvironmentProbe` — has no waiting child and is not what this is about.
    ///
    /// **It could not fail, twice over, and both reasons are recorded in the
    /// fixtures below.**
    ///
    /// It matched the literal `Task.sleep` and nothing else, so the same race
    /// written with `clock.sleep`, `DispatchQueue.asyncAfter` or a `Timer` was
    /// invisible — and those are not exotic, they are what somebody reaches for
    /// when the compiler complains about `Task.sleep` in a non-async context.
    ///
    /// Worse, its comment stripper cut every line at its first `//` with no idea
    /// what a string literal is. One `"https://…"` inside a group body deleted
    /// the rest of that line, including its closing brace, so the brace matcher
    /// ran off and the body came back as a single character. A one-character
    /// body contains nothing, and the file it was in reported clean.
    func testNothingRacesATimerInsideATaskGroup() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)

        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty, "found no Swift sources, so this guard is checking nothing")

        var offenders: [String] = []
        var groups = 0
        for file in files {
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            groups += Self.taskGroupBodies(in: source).count
            offenders += Self.racedTimers(in: source, file: file.lastPathComponent)
        }

        // The scan used to have no sentinel at all, which is how a stripper that
        // ate whole bodies could go unnoticed: no bodies, no offenders, green.
        XCTAssertGreaterThan(
            groups, 0,
            "no task group was found anywhere in Sources/, so this guard is checking nothing"
        )

        XCTAssertEqual(
            offenders, [],
            """
            these race a waiting child against work inside a task group, which \
            cannot return until the work finishes — so the timeout does nothing \
            in exactly the case it exists for: \(offenders.joined(separator: ", "))
            """
        )
    }

    // MARK: What a fixture proves that Sources/ cannot

    /// **The string literal that blinded the scan, as a fixture.**
    ///
    /// A single URL in a group body used to delete that line's closing brace,
    /// which left the brace matcher unbalanced and the body one character long.
    /// Written down here because `Sources/` is clean today and a clean tree
    /// cannot demonstrate a scanner that sees nothing.
    func testAURLInsideAGroupDoesNotSwallowItsBody() {
        let bodies = Self.taskGroupBodies(in: Self.urlFixture)
        XCTAssertEqual(bodies.count, 1)
        XCTAssertTrue(
            bodies.first?.contains("Task.sleep") ?? false,
            "the group's body stopped at the URL: \(bodies.first ?? "nothing")"
        )
        XCTAssertFalse(
            bodies.first?.contains("somethingElseEntirely") ?? true,
            "the group's body ran past its own closing brace into the next declaration"
        )
        XCTAssertEqual(
            Self.racedTimers(in: Self.urlFixture, file: "Fixture.swift"),
            ["Fixture.swift: Task.sleep"]
        )
    }

    /// A racing group with one URL in it, and one declaration after it.
    ///
    /// The URL's `//` sits before that line's closing brace, which is the whole
    /// mechanism: strip from `//` to end-of-line and the brace goes with it, so
    /// the matcher is one level short for the rest of the file and never returns
    /// to zero. The old implementation then reported this body as the single
    /// character `{`, found no timer in it, and passed.
    ///
    /// `somethingElseEntirely` is the other half of the same property: a body
    /// that runs *past* its group is as wrong as one that stops short, and would
    /// make this guard report a race in whatever happened to follow.
    static let urlFixture = """
    await withThrowingTaskGroup(of: String.self) { group in
        group.addTask { try await fetch("https://example.com/search?q=1") }
        group.addTask {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            throw TimedOut()
        }
        let first = try await group.next()
        group.cancelAll()
        return first ?? ""
    }

    func somethingElseEntirely() {
        let marker = "not part of the group"
    }
    """

    /// And the strip still has to happen, because the three real fixes each
    /// carry a paragraph naming `withThrowingTaskGroup` and `Task.sleep` in the
    /// same breath. A guard that reads prose flags the fix it exists to protect.
    func testATimerDescribedInACommentIsNotATimerRaced() {
        let fixture = """
        func wait() async {
            await withTaskGroup(of: Void.self) { group in
                // This used to add a child that did `try await Task.sleep(…)`
                // and race it, which is the mistake this comment describes.
                group.addTask { await work() }
            }
        }
        """

        XCTAssertEqual(Self.racedTimers(in: fixture, file: "Fixture.swift"), [])
    }

    /// **Every way to wait, not the one that happened to be used three times.**
    /// `Task.sleep` needs an async context; the next person to write this race
    /// in a synchronous one will reach for one of these instead.
    func testTheOtherWaysToWaitAreSeenToo() {
        for timer in ["try await clock.sleep(until: deadline)",
                      "DispatchQueue.main.asyncAfter(deadline: .now() + 5) { done() }",
                      "Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { _ in done() }",
                      "Thread.sleep(forTimeInterval: 5)"] {
            let fixture = """
            func wait() async {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await work() }
                    group.addTask { \(timer) }
                    _ = await group.next()
                    group.cancelAll()
                }
            }
            """
            XCTAssertFalse(
                Self.racedTimers(in: fixture, file: "Fixture.swift").isEmpty,
                "unseen: \(timer)"
            )
        }
    }

    /// The shape that must stay legal: a group that fans work out and waits for
    /// all of it. `EnvironmentProbe` is this, and flagging it would make the
    /// guard something people switch off.
    func testAGroupThatMerelyFansOutIsNotFlagged() {
        let fixture = """
        func probe() async -> [String] {
            await withTaskGroup(of: String.self) { group in
                for command in commands {
                    group.addTask { await run(command) }
                }
                var results: [String] = []
                for await result in group { results.append(result) }
                return results
            }
        }
        """

        XCTAssertEqual(Self.taskGroupBodies(in: fixture).count, 1)
        XCTAssertEqual(Self.racedTimers(in: fixture, file: "Fixture.swift"), [])
    }

    // MARK: The scan

    /// The ways of waiting that turn a task group into a race.
    ///
    /// The first three shipped; the rest are here because the mistake is the
    /// shape, not the API. Each is reported by name so a failure says which line
    /// to look at rather than merely which file.
    static let waits = [
        "Task.sleep", ".sleep(for:", ".sleep(until:", "clock.sleep",
        "asyncAfter(", "Timer.scheduledTimer", "Timer.publish",
        "makeTimerSource", "Thread.sleep", "usleep(", "nanosleep("
    ]

    /// Every task group in one file that adds a waiting child.
    static func racedTimers(in source: String, file: String) -> [String] {
        var offenders: [String] = []
        for group in taskGroupBodies(in: source) {
            for wait in waits where group.contains(wait) {
                offenders.append("\(file): \(wait)")
                break
            }
        }
        return offenders
    }

    /// The source with comments removed.
    ///
    /// Blank-padded rather than deleted, so brace depth and line structure are
    /// untouched — a comment containing a stray brace must not shift where a
    /// group is thought to end.
    ///
    /// Delegated to `SwiftSourceScan`, which knows what a string literal is.
    /// This used to cut at the first `//` on the line, and a URL is not a
    /// comment.
    static func code(in source: String) -> String {
        let scan = SwiftSourceScan(source)
        return scan.text(in: 0..<scan.characters.count)
    }

    /// The text of each `with*TaskGroup { … }` body, matched by brace depth.
    ///
    /// Crude on purpose. It only has to be right about where a group ends, and a
    /// false positive here costs a comment rewrite rather than a wrong release.
    /// Braces inside comments and string literals are not braces, which is the
    /// whole of the fix.
    static func taskGroupBodies(in source: String) -> [String] {
        let scan = SwiftSourceScan(source)
        return scan.indices(of: "TaskGroup")
            .compactMap { scan.block(from: $0) }
            .map { scan.text(in: $0) }
    }
}
