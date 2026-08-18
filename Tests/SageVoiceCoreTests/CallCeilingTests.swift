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

/// A caller must never be left on an open line for ever.
///
/// ## What was missing
///
/// The daemon has had `Configuration.turnCeilingSeconds` since 1.5.4, and the
/// reason it exists applies with more force here: a message thread that goes quiet
/// is a thread, while a phone line that goes quiet is somebody saying "hello? …
/// hello?" into a live microphone while the appliance holds the call open and
/// does nothing. This surface had no bound at all. A turn parked in something
/// cancellation cannot interrupt — the node's pipe read is the one that has
/// actually happened — held the line until the caller hung up.
///
/// `CallFiller` stops after four lines and about 26 seconds, deliberately. So
/// everything past 26 seconds was silence with no end to it.
///
/// ## Why these tests go through the socket
///
/// The bound lives in `speak`, which is private on an actor and reached only by
/// an utterance arriving on a connection. A test that called `withDeadline`
/// directly would prove `withDeadline` works — which `NoTimerRacedInATaskGroupTests`
/// already does — and would have gone on passing for the whole time this surface
/// had no ceiling. The property worth pinning is that *this surface* is bounded,
/// so the frames are real and the socket is real.
final class CallCeilingTests: XCTestCase {

    /// **The failure, end to end.** A turn that never returns, and a caller who
    /// gets told so rather than being held.
    ///
    /// The answer parks on a continuation resumed by nobody, off on a global
    /// queue — not `Task.sleep`, which cancellation ends politely. That
    /// distinction is the entire history of `withDeadline`: raced inside a task
    /// group it passed against sleeping work and hung against this.
    func testAWedgedTurnIsGivenUpOnAndSaidOutLoud() async throws {
        let socket = Self.scratchSocket()
        defer { try? FileManager.default.removeItem(at: socket) }

        let spoken = SpokenLines()
        let server = CallTurnServer(
            configuration: CallTurnServer.Configuration(
                socketURL: socket,
                turnCeilingSeconds: 0.4
            ),
            transcriber: Hears("what's still open for thursday"),
            synthesizer: RecordsWhatItIsAskedToSay(spoken),
            answer: { _ in
                // Uninterruptible on purpose. See the doc comment.
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
                return "never reached"
            },
            log: { _ in }
        )

        let running = Task { try? await server.run() }
        defer { running.cancel() }
        let caller = try await Self.connect(to: socket)
        defer { close(caller) }
        Self.drain(caller)

        try CallFrameWriter(descriptor: caller).send(.utterance(Self.aSecondOfSpeech()))

        // Waits on the *last* sentence of the apology, not the first. A reply is
        // handed to the synthesiser one sentence at a time — that is what lets
        // the caller hear the start of an answer while the rest is still being
        // made — so the whole string never arrives in a single request, and a
        // test that waited on the opening words would snapshot a half-spoken
        // apology and call it delivered.
        let door = await spoken.waitForSomethingContaining("chat", within: 10)
        // Read before asserting: an XCTAssert message is an autoclosure, and an
        // actor cannot be reached from inside one.
        let everythingSaid = await spoken.everything()
        XCTAssertNotNil(
            door,
            """
            the wedged turn was never given up on, so the caller sat on an open \
            line with a live microphone and heard nothing. Everything said: \
            \(everythingSaid)
            """
        )
        XCTAssertEqual(
            CallTurnServer.sentences(in: CallTurnServer.tookTooLong)
                .filter { !everythingSaid.contains($0) },
            [],
            "part of the apology never reached the caller: \(everythingSaid)"
        )
    }

    /// **The other half, and the one that makes the first mean something.** A
    /// ceiling of zero would pass the test above and break every call on the
    /// appliance, so an answer that arrives in time has to be the answer the
    /// caller hears.
    func testAnAnswerThatArrivesInTimeIsTheOneSpoken() async throws {
        let socket = Self.scratchSocket()
        defer { try? FileManager.default.removeItem(at: socket) }

        let spoken = SpokenLines()
        let server = CallTurnServer(
            configuration: CallTurnServer.Configuration(
                socketURL: socket,
                turnCeilingSeconds: 5
            ),
            transcriber: Hears("what's still open for thursday"),
            synthesizer: RecordsWhatItIsAskedToSay(spoken),
            answer: { _ in "Two things are open. The visa form, and the invoice." },
            log: { _ in }
        )

        let running = Task { try? await server.run() }
        defer { running.cancel() }
        let caller = try await Self.connect(to: socket)
        defer { close(caller) }
        Self.drain(caller)

        try CallFrameWriter(descriptor: caller).send(.utterance(Self.aSecondOfSpeech()))

        let said = await spoken.waitForSomethingContaining("visa form", within: 10)
        let everything = await spoken.everything()
        XCTAssertNotNil(
            said,
            "the real answer was never spoken; everything said: \(everything)"
        )
        // **Compared sentence by sentence, because that is what is spoken.**
        //
        // This was `everything.contains(CallTurnServer.tookTooLong)`, which asks
        // whether any single recorded line equals the whole two-sentence
        // apology. `speak` only ever hands `sentences(in:)` pieces to the
        // synthesiser, so no recorded line can ever equal the whole string, so
        // the assertion was false by construction and `XCTAssertFalse` always
        // passed. It could not have failed under any source edit — including
        // deleting the ceiling entirely.
        //
        // Written in the same commit as a paragraph about guards that cannot
        // fail, and caught by the 1.7.0 audit rather than by me.
        let apology = Set(CallTurnServer.sentences(in: CallTurnServer.tookTooLong))
        XCTAssertEqual(
            everything.filter { apology.contains($0) }, [],
            "a turn that finished well inside the ceiling was apologised for anyway"
        )
    }

    /// The relationship between the two ceilings, stated where somebody changing
    /// one will see it.
    ///
    /// Weak on its own — it is arithmetic on constants, which is the kind of
    /// assertion that let a ceiling go unused for four releases. It earns its
    /// place beside the two behavioural tests above rather than instead of them:
    /// what it catches is somebody raising this to "match the daemon", which
    /// would be five minutes of dead air on a phone.
    func testTheCallGivesUpLongBeforeTheToolLoopDoes() {
        XCTAssertLessThan(
            CallTurnServer.Configuration.defaultTurnCeilingSeconds,
            ToolLoop.defaultDeadlineSeconds,
            "the call surface would sit through the loop's own brake, which is "
                + "five minutes of silence on an open line"
        )
        XCTAssertLessThan(
            CallTurnServer.Configuration.defaultTurnCeilingSeconds,
            VoiceBridgeDaemon.Configuration.defaultTurnCeilingSeconds,
            "a call is more urgent than a message thread, not less"
        )
    }

    /// The apology has to name what to do next.
    ///
    /// A caller told "something went wrong" down a phone line is left with a
    /// working appliance and no idea how to get their answer. Their linked chat
    /// is the door: its ceiling is four times this one and nobody is holding a
    /// line open while it thinks. The copy must not hard-code Signal because the
    /// call may have originated from WhatsApp.
    func testTheApologyNamesTheWayThatWorks() {
        XCTAssertTrue(
            CallTurnServer.tookTooLong.localizedCaseInsensitiveContains("chat"),
            "a dead end with no door in it: \(CallTurnServer.tookTooLong)"
        )
        XCTAssertFalse(
            CallTurnServer.tookTooLong.localizedCaseInsensitiveContains("signal"),
            "the recovery path was hard-coded to the wrong channel: \(CallTurnServer.tookTooLong)"
        )
        // Nothing is still running to come back with — `withDeadline` cancels the
        // abandoned work on its way out — so a promise to follow up would be a
        // lie the caller then waits on.
        for promise in ["i'll get back", "i will get back", "message you when",
                        "come back to you", "let you know when"] {
            XCTAssertFalse(
                CallTurnServer.tookTooLong.localizedCaseInsensitiveContains(promise),
                "promises to follow up on work that has been cancelled: \(promise)"
            )
        }
    }

    // MARK: - The fixtures

    static func scratchSocket() -> URL {
        // Short path on purpose: sun_path is 104 bytes and the session temp
        // directory is most of that already.
        URL(fileURLWithPath: "/tmp/mynah-ceiling-\(UUID().uuidString.prefix(8)).sock")
    }

    /// One second of a tone at a level a segmenter would call speech.
    ///
    /// 16 kHz mono 16-bit, which is what the endpoint sends and what
    /// `answerIfSpoken` measures: 32 bytes to the millisecond. Loud enough to
    /// clear `CallAudioEnergy.silenceCeiling`, so nothing here depends on the
    /// hallucination gates letting a quiet segment through.
    static func aSecondOfSpeech() -> Data {
        var samples = Data()
        for index in 0..<16_000 {
            let value = Int16(3000 * sin(Double(index) * 0.05))
            samples.append(UInt8(truncatingIfNeeded: value))
            samples.append(UInt8(truncatingIfNeeded: value >> 8))
        }

        var wav = Data()
        wav.append(contentsOf: Array("RIFF".utf8))
        wav.append(contentsOf: withUnsafeBytes(of: UInt32(36 + samples.count).littleEndian) { Array($0) })
        wav.append(contentsOf: Array("WAVE".utf8))
        wav.append(contentsOf: Array("fmt ".utf8))
        wav.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        wav.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })   // PCM
        wav.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })   // mono
        wav.append(contentsOf: withUnsafeBytes(of: UInt32(16_000).littleEndian) { Array($0) })
        wav.append(contentsOf: withUnsafeBytes(of: UInt32(32_000).littleEndian) { Array($0) })
        wav.append(contentsOf: withUnsafeBytes(of: UInt16(2).littleEndian) { Array($0) })
        wav.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Array($0) })
        wav.append(contentsOf: Array("data".utf8))
        wav.append(contentsOf: withUnsafeBytes(of: UInt32(samples.count).littleEndian) { Array($0) })
        wav.append(samples)
        return wav
    }

    /// Reads and discards everything the appliance sends, on a thread of its own.
    ///
    /// **Not optional, and not politeness.** `CallFrameWriter.send` is a blocking
    /// `write`, and one reply frame carries a sentence plus
    /// `CallTurnServer.pause(after:)` — up to 600ms of 48 kHz 16-bit silence,
    /// which is tens of kilobytes and more than a unix socket will buffer for a
    /// peer that never reads. Without this the write parks on the actor after the
    /// first sentence and the second is never synthesised: the appliance looks
    /// wedged, and the test reports it as a missing ceiling.
    ///
    /// A real `Thread` rather than a `Task`, because `reader.next()` blocks and
    /// blocking a cooperative-pool thread starves everything else in the suite.
    /// It ends by itself when the socket closes.
    @discardableResult
    static func drain(_ descriptor: Int32) -> Thread {
        let reader = CallFrameReader(descriptor: descriptor)
        let thread = Thread {
            while (try? reader.next()) != nil {}
        }
        thread.start()
        return thread
    }

    /// Connects to the server's socket, retrying while it is still coming up.
    ///
    /// `run()` binds asynchronously, so a single attempt races startup — and a
    /// flaky connect here would read as a flaky ceiling, which is the last thing
    /// this file should be able to claim.
    static func connect(to socket: URL) async throws -> Int32 {
        for attempt in 0..<100 {
            if let descriptor = try? attemptConnect(to: socket) { return descriptor }
            try await Task.sleep(for: .milliseconds(attempt < 10 ? 20 : 50))
        }
        throw XCTSkip("the call server never opened \(socket.path)")
    }

    private static func attemptConnect(to socket: URL) throws -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let path = socket.path
        guard path.utf8.count < capacity else {
            throw CallFrameReader.Failure.truncated
        }
        _ = withUnsafeMutablePointer(to: &address.sun_path) { destination in
            path.withCString { source in
                strncpy(UnsafeMutableRawPointer(destination).assumingMemoryBound(to: CChar.self),
                        source, capacity - 1)
            }
        }

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw CallFrameReader.Failure.truncated }
        // The other half of what the server now does on its accepted socket. In
        // a test both ends are this process, so a SIGPIPE from either side takes
        // the whole runner down — which is how the missing `SO_NOSIGPIPE` on the
        // call socket was found, as `exited with unexpected signal code 13`.
        var noSignalOnADeadPeer: Int32 = 1
        setsockopt(
            descriptor, SOL_SOCKET, SO_NOSIGPIPE,
            &noSignalOnADeadPeer, socklen_t(MemoryLayout<Int32>.size)
        )
        let joined = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard joined == 0 else {
            close(descriptor)
            throw CallFrameReader.Failure.truncated
        }
        return descriptor
    }
}

/// Everything the appliance tried to say, in order.
///
/// An actor because the synthesiser is called from the turn's task and read from
/// the test's, and the whole point of these tests is what happens while work is
/// still in flight.
private actor SpokenLines {
    private var lines: [String] = []

    func add(_ line: String) { lines.append(line) }
    func everything() -> [String] { lines }

    /// Waits for a line containing `fragment`, or gives up.
    ///
    /// Polled rather than signalled: the thing being waited for is a side effect
    /// of a turn nobody hands back, and a wrong answer here should be a failed
    /// assertion with the transcript attached rather than a hung test.
    func waitForSomethingContaining(_ fragment: String, within seconds: TimeInterval) async -> String? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let found = lines.first(where: { $0.localizedCaseInsensitiveContains(fragment) }) {
                return found
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return lines.first(where: { $0.localizedCaseInsensitiveContains(fragment) })
    }
}

private struct Hears: AudioFileTranscribing {
    let words: String
    init(_ words: String) { self.words = words }
    func transcribe(audioFile: URL, options: AudioTranscriptionOptions) async throws -> String { words }
}

/// Says nothing aloud and remembers every word it was given.
///
/// Returns a real, if tiny, WAV: `CallTurnServer.samples(fromWAV:)` looks for a
/// `data` chunk, and a synthesiser that returned nothing usable would make the
/// send path a no-op and hide whatever it was asked to say.
private struct RecordsWhatItIsAskedToSay: SpeechSynthesizing {
    let identifier = "records"
    let defaultVoice = "none"
    private let said: SpokenLines

    init(_ said: SpokenLines) { self.said = said }

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
