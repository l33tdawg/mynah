import XCTest
@testable import SageVoiceCore

/// The bug: the owner asked "can you give me links for these please" and got a
/// mixture of the Tokyo festival just discussed and the Chiang Mai shops from
/// before they had corrected the subject.
///
/// The cause was not the model wandering. `conversationOnly` deletes tool
/// results from history — correctly, and for a measured reason — and takes every
/// URL `web_search` found with them, so the links to the thing just described
/// did not exist in context and a second search was the only way to answer.
final class SourceLinkCarryTests: XCTestCase {

    func testLinksFromToolResultsSurviveOntoTheAnswerThatUsedThem() {
        let finished: [BrainMessage] = [
            .system("prompt"),
            .user("where can I perform in Japan"),
            .toolResult(
                name: "web_search",
                content: """
                Web search results for "modular synth performance japan 2026".
                1. Festival of Modular 2026
                   https://tfom.info/
                   November 14-15 at SALOON & B1FLAT, Daikanyama.
                """,
                id: "1"
            ),
            .assistant("Festival of Modular 2026 is on November 14th and 15th in Daikanyama.")
        ]

        let carried = VoiceBridgeDaemon.conversationOnly(finished)
        let answer = try? XCTUnwrap(carried.last)
        XCTAssertEqual(answer?.role, .assistant)
        XCTAssertTrue(
            answer?.content.contains("https://tfom.info/") == true,
            "the link the owner would ask for next is gone: \(answer?.content ?? "nil")"
        )
        XCTAssertTrue(answer?.content.contains("Daikanyama") == true, "the answer itself was lost")
    }

    /// The reason tool results are dropped in the first place, still holding: a
    /// model that can see last turn's memory dump stops calling tools and
    /// recycles it. Only URLs come through — not the snippets around them.
    func testTheFactsAroundTheLinksAreStillDropped() {
        let carried = VoiceBridgeDaemon.conversationOnly([
            .user("what's on my backlog"),
            .toolResult(name: "web_search", content: "Task 41: rotate the Gemini key. Task 42: pay the Signal number.", id: "1"),
            .assistant("Two things: rotating a key and paying for the number.")
        ])
        let joined = carried.map(\.content).joined(separator: " ")
        XCTAssertFalse(joined.contains("Task 41"), "the tool result came back into history")
        XCTAssertFalse(joined.contains("sources:"), "a result with no URLs should gain no annotation")
    }

    /// Links belong to the turn that used them, so trimming history by turns
    /// drops them with it — otherwise the model cites a source for an answer
    /// that has already scrolled out of context.
    func testEachAnswerKeepsOnlyItsOwnLinks() throws {
        let carried = VoiceBridgeDaemon.conversationOnly([
            .user("modular shops in asia"),
            .toolResult(name: "web_search", content: "1. Siam Modular\n   https://siammodular.com/", id: "1"),
            .assistant("Siam Modular in Chiang Mai."),
            .user("no I meant places to perform in Japan"),
            .toolResult(name: "web_search", content: "1. Festival of Modular\n   https://tfom.info/", id: "2"),
            .assistant("Festival of Modular, Daikanyama.")
        ])

        // Unwrapped rather than subscripted: off Darwin `conversationOnly`
        // carries nothing at all, and `answers[0]` on an empty array is a trap
        // that takes the process down mid-suite instead of a test that says
        // which behaviour is missing.
        let answers = carried.filter { $0.role == .assistant }
        XCTAssertEqual(answers.count, 2, "the two answers did not survive the carry")
        let first = try XCTUnwrap(answers.first, "the first answer did not survive the carry")
        let second = try XCTUnwrap(answers.dropFirst().first, "the second answer did not survive the carry")

        XCTAssertTrue(first.content.contains("siammodular.com"))
        XCTAssertFalse(first.content.contains("tfom.info"))
        XCTAssertTrue(second.content.contains("tfom.info"))
        XCTAssertFalse(
            second.content.contains("siammodular.com"),
            "the corrected-away subject followed the owner into the new one — this is the reported bug"
        )
    }

    /// History is a prompt prefix. One that reorders itself between turns is a
    /// cache that never hits, which is the fault that cost this appliance 17
    /// seconds a turn until it was found.
    func testLinkOrderIsStableAndDeduplicated() {
        let text = """
        1. https://b.example/ two
        2. https://a.example/ one
        3. https://b.example/ again
        """
        XCTAssertEqual(
            SourceLinks.extract(from: text),
            ["https://b.example/", "https://a.example/"]
        )
        XCTAssertEqual(SourceLinks.extract(from: text), SourceLinks.extract(from: text))
    }

    func testTrailingPunctuationIsNotPartOfTheURL() {
        XCTAssertEqual(
            SourceLinks.extract(from: "See https://tfom.info/, then https://example.com."),
            ["https://tfom.info/", "https://example.com"]
        )
    }

    func testAFloodOfResultsCannotRefillTheContextThisWasCarvedOutOf() {
        let many = (1...50).map { "https://example.com/\($0)" }.joined(separator: " ")
        XCTAssertEqual(SourceLinks.extract(from: many).count, SourceLinks.maximumPerTurn)
    }
}
