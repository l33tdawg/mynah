import XCTest

/// `sage-voiced check` reads the inbox once, and says what that read costs.
///
/// **The incident this pins, 17 August 2026.** Another Mynah on a federated
/// node sent this appliance a message. The owner was never told, and the
/// diagnostic built to answer exactly that question printed both halves of the
/// contradiction in one breath: *"inbox: 1 waiting"* and then *"it would say
/// nothing."*
///
/// The cause is the node's contract, not a parsing slip. `sage_inbox` claims
/// every row it returns under `items` for the caller's opaque session, durably
/// — `message_fetch_receipts` has no expiry column — and hands a row already
/// claimed by that same session back under `own_claimed_unfinished`, which
/// never contributes to `count` or `items`. `check` queried the inbox twice
/// through one MCP client, so the first read took the claim and the second read
/// saw an empty inbox with no error at all. Worse than the wrong verdict: the
/// message was left claimed by a CLI session that exits three lines later, so
/// the daemon then sees it held elsewhere and cannot take it. A support tool
/// that eats what it is diagnosing.
///
/// **Which is why the stub below claims.** A fake node that returns the same
/// items every time makes both the broken and the fixed build look identical —
/// it would have proved nothing on the day. This one implements the contract:
/// the first `sage_inbox` returns the message, every later one returns the
/// passive `own_claimed_unfinished` shape. Against it, the shipped 2.3.0
/// behaviour reproduces verbatim.
///
/// **End-to-end through the real binary, because the defect was in the
/// wiring.** `sage-voiced` is an executable target and nothing can import it;
/// every value type underneath was already tested and every one of them was
/// correct. The only place the fault existed was in how `check` strung them
/// together, so the only test that can see it runs the command.
final class CheckReadsTheInboxOnceTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mynah-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// One read, and one claim.
    ///
    /// The count is the assertion that matters: every extra `sage_inbox` is
    /// another message taken from the daemon by a process about to exit.
    func testTheInboxIsReadExactlyOnce() throws {
        let run = try runCheckAgainstAClaimingNode()

        XCTAssertEqual(run.exitCode, 0, "check failed outright:\n\(run.output)")
        XCTAssertEqual(
            run.inboxCalls, 1,
            "check called sage_inbox \(run.inboxCalls) time(s). Every call claims what it "
                + "returns, durably and for this short-lived session, so a second one both "
                + "contradicts the first and strands whatever it took.\n\(run.output)"
        )
    }

    /// The summary and the verdict are made of the same read, so they cannot
    /// disagree.
    func testAWaitingMessageIsBothCountedAndAnnounced() throws {
        let run = try runCheckAgainstAClaimingNode()

        XCTAssertTrue(
            run.output.contains("inbox: 1 waiting"),
            "the node offered one message and the summary did not see it:\n\(run.output)"
        )
        XCTAssertFalse(
            run.output.contains("it would say nothing"),
            "check counted a waiting message and then denied it — the 17 August "
                + "contradiction, verbatim:\n\(run.output)"
        )
        XCTAssertTrue(
            run.output.contains("it would say:"),
            "no rehearsal verdict at all:\n\(run.output)"
        )
        XCTAssertTrue(
            run.output.contains("Mynah STUDIO"),
            "the verdict did not name the sender the summary listed:\n\(run.output)"
        )
    }

    /// The command admits what running it costs, and names the way round it.
    ///
    /// `sage_inbox` has no passive mode — its whole input schema is
    /// `{include_replies, limit, reply_since, reply_limit}` — so the one
    /// remaining read still claims. A tool that hides that is the silent-failure
    /// class this project treats as its worst, and a warning with no door out is
    /// only half a warning: `sage_message_history(folder: "inbox")` is the
    /// non-claiming read, and it has to be on screen.
    func testCheckNamesItsOwnSideEffect() throws {
        let run = try runCheckAgainstAClaimingNode()

        XCTAssertTrue(
            run.output.contains("claims"),
            "check never told the owner that reading the inbox claims it:\n\(run.output)"
        )
        XCTAssertTrue(
            run.output.contains("sage_message_history(folder: \"inbox\")"),
            "the warning named no alternative, so it dead-ends:\n\(run.output)"
        )
    }

    // MARK: - Work this appliance may not take

    /// **The state 17 August left behind — and the state the broken version of
    /// this very command creates.**
    ///
    /// The message was real, it was there all day, and it was held under a
    /// claim taken by another session, so this appliance could not take it. The
    /// node says so in `claimed_elsewhere_count`. Every layer underneath now
    /// carries that scalar, and the wrapper this command puts in front of the
    /// source drops it back to `.notReported` unless it forwards
    /// `waitingInbox` — the protocol's default compiles perfectly and silently
    /// prints "0 waiting", which is what a healthy quiet inbox prints too. Two
    /// opposite states, one sentence, in the tool built to tell them apart.
    func testWorkHeldByAnotherSessionIsNamedAndNotReadAsAQuietInbox() throws {
        let run = try runCheck(against: Self.heldElsewhereNodeScript)

        XCTAssertEqual(run.exitCode, 0, "check failed outright:\n\(run.output)")
        XCTAssertTrue(
            run.output.contains("inbox: 0 waiting; 1 held by another session"),
            "the node reported a message held elsewhere and the summary printed a bare "
                + "zero — 17 August, relocated into the support tool:\n\(run.output)"
        )
        XCTAssertEqual(
            run.inboxCalls, 1,
            "the read is still exactly one claim:\n\(run.output)"
        )
    }

    /// The verdict stays "nothing", and stops being unexplained.
    ///
    /// Nothing is announced, which is correct — this appliance will not break
    /// another session's claim, so a held message is not news for the owner's
    /// phone. What was missing is the reason beside it, and the next action:
    /// the rows are readable without claiming, and the claim ends by completion
    /// or by a handoff a *person* decides on. SAGE's guidance is to judge the
    /// prior claimant dead first and this appliance has no basis for that.
    func testTheSilentVerdictComesWithItsReasonAndADoor() throws {
        let run = try runCheck(against: Self.heldElsewhereNodeScript)

        XCTAssertTrue(
            run.output.contains("it would say nothing"),
            "a message this appliance cannot take must not be announced:\n\(run.output)"
        )
        XCTAssertTrue(
            run.output.contains("will not break the claim"),
            "the tool reported a held message without saying it declines to act:\n\(run.output)"
        )
        XCTAssertTrue(
            run.output.contains("sage_message_history(folder: \"inbox\")"),
            "no way to read the held message, so the report dead-ends:\n\(run.output)"
        )
        XCTAssertTrue(
            run.output.contains("sage_message_handoff"),
            "no way for the claim to ever clear, which is a wall and not a door:"
                + "\n\(run.output)"
        )
    }

    /// **The line `bridge.log` would have carried, proved through the wiring
    /// this command actually builds.**
    ///
    /// `ProactiveWatch` composes "[watch] inbox: N waiting; N held by another
    /// session" and hands it to `ProactiveSource.note`, whose default is
    /// silence. So this one assertion fails if the wrapper forgets to forward
    /// `note`, if it forgets to forward `waitingInbox` (the clause vanishes),
    /// or if the source underneath is built without a log sink — the three ways
    /// this fix can ship inert, in one string.
    func testTheDaemonsOwnLogLineIsShownWithTheClauseIntact() throws {
        let run = try runCheck(against: Self.heldElsewhereNodeScript)

        XCTAssertTrue(
            run.output.contains("[watch] inbox: 0 waiting; 1 held by another session"),
            "the watch's line reached nothing — which is the shape of the original "
                + "defect, one layer further out:\n\(run.output)"
        )
    }

    // MARK: The run

    private struct CheckRun {
        let output: String
        let exitCode: Int32
        let inboxCalls: Int
    }

    private func runCheckAgainstAClaimingNode() throws -> CheckRun {
        try runCheck(against: Self.claimingNodeScript)
    }

    private func runCheck(against script: String) throws -> CheckRun {
        let binary = try sageVoiced()
        let node = directory.appendingPathComponent("sage-gui")
        let calls = directory.appendingPathComponent("calls.log")
        let claimed = directory.appendingPathComponent("claimed")

        try script.write(to: node, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: node.path
        )

        let process = Process()
        process.executableURL = binary
        process.arguments = ["check", "--sage", node.path]
        var environment = ProcessInfo.processInfo.environment
        environment["MYNAH_STUB_LOG"] = calls.path
        environment["MYNAH_STUB_CLAIMED"] = claimed.path
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        // A wedged handshake would otherwise sit here for `MCPClient`'s
        // ninety-second request timeout, three times over, and a test that hangs
        // gets diagnosed as slow CI rather than as a failure.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        let log = (try? String(contentsOf: calls, encoding: .utf8)) ?? ""
        return CheckRun(
            output: String(decoding: data, as: UTF8.self),
            exitCode: process.terminationStatus,
            inboxCalls: log.split(separator: "\n").filter { $0 == "sage_inbox" }.count
        )
    }

    /// The command under test, beside this bundle.
    ///
    /// Absent means it was not built, which is not a pass — the whole point of
    /// this file is that the fault lived in the executable. Failing here names
    /// the command that fixes it rather than leaving a green run that tested
    /// nothing.
    private func sageVoiced() throws -> URL {
        let binary = Bundle(for: type(of: self)).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("sage-voiced")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            XCTFail("sage-voiced is not at \(binary.path) — run `swift build` before `swift test`.")
            throw XCTSkip("sage-voiced not built")
        }
        return binary
    }

    /// A node that speaks just enough MCP, and claims the way SAGE 11.18.18
    /// claims.
    private static let claimingNodeScript = #"""
    #!/bin/bash
    # Fake SAGE node for CheckReadsTheInboxOnceTests. Answers `initialize`,
    # `sage_inbox` and `sage_backlog`, logs every tool call, and — the point of
    # the exercise — hands a claimed row back only under `own_claimed_unfinished`.
    log="$MYNAH_STUB_LOG"
    claimed="$MYNAH_STUB_CLAIMED"
    while IFS= read -r line; do
      id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
      case "$line" in
        *'"method":"initialize"'*)
          printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2024-11-05","capabilities":{},"serverInfo":{"name":"stub-sage","version":"11.18.18"}}}\n' "$id"
          ;;
        *'"sage_inbox"'*)
          printf 'sage_inbox\n' >> "$log"
          if [ -f "$claimed" ]; then
            printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"{\\"count\\":0,\\"items\\":[],\\"own_claimed_unfinished\\":[{\\"message_id\\":\\"msg-federated-1\\",\\"already_claimed_by_you\\":true}],\\"claimed_elsewhere_count\\":0}"}]}}\n' "$id"
          else
            : > "$claimed"
            printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"{\\"count\\":1,\\"items\\":[{\\"message_id\\":\\"msg-federated-1\\",\\"from\\":\\"Mynah STUDIO\\",\\"payload\\":\\"the federated one\\",\\"requires_reply\\":true,\\"sender_agent\\":\\"366bf98c\\",\\"source_chain_id\\":\\"\\"}]}"}]}}\n' "$id"
          fi
          ;;
        *'"sage_backlog"'*)
          printf 'sage_backlog\n' >> "$log"
          printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"{\\"tasks_by_domain\\":{}}"}]}}\n' "$id"
          ;;
        *'"id"'*)
          printf '{"jsonrpc":"2.0","id":%s,"result":{}}\n' "$id"
          ;;
      esac
    done

    """#

    /// A node in the post-incident state: nothing claimable, and something
    /// there.
    ///
    /// The exact shape SAGE returns once a row is held by a session other than
    /// the caller's — `count` and `items` empty, because neither ever counts
    /// work the caller may not take, and the fact itself in
    /// `claimed_elsewhere_count`. Its state word is carried too, and is one the
    /// parser must *not* read as a failed probe: the node looked and answered.
    private static let heldElsewhereNodeScript = #"""
    #!/bin/bash
    # Fake SAGE node for CheckReadsTheInboxOnceTests: a message exists for this
    # appliance and another session holds it, so there is nothing to hand back.
    log="$MYNAH_STUB_LOG"
    while IFS= read -r line; do
      id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
      case "$line" in
        *'"method":"initialize"'*)
          printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2024-11-05","capabilities":{},"serverInfo":{"name":"stub-sage","version":"11.18.18"}}}\n' "$id"
          ;;
        *'"sage_inbox"'*)
          printf 'sage_inbox\n' >> "$log"
          printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"{\\"count\\":0,\\"items\\":[],\\"claimed_elsewhere_count\\":1,\\"claimed_elsewhere_state\\":\\"claimed_unfinished\\",\\"coordination_schema\\":\\"sage.inbox.v2\\"}"}]}}\n' "$id"
          ;;
        *'"sage_backlog"'*)
          printf 'sage_backlog\n' >> "$log"
          printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"{\\"tasks_by_domain\\":{}}"}]}}\n' "$id"
          ;;
        *'"id"'*)
          printf '{"jsonrpc":"2.0","id":%s,"result":{}}\n' "$id"
          ;;
      esac
    done

    """#
}
