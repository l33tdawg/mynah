import XCTest
@testable import SageVoiceCore

/// **The request is written down when it is heard, not when it is understood.**
///
/// Measured on the owner's own call, 8 August 2026 — the first time the
/// after-the-call queue was ever exercised for real:
///
///     18:11:56 heard: ...make a markdown file and then send it back to me
///              after this call is done.
///     18:11:57 said "On it — let me pull that together." after 3.1s
///     18:12:02 the call ended mid-answer; stopping that turn
///     18:12:02 cancelled: heard in 1.6s, thought in 6.2s+, spoke in ?
///
/// No queued line, no queue file, nothing drained. He hung up five seconds after
/// the filler, six seconds into a turn that had not reached its tool call — and
/// the appliance had already promised. The known gap in the design, found to be
/// the ordinary case rather than the edge one: people ring off once they have
/// said the thing they rang to say.
///
/// The owner's ruling on the fix: *"queue on hearing for sure"*.
final class QueueOnHearingTests: XCTestCase {

    /// **A directory of its own, and the reason is written up in
    /// `AfterTheCallTests`.** `OwnerOnlyFileSecurity` refuses to write into a
    /// directory this process does not own, and the queue swallows write errors
    /// on purpose — so a file placed straight in `NSTemporaryDirectory()`
    /// produces a queue that persists nothing and a test that looks like a real
    /// durability failure. Which is exactly what it looked like here first.
    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mynah-queue-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("after-the-call.json")
    }

    private func queue() throws -> CallActionQueue {
        let queue = CallActionQueue(fileURL: temporaryFile())
        queue.beginCall("call-1")
        return queue
    }

    private var turnOne: CallActionQueue.Generation {
        CallActionQueue.Generation(call: "call-1", turn: 1)
    }

    // MARK: The sentence that started it

    func testTheOwnersOwnSentenceIsQueuedFromWhatWasHeard() throws {
        let queue = try queue()

        let entry = queue.enqueueFromWhatWasHeard(
            generation: turnOne,
            heard: "No need to reread the whole plan, but make a markdown file and then "
                + "send it back to me after this call is done."
        )

        let queued = try XCTUnwrap(entry, "the sentence that was lost on 8 August is still lost")
        XCTAssertEqual(queued.kind, .instruction)
        XCTAssertEqual(queued.preemptive, true)
        XCTAssertTrue(queued.what.contains("markdown file"))
    }

    /// **The whole point: it survives a turn that never finishes.** Nothing here
    /// runs a model, so cancelling one cannot take it with it.
    func testItIsOnDiskBeforeAnyModelHasRun() throws {
        let file = temporaryFile()
        let queue = CallActionQueue(fileURL: file)
        queue.beginCall("call-1")

        _ = queue.enqueueFromWhatWasHeard(
            generation: turnOne,
            heard: "send me that file after we hang up"
        )

        // Diagnostics first, so a failure says which half broke.
        XCTAssertEqual(queue.everything().count, 1, "it was never in memory either")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: file.path),
            "nothing was written to \(file.path)"
        )

        // A second queue over the same file is what surviving the process means.
        let afterRestart = CallActionQueue(fileURL: file)
        XCTAssertEqual(
            afterRestart.everything().count, 1,
            "the request did not reach disk, so a cancelled turn still loses it"
        )
    }

    // MARK: What it does not queue

    /// A fail-safe that fires on everything is a queue full of things nobody
    /// asked for, and the drain runs each of them through a brain turn.
    func testAnOrdinaryQuestionIsNotQueued() throws {
        let queue = try queue()

        for ordinary in [
            "what's on for tomorrow?",
            "no, on Monday night",
            "I haven't picked it up yet, I'll get it around three",
            "read me the plan"
        ] {
            XCTAssertNil(
                queue.enqueueFromWhatWasHeard(generation: turnOne, heard: ordinary),
                "queued a request nobody made: \(ordinary)"
            )
        }
    }

    /// The forms the owner actually uses, from his own ruling — *"send me this
    /// file after the call or do xyz"*.
    func testTheWaysHeAsksAreAllHeard() throws {
        for asked in [
            "send me the deck after this call",
            "message Codex about it after we hang up",
            "make me a summary afterwards",
            "do that once we're done",
            "email it at the end of the call"
        ] {
            let queue = try queue()
            XCTAssertNotNil(
                queue.enqueueFromWhatWasHeard(generation: turnOne, heard: asked),
                "missed a request: \(asked)"
            )
        }
    }

    // MARK: And never twice

    /// **The model got there, so the placeholder goes.** Its entry names the
    /// file or the agent; this one only quotes a sentence. Performing both would
    /// send the owner the same thing twice, which is its own kind of broken
    /// promise.
    func testTheModelsOwnQueueingReplacesWhatWasWrittenForIt() throws {
        let queue = try queue()
        _ = queue.enqueueFromWhatWasHeard(
            generation: turnOne,
            heard: "send me the suitcase plan after this call"
        )

        _ = queue.enqueue(
            generation: turnOne,
            kind: .file,
            what: "suitcase-plan.md",
            who: nil,
            asked: "send me the suitcase plan after this call"
        )

        let queued = queue.everything().filter { $0.state == .queued }
        XCTAssertEqual(queued.count, 1, "the owner would get the same thing twice")
        XCTAssertEqual(queued.first?.kind, .file, "the vaguer entry won")
        XCTAssertNotEqual(queued.first?.preemptive, true)
    }

    /// Two genuine requests on one call are two entries. The replacement is
    /// scoped to the turn the model has just answered, not to the whole call.
    func testASecondRequestOnTheSameCallIsNotSwallowed() throws {
        let queue = try queue()
        let turnTwo = CallActionQueue.Generation(call: "call-1", turn: 2)

        _ = queue.enqueueFromWhatWasHeard(
            generation: turnOne, heard: "send me the plan after this call"
        )
        _ = queue.enqueueFromWhatWasHeard(
            generation: turnTwo, heard: "and message Codex about it afterwards"
        )
        _ = queue.enqueue(
            generation: turnOne, kind: .file, what: "plan.md", who: nil, asked: "…"
        )

        let queued = queue.everything().filter { $0.state == .queued }
        XCTAssertEqual(queued.count, 2, "answering turn one dropped turn two's request")
    }

    /// A retry of the same turn is not a second request.
    func testTheSameTurnIsOnlyEverNotedOnce() throws {
        let queue = try queue()

        _ = queue.enqueueFromWhatWasHeard(generation: turnOne, heard: "send it after this call")
        _ = queue.enqueueFromWhatWasHeard(generation: turnOne, heard: "send it after this call")

        XCTAssertEqual(queue.everything().count, 1)
    }

    /// The guard that stops an abandoned turn filing into the next call applies
    /// here too — this writes through the same door.
    func testNothingIsNotedForACallThatIsNoLongerLive() throws {
        let queue = try queue()

        let stale = CallActionQueue.Generation(call: "an-earlier-call", turn: 1)
        XCTAssertNil(
            queue.enqueueFromWhatWasHeard(generation: stale, heard: "send it after this call"),
            "a dead call's request was filed against the live one"
        )
    }
}
