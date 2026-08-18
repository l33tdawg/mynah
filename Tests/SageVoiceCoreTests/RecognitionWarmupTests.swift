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

    func testPreparingACallWarmsRecognition() async {
        let ear = CountingEar()
        let server = CallTurnServer(
            configuration: CallTurnServer.Configuration(),
            transcriber: ear,
            synthesizer: NeverSpeaks(),
            answer: { _ in "" },
            log: { _ in }
        )

        await server.prepare()
        await settle { await ear.count > 0 }

        let warmed = await ear.count
        XCTAssertEqual(warmed, 1, "//call warmed the transcriber \(warmed) times, not once")
    }

    /// **It must send real audio.** A warm-up that posts an empty file gets a
    /// fast rejection and loads nothing, which would look identical from the
    /// outside — the request happened, the log line printed, and the caller
    /// still waits 10.7s.
    func testTheWarmUpActuallySendsAudio() async {
        let ear = CountingEar()
        let server = CallTurnServer(
            configuration: CallTurnServer.Configuration(),
            transcriber: ear,
            synthesizer: NeverSpeaks(),
            answer: { _ in "" },
            log: { _ in }
        )

        await server.prepare()
        await settle { await ear.count > 0 }

        let audio = await ear.lastAudioBytes
        XCTAssertGreaterThan(audio ?? 0, 44, "no samples, only a header — nothing would load")
    }

    /// **`//call` pressed repeatedly must not pile warm-ups onto the server.**
    ///
    /// Counting invocations would not catch this: five sequential warm-ups and
    /// five concurrent ones both invoke the transcriber five times, and only the
    /// second is a problem. What separates them is whether the earlier four were
    /// *cancelled*, so that is what this asks — five asked for, four cancelled,
    /// none of the four allowed to run its course. Without the `cancel()` in
    /// `prepare()` all five run to completion and this goes red on `completed`.
    ///
    /// ## What this used to measure, and why it flaked
    ///
    /// It measured `peakInFlight` and asserted 1. That failed once in a
    /// 2157-test run on 7 August 2026 — `("2") is not equal to ("1")` — and
    /// three isolated re-runs of the file were green, so it was load-sensitive
    /// rather than a regression. It mattered because release.sh and
    /// release.yml both fail the release on any failure, and the usual answer to
    /// a random red is to re-run it, which is how a real one gets waved through.
    ///
    /// **The margin was never the 20 ms sleep, and widening it would not have
    /// helped.** `withDeadline` runs its work in an *unstructured* `Task`, which
    /// does not inherit cancellation — cancelling `recognitionWarming` reaches
    /// the transcriber only through `withDeadline`'s `defer { worker.cancel() }`,
    /// which cannot run until the enclosing task is resumed and scheduled. By
    /// then `prepare()` has already returned and started the next warm-up. So
    /// the window in which two are counted is a scheduler round trip wide,
    /// independent of any sleep in the test, and a peak of 2 was the machine
    /// being busy rather than the code being wrong.
    ///
    /// That is a real property of production and not only of the stub: five
    /// rapid `//call`s can put two 250 ms warm-up requests on the ASR server for
    /// a moment. Two is harmless; five piling up is the failure, and five is
    /// what `cancel()` prevents. The assertion now matches the promise the code
    /// makes instead of a stronger one it never made.
    ///
    /// No sleeps: it waits for a state rather than a duration. See `settle`.
    func testRepeatedCallRequestsCancelEveryWarmUpButTheLast() async {
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
        }
        await settle { await ear.reached(started: 5, ended: 4) }

        let started = await ear.started
        let cancelled = await ear.cancelled
        let completed = await ear.completed
        XCTAssertEqual(started, 5, "\(started) of 5 //call presses warmed anything")
        XCTAssertEqual(cancelled, 4, "\(cancelled) of the first 4 warm-ups were cancelled")
        XCTAssertEqual(
            completed, 0,
            "\(completed) superseded warm-ups ran their course — they are piling onto the server"
        )
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

// MARK: - Waiting

/// Waits for a state rather than for a duration.
///
/// Every test in this file used to sleep for a fixed number of milliseconds and
/// then assert — 400 ms for "did a warm-up happen", 20 ms between `//call`s —
/// and one of them went red once in a 2157-test run on 7 August 2026 while
/// being green three times out of three in isolation. A sleep long enough to be
/// safe on an idle Mac is a coin flip on a loaded one, and the usual answer to a
/// random red is to re-run it, which is how a real failure eventually gets
/// waved through.
///
/// **The 15 s here is a bound, not a margin, and the difference is the whole
/// point.** A margin is spent whether or not it is needed and decides the
/// verdict; this is checked continuously, exits the instant the condition holds,
/// and is reached only when something is actually wrong. The 5 ms between polls
/// is granularity — losing that race costs 5 ms and then the loop asks again.
///
/// It returns on expiry rather than throwing, so the assertions that follow
/// report the real counts. "0 of 5 //call presses warmed anything" says what
/// broke; a bare timeout says only that something did.
private func settle(
    within seconds: TimeInterval = 15,
    until condition: @Sendable () async -> Bool
) async {
    let deadline = Date().addingTimeInterval(seconds)
    while await !condition() {
        guard Date() < deadline else { return }
        try? await Task.sleep(for: .milliseconds(5))
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

/// Slow enough that a warm-up nobody cancelled is still running when the next
/// one starts, and it records **how each one ended** rather than how many
/// overlapped — see the test that uses it.
///
/// Ten seconds, not the half second the overlap version used, and the length is
/// doing a job: the only way `completed` can move here is if a superseded
/// warm-up was genuinely never cancelled. A shorter sleep would let a slow
/// machine finish one before its cancellation landed and call that a defect,
/// which is the shape of failure this stub was rewritten to stop producing.
private actor SlowEar: AudioFileTranscribing {

    /// Warm-ups that reached the transcriber at all.
    private(set) var started = 0
    /// Warm-ups that ran their full course. Exactly one should survive five
    /// `//call`s, and it is still sleeping when the test ends.
    private(set) var completed = 0
    /// Warm-ups that were cancelled out from under themselves.
    private(set) var cancelled = 0

    /// Warm-ups that are over, however they ended.
    ///
    /// Counting **both** outcomes is what keeps the wait honest. A wait for
    /// four cancellations would hang forever on exactly the bug this test
    /// exists to catch — no cancellations is the symptom — whereas a wait for
    /// four *endings* is satisfied by four completions too, and then the
    /// assertions say which four they were.
    var ended: Int { cancelled + completed }

    /// Both counters in one hop, so the wait never sees a half-updated pair.
    func reached(started target: Int, ended target2: Int) -> Bool {
        started >= target && ended >= target2
    }

    func transcribe(audioFile: URL, options: AudioTranscriptionOptions) async throws -> String {
        started += 1
        do {
            try await Task.sleep(for: .seconds(10))
        } catch {
            cancelled += 1
            throw error
        }
        completed += 1
        return ""
    }
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
#endif  // os(macOS)
