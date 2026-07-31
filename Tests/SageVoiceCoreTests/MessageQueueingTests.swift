import XCTest
@testable import MynahMac
@testable import SageVoiceCore

/// **That a sentence typed while Mynah is thinking is not thrown away.**
///
/// `send()` guarded on `!isBusy` and returned *before* clearing the draft, so
/// pressing Return during a turn did nothing at all and left the text sitting
/// in the box. On an appliance whose turns run 20–60 s, that is most of the
/// time it is being used, and there was no way to tell a refused send from a
/// slow one.
@MainActor
final class MessageQueueingTests: XCTestCase {

    private func makeModel(_ engine: GatedEngine) -> ConversationModel {
        ConversationModel(
            engine: engine,
            readiness: .ready(destination: "this Mac", staysOnDevice: true)
        )
    }

    private func settle(_ model: ConversationModel) async {
        for _ in 0..<400 where model.isBusy {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The sentence is taken, and the box is emptied so it looks taken.
    func testTypingWhileItThinksQueuesInsteadOfVanishing() async {
        let engine = GatedEngine()
        let model = makeModel(engine)

        model.draft = "what is on my plate"
        model.send()
        XCTAssertTrue(model.isBusy, "the first send should have started a turn")

        model.draft = "and the address"
        model.send()

        XCTAssertEqual(model.queued, ["and the address"])
        XCTAssertEqual(model.draft, "", "a queued sentence must leave the box, or it reads as refused")
        XCTAssertEqual(model.exchanges.count, 1, "queued is not yet asked")

        await engine.release()
        await settle(model)
    }

    /// Several queued sentences become one question, not several turns.
    ///
    /// Three sentences typed while waiting — "and the address", "and their
    /// number" — are almost always one thought, and answering them separately
    /// costs three full turns to say what one turn says better.
    func testQueuedMessagesGoTogetherAsOneTurn() async {
        let engine = GatedEngine()
        let model = makeModel(engine)

        model.draft = "find me a plumber"
        model.send()
        model.draft = "and the address"
        model.send()
        model.draft = "and their number"
        model.send()

        XCTAssertEqual(model.queued.count, 2)

        await engine.release()
        await settle(model)

        XCTAssertTrue(model.queued.isEmpty, "the queue must drain when the turn ends")
        XCTAssertEqual(
            model.exchanges.count, 2,
            "two queued sentences must produce ONE follow-up turn, not two"
        )
        XCTAssertEqual(model.exchanges.last?.question, "and the address\nand their number")

        let asked = await engine.transcripts
        XCTAssertEqual(asked, ["find me a plumber", "and the address\nand their number"])
    }

    /// Stop means stop — including whatever was typed while it ran.
    ///
    /// Draining the queue on cancellation would answer the Stop button by
    /// immediately starting another turn. The text goes back in the box rather
    /// than being discarded, so pressing Return again is all it takes.
    func testStopPutsQueuedTextBackInTheBoxRatherThanSendingIt() async {
        let engine = GatedEngine()
        let model = makeModel(engine)

        model.draft = "a long one"
        model.send()
        model.draft = "never mind, this instead"
        model.send()
        XCTAssertEqual(model.queued.count, 1)

        model.stop()

        XCTAssertTrue(model.queued.isEmpty)
        XCTAssertEqual(model.draft, "never mind, this instead")
        XCTAssertFalse(model.isBusy, "Stop must not start the queued turn")

        await engine.release()
    }
}

// MARK: - Fixtures

/// An engine that will not answer until it is released, so a test can hold a
/// turn open and type into it.
private actor GatedEngine: TurnEngine {
    private var released = false
    private(set) var transcripts: [String] = []

    func release() { released = true }

    func prepare() async throws {}
    func warmUp() async {}
    func shutDown() async {}

    func run(transcript: String, history: [BrainMessage]) async throws -> TurnResult {
        transcripts.append(transcript)
        while !released {
            try? await Task.sleep(for: .milliseconds(5))
        }
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
