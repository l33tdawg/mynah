import XCTest
@testable import SageVoiceCore

/// A tool call the model wrote as text instead of requesting properly.
///
/// Reported by the owner from their own thread. They asked for something to be
/// saved to a note, and the reply was:
///
///     <|DSML|>tool_calls>
///     <|DSML|>invoke name="read_note">
///     <|DSML|>parameter name="title" string="true">llm on raspberry pi 5 …
///
/// The model wanted `read_note` and emitted the call as prose. The backend saw
/// no structured tool call, so the loop took the markup for the answer — and
/// nothing downstream could tell, because it is a perfectly ordinary non-empty
/// assistant message.
final class ToolCallMarkupTests: XCTestCase {

    /// Verbatim from the screenshot.
    private let reported = """
    <|DSML|>tool_calls>
    <|DSML|>invoke name="read_note">
    <|DSML|>parameter name="title" string="true">llm on raspberry pi 5 offline ept device research</|DSML|>parameter>
    </|DSML|>invoke>
    </|DSML|>tool_calls>
    """

    func testTheReportedReplyBecomesNothing() {
        XCTAssertTrue(
            ToolLoop.speakable(reported).isEmpty,
            "markup reached the owner: \(ToolLoop.speakable(reported))"
        )
    }

    /// Empty is the point. An empty reply routes into the forced-summary turn,
    /// where tools are withheld and the model must produce speech — so a mangled
    /// tool call degrades into one more attempt rather than into markup on a
    /// phone. If this ever returns a non-empty fragment, the owner sees it.
    func testNoFragmentSurvivesToBeSpoken() {
        for fragment in [
            "<|DSML|>invoke name=\"write_note\">",
            "</|DSML|>tool_calls>",
            "<tool_calls><invoke name=\"read_note\"></invoke></tool_calls>",
            "<|DSML|>"
        ] {
            XCTAssertTrue(
                ToolLoop.speakable(fragment).isEmpty,
                "\"\(fragment)\" survived as \"\(ToolLoop.speakable(fragment))\""
            )
        }
    }

    /// A real answer that merely mentions a tool by name must not be eaten.
    /// Over-stripping would silently delete the owner's answer, which is a worse
    /// failure than the one being fixed.
    func testOrdinaryAnswersAreUntouched() {
        for answer in [
            "I saved that to the note about the raspberry pi research.",
            "Your note tokyo-trip.md is saved with three packing bullet points.",
            "I used read_note to check, and it covers the storage sizing.",
            "Ollama plus runtime is about 2 GB, and model files another 5 GB."
        ] {
            XCTAssertEqual(ToolLoop.speakable(answer), answer, "an ordinary answer was stripped")
        }
    }

    /// Mixed content: the model produced a real sentence and then trailed into
    /// markup. The sentence is the answer and must survive.
    func testARealSentenceBeforeTheMarkupSurvives() {
        let mixed = "Saved it for later.\n<|DSML|>tool_calls>\n<|DSML|>invoke name=\"write_note\">\n</|DSML|>tool_calls>"
        XCTAssertEqual(ToolLoop.speakable(mixed), "Saved it for later.")
    }
}
