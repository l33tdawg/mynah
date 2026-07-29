import XCTest
@testable import SageVoiceCore

/// **The 12-utterance routing set, written down at last.**
///
/// The numbers in `BrainPrompts.voiceToolAllowlist` — *27 tools = 5–6/12,
/// 14 tools = 12/12* — have been quoted all week to justify curating the voice
/// tool catalogue, and the set that produced them existed only as something
/// somebody ran once. A number nobody can re-run is not evidence; it is a
/// rumour with a decimal point. This file is that set, so the claim can be
/// checked instead of cited.
///
/// ## It matters because there is a second measurement, and they disagree
///
/// Recorded on the Mac mini on 2026-07-27, against real MCP schemas:
///
/// > *routing does NOT degrade with tool count: 10 tools = 91%, 22 tools = 91%
/// > (+0.26 s latency). No need to curate the SAGE tool set for the voice brain.*
///
/// One says catalogue size is the dominant factor in routing accuracy. The
/// other says it is not a factor at all, and explicitly concludes the opposite
/// of the comment we have been acting on. **A feature was declined on the
/// weaker of the two** — the roster tool was held at 18→19 on the strength of a
/// number that cannot be reproduced, against one that was written down with its
/// conditions.
///
/// ## The most likely reconciliation, and why it is now urgent
///
/// The two runs used different brains. `BrainPrompts` says *"measured on
/// qwen3.5:4b"* — a 4B model running locally. The Mac mini figures do not name
/// a model, but 91% at 22 tools is not 4B behaviour.
///
/// If tool-count sensitivity is a small-model property, both measurements are
/// true and neither generalises: the allowlist is load-bearing for the **fully
/// local** option and pointless for every cloud provider. That question has
/// just become live, because every provider now offered in setup is a cloud one
/// — so the curation may be protecting a brain almost nobody is running while
/// costing capability for everybody else.
///
/// **Do not resolve this by argument.** Run the set on both.
///
/// ## Running it
///
/// These cases are data, not assertions — nothing here calls a model, because a
/// unit test that needs a live brain and a running MCP server is a test that
/// gets disabled. Drive them from a harness that has both:
///
///   1. Build the backend under test and compose the tool catalogue at the size
///      being measured (`BrainPrompts.voiceToolAllowlist` for the curated set,
///      the unfiltered `tools/list` for the full one).
///   2. Send each `utterance` as a single user turn, temperature 0, no history.
///   3. Score `expected` against the tool actually called — **name only**. Do
///      not score arguments; this measures routing, not argument quality, and
///      conflating them is how a 12/12 becomes unreproducible.
///   4. Report `n/12` with the model, the tool count, and the date.
///
/// Record the result in `docs/MODEL-CHOICES.md` next to the latency figures,
/// with those three facts. A score without them is how we got here.
enum VoiceRoutingUtterances {

    struct Case: Sendable {
        /// What the owner says, verbatim.
        let utterance: String
        /// The tool that must be called, or `nil` when the right answer is to
        /// call nothing and just reply.
        let expected: String?
        /// Why this case is in the set — the failure it is here to catch.
        let rationale: String
    }

    /// Twelve, deliberately: this is the size the quoted numbers refer to, so a
    /// re-run is comparable to them rather than a fresh measurement that cannot
    /// settle the disagreement.
    ///
    /// Composition is not accidental. Nine cases expect a specific tool across
    /// the distinct families a voice turn actually reaches — memory, tasks,
    /// notes, search, agents. Three expect **no tool at all**, because the
    /// failure mode that curation was introduced to fix was over-triggering:
    /// the model reaching for a generic browse-style tool for every question.
    /// A set of twelve tool-calling utterances would score 12/12 on a model that
    /// calls a tool for "thanks, that's all", which is precisely the broken
    /// behaviour.
    static let all: [Case] = [
        Case(
            utterance: "What did we decide about the DMG signing thing?",
            expected: "sage_recall",
            rationale: "Recall by topic. The commonest voice turn there is."
        ),
        Case(
            utterance: "Remember that the Apple account for this is l33tdawg at hackinthebox dot org.",
            expected: "sage_remember",
            rationale: "Storing a fact. Must not be confused with recall."
        ),
        Case(
            utterance: "What's on my plate?",
            expected: "sage_backlog",
            rationale: "Idiomatic, not literal — no word here matches a tool name."
        ),
        Case(
            utterance: "Add a task to measure time to first token on DeepSeek.",
            expected: "sage_task",
            rationale: "Creating work, adjacent to backlog and easily confused with it."
        ),
        Case(
            utterance: "What have I been working on this week?",
            expected: "sage_timeline",
            rationale: "Time-scoped. The classic pull towards a generic browse tool."
        ),
        Case(
            utterance: "Make a note called shopping list — milk, bread, coffee.",
            expected: "write_note",
            rationale: "A note is not a memory. These two collapse into each other under pressure."
        ),
        Case(
            utterance: "What notes do I have?",
            expected: "list_notes",
            rationale: "Distinguishes listing from reading, the pair flagged as collapsible."
        ),
        Case(
            utterance: "What's the weather in Kuala Lumpur tomorrow?",
            expected: "web_search",
            rationale: "Outside SAGE entirely. Reaching for a SAGE tool here is the failure."
        ),
        Case(
            utterance: "Is anything waiting for me from the other agents?",
            expected: "sage_inbox",
            rationale: "Agent-to-agent. Sits near find_agent and federation."
        ),

        // The three that must call nothing.
        Case(
            utterance: "Thanks bro, that's all.",
            expected: nil,
            rationale: "Sign-off. A tool call here is pure over-trigger."
        ),
        Case(
            utterance: "How are you doing today?",
            expected: nil,
            rationale: "Pleasantry. Tempting for a status tool, and wrong."
        ),
        Case(
            utterance: "Can you say that again but shorter?",
            expected: nil,
            rationale: "Refers to the reply just given. Needs conversation, not retrieval."
        )
    ]
}

/// Properties of the set itself, so the fixture cannot rot unnoticed.
///
/// These do not measure routing — nothing here talks to a model. They keep the
/// set honest, which is the part that failed last time: the numbers survived and
/// the thing they were measured against did not.
final class VoiceRoutingUtteranceSetTests: XCTestCase {

    func testTheSetIsTwelveSoARerunIsComparableToTheQuotedNumbers() {
        XCTAssertEqual(VoiceRoutingUtterances.all.count, 12)
    }

    /// A set that only contains tool-calling utterances cannot detect
    /// over-triggering, which is the failure curation exists to prevent.
    func testTheSetContainsUtterancesThatMustCallNothing() {
        let silent = VoiceRoutingUtterances.all.filter { $0.expected == nil }
        XCTAssertEqual(silent.count, 3, "a set with no negative cases scores a broken model 12/12")
    }

    /// Every expected tool must survive the voice allowlist, or the case is
    /// unscoreable against the curated catalogue — it would fail for the trivial
    /// reason that the model was never shown the tool.
    func testEveryExpectedToolIsActuallyOfferedToTheVoiceBrain() {
        for testCase in VoiceRoutingUtterances.all {
            guard let expected = testCase.expected else { continue }
            XCTAssertTrue(
                BrainPrompts.voiceToolAllowlist.contains(expected),
                "'\(expected)' is expected by an utterance but filtered out of the voice catalogue"
            )
        }
    }

    /// Distinct tools, so the score measures breadth rather than one family
    /// answered nine times.
    func testTheExpectedToolsAreDistinct() {
        let expected = VoiceRoutingUtterances.all.compactMap(\.expected)
        XCTAssertEqual(Set(expected).count, expected.count, "a repeated tool narrows what 12/12 proves")
    }

    /// Every case says what it is for. The set has to survive somebody deciding
    /// a case looks redundant.
    func testEveryCaseCarriesItsRationale() {
        for testCase in VoiceRoutingUtterances.all {
            XCTAssertFalse(testCase.rationale.isEmpty, "'\(testCase.utterance)' has no stated purpose")
            XCTAssertFalse(testCase.utterance.isEmpty)
        }
    }
}
