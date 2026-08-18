import XCTest
@testable import SageVoiceCore

/// Answering the agent that wrote to you, rather than the name it was announced
/// under.
///
/// ## Why a label is not an address
///
/// SAGE says it plainly: `sender_agent` is *"the authoritative exact local
/// sender"*, while display, registered-name and provider labels are *"optional
/// presentation metadata"* and *"no label establishes authorization"*. Two
/// agents can share a display name, a display name can be changed by an
/// operator, and before 11.18.12 a local inbox line carried the sender's
/// *provider* — so every `codex/*` agent announced identically.
///
/// This is not hypothetical here. Confusing `1ab7aa10…` (this repository's
/// developer key) with `74140c2d…` (the appliance) is recorded in
/// `SageAgentIdentity` as *"how the owner's messages once reached strangers"*.
///
/// 11.18.12 puts the exact id on every inbox item. These tests are about
/// carrying it to the one place that needs it — the model's history — without
/// putting a 64-character hex string in front of the owner.
final class ExactSenderTests: XCTestCase {

    // MARK: - Reading it off the node

    private func item(_ raw: [String: Any]) -> AgentInboxItem? {
        SageAgentMessaging.item(from: raw)
    }

    /// The shape 11.18.12 sends for a local message.
    func testALocalItemCarriesTheExactSender() throws {
        let parsed = try XCTUnwrap(item([
            "message_id": "msg-1",
            "from": "codex/sage",
            "sender_agent": "62a4fb76cb0ff019a2e44d2f49a4ee34efbee63a290c4afae055ef88345a1838",
            "payload": "have a look at this",
            "trust": "agent_untrusted"
        ]))
        XCTAssertEqual(
            parsed.replyTo?.wire,
            "62a4fb76cb0ff019a2e44d2f49a4ee34efbee63a290c4afae055ef88345a1838"
        )
        XCTAssertEqual(parsed.replyTo?.displayName, "codex/sage")
        XCTAssertEqual(parsed.replyTo?.isForeign, false)
    }

    /// **Nil is a real answer.** Before 11.18.12 the key was written only for
    /// foreign items, so a local one on an older node has no exact identity —
    /// and nil must mean "ask the node", never "rebuild it from the label".
    func testAnOlderNodeYieldsNoExactSenderRatherThanAGuess() throws {
        let parsed = try XCTUnwrap(item([
            "message_id": "msg-1",
            "from": "codex",
            "payload": "hello"
        ]))
        XCTAssertNil(parsed.replyTo)
        XCTAssertEqual(parsed.content.sender, "codex", "the label is still shown")
    }

    /// A foreign sender is addressed `id@chain`; a bare id reaches nobody once
    /// it leaves this SAGE.
    func testAForeignSenderKeepsItsChain() throws {
        let parsed = try XCTUnwrap(item([
            "message_id": "msg-2",
            "from": "MYNAH@studio",
            "sender_agent": "abc123",
            "source_chain": "sage-studio",
            "foreign": true,
            "payload": "from the other Mac"
        ]))
        XCTAssertEqual(parsed.replyTo?.wire, "abc123@sage-studio")
        XCTAssertEqual(parsed.replyTo?.isForeign, true)
    }

    /// **Captured verbatim from the owner's live 11.18.13 node**, 16 August
    /// 2026 — a local message from codex/sage. Two things this pins that a
    /// hand-written fixture would not have: `from` is now the display name
    /// rather than the provider (11.18.12's #216), and `source_chain_id` is
    /// present-but-empty on a local item. Reading that key alone would have
    /// built `62a4fb76…@` as the address of every local sender.
    func testTheLiveLocalShapeParses() throws {
        let parsed = try XCTUnwrap(item([
            "message_id": "msg-16539de7-8090-430d-b6a1-a5caeda1e995",
            "from": "codex/sage",
            "from_display_name": "codex/sage",
            "from_registered_name": "codex/sage",
            "sender_agent": "62a4fb76cb0ff019a2e44d2f49a4ee34efbee63a290c4afae055ef88345a1838",
            "source_chain_id": "",
            "trust": "agent_untrusted",
            "requires_reply": true,
            "payload": "Coordinate the bridge fix"
        ]))
        XCTAssertEqual(
            parsed.replyTo?.wire,
            "62a4fb76cb0ff019a2e44d2f49a4ee34efbee63a290c4afae055ef88345a1838",
            "an empty source_chain_id was appended as though this were federated"
        )
        XCTAssertEqual(parsed.replyTo?.isForeign, false)
        XCTAssertTrue(parsed.expectsAResult)
    }

    /// An empty or blank id is not an address.
    func testABlankSenderIsRefused() throws {
        let parsed = try XCTUnwrap(item([
            "message_id": "msg-3", "from": "x", "sender_agent": "   ", "payload": "hi"
        ]))
        XCTAssertNil(parsed.replyTo)
        XCTAssertNil(AgentAddress.asAttributedByTheNode(
            senderAgent: "", displayName: "x", isForeign: false
        ))
    }

    // MARK: - Which senders a digest quotes

    private func inboxItem(id: String, from: String, wire: String?) -> AgentInboxItem {
        AgentInboxItem(
            id: id,
            content: UntrustedAgentContent(sender: from, trust: .anotherAgentHere, body: "body"),
            intent: nil,
            arrived: nil,
            expectsAResult: true,
            replyTo: wire.flatMap {
                AgentAddress.asAttributedByTheNode(
                    senderAgent: $0, displayName: from, isForeign: false
                )
            }
        )
    }

    /// One agent that sent three messages is one identity to answer.
    func testSendersAreDeduplicatedByExactIdNotByLabel() {
        let senders = ProactiveWatch.exactSenders(of: [
            inboxItem(id: "a", from: "codex/sage", wire: "62a4"),
            inboxItem(id: "b", from: "codex/sage", wire: "62a4"),
            inboxItem(id: "c", from: "claude-code/sage", wire: "65a6")
        ])
        XCTAssertEqual(senders.map(\.wire), ["62a4", "65a6"])
    }

    /// **Two agents sharing a display name stay two identities.** Deduplicating
    /// on the label would collapse exactly the case the id exists for.
    func testTwoAgentsWithOneNameStayTwoIdentities() {
        let senders = ProactiveWatch.exactSenders(of: [
            inboxItem(id: "a", from: "sage", wire: "1ab7aa10"),
            inboxItem(id: "b", from: "sage", wire: "74140c2d")
        ])
        XCTAssertEqual(senders.map(\.wire), ["1ab7aa10", "74140c2d"])
    }

    /// A message from a node that did not say who contributes nothing rather
    /// than a placeholder.
    func testAnItemWithNoExactSenderIsSkipped() {
        let senders = ProactiveWatch.exactSenders(of: [
            inboxItem(id: "a", from: "codex/sage", wire: nil),
            inboxItem(id: "b", from: "claude-code/sage", wire: "65a6")
        ])
        XCTAssertEqual(senders.map(\.wire), ["65a6"])
    }

    // MARK: - Where it ends up, and where it must not

    private var twoSenders: [AgentAddress] {
        [
            AgentAddress.asAttributedByTheNode(
                senderAgent: "62a4fb76", displayName: "codex/sage", isForeign: false
            )!,
            AgentAddress.asAttributedByTheNode(
                senderAgent: "65a6fab9", displayName: "claude-code/sage", isForeign: false
            )!
        ]
    }

    /// The stored copy carries the exact ids, so a later "reply to them" has
    /// something exact to address.
    func testTheStoredCopyCarriesTheExactSenders() {
        let stored = VoiceBridgeDaemon.remembered(
            "codex/sage sent work: “have a look”",
            quotingAnotherAgent: true,
            senders: twoSenders
        )
        XCTAssertTrue(stored.contains("62a4fb76"), stored)
        XCTAssertTrue(stored.contains("65a6fab9"), stored)
        XCTAssertTrue(stored.contains("codex/sage = 62a4fb76"), stored)
        // And it still says the words are not Mynah's and not an instruction.
        XCTAssertTrue(stored.lowercased().contains("another agent"))
        XCTAssertTrue(stored.lowercased().contains("instruction"))
        XCTAssertTrue(stored.contains("have a look"), "the message itself was dropped")
    }

    /// **The owner is never shown a hex id**, which is the entire reason this
    /// rides on the stored copy rather than in the sentence. `announce` sends
    /// `text` to the phone and stores `remembered(text:)`, so the phone copy is
    /// the argument itself — unchanged, whatever the senders are.
    func testThePhoneCopyIsUntouched() {
        let spoken = "codex/sage sent work: “have a look”"
        XCTAssertEqual(
            VoiceBridgeDaemon.remembered(spoken, quotingAnotherAgent: false, senders: twoSenders),
            spoken,
            "Mynah's own words were reframed as somebody else's"
        )
        XCTAssertFalse(spoken.contains("62a4fb76"))
    }

    /// A node that did not say who produces the frame it always did — no empty
    /// bracket, no dangling "for a reply:" with nothing after it.
    func testNoSendersMeansNoExtraLine() {
        let withNone = VoiceBridgeDaemon.relayed("something arrived")
        XCTAssertFalse(withNone.contains("exact agent"), withNone)
        XCTAssertTrue(withNone.contains("another agent"))
        XCTAssertTrue(withNone.contains("something arrived"))
    }

    /// The caution still precedes the words it is about — a warning after the
    /// payload is read after the instruction.
    func testTheExactSendersDoNotPushTheCautionBelowThePayload() throws {
        let stored = VoiceBridgeDaemon.relayed("PAYLOAD", from: twoSenders)
        let caution = try XCTUnwrap(stored.range(of: "another agent"))
        let exact = try XCTUnwrap(stored.range(of: "62a4fb76"))
        let payload = try XCTUnwrap(stored.range(of: "PAYLOAD"))
        XCTAssertLessThan(caution.lowerBound, exact.lowerBound)
        XCTAssertLessThan(exact.lowerBound, payload.lowerBound)
    }

    /// The daemon has to actually pass them through — `main.swift` cannot be
    /// imported, so this is the scan precedent `AfterTheCallTests` set. Without
    /// it the whole path can be correct and the ids never leave the report.
    func testTheDaemonPassesTheExactSendersToTheStoredCopy() throws {
        let main = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/sage-voiced/main.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            main.contains("await say(message, report.relaysAnotherAgent, report.relayedSenders)"),
            "the digest's exact senders never reach the announcement"
        )
        XCTAssertTrue(
            main.contains("quotingAnotherAgent: quotingAnotherAgent, senders: senders"),
            "the announcement drops the exact senders before the stored copy is written"
        )
        XCTAssertTrue(
            main.contains("await say(nudge.text, false, [])"),
            "a reminder is Mynah's own sentence and must not be marked as a relay"
        )
    }

    // MARK: - The outbox half

    /// **The half that was left open in 2.2.0.**
    ///
    /// The inbox side built this road: an announcement quoting another agent
    /// goes to the phone as a plain sentence and into the model's history with
    /// the exact identity attached. The *reply* side — an answer coming back to
    /// work this appliance sent out — walked past it. `main.swift` mapped every
    /// `PipeReply` to its sentence and called `say(reply, true, [])`, and that
    /// literal empty array was where the identity was lost: the model's only
    /// handle on the agent that had just answered was a mutable display label,
    /// which is the condition that once sent the owner's messages to strangers.
    ///
    /// Nothing in `VoiceBridgeDaemon` changed to close it. The frame already
    /// took the addresses and already put them in the stored copy and nowhere
    /// else; the outbox half simply drives on the road the inbox half built.
    func testTheOutboxHalfNowReachesTheStoredFrame() throws {
        let wire = "62a4fb76cb0ff019a2e44d2f49a4ee34efbee63a290c4afae055ef88345a1838"
        let reply = SageRitual.PipeReply(
            from: "codex/sage",
            text: "The roof quote came back at 4,200.",
            exactAgent: AgentAddress.asAttributedByTheNode(
                senderAgent: wire, displayName: "codex/sage", isForeign: false
            )
        )

        let stored = VoiceBridgeDaemon.relayed(reply.spokenDescription, from: reply.storedSenders)
        XCTAssertTrue(stored.contains(wire), stored)
        XCTAssertTrue(stored.contains("codex/sage = \(wire)"), stored)
        XCTAssertTrue(stored.contains("The roof quote came back at 4,200."), stored)

        // And the phone copy — which is the argument itself — carries neither
        // the id nor the frame.
        XCTAssertFalse(reply.spokenDescription.contains(wire))
        XCTAssertFalse(reply.spokenDescription.contains("["), reply.spokenDescription)
    }

    /// A reply from a node that did not say who gets the frame it always got:
    /// no empty bracket, no address rebuilt from the label.
    func testStoredSendersIsEmptyRatherThanInvented() {
        let reply = SageRitual.PipeReply(from: "6aa1d1a4214855ff…", text: "Done.")
        XCTAssertEqual(reply.storedSenders, [])

        let stored = VoiceBridgeDaemon.relayed(reply.spokenDescription, from: reply.storedSenders)
        XCTAssertFalse(stored.contains("exact agent"), stored)
        XCTAssertTrue(stored.contains("another agent"))
        XCTAssertTrue(stored.contains("Done."))
    }

    /// The wiring, at the one seam a test cannot import. Everything above can be
    /// correct while the daemon still hands `[]` to `say`, which is exactly what
    /// it did until this release.
    func testTheDaemonHandsTheReplysOwnSendersToTheStoredCopy() throws {
        let main = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/sage-voiced/main.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            main.contains("await say(reply.spokenDescription, true, reply.storedSenders)"),
            "the agent that answered is announced with no identity attached"
        )
        XCTAssertFalse(
            main.contains("collectArrivedReplies().map(\\.spokenDescription)"),
            "the replies are flattened to sentences before their identities can be read"
        )
    }
}

/// A failed tool call's receipt, which is the only record of why it failed.
///
/// This exists because a 120-character cut produced a wrong bug report. The
/// `sage_timeline` refusal in `bridge.log` read
///
///     Timeline range too large: App-v23 governed timelines are li
///
/// and that was sent upstream as an error that "arrives without the number".
/// The node's sentence ends "limited to 31 days per request; choose a narrower
/// range" — and the model saw all of it, because `ToolLoop.execute` returns
/// `"Error: \(error)"` unbudgeted. Only the log line was short, and it happened
/// to stop one word before the only number that mattered.
final class ToolReceiptTests: XCTestCase {

    private func record(name: String, result: String, failed: Bool) -> ToolCallRecord {
        ToolCallRecord(
            iteration: 1,
            name: name,
            arguments: [:],
            result: result,
            failed: failed,
            durationSeconds: 0.1
        )
    }

    /// The exact sentence that was cut, at its real length.
    private var timelineRefusal: String {
        "Error: MCP tool 'sage_timeline' failed: Error: get timeline: Timeline range too large: "
            + "App-v23 governed timelines are limited to 31 days per request; choose a narrower range."
    }

    func testAFailedReceiptKeepsTheReasonItFailed() {
        let progress = ToolLoopTrace(model: "test", toolCalls: [
            record(name: "sage_timeline", result: timelineRefusal, failed: true)
        ])
        let receipt = try! XCTUnwrap(progress.receipts.first)
        XCTAssertTrue(
            receipt.contains("31 days"),
            "the receipt still cuts the only actionable number in the message: \(receipt)"
        )
        XCTAssertTrue(receipt.contains("choose a narrower range"), receipt)
    }

    /// The old budget is exactly where it went wrong, kept as a pin: at 120 the
    /// number is gone. Mutate `failedReceiptCharacters` back to 120 and the test
    /// above reddens.
    func testTheOldBudgetWouldHaveCutIt() {
        XCTAssertFalse(
            String(timelineRefusal.prefix(120)).contains("31 days"),
            "this fixture no longer reproduces the truncation it was written for"
        )
        XCTAssertGreaterThan(
            ToolLoopTrace.failedReceiptCharacters,
            ToolLoopTrace.receiptCharacters
        )
    }

    /// A success is a confirmation, and one line is still plenty.
    func testASuccessfulSendReceiptStaysShort() {
        let progress = ToolLoopTrace(model: "test", toolCalls: [
            record(name: "sage_message_send", result: String(repeating: "x", count: 900), failed: false)
        ])
        let receipt = try! XCTUnwrap(progress.receipts.first)
        XCTAssertLessThan(receipt.count, ToolLoopTrace.receiptCharacters + 40)
    }

    /// Nothing that fits is decorated with an ellipsis it does not need.
    func testAShortReceiptIsNotMarkedTruncated() {
        let progress = ToolLoopTrace(model: "test", toolCalls: [
            record(name: "sage_message_send", result: "sent", failed: false)
        ])
        XCTAssertEqual(progress.receipts.first, "sage_message_send -> sent")
    }

    /// A truncated one says so, rather than ending mid-word as though that were
    /// the whole message — which is precisely how the wrong report happened.
    func testATruncatedReceiptSaysItWasTruncated() {
        let progress = ToolLoopTrace(model: "test", toolCalls: [
            record(name: "sage_timeline", result: String(repeating: "y", count: 2_000), failed: true)
        ])
        XCTAssertTrue(try! XCTUnwrap(progress.receipts.first).hasSuffix("…"))
    }
}
