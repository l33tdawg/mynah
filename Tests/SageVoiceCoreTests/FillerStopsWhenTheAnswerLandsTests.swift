import XCTest
@testable import SageVoiceCore

/// The filler must stop the moment the answer arrives, not when the turn ends.
///
/// ## The regression
///
/// `speak` starts an unstructured task that says "One moment.", "Nearly there."
/// on `CallFiller`'s cadence while the model thinks. It used to be cancelled on
/// the line after the answer came back. Widening that cover to a `defer` — so
/// the paths that throw are covered too — moved it to *scope exit*, which is
/// after the per-sentence synthesise-and-send loop, after `replyEnd`, and after
/// `afterSpeaking()`.
///
/// So the filler stayed alive for the whole time the answer was being spoken and
/// kept waking on its cadence. The caller hears "Nearly there." spliced between
/// two sentences of the answer he is already listening to.
///
/// The fix is both: cancel where the answer lands, keep the defer as the
/// backstop for the paths that never reach it.
final class FillerStopsWhenTheAnswerLandsTests: XCTestCase {

    /// **Held open long enough for the first filler, then answered.**
    ///
    /// **The timing is the test, and the first version of it had the timing
    /// wrong.**
    ///
    /// `CallFiller`'s ladder is cumulative: line one at 6s, line two at 12s,
    /// then 20s and 26s. The answer is held to 7s so line one genuinely fires —
    /// otherwise the absence of line two proves nothing. Then three sentences at
    /// 2.6s of synthesis each keep the speaking phase running to about 14.8s,
    /// which is *past* the 12s slot line two would take.
    ///
    /// That last part is what makes it a guard. The first draft used 0.9s
    /// pauses, so the turn finished around 9.7s and the defer fired before line
    /// two was ever due — the test passed against the defect, which is precisely
    /// the class of thing this suite keeps having to catch in itself. Verified
    /// by mutation: with the eager cancel removed, this fails.
    func testNoFillerIsSpokenOnceTheAnswerHasArrived() async throws {
        let socket = CallCeilingTests.scratchSocket()
        defer { try? FileManager.default.removeItem(at: socket) }

        let spoken = SaidLines()
        let server = CallTurnServer(
            configuration: CallTurnServer.Configuration(socketURL: socket, turnCeilingSeconds: 60),
            transcriber: Hears("what's still open"),
            synthesizer: SlowVoice(spoken, pause: 2.6),
            answer: { _ in
                // Past the first filler at 6s, comfortably short of the second
                // at 12s.
                try? await Task.sleep(for: .seconds(7))
                return "The visa form is still open. The dentist moved to Friday. Nothing else is open."
            },
            log: { _ in }
        )

        let running = Task { try? await server.run() }
        defer { running.cancel() }
        let caller = try await CallCeilingTests.connect(to: socket)
        defer { close(caller) }
        CallCeilingTests.drain(caller)

        try CallFrameWriter(descriptor: caller).send(.utterance(CallCeilingTests.aSecondOfSpeech()))

        // Wait until the whole answer has been spoken. Three sentences at 0.9s
        // of synthesis each, plus the 7s think, plus the opening.
        let finished = await spoken.waitFor("Nothing else is open", within: 30)
        let duringTheTurn = await spoken.everything()
        XCTAssertNotNil(finished, "the answer was never spoken: \(duringTheTurn)")

        // **Sampled after the slot, not when the last sentence was handed over.**
        //
        // `waitFor` returns the moment the final sentence reaches the
        // synthesiser, which is several seconds before the turn actually ends —
        // and filler line two is due at 12s, inside that gap. Reading the
        // transcript at `waitFor` therefore sampled *before* the thing being
        // tested for could happen, and the test passed against the defect. Third
        // timing mistake in this one test; it is why the mutation check is not
        // optional.
        try await Task.sleep(for: .seconds(6))
        let said = await spoken.everything()
        let fillers = said.filter { CallFiller.isAFillerLine($0) }
        let answerAt = said.firstIndex { $0.contains("visa form") } ?? said.count
        let fillersAfterTheAnswer = said.enumerated()
            .filter { $0.offset > answerAt && CallFiller.isAFillerLine($0.element) }
            .map(\.element)

        XCTAssertFalse(
            fillers.isEmpty,
            "no filler fired at all, so this test cannot show that the second one was stopped: \(said)"
        )
        XCTAssertEqual(
            fillersAfterTheAnswer, [],
            """
            a filler was spoken after the answer had started. The caller hears \
            "\(fillersAfterTheAnswer.first ?? "")" between two sentences of the \
            answer he is already listening to. Everything said: \(said)
            """
        )
    }
}

/// Whether a line came from the filler ladder rather than from the model.
///
/// Membership of the pools, not a sample of `line(at:previous:)` — that picks
/// randomly within a pool, so comparing against one draw misses two thirds of
/// them. The first version of this test did exactly that and reported "no filler
/// fired" while "Okay…" sat in the transcript.
extension CallFiller {
    static var everyLine: Set<String> { Set(CallFiller.pools.flatMap { $0 }) }
    static func isAFillerLine(_ line: String) -> Bool { everyLine.contains(line) }
}

private struct Hears: AudioFileTranscribing {
    let words: String
    init(_ words: String) { self.words = words }
    func transcribe(audioFile: URL, options: AudioTranscriptionOptions) async throws -> String { words }
}

private actor SaidLines {
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

/// Records what it was asked to say, slowly — so the speaking phase is a real
/// window rather than an instant.
private struct SlowVoice: SpeechSynthesizing {
    let identifier = "slow"
    let defaultVoice = "none"
    private let said: SaidLines
    private let pause: TimeInterval

    init(_ said: SaidLines, pause: TimeInterval) {
        self.said = said
        self.pause = pause
    }

    func isAvailable() async -> Bool { true }

    /// **Slow for the answer, instant for the fillers.**
    ///
    /// Slowing everything was the second timing mistake in this test: the filler
    /// loop calls the synthesiser too, so a 2.6s pause on its own line pushed
    /// the next filler from 12s out to ~14.6s — past the end of the turn — and
    /// the test passed against the defect again. Only the answer needs to take
    /// time; the ladder must run on its real cadence.
    func synthesize(_ request: SpeechRequest) async throws -> SynthesizedSpeech {
        await said.add(request.text)
        if !CallFiller.isAFillerLine(request.text) {
            try? await Task.sleep(for: .seconds(pause))
        }
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
            wav: wav, sampleRate: 48_000, channelCount: 1,
            duration: 0.001, timeToFirstAudio: 0, generationDuration: 0
        )
    }
}
