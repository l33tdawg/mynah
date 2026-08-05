import XCTest
@testable import SageVoiceCore

private final class TurnSpy: ToolProviding, @unchecked Sendable {
    var names: [String] = []
    var arguments: [[String: JSONValue]] = []
    var turnReply = "{}"

    func listTools() async throws -> [MCPTool] { [] }

    func call(name: String, arguments: [String: JSONValue]) async throws -> String {
        names.append(name)
        self.arguments.append(arguments)
        return name == SageRitual.Tool.messageHistory ? turnReply : "{}"
    }
}

/// **Nothing pushed a reply to the owner, and the timer that should have was
/// looking in the wrong place.**
///
/// He put it plainly: *"we need it to proactively tell us when there's a reply
/// not wait for us to ask"*, then diagnosed it himself — *"we need some kind of
/// background polling basically"*.
///
/// `ProactiveWatch` already polls every half hour. It reads `sage_inbox` and
/// `sage_backlog`, and `sage_inbox` is by SAGE's own definition the one place a
/// reply to work *you* sent never lands — so the appliance was checking for
/// news on schedule, correctly, somewhere it could not be.
///
/// **The channel this then used is itself gone.** It drove a `sage_turn` with
/// no conversation attached and read `pipe_results` off the answer; that key
/// was renamed at 11.17.4 and removed at 11.17.9, and .9 also made `sage_turn`
/// payload-free. So on the shipped build the poll wrote one episodic memory per
/// tick and could not learn anything. It now reads
/// `sage_message_history(folder: "outbox")`, which is a passive read of what
/// this appliance sent and what came back — no claim, no re-queue, and no
/// consensus write per tick.
final class ProactiveReplyCollectionTests: XCTestCase {

    private var directory = URL(fileURLWithPath: NSTemporaryDirectory())

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("proactive-reply-\(UUID().uuidString)", isDirectory: true)
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

    private let oneReply = """
    {"items":[{"completed_at":"2026-08-05T09:15:00Z","counterparty":"agent/sage-voice-bridge","result":"Received your test note."}]}
    """

    /// A ledger that has already seen a turn — which is every ledger on every
    /// Mac that has run this appliance. See `testTheVeryFirstLookIsStillSilent`
    /// for the one case that is not.
    private func seededLedger() -> URL {
        let url = directory.appendingPathComponent("said.json")
        SageRitual.AlreadySaid(ids: ["pipe-older"], hasSeeded: true).save(to: url)
        return url
    }

    func testAPollFindsAReplyWithTheOwnerSayingNothing() async {
        let tools = TurnSpy()
        tools.turnReply = oneReply
        _ = seededLedger()
        let ritual = makeRitual(tools)

        let replies = await ritual.collectArrivedReplies()

        XCTAssertEqual(
            tools.names, [SageRitual.Tool.messageHistory],
            "a reply to work this appliance sent lives in its own outbox and nowhere else"
        )
        guard case .string(let folder)? = tools.arguments.first?["folder"] else {
            return XCTFail("the poll did not say which folder it wanted")
        }
        XCTAssertEqual(folder, "outbox", "the inbox is the one place a reply to our own send never lands")
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(replies.first?.text, "Received your test note.")
    }

    /// **The first look on a brand-new ledger stays silent, on a timer too.**
    ///
    /// That rule exists because the node keeps returning the same results for
    /// hours, so everything present when a ledger is born looks new — the owner
    /// upgraded once and his thread filled with replies he had already read.
    /// Polling does not weaken it. If anything it needs it more: a fresh
    /// install would otherwise open with a burst of history nobody asked for,
    /// unprompted, before the owner had said a word.
    ///
    /// The cost is one reply on one install, and it is written down rather than
    /// lost — the next question about it answers correctly.
    func testTheVeryFirstLookIsStillSilent() async {
        let tools = TurnSpy()
        tools.turnReply = oneReply

        let replies = await makeRitual(tools).collectArrivedReplies()

        XCTAssertTrue(replies.isEmpty)
    }

    /// **The poll no longer writes anything, and that is the point.**
    ///
    /// It used to be a `sage_turn` with no conversation attached — one episodic
    /// consensus write per tick, purely to see what rode back on the answer. At
    /// the intervals on offer that is a few dozen writes a day into the owner's
    /// ledger recording that Mynah looked and found nothing.
    ///
    /// `sage_message_history` is passive. Its own answer says so — *"This is
    /// passive history; it did not claim or re-queue any message"* — so checking
    /// for news now costs a read and changes nothing on the node.
    ///
    /// This test replaces one that asserted the observation was worded as a look
    /// rather than a conversation. That was the right rule for a mechanism that
    /// had to write; the better answer is not to write.
    func testThePollDoesNotWriteToTheOwnersLedger() async {
        let tools = TurnSpy()
        let ritual = makeRitual(tools)

        await ritual.collectArrivedReplies()

        XCTAssertFalse(
            tools.names.contains(SageRitual.Tool.turn),
            "checking for replies recorded an episodic memory; on a half-hourly timer that is "
                + "a few dozen writes a day saying nothing happened"
        )
        XCTAssertFalse(tools.names.contains(SageRitual.Tool.reflect))
        // And nothing that claims. `sage_messages_receive` would take the
        // message out of the queue, which is destructive to anything else
        // reading it — passive history is the whole reason this can be polled.
        XCTAssertFalse(tools.names.contains("sage_messages_receive"))
    }

    /// **The ledger is what stops a timer becoming a nag.** A poll every half
    /// hour against a node that keeps listing the same answered send for
    /// hours is the exact shape of the bug the owner already read twice —
    /// *"you repeated yourself two three tiems"* — only now it repeats without
    /// him saying anything at all.
    func testASecondPollDoesNotSayItAgain() async {
        let tools = TurnSpy()
        tools.turnReply = oneReply
        _ = seededLedger()
        let ritual = makeRitual(tools)

        let first = await ritual.collectArrivedReplies()
        let second = await ritual.collectArrivedReplies()

        XCTAssertEqual(first.count, 1)
        XCTAssertTrue(second.isEmpty, "the node keeps offering it; the appliance must not keep saying it")
    }

    /// And the ledger is on disk, so the restart between two ticks that the
    /// daemon takes several times a day does not replay the morning.
    func testARestartBetweenPollsDoesNotReplayIt() async {
        let tools = TurnSpy()
        tools.turnReply = oneReply
        _ = seededLedger()
        let said = await makeRitual(tools).collectArrivedReplies()
        XCTAssertEqual(said.count, 1)

        let afterRestart = await makeRitual(tools).collectArrivedReplies()

        XCTAssertTrue(afterRestart.isEmpty)
    }

    /// A node that will not answer must not put a failure on the owner's phone.
    /// Every proactive path in this appliance swallows its errors for the same
    /// reason: nobody asked for this check, so nobody should hear it fail.
    func testAFailedPollIsSilent() async {
        struct Broken: ToolProviding {
            func listTools() async throws -> [MCPTool] { [] }
            func call(name: String, arguments: [String: JSONValue]) async throws -> String {
                throw BrainBackendError.unreachable("node is down")
            }
        }

        let replies = await makeRitual(Broken()).collectArrivedReplies()

        XCTAssertTrue(replies.isEmpty)
    }
}
