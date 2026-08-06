import XCTest
@testable import SageVoiceCore

/// **The sibling of the read that emptied the owner's calendar.**
///
/// `SageProactiveSource.openTasks` was fixed on 6 August, after a SAGE restart
/// made eleven dated tasks vanish from the owner's calendar for thirty-two
/// minutes. `SageAgentMessaging.inbox` coalesced in exactly the same way and was
/// left alone that night, deliberately, because it destroys nothing.
///
/// What it does instead: `ProactiveWatch.check` guards every ledger mutation
/// behind `if let messages`, under a comment insisting that a failed check "must
/// not *forget* anything either". An unreadable reply arrived as a **successful
/// empty list**, so the guard passed and `forgetMessagesNotIn(Set([]))` erased
/// the record of every message already announced. The next healthy check then
/// re-announced the whole inbox to the owner's phone.
///
/// The justification was *"an empty inbox and an unparseable one are the same to
/// a screen that has nothing to show"* — true on 29 July, when the Agents panel
/// was the only consumer. The panel was deleted on 30 July in `dc4e4f1`. The
/// sentence stayed for eight days and the test below asserted it.
final class InboxFailureIsNotAnEmptyInboxTests: XCTestCase {

    /// A node that answers, but not with an inbox: a restart, a rebuild, a
    /// refusal, a shape change. Success at the transport layer, which is what
    /// makes it dangerous — nothing throws.
    private struct AnswersWithoutAnInbox: ToolProviding {
        let reply: String
        func listTools() async throws -> [MCPTool] { [] }
        func call(name: String, arguments: [String: JSONValue]) async throws -> String { reply }
    }

    // MARK: - The read

    func testAnUnreadableReplyIsAFailureAndNotAnEmptyInbox() async {
        let source = SageProactiveSource(
            tools: AnswersWithoutAnInbox(reply: #"{"error":"node is starting up"}"#)
        )
        do {
            let waiting = try await source.waitingMessages(limit: 20)
            XCTFail("came back as \(waiting.count) item(s) instead of throwing")
        } catch {
            // The point.
        }
    }

    func testAnEmptyInboxStillReadsAsEmpty() async throws {
        let source = SageProactiveSource(
            tools: AnswersWithoutAnInbox(reply: #"{"count":0,"items":[],"message_count":0}"#)
        )
        let waiting = try await source.waitingMessages(limit: 20)
        XCTAssertEqual(waiting, [])
    }

    // MARK: - What it costs downstream, which is why any of this matters

    /// **The end-to-end property.** A failed look must reach the ledger as
    /// `nil`, and `nil` must not forget what the owner has already been told.
    func testAFailedLookDoesNotForgetWhatTheOwnerWasAlreadyTold() async {
        var ledger = ProactiveLedger()
        ledger.toldAboutMessages = ["m-1", "m-2"]

        let source = SageProactiveSource(
            tools: AnswersWithoutAnInbox(reply: #"{"error":"node is starting up"}"#)
        )
        // Exactly what ProactiveWatch.check does with it.
        let sawMessages = try? await source.waitingMessages(limit: 20)
        XCTAssertNil(sawMessages, "the read has to fail, or the rest of this proves nothing")

        var updated = ledger
        if let sawMessages {
            updated.forgetMessagesNotIn(Set(sawMessages.map(\.id)))
        }

        XCTAssertEqual(
            updated.toldAboutMessages, ["m-1", "m-2"],
            "a look that failed forgot \(ledger.toldAboutMessages.subtracting(updated.toldAboutMessages)) "
                + "— the owner gets told about them again on the next healthy check"
        )
    }

    /// The counterfactual, so the test above cannot pass for the wrong reason: a
    /// genuinely empty inbox *does* forget, which is correct — an item the node
    /// has dropped cannot arrive again — and is what made the bug invisible.
    func testAGenuinelyEmptyInboxDoesForget() async {
        var ledger = ProactiveLedger()
        ledger.toldAboutMessages = ["m-1", "m-2"]

        let source = SageProactiveSource(
            tools: AnswersWithoutAnInbox(reply: #"{"count":0,"items":[],"message_count":0}"#)
        )
        let sawMessages = try? await source.waitingMessages(limit: 20)
        XCTAssertNotNil(sawMessages)

        var updated = ledger
        if let sawMessages {
            updated.forgetMessagesNotIn(Set(sawMessages.map(\.id)))
        }

        XCTAssertTrue(
            updated.toldAboutMessages.isEmpty,
            "an empty inbox must still mean 'those are gone' — that is why the "
                + "manufactured empty was so dangerous"
        )
    }

    // MARK: - The log line

    /// A node that answers with something else leaves no trace anywhere else.
    /// This is the whole of the diagnosis next time.
    func testTheUnreadableReplyIsLogged() async {
        let said = Recorder()
        let source = SageProactiveSource(
            tools: AnswersWithoutAnInbox(reply: #"{"error":"node is starting up"}"#),
            log: { said.add($0) }
        )
        _ = try? await source.waitingMessages(limit: 20)

        // `first`, not `[0]`. Indexing here crashed the whole xctest process
        // when this was run against the un-fixed read — a failing assertion
        // above does not stop the line below, and one bad test then takes the
        // rest of the suite's results with it.
        let lines = said.lines
        XCTAssertEqual(lines.count, 1)
        let line = lines.first ?? ""
        XCTAssertTrue(line.contains("sage_inbox"), line)
        XCTAssertTrue(line.contains("node is starting up"), line)
        XCTAssertTrue(line.contains("changed nothing"), line)
    }

    /// A node that is simply unreachable already says so through `MCPClient`.
    /// Two lines for one event is how a log stops being read.
    func testAnUnreachableNodeIsNotLoggedTwice() async {
        struct Unreachable: ToolProviding {
            func listTools() async throws -> [MCPTool] { [] }
            func call(name: String, arguments: [String: JSONValue]) async throws -> String {
                throw AgentMessagingTrouble.nodeUnavailable
            }
        }
        let said = Recorder()
        let source = SageProactiveSource(tools: Unreachable(), log: { said.add($0) })
        _ = try? await source.waitingMessages(limit: 20)

        XCTAssertEqual(said.lines, [])
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
