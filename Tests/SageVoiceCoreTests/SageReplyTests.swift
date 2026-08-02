import XCTest
@testable import SageVoiceCore

/// Reading what the node said when the node also said something else.
///
/// This is the seam every SAGE answer enters the product through, and it was
/// wrong in three places at once. The node writes for an AI agent, not for this
/// app: it prepends a banner on the first call of a session and appends a
/// `[SAGE] Reminder: …` every few calls after that. Trailing bytes fail
/// `JSONSerialization` outright, and every reader here treated that failure as
/// *empty* — so the appliance reported no tasks and no waiting messages while
/// the node was answering with three of one.
///
/// Measured against the real thing on 2 August: 1,709 characters, of which the
/// last 121 were the reminder.
final class SageReplyTests: XCTestCase {

    private let real = """
    {
      "message": "You have 3 assigned open tasks across 1 domains.",
      "tasks_by_domain": {
        "mynah-home": [
          {
            "assigned_to_you": true,
            "content": "[TASK] Message Biatch0 on Wednesday about TBCERT.",
            "memory_id": "abc123",
            "task_status": "planned"
          }
        ]
      },
      "total_open": 3
    }

    [SAGE] Reminder: call sage_turn with the current topic + observation. \
    You haven't logged a turn in 3 calls (0min) — your recent experience isn't being stored.
    """

    func testTheRemindersDoNotHideTheAnswer() throws {
        let root = try XCTUnwrap(SageReply.object(in: real))

        XCTAssertEqual(root["total_open"] as? Int, 3)
        XCTAssertNotNil(root["tasks_by_domain"])
    }

    func testAPlainAnswerStillReads() throws {
        let root = try XCTUnwrap(SageReply.object(in: #"{"total_open": 0}"#))
        XCTAssertEqual(root["total_open"] as? Int, 0)
    }

    func testTheBannerBeforeItIsCutAway() throws {
        let banner = """
        Welcome back. You are MYNAH on this node.

        ---

        {"total_open": 1}
        """
        XCTAssertEqual(SageReply.object(in: banner)?["total_open"] as? Int, 1)
    }

    func testABraceInTheTrailingProseCannotSwallowTheAnswer() throws {
        // "first { to last }" would run past the end of the object and produce
        // nothing at all. This is why the reading counts depth.
        let reply = #"{"total_open": 2}"# + "\n\n[SAGE] Reminder: use {topic} next time }"
        XCTAssertEqual(SageReply.object(in: reply)?["total_open"] as? Int, 2)
    }

    func testBracesInsideStringsAreNotStructure() throws {
        let reply = #"{"content": "a task about {braces} and \"quotes\"", "total_open": 1}"#
            + "\n\n[SAGE] Reminder: something."
        let root = try XCTUnwrap(SageReply.object(in: reply))

        XCTAssertEqual(root["total_open"] as? Int, 1)
        XCTAssertEqual(root["content"] as? String, #"a task about {braces} and "quotes""#)
    }

    func testNestingIsFollowedToTheRightBrace() throws {
        let reply = #"{"a": {"b": {"c": 1}}, "total_open": 9}"# + "\n\n[SAGE] Reminder."
        XCTAssertEqual(SageReply.object(in: reply)?["total_open"] as? Int, 9)
    }

    func testATruncatedAnswerIsNotGuessedAt() {
        XCTAssertNil(SageReply.object(in: #"{"total_open": 3, "tasks": ["#))
        XCTAssertNil(SageReply.object(in: "Error: get backlog: connection refused"))
        XCTAssertNil(SageReply.object(in: ""))
    }

    func testTheValueFormReadsTheSameThing() throws {
        let value = try XCTUnwrap(SageReply.value(in: real))
        XCTAssertEqual(value["total_open"]?.intValue, 3)
    }
}

// MARK: - The readers that were wrong

/// The two in this module that parsed the whole string, and the backlog reader
/// that found the bug.
final class SageReplyCallersTests: XCTestCase {

    private func withReminder(_ json: String) -> String {
        json + "\n\n[SAGE] Reminder: call sage_turn with the current topic + observation."
    }

    func testTheBacklogReadsThroughAReminder() {
        let reply = withReminder("""
        {"tasks_by_domain":{"mynah-home":[
          {"memory_id":"abc","content":"[TASK] Send the car in","task_status":"planned"}]},
         "total_open":1}
        """)

        let tasks = SageProactiveSource.tasks(inBacklog: reply)

        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.title, "Send the car in")
    }

    func testTheAgentInboxReadsThroughAReminder() {
        // The quiet one. An inbox that cannot be parsed reports as clear, so
        // this failed by telling the owner nobody had written to them.
        let reply = withReminder("""
        {"count":1,"items":[
          {"pipe_id":"p1","from":"Cerebrum","payload":"The quote came back.",
           "trust":"agent_untrusted","requires_result":false}]}
        """)

        let root = SageAgentMessaging.object(in: reply)

        XCTAssertNotNil(root)
        XCTAssertEqual((root?["items"] as? [[String: Any]])?.count, 1)
    }

    func testTheDictationVocabularyDoesNotSwallowTheReminderAsProse() {
        // Here the failure was quieter still: the fallback hands the whole
        // reply over as a language sample, so the node's own reminder text
        // became part of the owner's dictation vocabulary.
        let reply = withReminder(#"{"memories":[{"content":"Nasi lemak at Village Park"}]}"#)

        let texts = SageMemoryVocabularySource.texts(in: reply)

        XCTAssertFalse(
            texts.contains { $0.contains("sage_turn") },
            "the node's nudge to an AI agent is not a word the owner says"
        )
    }
}

// MARK: - Replies to work Mynah sent out

/// The channel that was being thrown away.
///
/// The owner had Mynah send a test note to another agent. It was delivered and
/// acknowledged within seconds. He then asked *"anything in the inbox?"* and
/// Mynah answered *"Inbox is clear."* — truthfully, because it had checked the
/// one place the answer could not be. `sage_inbox` says so itself: *"This does
/// not return results for pipes you sent; completed results arrive separately
/// in sage_turn.pipe_results, so a clean inbox is not evidence that no reply
/// exists."*
///
/// `SageRitual` is the only place this appliance calls `sage_turn`, and it
/// discarded the answer. So every reply any agent ever sent back was dropped.
final class PipeReplyTests: XCTestCase {

    private var said: URL!
    private var saidDirectory: URL!

    override func setUpWithError() throws {
        // A directory of its own, never the shared temp root: writes here go
        // through `OwnerOnlyFileSecurity`, which chmods the *containing*
        // directory to 0700 — and doing that to /var/folders/.../T would be a
        // test changing the machine it runs on.
        saidDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("said-\(UUID().uuidString)", isDirectory: true)
        said = saidDirectory.appendingPathComponent("said-replies.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: saidDirectory)
    }

    private func ritual() -> SageRitual {
        SageRitual(tools: SilentTools(), displayName: "Mynah", alreadySaidFile: said)
    }

    private func turnAnswer(_ results: String) -> String {
        """
        {"stored": true, "topic": "agents",
         "pipe_results": [\(results)]}

        [SAGE] Reminder: call sage_turn with the current topic + observation.
        """
    }

    func testAReplyBecomesSomethingToSay() async {
        let ritual = ritual()

        await ritual.noteResults(in: turnAnswer(
            #"{"pipe_id":"p1","from":"Claude","result":"Acknowledged — the pipeline works."}"#
        ))

        let replies = await ritual.drainReplies()
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(
            replies.first?.spokenDescription,
            "Claude replied: Acknowledged — the pipeline works."
        )
    }

    func testDrainingClearsThem() async {
        let ritual = ritual()
        await ritual.noteResults(in: turnAnswer(#"{"from":"Claude","result":"Done."}"#))

        _ = await ritual.drainReplies()

        let second = await ritual.drainReplies()
        XCTAssertTrue(second.isEmpty, "a reply said twice is a confusing thing to chase from a phone")
    }

    func testA64CharacterAgentIdIsNotReadOutInFull() async {
        let ritual = ritual()
        let id = String(repeating: "a1b2c3d4", count: 8)

        await ritual.noteResults(in: turnAnswer(#"{"from":"\#(id)","result":"Done."}"#))

        let replies = await ritual.drainReplies()
        XCTAssertEqual(replies.first?.from, "a1b2c3d4…")
    }

    func testTheFieldNamesAreReadLeniently() async {
        // The exact shape is not documented. A reply whose text is under
        // `payload` rather than `result` must not vanish — that would silently
        // reproduce the bug this fixes.
        let ritual = ritual()

        await ritual.noteResults(in: turnAnswer(
            #"{"agent":"Kestrel","payload":"Looked it up: 4,200."}"#
        ))

        let replies = await ritual.drainReplies()
        XCTAssertEqual(replies.first?.from, "Kestrel")
        XCTAssertTrue(replies.first?.text.contains("4,200") ?? false)
    }

    func testATurnWithNoRepliesSaysNothing() async {
        let ritual = ritual()

        await ritual.noteResults(in: #"{"stored": true, "pipe_results": []}"#)
        await ritual.noteResults(in: #"{"stored": true}"#)
        await ritual.noteResults(in: "Error: node unavailable")

        let replies = await ritual.drainReplies()
        XCTAssertTrue(replies.isEmpty)
    }
}

/// A node that answers nothing, for the parsing tests above.
private struct SilentTools: ToolProviding {
    func listTools() async throws -> [MCPTool] { [] }
    func call(name: String, arguments: [String: JSONValue]) async throws -> String { "{}" }
}

// MARK: - Saying it once

/// The bug that reached the owner's phone.
///
/// `sage_turn` keeps returning the same `pipe_results` on later turns, and
/// draining them from the ritual clears the ritual rather than the node. So
/// every following turn announced the same reply again, and his Note to Self
/// filled with "one of your agents replied:" repeating an acknowledgement and a
/// long status update over and over.
final class RepeatedReplyTests: XCTestCase {

    private var said: URL!
    private var saidDirectory: URL!

    override func setUpWithError() throws {
        // A directory of its own, never the shared temp root: writes here go
        // through `OwnerOnlyFileSecurity`, which chmods the *containing*
        // directory to 0700 — and doing that to /var/folders/.../T would be a
        // test changing the machine it runs on.
        saidDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("said-\(UUID().uuidString)", isDirectory: true)
        said = saidDirectory.appendingPathComponent("said-replies.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: saidDirectory)
    }

    private func ritual() -> SageRitual {
        SageRitual(tools: SilentTools(), displayName: "Mynah", alreadySaidFile: said)
    }

    private let turnAnswer = """
    {"stored": true, "pipe_results": [
      {"pipe_id":"p-1","from":"Claude","result":"Acknowledged — the pipeline works."}]}
    """

    func testTheSameResultIsNotSaidTwice() async {
        let ritual = ritual()

        await ritual.noteResults(in: turnAnswer)
        let first = await ritual.drainReplies()
        XCTAssertEqual(first.count, 1)

        // The node offers it again on the next turn, as it does.
        await ritual.noteResults(in: turnAnswer)
        let second = await ritual.drainReplies()
        XCTAssertTrue(
            second.isEmpty,
            "the node goes on offering a result after it has been handed over; this ledger "
                + "is the only thing that stops a repeat"
        )
    }

    func testARestartDoesNotReplayEverything() async {
        let first = ritual()
        await first.noteResults(in: turnAnswer)
        _ = await first.drainReplies()

        // A daemon restart — a changed setting, an update, a launchd reconcile.
        // In memory alone this would say everything again.
        let afterRestart = ritual()
        await afterRestart.noteResults(in: turnAnswer)

        let replayed = await afterRestart.drainReplies()
        XCTAssertTrue(replayed.isEmpty)
    }

    func testADifferentReplyStillArrives() async {
        let ritual = ritual()
        await ritual.noteResults(in: turnAnswer)
        _ = await ritual.drainReplies()

        await ritual.noteResults(in: """
        {"pipe_results": [{"pipe_id":"p-2","from":"Codex","result":"Wave 3 is done."}]}
        """)

        let arrived = await ritual.drainReplies()
        XCTAssertEqual(arrived.first?.from, "Codex")
    }

    func testWithNoPipeIdItFallsBackToWhatWasSaid() async {
        // Some results may carry no id. Two replies identical in sender and
        // text are indistinguishable to a reader anyway, so treating them as
        // one costs nothing and saying them twice costs the owner's patience.
        let ritual = ritual()
        let anonymous = #"{"pipe_results": [{"from":"Codex","result":"Wave 3 is done."}]}"#

        await ritual.noteResults(in: anonymous)
        let first = await ritual.drainReplies()
        XCTAssertEqual(first.count, 1)

        await ritual.noteResults(in: anonymous)
        let again = await ritual.drainReplies()
        XCTAssertTrue(again.isEmpty)
    }

    func testTheLedgerDoesNotGrowForever() {
        var ledger = SageRitual.AlreadySaid()
        for index in 0..<(SageRitual.AlreadySaid.mostKept + 50) {
            ledger.remember("p-\(index)")
        }

        XCTAssertEqual(ledger.ids.count, SageRitual.AlreadySaid.mostKept)
        XCTAssertFalse(ledger.has("p-0"), "the oldest go first")
        XCTAssertTrue(ledger.has("p-\(SageRitual.AlreadySaid.mostKept + 49)"))
    }
}
