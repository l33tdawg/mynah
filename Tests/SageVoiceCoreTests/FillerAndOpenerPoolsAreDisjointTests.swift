// **Mac-only, because the live voice call is a Mac feature.**
//
// `Sources/SageVoiceCore/Call` is excluded from the target off Darwin — see
// `coreExclusions` in Package.swift — so none of the types below exist there.
// The exclusion and this guard are two halves of one decision, and the tests
// have to carry their half explicitly: a test file that cannot compile does not
// fail loudly, it takes the whole target down with it and every other test in
// the suite stops running too. That is what happened here.
#if os(macOS)
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

    /// Every sentence written down in either opener file, taken from the files.
    ///
    /// ## Why this reads the source instead of calling the functions
    ///
    /// Because calling the functions is what got this wrong twice. The first
    /// version compared against `WaitingPhrases`, which the call never speaks.
    /// The second called `lines(forTools:)` and `instantOptions(forRequest:)`
    /// with a handful of probe values I picked by reading a `switch` — and
    /// missed ten of the sixteen pools, because a probe list written by hand is
    /// a guess about a function's branches that goes stale the moment somebody
    /// adds a `case`. Its own non-vacuity sentinel passed, because I had
    /// calibrated the sentinel to what my probes happened to collect.
    ///
    /// Reading the literals cannot drift. A new pool, a new `case`, a new
    /// fallback sentence — all of them are string literals in these files, so
    /// all of them are here the moment they are written, with nobody having to
    /// remember to add a probe.
    ///
    /// It is deliberately over-broad: it also collects keyword literals like
    /// `"add a note"` that are matched against rather than spoken. That is the
    /// safe direction. It means a filler line may not collide with anything
    /// written in either file, which is stronger than what is needed and costs
    /// nothing — none of the ladder's lines is a keyword.
    ///
    /// ## Why there are two files now
    ///
    /// **1.7.5 moved the call's opener into `CallOpening`, and this guard would
    /// have gone on reading `WorkingReply` alone.** That is the precise defect
    /// this file's own header describes — a rule enforced against one surface
    /// while the identical one goes unexamined — and it would have been
    /// committed for the third time in the test written to catch it, by nobody
    /// touching this file at all. The call's catch-all now lives in
    /// `CallOpening.swift`, so a filler colliding with what the caller actually
    /// hears would have gone unwatched from the day #47 landed.
    private func everySentenceWrittenInTheOpenerPools() throws -> Set<String> {
        try [
            "Sources/SageVoiceCore/Brain/WorkingReply.swift",
            "Sources/SageVoiceCore/Call/CallOpening.swift"
        ].reduce(into: Set<String>()) { collected, path in
            let source = try String(
                contentsOf: URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent(path),
                encoding: .utf8
            )
            collected.formUnion(SwiftSourceScan(source).stringLiterals())
        }
    }

    /// **The one that matters: the ladder against what the call actually says.**
    func testNoFillerLineIsAlsoSomethingTheCallSaysAsAnOpener() throws {
        let ladder = Set(CallFiller.pools.flatMap { $0 })
        let shared = ladder.intersection(try everySentenceWrittenInTheOpenerPools()).sorted()

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

    /// Every pool is non-empty, and the extractor really extracted.
    ///
    /// **The sentinel is calibrated against the real pools, not against what the
    /// collector happened to return.** The previous version asserted "more than
    /// 10" while collecting 6 pools of 16 — a number chosen after seeing the
    /// result, which is how a sentinel becomes decoration. These are anchored to
    /// facts about the file instead: every catch-all option must be present, and
    /// so must a line from a per-tool pool that no probe list of mine ever
    /// reached.
    func testTheOpenerPoolWasReallyCollected() throws {
        XCTAssertFalse(
            CallFiller.pools.flatMap { $0 }.isEmpty,
            "the filler ladder has no lines, so the disjointness above is vacuously true"
        )
        XCTAssertFalse(
            WaitingPhrases.all.isEmpty,
            "WaitingPhrases has no lines, so the disjointness above is vacuously true"
        )

        let collected = try everySentenceWrittenInTheOpenerPools()

        for option in WorkingReply.catchAllOptions {
            XCTAssertTrue(
                collected.contains(option),
                "the extractor missed a catch-all option, so it is not reading WorkingReply properly: \(option)"
            )
        }
        // And the call's own pool, which is the one a caller actually hears and
        // the one this guard is nominally about. Reading only WorkingReply after
        // 1.7.5 would leave these six unwatched.
        for option in CallOpening.catchAllOptions {
            XCTAssertTrue(
                collected.contains(option),
                "the extractor is not reading CallOpening, so the call's real opener pool is unguarded: \(option)"
            )
        }
        // A per-tool line, reached through a `case` in a switch. Nothing about
        // this one is special except that it is the kind of line a hand-written
        // probe list forgets, which is the failure this replaces.
        XCTAssertTrue(
            collected.contains("Searching for that now."),
            "the extractor missed the per-tool pools, which is exactly what the previous version of this test did"
        )
        XCTAssertGreaterThan(
            collected.count, 40,
            "only \(collected.count) sentences were collected from WorkingReply; the extractor is not working"
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
#endif  // os(macOS)
