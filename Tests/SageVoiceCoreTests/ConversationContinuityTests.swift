// **Mac-only, because it tests `MynahMac`.**
//
// `MynahMac` is the AppKit/SwiftUI half of this package, and Package.swift does
// not declare that target off Darwin — so the import below resolves on a Mac
// and nowhere else. The guard wraps the whole file rather than just the import,
// because every test in here drives a Mac type: a file that compiled down to an
// empty test class would let Linux report a green suite that ran nothing, which
// is the exact failure this branch exists to stop. See `coreTestDependencies`
// in Package.swift.
#if os(macOS)
import XCTest
@testable import MynahMac
@testable import SageVoiceCore

/// **That the window and the phone are one conversation.**
///
/// The owner found this by using it. He asked Mynah on his phone for a tomato
/// soup recipe, got one, opened the window — where that exact recipe was drawn
/// on screen by `ConversationMirror` — and typed *"can you give me the step by
/// step instructions for the recipe"*. Mynah asked which recipe he meant.
///
/// He diagnosed it correctly from the outside: *"asking via signal it works —
/// meaning the history is 'preserved' there for some reason and in our chat
/// interface its not"*. The daemon keeps `conversations.json` per thread and
/// hands it to the engine on every turn; the window ran a second engine off a
/// private array that started empty and only ever grew from turns typed into the
/// window. One screen, two memories, and nothing keeping them in step.
///
/// The screenshot that isolated it had the product's own "In this window"
/// divider sitting exactly on the boundary where the context stopped.
@MainActor
final class ConversationContinuityTests: XCTestCase {

    /// **The bug, as a test.**
    ///
    /// The phone said something; the window must answer knowing it.
    func testAQuestionInTheWindowCarriesWhatThePhoneAlreadySaid() async {
        let engine = RecordingEngine()
        let model = ConversationModel(engine: engine, readiness: .ready(destination: "this Mac", model: "qwen3.5:4b", staysOnDevice: true))
        model.priorContext = {
            [
                BrainMessage(role: .user, content: "search for a tomato soup recipe"),
                BrainMessage(role: .assistant, content: "Here are some easy tomato soup recipes…")
            ]
        }

        model.draft = "can you give me the step by step instructions for the recipe"
        model.send()
        await model.settle()

        let seen = await engine.lastHistory
        XCTAssertEqual(
            seen.count, 2,
            "the window answered without the phone's conversation: \(seen.map(\.content))"
        )
        XCTAssertTrue(seen.contains { $0.content.contains("tomato soup recipes") },
                      "the recipe was on screen and the engine never saw it")
    }

    /// The window's own turns must still be there, in order, after the phone's.
    /// A fix that swapped one empty history for another would pass the test
    /// above and break every follow-up typed in the window.
    func testTheWindowsOwnTurnsFollowThePhonesInOrder() async {
        let engine = RecordingEngine()
        let model = ConversationModel(engine: engine, readiness: .ready(destination: "this Mac", model: "qwen3.5:4b", staysOnDevice: true))
        model.priorContext = { [BrainMessage(role: .assistant, content: "from the phone")] }

        model.draft = "first question here"
        model.send()
        await model.settle()

        model.draft = "second question here"
        model.send()
        await model.settle()

        let seen = await engine.lastHistory
        XCTAssertEqual(
            seen.map(\.content),
            ["from the phone", "first question here", "an answer"],
            "the second turn did not see the phone and the first window turn in order"
        )
    }

    /// The turn being answered is passed as `transcript`. If it is also in the
    /// history the model is asked the same thing twice in one request.
    func testTheQuestionBeingAskedIsNotAlsoInTheHistory() async {
        let engine = RecordingEngine()
        let model = ConversationModel(engine: engine, readiness: .ready(destination: "this Mac", model: "qwen3.5:4b", staysOnDevice: true))

        model.draft = "only once please"
        model.send()
        await model.settle()

        let seen = await engine.lastHistory
        XCTAssertFalse(
            seen.contains { $0.content == "only once please" },
            "the live question is duplicated into its own history"
        )
    }

    // MARK: Clearing

    /// **The owner's ruling on what Clear means.**
    ///
    /// *"we should just make it local clear and if you send a new message the
    /// old context is still there, just visually you don't see it — think of the
    /// clear more to clear the screen of chat clutter, but behind the scenes the
    /// agent still needs the context window and what was last discussed."*
    ///
    /// `clear()` used to call `history.removeAll()`, so emptying the screen also
    /// emptied the appliance — a button whose own label promises it changes
    /// nothing on the phone, quietly amputating the conversation.
    func testClearingTheScreenLeavesTheApplianceItsContext() async {
        let engine = RecordingEngine()
        let model = ConversationModel(engine: engine, readiness: .ready(destination: "this Mac", model: "qwen3.5:4b", staysOnDevice: true))
        model.priorContext = { [BrainMessage(role: .assistant, content: "said on the phone")] }

        model.draft = "before the clear"
        model.send()
        await model.settle()

        model.clear()
        XCTAssertTrue(model.exchanges.isEmpty, "the screen was not cleared")

        model.draft = "after the clear"
        model.send()
        await model.settle()

        let seen = await engine.lastHistory
        XCTAssertTrue(
            seen.contains { $0.content == "said on the phone" },
            "clearing the window's screen took the phone's conversation with it"
        )
    }

    /// The other half: what was cleared is off the screen, so it must not come
    /// back into the context through `exchanges`. Only the phone's side and
    /// anything said since survive — which is exactly "the conversation is what
    /// Signal holds".
    func testClearedWindowTurnsDoNotReturnToTheContext() async {
        let engine = RecordingEngine()
        let model = ConversationModel(engine: engine, readiness: .ready(destination: "this Mac", model: "qwen3.5:4b", staysOnDevice: true))

        model.draft = "swept away"
        model.send()
        await model.settle()
        model.clear()

        model.draft = "the new one"
        model.send()
        await model.settle()

        let seen = await engine.lastHistory
        XCTAssertFalse(
            seen.contains { $0.content == "swept away" },
            "a turn the owner cleared is still being sent to the model"
        )
    }
}

// MARK: - Fixtures

/// An engine that answers instantly and remembers what it was handed.
private actor RecordingEngine: TurnEngine {
    private(set) var lastHistory: [BrainMessage] = []

    func prepare() async throws {}
    func warmUp() async {}
    func shutDown() async {}

    func run(transcript: String, history: [BrainMessage]) async throws -> TurnResult {
        lastHistory = history
        return TurnResult(
            reply: "an answer",
            toolNames: [],
            seconds: 0.1,
            messages: history + [
                BrainMessage(role: .user, content: transcript),
                BrainMessage(role: .assistant, content: "an answer")
            ]
        )
    }
}

@MainActor
extension ConversationModel {
    /// Waits for the turn in flight, so a test reads a finished exchange rather
    /// than a racing one.
    fileprivate func settle() async {
        for _ in 0..<200 where isBusy {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
#endif  // os(macOS)
