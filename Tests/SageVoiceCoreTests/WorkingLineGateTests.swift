import XCTest
@testable import SageVoiceCore

/// The rule that decides whether the appliance says it is working.
///
/// Every case here is a message the owner either does or does not get on their
/// phone, seconds apart, and the failure mode has no stack trace: it is two
/// notifications where there should have been one.
final class WorkingLineGateTests: XCTestCase {

    private var gate = WorkingLineGate()

    override func setUp() {
        super.setUp()
        gate = WorkingLineGate()
        gate.beginTurn()
    }

    // MARK: A fast turn

    func testAFastTurnSaysNothingButTheAnswer() {
        XCTAssertEqual(gate.offer("On it.", previous: nil), .hold)

        // The answer arrives inside the quiet period, which against an API
        // brain is the ordinary case.
        gate.answered()

        // The timer still fires — nothing cancels it in this type — and must
        // produce nothing.
        XCTAssertNil(gate.quietPeriodEnded(), "the owner has already been answered")
    }

    func testALineOfferedAfterTheAnswerIsNotAnEcho() {
        gate.answered()

        XCTAssertEqual(
            gate.offer("Looking that up online.", previous: nil), .drop,
            "a tool loop still talking after the reply went out is not news"
        )
        XCTAssertNil(gate.quietPeriodEnded())
    }

    // MARK: A slow turn

    func testASlowTurnSaysTheHeldLineOnce() {
        XCTAssertEqual(gate.offer("On it.", previous: nil), .hold)

        XCTAssertEqual(gate.quietPeriodEnded(), "On it.")
        XCTAssertNil(gate.quietPeriodEnded(), "and not a second time")
    }

    func testOnceItIsTalkingEverythingElseGoesStraightOut() {
        _ = gate.quietPeriodEnded()

        XCTAssertEqual(
            gate.offer("Looking that up online.", previous: nil), .say,
            "past the quiet period the appliance is visibly working, so progress "
                + "updates are what the owner is waiting for"
        )
    }

    // MARK: Which line, when two are waiting

    func testTheNewerLineReplacesTheOneStillWaiting() {
        XCTAssertEqual(gate.offer("On it.", isArrivalOpener: false, previous: nil), .hold)
        XCTAssertEqual(gate.offer("Having a look online.", previous: nil), .hold)

        XCTAssertEqual(
            gate.quietPeriodEnded(), "Having a look online.",
            "a tool decision is better news than an acknowledgement, and there is "
                + "no reason to say both"
        )
    }

    func testTheSameNewsTwiceIsRefusedWhetherTheFirstWasSaidOrIsWaiting() {
        XCTAssertEqual(gate.offer("Looking that up online.", previous: nil), .hold)
        XCTAssertEqual(
            gate.offer("Looking online for that.", previous: nil), .drop,
            "held lines count as said for the purpose of not stuttering"
        )

        XCTAssertEqual(gate.quietPeriodEnded(), "Looking that up online.")
        XCTAssertEqual(
            gate.offer("Looking online for the rest of it.", previous: "Looking that up online."),
            .drop
        )
    }

    // MARK: What the tool-decision line is allowed to do

    func testAnOpenerNobodyHeardDoesNotSilenceTheToolLine() {
        // The bug this exists to stop: the opener is decided, held, and never
        // said — and the tool-decision line is suppressed on the strength of an
        // opener that never left the Mac, leaving a slow turn completely quiet.
        XCTAssertEqual(gate.offer("Let me check.", isArrivalOpener: true, previous: nil), .hold)

        XCTAssertFalse(gate.saidArrivalOpener, "it has not been said, only chosen")
    }

    func testAnOpenerThatWasSaidCountsAsSaid() {
        XCTAssertEqual(gate.offer("Let me check.", isArrivalOpener: true, previous: nil), .hold)
        XCTAssertEqual(gate.quietPeriodEnded(), "Let me check.")

        XCTAssertTrue(gate.saidArrivalOpener)
    }

    func testTheNextTurnStartsQuietAgain() {
        _ = gate.offer("Let me check.", isArrivalOpener: true, previous: nil)
        _ = gate.quietPeriodEnded()
        gate.answered()

        gate.beginTurn()

        XCTAssertFalse(gate.saidArrivalOpener)
        XCTAssertEqual(
            gate.offer("On it.", previous: nil), .hold,
            "every turn gets its own quiet period, or the second message of a "
                + "conversation would be answered by filler again"
        )
    }
}

// MARK: - One line per turn

/// **The bug the owner photographed.** One question produced two notifications:
///
///     MYNAH >> On it — give me a couple of minutes and I'll come back
///              when it's all done.
///     MYNAH >> Searching for that now.
///
/// Everything here deduplicates by *wording*, and correctly — `saysTheSameThing`
/// catches a stutter, two phrasings of one piece of news. These two share no
/// significant words at all, so it passed them both, and nothing else counted.
extension WorkingLineGateTests {

    /// The exact pair, in the exact order, with the quiet period ending in
    /// between — which is what let both out.
    func testTheOpenerAndTheToolLineDoNotBothGoOut() {
        XCTAssertEqual(
            gate.offer("On it — give me a couple of minutes and I'll come back when it's all done.",
                       previous: nil),
            .hold
        )
        XCTAssertEqual(
            gate.quietPeriodEnded(),
            "On it — give me a couple of minutes and I'll come back when it's all done."
        )
        XCTAssertEqual(
            gate.offer("Searching for that now.", previous: nil), .drop,
            "second notification for one question — this is the reported bug"
        )
    }

    /// Stated as the rule rather than as that one pair, so it holds for any two
    /// lines however differently they are worded.
    func testNothingIsSaidTwiceInOneTurnHoweverDifferentlyItIsPhrased() {
        XCTAssertEqual(gate.offer("On it.", previous: nil), .hold)
        XCTAssertNotNil(gate.quietPeriodEnded())
        XCTAssertTrue(gate.hasSaidSomething)

        for line in ["Searching for that now.", "Checking your calendar.", "Nearly there."] {
            XCTAssertEqual(gate.offer(line, previous: nil), .drop, "\(line) was a second line")
        }
    }

    /// A line said *directly* — no quiet period involved — closes the turn just
    /// the same. The quiet period is one route to speaking, not the only one.
    func testALineSaidOutrightAlsoClosesTheTurn() {
        _ = gate.quietPeriodEnded()
        XCTAssertEqual(gate.offer("Looking that up online.", previous: nil), .say)
        XCTAssertTrue(gate.hasSaidSomething)
        XCTAssertEqual(gate.offer("Still going.", previous: nil), .drop)
    }

    /// The next turn gets its own line. This bounds one turn, it does not mute
    /// the appliance for the rest of the conversation.
    func testTheNextTurnMaySpeakAgain() {
        _ = gate.quietPeriodEnded()
        XCTAssertEqual(gate.offer("Looking that up online.", previous: nil), .say)
        XCTAssertEqual(gate.offer("Still going.", previous: nil), .drop)

        gate.beginTurn()
        XCTAssertFalse(gate.hasSaidSomething)
        XCTAssertEqual(gate.offer("On it.", previous: nil), .hold)
    }

    /// A turn that only ever *held* a line has said nothing, so a replacement is
    /// still allowed — the newest news wins while the appliance is still quiet.
    func testHoldingALineIsNotSayingIt() {
        XCTAssertEqual(gate.offer("On it.", previous: nil), .hold)
        XCTAssertFalse(gate.hasSaidSomething)
        XCTAssertEqual(
            gate.offer("Searching for that now.", previous: nil), .hold,
            "nothing has left the Mac yet, so the better line may still replace it"
        )
        XCTAssertEqual(gate.quietPeriodEnded(), "Searching for that now.")
    }

    // MARK: An unprompted line is not an answer

    /// **The second bug in the same six-minute window as the history race.**
    ///
    /// `reply` took `isWorkingLine: Bool`, and everything that was not a working
    /// line called `workingLines.answered()` — which marks the gate answered and
    /// drops whatever the running turn is holding. Correct for an answer. Wrong
    /// for an announcement, which the proactive watch sends on a sixty-second
    /// tick straight through the middle of a turn that may take six minutes.
    ///
    /// So a task coming off the list silenced the "let me look that up" for a
    /// question it had nothing to do with, and the owner waited in silence for
    /// an appliance that had already decided it had spoken.
    ///
    /// Two booleans cannot express three states. `VoiceBridgeDaemon.Utterance`
    /// can.
    func testAnAnsweredGateDropsWhatItWasHolding() {
        var gate = WorkingLineGate()
        gate.beginTurn()
        XCTAssertEqual(gate.offer("On it.", isArrivalOpener: true, previous: nil), .hold)

        gate.answered()

        XCTAssertNil(
            gate.quietPeriodEnded(),
            "a gate told the owner has been answered must not then say the held line"
        )
    }

    /// And the states are distinct, so the daemon has somewhere to put the third
    /// case rather than folding it into "not a working line".
    /// **Asserted on something that can be wrong, because the old version could
    /// not be.** It compared `String(describing:)` of three different enum
    /// cases, which the compiler guarantees to differ — so it was green whatever
    /// the daemon did with them, including deleting the third case's meaning
    /// entirely.
    ///
    /// The meaning is at the call sites rather than inside `reply`, which
    /// branches on `.answer` and nothing else. What makes `.unprompted` a
    /// separate thing from `.workingLine` is that **an unprompted line is never
    /// spoken aloud**: a proactive announcement or a call transcript arriving
    /// out of the blue must land in the thread, not out of the speaker over
    /// whatever the owner is doing. That is a property a source edit can break,
    /// so that is what this checks.
    func testAnUnpromptedLineIsNeverSpokenAloud() throws {
        let daemon = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/SageVoiceCore/VoiceBridgeDaemon.swift"),
            encoding: .utf8
        )
        let scan = SwiftSourceScan(daemon)

        let sites = scan.indices(of: "as: .unprompted").map { scan.statement(at: $0) }
        XCTAssertFalse(
            sites.isEmpty,
            "no unprompted reply was found in the daemon at all, so this guard checks nothing"
        )

        let speaking = sites.filter { !$0.contains("allowSpeaking: false") }
        XCTAssertEqual(
            speaking, [],
            """
            an unprompted line is allowed to speak aloud, so a proactive \
            announcement or a call transcript can come out of the speaker over \
            whatever the owner is doing: \(speaking)
            """
        )
    }
}
