import XCTest
@testable import SageVoiceCore

/// The rules that make a stored memory reachable.
///
/// Semantic embeddings fixed *whether* the right memory comes back. They do
/// nothing about *whether the model looks*, and those are separate failures with
/// the same symptom. Measured on the appliance after the embedding switch, with
/// every shop already recallable in one call:
///
///     "write me a note listing every shop we discussed across Thailand,
///      Philippines and Japan"
///     -> 1 iteration, tools: none, "This is a new conversation so I don't have
///        memory of our prior discussion about these topics."
///
/// A 4B model reads an empty conversation as an empty memory. `sage_recall` was
/// right there, offered, in a catalogue of 18. Nothing in the prompt connected
/// "we discussed" to it, so it asked the owner to retype what SAGE already held.
///
/// These assertions are deliberately about wording. The prompt is the only place
/// this behaviour lives — there is no code path to test — so a rule nobody
/// asserts is a rule the next edit quietly deletes.
final class RecallDisciplineTests: XCTestCase {

    private var prompt: String { BrainPrompts.voiceAgentManager }

    /// The trigger phrases. These are the owner's actual words from the Signal
    /// thread, not invented examples.
    func testThePromptNamesTheWordsThatMeanAnEarlierConversation() {
        for phrase in ["we talked about", "you told me", "the ones from before", "our list"] {
            XCTAssertTrue(
                prompt.contains(phrase),
                "\"\(phrase)\" is how the owner refers to stored memory and the prompt does not mention it"
            )
        }
        XCTAssertTrue(prompt.contains("sage_recall"), "no tool is named as the answer")
    }

    /// The exact refusal that was observed, forbidden by name.
    ///
    /// Same shape as the picture rule ("never say you are unable to look at
    /// pictures"): a capable model denying a capability it has is worse than one
    /// that tries and fails, because the owner has no reason to ask again.
    func testThePromptForbidsClaimingToHaveNoMemory() {
        XCTAssertTrue(
            prompt.contains("Never say you have no record of an earlier conversation"),
            "the model may still answer \"this is a new conversation so I don't have memory\""
        )
        XCTAssertTrue(
            prompt.contains("never ask the owner to repeat something before you have looked"),
            "nothing stops it asking the owner to retype what SAGE already holds"
        )
    }

    /// The owner's own diagnosis: *"the agent can do sage recall as many times as
    /// it needs — it's probably not really doing that."* The log agreed. The turn
    /// that produced the thin document called `sage_recall` exactly once, then
    /// spent three iterations on consolation web searches.
    func testThePromptAsksForMoreThanOneRecallBeforeGivingUp() {
        XCTAssertTrue(prompt.contains("One recall is rarely enough"))
        XCTAssertTrue(
            prompt.contains("call sage_recall again in different words"),
            "a thin first result still ends the search"
        )
        XCTAssertTrue(
            prompt.contains("before you answer or reach for web_search"),
            "the web is still an equal first choice to the owner's own memory"
        )
    }

    /// Raising the iteration cap to 10 is what makes "recall again" affordable.
    /// At 5, a second and third recall came out of the same budget as the write,
    /// which is how the shop list got truncated in the first place.
    func testThereIsRoomInTheBudgetToActuallyDoThis() {
        XCTAssertGreaterThanOrEqual(
            ToolLoop.defaultMaxIterations,
            8,
            "asking for repeated recall inside a cap that cannot afford it just moves where the turn breaks"
        )
    }

    /// This section cost ~624 characters, taking the prompt from 5,100 to ~5,724.
    ///
    /// `PromptLatencyBudgetTests` owns the ceiling and explains why it is now
    /// 8,000 rather than 6,000 — briefly, the system prompt is the most cacheable
    /// part of the request, so its real cost is a 4B model's attention rather
    /// than the owner's seconds. This assertion just keeps the arithmetic above
    /// honest: if the section is edited down to nothing, the sentence claiming it
    /// cost 624 characters should stop being true out loud.
    func testTheseRulesCostWhatTheDocSaysTheyCost() {
        XCTAssertGreaterThan(
            prompt.count,
            5_400,
            "the recall section appears to have been cut — the 624-character note above is now wrong"
        )
        XCTAssertLessThanOrEqual(prompt.count, PromptLatencyBudgetTests.systemPromptCharacterBudget)
    }
}
