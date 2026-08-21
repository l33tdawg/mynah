import XCTest
@testable import SageVoiceCore

/// **The state the appliance had no word for, and what not having one cost.**
///
/// The owner asked Mynah about a question he had sent on 17 August. It told him
/// the row was *"a legacy row from the claim bug that may never flip on its
/// own"* and that *"there's nothing left on my side or his to make that row
/// move"*. Both halves were wrong, and the node would have said so: that
/// message was delivered at 08:56:56Z and read-confirmed at 08:57:27Z —
/// thirty-two seconds — with `retention: durable_until_handled`. Nothing was
/// stuck and nothing was lost. The recipient simply never handled it, which is
/// a live thing somebody can still do.
///
/// It guessed because `SageRitual` gave it nothing better. `noteResults` sorts
/// the outbox into ANSWERED (carries a `result`) and NEVER ARRIVED (a terminal
/// status). A row that is `pending` or `claimed` is neither, so it fell between
/// the two filters and the model's only view of it was the raw word "pending"
/// in a listing.
///
/// **And the row itself cannot settle it.** Measured against the owner's node
/// on 21 Aug 2026: a pending outbox row carries `status`, `created_at`,
/// `claimed_at` and `completed_at` and no delivery or read state at all. So a
/// send dropped ten days ago and one made ten minutes ago are the same row to
/// this file. `sage_message_status` is the only surface that can tell them
/// apart, which is why this pass costs a call per aged send.
final class AnUnansweredSendHasANameTests: XCTestCase {

    /// Answers the outbox with whatever the test sets, and every
    /// `sage_message_status` with a per-id fixture.
    private final class OutboxSpy: ToolProviding, @unchecked Sendable {
        var outbox = "{}"
        var status: [String: String] = [:]
        var statusCalls: [String] = []

        func listTools() async throws -> [MCPTool] { [] }

        func call(name: String, arguments: [String: JSONValue]) async throws -> String {
            switch name {
            case SageRitual.Tool.messageHistory:
                return outbox
            case SageRitual.Tool.messageStatus:
                guard case .string(let id)? = arguments["message_id"] else { return "{}" }
                statusCalls.append(id)
                return status[id] ?? "{}"
            default:
                return "{}"
            }
        }
    }

    private var directory = URL(fileURLWithPath: NSTemporaryDirectory())

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("unanswered-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeRitual(_ tools: ToolProviding) -> SageRitual {
        SageRitual(
            tools: tools,
            alreadySaidFile: directory.appendingPathComponent("said.json"),
            readableDomainsFile: directory.appendingPathComponent("domains.json")
        )
    }

    /// Seeds the say-once ledger the way every shipped appliance already has
    /// one, so these tests measure the feature and not the first-look silence.
    private func seeded(_ tools: OutboxSpy) async -> SageRitual {
        let ritual = makeRitual(tools)
        let held = tools.outbox
        tools.outbox = Self.outbox([])
        _ = await ritual.collectArrivedReplies()
        tools.outbox = held
        return ritual
    }

    private static func daysAgo(_ days: Double) -> String {
        BoundedTimeline.rfc3339(Date().addingTimeInterval(-days * 24 * 60 * 60))
    }

    private static func outbox(_ rows: [String]) -> String {
        "{\"items\":[\(rows.joined(separator: ","))]}"
    }

    private static func send(id: String, to: String = "mini", ago: Double) -> String {
        """
        {"message_id":"\(id)","counterparty":"\(to)","created_at":"\(daysAgo(ago))",
         "completed_at":"","status":"pending","intent":"Ask about the menu"}
        """
    }

    private static func statusReply(
        transport: String = "delivered", read: String = "not_confirmed", workflow: String
    ) -> String {
        """
        {"transport_status":"\(transport)","read_status":"\(read)","workflow_status":"\(workflow)"}
        """
    }

    // MARK: The three states, as they were measured on the owner's node

    /// Four of his six aged sends were in this state, and it is the strongest
    /// of the three: an agent chose to take the work and then stopped.
    func testAClaimedSendNobodyFinishedIsReported() async {
        let tools = OutboxSpy()
        tools.outbox = Self.outbox([Self.send(id: "msg-1", to: "levelup", ago: 6)])
        tools.status["msg-1"] = Self.statusReply(workflow: "claimed")
        let ritual = await seeded(tools)

        let said = await ritual.collectArrivedReplies()

        XCTAssertEqual(said.count, 1)
        XCTAssertEqual(
            said.first?.spokenDescription,
            "levelup still hasn't answered you — somebody there took it on and never finished."
        )
    }

    /// The 17 August menu question, which is the one he asked about.
    func testASendTheyReadAndNeverPickedUpIsReported() async {
        let tools = OutboxSpy()
        tools.outbox = Self.outbox([Self.send(id: "msg-2", ago: 4)])
        tools.status["msg-2"] = Self.statusReply(read: "confirmed", workflow: "pending")
        let ritual = await seeded(tools)

        let said = await ritual.collectArrivedReplies()

        XCTAssertEqual(
            said.first?.spokenDescription,
            "mini still hasn't answered you — they read it and never picked it up."
        )
    }

    func testASendNobodyEvenOpenedIsReported() async {
        let tools = OutboxSpy()
        tools.outbox = Self.outbox([Self.send(id: "msg-3", to: "hardware", ago: 11)])
        tools.status["msg-3"] = Self.statusReply(workflow: "pending")
        let ritual = await seeded(tools)

        let said = await ritual.collectArrivedReplies()

        XCTAssertEqual(
            said.first?.spokenDescription,
            "hardware still hasn't answered you — it reached them and nobody has opened it."
        )
    }

    // MARK: What must stay quiet

    /// A day, because the point is telling dropped from slow. Mini answered a
    /// message in two minutes on the day this shipped.
    func testASendFromThisMorningIsStillInFlight() async {
        let tools = OutboxSpy()
        tools.outbox = Self.outbox([Self.send(id: "msg-4", ago: 0.2)])
        tools.status["msg-4"] = Self.statusReply(workflow: "claimed")
        let ritual = await seeded(tools)

        let said = await ritual.collectArrivedReplies()

        XCTAssertTrue(said.isEmpty, "a send from five hours ago was called unanswered")
        XCTAssertTrue(
            tools.statusCalls.isEmpty,
            "the node was asked about a send too fresh to report, which is a call per tick forever"
        )
    }

    /// The same rule `terminalFailure` follows: an unrecognised state says
    /// nothing rather than being read as neglect. This sentence sends the owner
    /// to chase a person, and chasing somebody who is mid-answer is a cost that
    /// silence does not have.
    func testAWorkflowStateThisDoesNotKnowSaysNothing() async {
        let tools = OutboxSpy()
        tools.outbox = Self.outbox([Self.send(id: "msg-5", ago: 9)])
        tools.status["msg-5"] = Self.statusReply(workflow: "in_progress")
        let ritual = await seeded(tools)

        let said = await ritual.collectArrivedReplies()

        XCTAssertTrue(said.isEmpty, "an unknown workflow state was reported as neglect")
    }

    /// Undelivered belongs to the other two paths — still travelling, or a
    /// terminal failure `neverArrived` already has the sentence for.
    func testSomethingStillInTransitIsNotThisPathsBusiness() async {
        let tools = OutboxSpy()
        tools.outbox = Self.outbox([Self.send(id: "msg-6", ago: 9)])
        tools.status["msg-6"] = Self.statusReply(transport: "queued", workflow: "pending")
        let ritual = await seeded(tools)

        let said = await ritual.collectArrivedReplies()

        XCTAssertTrue(said.isEmpty, "a message still in transit was reported as ignored")
    }

    func testItIsSaidOnceAndNotEveryFifteenMinutesForever() async {
        let tools = OutboxSpy()
        tools.outbox = Self.outbox([Self.send(id: "msg-7", ago: 5)])
        tools.status["msg-7"] = Self.statusReply(workflow: "claimed")
        let ritual = await seeded(tools)

        let first = await ritual.collectArrivedReplies()
        let second = await ritual.collectArrivedReplies()

        XCTAssertEqual(first.count, 1)
        XCTAssertTrue(second.isEmpty, "the owner would get this every tick for as long as it stands")
    }

    // MARK: The trap this was designed around

    /// **The ledger key is `unanswered|<id>`, not the bare id, and this is why.**
    ///
    /// `noteResults` remembers a bare `message_id` when it announces an answer.
    /// Had this path written the same key, reporting a send as unanswered would
    /// have poisoned it: when the answer finally arrived, `noteResults` would
    /// find the id already in the ledger and stay silent. A feature about
    /// unanswered mail would have become a way of swallowing the answer.
    func testReportingASendUnansweredDoesNotSwallowItsAnswerLater() async {
        let tools = OutboxSpy()
        tools.outbox = Self.outbox([Self.send(id: "msg-8", to: "levelup", ago: 7)])
        tools.status["msg-8"] = Self.statusReply(workflow: "claimed")
        let ritual = await seeded(tools)

        let chased = await ritual.collectArrivedReplies()
        XCTAssertEqual(chased.count, 1, "the unanswered notice did not go out")

        // Now they answer it.
        tools.outbox = Self.outbox(["""
        {"message_id":"msg-8","counterparty":"levelup","created_at":"\(Self.daysAgo(7))",
         "completed_at":"\(Self.daysAgo(0))","status":"completed","result":"Sorry — here it is."}
        """])

        let answered = await ritual.collectArrivedReplies()

        XCTAssertEqual(
            answered.first?.spokenDescription, "levelup replied: Sorry — here it is.",
            "the answer was swallowed because the chase had already claimed its id"
        )
    }

    /// Asking is cheap and lands on a node; saying is a notification and lands
    /// on a person. Six qualified at once on the owner's node the day this
    /// shipped, because the say-once ledger is seeded on every appliance that
    /// has ever run — so nothing here gets the silent first look.
    func testABacklogOfThemDoesNotArriveAsOneBurst() async {
        let tools = OutboxSpy()
        tools.outbox = Self.outbox((1...6).map { Self.send(id: "old-\($0)", ago: Double(20 - $0)) })
        for n in 1...6 { tools.status["old-\(n)"] = Self.statusReply(workflow: "claimed") }
        let ritual = await seeded(tools)

        let firstTick = await ritual.collectArrivedReplies()
        let secondTick = await ritual.collectArrivedReplies()
        let thirdTick = await ritual.collectArrivedReplies()

        XCTAssertEqual(firstTick.count, SageRitual.unansweredPerTick)
        XCTAssertEqual(secondTick.count, SageRitual.unansweredPerTick)
        XCTAssertTrue(thirdTick.isEmpty)
        XCTAssertEqual(
            firstTick.count + secondTick.count, 6,
            "the cap must spread them, never drop them"
        )
    }

    /// Oldest first, so that a cap spends its calls on what has waited longest.
    func testTheLongestWaitIsSaidFirst() async {
        let tools = OutboxSpy()
        tools.outbox = Self.outbox([
            Self.send(id: "newer", to: "recent", ago: 2),
            Self.send(id: "oldest", to: "ancient", ago: 30)
        ])
        for id in ["newer", "oldest"] { tools.status[id] = Self.statusReply(workflow: "claimed") }
        let ritual = await seeded(tools)

        let said = await ritual.collectArrivedReplies()

        XCTAssertEqual(said.first?.from, "ancient")
    }

    // MARK: Trust

    /// Both call sites passed a hardcoded `true`, which was already wrong for
    /// `.neverArrived` and would have been wrong here for the same reason:
    /// these two sentences contain no foreign prose at all.
    func testOnlyARealReplyCountsAsQuotingAnotherAgent() {
        XCTAssertTrue(SageRitual.PipeReply(from: "a", text: "hi").quotesAnotherAgent)
        XCTAssertFalse(
            SageRitual.PipeReply(from: "a", text: "", kind: .neverArrived(why: "it expired"))
                .quotesAnotherAgent
        )
        XCTAssertFalse(
            SageRitual.PipeReply(from: "a", text: "", kind: .unanswered(how: "they read it"))
                .quotesAnotherAgent
        )
    }
}
