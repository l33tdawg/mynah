import XCTest
@testable import SageVoiceCore

/// **A call opens on the conversation, or it opens with hello.**
///
/// The owner, twice: *"most likely i'm calling you to continue the
/// conversation"*, and *"skip the open items on task list - look at what we
/// were last talking about via text"*.
///
/// Measured against that on 8 August 2026, on 2.0.0-beta.5, his own call:
///
///     12:31:50 [call] opening ready in 5.3s: Morning. Only thing open is the
///              Cayenne — still set for this afternoon from Prestige. Have you
///              picked it up yet, or is that still ahead of you?
///
/// That is the task list, read out, on a call whose prompt has said *"Do not
/// read my task list out"* since the day it was written. The daemon had started
/// at 06:44 and nothing had been said in messages since, so `recentMessages`
/// was nil — there was no thread to carry on, and a model asked for "the one
/// thing that is still open between us" with nothing to continue found
/// something open in the backlog instead.
///
/// So the ban is no longer the only thing holding: with nothing to pick up
/// there is now no model call at all. A rule the model cannot be talked out of
/// beats a rule it is asked to keep, and it costs a turn and a tool round trip
/// less on exactly the calls where the briefing had nothing to add.
final class OpeningOnTheThreadTests: XCTestCase {

    private func server(
        recent: String?,
        calls: Calls,
        synthesizer: any SpeechSynthesizing = SpeaksAtOnce()
    ) async -> CallTurnServer {
        let server = CallTurnServer(
            configuration: CallTurnServer.Configuration(),
            transcriber: SaysNothing(),
            synthesizer: synthesizer,
            answer: { _ in
                calls.record("answer")
                return "answered"
            },
            log: { _ in }
        )
        await server.onRecentMessages { recent }
        await server.onBriefing { request in
            calls.record("brief")
            calls.record(request)
            return "Picking up where we left off, then."
        }
        return server
    }

    // MARK: Nothing to pick up

    /// **The change, stated as the thing that must not happen.** No thread means
    /// no model call — not a model call whose prompt asks it to be brief.
    func testACallWithNothingToPickUpNeverAsksTheModel() async {
        let calls = Calls()
        let server = await server(recent: nil, calls: calls)

        await server.prepare()
        _ = await server.openingForTesting()

        XCTAssertEqual(
            calls.recorded, [],
            "a call with no thread to continue still ran a brain turn"
        )
    }

    /// Whitespace is not a conversation. `recentMessagesForCall` returns a
    /// joined string, and a history of empty assistant turns joins to blanks.
    func testAThreadOfWhitespaceIsNotAThread() async {
        let calls = Calls()
        let server = await server(recent: "   \n  ", calls: calls)

        await server.prepare()
        _ = await server.openingForTesting()

        XCTAssertEqual(calls.recorded, [])
    }

    /// **And the caller still hears something.** The point of skipping the
    /// briefing is to save a turn, not to answer the phone with silence — which
    /// is the failure `buildOpening` was written to prevent in the first place.
    func testACallWithNothingToPickUpStillHasAnOpeningReady() async {
        let calls = Calls()
        let server = await server(recent: nil, calls: calls)

        await server.prepare()
        let opening = await server.openingForTesting()

        XCTAssertNotNil(opening, "the phone would be answered with nothing at all")
    }

    // MARK: Something to pick up

    func testACallWithAThreadAsksTheModelAndCarriesTheThreadIn() async {
        let calls = Calls()
        let server = await server(recent: "Me: did the ferry booking come through?", calls: calls)

        await server.prepare()
        _ = await server.openingForTesting()

        XCTAssertTrue(calls.recorded.contains("brief"), "a live thread was not briefed on")
        XCTAssertTrue(
            calls.recorded.contains { $0.contains("did the ferry booking come through?") },
            "the briefing was run without the thread it exists to continue"
        )
    }

    /// **Through `brief`, never through `answer`.** They differ in one respect
    /// and it is the whole of this change: the daemon's `answer` closure ends in
    /// `callHistory.remember`, so a briefing run through it becomes turn zero of
    /// the call — in the owner's voice, for words he never said.
    func testTheBriefingNeverGoesThroughTheAnsweringPath() async {
        let calls = Calls()
        let server = await server(recent: "Me: still thinking about the roof", calls: calls)

        await server.prepare()
        _ = await server.openingForTesting()

        XCTAssertFalse(
            calls.recorded.contains("answer"),
            "the briefing went through the closure that writes the conversation"
        )
    }

    // MARK: What the conversation starts with

    /// The opening is kept, because the caller's first sentence answers it.
    func testTheOpeningTheCallerHeardStartsTheConversation() async {
        let history = CallHistory()

        await history.open(with: "Morning. Did the ferry booking come through?")
        let messages = await history.recent()

        XCTAssertEqual(messages.count, 1, "a call started with more than the sentence he heard")
        XCTAssertEqual(messages.first?.role, .assistant)
        XCTAssertEqual(messages.first?.content, "Morning. Did the ferry booking come through?")
    }

    /// A call starts on itself. The previous one reaches the model as
    /// `LastCall.closing`, labelled as what it is, rather than as more of this
    /// conversation.
    func testANewCallDoesNotOpenInTheMiddleOfTheLastOne() async {
        let history = CallHistory()
        await history.remember([
            BrainMessage(role: .user, content: "what time is the ferry"),
            BrainMessage(role: .assistant, content: "half two")
        ])

        await history.open(with: "Hey — what's up?")
        let messages = await history.recent()

        XCTAssertEqual(messages.map(\.content), ["Hey — what's up?"])
    }

    func testAnOpeningOfNothingStartsAnEmptyConversation() async {
        let history = CallHistory()
        await history.open(with: "   ")
        let messages = await history.recent()

        XCTAssertTrue(messages.isEmpty, "an empty assistant turn was stored, which bricks a thread")
    }

    // MARK: The words

    /// **The phrase that invited it, and the ban that did not hold alone.**
    ///
    /// The request used to ask for "the one thing that is still open between
    /// us" two lines above "Do not read my task list out". "Open" is the word
    /// the backlog uses for its own rows, and the model resolved the collision
    /// the way the collision invited.
    func testTheBriefingNeverAsksForWhatIsOpen() {
        let request = CallTurnServer.briefingRequest(
            now: Date(timeIntervalSince1970: 1_754_600_000),
            sinceLastCall: 3600,
            recentMessages: "Me: about the roof"
        )

        XCTAssertFalse(
            request.lowercased().contains("still open"),
            "the request still asks for what is open, which is what the task list calls its rows"
        )
        XCTAssertTrue(request.contains("Do not read my task list out"))
    }

    /// Having nothing to say is a complete answer, said in the request in those
    /// words — because the failure was not the model disobeying an instruction,
    /// it was the model filling a silence the instruction left it holding.
    func testTheBriefingSaysThatHavingNothingToSayIsEnough() {
        let request = CallTurnServer.briefingRequest(
            now: Date(timeIntervalSince1970: 1_754_600_000),
            sinceLastCall: nil,
            recentMessages: "Me: about the roof"
        )

        XCTAssertTrue(
            request.contains("do not go looking for one"),
            "nothing stops the model hunting for a list when the thread runs dry"
        )
        XCTAssertTrue(request.contains("That is a complete answer"))
    }

    // MARK: The wiring

    /// A source scan, for the reason the identity and after-the-call guards are
    /// source scans: the executable target cannot be imported, and what must not
    /// come back is a *shape* — the briefing being remembered — rather than any
    /// particular runtime value.
    func testTheDaemonRunsTheBriefingWithNoHistoryAndKeepsNoneOfIt() throws {
        let main = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/sage-voiced/main.swift"),
            encoding: .utf8
        )

        guard let start = main.range(of: "callServer.onBriefing"),
              let end = main.range(of: "callServer.onOpeningSpoken") else {
            return XCTFail("the daemon no longer wires onBriefing and onOpeningSpoken")
        }
        let block = String(main[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(
            block.contains("history: []"),
            "the briefing is being fed the previous call's tail as well as its labelled closing"
        )
        XCTAssertFalse(
            block.contains("callHistory.remember"),
            "the briefing request is being written into the conversation again"
        )
        XCTAssertTrue(
            main.contains("callHistory.open(with: opening)"),
            "nothing starts the conversation at the sentence the caller heard"
        )
    }
}

// MARK: - Stubs

/// Records what the server reached for, in order.
private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func record(_ what: String) {
        lock.lock()
        defer { lock.unlock() }
        stored.append(what)
    }

    var recorded: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

/// The recognition warm-up runs on every `prepare()` and is not what these
/// tests are about — see `RecognitionWarmupTests` for that half.
private struct SaysNothing: AudioFileTranscribing {
    func transcribe(audioFile: URL, options: AudioTranscriptionOptions) async throws -> String { "" }
}

private struct SpeaksAtOnce: SpeechSynthesizing {
    let identifier = "instant"
    let defaultVoice = "test"
    func isAvailable() async -> Bool { true }
    func synthesize(_ request: SpeechRequest) async throws -> SynthesizedSpeech {
        let wav = CallTurnServer.silence(milliseconds: 40)
        return SynthesizedSpeech(
            wav: wav,
            sampleRate: 16000,
            channelCount: 1,
            duration: 0.04,
            timeToFirstAudio: 0,
            generationDuration: 0
        )
    }
}
