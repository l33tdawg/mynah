import XCTest
@testable import SageVoiceCore

/// **That the node's vocabulary stays out of the owner's face.**
///
/// The Agents page showed this, verbatim, to somebody who is not a programmer:
///
///     Your SAGE node wouldn't send that. MCP tool 'sage_inbox' failed: Error:
///     pipeline inbox: Active agent required: agent pipeline work is available
///     only to an active ordinary agent on this SAGE.
///
/// Every word accurate, none of it usable. The owner's verdict on the page was
/// that it "says wayyyyyyy too much nonsense the user doesn't need to know
/// about", and a pasted MCP error is the purest form of that.
///
/// There was no test on this path at all, which is how it shipped: the sentence
/// was assembled by string interpolation in an `errorDescription`, and nothing
/// ever asserted what came out.
final class AgentMessagingRefusalTests: XCTestCase {

    /// The refusal that actually happens on a fresh install, and the only one
    /// with a known cause: SAGE will not give pipeline work to a restricted
    /// appliance.
    ///
    /// It has to name the same cause and the same fix as the warning on the
    /// Agents page. One problem described in two vocabularies reads as two
    /// problems, and the owner cannot tell that fixing one fixes both.
    func testTheRestrictedApplianceRefusalIsExplainedNotQuoted() {
        let raw = "MCP tool 'sage_inbox' failed: Error: pipeline inbox: Active agent required: "
            + "agent pipeline work is available only to an active ordinary agent on this SAGE."
        let sentence = AgentMessagingTrouble.refused(raw).errorDescription ?? ""

        XCTAssertTrue(
            sentence.contains("its own memory"),
            "the refusal does not name the cause the owner can act on: \(sentence)"
        )
        XCTAssertTrue(
            sentence.lowercased().contains("administrator"),
            "the refusal does not say who has to fix it: \(sentence)"
        )
        for leak in ["MCP", "sage_inbox", "Error:", "pipeline inbox", "ordinary agent"] {
            XCTAssertFalse(
                sentence.contains(leak),
                "\(leak.debugDescription) leaked into what the owner reads: \(sentence)"
            )
        }
    }

    /// A refusal nobody has seen yet still must not paste the node's words. The
    /// generic sentence says what happened and what did not happen — nothing was
    /// sent — which is the part the owner needs either way.
    func testAnUnrecognisedRefusalIsStillNotQuoted() {
        let sentence = AgentMessagingTrouble
            .refused("Error: some future internal condition nobody has met yet")
            .errorDescription ?? ""

        XCTAssertFalse(sentence.contains("Error:"), "raw text leaked: \(sentence)")
        XCTAssertFalse(sentence.contains("internal condition"), "raw text leaked: \(sentence)")
        XCTAssertTrue(sentence.lowercased().contains("nothing was sent"))
    }

    /// The node's own words are not discarded — they move. An administrator
    /// acting on this needs them, and the disclosure on the Agents page is where
    /// a node's internal vocabulary belongs.
    func testTheNodesOwnWordsSurviveForTheAdministrator() {
        let raw = "pipeline inbox: Active agent required"
        XCTAssertEqual(AgentMessagingTrouble.refused(raw).technicalDetail, raw)
        XCTAssertEqual(
            AgentMessagingTrouble.unreachable(name: "codex", why: "stale registration").technicalDetail,
            "stale registration"
        )
    }

    /// Nothing to disclose where the node said nothing. A disclosure containing
    /// an empty box is worse than no disclosure.
    func testTroublesWithNothingToDiscloseSaySo() {
        XCTAssertNil(AgentMessagingTrouble.noSuchAgent(name: "nobody").technicalDetail)
        XCTAssertNil(AgentMessagingTrouble.nodeUnavailable.technicalDetail)
        XCTAssertNil(
            AgentMessagingTrouble.ambiguousName(name: "c", candidates: ["a", "b"]).technicalDetail
        )
    }

    /// The three troubles that were already owner-facing keep their sentences.
    /// This change was meant to fix one case, not rewrite the others.
    func testTheAlreadyReadableTroublesAreUnchanged() {
        XCTAssertTrue(
            (AgentMessagingTrouble.noSuchAgent(name: "codex").errorDescription ?? "")
                .contains("No agent called “codex”")
        )
        XCTAssertTrue(
            (AgentMessagingTrouble.nodeUnavailable.errorDescription ?? "")
                .contains("can't reach your SAGE node")
        )
    }
}
