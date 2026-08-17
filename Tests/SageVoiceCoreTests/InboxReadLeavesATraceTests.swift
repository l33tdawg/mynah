import XCTest
@testable import SageVoiceCore

/// **A day of healthy-looking log that could not answer "did the inbox read
/// work".**
///
/// On 17 August 2026 a Mynah on a federated node sent a message to this
/// appliance and the owner was never told. The wake bus was healthy the whole
/// time — a `[wake]` line every five minutes, all day — and `bridge.log`
/// carried 197 dumps of the *outbox* against zero lines of any kind about an
/// inbox read. Not one failure, not one count.
///
/// The cause was one character: `try?` in `ProactiveWatch.check`. Nil is the
/// right answer to hand the owner — a check that failed says nothing and
/// forgets nothing, which is the design and stays the design — but nil was
/// also the only thing anybody got, because the error was dropped where it
/// stood. A failing inbox and an empty one were indistinguishable in the one
/// file somebody would open to tell them apart.
///
/// Every test here is about the log, not about the owner. What he hears is
/// pinned by `ProactiveWatchTests` and must not move.
final class InboxReadLeavesATraceTests: XCTestCase {

    // MARK: - A node that behaves however the test needs

    private struct Node: ProactiveSource {
        var messages: [AgentInboxItem] = []
        var tasks: [WatchedTask] = []
        var inboxTrouble: (any Error)?
        var taskTrouble: (any Error)?
        let said: Recorder

        func waitingMessages(limit: Int) async throws -> [AgentInboxItem] {
            if let inboxTrouble { throw inboxTrouble }
            return messages
        }

        func openTasks() async throws -> [WatchedTask] {
            if let taskTrouble { throw taskTrouble }
            return tasks
        }

        func note(_ line: String) { said.add(line) }
    }

    private func seeded() -> ProactiveLedger { ProactiveLedger(hasSeeded: true) }

    private func message(_ id: String) -> AgentInboxItem {
        AgentInboxItem(
            id: id,
            content: UntrustedAgentContent(
                sender: "Mynah MBP",
                trust: .anotherAgentHere,
                body: "The roof quote came back at 4,200."
            ),
            intent: nil,
            arrived: nil,
            expectsAResult: false
        )
    }

    private func inboxLine(in lines: [String]) -> String? {
        lines.first { $0.hasPrefix("[watch] inbox:") }
    }

    // MARK: - The read that worked

    /// The line whose absence cost the day. A successful read writes down what
    /// it saw, every time, so that silence in the log means "no check ran" and
    /// nothing else.
    func testASuccessfulInboxReadIsLogged() async {
        let said = Recorder()
        let node = Node(messages: [message("p1"), message("p2")], said: said)

        _ = await ProactiveWatch(source: node).check(against: seeded())

        let line = inboxLine(in: said.lines)
        XCTAssertNotNil(
            line,
            "a healthy check left no trace of the inbox at all — which is exactly the "
                + "state 17 August's bridge.log was in, 105 times over"
        )
        XCTAssertEqual(line, "[watch] inbox: 2 waiting")
    }

    /// The half that makes the other half worth having: an inbox with nothing
    /// in it is a *result*, and it has to be written down as one. Logging only
    /// failures would leave "nothing waiting" and "never asked" sharing one
    /// blank space, which is the same defect one step along.
    func testAnEmptyInboxIsLoggedAsAResultAndNotAsSilence() async {
        let said = Recorder()

        _ = await ProactiveWatch(source: Node(said: said)).check(against: seeded())

        XCTAssertEqual(inboxLine(in: said.lines), "[watch] inbox: 0 waiting")
    }

    /// One line per event. This log is read by eye and shares a file with the
    /// daemon's own; a check that healthily found nothing must cost one line,
    /// not a paragraph.
    func testAHealthyCheckCostsOneLine() async {
        let said = Recorder()
        let node = Node(
            messages: [message("p1")],
            tasks: [WatchedTask(id: "t1", title: "Book the hotel", status: "planned")],
            said: said
        )

        _ = await ProactiveWatch(source: node).check(against: seeded())

        XCTAssertEqual(said.lines, ["[watch] inbox: 1 waiting"])
    }

    // MARK: - The read that failed

    /// **Every failure, not the one case the source happens to name.** The
    /// message that went missing did so behind an error nobody logged.
    func testAFailedInboxReadIsLoggedWithItsError() async {
        struct NodeIsAsleep: Error {}
        let said = Recorder()
        let node = Node(inboxTrouble: NodeIsAsleep(), said: said)

        _ = await ProactiveWatch(source: node).check(against: seeded())

        let line = inboxLine(in: said.lines) ?? ""
        XCTAssertTrue(
            line.contains("could not read"),
            "the throw reached nothing: \(said.lines)"
        )
        XCTAssertTrue(
            line.contains("NodeIsAsleep"),
            "the line has to name the actual error, or it says no more than the "
                + "absence it replaced: \(line)"
        )
    }

    /// The specific error that was silent on 17 August. `MCPClient` throws and
    /// logs nothing, `SageAgentMessaging` maps the throw to this case, and
    /// before the fix the whole chain ended in `try?`.
    func testAnUnreachableNodeIsLoggedRatherThanAssumedLoggedElsewhere() async {
        let said = Recorder()
        let node = Node(inboxTrouble: AgentMessagingTrouble.nodeUnavailable, said: said)

        _ = await ProactiveWatch(source: node).check(against: seeded())

        let line = inboxLine(in: said.lines) ?? ""
        XCTAssertTrue(
            line.contains("nodeUnavailable"),
            "the failure that was silent all day is still silent: \(said.lines)"
        )
    }

    /// **The log gets the fault, not the reassurance.**
    /// `AgentMessagingTrouble.errorDescription` is the sentence written for the
    /// owner's phone — *"Mynah can't exchange messages with your other agents
    /// until it has its own memory"* — and a log that prints that has thrown
    /// away the node's own words, which are the only thing that names the next
    /// action.
    func testTheLoggedErrorIsTheTechnicalOneAndNotTheOwnerSentence() async {
        let said = Recorder()
        let refusal = AgentMessagingTrouble.refused(
            "MCP tool 'sage_inbox' failed: Error: pipeline inbox: Active agent required"
        )
        let node = Node(inboxTrouble: refusal, said: said)

        _ = await ProactiveWatch(source: node).check(against: seeded())

        let line = inboxLine(in: said.lines) ?? ""
        XCTAssertTrue(
            line.contains("Active agent required"),
            "the node's own words are what name the next action: \(said.lines)"
        )
        XCTAssertFalse(
            line.contains("Mynah can't exchange messages"),
            "that is the owner's sentence, and it names nothing a person "
                + "diagnosing this can act on: \(line)"
        )
    }

    /// The task half had the same hole: `try? await source.openTasks()`, one
    /// line below. A `sage_backlog` call that throws — a node restarting, a
    /// refused caller — reached nothing at all.
    func testAFailedTaskReadIsLoggedWithItsError() async {
        struct BacklogRefused: Error {}
        let said = Recorder()
        let node = Node(taskTrouble: BacklogRefused(), said: said)

        _ = await ProactiveWatch(source: node).check(against: seeded())

        let line = said.lines.first { $0.hasPrefix("[watch] tasks:") } ?? ""
        XCTAssertTrue(
            line.contains("could not read"),
            "the backlog throw reached nothing: \(said.lines)"
        )
        XCTAssertTrue(
            line.contains("BacklogRefused"),
            "the line has to name the actual error: \(said.lines)"
        )
    }

    /// A log line is one line. An error carrying a page of JSON must not push
    /// the next event off the screen — the thing a person is scrolling for.
    func testALongErrorStaysOneBoundedLine() async {
        struct Wordy: Error, CustomStringConvertible {
            var description: String { String(repeating: "{\"x\":1}\n", count: 400) }
        }
        let said = Recorder()
        let node = Node(inboxTrouble: Wordy(), said: said)

        _ = await ProactiveWatch(source: node).check(against: seeded())

        let line = inboxLine(in: said.lines) ?? ""
        XCTAssertFalse(line.contains("\n"), "a multi-line log line is several log lines")
        XCTAssertLessThan(line.count, 400, "\(line.count) characters buries whatever came next")
    }

    // MARK: - What the owner is told, which does not change

    /// The design intent this fix had to preserve. A failed check is still
    /// silent to him and still forgets nothing; the only difference is that it
    /// is no longer silent to the log.
    func testAFailedReadStillSaysNothingAndForgetsNothing() async {
        let said = Recorder()
        let node = Node(inboxTrouble: AgentMessagingTrouble.nodeUnavailable, said: said)
        var ledger = seeded()
        ledger.toldAboutMessages = ["p1", "p2"]

        let report = await ProactiveWatch(source: node).check(against: ledger)

        XCTAssertNil(report.message, "a check that could not look must not put anything on his phone")
        XCTAssertEqual(
            report.ledger.toldAboutMessages, ["p1", "p2"],
            "a failed check that forgets re-announces the whole inbox on the next healthy one"
        )
        XCTAssertFalse(said.lines.isEmpty, "and it still has to be diagnosable afterwards")
    }

    // MARK: - The wiring, without which none of the above reaches bridge.log

    /// A node that answers whatever the test hands it, at the transport layer.
    ///
    /// The backlog answers healthily unless the whole node is down, so the
    /// task half stays out of the way of assertions about the inbox — a node
    /// that is up but answering the inbox oddly is the case being pinned.
    private struct Answers: ToolProviding {
        var reply: String = ""
        var trouble: (any Error)?
        func listTools() async throws -> [MCPTool] { [] }
        func call(name: String, arguments: [String: JSONValue]) async throws -> String {
            if let trouble { throw trouble }
            return name == "sage_backlog" ? #"{"tasks_by_domain":{}}"# : reply
        }
    }

    /// **The test that stops this shipping inert.** The daemon builds its
    /// source as `SageProactiveSource(tools: mcp, log: { note($0) })` and
    /// builds the watch as `ProactiveWatch(source: source)` — no second sink.
    /// So the watch's lines reach `bridge.log` only if the source forwards
    /// them, and this is that path end to end.
    func testTheWatchsLinesReachTheSourcesOwnLog() async {
        let said = Recorder()
        let source = SageProactiveSource(
            tools: Answers(reply: #"{"count":0,"items":[],"message_count":0}"#),
            log: { said.add($0) }
        )

        _ = await ProactiveWatch(source: source).check(against: seeded())

        XCTAssertTrue(
            said.lines.contains("[watch] inbox: 0 waiting"),
            "the watch noted it and nothing carried it to the daemon's log: \(said.lines)"
        )
    }

    /// The same wiring for the failure that was silent all day, through the
    /// real source rather than a stub: an unreachable node now costs exactly
    /// one line, where it used to cost none.
    func testAnUnreachableNodeCostsExactlyOneLineThroughTheRealSource() async {
        let said = Recorder()
        let source = SageProactiveSource(
            tools: Answers(trouble: MCPClientError.toolFailed(
                "sage_inbox",
                "Error: pipeline inbox: dial tcp 127.0.0.1:8443: connect: connection refused"
            )),
            log: { said.add($0) }
        )

        _ = await ProactiveWatch(source: source).check(against: seeded())

        let inbox = said.lines.filter { $0.hasPrefix("[watch] inbox:") }
        XCTAssertEqual(inbox.count, 1, "\(said.lines)")
        XCTAssertTrue(inbox.first?.contains("could not read") ?? false, "\(inbox)")
    }

    /// And the one case that is deliberately two lines, pinned so it reads as
    /// chosen rather than overlooked: `SageProactiveSource` names the reply the
    /// node actually sent, which the outer line cannot carry, and the watch
    /// names what the check then did about it. Cause, then consequence.
    func testAnUnreadableReplyIsNamedTwiceOnPurpose() async {
        let said = Recorder()
        let source = SageProactiveSource(
            tools: Answers(reply: #"{"error":"node is starting up"}"#),
            log: { said.add($0) }
        )

        _ = await ProactiveWatch(source: source).check(against: seeded())

        XCTAssertTrue(
            said.lines.contains { $0.contains("node is starting up") },
            "the node's own reply is the detail nothing else records: \(said.lines)"
        )
        XCTAssertTrue(
            said.lines.contains { $0.hasPrefix("[watch] inbox: could not read") },
            "and the outcome line is what makes every *other* failure visible: \(said.lines)"
        )
    }
}

/// Sendable line collector for a `@Sendable` log closure.
private final class Recorder: @unchecked Sendable {
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
