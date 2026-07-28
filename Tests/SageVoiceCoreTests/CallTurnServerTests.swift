import XCTest
@testable import SageVoiceCore

final class CallTurnServerTests: XCTestCase {

    // MARK: - Finding the audio in a WAV

    /// afconvert writes a LIST chunk before the audio.
    ///
    /// Every example of WAV parsing starts the data at byte 44, which is right
    /// only for the simplest possible file. afconvert describes its encoder in a
    /// LIST chunk first, so the fixed offset hands several hundred bytes of
    /// metadata to the Opus encoder as though it were audio — a burst of noise
    /// at the front of every single reply.
    func testTheDataChunkIsFoundEvenBehindAListChunk() {
        var wav = Data()
        wav.append(contentsOf: Array("RIFF".utf8))
        wav.append(contentsOf: [0, 0, 0, 0])
        wav.append(contentsOf: Array("WAVE".utf8))

        // fmt
        wav.append(contentsOf: Array("fmt ".utf8))
        wav.append(contentsOf: [16, 0, 0, 0])
        wav.append(contentsOf: [UInt8](repeating: 0, count: 16))

        // The chunk that breaks the naive parser.
        let listPayload = [UInt8](repeating: 0xAB, count: 120)
        wav.append(contentsOf: Array("LIST".utf8))
        wav.append(contentsOf: [UInt8(listPayload.count), 0, 0, 0])
        wav.append(contentsOf: listPayload)

        let audio: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0xFF, 0x7F]
        wav.append(contentsOf: Array("data".utf8))
        wav.append(contentsOf: [UInt8(audio.count), 0, 0, 0])
        wav.append(contentsOf: audio)

        let found = CallTurnServer.samples(fromWAV: wav)
        XCTAssertEqual(
            [UInt8](found), audio,
            "the data chunk was not located; a fixed 44-byte offset would send "
                + "the LIST chunk to the encoder as audio"
        )
    }

    func testAWavWithNoDataChunkYieldsNothingRatherThanGarbage() {
        var wav = Data()
        wav.append(contentsOf: Array("RIFF".utf8))
        wav.append(contentsOf: [0, 0, 0, 0])
        wav.append(contentsOf: Array("WAVE".utf8))
        wav.append(contentsOf: Array("fmt ".utf8))
        wav.append(contentsOf: [16, 0, 0, 0])
        wav.append(contentsOf: [UInt8](repeating: 0, count: 16))

        XCTAssertTrue(CallTurnServer.samples(fromWAV: wav).isEmpty)
        XCTAssertTrue(CallTurnServer.samples(fromWAV: Data()).isEmpty)
        XCTAssertTrue(CallTurnServer.samples(fromWAV: Data([0x01, 0x02])).isEmpty)
    }

    // MARK: - Splitting a reply for synthesis

    /// The reply is spoken sentence by sentence so the caller hears the start of
    /// the answer while the rest is still being made.
    func testAReplyIsSplitIntoSentences() {
        let pieces = CallTurnServer.sentences(
            in: "I found three suppliers near you. The closest is on Sukhumvit 51. "
                + "Want me to send the details?"
        )
        XCTAssertEqual(pieces.count, 3, "got \(pieces)")
        XCTAssertTrue(pieces[0].hasPrefix("I found three"))
        XCTAssertTrue(pieces[2].hasSuffix("?"))
    }

    /// A short opener must not become its own subprocess.
    ///
    /// "Sure." is a whole `say` invocation and an afconvert for a quarter second
    /// of audio, and the seam between it and the next sentence is audible.
    func testAShortFragmentIsJoinedRatherThanSpokenAlone() {
        let pieces = CallTurnServer.sentences(in: "Sure. Nether Studio is the one on Sukhumvit 51.")
        XCTAssertEqual(pieces.count, 1, "a two-word opener was split off: \(pieces)")
    }

    func testATrailingFragmentIsNotLost() {
        let pieces = CallTurnServer.sentences(
            in: "That should be everything you asked for today. And one more thing"
        )
        XCTAssertEqual(pieces.joined(separator: " ").contains("And one more thing"), true,
                       "the tail after the last full stop was dropped: \(pieces)")
    }

    func testAReplyWithNoPunctuationIsStillSpoken() {
        let pieces = CallTurnServer.sentences(in: "yes")
        XCTAssertEqual(pieces, ["yes"])
    }

    // MARK: - The wire format

    func testFramesEncodeWithATypeAndABigEndianLength() {
        let frame = CallFrame.utterance(Data([0xAA, 0xBB, 0xCC]))
        let encoded = frame.encoded

        XCTAssertEqual(encoded.count, 5 + 3)
        XCTAssertEqual(encoded[0], 1)
        XCTAssertEqual([UInt8](encoded[1...4]), [0, 0, 0, 3])
        XCTAssertEqual([UInt8](encoded[5...]), [0xAA, 0xBB, 0xCC])
    }

    func testEmptyFramesCarryNoPayload() {
        for frame in [CallFrame.interrupted, CallFrame.replyEnd] {
            let encoded = frame.encoded
            XCTAssertEqual(encoded.count, 5, "\(frame) should be a header and nothing else")
            XCTAssertEqual([UInt8](encoded[1...4]), [0, 0, 0, 0])
        }
    }

    func testEveryKindSurvivesADecode() {
        let frames: [CallFrame] = [
            .utterance(Data([1, 2, 3])),
            .replyAudio(Data([4, 5])),
            .interrupted,
            .replyEnd,
            .turnFailed("the model timed out")
        ]
        for frame in frames {
            let encoded = frame.encoded
            let decoded = CallFrame.decode(kind: encoded[0], payload: Data(encoded[5...]))
            XCTAssertEqual(decoded, frame)
        }
    }

    /// The kinds must match the Go side exactly, and a number is the easiest
    /// thing in the world to change on one side only.
    func testKindNumbersMatchTheEndpoint() {
        XCTAssertEqual(CallFrame.utterance(Data()).kind, 1)
        XCTAssertEqual(CallFrame.replyAudio(Data()).kind, 2)
        XCTAssertEqual(CallFrame.interrupted.kind, 3)
        XCTAssertEqual(CallFrame.replyEnd.kind, 4)
        XCTAssertEqual(CallFrame.turnFailed("").kind, 5)
    }

    // MARK: - The actor must stay reachable while it is waiting

    /// A running call server must still answer calls into it.
    ///
    /// `run()` spends nearly all its time blocked in accept(), waiting for a
    /// call that may never come. Doing that on the actor makes every other entry
    /// point unreachable — and the two that matter arrive precisely when nothing
    /// is connected: setting the transcript sink at startup, and preparing an
    /// opening when //call is typed.
    ///
    /// This deadlocked the daemon's own startup. It never reached Signal, so the
    /// appliance answered nothing at all, and the log simply stopped after
    /// "[call] ready".
    func testTheServerStaysReachableWhileWaitingForACall() async throws {
        let socket = FileManager.default.temporaryDirectory
            .appendingPathComponent("mynah-test-\(UUID().uuidString).sock")
        defer { try? FileManager.default.removeItem(at: socket) }

        let server = CallTurnServer(
            configuration: CallTurnServer.Configuration(socketURL: socket),
            transcriber: NeverTranscribes(),
            synthesizer: NeverSpeaks(),
            answer: { _ in "" },
            log: { _ in }
        )

        let running = Task { try? await server.run() }
        defer { running.cancel() }

        // Give it a moment to reach accept().
        try await Task.sleep(for: .milliseconds(300))

        // If the actor is parked in a blocking syscall this never returns.
        let reached = Task {
            await server.onTranscript { _ in }
            return true
        }
        let answered = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask { await reached.value }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }

        XCTAssertTrue(
            answered,
            "the call server did not answer while waiting for a call; a blocking "
                + "accept() on the actor deadlocks startup and the appliance never "
                + "connects to Signal"
        )
    }
}

private struct NeverTranscribes: AudioFileTranscribing {
    func transcribe(audioFile: URL, options: AudioTranscriptionOptions) async throws -> String { "" }
}

private struct NeverSpeaks: SpeechSynthesizing {
    let identifier = "never"
    let defaultVoice = "none"
    func isAvailable() async -> Bool { false }
    func synthesize(_ request: SpeechRequest) async throws -> SynthesizedSpeech {
        throw SpeechSynthesisError.requestFailed("not in this test")
    }
}
