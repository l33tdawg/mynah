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
            VoiceBridgeDaemon.turnCeiling,
            ToolLoop.defaultDeadlineSeconds,
            "the outer ceiling must not pre-empt the loop's own graceful stop"
        )
    }

    /// And not so far above it that the owner is left in silence for long. He
    /// was promised a return; six minutes is the outside of honest.
    func testTheTurnCeilingIsNotOpenEnded() {
        XCTAssertLessThanOrEqual(VoiceBridgeDaemon.turnCeiling, 420)
    }
}
