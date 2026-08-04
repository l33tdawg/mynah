import XCTest
@testable import SageVoiceCore

/// A caller who stops listening must not make the appliance deaf.
///
/// ## The defect
///
/// `CallFrameWriter.send` is a blocking `write`, and all nine call sites were on
/// the actor. One reply frame carries a sentence plus `CallTurnServer.pause`, up
/// to 600ms of 48 kHz 16-bit — tens of kilobytes, more than a unix socket
/// buffers for a peer that is not draining. Parked in that syscall, the actor
/// serves nothing: not the next utterance, not `.interrupted`, which by
/// definition arrives while a turn is speaking, and not the idle watch that
/// hangs up an abandoned call.
///
/// The endpoint normally drains eagerly, which is why this survived — but
/// `SO_SNDTIMEO` now bounds a stuck write at fifteen seconds, and fifteen
/// seconds is exactly how long the whole call surface would have been
/// unreachable for.
///
/// `accept()` and `reader.next()` were both moved off the actor for this same
/// reason, years apart. `send` was the third blocking syscall on this surface
/// and the one still holding the lock.
///
/// ## Why the reply is deliberately enormous
///
/// The bug needs the socket's send buffer to actually fill. A small frame is
/// swallowed by the kernel and returns immediately, which is a test that passes
/// against the defect. `CallCeilingTests.drain` exists because of this and every
/// other call test uses it; this one is the single place that must *not* drain.
final class CallActorNotBlockedTests: XCTestCase {

    /// The appliance still answers while a write to a silent peer is parked.
    func testTheCallSurfaceStillAnswersWhileACallerIsNotListening() async throws {
        let socket = CallCeilingTests.scratchSocket()
        defer { try? FileManager.default.removeItem(at: socket) }

        let server = CallTurnServer(
            configuration: CallTurnServer.Configuration(socketURL: socket, turnCeilingSeconds: 30),
            transcriber: Hears("what's still open"),
            synthesizer: EnormousVoice(),
            answer: { _ in "The visa form is still open." },
            log: { _ in }
        )

        let running = Task { try? await server.run() }
        defer { running.cancel() }

        // Connected, and then deliberately never read from. This is a caller
        // whose endpoint has wedged: the socket is open, so writes do not fail,
        // they simply stop making progress once the buffer is full.
        let deaf = try await CallCeilingTests.connect(to: socket)
        defer { close(deaf) }

        try CallFrameWriter(descriptor: deaf).send(.utterance(CallCeilingTests.aSecondOfSpeech()))

        // Long enough for the turn to have recognised, answered, synthesised and
        // begun writing into a socket nobody is emptying.
        try await Task.sleep(for: .milliseconds(1500))

        // The question is not what the caller hears — they hear nothing, their
        // endpoint is broken. It is whether *this appliance* is still able to
        // think at all.
        let answered = await Self.answersWithin(seconds: 3) {
            _ = await server.quietForTesting()
        }

        XCTAssertTrue(
            answered,
            """
            the call actor is parked inside a blocking write to a caller who \
            stopped reading. Every other entry point is unreachable for as long \
            as it lasts — the next utterance, the interruption that arrives \
            mid-turn, and the watchdog that hangs up an abandoned call.
            """
        )

        // Start listening again, so the parked write finishes and the server can
        // be torn down. Without this the suite waits out `SO_SNDTIMEO` — fifteen
        // seconds per stuck frame — for a question already answered.
        CallCeilingTests.drain(deaf)
    }

    /// Whether an actor call comes back inside a deadline.
    ///
    /// A race between the work and a sleep, rather than a timeout on the actor
    /// itself: the failure being tested for is one where the actor never
    /// answers, so anything that awaits it unconditionally would hang the suite
    /// instead of failing it.
    private static func answersWithin(
        seconds: TimeInterval,
        _ work: @escaping @Sendable () async -> Void
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await work()
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}

private struct Hears: AudioFileTranscribing {
    let words: String
    init(_ words: String) { self.words = words }
    func transcribe(audioFile: URL, options: AudioTranscriptionOptions) async throws -> String { words }
}

/// A voice whose *answers* are far larger than a socket buffer.
///
/// A quarter of a megabyte. macOS gives a unix socket a send buffer measured in
/// single-digit kilobytes, so that frame fills it and the write parks — which is
/// the state this whole file exists to get into.
///
/// **The greeting is deliberately small.** `openTheCall` speaks before any
/// utterance arrives, so a voice that is enormous for everything parks twice and
/// the test spends thirty seconds — two full `SO_SNDTIMEO` waits — proving
/// something it had already proved in one. Only the answer needs to be big.
private struct EnormousVoice: SpeechSynthesizing {
    let identifier = "enormous"
    let defaultVoice = "none"

    func isAvailable() async -> Bool { true }

    func synthesize(_ request: SpeechRequest) async throws -> SynthesizedSpeech {
        let isTheAnswer = request.text.localizedCaseInsensitiveContains("visa")
        let samples = isTheAnswer ? 128 * 1024 : 8   // 256 KB, or nothing much
        var wav = Data()
        wav.append(contentsOf: Array("RIFF".utf8))
        wav.append(contentsOf: withUnsafeBytes(of: UInt32(36 + samples * 2).littleEndian) { Array($0) })
        wav.append(contentsOf: Array("WAVE".utf8))
        wav.append(contentsOf: Array("fmt ".utf8))
        wav.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        wav.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
        wav.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
        wav.append(contentsOf: withUnsafeBytes(of: UInt32(48_000).littleEndian) { Array($0) })
        wav.append(contentsOf: withUnsafeBytes(of: UInt32(96_000).littleEndian) { Array($0) })
        wav.append(contentsOf: withUnsafeBytes(of: UInt16(2).littleEndian) { Array($0) })
        wav.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Array($0) })
        wav.append(contentsOf: Array("data".utf8))
        wav.append(contentsOf: withUnsafeBytes(of: UInt32(samples * 2).littleEndian) { Array($0) })
        wav.append(Data(count: samples * 2))
        return SynthesizedSpeech(
            wav: wav,
            sampleRate: 48_000,
            channelCount: 1,
            duration: Double(samples) / 48_000,
            timeToFirstAudio: 0,
            generationDuration: 0
        )
    }
}
