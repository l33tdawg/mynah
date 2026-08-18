import XCTest
@testable import SageVoiceCore

/// Why a wake found nothing.
///
/// ## The gap this closes
///
/// `MessageWakeBus` tells the appliance that canonical inbox work was durably
/// inserted for it, `runProactiveWatch` logs *"the node says a message is
/// waiting; checking now"*, and then — until this — nothing. A wake that finds
/// an empty inbox has two ordinary causes and the log distinguished neither: the
/// work went to another runtime sharing this agent identity, or the node simply
/// has nothing to say about it.
///
/// ## Why this is an enum and not an `Int?`
///
/// `sage_inbox`'s own contract sentence is that *"claimed_elsewhere_count is an
/// exact payload-free scalar for unfinished work held by another session; an
/// unavailable probe is explicit and never presented as zero"*. The mechanism
/// is visible in the vendored node, which carries the field as a pointer:
/// `*struct { Count int "json:\"claimed_elsewhere_count\"" }`. A probe that
/// cannot run omits the key rather than sending `0`.
///
/// So `as? Int ?? 0` anywhere on this path turns *"I could not find out"* into
/// *"nothing is held elsewhere"* — this project's worst defect class, landing in
/// the one sentence whose whole job is telling those apart.
///
/// The keys are present in the **vendored** node as well as on the owner's live
/// one, so this is not a feature that only works on his Mac. Which SAGE release
/// introduced them could not be determined, and no version is asserted anywhere
/// in the code or the log line as a result.
final class ClaimedElsewhereTests: XCTestCase {

    /// The probe fields and the `message` sentence are as recorded from the
    /// owner's live 11.18.17 node while this was designed, in the envelope shape
    /// that release sends. The reading it describes is a real one and an
    /// awkward one: nothing unclaimed waiting, and one message held under
    /// somebody else's claim — the exact situation a wake cannot otherwise
    /// explain.
    private func captured() throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Fixtures/sage_inbox-11.18.17-claimed-elsewhere.json"),
            encoding: .utf8
        )
    }

    private func reading(_ reply: String) async throws -> AgentInboxReading {
        try await SageAgentMessaging(tools: OneReply(reply: reply)).inboxReading(limit: 20)
    }

    // MARK: - The three states

    func testAnExactCountIsRead() async throws {
        let read = try await reading(try captured())
        XCTAssertEqual(read.claimedElsewhere, .counted(1, state: "present"))
        XCTAssertTrue(read.items.isEmpty, "the captured reading has nothing unclaimed waiting")
    }

    /// **The central guard.** A state with no count is the node's pointer-nil
    /// shape: it looked, it could not answer, and it said so explicitly rather
    /// than sending a zero. Read as `.counted(0, …)` this becomes a confident
    /// "nothing is held elsewhere" that nobody measured.
    func testAnUnavailableProbeIsNeverZero() async throws {
        let read = try await reading("""
        {"count":0,"items":[],"claimed_elsewhere_state":"unavailable"}
        """)
        XCTAssertEqual(read.claimedElsewhere, .unavailable(state: "unavailable"))
        XCTAssertNotEqual(
            read.claimedElsewhere, .counted(0, state: "unavailable"),
            "a probe that could not answer was reported as a measured zero"
        )
    }

    /// A node that does not carry the probe at all is a third thing again —
    /// not a zero, and not a failed probe either. Nothing can be said about
    /// stranded claims from such a reply, and saying nothing is the honest
    /// outcome.
    func testANodeWithNoProbeIsNotACountOfNone() async throws {
        let read = try await reading(#"{"count":0,"items":[],"message_count":0}"#)
        XCTAssertEqual(read.claimedElsewhere, .notReported)
        XCTAssertNotEqual(read.claimedElsewhere, .counted(0, state: ""))
        XCTAssertNotEqual(read.claimedElsewhere, .unavailable(state: ""))
    }

    /// The state word is carried through untouched and never matched on. It has
    /// been observed with exactly one value; inventing a vocabulary on that
    /// evidence is how a reader ends up branching on a string the node renames.
    func testTheStateWordIsCarriedVerbatim() async throws {
        let read = try await reading("""
        {"items":[],"claimed_elsewhere_count":3,"claimed_elsewhere_state":"partial_scan"}
        """)
        XCTAssertEqual(read.claimedElsewhere, .counted(3, state: "partial_scan"))
    }

    // MARK: - The sentence

    /// Five facts, five sentences. Two of them collapsing into one is how the
    /// distinction dies quietly a release later.
    func testTheFourLogSentencesAreAllDifferent() {
        let sentences = [
            ClaimedElsewhere.forTheLog(.counted(1, state: "present")),
            ClaimedElsewhere.forTheLog(.counted(0, state: "present")),
            ClaimedElsewhere.forTheLog(.unavailable(state: "present")),
            ClaimedElsewhere.forTheLog(.notReported),
            ClaimedElsewhere.forTheLog(nil)
        ]
        XCTAssertEqual(Set(sentences).count, 5, sentences.joined(separator: "\n"))

        // The unavailable one must not read as a count of none, in either of
        // the two ways it could: a digit, or the word.
        let unavailable = ClaimedElsewhere.forTheLog(.unavailable(state: "present"))
        XCTAssertFalse(unavailable.contains("0"), unavailable)
        let words = unavailable.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        XCTAssertFalse(words.contains("no"), unavailable)
        XCTAssertTrue(unavailable.contains("not a count of zero"), unavailable)

        // And the counted-none one must, because that is the fact it carries.
        XCTAssertTrue(
            ClaimedElsewhere.forTheLog(.counted(0, state: "present"))
                .contains("no message held"),
            "the measured zero stopped saying it measured a zero"
        )
    }

    /// The count itself reaches the line — a sentence saying "some" would send
    /// the reader back to the node for the number.
    func testTheCountIsInTheSentence() {
        XCTAssertTrue(ClaimedElsewhere.forTheLog(.counted(4, state: "present")).contains("4"))
    }

    /// A reply with no state word must not print a dangling `(state: )`.
    func testAMissingStateLeavesNoEmptyBracket() {
        let line = ClaimedElsewhere.forTheLog(.counted(2, state: ""))
        XCTAssertFalse(line.contains("state:"), line)
        XCTAssertTrue(line.contains("2"), line)
    }

    /// **The node's own advice is deliberately not relayed.** It tells the
    /// reader to compare `claimant_session_id` values and consider
    /// `sage_message_handoff` — advice this appliance cannot follow, because it
    /// has no basis for judging another session dead, and prose that changes
    /// between releases besides.
    func testTheNodesOwnActionTextIsNotRepeatedBack() throws {
        let captured = try captured()
        XCTAssertTrue(captured.contains("sage_message_handoff"), "the fixture lost the action field")
        for sentence in [
            ClaimedElsewhere.forTheLog(.counted(1, state: "present")),
            ClaimedElsewhere.forTheLog(.unavailable(state: "present"))
        ] {
            XCTAssertFalse(sentence.contains("sage_message_handoff"), sentence)
            XCTAssertFalse(sentence.contains("claimant_session_id"), sentence)
        }
    }
}

/// A node that says one thing, whatever it is asked.
private struct OneReply: ToolProviding {
    let reply: String
    func listTools() async throws -> [MCPTool] { [] }
    func call(name: String, arguments: [String: JSONValue]) async throws -> String { reply }
}
