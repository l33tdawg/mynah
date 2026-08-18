// **Mac-only, because the live voice call is a Mac feature.**
//
// `Sources/SageVoiceCore/Call` is excluded from the target off Darwin — see
// `coreExclusions` in Package.swift — so none of the types below exist there.
// The exclusion and this guard are two halves of one decision, and the tests
// have to carry their half explicitly: a test file that cannot compile does not
// fail loudly, it takes the whole target down with it and every other test in
// the suite stops running too. That is what happened here.
#if os(macOS)
import XCTest
@testable import SageVoiceCore

/// What a call keeps between turns, and why the shape of it is latency.
///
/// ## Three compounding problems, one store
///
/// `CallHistory.remember` kept `conversation.dropFirst()` — everything the loop
/// worked with, unfiltered. So a call's context carried assistant tool-call
/// turns and whole `.toolResult` messages, and a single result can run to six
/// thousand characters.
///
/// The daemon has stripped those since 1.5.x through `conversationOnly`, and
/// writes down why: with last turn's tool output still sitting in context, a 4B
/// model concludes it already has the facts and stops calling the tool. The call
/// path got neither that protection nor the tokens back.
///
/// Then it trimmed with `suffix(24)` over *messages*, which slides by one on
/// nearly every append. The byte prefix the model is asked to prefill therefore
/// moved almost every turn, so Ollama's KV checkpoint matched nothing even once
/// anchoring existed.
///
/// It shows up as dead air mid-call, which on a phone reads as a dropped
/// connection — and it is bidirectional: an unanchored call turn evicts the
/// Signal thread's checkpoint from Ollama's single slot, so the first message
/// after a call pays full prefill too. The daemon measures that at 12.0s and
/// 2,613 tokens.
final class CallHistoryPrefixTests: XCTestCase {

    /// Tool traffic is not conversation, and must not be carried.
    func testToolCallsAndTheirResultsAreNotKept() async {
        let history = CallHistory()
        await history.remember([
            .system("you are a helpful appliance"),
            .user("what's still open"),
            .toolResult(name: "sage_backlog", content: String(repeating: "x", count: 6_000)),
            .assistant("The visa form is still open."),
        ])

        let kept = await history.recent()

        XCTAssertEqual(
            kept.filter { $0.role == .tool }, [],
            "a six-thousand-character tool result is being replayed into every later turn of the call"
        )
        XCTAssertEqual(
            kept.filter { $0.role == .system }, [],
            "the system prompt is stored and would stack a second copy each turn"
        )
        XCTAssertEqual(kept.map(\.role), [.user, .assistant], "\(kept.map(\.role))")
        XCTAssertTrue(
            kept.last?.content.contains("visa") ?? false,
            "the answer itself was dropped along with the tool traffic: \(kept)"
        )
    }

    /// **A kept history always begins at the start of a turn.**
    ///
    /// This is the prefix-stability property stated in the only way that can
    /// fail. `suffix(24)` counts messages, so it cuts wherever twenty-four
    /// happens to land — routinely mid-turn, on an assistant message whose
    /// question is no longer there. Every append then shifts that boundary by
    /// one and the prefill prefix changes underneath the checkpoint.
    ///
    /// Cutting at a user message means the prefix only moves when a whole turn
    /// genuinely falls out of the window.
    func testWhatIsKeptAlwaysStartsAtTheBeginningOfATurn() async {
        let history = CallHistory(keepingLastTurns: 4)
        await history.remember(Self.exchanges(20))

        let kept = await history.recent()

        XCTAssertEqual(
            kept.first?.role, .user,
            """
            the kept history starts mid-turn, on an answer whose question has \
            been cut away. The prefill prefix moves every append and no KV \
            checkpoint can survive it: \(kept.prefix(3).map(\.role))
            """
        )
        XCTAssertEqual(
            kept.filter { $0.role == .user }.count, 4,
            "the window is not the number of turns it says it is: \(kept.map(\.role))"
        )
    }

    /// And the prefix genuinely holds still while the window has room.
    ///
    /// The property the anchoring exists for: turn N+1's context must begin with
    /// exactly the bytes turn N's did, or the checkpoint planted after N matches
    /// nothing.
    ///
    /// **Stated plainly: this one passes against the old code too**, because
    /// below the window nothing was being trimmed either way. It is here to stop
    /// a future `remember` from reordering or rewriting earlier turns, which
    /// would break anchoring just as thoroughly and which neither test above
    /// would notice. The two that actually fail on the defect are the ones
    /// above; this is not a third.
    func testThePrefixDoesNotMoveWhileTheWindowHasRoom() async {
        let history = CallHistory(keepingLastTurns: 8)

        await history.remember(Self.exchanges(3))
        let afterThree = await history.recent()

        await history.remember(Self.exchanges(4))
        let afterFour = await history.recent()

        XCTAssertEqual(
            Array(afterFour.prefix(afterThree.count)).map(\.content),
            afterThree.map(\.content),
            """
            the fourth turn rewrote the first three, so the checkpoint planted \
            after turn three describes a sequence turn four never asks for
            """
        )
    }

    /// `n` complete turns, with tool traffic in them like a real one.
    private static func exchanges(_ count: Int) -> [BrainMessage] {
        var conversation: [BrainMessage] = [.system("you are a helpful appliance")]
        for turn in 1...count {
            conversation.append(.user("question \(turn)"))
            conversation.append(.toolResult(name: "sage_recall", content: "result \(turn)"))
            conversation.append(.assistant("answer \(turn)"))
        }
        return conversation
    }
}
#endif  // os(macOS)
