import XCTest
@testable import SageVoiceCore

/// A turn abandoned by the call that started it must never reach the next one.
///
/// ## The defect
///
/// `CallFrameWriter` held a bare `Int32`. It is a struct, so every turn task got
/// its own copy of that number, and the number outlived the call: cancellation in
/// Swift is cooperative, so a turn parked on the model or the synthesiser keeps
/// running well after the caller hangs up.
///
/// Meanwhile `handle(connection:)` closed the descriptor, and POSIX hands the
/// *lowest available* number to the next `accept()` — which is the one just
/// freed. Verified on this Mac with a C probe before any of this was written:
/// listening socket on fd 3, first call accepted on fd 5, closed, second call
/// accepted on fd 5 again.
///
/// So the abandoned turn woke up, wrote to "its" descriptor, and the previous
/// caller's answer was played into a different person's ear — with nothing in any
/// log to say so, because from the appliance's side the write simply succeeded.
///
/// ## Why the fix is an object and not a flag
///
/// A `usable` flag checked before writing still leaves a window: check, then the
/// call ends and the number is reissued, then write. `CallConnection` closes that
/// window by holding the lock across the whole write, so `retire()` — which the
/// server calls *before* `close` — cannot return while a write is in flight.
final class AbandonedTurnTests: XCTestCase {

    // MARK: - The mechanism, with the descriptor genuinely reissued

    /// The defect reproduced exactly, without needing a call at all.
    ///
    /// Deterministic on purpose. Driving two real calls through the server and
    /// hoping the kernel reissues the number would be a test that sometimes
    /// exercises the bug and sometimes does not, which is worse than no test:
    /// it would go green on broken code often enough to be believed. Here the
    /// reissue is asserted rather than hoped for, and the test says so if it
    /// did not happen.
    func testARetiredWriterStaysSilentWhenItsNumberBelongsToSomebodyElse() throws {
        // Call one.
        var one: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &one), 0, "socketpair: \(errno)")
        let callOne = CallConnection(descriptor: one[0])
        let abandoned = CallFrameWriter(callOne)

        // It works while the call is up — otherwise "refuses to write" below
        // would be true of a writer that never worked at all.
        XCTAssertNoThrow(try abandoned.send(.replyEnd))

        // The call ends, in the order `handle(connection:)` uses.
        callOne.retire()
        close(one[0])
        close(one[1])

        // Call two, which the kernel builds out of the numbers just freed.
        var two: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &two), 0, "socketpair: \(errno)")
        defer { close(two[0]); close(two[1]) }

        XCTAssertTrue(
            two.contains(one[0]),
            """
            the kernel did not reissue descriptor \(one[0]) (call two got \(two)), \
            so this run never put the abandoned writer on somebody else's socket \
            and proves nothing. The bug needs the reuse to be real.
            """
        )

        // The whole point: same number, different call, and it must not write.
        XCTAssertThrowsError(
            try abandoned.send(.replyAudio(Data(repeating: 7, count: 64))),
            "the first caller's answer was written into the second caller's socket"
        ) { error in
            XCTAssertEqual(error as? CallFrameWriter.Failure, .callEnded)
        }

        // Belt and braces: ask the new call whether anything arrived. A throw
        // with the bytes already sent would be a fix that reads well and fails.
        for end in two {
            XCTAssertEqual(
                Self.pendingBytes(on: end), 0,
                "bytes from the abandoned turn are sitting in the new call's socket"
            )
        }
    }

    /// The guard must not be a blanket refusal — a live call still has to talk.
    func testAConnectionThatHasNotEndedStillWrites() throws {
        var ends: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &ends), 0, "socketpair: \(errno)")
        defer { close(ends[0]); close(ends[1]) }

        let live = CallConnection(descriptor: ends[0])
        XCTAssertTrue(live.isUsable)
        XCTAssertNoThrow(try CallFrameWriter(live).send(.replyAudio(Data(repeating: 3, count: 32))))
        XCTAssertGreaterThan(
            Self.pendingBytes(on: ends[1]), 0,
            "a call that is still up was silenced by the fix for one that ended"
        )
    }

    // MARK: - The wiring

    /// That a turn abandoned by a finished call files nothing into the next one.
    ///
    /// **Four findings of the 1.7.2 re-audit were this one omission**, each
    /// surviving three independent skeptics. Nothing cancelled `turn` when the
    /// call ended, so an abandoned turn ran on past the writer guard to
    /// `deliverTranscript(links)` and `transcript.said(fullReply)` — and
    /// `transcript` is a single actor property that the *next* call has already
    /// reset. So the Signal record of call two carried a question and an answer
    /// nobody heard on it, plus a stray links message; `rememberThisCall` then
    /// stored it as the closing for the call after that.
    ///
    /// This test used to assert only the "leaving it unsaid" log line, which
    /// sits at the *socket*. Every side effect above happens before that, so it
    /// covered none of them — the audit said so, and it was right.
    func testATurnAbandonedByAFinishedCallFilesNothing() async throws {
        let socket = CallCeilingTests.scratchSocket()
        defer { try? FileManager.default.removeItem(at: socket) }

        let held = HoldOpen()
        let logged = Logged()
        let posted = Logged()
        let server = CallTurnServer(
            configuration: CallTurnServer.Configuration(socketURL: socket, turnCeilingSeconds: 30),
            transcriber: Hears("what's still open"),
            synthesizer: PlainVoice(),
            answer: { _ in
                await held.wait()
                // Carries a link, so `deliverTranscript` is live too — one of
                // the two paths the audit found running past the writer guard.
                return "The visa form is still open. See https://example.com/visa"
            },
            log: { logged.add($0) }
        )
        await server.onTranscript { posted.add($0) }

        let running = Task { try? await server.run() }
        defer { running.cancel() }

        let caller = try await CallCeilingTests.connect(to: socket)
        CallCeilingTests.drain(caller)
        try CallFrameWriter(descriptor: caller).send(.utterance(CallCeilingTests.aSecondOfSpeech()))

        let started = await held.waitUntilSomeoneIsWaiting(within: 10)
        XCTAssertTrue(started, "the turn never reached the model: \(logged.everything)")

        close(caller)
        let noticed = await logged.waitFor("stopping that turn", within: 10)
        XCTAssertNotNil(
            noticed,
            "the call ended and the turn it was mid-answer on was left running: \(logged.everything)"
        )

        // Let the abandoned turn finish. It must file nothing.
        await held.open()
        try await Task.sleep(for: .seconds(2))

        XCTAssertEqual(
            posted.everything.filter { $0.contains("example.com") }, [],
            """
            the abandoned turn pushed its links to the thread — on the owner's \
            phone that is a bare URL for a question he gave up on: \(posted.everything)
            """
        )
        XCTAssertFalse(
            logged.everything.contains { $0.contains("replying:") },
            "the abandoned turn carried on into the reply path: \(logged.everything)"
        )
    }

    // MARK: - Fixtures

    /// How many bytes are queued on this end.
    ///
    /// A non-blocking `read` rather than `FIONREAD`, which Swift's Darwin
    /// overlay does not expose. Consuming what it finds is fine here — every
    /// caller asks once, and the question is only ever "did anything arrive".
    private static func pendingBytes(on descriptor: Int32) -> Int {
        let flags = fcntl(descriptor, F_GETFL, 0)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        defer { _ = fcntl(descriptor, F_SETFL, flags) }

        var buffer = [UInt8](repeating: 0, count: 4096)
        let got = read(descriptor, &buffer, buffer.count)
        return got > 0 ? got : 0
    }
}

/// Opens once, and can say whether anybody is waiting on it yet.
private actor HoldOpen {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var everWaited = false

    func open() {
        isOpen = true
        let resume = waiting
        waiting = []
        resume.forEach { $0.resume() }
    }

    func wait() async {
        guard !isOpen else { return }
        everWaited = true
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Polled rather than signalled: the thing being waited for is a side effect
    /// of a turn nobody hands back.
    func waitUntilSomeoneIsWaiting(within seconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if everWaited { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }
}

/// Everything the server logged, from whichever task logged it.
private final class Logged: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func add(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    var everything: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    func waitFor(_ fragment: String, within seconds: TimeInterval) async -> String? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let found = everything.first(where: { $0.localizedCaseInsensitiveContains(fragment) }) {
                return found
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return nil
    }
}

private struct Hears: AudioFileTranscribing {
    let words: String
    init(_ words: String) { self.words = words }
    func transcribe(audioFile: URL, options: AudioTranscriptionOptions) async throws -> String { words }
}

/// Returns a small valid WAV and records nothing.
private struct PlainVoice: SpeechSynthesizing {
    let identifier = "plain"
    let defaultVoice = "none"

    func isAvailable() async -> Bool { true }

    func synthesize(_ request: SpeechRequest) async throws -> SynthesizedSpeech {
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

/// A transcription that lands after the hang-up must not open a turn.
///
/// Round two of the 1.7.2 audit found that half the call fix — the
/// `writer.isUsable` guard in `replaceTurn` and the `CallFrameWriter.isUsable`
/// it reads — had no test at all: both could be deleted with the suite green.
/// It was right. The other half (`endTheCurrentTurn`) is covered by
/// `AbandonedTurnTests`, which never lands a transcription after the call ends.
///
/// This is the path that matters when recognition is slow: the utterance tasks
/// the read loop spawns are not cancelled with the call, so one finishing after
/// the hang-up would start a fresh turn, write `transcript.heard` into whatever
/// call is current, and speak into a connection belonging to somebody else.
final class LateTranscriptionTests: XCTestCase {

    func testATranscriptionFinishingAfterTheHangUpStartsNoTurn() async throws {
        let socket = CallCeilingTests.scratchSocket()
        defer { try? FileManager.default.removeItem(at: socket) }

        let recognising = SlowEar()
        let logged = LateLog()
        let server = CallTurnServer(
            configuration: CallTurnServer.Configuration(socketURL: socket, turnCeilingSeconds: 30),
            transcriber: recognising,
            synthesizer: SilentVoice(),
            answer: { _ in "The visa form is still open." },
            log: { logged.add($0) }
        )

        let running = Task { try? await server.run() }
        defer { running.cancel() }

        let caller = try await CallCeilingTests.connect(to: socket)
        CallCeilingTests.drain(caller)
        try CallFrameWriter(descriptor: caller).send(.utterance(CallCeilingTests.aSecondOfSpeech()))

        // Wait until recognition is genuinely in flight, then hang up under it.
        let started = await recognising.waitUntilBusy(within: 10)
        XCTAssertTrue(started, "recognition never started: \(logged.everything)")
        close(caller)
        try await Task.sleep(for: .milliseconds(400))

        // Now let recognition finish. It must not open a turn.
        await recognising.finish()
        let refused = await logged.waitFor("recognised after the call ended", within: 10)

        XCTAssertNotNil(
            refused,
            """
            a transcription that landed after the hang-up opened a turn on the \
            dead call. Everything logged: \(logged.everything)
            """
        )
        XCTAssertFalse(
            logged.everything.contains { $0.contains("replying:") },
            "the late turn ran all the way into the reply path: \(logged.everything)"
        )
    }
}

/// Recognition the test can hold open across a hang-up.
private actor SlowEar: AudioFileTranscribing {
    private var busy = false
    private var release: CheckedContinuation<Void, Never>?

    func waitUntilBusy(within seconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if busy { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }

    func finish() {
        release?.resume()
        release = nil
    }

    func transcribe(audioFile: URL, options: AudioTranscriptionOptions) async throws -> String {
        busy = true
        await withCheckedContinuation { release = $0 }
        return "what's still open"
    }
}

private final class LateLog: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    var everything: [String] { lock.lock(); defer { lock.unlock() }; return lines }
    func waitFor(_ fragment: String, within seconds: TimeInterval) async -> String? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let hit = everything.first(where: { $0.localizedCaseInsensitiveContains(fragment) }) { return hit }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return nil
    }
}

private struct SilentVoice: SpeechSynthesizing {
    let identifier = "silent"
    let defaultVoice = "none"
    func isAvailable() async -> Bool { true }
    func synthesize(_ request: SpeechRequest) async throws -> SynthesizedSpeech {
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
        return SynthesizedSpeech(wav: wav, sampleRate: 48_000, channelCount: 1,
                                 duration: 0.001, timeToFirstAudio: 0, generationDuration: 0)
    }
}
