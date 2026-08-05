import XCTest
@testable import SageVoiceCore

/// A filler line and an opener must never be the same words.
///
/// ## Why this is worth a test of its own
///
/// It is not a tidiness rule. `"One moment."` and `"Bear with me."` are in the
/// call's filler ladder *and* in `WaitingPhrases`, and the collision was live on
/// the owner's Mac: `bridge.log` shows the call **opener** saying "One moment."
/// four times, in the opener's own log format.
///
/// Two things break, and the second is worse than the first.
///
/// **On the phone.** The opener is what the caller hears the instant they finish
/// speaking; the ladder is what covers the wait afterwards. Drawing the same
/// three words for both means a caller can hear "One moment." and then, six
/// seconds later, "One moment." — a stutter that reads as a stuck machine, which
/// is the exact impression the ladder exists to prevent.
///
/// **In the test suite, which is how it would stay broken.** The only way the
/// suite can tell a ladder line from an opener is pool membership —
/// `CallFiller.isAFillerLine`, which is `Set(pools.flatMap { $0 }).contains`.
/// `FillerStopsWhenTheAnswerLandsTests` guards against a vacuous pass with
/// `XCTAssertFalse(fillers.isEmpty)`, and a colliding string satisfies that
/// guard **with an opener**, having never run the ladder at all. So the
/// collision disables the non-vacuity check that exists to stop this suite
/// passing against the defect.
///
/// Which makes this the guard that protects the other guard, and the reason it
/// asserts a property of the data rather than a behaviour.
final class FillerAndOpenerPoolsAreDisjointTests: XCTestCase {

    func testNoFillerLineIsAlsoAWaitingPhrase() {
        let ladder = Set(CallFiller.pools.flatMap { $0 })
        let openers = Set(WaitingPhrases.all)
        let shared = ladder.intersection(openers).sorted()

        XCTAssertEqual(
            shared, [],
            """
            these lines are in both the call's filler ladder and the opener pool: \
            \(shared.joined(separator: ", ")). A caller can be told the same three \
            words twice six seconds apart, and — worse — the suite's only way to \
            recognise a filler is pool membership, so an opener now counts as \
            "a filler fired" and the non-vacuity guard in \
            FillerStopsWhenTheAnswerLandsTests can be satisfied without the ladder \
            ever running.
            """
        )
    }

    /// Both pools are non-empty, so an emptied one cannot make this pass.
    func testBothPoolsActuallyHaveLinesInThem() {
        XCTAssertFalse(
            CallFiller.pools.flatMap { $0 }.isEmpty,
            "the filler ladder has no lines, so the disjointness above is vacuously true"
        )
        XCTAssertFalse(
            WaitingPhrases.all.isEmpty,
            "the opener pool has no lines, so the disjointness above is vacuously true"
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
