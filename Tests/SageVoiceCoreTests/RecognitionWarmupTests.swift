import XCTest
@testable import SageVoiceCore

/// **The first thing a caller says is transcribed by a cold model.**
///
/// Measured on the owner's call, 6 August 2026:
///
///     15:38:40 [asr] transcribed  54kB in 10.7s — somebody else's server
///     15:38:43 [asr] transcribed  32kB in  2.0s — somebody else's server
///     15:38:57 [asr] transcribed 111kB in  1.2s — somebody else's server
///
/// Twice the audio in a ninth of the time, three turns later. Not a cold
/// *process*: `ManagedWhisperKitTranscriber` appends ", after Ns starting it"
/// whenever the supervisor spent over half a second, and none of those lines
/// carry it. The server was up with its weights unloaded — on that Mac it is
/// QuietType's, which Mynah can neither start nor stop, so the only way to make
/// it load them is to ask it to transcribe something.
///
/// The caller pays it twice over, because the opener cannot fire until there is
/// a transcript to react to. The first filler on that call came at 11.5s and
/// every one after it at 1.8s.
///
/// **`//call` already buys several seconds of warning**, and `prepare()` already
/// spends them on the brain and the voice. It never spent them on recognition —
/// though the call site's comment said it did, and three pieces written for the
/// job (`silence(_:)`, `startWarming()`, `warmupTimeoutSeconds`) sat with no
/// callers between them.
final class RecognitionWarmupTests: XCTestCase {

    // MARK: - The warm-up happens at all

    func testPreparingACallWarmsRecognition() async throws {
        let ear = CountingEar()
        let server = CallTurnServer(
            configuration: CallTurnServer.Configuration(),
            transcriber: ear,
            synthesizer: NeverSpeaks(),
            answer: { _ in "" },
            log: { _ in }
        )

        await server.prepare()
        try await Task.sleep(for: .milliseconds(400))

        let warmed = await ear.count
        XCTAssertEqual(warmed, 1, "//call did not warm the transcriber")
    }

    /// **It must send real audio.** A warm-up that posts an empty file gets a
    /// fast rejection and loads nothing, which would look identical from the
    /// outside — the request happened, the log line printed, and the caller
    /// still waits 10.7s.
    func testTheWarmUpActuallySendsAudio() async throws {
        let ear = CountingEar()
        let server = CallTurnServer(
            configuration: CallTurnServer.Configuration(),
            transcriber: ear,
            synthesizer: NeverSpeaks(),
            answer: { _ in "" },
            log: { _ in }
        )

        await server.prepare()
        try await Task.sleep(for: .milliseconds(400))

        let audio = await ear.lastAudioBytes
        XCTAssertGreaterThan(audio ?? 0, 44, "no samples, only a header — nothing would load")
    }

    /// **`//call` pressed repeatedly must not pile warm-ups onto the server.**
    ///
    /// Counting invocations would not catch this: five sequential warm-ups and
    /// five concurrent ones both invoke the transcriber five times, and only the
    /// second is a problem. What matters is how many are in flight at once, so
    /// that is what this measures — without the `cancel()` in `prepare()` the
    /// peak is 5.
    func testRepeatedCallRequestsNeverRunTwoWarmUpsAtOnce() async throws {
        let ear = SlowEar()
        let server = CallTurnServer(
            configuration: CallTurnServer.Configuration(),
            transcriber: ear,
            synthesizer: NeverSpeaks(),
            answer: { _ in "" },
            log: { _ in }
        )

        for _ in 0..<5 {
            await server.prepare()
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(200))

        let peak = await ear.peakInFlight
        XCTAssertEqual(peak, 1, "\(peak) warm-ups ran at once; the previous one is not cancelled")
    }

    // MARK: - And never costs the caller anything

    /// **The guarantee that matters.** `handle(connection:)` awaits
    /// `preparation` before its read loop, so anything folded into that task
    /// delays the greeting by its own duration — and a warm-up is by definition
    /// the slow thing. A transcriber that never returns must not hold up the
    /// opening by one millisecond.
    func testASlowWarmUpDoesNotDelayTheOpening() async throws {
        let server = CallTurnServer(
            configuration: CallTurnServer.Configuration(),
            transcriber: NeverReturns(),
            synthesizer: SpeaksInstantly(),
            answer: { _ in "ready" },
            log: { _ in }
        )

        await server.prepare()
        let started = Date()
        let opening = await server.openingForTesting()
        let waited = Date().timeIntervalSince(started)

        XCTAssertNotNil(opening, "the opening never arrived")
        XCTAssertLessThan(waited, 2.0, "the opening waited on the warm-up: \(waited)s")
    }

    /// A warm-up that throws is the ORDINARY case, not the exceptional one.
    /// Silence is exactly what Whisper confabulates over, so `emptyTranscript`
    /// and `noiseOnlyTranscript` are what a correct server returns here. The
    /// transcript was never the point; the model load was.
    func testAWarmUpThatFailsIsNotACallFailure() async throws {
        let server = CallTurnServer(
            configuration: CallTurnServer.Configuration(),
            transcriber: AlwaysThrows(),
            synthesizer: SpeaksInstantly(),
            answer: { _ in "ready" },
            log: { _ in }
        )

        await server.prepare()
        let opening = await server.openingForTesting()

        XCTAssertNotNil(opening, "a failed warm-up took the opening down with it")
    }

    // MARK: - The silence it sends

    /// A real WAV, or the server rejects it and nothing loads.
    func testTheWarmUpAudioIsAWellFormedWAV() {
        let wav = CallTurnServer.silence(milliseconds: 250)

        XCTAssertEqual(wav.prefix(4), Data("RIFF".utf8))
        XCTAssertEqual(Array(wav[8..<12]), Array("WAVE".utf8))
        // 16 kHz, 16-bit mono for 250ms, plus the 44-byte header.
        XCTAssertEqual(wav.count, 44 + (16000 * 250 / 1000) * 2)
    }

    /// Short enough that warming costs a fraction of what it saves. The point is
    /// to make the server load its weights, and it loads the same weights for a
    /// quarter-second as for a minute.
    func testTheWarmUpAudioIsShort() {
        XCTAssertLessThan(CallTurnServer.silence(milliseconds: 250).count, 10_000)
    }
}

// MARK: - Stubs

private actor CountingEar: AudioFileTranscribing {
    private(set) var count = 0
    private(set) var lastAudioBytes: Int?

    func transcribe(audioFile: URL, options: AudioTranscriptionOptions) async throws -> String {
        count += 1
        lastAudioBytes = (try? Data(contentsOf: audioFile))?.count
        return ""
    }
}

/// Slow enough that a second warm-up would overlap the first, and it records
/// the overlap rather than the count — see the test that uses it.
private actor SlowEar: AudioFileTranscribing {
    private var inFlight = 0
    private(set) var peakInFlight = 0

    func transcribe(audioFile: URL, options: AudioTranscriptionOptions) async throws -> String {
        began()
        defer { ended() }
        try await Task.sleep(for: .milliseconds(500))
        return ""
    }

    private func began() {
        inFlight += 1
        peakInFlight = max(peakInFlight, inFlight)
    }

    private func ended() { inFlight -= 1 }
}

/// The wedged server: up, reachable, and never answering.
private struct NeverReturns: AudioFileTranscribing {
    func transcribe(audioFile: URL, options: AudioTranscriptionOptions) async throws -> String {
        try await Task.sleep(for: .seconds(600))
        return ""
    }
}

private struct AlwaysThrows: AudioFileTranscribing {
    func transcribe(audioFile: URL, options: AudioTranscriptionOptions) async throws -> String {
        throw AudioTranscriberError.emptyTranscript
    }
}

private struct NeverSpeaks: SpeechSynthesizing {
    let identifier = "never"
    let defaultVoice = "none"
    func isAvailable() async -> Bool { false }
    func synthesize(_ request: SpeechRequest) async throws -> SynthesizedSpeech {
        throw SpeechSynthesisError.requestFailed("not in this test")
    }
}

private struct SpeaksInstantly: SpeechSynthesizing {
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
