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
