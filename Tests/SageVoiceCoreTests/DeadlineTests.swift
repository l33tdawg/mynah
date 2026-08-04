import XCTest
@testable import SageVoiceCore

/// The backstop against waits nobody bounded.
///
/// **What it is for, from the night it was written.** The owner asked a question
/// at 22:00 and was told "I'll come back when it's all done". He sent two more
/// messages a minute later. Fourteen minutes on there was still no answer, no
/// error, and nothing in the log — the daemon alive the whole time at 0% CPU,
/// parked in an await. Turns are serialised, so the two follow-ups were accepted
/// and never processed either: one wedged turn had stopped the appliance
/// answering Signal at all.
///
/// Every individual call had a timeout except the node's pipe, and the tool
/// loop's own deadline could not help because it is checked between iterations
/// and never during one.
final class DeadlineTests: XCTestCase {

    func testWorkThatFinishesInTimeIsReturned() async throws {
        let value = try await withDeadline(5, label: "quick") { "done" }
        XCTAssertEqual(value, "done")
    }

    func testWorkThatOverrunsThrows() async {
        do {
            _ = try await withDeadline(0.05, label: "slow") {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return "never"
            }
            XCTFail("expected the deadline to fire")
        } catch let error as DeadlineExceeded {
            XCTAssertEqual(error.label, "slow")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// The work's own error must survive rather than being reported as a
    /// timeout — a rejected key and a hang need different sentences.
    func testAnErrorFromTheWorkIsNotDisguisedAsATimeout() async {
        struct Rejected: Error {}
        do {
            _ = try await withDeadline(5, label: "failing") { throw Rejected() }
            XCTFail("expected the work's own error")
        } catch is DeadlineExceeded {
            XCTFail("the work's error was replaced by a timeout")
        } catch is Rejected {
            // Correct.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// **The property that actually unwedges the appliance.** Cancelling the
    /// work does not necessarily unblock a read already in flight inside it, and
    /// it does not need to — what matters is that the caller stops waiting, so
    /// the next message gets answered.
    /// **This test passed for the wrong reason and hid a watchdog that never
    /// fired.** It used `try? await Task.sleep`, which is *cancellable*: the
    /// group cancelled it, it returned at once, and the group exited in
    /// milliseconds. So it measured a fast cancellation while claiming to
    /// measure an uncancellable one, and the real case — `MCPClient` parked in a
    /// blocking pipe read — went untested through four releases.
    ///
    /// Found on 4 August 2026, in production: a turn that started at 10:42:41
    /// was still parked at 10:51, three minutes past its 360-second ceiling, with
    /// Signal answering nothing.
    ///
    /// So the work here blocks a real thread and cannot be interrupted, which is
    /// what a pipe read does.
    func testTheCallerStopsWaitingEvenIfTheWorkNeverDoes() async {
        let started = Date()

        _ = try? await withDeadline(0.1, label: "wedged") {
            await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
                // A real blocked thread. `Task.cancel()` has no effect on this,
                // and neither has anything else.
                DispatchQueue.global().async {
                    Thread.sleep(forTimeInterval: 5)
                    continuation.resume(returning: "never")
                }
            }
        }

        XCTAssertLessThan(
            Date().timeIntervalSince(started), 3,
            "the caller was still waiting on work that had been abandoned"
        )
    }

    /// And it must be the deadline it reports, not a cancellation — the owner
    /// gets a different sentence for each and only one of them is true here.
    func testTheAbandonedCallerIsToldItWasTheDeadline() async {
        do {
            _ = try await withDeadline(0.1, label: "wedged") {
                await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
                    DispatchQueue.global().async {
                        Thread.sleep(forTimeInterval: 3)
                        continuation.resume(returning: "never")
                    }
                }
            }
            XCTFail("the wedged work was allowed to succeed")
        } catch let deadline as DeadlineExceeded {
            XCTAssertEqual(deadline.label, "wedged")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    /// The next message is answered while the first is still stuck, which is the
    /// property the whole thing exists for — one wedged turn must not take the
    /// appliance down, because turns are serialised.
    func testAWedgedTurnDoesNotBlockTheOneBehindIt() async throws {
        let started = Date()
        let stuck = Task {
            try? await withDeadline(0.1, label: "wedged") {
                await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
                    DispatchQueue.global().async {
                        Thread.sleep(forTimeInterval: 5)
                        continuation.resume(returning: "never")
                    }
                }
            }
        }

        _ = await stuck.value
        let answered = try await withDeadline(5, label: "next") { "here you go" }

        XCTAssertEqual(answered, "here you go")
        // Timed, or this passes on an implementation that simply waits out the
        // orphan — which is what the previous one did, for five seconds.
        XCTAssertLessThan(
            Date().timeIntervalSince(started), 3,
            "the second turn waited for the first one's abandoned work"
        )
    }

    /// The ceiling sits above the loop's own brake, so it only ever fires when
    /// that brake failed. Two competing deadlines where the outer one is tighter
    /// would cut off turns the loop was about to finish properly.
    func testTheTurnCeilingIsAboveTheLoopsOwnDeadline() {
        XCTAssertGreaterThan(
            VoiceBridgeDaemon.Configuration.defaultTurnCeilingSeconds,
            ToolLoop.defaultDeadlineSeconds,
            "the outer ceiling must not pre-empt the loop's own graceful stop"
        )
    }

    /// And not so far above it that the owner is left in silence for long. He
    /// was promised a return; six minutes is the outside of honest.
    func testTheTurnCeilingIsNotOpenEnded() {
        XCTAssertLessThanOrEqual(VoiceBridgeDaemon.Configuration.defaultTurnCeilingSeconds, 420)
    }

    // MARK: - The ceiling is around the turn, and not merely available

    /// **Everything above this line exercises `withDeadline` with a closure of
    /// its own, and none of it asks whether the appliance still uses it.**
    ///
    /// Found on 4 August 2026 by deleting the one line in `Sources/` that wraps
    /// the daemon's turn — `let result = try await withDeadline(…) {` and its
    /// closing brace — and running the suite. Every test here still passed. The
    /// watchdog was gone, the fourteen-minute silence was back, and the file
    /// that exists to prevent it reported success in a tenth of a second.
    ///
    /// It passes because `ToolLoop.run` is `async throws` with no declared error
    /// type. Unwrap the call and the result type is unchanged, so it still
    /// compiles; `catch let error as DeadlineExceeded` below it stays legal and
    /// simply never matches. Nothing in the type system, and nothing in the
    /// suite, could tell the difference.
    ///
    /// A source scan, in the shape `MemoryOwnedScopeTests` uses and for the same
    /// reason: the seam is inside an actor that owns a live Signal connection and
    /// an MCP client, so reaching it at runtime means standing up the appliance.
    /// Spans are matched by brace depth rather than by distance — the first
    /// version of that other guard used a 400-character window and read the
    /// neighbouring branch, which is how a guard about guards shipped unable to
    /// fail.
    func testTheDaemonRunsNoTurnItHasNotBounded() throws {
        let scan = SwiftSourceScan(try Self.daemonSource())
        let turns = Self.turnCalls(in: scan)

        XCTAssertFalse(
            turns.isEmpty,
            """
            no tool-loop turn was found in VoiceBridgeDaemon.swift, so this guard is \
            checking nothing. If the turn moved, point this at where it went.
            """
        )

        let bounded = Self.deadlineSpans(in: scan)
        let loose = turns
            .filter { call in !bounded.contains { $0.contains(call) } }
            .map { "line \(scan.line(of: $0)): \(scan.statement(at: $0))" }

        XCTAssertEqual(
            loose, [],
            """
            the daemon runs a turn that no withDeadline encloses, so a wedged tool call \
            parks the appliance for as long as it likes — turns are serialised, so every \
            message behind it goes unanswered too, which is the 22:00 silence this file \
            was written for: \(loose.joined(separator: "; "))
            """
        )
    }

    /// And bounded by the ceiling the two tests above pin, not by a number
    /// somebody typed at the call site.
    ///
    /// Those two compare `defaultTurnCeilingSeconds` against
    /// `ToolLoop.defaultDeadlineSeconds` and say nothing about what the daemon
    /// passes. A literal `withDeadline(30, …)` around the turn would satisfy the
    /// guard above, keep both constants true, and cut off every turn that took
    /// longer than half a minute.
    func testTheTurnIsBoundedByTheConfiguredCeiling() throws {
        let scan = SwiftSourceScan(try Self.daemonSource())
        let turns = Self.turnCalls(in: scan)
        XCTAssertFalse(turns.isEmpty, "no tool-loop turn was found, so this guard is checking nothing")

        for turn in turns {
            let ceiling = Self.deadlines(in: scan)
                .first { $0.span.contains(turn) }
                .map { scan.text(in: $0.arguments) }

            XCTAssertNotNil(ceiling, "line \(scan.line(of: turn)) runs a turn outside every deadline")
            XCTAssertEqual(
                ceiling?.contains("turnCeilingSeconds"), true,
                """
                the turn at line \(scan.line(of: turn)) is bounded by something other than \
                Configuration.turnCeilingSeconds — \(ceiling ?? "nothing") — so the two \
                tests above pin a number the daemon does not use
                """
            )
        }
    }

    // MARK: The scan

    /// `VoiceBridgeDaemon.swift`, as text.
    ///
    /// Read from disk rather than reached through the type, because what is
    /// being asserted is the *shape* of the call and a compiled type cannot say
    /// whether its own body was wrapped.
    static func daemonSource() throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/SageVoiceCore/VoiceBridgeDaemon.swift"),
            encoding: .utf8
        )
    }

    /// Where the daemon hands a transcript to the brain.
    ///
    /// Matched on the argument label rather than on the receiver's name, because
    /// the receiver is a local — `let brain = loop` — resolved on the actor
    /// before the closure takes the work off it, and renaming it must not
    /// silently empty this scan.
    static func turnCalls(in scan: SwiftSourceScan) -> [Int] {
        scan.indices(of: ".run(").filter { call in
            guard let arguments = scan.arguments(from: call) else { return false }
            return scan.text(in: arguments).contains("transcript:")
        }
    }

    /// Every `withDeadline(…) { … }` in the file, as the argument list it was
    /// given and the span it bounds.
    static func deadlines(in scan: SwiftSourceScan) -> [(arguments: Range<Int>, span: Range<Int>)] {
        scan.indices(of: "withDeadline(").compactMap { call in
            guard let arguments = scan.arguments(from: call),
                  let span = scan.block(from: arguments.upperBound) else { return nil }
            return (arguments, span)
        }
    }

    static func deadlineSpans(in scan: SwiftSourceScan) -> [Range<Int>] {
        deadlines(in: scan).map(\.span)
    }
}
