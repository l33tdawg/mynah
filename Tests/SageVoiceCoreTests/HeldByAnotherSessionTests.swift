import XCTest
@testable import SageVoiceCore

/// **"Woken, nothing claimable" and "the bus is broken" used to look the same
/// in `bridge.log`, and one of them was true on 17 August 2026.**
///
/// A Mynah on a federated node (`STUDIO-MACMINI`) sent this appliance a
/// message. The wake bus was healthy the whole day — `pending: true` every five
/// minutes — and the owner was never told. The message was there; it was held
/// under a claim taken by another session, so this appliance could not take it.
/// `sage_inbox` reports that in `claimed_elsewhere_count`, and the watch had
/// nowhere to put it, so the only line the log could form was `0 waiting` —
/// which is what a genuinely quiet inbox prints too.
///
/// Three states, three lines, and telling them apart is the whole of this file:
///
/// | state | line |
/// |---|---|
/// | quiet inbox | `[watch] inbox: 0 waiting; none held by another session` |
/// | held elsewhere | `[watch] inbox: 0 waiting; 1 held by another session` |
/// | broken bus | `[watch] inbox: could not read — …` |
///
/// Nothing here changes what the owner hears, and one test below exists only to
/// pin that. The appliance reports the state and does not act on it: SAGE's own
/// guidance for taking over a claim is to judge the prior claimant dead first,
/// and this appliance has no basis for that judgement.
final class HeldByAnotherSessionTests: XCTestCase {

    // MARK: - A source that answers however the test needs

    private struct Node: ProactiveSource {
        var items: [AgentInboxItem] = []
        var claimed: AgentInboxRead.ClaimedElsewhere = .notReported
        var inboxTrouble: (any Error)?
        let said: LineLog

        func waitingInbox(limit: Int) async throws -> AgentInboxRead {
            if let inboxTrouble { throw inboxTrouble }
            return AgentInboxRead(items: items, claimedElsewhere: claimed)
        }

        func waitingMessages(limit: Int) async throws -> [AgentInboxItem] {
            try await waitingInbox(limit: limit).items
        }

        func openTasks() async throws -> [WatchedTask] { [] }

        func note(_ line: String) { said.add(line) }
    }

    private func seeded() -> ProactiveLedger { ProactiveLedger(hasSeeded: true) }

    private func message(_ id: String) -> AgentInboxItem {
        AgentInboxItem(
            id: id,
            content: UntrustedAgentContent(
                sender: "Mynah STUDIO-MACMINI",
                trust: .anotherAgentHere,
                body: "Did the 2.3.0 notarisation go through?"
            ),
            intent: nil,
            arrived: nil,
            expectsAResult: false
        )
    }

    private func inboxLine(in lines: [String]) -> String {
        lines.first { $0.hasPrefix("[watch] inbox:") } ?? ""
    }

    // MARK: - The three states

    /// **The incident, as a line.** Nothing this appliance may take, and
    /// something there all the same. The count alone was true and useless; the
    /// clause is the half that names what to go and look at.
    func testWorkHeldByAnotherSessionIsNamedBesideTheZero() async {
        let said = LineLog()
        let node = Node(claimed: .exactly(1), said: said)

        _ = await ProactiveWatch(source: node).check(against: seeded())

        XCTAssertEqual(
            inboxLine(in: said.lines),
            "[watch] inbox: 0 waiting; 1 held by another session",
            "this is the day's log with the missing half restored — without the clause "
                + "it reads as a quiet inbox, which is what it read as for 105 checks"
        )
    }

    /// The negative that makes the positive worth having. A node that looked
    /// and found nobody holding anything says so, so that an *absent* clause
    /// can keep meaning "this node does not report it" rather than "zero".
    func testARealZeroIsSaidOutLoudRatherThanLeftBlank() async {
        let said = LineLog()
        let node = Node(claimed: .exactly(0), said: said)

        _ = await ProactiveWatch(source: node).check(against: seeded())

        XCTAssertEqual(
            inboxLine(in: said.lines),
            "[watch] inbox: 0 waiting; none held by another session"
        )
    }

    /// **An older node's line does not move.** `claimed_elsewhere_*` arrived in
    /// a recent SAGE; a node that never mentions it must not have a zero
    /// invented on its behalf, and must not gain a clause saying so on every
    /// check for the rest of its life. Silence is the correct output for "this
    /// node does not say".
    func testANodeThatNeverMentionsItAddsNothingToTheLine() async {
        let said = LineLog()
        let node = Node(claimed: .notReported, said: said)

        _ = await ProactiveWatch(source: node).check(against: seeded())

        XCTAssertEqual(inboxLine(in: said.lines), "[watch] inbox: 0 waiting")
    }

    /// **A probe that failed is not a zero, in the log any more than in the
    /// parser.** The node's own contract: *"an unavailable probe is explicit
    /// and never presented as zero"*. Its state word travels verbatim, because
    /// a paraphrase is a state nobody can grep the node's source for.
    func testAnUnavailableProbeNamesTheNodesOwnStateAndNotAZero() async {
        let said = LineLog()
        let node = Node(claimed: .probeUnavailable(state: "temporarily_unavailable"), said: said)

        _ = await ProactiveWatch(source: node).check(against: seeded())

        let line = inboxLine(in: said.lines)
        XCTAssertTrue(line.contains("could not say"), line)
        XCTAssertTrue(
            line.contains("temporarily_unavailable"),
            "the node's own word is the only thing that names the next place to look: \(line)"
        )
        XCTAssertFalse(
            line.contains("none held"),
            "a failed probe rendered as a clean zero is the incident with extra confidence: \(line)"
        )
    }

    /// **The distinction this whole change is for.** A bus that is down must
    /// not borrow the vocabulary of a bus that is up and holding something —
    /// they are opposite states with opposite next actions, and the failure
    /// line has to stay a failure line.
    func testABrokenBusStillReadsAsAFailureAndNotAsNothingHeld() async {
        let said = LineLog()
        let node = Node(inboxTrouble: AgentMessagingTrouble.nodeUnavailable, said: said)

        _ = await ProactiveWatch(source: node).check(against: seeded())

        let line = inboxLine(in: said.lines)
        XCTAssertTrue(line.contains("could not read"), line)
        XCTAssertFalse(
            line.contains("held by another session"),
            "a check that never reached the node cannot know what anybody is holding: \(line)"
        )
    }

    /// One line per read, still. This log is read by eye and shares a file with
    /// the daemon's own; the clause is a clause, not a second entry.
    func testTheClauseCostsNoExtraLine() async {
        let said = LineLog()
        let node = Node(items: [message("m-1")], claimed: .exactly(2), said: said)

        _ = await ProactiveWatch(source: node).check(against: seeded())

        XCTAssertEqual(said.lines, ["[watch] inbox: 1 waiting; 2 held by another session"])
    }

    // MARK: - What the owner is told, which does not change

    /// **A held message is a fact about the node, not news for his phone.** He
    /// cannot act on it — this appliance will not break another session's
    /// claim — so telling him would be an alert with no next step, which is the
    /// dead end this project keeps removing.
    func testNothingClaimableStillMeansNothingIsSaid() async {
        let said = LineLog()
        let node = Node(claimed: .exactly(1), said: said)

        let report = await ProactiveWatch(source: node).check(against: seeded())

        XCTAssertNil(report.message, "he was told about a message this appliance cannot even read")
        XCTAssertFalse(said.lines.isEmpty, "and it still has to be diagnosable afterwards")
    }

    /// And the digest that *does* go out carries none of this machinery.
    func testTheDigestNeverMentionsTheOtherSession() async {
        let said = LineLog()
        let node = Node(items: [message("m-1")], claimed: .exactly(3), said: said)

        let report = await ProactiveWatch(source: node).check(against: seeded())

        let message = report.message ?? ""
        XCTAssertTrue(message.contains("Mynah STUDIO-MACMINI"), message)
        XCTAssertFalse(message.contains("held by another session"), message)
        XCTAssertFalse(message.contains("session"), "log vocabulary on his phone: \(message)")
    }

    // MARK: - The wiring, without which none of it reaches bridge.log

    /// A node at the transport layer: the inbox reply the test chooses, and a
    /// healthy empty backlog so the task half stays out of the assertions.
    private actor Answers: ToolProviding {
        private let inbox: String
        private var calls: [String] = []

        init(inbox: String) { self.inbox = inbox }

        func listTools() async throws -> [MCPTool] { [] }

        func call(name: String, arguments: [String: JSONValue]) async throws -> String {
            calls.append(name)
            return name == "sage_backlog" ? #"{"tasks_by_domain":{}}"# : inbox
        }

        func callCount(_ name: String) -> Int { calls.filter { $0 == name }.count }
    }

    /// **The test that stops this shipping inert**, and the reason it is worth
    /// more than the seven above put together.
    ///
    /// `ProactiveSource` gives `waitingInbox` a default implementation, and the
    /// default answers `.notReported` — so a `SageProactiveSource` that forgot
    /// to override it would compile, pass every stub-driven test in this file,
    /// print `0 waiting` forever, and reproduce 17 August exactly. This is the
    /// path the daemon actually runs: `SageProactiveSource(tools: mcp, log: {
    /// note($0) })`, wrapped in `ProactiveWatch(source: source)`, with the
    /// node's real reply shape at the bottom.
    func testTheHeldCountReachesTheLogThroughTheSourceTheDaemonBuilds() async {
        let said = LineLog()
        let source = SageProactiveSource(
            tools: Answers(inbox: #"""
                {"count":0,"items":[],"message_count":0,"task_assignment_count":0,
                 "claimed_elsewhere_count":1,
                 "coordination_schema":"sage.inbox.v2"}
                """#),
            log: { said.add($0) }
        )

        _ = await ProactiveWatch(source: source).check(against: seeded())

        XCTAssertTrue(
            said.lines.contains("[watch] inbox: 0 waiting; 1 held by another session"),
            "the node reported it, the parser read it, and it got no further than the "
                + "source — which is the whole shape of the original defect: \(said.lines)"
        )
    }

    /// **And it is still one call.** `sage_inbox` atomically claims the rows it
    /// returns, with no expiry, so a second read taken "just for the counters"
    /// would strand a message under a claim — the same defect this patch
    /// removes from `sage-voiced check`. Two methods, one call.
    func testTheInboxIsReadExactlyOncePerCheck() async {
        let tools = Answers(inbox: #"{"count":0,"items":[],"claimed_elsewhere_count":1}"#)
        let source = SageProactiveSource(tools: tools, log: { _ in })

        _ = await ProactiveWatch(source: source).check(against: seeded())

        let calls = await tools.callCount("sage_inbox")
        XCTAssertEqual(
            calls, 1,
            "every extra sage_inbox call is another durable claim taken under this session"
        )
    }
}

/// Sendable line collector for a `@Sendable` log closure.
private final class LineLog: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [String] = []

    var lines: [String] {
        lock.lock(); defer { lock.unlock() }
        return collected
    }

    func add(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        collected.append(line)
    }
}
