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

/// What the appliance believes about whether it is busy.
///
/// ## One predicate, wrong three times
///
/// Three places asked "is a turn running?" by writing
/// `turn.map { !$0.isCancelled } ?? false`. **A `Task` that finished normally is
/// not cancelled**, and `turn` was never cleared, so that expression became
/// permanently true at the end of the very first turn and stayed true for the
/// life of the process — across later calls included.
///
/// - the courtesy guard then swallowed every real "thanks", "okay" and "bye"
///   for the rest of the call, logging `heard "thanks" while working` with
///   nothing working;
/// - `cutIn` gave every ordinary follow-up the interrupted opening;
/// - `quietFor` returned nil for ever and the idle watch treated that as a
///   reason to stop, so the watchdog that hangs up an abandoned call died five
///   seconds after the first utterance and a call nobody was on stayed open with
///   a live microphone.
///
/// ## Why nothing caught it
///
/// Every existing test of these three exercised their *inputs* —
/// `HeardSpeech.isCourtesy` on strings, `WorkingReply.interruptedOpening` on
/// wording — and none of them ever drove a turn to completion and then asked a
/// second thing. The bug lived entirely in the second utterance of a call, which
/// no test had.
///
/// So these tests all have the same shape: **finish one turn, then do the thing.**
final class CallTurnLifecycleTests: XCTestCase {

    /// **The regression, stated as the caller experiences it.** He thanks it and
    /// it says nothing back, for the rest of the call.
    ///
    /// A courtesy is discarded only while work is genuinely in flight, which is
    /// what the guard was written for: an invented "Thank you." arriving
    /// mid-answer used to cancel the answer. A courtesy spoken into a quiet
    /// appliance is a thing to reply to.
    func testACourtesyAfterAFinishedTurnIsAnsweredRatherThanSwallowed() async throws {
        let socket = CallCeilingTests.scratchSocket()
        defer { try? FileManager.default.removeItem(at: socket) }

        let spoken = SaidAloud()
        let heard = OneThingThenAnother("what's still open", then: "thanks")
        let server = CallTurnServer(
            configuration: CallTurnServer.Configuration(socketURL: socket, turnCeilingSeconds: 5),
            transcriber: heard,
            synthesizer: RecordingVoice(spoken),
            answer: { asked in
                asked.contains("thanks") ? "Any time." : "The visa form is still open."
            },
            log: { _ in }
        )

        let running = Task { try? await server.run() }
        defer { running.cancel() }
        let caller = try await CallCeilingTests.connect(to: socket)
        defer { close(caller) }
        CallCeilingTests.drain(caller)
        let writer = CallFrameWriter(descriptor: caller)

        // Turn one, driven all the way to its answer so `turn` holds a task that
        // has finished — the state the old predicate could not distinguish from
        // one still running.
        try writer.send(.utterance(CallCeilingTests.aSecondOfSpeech()))
        let first = await spoken.waitFor("visa form", within: 10)
        let afterOne = await spoken.everything()
        XCTAssertNotNil(first, "the first turn never answered: \(afterOne)")

        // Now the courtesy.
        try writer.send(.utterance(CallCeilingTests.aSecondOfSpeech()))

        let answered = await spoken.waitFor("any time", within: 10)
        let everything = await spoken.everything()
        XCTAssertNotNil(
            answered,
            """
            the appliance went mute on a caller who thanked it. Everything said: \
            \(everything)
            """
        )
    }

    /// The property the guard exists for, which must survive the fix.
    ///
    /// Without this the whole thing could be "fixed" by deleting the guard, and
    /// the failure that put it there — nine phantom "Thank you."s in one call,
    /// each cancelling the answer being prepared — would come straight back.
    func testACourtesyDuringWorkStillDoesNotTakeTheAnswerAway() async throws {
        let socket = CallCeilingTests.scratchSocket()
        defer { try? FileManager.default.removeItem(at: socket) }

        let spoken = SaidAloud()
        let letGo = Gate()
        let heard = OneThingThenAnother("what's still open", then: "thank you")
        let server = CallTurnServer(
            configuration: CallTurnServer.Configuration(socketURL: socket, turnCeilingSeconds: 20),
            transcriber: heard,
            synthesizer: RecordingVoice(spoken),
            answer: { asked in
                guard !asked.contains("thank") else { return "Any time." }
                // Held open so the courtesy lands mid-turn, which is the whole
                // case: the answer must survive it.
                await letGo.wait()
                return "The visa form is still open."
            },
            log: { _ in }
        )

        let running = Task { try? await server.run() }
        defer { running.cancel() }
        let caller = try await CallCeilingTests.connect(to: socket)
        defer { close(caller) }
        CallCeilingTests.drain(caller)
        let writer = CallFrameWriter(descriptor: caller)

        try writer.send(.utterance(CallCeilingTests.aSecondOfSpeech()))
        // Long enough for the turn to be genuinely in flight and its opener said.
        try await Task.sleep(for: .milliseconds(400))
        try writer.send(.utterance(CallCeilingTests.aSecondOfSpeech()))
        try await Task.sleep(for: .milliseconds(400))
        await letGo.open()

        let answered = await spoken.waitFor("visa form", within: 10)
        let everything = await spoken.everything()
        XCTAssertNotNil(
            answered,
            """
            a courtesy arriving mid-turn took the answer away, which is the \
            failure the guard exists to prevent. Everything said: \
            \(everything)
            """
        )
    }

    /// The watchdog has to outlive a turn.
    ///
    /// `quietFor` returns nil while a turn is in flight, and the watch treated
    /// nil as a reason to `return` out of its loop for good — so it died at the
    /// first utterance of the first call and never checked in on, or hung up, an
    /// abandoned one again. A call left open holds a live microphone.
    ///
    /// Driven through the real check-in rather than by inspecting state, because
    /// the bug was in the loop rather than in the predicate alone.
    func testTheIdleWatchStillChecksInAfterATurnHasHappened() async throws {
        let socket = CallCeilingTests.scratchSocket()
        defer { try? FileManager.default.removeItem(at: socket) }

        let spoken = SaidAloud()
        let server = CallTurnServer(
            configuration: CallTurnServer.Configuration(socketURL: socket, turnCeilingSeconds: 5),
            transcriber: Always("what's still open"),
            synthesizer: RecordingVoice(spoken),
            answer: { _ in "The visa form is still open." },
            log: { _ in }
        )

        let running = Task { try? await server.run() }
        defer { running.cancel() }
        let caller = try await CallCeilingTests.connect(to: socket)
        defer { close(caller) }
        CallCeilingTests.drain(caller)

        try CallFrameWriter(descriptor: caller).send(.utterance(CallCeilingTests.aSecondOfSpeech()))
        let itAnswered = await spoken.waitFor("visa form", within: 10)
        XCTAssertNotNil(
            itAnswered,
            "the turn never answered, so this proves nothing about the watch"
        )

        // The watch's own state, after a completed turn. Asking it directly
        // rather than waiting out the real 60-second check-in: the property is
        // that it still knows the line is quiet, and a minute of wall clock in
        // the suite buys nothing extra.
        //
        // **Polled, because the synthesiser being called is not the turn being
        // over.** `waitFor` above returns when `RecordingVoice` is handed a
        // sentence; the turn still has to write the audio and `replyEnd` and
        // then retire itself. Those writes go off the actor now, so this read
        // could land in the gap — which it did, in the full suite but never
        // alone, exactly the shape of a test that was passing by timing.
        //
        // Bounded, so the defect this exists for still fails it: that bug made
        // `quietFor` return nil for the rest of the process, and no amount of
        // waiting turns that into an answer.
        var quiet: TimeInterval?
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            quiet = await server.quietForTesting()
            if quiet != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }

        XCTAssertNotNil(
            quiet,
            """
            the watch believes a turn is still running after one finished, so it \
            stops looking — and an abandoned call stays open with a live \
            microphone until the daemon restarts
            """
        )
    }

    /// A second question after a finished answer is not an interruption.
    ///
    /// `cutIn` chooses between two openings, and the interrupted one exists to
    /// tell a caller who talked over the appliance that it heard them rather
    /// than merely stopped. Said in response to an ordinary follow-up it is
    /// simply wrong, and it was said for every follow-up after the first turn.
    func testAFollowUpAfterAFinishedAnswerIsNotTreatedAsAnInterruption() async throws {
        let socket = CallCeilingTests.scratchSocket()
        defer { try? FileManager.default.removeItem(at: socket) }

        let spoken = SaidAloud()
        let server = CallTurnServer(
            configuration: CallTurnServer.Configuration(socketURL: socket, turnCeilingSeconds: 5),
            transcriber: OneThingThenAnother("what's still open", then: "and what about friday"),
            synthesizer: RecordingVoice(spoken),
            answer: { asked in
                asked.contains("friday") ? "Friday is clear." : "The visa form is still open."
            },
            log: { _ in }
        )

        let running = Task { try? await server.run() }
        defer { running.cancel() }
        let caller = try await CallCeilingTests.connect(to: socket)
        defer { close(caller) }
        CallCeilingTests.drain(caller)
        let writer = CallFrameWriter(descriptor: caller)

        try writer.send(.utterance(CallCeilingTests.aSecondOfSpeech()))
        let firstAnswer = await spoken.waitFor("visa form", within: 10)
        XCTAssertNotNil(firstAnswer)
        let afterFirst = await spoken.everything()

        try writer.send(.utterance(CallCeilingTests.aSecondOfSpeech()))
        let followUp = await spoken.waitFor("friday is clear", within: 10)
        let everything = await spoken.everything()
        XCTAssertNotNil(followUp, "the follow-up never answered: \(everything)")

        // Only what was said in response to the second question.
        let second = Array(everything.dropFirst(afterFirst.count))
        // An interrupted opening is exactly the one that leads with an
        // acknowledgement of having cut in — "Right —", "Okay —", "Sure —" —
        // which is what `WorkingReply.interruptedOpening` prefixes and what an
        // ordinary opener never does.
        let acknowledgements = ["Right —", "Okay —", "Sure —"]
        XCTAssertEqual(
            second.filter { line in acknowledgements.contains { line.hasPrefix($0) } }, [],
            """
            an ordinary follow-up got the opening reserved for a caller who \
            talked over the appliance: \(second)
            """
        )
    }
}

// MARK: - Fixtures

/// Opens once, for holding an answer in flight.
private actor Gate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        let resume = waiting
        waiting = []
        resume.forEach { $0.resume() }
    }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiting.append($0) }
    }
}

/// Everything handed to the synthesiser, in order.
private actor SaidAloud {
    private var lines: [String] = []

    func add(_ line: String) { lines.append(line) }
    func everything() -> [String] { lines }

    func waitFor(_ fragment: String, within seconds: TimeInterval) async -> String? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let found = lines.first(where: { $0.localizedCaseInsensitiveContains(fragment) }) {
                return found
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return nil
    }
}

private struct Always: AudioFileTranscribing {
    let words: String
    init(_ words: String) { self.words = words }
    func transcribe(audioFile: URL, options: AudioTranscriptionOptions) async throws -> String { words }
}

/// Hears one thing, then a different thing for ever after.
///
/// The second utterance is the whole point of this file — the bug lived entirely
/// in what the appliance believed once a turn had finished.
private final class OneThingThenAnother: AudioFileTranscribing, @unchecked Sendable {
    private let first: String
    private let rest: String
    private let lock = NSLock()
    private var served = 0

    init(_ first: String, then rest: String) {
        self.first = first
        self.rest = rest
    }

    func transcribe(audioFile: URL, options: AudioTranscriptionOptions) async throws -> String {
        lock.lock()
        defer { lock.unlock() }
        served += 1
        return served == 1 ? first : rest
    }
}

/// Records what it was asked to say and returns a small valid WAV.
private struct RecordingVoice: SpeechSynthesizing {
    let identifier = "records"
    let defaultVoice = "none"
    private let said: SaidAloud

    init(_ said: SaidAloud) { self.said = said }

    func isAvailable() async -> Bool { true }

    func synthesize(_ request: SpeechRequest) async throws -> SynthesizedSpeech {
        await said.add(request.text)
        var wav = Data()
        wav.append(contentsOf: Array("RIFF".utf8))
        wav.append(contentsOf: [0, 0, 0, 0])
        wav.append(contentsOf: Array("WAVE".utf8))
        wav.append(contentsOf: Array("fmt ".utf8))
        wav.append(contentsOf: [16, 0, 0, 0])
        wav.append(contentsOf: [UInt8](repeating: 0, count: 16))
        wav.append(contentsOf: Array("data".utf8))
        wav.append(contentsOf: [4, 0, 0, 0])
        wav.append(contentsOf: [0x10, 0x00, 0x20, 0x00])
        return SynthesizedSpeech(
            wav: wav,
            sampleRate: 48_000,
            channelCount: 1,
            duration: 0.001,
            timeToFirstAudio: 0,
            generationDuration: 0
        )
    }
}
#endif  // os(macOS)
