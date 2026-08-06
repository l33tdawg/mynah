import XCTest
@testable import SageVoiceCore

/// **The prompt told the model to call a tool it does not have.**
///
/// `sage_pipe` was removed from `voiceToolAllowlist` in 1.7.2 and replaced by
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

    /// Tools the appliance implements itself rather than taking from SAGE.
    ///
    /// Listed rather than pattern-matched: the point is to enumerate what is
    /// real, so a name the prompt invents has nowhere to hide. `ToolLoop` and
    /// the note/file surfaces own these.
    private static let applianceTools: Set<String> = [
        "web_search", "write_note", "read_note", "list_notes", "send_file"
    ]

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

    private var everyRealTool: Set<String> {
        BrainPrompts.voiceToolAllowlist.union(Self.applianceTools)
    }

    /// The defect itself, for every reply style — the body is shared, so a
    /// single style passing would prove nothing about the others.
    func testEveryToolTheVoicePromptNamesIsOneTheModelHas() {
        for style in ReplyStyle.allCases {
            let prompt = BrainPrompts.voiceAgentManager(style: style)
            let named = toolNames(in: prompt)
            XCTAssertFalse(named.isEmpty, "the \(style) prompt names no tools at all, so this test is vacuous")

            let invented = named.subtracting(everyRealTool)
            XCTAssertTrue(
                invented.isEmpty,
                "the \(style) prompt instructs the model to call \(invented.sorted().joined(separator: ", ")), "
                    + "which is not in voiceToolAllowlist and not an appliance tool. A model told to "
                    + "call a tool it cannot see improvises rather than reporting the gap."
            )
        }
    }

    /// **The specific removal that caused this**, named so the fix cannot be
    /// undone by a copy-paste from an older revision of the prompt.
    func testThePipeToolsAreGoneFromBothTheCatalogueAndTheProse() {
        for retired in ["sage_pipe", "sage_pipe_result", "sage_pipe_history", "sage_list", "sage_reflect"] {
            XCTAssertFalse(
                BrainPrompts.voiceToolAllowlist.contains(retired),
                "\(retired) is back in the allowlist; if that is deliberate, this test is the place to say so"
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
