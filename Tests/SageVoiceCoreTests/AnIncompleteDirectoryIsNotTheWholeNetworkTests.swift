import XCTest
@testable import SageVoiceCore

/// **The third instance of one rule, and the first one caught by someone else.**
///
/// 1.8.3: a backlog read turned a failure into an empty list and emptied the
/// owner's calendar. 1.8.5: the inbox read did the same and made the watch
/// forget what it had announced. This is the same rule at the prompt layer —
/// asked *"can you see other agents on the network?"*, Mynah called
/// `sage_directory` with its default `local` scope, listed seventeen local
/// agents and answered **"No federated SAGEs connected"**, while a federated
/// MYNAH sat on STUDIO-MACMINI. Reported by codex on the SAGE team, reproduced
/// live by the owner, confirmed here.
///
/// The prompt half is in `BrainPrompts` and pinned by
/// `AgentEnumerationHonestyTests`: always pass `{"scope":"all"}`, and say so
/// when the reply is incomplete.
///
/// **This file is the half that makes the prompt half possible.** SAGE emits
/// `complete`, `total` and `warnings` *after* the unbounded `agents` array —
/// byte 9,525 of a 9,977-byte reply, measured against the live node on 7
/// August. `VoiceToolBudget.fit` keeps the head, and a directory result gets
/// 2,000 bytes on the on-device brain. So the fields the prompt now depends on
/// fell off the end at around five agents, and the owner has seventeen. A rule
/// telling the model to report `complete: false` is decorative if the model is
/// never shown it.
final class AnIncompleteDirectoryIsNotTheWholeNetworkTests: XCTestCase {

    private var allowance: Int {
        VoiceToolBudget.budget(forTool: "sage_directory", brain: .onDevice)
    }

    // MARK: - The property

    func testTheIncompletenessSurvivesTheBudget() throws {
        let reply = directory(agents: 17, complete: false, warnings: [Self.warning])
        XCTAssertGreaterThan(
            reply.utf8.count, allowance,
            "the payload has to exceed the budget or this test proves nothing"
        )

        let fitted = VoiceToolBudget.fit(reply, tool: "sage_directory", brain: .onDevice)

        XCTAssertTrue(
            fitted.contains("\"complete\": false"),
            "the model cannot say the list is partial if it never sees this: \(fitted)"
        )
        XCTAssertTrue(
            fitted.contains("best effort"),
            "the warning explaining WHY it is partial is gone: \(fitted)"
        )
        XCTAssertTrue(fitted.contains("\"total\": 17"), fitted)
    }

    /// **The counterfactual, so the test above cannot pass for the wrong
    /// reason.** This is what the generic path did, at the same allowance. If
    /// this ever stops failing to keep `complete`, the fix has become a no-op
    /// and the test above is guarding nothing.
    func testAPlainHeadTruncationLosesExactlyThoseFields() {
        let reply = directory(agents: 17, complete: false, warnings: [Self.warning])
        let head = String(decoding: reply.utf8.prefix(allowance), as: UTF8.self)

        XCTAssertFalse(
            head.contains("\"complete\""),
            "if the head keeps this, the bug this file exists for cannot happen"
        )
        XCTAssertFalse(head.contains("\"warnings\""))
        XCTAssertFalse(head.contains("\"total\""))
    }

    /// A partial list has to *announce* that it is partial, in the reply itself
    /// — the model is not expected to compare two numbers and infer it.
    func testAPartialListSaysSoAndStatesBothNumbers() {
        let fitted = VoiceToolBudget.fit(
            directory(agents: 17, complete: false, warnings: [Self.warning]),
            tool: "sage_directory", brain: .onDevice
        )
        XCTAssertTrue(fitted.contains("this list is incomplete, say so"), fitted)
        XCTAssertTrue(fitted.contains("of 17"), fitted)
    }

    // MARK: - The session preamble

    /// SAGE prepends `[SAGE Auto-Connect]` operating instructions to the
    /// **first** tool result of a session: 2,918 bytes ahead of this tool's
    /// JSON, measured, and absent on every later call. Against a 2,000-byte
    /// budget the generic path hands the model pure boilerplate and *zero*
    /// agents — and `warmUpProbe` is deliberately tool-free, so the call that
    /// pays is the first real one the owner asks for.
    func testTheSessionPreambleDoesNotEatTheAnswer() {
        let reply = Self.preamble + directory(agents: 17, complete: false, warnings: [])
        let fitted = VoiceToolBudget.fit(reply, tool: "sage_directory", brain: .onDevice)

        XCTAssertFalse(
            fitted.contains("SAGE Auto-Connect"),
            "the preamble is spending the owner's budget on boilerplate"
        )
        XCTAssertTrue(fitted.contains("agent-0"), "no agents survived at all: \(fitted)")
        XCTAssertTrue(fitted.contains("\"complete\": false"), fitted)
    }

    /// The same preamble, against the un-fixed path, at the same budget.
    func testThePreamblePreviouslyLeftNoAgentsAtAll() {
        let reply = Self.preamble + directory(agents: 17, complete: false, warnings: [])
        let head = String(decoding: reply.utf8.prefix(allowance), as: UTF8.self)
        XCTAssertFalse(
            head.contains("\"agent_id\""),
            "if a row fits, the preamble is no longer the problem this test describes"
        )
    }

    // MARK: - What a row may lose

    /// `name` repeats `display_name` and `to` repeats `agent_id` in every row
    /// the live node sent, and an `agent_id` is 64 characters — so the repeat is
    /// most of the row. It is dropped **only when the values are literally
    /// equal**, never by name.
    func testARowDropsOnlyLiteralRepeats() throws {
        let reply = """
        {"agents": [{"agent_id": "aaa", "display_name": "Perplexity", \
        "name": "Perplexity", "provider": "perplexity", "scope": "local", \
        "status": "active", "to": "aaa"}], "complete": true, "scope": "all", \
        "total": 1, "warnings": []}
        """
        let fitted = try XCTUnwrap(VoiceToolBudget.fitDirectory(reply, allowance: 40))
        XCTAssertTrue(fitted.contains("Perplexity"))
        XCTAssertEqual(
            fitted.components(separatedBy: "Perplexity").count - 1, 1,
            "the duplicated display name is still being paid for twice: \(fitted)"
        )
    }

    /// **The case the equality rule exists for.** A federated recipient whose
    /// `to` is a routed address that differs from its `agent_id` must keep both,
    /// or it becomes unaddressable — which would be a worse bug than the one
    /// being fixed, introduced by the fix.
    func testAFederatedRowKeepsBothAddressesWhenTheyDiffer() throws {
        let reply = """
        {"agents": [{"agent_id": "bbb", "display_name": "MYNAH", "name": "MYNAH", \
        "provider": "audit", "scope": "federated", "status": "active", \
        "to": "#studio-macmini/MYNAH"}], "complete": false, "scope": "all", \
        "total": 1, "warnings": []}
        """
        let fitted = try XCTUnwrap(VoiceToolBudget.fitDirectory(reply, allowance: 40))
        XCTAssertTrue(fitted.contains("\"bbb\""), fitted)
        XCTAssertTrue(
            fitted.contains("#studio-macmini/MYNAH"),
            "the routed address was dropped as a duplicate and the agent cannot be reached: \(fitted)"
        )
        XCTAssertTrue(
            fitted.contains("federated"),
            "scope is how the model says which of these are on other machines"
        )
    }

    // MARK: - Not everything is a directory

    func testANonDirectoryReplyIsLeftToTheGenericPath() {
        XCTAssertNil(VoiceToolBudget.fitDirectory(#"{"total_memories": 13000}"#, allowance: 10))
        XCTAssertNil(VoiceToolBudget.fitDirectory("Error: node is starting up", allowance: 10))
        XCTAssertNil(VoiceToolBudget.fitDirectory(#"{"agents": "not a list"}"#, allowance: 10))
    }

    /// A directory that fits is handed over untouched — no note, no reshaping,
    /// nothing for the model to misread as a caveat.
    func testADirectoryUnderBudgetIsNotTouched() {
        let reply = directory(agents: 1, complete: true, warnings: [])
        XCTAssertEqual(
            VoiceToolBudget.fit(reply, tool: "sage_directory", brain: .onDevice), reply
        )
    }

    /// **Complete must stay complete.** Mistaking a whole list for a partial one
    /// is the opposite failure, and it would teach the owner to distrust an
    /// answer that was right.
    func testACompleteDirectoryIsNeverCalledIncomplete() {
        let fitted = VoiceToolBudget.fit(
            directory(agents: 17, complete: true, warnings: []),
            tool: "sage_directory", brain: .onDevice
        )
        XCTAssertTrue(fitted.contains("\"complete\": true"), fitted)
        XCTAssertFalse(
            fitted.contains("\"warnings\""),
            "an empty warnings list is noise, and noise gets spoken aloud"
        )
    }

    // MARK: - Fixtures, shaped like the live node's reply

    private static let warning = "Federated recipient enumeration is best effort; "
        + "peers without the negotiated safe-directory capability are omitted."

    /// What was measured against the live node on 7 August: the preamble ahead
    /// of `sage_directory`'s JSON on the first tool call of a session.
    private static let measuredPreambleBytes = 2_918

    /// Abridged from the real thing and then **padded back to the length that
    /// was measured**, because here the length is the whole claim.
    ///
    /// The first draft of this file said "the length is what matters" and then
    /// shipped 622 bytes of it, so a row fitted inside the 2,000-byte head and
    /// `testThePreamblePreviouslyLeftNoAgentsAtAll` failed. That test earning
    /// its place on the day it was written is the reason it is still here.
    private static var preamble: String {
        let block = """
        [SAGE Auto-Connect] Your persistent memory is online.

        You have persistent institutional memory via SAGE — governed by consensus, \
        not a flat file.

        EVERY TURN: Call sage_turn with the current topic + observation of what \
        happened. This recalls relevant committed memories AND stores your episodic \
        observation in one atomic operation.

        DOMAINS ARE DYNAMIC: Create domains organically based on what you are working \
        on. Specific domains mean better recall. Do not dump everything into general.

        FEEDBACK LOOP: After significant tasks, call sage_reflect with dos and don'ts.

        """
        var text = block
        while text.utf8.count < measuredPreambleBytes { text += block }
        return text
    }

    /// Key order matches the live reply: `agents` first and unbounded, every
    /// field that qualifies it afterwards. That ordering *is* the bug.
    private func directory(agents count: Int, complete: Bool, warnings: [String]) -> String {
        let rows = (0..<count).map { index in
            let id = String(repeating: String(index % 10), count: 64)
            return """
                {
                  "agent_id": "\(id)",
                  "display_name": "agent-\(index)",
                  "name": "agent-\(index)",
                  "provider": "claude-code",
                  "registered_name": "claude-code/agent-\(index)",
                  "scope": "local",
                  "status": "active",
                  "to": "\(id)"
                }
            """
        }
        let warningList = warnings.map { "\"\($0)\"" }.joined(separator: ", ")
        return """
        {
          "agents": [
        \(rows.joined(separator: ",\n"))
          ],
          "complete": \(complete),
          "message": "Caller-authorized recipient directory. Pass an agent's exact to value \
        to sage_pipe. Membership proves neither presence nor delivery.",
          "next_peer_cursor": "",
          "scope": "all",
          "total": \(count),
          "warnings": [\(warningList)]
        }
        """
    }
}
