import XCTest
@testable import SageVoiceCore

/// **The prompt told the model to call a tool it does not have.**
///
/// `sage_pipe` was removed from the SAGE curation in 1.7.2 and replaced by
/// `sage_message_send` / `sage_message_reply`. The allowlist changed; two lines
/// of the prompt did not, and they were not obscure ones:
///
///     - To send a document to another agent, read_note it first, then pass
///       what it says to sage_pipe.
///     - Then call sage_pipe using the exact agent_id from that list.
///
/// That is the whole of the "send this to MacBook Pro Agent A" flow. The model
/// was instructed, in the imperative, to reach for something not in its
/// catalogue — and a 4B told to call a tool it cannot see does not report a
/// missing tool, it improvises: the nearest name, or a confident sentence
/// saying the thing was sent.
///
/// Nothing could catch it. The allowlist is a `Set<String>` and the prompt is
/// prose, so the two agreed only by somebody remembering to change both. This
/// test makes the prompt's claims checkable against the catalogue, which is the
/// only way that agreement survives the next removal.
final class PromptNamesOnlyRealToolsTests: XCTestCase {

    /// Every `snake_case` word the prompt uses as a tool name.
    ///
    /// Deliberately greedy — anything shaped like a tool is treated as a claim
    /// about a tool. A false positive here is a prompt sentence that reads like
    /// an instruction and is not one, which is worth rewriting anyway.
    private func toolNames(in prompt: String) -> Set<String> {
        let pattern = #"\b(sage_[a-z_]+|web_search|write_note|read_note|list_notes|send_file)\b"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(prompt.startIndex..., in: prompt)
        var found: Set<String> = []
        regex.enumerateMatches(in: prompt, range: range) { match, _, _ in
            guard let match, let r = Range(match.range, in: prompt) else { return }
            found.insert(String(prompt[r]))
        }
        return found
    }

    /// **The composed catalogue, not a set unioned with a hand-written list of
    /// "appliance tools".**
    ///
    /// That literal existed because `voiceToolAllowlist` was only ever half the
    /// answer — it curated SAGE, so the five tools this repository implements
    /// had to be listed beside it by hand. Two hand-maintained lists to answer
    /// one question is how the prompt and the catalogue drifted apart in the
    /// first place, which is the defect this whole file exists for. There is
    /// one list now and nobody maintains it: it is what the model is handed.
    ///
    /// The payoff is not tidiness. A skills loader publishes tools no constant
    /// anywhere names, and a prompt sentence naming one of them is checkable
    /// here the day it lands, with no edit to this file.
    private func everyRealTool() async throws -> Set<String> {
        let offered = try await ComposedCatalogue.conversation()
        // Not vacuous, and asserted rather than assumed: if the composition
        // ever returns nothing, every "the prompt invented a tool" assertion
        // below would fail loudly — but if it returned only SAGE's names, the
        // *absence* checks would pass for the wrong reason forever.
        XCTAssertTrue(offered.contains("write_note"), "the composed catalogue is missing this repository's own tools")
        XCTAssertTrue(offered.contains("web_search"))
        XCTAssertTrue(offered.contains("sage_recall"))
        return offered
    }

    /// The defect itself, for every reply style — the body is shared, so a
    /// single style passing would prove nothing about the others.
    func testEveryToolTheVoicePromptNamesIsOneTheModelHas() async throws {
        let real = try await everyRealTool()
        for style in ReplyStyle.allCases {
            let prompt = BrainPrompts.voiceAgentManager(style: style)
            let named = toolNames(in: prompt)
            XCTAssertFalse(named.isEmpty, "the \(style) prompt names no tools at all, so this test is vacuous")

            let invented = named.subtracting(real)
            XCTAssertTrue(
                invented.isEmpty,
                "the \(style) prompt instructs the model to call \(invented.sorted().joined(separator: ", ")), "
                    + "which nothing publishes into the composed catalogue. A model told to call a "
                    + "tool it cannot see improvises rather than reporting the gap."
            )
        }
    }

    /// **The specific removal that caused this**, named so the fix cannot be
    /// undone by a copy-paste from an older revision of the prompt.
    func testThePipeToolsAreGoneFromBothTheCatalogueAndTheProse() async throws {
        let offered = try await ComposedCatalogue.conversation()
        for retired in ["sage_pipe", "sage_pipe_result", "sage_pipe_history", "sage_list", "sage_reflect"] {
            XCTAssertFalse(
                offered.contains(retired),
                "\(retired) is back in the catalogue; if that is deliberate, this test is the place to say so"
            )
            for style in ReplyStyle.allCases {
                XCTAssertFalse(
                    toolNames(in: BrainPrompts.voiceAgentManager(style: style)).contains(retired),
                    "the \(style) prompt still tells the model to use \(retired), which it does not have"
                )
            }
        }
    }

    /// The replacement is actually named, so the flow the prompt describes can
    /// be carried out. Removing the wrong instruction without supplying the
    /// right one leaves the model with a task and no way to do it.
    func testThePromptSaysHowToSendWorkToAnAgent() {
        let named = toolNames(in: BrainPrompts.voiceAgentManager)
        XCTAssertTrue(
            named.contains("sage_message_send"),
            "the prompt describes sending work to another agent but never names the tool that does it"
        )
        XCTAssertTrue(
            named.contains("sage_directory"),
            "the prompt must say to resolve a spoken name to an exact agent_id before sending"
        )
    }
}
