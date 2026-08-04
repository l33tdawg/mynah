import XCTest
@testable import SageVoiceCore

/// A reply that strips to nothing must never reach the stored history.
///
/// ## How a thread dies
///
/// `conversationOnly` tested the *raw* reply for emptiness and then stored the
/// *stripped* one. Those are different strings, so anything non-empty that
/// strips to nothing walked through the guard and was stored as an assistant
/// turn with no content. Three real ways to produce one:
///
/// - a `<think>` block truncated at `maxGeneratedTokens`, which strips to end of
///   string;
/// - a reply that is nothing but a fenced code block;
/// - a model that writes its tool call as text, which
///   `strippingToolCallMarkup` is documented to strip to nothing.
///
/// The next turn puts that message back on the wire as
/// `{"role":"assistant","content":null}` with no `tool_calls`, and DeepSeek
/// answers `400 Invalid assistant message: content or tool_calls must be set`.
/// The owner then gets "Something went wrong talking to the model" for **every**
/// message he sends: history is written only on the success path, so no later
/// turn is recorded, `trimmed` cuts at user-message indices and can never scroll
/// the bad turn out, and `ConversationStore` persists it and restores it on
/// restart. The thread stays dead until the six-hour on-disk expiry.
///
/// Found by the 1.7.0 audit. Nothing in the suite constructed a reply that was
/// non-empty and stripped to empty, which is the only input that shows it.
final class EmptyAssistantTurnTests: XCTestCase {

    /// The three shapes, each of which used to be stored as an empty turn.
    ///
    /// Table-driven on purpose: the bug is not about `<think>` in particular, it
    /// is about the gap between what is tested and what is kept, and any string
    /// in that gap does it.
    func testNothingThatStripsToNothingIsCarriedIntoHistory() {
        let stripToNothing = [
            "a truncated think block": "<think>right, he's asking about the invoice and I should",
            "a bare code fence": "```\nswift build\n```",
            // The shape ToolCallMarkupTests captured from a real reply: the
            // model wrote its tool call as prose instead of calling it.
            "tool-call markup as text": """
                <|DSML|>tool_calls>
                <|DSML|>invoke name="read_note">
                <|DSML|>parameter name="title" string="true">llm on raspberry pi</|DSML|>parameter>
                </|DSML|>invoke>
                </|DSML|>tool_calls>
                """,
        ]

        for (what, reply) in stripToNothing {
            XCTAssertFalse(
                reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "\(what): the fixture is empty already, so it proves nothing"
            )
            XCTAssertTrue(
                ToolLoop.speakable(reply).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "\(what): this no longer strips to nothing, so it is the wrong fixture now — "
                    + "find one that does rather than deleting the case"
            )

            let carried = VoiceBridgeDaemon.conversationOnly([
                .system("you are a helpful appliance"),
                .user("what's the invoice status"),
                .assistant(reply),
            ])

            XCTAssertEqual(
                carried.filter { $0.role == .assistant && $0.content.isEmpty }, [],
                """
                \(what) was stored as an empty assistant turn. Next turn it goes \
                back on the wire as content:null and the provider refuses every \
                message in this thread from then on.
                """
            )
        }
    }

    /// The window keeps its own copy of this and its doc comment says the two
    /// must behave identically. They did — including this.
    ///
    /// Pinned here rather than only in the Mac target's tests because "identical
    /// to the daemon's" is a claim about two files, and a claim about two files
    /// is worth exactly one test that reads both.
    func testTheWindowAndTheDaemonAgreeAboutWhatIsWorthKeeping() throws {
        let window = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MynahMac/Main/ConversationModel.swift")
        let source = try String(contentsOf: window, encoding: .utf8)

        // The exact shape that was wrong: guarding the raw content and then
        // storing the stripped text.
        XCTAssertFalse(
            source.contains("guard !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty"),
            """
            the window still decides emptiness from the raw reply while storing \
            the stripped one, which is the gap that bricks a thread — see \
            VoiceBridgeDaemon.conversationOnly
            """
        )
        XCTAssertTrue(
            source.contains("let spoken = ToolLoop.speakable(message.content)"),
            "the window no longer strips before deciding, so this guard is reading the wrong file"
        )
    }

    /// And the ordinary reply still survives, because a guard that drops
    /// everything would pass the test above and lose the whole conversation.
    func testARealReplyIsStillCarried() {
        let carried = VoiceBridgeDaemon.conversationOnly([
            .system("you are a helpful appliance"),
            .user("what's the invoice status"),
            .assistant("It went out on Tuesday and hasn't been paid yet."),
        ])

        XCTAssertEqual(carried.count, 2, "\(carried)")
        XCTAssertEqual(carried.last?.role, .assistant)
        XCTAssertTrue(
            carried.last?.content.contains("Tuesday") ?? false,
            "the answer was dropped along with the empties: \(carried)"
        )
    }
}
