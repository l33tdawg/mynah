import XCTest
@testable import SageVoiceCore

/// SAGE's turn-discipline nudge, kept away from a model that cannot act on it.
///
/// The node **used to** append `[SAGE] ⚠️ You have not called sage_turn in N
/// tool calls (Mmin)…` to any tool result once five calls or five minutes had
/// passed without one. That was aimed at a coding agent driving its own turn
/// discipline.
///
/// **SAGE removed it at 11.16.1**, and 11.17.x says why in the source:
/// *"Session state is advisory only. MCP operations must never be blocked or
/// padded"* (`internal/mcp/server.go:412-413`). The appliance vendors 11.17.10
/// and will not see this suffix from a current node.
///
/// These stay green on purpose. `SageNodeChoice` runs whichever SAGE is
/// *installed* on the Mac rather than the vendored copy, so a machine sitting on
/// an older node still produces it — and the cost of tolerating a suffix that
/// never arrives is nothing, while the cost of a model reading an instruction it
/// cannot act on was measured. What is corrected here is the tense: this
/// describes a node behaviour that has been retired, not one to expect.
///
/// This appliance does not work that way: `SageRitual.recordTurn` calls
/// `sage_turn` from the daemon after every turn, precisely so the model never
/// has to — a 4B forgets the discipline three turns in, which is why `sage_turn`
/// is deliberately absent from `voiceToolAllowlist` and `SageRitualTests` says
/// so out loud.
///
/// The five-minute clause is what makes this near-certain rather than
/// occasional: an appliance whose whole job is to sit idle and then be wanted is
/// always more than five minutes past its last turn.
final class ServerNudgeTests: XCTestCase {

    /// The real shape, from server.go:512-514.
    private let nudged = """
    {
      "memories": [
        { "content": "Siam Modular, Chiang Mai" }
      ]
    }

    [SAGE] ⚠️ You have not called sage_turn in 1 tool calls (20min). Your experience \
    this session is NOT being recorded. Call sage_turn now, otherwise this work is lost.
    """

    func testTheNudgeIsRemoved() {
        let cleaned = ToolLoop.withoutServerNudge(nudged)
        XCTAssertFalse(cleaned.contains("[SAGE]"))
        XCTAssertFalse(cleaned.contains("sage_turn"), "the model is still told to call a tool it does not have")
    }

    /// The result itself has to survive intact — this runs on every SAGE tool
    /// call, and over-trimming would silently delete the owner's memories on the
    /// way back from a recall.
    func testTheActualResultSurvives() {
        let cleaned = ToolLoop.withoutServerNudge(nudged)
        XCTAssertTrue(cleaned.contains("Siam Modular, Chiang Mai"))
        XCTAssertTrue(cleaned.hasPrefix("{"), "the JSON body was damaged")
        XCTAssertTrue(cleaned.hasSuffix("}"), "the JSON body was truncated")
    }

    func testAnOrdinaryResultIsUntouched() {
        for result in [
            "{\n  \"memories\": []\n}",
            "Web search results for \"eurorack japan\".\n1. Festival of Modular\n   https://tfom.info/",
            "",
            "ok"
        ] {
            XCTAssertEqual(ToolLoop.withoutServerNudge(result), result)
        }
    }

    /// A memory whose text happens to mention the tool is not a nudge. Only the
    /// server's own marker is.
    func testAMemoryMentioningSageTurnIsNotMistakenForANudge() {
        let result = "{ \"content\": \"remember to call sage_turn every turn\" }"
        XCTAssertEqual(ToolLoop.withoutServerNudge(result), result)
    }

    /// The two halves of the decision have to stay consistent: the model is not
    /// given the tool, so it must not be told to use it.
    func testTheModelIsStillNotGivenTheTool() {
        XCTAssertFalse(
            BrainPrompts.voiceToolAllowlist.contains(SageRitual.Tool.turn),
            "if sage_turn is ever offered to the model, this stripping should be reconsidered"
        )
    }
}
