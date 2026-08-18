import XCTest
@testable import SageVoiceCore

/// Reading what the node said when the node also said something else.
///
/// This is the seam every SAGE answer enters the product through, and it was
/// wrong in three places at once. The node writes for an AI agent, not for this
/// app: it prepends a banner on the first call of a session and — at the time —
/// appended a `[SAGE] Reminder: …` every few calls after that. Trailing bytes
/// fail `JSONSerialization` outright, and every reader here treated that failure
/// as *empty* — so the appliance reported no tasks and no waiting messages while
/// the node was answering with three of one.
///
/// Measured against the real thing on 2 August: 1,709 characters, of which the
/// last 121 were the reminder.
///
/// ## Half of that is no longer true of the node, and the parser stays anyway
///
/// **The trailing nudge has not existed since 11.16.1.** 11.17.x states the
/// position in the source: *"Session state is advisory only. MCP operations must
/// never be blocked or padded"* (`internal/mcp/server.go:412-413`). So the
/// fixtures below carry a suffix the appliance will not meet again.
///
/// The **leading** banner is still real — server.go:417-422 prepends it with a
/// `\n\n---\n\n` separator on the first tool call of a session — which is what
/// keeps this parser load-bearing rather than legacy. It scans braces rather
/// than trusting the whole reply to be JSON, and that is required for the
/// prefix whether or not anything follows.
///
/// The trailing cases are kept deliberately rather than deleted. A parser that
/// tolerates bytes on both sides costs nothing, an installed node may be older
/// than the appliance (`SageNodeChoice` runs whichever SAGE is on the Mac), and
/// deleting a passing test to make a comment true is how a defence disappears
/// while everyone believes it is there.
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

    func testTheBacklogReadsThroughAReminder() throws {
        let reply = withReminder("""
        {"tasks_by_domain":{"mynah-home":[
          {"memory_id":"abc","content":"[TASK] Send the car in","task_status":"planned"}]},
         "total_open":1}
        """)

        let tasks = try XCTUnwrap(SageProactiveSource.tasks(inBacklog: reply))

        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.title, "Send the car in")
    }

    func testTheAgentInboxReadsThroughAReminder() {
        // The quiet one. An inbox that cannot be parsed reports as clear, so
        // this failed by telling the owner nobody had written to them.
        // An **inbox** item, so the keys are the inbox's: `from` and
        // `requires_reply`. Not the outbox shape `PipeReplyTests` uses — the two
        // are different folders of one tool and conflating them is how `payload`
        // nearly got read as somebody else's answer.
        let reply = withReminder("""
        {"count":1,"items":[
          {"message_id":"p1","from":"Cerebrum","payload":"The quote came back.",
           "trust":"agent_untrusted","requires_reply":false}]}
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
/// one place the answer could not be. `sage_inbox` says so itself: a clean inbox
/// is not evidence that no reply exists, because a reply to work *you* sent
/// never lands there.
///
/// `SageRitual` was the only place this appliance called `sage_turn`, and it
/// discarded the answer. So every reply any agent ever sent back was dropped.
///
/// **Then the fix rotted.** `sage_turn.pipe_results`, which the inbox's own
/// documentation named as the channel, was renamed at 11.17.4 and removed at
/// 11.17.9 — and .9 made `sage_turn` payload-free besides. The answer now comes
/// from `sage_message_history(folder: "outbox")`, a passive read of this
/// appliance's own sends. See `SageRitual.noteResults`, and
/// `Tests/Fixtures/sage_message_history-outbox-11.17.10.json` for the captured
/// shape.
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

    /// Already seeded, which is every ritual after its first turn — the state
    /// these tests are about. The seeding turn has its own tests below.
    private func ritual() -> SageRitual {
        let ritual = SageRitual(tools: SilentTools(), displayName: "Mynah", alreadySaidFile: said)
        return ritual
    }

    /// Seeding needs a poll that actually carries an answered send — an empty
    /// outbox is not a first look, it is a quiet one.
    private func seeded() async -> SageRitual {
        let ritual = ritual()
        await ritual.noteResults(in: outbox(#"{"counterparty":"x","completed_at":"\#(then)","result":"old"}"#))
        _ = await ritual.drainReplies()
        return ritual
    }

    /// A `sage_message_history(folder: "outbox")` answer.
    ///
    /// **Shaped after the capture, not after the old fixture.** The previous
    /// version of this helper wrapped items in `pipe_results` and appended a
    /// trailing `[SAGE] Reminder:` line, and both were wrong about the node —
    /// `pipe_results` was removed at 11.17.9 and the trailing nudge has not
    /// existed since 11.16.1. See `Tests/Fixtures/sage_message_history-outbox-11.17.10.json`,
    /// which is a real reply from the owner's node.
    ///
    /// The *leading* auto-inception banner is still real, so it is here: the
    /// node prepends it on the first tool call of a session with a `---`
    /// separator, which is what keeps `SageReply`'s brace-scanning parser
    /// load-bearing.
    private func outbox(_ items: String) -> String {
        """
        Welcome back. Your institutional memory is online.

        ---

        {"folder": "outbox", "count": 1, "items": [\(items)]}
        """
    }

    /// Any completion timestamp. The value is never parsed — presence is what
    /// separates an answered send from one still in flight.
    private let then = "2026-08-05T09:15:00Z"

    func testAReplyBecomesSomethingToSay() async {
        let ritual = await seeded()

        await ritual.noteResults(in: outbox(
            #"{"message_id":"msg-p1","counterparty":"Claude","completed_at":"\#(then)","#
                + #""result":"Acknowledged — the pipeline works."}"#
        ))

        let replies = await ritual.drainReplies()
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(
            replies.first?.spokenDescription,
            "Claude replied: Acknowledged — the pipeline works."
        )
    }

    /// **An outbox is mostly things still in flight, and none of it is news.**
    ///
    /// This is the failure the transport change would otherwise have
    /// introduced. `pipe_results` only ever contained answers, so everything in
    /// it was worth saying; the outbox contains every message this appliance has
    /// sent, and announcing those would have Mynah telling the owner about its
    /// own outgoing messages the moment they left. Both items in the captured
    /// live reply are unanswered.
    func testAnUnansweredSendIsNotNews() async {
        let ritual = await seeded()

        await ritual.noteResults(in: outbox(
            #"{"message_id":"msg-1","counterparty":"Claude","completed_at":"","status":"pending","#
                + #""payload":"Please look into the ferry timetable."}"#
        ))

        let replies = await ritual.drainReplies()
        XCTAssertTrue(
            replies.isEmpty,
            "the appliance announced a message it had just sent as though somebody had replied"
        )
    }

    /// **`payload` in an outbox is what *we* said, and reading it as an answer
    /// is worse than silence because it is convincing.**
    ///
    /// The old candidate list included `payload`, and it was correct there:
    /// `pipe_results` entries *were* answers, so their payload was the answer.
    /// Carrying that list over unexamined would have had Mynah read the owner
    /// his own outgoing message back in another agent's name.
    func testOurOwnOutgoingMessageIsNeverReadAsAReply() async {
        let ritual = await seeded()

        await ritual.noteResults(in: outbox(
            #"{"message_id":"msg-2","counterparty":"Kestrel","completed_at":"\#(then)","#
                + #""payload":"Mynah here — could you check the ferry times?"}"#
        ))

        let replies = await ritual.drainReplies()
        XCTAssertTrue(
            replies.isEmpty,
            "Mynah read its own sent message back to the owner as Kestrel's reply: "
                + (replies.first?.spokenDescription ?? "")
        )
    }

    func testDrainingClearsThem() async {
        let ritual = await seeded()
        await ritual.noteResults(in: outbox(
            #"{"counterparty":"Claude","completed_at":"\#(then)","result":"Done."}"#
        ))

        _ = await ritual.drainReplies()

        let second = await ritual.drainReplies()
        XCTAssertTrue(second.isEmpty, "a reply said twice is a confusing thing to chase from a phone")
    }

    func testA64CharacterAgentIdIsNotReadOutInFull() async {
        let ritual = await seeded()
        let id = String(repeating: "a1b2c3d4", count: 8)

        await ritual.noteResults(in: outbox(
            #"{"counterparty":"\#(id)","completed_at":"\#(then)","result":"Done."}"#
        ))

        let replies = await ritual.drainReplies()
        XCTAssertEqual(replies.first?.from, "a1b2c3d4…")
    }

    /// **The reply key could not be read off the live node**, because neither
    /// retained item in the capture has been answered. So the candidates are
    /// tried in order rather than pinned to one guess — which is exactly the
    /// mistake that made this whole family: a key was guessed, was right for two
    /// releases, and was then silently wrong for two more.
    func testTheReplyKeyIsReadLeniently() async {
        for key in ["result", "reply", "response", "result_payload"] {
            let ritual = await seeded()
            // A distinct id per key. Without one the dedup ledger — which is
            // shared across this loop's iterations because they share a file —
            // would swallow every reply after the first and the loop would
            // report the last three keys as broken.
            await ritual.noteResults(in: outbox(
                #"{"message_id":"msg-\#(key)","counterparty":"Kestrel","#
                    + #""completed_at":"\#(then)","\#(key)":"Looked it up: 4,200."}"#
            ))

            let replies = await ritual.drainReplies()
            XCTAssertEqual(replies.first?.from, "Kestrel", "a reply under \"\(key)\" vanished")
            XCTAssertTrue(replies.first?.text.contains("4,200") ?? false, "under \"\(key)\"")
        }
    }

    /// An answered send whose reply is under a key nobody anticipated is skipped
    /// rather than announced hollow. An owner told "Kestrel replied" with
    /// nothing attached learns less than one told nothing.
    func testAnAnsweredSendWithNoRecognisableReplyIsNotAnnounced() async {
        let ritual = await seeded()

        await ritual.noteResults(in: outbox(
            #"{"counterparty":"Kestrel","completed_at":"\#(then)","some_future_key":"4,200."}"#
        ))

        let replies = await ritual.drainReplies()
        XCTAssertTrue(replies.isEmpty)
    }

    func testAPollWithNoRepliesSaysNothing() async {
        let ritual = await seeded()

        await ritual.noteResults(in: #"{"folder":"outbox","count":0,"items": []}"#)
        await ritual.noteResults(in: #"{"folder":"outbox"}"#)
        await ritual.noteResults(in: "Error: node unavailable")

        let replies = await ritual.drainReplies()
        XCTAssertTrue(replies.isEmpty)
    }

    /// **Against the bytes the node really sent.**
    ///
    /// Read from the capture rather than from a literal here, so a change in the
    /// outbox shape shows up as a failing test instead of as a fixture that
    /// still agrees with a codebase both of which have drifted.
    ///
    /// **This test used to assert silence, and the reason it did was the bug.**
    /// Its wording was "both items are unanswered, so the correct behaviour is
    /// silence" — true of the rule as written, and wrong about the world. One of
    /// the two captured items is `msg-96ad952b`, which **expired undelivered** on
    /// this owner's node on 4 August 2026. Mynah said it would send that message,
    /// it never arrived, and the old rule filed that under "nothing to report"
    /// because the only question it asked was whether a reply had come back.
    ///
    /// So the fixture was right the whole time and the assertion was wrong. Worth
    /// keeping as a note: a captured fixture only protects the shape, never the
    /// judgement made about it.
    func testTheCapturedOutboxAnnouncesTheSendThatDied() async throws {
        let captured = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Fixtures/sage_message_history-outbox-11.17.10.json"),
            encoding: .utf8
        )
        let ritual = await seeded()

        await ritual.noteResults(in: captured)

        let replies = await ritual.drainReplies()
        XCTAssertEqual(
            replies.count, 1,
            "the captured outbox holds one pending send and one that expired undelivered; "
                + "exactly the dead one is news, and the pending one is not"
        )
        guard case .neverArrived = replies.first?.kind else {
            return XCTFail(
                "the expired send was reported as \(String(describing: replies.first?.kind)); "
                    + "a message nobody received must not be read out as though somebody answered"
            )
        }
    }
    // MARK: - Sends that will never arrive

    /// **Mynah said it would send something, it never got there, and nobody was
    /// told.** Same family as #45: a promise made and silently broken.
    ///
    /// Everything not `completed` fell through the answered filter, which is
    /// right for the many things still in flight and wrong for the few that have
    /// stopped. `msg-96ad952b` expired undelivered on the owner's node on 4
    /// August 2026 — it is in the captured fixture, and before this it was read,
    /// discarded and never mentioned.
    func testAnExpiredSendIsReportedAsNeverArriving() async {
        let ritual = await seeded()

        await ritual.noteResults(in: outbox(
            #"{"message_id":"msg-96ad952b","counterparty":"Kestrel","completed_at":"","#
                + #""status":"expired"}"#
        ))

        let replies = await ritual.drainReplies()
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(
            replies.first?.spokenDescription,
            "Your message to Kestrel never got there — it expired before it could be delivered. "
                + "Nobody has seen it."
        )
        // Not phrased as a reply. Reading a failure out with the sentence built
        // for an answer would tell the owner an agent said something when the
        // truth is that nobody ever received the question.
        XCTAssertEqual(replies.first?.kind, .neverArrived(why: "it expired before it could be delivered"))
    }

    /// **The direction this must not get wrong.** An unrecognised status is a
    /// message still on its way, not a lost one: announcing it as lost makes the
    /// owner re-send, and the recipient gets it twice. The outbox carries
    /// in-flight words this code has never enumerated.
    func testAnUnfamiliarStatusIsTreatedAsStillInFlight() async {
        let ritual = await seeded()

        for status in ["pending", "queued", "delivered", "accepted", "in_progress", "claimed"] {
            await ritual.noteResults(in: outbox(
                #"{"message_id":"msg-\#(status)","counterparty":"Kestrel","completed_at":"","#
                    + #""status":"\#(status)"}"#
            ))
        }

        let replies = await ritual.drainReplies()
        XCTAssertTrue(
            replies.isEmpty,
            "announced \(replies.map(\.spokenDescription)) as undeliverable; a status this code "
                + "does not know is a message on its way, and calling it lost makes the owner re-send"
        )
    }

    /// The node goes on listing a dead send, so what stops a repeat is the
    /// ledger. Said once, then never again — the same rule answered sends live
    /// under, and the reason `AlreadySaid` exists at all.
    func testAFailureIsSaidOnceHoweverOftenTheNodeRepeatsIt() async {
        let ritual = await seeded()
        let dead = #"{"message_id":"msg-96ad952b","counterparty":"Kestrel","completed_at":"","status":"expired"}"#

        await ritual.noteResults(in: outbox(dead))
        let first = await ritual.drainReplies()
        XCTAssertEqual(first.count, 1)

        await ritual.noteResults(in: outbox(dead))
        let second = await ritual.drainReplies()
        XCTAssertTrue(second.isEmpty, "the same broken promise was announced twice")
    }

    /// An answered send is still a reply. The failure path must not have
    /// swallowed the case this code was originally for.
    func testAnAnsweredSendIsUnaffected() async {
        let ritual = await seeded()

        await ritual.noteResults(in: outbox(
            #"{"message_id":"msg-ok","counterparty":"Claude","completed_at":"\#(then)","#
                + #""status":"completed","result":"Done."}"#
        ))

        let replies = await ritual.drainReplies()
        XCTAssertEqual(replies.first?.spokenDescription, "Claude replied: Done.")
    }

    // MARK: - Who actually answered
    //
    // The outbox half of the exact-sender fix. 2.2.0 put the authenticated
    // identity on every *inbox* item and carried it into the stored copy of an
    // announcement; the reply path kept reading `counterparty`, which is a
    // display label — and on the captured 11.17.10 outbox is worse than a
    // label, being a hex string the node itself truncated to sixteen characters
    // and an ellipsis. Nothing can be addressed with that.

    /// **The keys are as recorded from a live 11.18.17 outbox on an answered
    /// send; the envelope around them follows the 11.17.10 capture.** Said
    /// exactly rather than loosely, because this file already carries a note
    /// about a fixture that was believed to be a capture and an assertion that
    /// was believed to follow from it: `counterparty`, `counterparty_agent`,
    /// `counterparty_display_name`, `counterparty_registered_name` and `result`
    /// are the measured part, and the ids, timestamps and payload text are
    /// written to match the shape of the row they came from.
    ///
    /// Two things it pins that no hand-written case would: `counterparty_agent`
    /// is the full exact identity beside the display and registered names, and
    /// `result` — guessed first in the candidate list since the day this was
    /// written, and never once verified against the wire — is the reply key.
    func testAnAnsweredSendCarriesTheExactCounterparty() async throws {
        let captured = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Fixtures/sage_message_history-outbox-11.18.17-answered.json"),
            encoding: .utf8
        )
        let ritual = await seeded()

        await ritual.noteResults(in: captured)

        let replies = await ritual.drainReplies()
        let reply = try XCTUnwrap(replies.first)
        XCTAssertEqual(
            reply.exactAgent?.wire,
            "62a4fb76cb0ff019a2e44d2f49a4ee34efbee63a290c4afae055ef88345a1838",
            "the identity of the agent that answered never left the outbox row"
        )
        XCTAssertEqual(reply.from, "codex/sage", "the owner hears the name, not the id")
        XCTAssertEqual(reply.exactAgent?.displayName, "codex/sage")
        XCTAssertEqual(reply.exactAgent?.isForeign, false)
        XCTAssertTrue(reply.text.contains("Under result"), reply.text)
    }

    /// **The exact id is carried whole or not at all.** `shortened` cuts any hex
    /// run over 24 characters to eight and an ellipsis, which is right for a
    /// name being read aloud and fatal for an address — eight characters of an
    /// agent id reaches nobody while still looking like an identity.
    func testTheWireIsNotShortened() async throws {
        let ritual = await seeded()

        await ritual.noteResults(in: outbox(
            #"{"message_id":"msg-w","counterparty_display_name":"codex/sage","#
                + #""counterparty_agent":"62a4fb76cb0ff019a2e44d2f49a4ee34efbee63a290c4afae055ef88345a1838","#
                + #""completed_at":"\#(then)","result":"Done."}"#
        ))

        let replies = await ritual.drainReplies()
        let reply = try XCTUnwrap(replies.first)
        XCTAssertEqual(reply.exactAgent?.wire.count, 64)
        XCTAssertFalse(reply.exactAgent?.wire.contains("…") == true, "the address was truncated")
    }

    /// **The pinned 11.17.10 capture has no `counterparty_agent`, and nothing is
    /// invented from what it does have.** Its `counterparty` reads
    /// `"6aa1d1a4214855ff…"` — truncated *by the node*, with a literal ellipsis
    /// in it. Building an address from that would produce a plausible-looking
    /// identity that reaches nobody, which is worse than having none.
    func testAnOlderOutboxRowInventsNothing() async throws {
        let captured = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Fixtures/sage_message_history-outbox-11.17.10.json"),
            encoding: .utf8
        )
        let ritual = await seeded()

        await ritual.noteResults(in: captured)

        let replies = await ritual.drainReplies()
        let reply = try XCTUnwrap(replies.first)
        XCTAssertNil(reply.exactAgent, "an address was built out of a truncated label")
        XCTAssertEqual(reply.storedSenders, [])
        XCTAssertTrue(reply.from.hasPrefix("6aa1d1a4"), reply.from)
    }

    /// The failure branch is the one that regresses silently when only the happy
    /// path is wired, and a broken promise is the thing the owner is most likely
    /// to want to follow up on.
    func testAnUndeliveredSendAlsoCarriesTheIdentity() async throws {
        let ritual = await seeded()

        await ritual.noteResults(in: outbox(
            #"{"message_id":"msg-dead","counterparty":"Kestrel","#
                + #""counterparty_agent":"7f2b91aabbccddee0011223344556677889900aabbccddeeff0011223344556","#
                + #""status":"expired"}"#
        ))

        let replies = await ritual.drainReplies()
        let reply = try XCTUnwrap(replies.first)
        XCTAssertEqual(reply.kind, .neverArrived(why: "it expired before it could be delivered"))
        XCTAssertEqual(
            reply.exactAgent?.wire,
            "7f2b91aabbccddee0011223344556677889900aabbccddeeff0011223344556"
        )
        XCTAssertEqual(reply.storedSenders.count, 1)
    }

    /// A federated counterparty is addressed `id@chain`, and the whole string is
    /// the exact `to`. Stripping at the `@` leaves a bare id that reaches nobody
    /// once it leaves this SAGE — the same rule `AgentInboxItem.replyTo` keeps
    /// on the inbox side.
    func testAForeignCounterpartyKeepsItsChain() async throws {
        let ritual = await seeded()

        await ritual.noteResults(in: outbox(
            #"{"message_id":"msg-far","counterparty_display_name":"MYNAH@studio","#
                + #""counterparty_agent":"abc123@sage-studio","#
                + #""completed_at":"\#(then)","result":"Got it."}"#
        ))

        let replies = await ritual.drainReplies()
        let reply = try XCTUnwrap(replies.first)
        XCTAssertEqual(reply.exactAgent?.wire, "abc123@sage-studio")
        XCTAssertEqual(reply.exactAgent?.isForeign, true)
    }

    /// **The owner's-phone guarantee.** `spokenDescription` is what goes to
    /// Signal; the exact id belongs only in the stored frame. Reading a
    /// 64-character hex string to somebody is not an answer.
    func testTheExactIdIsNeverInWhatIsSpoken() throws {
        let wire = "62a4fb76cb0ff019a2e44d2f49a4ee34efbee63a290c4afae055ef88345a1838"
        let exact = try XCTUnwrap(AgentAddress.asAttributedByTheNode(
            senderAgent: wire, displayName: "codex/sage", isForeign: false
        ))
        for reply in [
            SageRitual.PipeReply(from: "codex/sage", text: "Done.", exactAgent: exact),
            SageRitual.PipeReply(
                from: "codex/sage", text: "",
                kind: .neverArrived(why: "it expired before it could be delivered"),
                exactAgent: exact
            )
        ] {
            let spoken = reply.spokenDescription
            XCTAssertFalse(spoken.contains(wire), spoken)
            XCTAssertNil(
                spoken.range(of: "[0-9a-fA-F]{24,}", options: .regularExpression),
                "a long hex run reached the owner's phone: \(spoken)"
            )
            XCTAssertTrue(spoken.contains("codex/sage"), spoken)
        }
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
    {"stored": true, "items": [
      {"message_id":"p-1","completed_at":"2026-08-05T09:15:00Z","counterparty":"Claude","result":"Acknowledged — the pipeline works."}]}
    """

    func testTheSameResultIsNotSaidTwice() async {
        let ritual = ritual()
        await ritual.noteResults(in: #"{"items": [{"completed_at":"2026-08-05T09:15:00Z","counterparty":"x","result":"old"}]}"#)

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
        await first.noteResults(in: #"{"items": [{"completed_at":"2026-08-05T09:15:00Z","counterparty":"x","result":"old"}]}"#)
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
        await ritual.noteResults(in: #"{"items": [{"completed_at":"2026-08-05T09:15:00Z","counterparty":"x","result":"old"}]}"#)
        await ritual.noteResults(in: turnAnswer)
        _ = await ritual.drainReplies()

        await ritual.noteResults(in: """
        {"items": [{"message_id":"p-2","completed_at":"2026-08-05T09:15:00Z","counterparty":"Codex","result":"Wave 3 is done."}]}
        """)

        let arrived = await ritual.drainReplies()
        XCTAssertEqual(arrived.first?.from, "Codex")
    }

    func testWithNoPipeIdItFallsBackToWhatWasSaid() async {
        // Some results may carry no id. Two replies identical in sender and
        // text are indistinguishable to a reader anyway, so treating them as
        // one costs nothing and saying them twice costs the owner's patience.
        let ritual = ritual()
        await ritual.noteResults(in: #"{"items": [{"completed_at":"2026-08-05T09:15:00Z","counterparty":"x","result":"old"}]}"#)
        let anonymous = #"{"items": [{"completed_at":"2026-08-05T09:15:00Z","counterparty":"Codex","result":"Wave 3 is done."}]}"#

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

// MARK: - The first look

/// What happens the moment this ledger exists.
///
/// The node goes on returning results for hours, so the first turn after an
/// upgrade hands over everything it still holds — and every one of them looks
/// new to an empty ledger. That is exactly what the owner saw: he updated, and
/// his thread immediately filled with three replies he had already read twice.
/// *"you repeated yourself two three tiems."*
final class FirstLookTests: XCTestCase {

    private var said: URL!
    private var saidDirectory: URL!

    override func setUpWithError() throws {
        saidDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("first-look-\(UUID().uuidString)", isDirectory: true)
        said = saidDirectory.appendingPathComponent("said-replies.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: saidDirectory)
    }

    private func ritual() -> SageRitual {
        SageRitual(tools: SilentTools(), displayName: "Mynah", alreadySaidFile: said)
    }

    private let backlog = """
    {"items": [
      {"completed_at":"2026-08-05T09:15:00Z","counterparty":"Claude","result":"Acknowledged."},
      {"completed_at":"2026-08-05T09:15:00Z","counterparty":"Codex","result":"Wave 3 is done."}]}
    """

    func testNothingAlreadyWaitingIsSaid() async {
        let ritual = ritual()

        await ritual.noteResults(in: backlog)

        let replies = await ritual.drainReplies()
        XCTAssertTrue(replies.isEmpty, "an upgrade must not replay a morning of replies")
    }

    func testButItIsWrittenDown() async {
        let first = ritual()
        await first.noteResults(in: backlog)

        // A later turn, and a later process, must still treat these as old.
        let next = ritual()
        await next.noteResults(in: backlog)

        let replies = await next.drainReplies()
        XCTAssertTrue(replies.isEmpty)
    }

    func testWhatArrivesAfterwardsIsSaid() async {
        let ritual = ritual()
        await ritual.noteResults(in: backlog)

        await ritual.noteResults(in: """
        {"items": [{"completed_at":"2026-08-05T09:15:00Z","counterparty":"Kestrel","result":"Found it: 4,200."}]}
        """)

        let replies = await ritual.drainReplies()
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(replies.first?.from, "Kestrel")
    }

    func testALedgerFromTheVersionBeforeThisRuleIsNotReplayed() throws {
        // 1.2.13 wrote ids and no seeded flag. Its contents are proof it has
        // seen a turn, so it is treated as seeded rather than as brand new —
        // otherwise upgrading *again* would replay everything one more time.
        try FileManager.default.createDirectory(at: saidDirectory, withIntermediateDirectories: true)
        try Data(#"{"ids":["Claude|Acknowledged."]}"#.utf8).write(to: said)

        let ledger = SageRitual.AlreadySaid.load(from: said)

        XCTAssertNil(ledger.hasSeeded)
        XCTAssertTrue(ledger.has("Claude|Acknowledged."))
    }

}
