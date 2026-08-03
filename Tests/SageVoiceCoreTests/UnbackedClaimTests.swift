import XCTest
@testable import SageVoiceCore

/// **"said it did it, but actually didn't … quite dangerous".**
///
/// Observed 3 August 2026. Asked to add a call to the task list, Mynah replied
/// *"Added — call with Daniel & Tenzai tomorrow (Tuesday 4 August) at 1pm on
/// Google Meet. No clash with Cayenne at 10am or Credence at 11am."* The turn's
/// receipt was `Looked through what it remembers`: one recall, no write. Nothing
/// was on the list.
///
/// The owner is right that this is the dangerous class. An unfulfilled promise
/// ends a turn on "Let me check:" and is obvious within a minute. This one is
/// confident, complete, and wrong, and the way you find out is by missing the
/// appointment.
///
/// Note what actually fixed it at the time: he asked *"did you add it ? i do't
/// see it"* and the model went and did it. The question worked. The loop now
/// asks it, which is the whole design — it does not rewrite the model's words
/// while there is still a chance of the model doing the thing.
final class UnbackedClaimTests: XCTestCase {

    // MARK: What counts as a claim

    /// The exact sentence from the bug.
    func testTheReplyThatCausedThis() {
        XCTAssertTrue(ToolLoop.readsAsCompletedAction(
            "Added — call with Daniel & Tenzai tomorrow (Tuesday 4 August) at 1pm on Google Meet. "
                + "No clash with Cayenne at 10am or Credence at 11am."
        ))
    }

    func testTheOrdinaryWaysOfSayingItIsDone() {
        for reply in [
            "Done. Cayenne send to Prestige is now at 10am tomorrow.",
            "Saved that for you.",
            "I've added it to your list.",
            "I have put that on the list for Tuesday.",
            "Noted — I'll remind you.",
            "It's now on the list.",
            "Removed it.",
            "Sent — agent/sage-voice-bridge will see it on its next check.",
            "Right, that's sorted. Updated the entry to 2pm."
        ] {
            XCTAssertTrue(ToolLoop.readsAsCompletedAction(reply), reply)
        }
    }

    // MARK: What must not count

    /// **The expensive false positive.** A report about a *read* is not a claim
    /// of a change, and treating it as one would retry every successful search
    /// and lookup in the product.
    func testFindingsAreNotClaims() {
        for reply in [
            "I found three Eurorack dealers in Malaysia.",
            "Your next appointment is the chiropractor on Wednesday at 11.",
            "Nothing new in your inbox.",
            "There are four tasks on the list, the soonest is tomorrow at 10.",
            "The hotel address is 188 Prachathipat Road, Betong.",
            "I couldn't find anything about that."
        ] {
            XCTAssertFalse(ToolLoop.readsAsCompletedAction(reply), reply)
        }
    }

    /// Future and conditional forms are promises or offers, not claims. The
    /// promise machinery already covers the ones that need covering.
    func testIntentionsAreNotClaims() {
        for reply in [
            "I'll add that now.",
            "Shall I add it to the list?",
            "Send me the link and I'll attach it to the entry.",
            "Let me know once it's saved.",
            "I can add it if you want."
        ] {
            XCTAssertFalse(ToolLoop.readsAsCompletedAction(reply), reply)
        }
    }

    /// A word that only appears mid-sentence is usually part of a description
    /// rather than an assertion about this turn.
    func testAMentionIsNotAClaim() {
        XCTAssertFalse(ToolLoop.readsAsCompletedAction(
            "The task you added yesterday is still open."
        ))
        XCTAssertFalse(ToolLoop.readsAsCompletedAction(
            "That booking was sent to you by the hotel."
        ))
    }

    // MARK: Whether anything actually happened

    private func trace(tools: [(String, Bool)]) -> ToolLoopTrace {
        var trace = ToolLoopTrace(model: "m", toolsOffered: 5)
        trace.toolCalls = tools.map { name, failed in
            ToolCallRecord(
                iteration: 1,
                name: name,
                arguments: [:],
                result: failed ? "Error: refused" : "ok",
                failed: failed,
                durationSeconds: 0.1
            )
        }
        return trace
    }

    /// The bug's turn: a recall and nothing else.
    func testAReadOnlyTurnDidNothing() {
        XCTAssertFalse(trace(tools: [("sage_recall", false)]).didSomething)
        XCTAssertFalse(trace(tools: [("sage_backlog", false), ("web_search", false)]).didSomething)
        XCTAssertFalse(trace(tools: []).didSomething)
    }

    func testAWriteCounts() {
        XCTAssertTrue(trace(tools: [("sage_task", false)]).didSomething)
        XCTAssertTrue(trace(tools: [("sage_recall", false), ("write_note", false)]).didSomething)
    }

    /// **A failed write is not a write**, and this is the case the comment on
    /// `sendingTools` was written for: a model that has just read "Error: …"
    /// still telling the owner it sent the message. Counting a failure as having
    /// acted would let exactly that through.
    func testAFailedWriteIsNotAnAction() {
        XCTAssertFalse(trace(tools: [("sage_task", true)]).didSomething)
        XCTAssertFalse(trace(tools: [("sage_pipe", true)]).didSomething)
        XCTAssertTrue(
            trace(tools: [("sage_task", true), ("sage_task", false)]).didSomething,
            "a retry that worked is still a write"
        )
    }

    /// **An unknown tool counts as having acted**, which is the safe direction.
    ///
    /// The obvious design — list the writers, assume everything else reads —
    /// fails dangerously: a tool nobody remembered to add makes a real write
    /// invisible, so an honest "Saved that" gets contradicted and the owner is
    /// told nothing was written when it was. Crying wolf about their own data is
    /// its own kind of untrustworthy.
    func testAToolNobodyListedIsAssumedToHaveDoneSomething() {
        XCTAssertTrue(trace(tools: [("some_new_tool", false)]).didSomething)
        XCTAssertFalse(
            trace(tools: [("some_new_tool", true)]).didSomething,
            "a failure is still not an action, whatever the tool was called"
        )
    }

    /// Every read in the catalogue, so a recall-only turn is recognised as
    /// having changed nothing. This is the list the guard actually depends on.
    func testTheKnownReadsAreAllRecognised() {
        for tool in ["sage_recall", "sage_backlog", "sage_inbox", "sage_list", "sage_timeline",
                     "sage_directory", "web_search", "list_notes", "read_note"] {
            XCTAssertFalse(trace(tools: [(tool, false)]).didSomething, tool)
        }
    }

    // MARK: The correction

    /// It tells the model what is wrong and what to do about it, in that order.
    func testTheCorrectionNamesTheProblemAndTheWayOut() {
        let correction = ToolLoop.unbackedClaimCorrection.lowercased()

        XCTAssertTrue(correction.contains("did not call"))
        XCTAssertTrue(correction.contains("nothing was saved"))
        XCTAssertTrue(correction.contains("call the right tool") || correction.contains("tell the owner"))
    }

    /// **Last resort, and it leads.** A warning appended after four sentences of
    /// confident prose is one the owner reads last, if at all. The rest of the
    /// reply is kept because it is usually true — the turn that caused this also
    /// correctly worked out there was no clash at 1pm.
    func testTheFlaggedReplyLeadsWithTheCorrectionAndKeepsTheRest() {
        let original = "Added — call with Daniel at 1pm. No clash with Cayenne at 10am."
        let flagged = ToolLoop.flaggedAsUnconfirmed(original)

        XCTAssertTrue(flagged.hasPrefix("I need to correct myself"), flagged)
        XCTAssertTrue(flagged.contains("have NOT saved"), flagged)
        XCTAssertTrue(flagged.contains(original), "the true half of the answer was thrown away")
        XCTAssertLessThan(
            flagged.range(of: "NOT saved")!.lowerBound,
            flagged.range(of: original)!.lowerBound,
            "the correction must come first"
        )
    }

    /// **A caught false claim must never become silence.**
    ///
    /// The first version of the guard sent the model back to try again, and a
    /// retry that came back blank left the turn with nothing — so asking Mynah
    /// to add a task produced "Mynah didn't have an answer for that."
    ///
    /// That is worse than the bug it replaced in one specific way: the owner now
    /// has no idea whether anything was written. The truth is still known at
    /// that point — a claim was made and nothing backed it — so it gets said.
    func testARetryThatComesBackEmptyStillTellsTheOwnerTheTruth() {
        let claimed = "Added — review modular malaya x music bliss agreement by Friday."
        let flagged = ToolLoop.flaggedAsUnconfirmed(claimed)

        XCTAssertFalse(flagged.isEmpty)
        XCTAssertTrue(flagged.contains("have NOT saved"))
        XCTAssertTrue(flagged.contains(claimed), "the owner should still see what it thought it did")
    }

    /// The log can tell the two failure modes apart, because they call for
    /// opposite fixes.
    func testTheLogDistinguishesItFromAnUnfulfilledPromise() {
        var trace = ToolLoopTrace(model: "m", toolsOffered: 5)
        trace.unbackedClaims = 2

        XCTAssertTrue(trace.summary.contains("[UNBACKED 2]"), trace.summary)
        XCTAssertFalse(trace.summary.contains("[PROMISED"), trace.summary)
    }
}
