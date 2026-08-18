import XCTest
@testable import SageVoiceCore

/// **The 12-utterance routing set, written down at last.**
///
/// The numbers in `BrainPrompts.sageToolCuration` — *27 tools = 5–6/12,
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
/// ## Answered — 2026-07-29, and the hypothesis was backwards
///
/// The guess written here was that tool-count sensitivity is a *small-model*
/// property, so the allowlist would be load-bearing for the local option and
/// pointless for cloud. Run on two local brains with everything else fixed:
///
/// ```
///                14 tools (11,899 B)      27 tools (21,428 B)
/// qwen3.5:4b     9/12   5.9 s/turn        9/12   9.3 s/turn
/// gemma4:26b     9/12   8.7 s/turn        4/12   8.3 s/turn
/// ```
///
/// **The 4B is the one that shrugs it off.** The 26B collapses — and it does so
/// by over-triggering on exactly the utterances that should call nothing:
/// "thanks bro, that's all" → `sage_turn`, "good morning" → `sage_inception`.
/// All three negative cases pass at 14 tools and fail at 27.
///
/// So the effect is real, it is not a small-model artefact, and the direction
/// is the opposite of what was assumed here. High-generality tools act as
/// attractors: a tool plausible for *any* input wins whenever nothing else is a
/// strong match. `BrainPrompts.sageToolCuration` carries the full write-up.
///
/// Two things this does not settle. The original 5–6/12 figure still does not
/// reproduce on the model it names. And 4B and 26B are different families —
/// `gemma3:12b` would have made it a clean same-family sweep, but it cannot do
/// tool calling at all (`HTTP 400: does not support tools`), so the family
/// confound cannot be removed on this machine.
///
/// ## Running it
///
/// These cases are data, not assertions — nothing here calls a model, because a
/// unit test that needs a live brain and a running MCP server is a test that
/// gets disabled. Drive them from a harness that has both:
///
///   1. Build the backend under test and compose the tool catalogue at the size
///      being measured (`BrainPrompts.sageToolCuration` for the curated set,
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

    struct Case: Sendable, Decodable {
        /// What the owner says, verbatim.
        let utterance: String
        /// The tool that must be called, or `nil` when the right answer is to
        /// call nothing and just reply.
        let expected: String?
        /// Why this case is in the set — the failure it is here to catch.
        let rationale: String
    }

    /// Decoded from `Tests/Fixtures/voice-routing-utterances.json`, which
    /// `scripts/measure-tool-routing.py` reads too.
    ///
    /// **One file, deliberately.** These cases were briefly declared twice —
    /// here and in the harness — and the two copies had already drifted apart
    /// before anyone noticed, so the numbers in `BrainPrompts` described a set
    /// that was not the set checked in beside them. That is the same defect as
    /// `deepseek-chat` surviving in `BrainFactory` under a comment claiming it
    /// matched the daemon, and it would have quietly recreated the exact problem
    /// this whole exercise exists to fix: a measurement whose inputs are not the
    /// ones recorded.
    static let all: [Case] = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SageVoiceCoreTests
            .deletingLastPathComponent()   // Tests
            .appendingPathComponent("Fixtures/voice-routing-utterances.json")
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Fixture.self, from: data) else {
            return []
        }
        return decoded.cases
    }()

    private struct Fixture: Decodable { let cases: [Case] }
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

    /// Every expected tool must actually be offered, or the case is unscoreable
    /// against the curated catalogue — it would fail for the trivial reason
    /// that the model was never shown the tool.
    ///
    /// Against the composed catalogue rather than the SAGE curation, because an
    /// utterance may reasonably expect `web_search` or `write_note`, and
    /// neither is a SAGE tool.
    func testEveryExpectedToolIsActuallyOfferedToTheVoiceBrain() async throws {
        let offered = try await ComposedCatalogue.conversation()
        for testCase in VoiceRoutingUtterances.all {
            guard let expected = testCase.expected else { continue }
            XCTAssertTrue(
                offered.contains(expected),
                "'\(expected)' is expected by an utterance but never offered to the model"
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
