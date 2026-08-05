import XCTest
@testable import SageVoiceCore

/// A filler line and an opener must never be the same words.
///
/// ## Why this is worth a test of its own
///
/// The opener is what the caller hears the instant they stop speaking; the
/// ladder covers the wait after it. Drawing the same words for both means a
/// caller hears a line and then, six seconds later, the same line — a stutter
/// that reads as a stuck machine, which is exactly the impression the ladder
/// exists to prevent.
///
/// The second failure is worse, because it is how the first would stay broken.
/// The only way this suite can tell a ladder line from an opener is pool
/// membership — `CallFiller.isAFillerLine`, which is
/// `Set(pools.flatMap { $0 }).contains`. `FillerStopsWhenTheAnswerLandsTests`
/// protects itself against a vacuous pass with `XCTAssertFalse(fillers.isEmpty)`,
/// and a colliding string satisfies that guard **with an opener**, having never
/// run the ladder at all. So a collision disables the check that exists to stop
/// this suite passing against the defect.
///
/// ## Which pool, and the mistake this file was written with
///
/// The first version of this compared the ladder against `WaitingPhrases`, and
/// **the call never speaks a `WaitingPhrases` line.** That pool has exactly one
/// call site in the whole tree — `VoiceBridgeDaemon`'s thinking
/// acknowledgement, on Signal, behind a flag that defaults off. The call's
/// opener comes from `WorkingReply.opening` / `interruptedOpening`.
///
/// So the guard was watching a pool that could not produce the failure it
/// describes: it would have gone green forever while the real collision sat
/// unwatched. Caught by the 1.7.3 review, and it is the same defect this
/// codebase keeps making — a rule enforced against one surface while the
/// identical one goes unexamined — committed inside the test written to catch
/// that defect.
///
/// It now checks both pools, and `WorkingReply` is the load-bearing one.
final class FillerAndOpenerPoolsAreDisjointTests: XCTestCase {

    /// Everything the call can say as an opener.
    ///
    /// `opening` returns either a per-tool line, an instant line, or a
    /// catch-all, and `interruptedOpening` prefixes a specific one or falls back
    /// to its own sentence. Enumerated rather than sampled, because `opening`
    /// chooses at random within a pool and one draw proves nothing about the
    /// other two — the mistake `CallFiller.isAFillerLine` documents.
    private var everyOpenerTheCallCanSpeak: Set<String> {
        var lines = Set(WorkingReply.catchAllOptions)
        for tools in [["web_search"], ["sage_recall"], ["sage_task"], ["sage_remember"], ["notes_write"]] {
            lines.formUnion(WorkingReply.lines(forTools: tools) ?? [])
        }
        for request in ["what's the weather", "remind me to call him", "hello", "what did I say yesterday"] {
            lines.formUnion(WorkingReply.instantOptions(forRequest: request) ?? [])
        }
        // The interrupted fallback, which is a literal rather than a pool.
        lines.insert("Right — let me get that instead.")
        return lines
    }

    /// **The one that matters: the ladder against what the call actually says.**
    func testNoFillerLineIsAlsoSomethingTheCallSaysAsAnOpener() {
        let ladder = Set(CallFiller.pools.flatMap { $0 })
        let shared = ladder.intersection(everyOpenerTheCallCanSpeak).sorted()

        XCTAssertEqual(
            shared, [],
            """
            these lines are in both the call's filler ladder and its opener pool: \
            \(shared.joined(separator: ", ")). A caller can be told the same words \
            twice six seconds apart, and the suite's only way to recognise a filler \
            is pool membership — so an opener would count as "a filler fired" and \
            the non-vacuity guard in FillerStopsWhenTheAnswerLandsTests could be \
            satisfied without the ladder ever running.
            """
        )
    }

    /// And against the Signal-side pool too, which is where the historical
    /// collision actually was.
    func testNoFillerLineIsAlsoAWaitingPhrase() {
        let ladder = Set(CallFiller.pools.flatMap { $0 })
        let shared = ladder.intersection(Set(WaitingPhrases.all)).sorted()

        XCTAssertEqual(
            shared, [],
            "the filler ladder shares lines with WaitingPhrases: \(shared.joined(separator: ", "))"
        )
    }

    /// Every pool is non-empty, so an emptied one cannot make the above pass.
    ///
    /// The sentinel matters more here than usual: `lines(forTools:)` and
    /// `instantOptions(forRequest:)` both return `Optional`, and a `?? []` on a
    /// nil is indistinguishable from a pool with nothing in it.
    func testEveryPoolActuallyHasLinesInIt() {
        XCTAssertFalse(
            CallFiller.pools.flatMap { $0 }.isEmpty,
            "the filler ladder has no lines, so the disjointness above is vacuously true"
        )
        XCTAssertFalse(
            WaitingPhrases.all.isEmpty,
            "WaitingPhrases has no lines, so the disjointness above is vacuously true"
        )
        XCTAssertGreaterThan(
            everyOpenerTheCallCanSpeak.count, 10,
            """
            only \(everyOpenerTheCallCanSpeak.count) opener lines were collected, which \
            is too few to be the real pool — lines(forTools:) or instantOptions(forRequest:) \
            is returning nil for the probes above, so the intersection is comparing \
            against almost nothing and cannot fail.
            """
        )
    }

    /// The rungs do not repeat each other either.
    ///
    /// `pools` documents this — *"nothing in a later pool appears in an earlier
    /// one — hearing 'nearly there' as the first thing after a question would be
    /// a claim the appliance cannot make yet"* — and nothing checked it. The
    /// ladder's whole meaning is that it escalates, so a line appearing on two
    /// rungs makes the escalation a coincidence of which draw came up.
    func testNoLineAppearsOnTwoRungs() {
        var seen: [String: Int] = [:]
        var repeated: [String] = []
        for (rung, lines) in CallFiller.pools.enumerated() {
            for line in lines {
                if let earlier = seen[line] {
                    repeated.append("\"\(line)\" on rungs \(earlier) and \(rung)")
                }
                seen[line] = rung
            }
        }
        XCTAssertEqual(
            repeated, [],
            "the ladder repeats itself, so it does not escalate: \(repeated.joined(separator: "; "))"
        )
    }

    /// And each rung of the ladder can still offer a choice.
    ///
    /// Resolving the collision by deleting lines would leave a rung with one
    /// line in it, and `line(at:previous:)` refuses to repeat the previous
    /// line — so a one-line rung goes silent exactly when it is reached twice.
    func testEveryRungStillHasSomethingToSay() {
        for (rung, lines) in CallFiller.pools.enumerated() {
            XCTAssertGreaterThanOrEqual(
                lines.count, 2,
                """
                rung \(rung) of the filler ladder has \(lines.count) line(s). \
                line(at:previous:) will not repeat the previous line, so a rung \
                with fewer than two can fall silent on the turn it is needed.
                """
            )
        }
    }
}
