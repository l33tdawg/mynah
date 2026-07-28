import Foundation

/// Answers the call: an utterance arrives, an answer goes back as audio.
///
/// The split with the endpoint is by deadline, not by subject. Anything measured
/// in milliseconds — decoding, deciding a sentence ended, pacing playback —
/// stays in the endpoint, where a stall is a stutter the caller hears. Anything
/// measured in seconds — recognition, the model, synthesis — happens here, where
/// a delay is a delay in answering.
///
/// ## Why a reply is spoken in pieces
///
/// The whole answer could be synthesised and then sent. It would also mean the
/// caller hears nothing until the last word has been generated, which on a
/// three-sentence answer is several seconds of silence indistinguishable from a
/// dropped call. Each sentence is spoken as it is ready, so the appliance starts
/// talking about as fast as a person would.
public actor CallTurnServer {

    public struct Configuration: Sendable {
        /// Where the endpoint connects.
        public var socketURL: URL

        /// The voice for calls.
        public var voice: String?

        public init(socketURL: URL = CallTurnServer.defaultSocket(), voice: String? = nil) {
            self.socketURL = socketURL
            self.voice = voice
        }
    }

    private let configuration: Configuration
    private let transcriber: any AudioFileTranscribing
    private let synthesizer: any SpeechSynthesizing
    private let answer: @Sendable (String) async throws -> String
    private let log: @Sendable (String) -> Void

    private var listening: Int32 = -1
    private var turn: Task<Void, Never>?

    /// So two turns running do not open with the same line, which is the tell
    /// that makes a stock phrase sound like a stock phrase.
    private var lastOpener: String?

    public init(
        configuration: Configuration,
        transcriber: any AudioFileTranscribing,
        synthesizer: any SpeechSynthesizing,
        answer: @escaping @Sendable (String) async throws -> String,
        log: @escaping @Sendable (String) -> Void = { print($0) }
    ) {
        self.configuration = configuration
        self.transcriber = transcriber
        self.synthesizer = synthesizer
        self.answer = answer
        self.log = log
    }

    public static func defaultSocket(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/SAGE Voice Bridge", isDirectory: true)
            .appendingPathComponent("call.sock")
    }

    public enum Failure: Error, CustomStringConvertible {
        case pathTooLong(String)
        case couldNotListen(String)

        public var description: String {
            switch self {
            case .pathTooLong(let path):
                return "the call socket path is too long for a unix socket: \(path)"
            case .couldNotListen(let reason):
                return "could not open the call socket: \(reason)"
            }
        }
    }

    /// Opens the socket and answers calls until cancelled.
    public func run() async throws {
        let descriptor = try openSocket()
        listening = descriptor
        defer {
            close(descriptor)
            listening = -1
            try? FileManager.default.removeItem(at: configuration.socketURL)
        }

        log("[call] ready on \(configuration.socketURL.path)")
        while !Task.isCancelled {
            let accepted = accept(descriptor, nil, nil)
            if accepted < 0 {
                if errno == EINTR { continue }
                break
            }
            // One call at a time. A second endpoint connecting means the first
            // is gone or something is wrong; either way the newest wins, which
            // matches how //call reissues the link.
            await handle(connection: accepted)
        }
    }

    private func openSocket() throws -> Int32 {
        let path = configuration.socketURL.path
        try? FileManager.default.createDirectory(
            at: configuration.socketURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Stale socket from a previous run. bind() fails on an existing path,
        // and a crash leaves one behind — so an appliance that did not shut down
        // cleanly would never accept another call.
        try? FileManager.default.removeItem(at: configuration.socketURL)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { throw Failure.pathTooLong(path) }
        _ = withUnsafeMutablePointer(to: &address.sun_path) { destination in
            path.withCString { source in
                strncpy(UnsafeMutableRawPointer(destination).assumingMemoryBound(to: CChar.self),
                        source, capacity - 1)
            }
        }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure.couldNotListen("socket: \(errno)") }

        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            close(descriptor)
            throw Failure.couldNotListen("bind: \(errno)")
        }
        // The socket carries a live microphone. Nobody else on this Mac needs it.
        chmod(path, 0o600)

        guard listen(descriptor, 1) == 0 else {
            close(descriptor)
            throw Failure.couldNotListen("listen: \(errno)")
        }
        return descriptor
    }

    private func handle(connection: Int32) async {
        defer { close(connection) }
        let reader = CallFrameReader(descriptor: connection)
        let writer = CallFrameWriter(descriptor: connection)
        log("[call] a call connected")

        while !Task.isCancelled {
            let frame: CallFrame
            do {
                // Blocking, off the actor: a read that parks here would stop the
                // actor answering anything, including the interruption that has
                // to arrive while a turn is running.
                frame = try await withoutBlockingTheActor { try reader.next() }
            } catch CallFrameReader.Failure.closed {
                log("[call] the call ended")
                return
            } catch {
                log("[call] the endpoint stopped: \(error)")
                return
            }

            switch frame {
            case .utterance(let wav):
                // Recognised first, cancelled second.
                //
                // Whether the caller spoke is decided by whether there are
                // words in it, not by how loud it was — loudness is the one
                // thing noise reliably has. Cancelling on arrival meant a door,
                // a cough or the tail of the appliance's own voice destroyed
                // whatever was in flight, and the log showed exactly that: a
                // finished answer, "Just the A100 benchmarks before Friday",
                // thrown away between being generated and being spoken.
                //
                // So an utterance with no words in it now changes nothing at
                // all. Noise cannot cancel what it cannot be mistaken for.
                Task { [weak self] in
                    await self?.answerIfSpoken(wav, over: writer)
                }
            case .interrupted:
                // Deliberately does not cancel the turn.
                //
                // This arrives on energy alone, milliseconds after a sound
                // starts and long before anyone knows whether it was speech.
                // The endpoint has already dropped the queued audio locally,
                // which is what makes cutting in feel instant — but stopping
                // the model on the same evidence is what let background noise
                // kill answers. The turn is cancelled when words arrive, if
                // they do.
                log("[call] interrupted")
            case .replyAudio, .replyEnd, .turnFailed:
                break // Ours to send, not to receive.
            }
        }
    }

    /// Recognises an utterance and, only if it contains words, makes it the
    /// current turn.
    private func answerIfSpoken(_ wav: Data, over writer: CallFrameWriter) async {
        let started = Date()
        let heard: String
        do {
            heard = try await transcribe(wav)
        } catch {
            log("[call] could not recognise: \(error)")
            return
        }
        // 32 bytes per millisecond: 16 kHz, mono, sixteen bits.
        let milliseconds = Int(wav.count / 32)
        guard !HeardSpeech.isNothing(heard, milliseconds: milliseconds) else {
            // A cough, a door, a car, the appliance's own voice returning — or
            // Whisper filling silence with a phrase from its training data.
            // Nothing was said, so nothing changes, and in particular whatever
            // the appliance is already doing carries on.
            let what = heard.isEmpty ? "nothing" : "\"\(heard)\" (no one spoke)"
            log("[call] heard \(what) in \(milliseconds)ms of audio")
            return
        }

        // Words. Now the previous turn is genuinely superseded.
        await replaceTurn(with: heard, recognisedIn: Date().timeIntervalSince(started), over: writer)
    }

    private func replaceTurn(
        with heard: String,
        recognisedIn recognition: TimeInterval,
        over writer: CallFrameWriter
    ) {
        turn?.cancel()
        turn = Task { [weak self] in
            await self?.speak(heard, recognisedIn: recognition, over: writer)
        }
    }

    private func speak(
        _ heard: String,
        recognisedIn recognition: TimeInterval,
        over writer: CallFrameWriter
    ) async {
        let started = Date().addingTimeInterval(-recognition)
        do {
            let recognised = Date()
            guard !Task.isCancelled else { return }
            log("[call] heard: \(heard)")

            // Say something before thinking, not after.
            //
            // The silence while the model works is the whole of what "it feels
            // slow" means. On a call it is worse than in a message thread: a
            // Signal thread at least shows the question was delivered, while a
            // silent line is indistinguishable from a dropped one, and the
            // caller starts saying "hello?" into it.
            //
            // This costs nothing to produce. The opener is derived from the
            // caller's own sentence, so it needs no model call — which is the
            // only reason it can arrive before the model rather than after.
            if let opener = WorkingReply.opening(forRequest: heard, previous: lastOpener) {
                lastOpener = opener.line
                if let audio = try? await synthesizer.synthesize(
                    SpeechRequest(text: opener.line, voice: configuration.voice)
                ) {
                    guard !Task.isCancelled else { return }
                    try? writer.send(.replyAudio(CallTurnServer.samples(fromWAV: audio.wav)))
                    log("[call] said \"\(opener.line)\" after \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
                }
            }

            // A second acknowledgement, for the answers that take a while.
            //
            // The opener buys about eight seconds of patience. A tool call can
            // run well past that, and the silence after an opener is worse than
            // the silence before one — the caller has been told it is working
            // and then hears nothing, which reads as the thing having crashed
            // mid-sentence rather than merely being slow.
            let waiting = Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled, let self else { return }
                await self.sayStillWorking(over: writer)
            }
            let reply = try await answer(heard)
            waiting.cancel()
            let thought = Date()
            guard !Task.isCancelled else { return }
            log("[call] replying: \(reply)")

            // Timed per stage rather than end to end. "A bit slow" is three
            // different problems — recognition, the model, synthesis — and they
            // have nothing in common except that the caller waits through all of
            // them. Only the first-sentence figure is what they actually
            // experience; the rest is spoken while they are already listening.
            var firstSpoken: Date?
            for sentence in CallTurnServer.sentences(in: reply) {
                guard !Task.isCancelled else { return }
                let speech = try await synthesizer.synthesize(
                    SpeechRequest(text: sentence, voice: configuration.voice)
                )
                guard !Task.isCancelled else { return }
                try writer.send(.replyAudio(CallTurnServer.samples(fromWAV: speech.wav)))
                if firstSpoken == nil { firstSpoken = Date() }
            }
            try writer.send(.replyEnd)

            let seconds = { (from: Date, to: Date) in
                String(format: "%.1f", to.timeIntervalSince(from))
            }
            log("[call] heard in \(seconds(started, recognised))s, "
                + "thought in \(seconds(recognised, thought))s, "
                + "spoke in \(seconds(thought, firstSpoken ?? thought))s "
                + "— talking after \(seconds(started, firstSpoken ?? thought))s")
        } catch is CancellationError {
            return
        } catch {
            log("[call] could not answer: \(error)")
            try? writer.send(.turnFailed("\(error)"))
        }
    }

    /// Fills a long think with something human.
    private func sayStillWorking(over writer: CallFrameWriter) async {
        let line = WorkingReply.progressLine(completed: [], pending: nil)
            ?? "Still on it."
        guard let audio = try? await synthesizer.synthesize(
            SpeechRequest(text: line, voice: configuration.voice)
        ) else { return }
        try? writer.send(.replyAudio(CallTurnServer.samples(fromWAV: audio.wav)))
        log("[call] said \"\(line)\" while working")
    }

    private func transcribe(_ wav: Data) async throws -> String {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("mynah-call-\(UUID().uuidString).wav")
        try wav.write(to: scratch)
        defer { try? FileManager.default.removeItem(at: scratch) }
        do {
            return try await transcriber.transcribe(audioFile: scratch)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            // Finding no words is the ordinary outcome for a door, a cough, or
            // the appliance's own voice arriving back through the phone. The
            // backends raise it as an error, but there is nothing wrong and
            // nothing to say — treating it as a failure fills the log with
            // alarms and answers noise the caller never made.
            if "\(error)".contains("emptyTranscript") { return "" }
            throw error
        }
    }

    /// Splits a reply into pieces worth synthesising separately.
    ///
    /// The unit is a sentence because that is the smallest chunk that sounds
    /// natural on its own — synthesising by phrase produces audible seams where
    /// the prosody restarts. Very short sentences are joined to the next, since
    /// "Sure." on its own is a whole subprocess for a quarter second of audio.
    static func sentences(in reply: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        for character in reply {
            current.append(character)
            if character == "." || character == "!" || character == "?" || character == "\n" {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count >= 25 {
                    pieces.append(trimmed)
                    current = ""
                }
            }
        }
        let remainder = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remainder.isEmpty {
            if remainder.count < 25, var last = pieces.popLast() {
                last += " " + remainder
                pieces.append(last)
            } else {
                pieces.append(remainder)
            }
        }
        return pieces.isEmpty ? [reply] : pieces
    }

    /// Strips the RIFF header, leaving the samples the endpoint encodes.
    ///
    /// The data chunk is located rather than assumed to start at byte 44.
    /// afconvert emits a LIST chunk describing the encoder, so the fixed offset
    /// every example uses would hand the encoder several hundred bytes of
    /// metadata as audio — which is a burst of noise before every reply.
    static func samples(fromWAV wav: Data) -> Data {
        let bytes = [UInt8](wav)
        guard bytes.count > 12 else { return Data() }
        var at = 12 // past "RIFF" + size + "WAVE"
        while at + 8 <= bytes.count {
            let identifier = String(decoding: bytes[at..<(at + 4)], as: UTF8.self)
            let size = Int(bytes[at + 4]) | Int(bytes[at + 5]) << 8
                | Int(bytes[at + 6]) << 16 | Int(bytes[at + 7]) << 24
            let start = at + 8
            if identifier == "data" {
                let end = min(start + size, bytes.count)
                guard start < end else { return Data() }
                return Data(bytes[start..<end])
            }
            at = start + size + (size % 2) // chunks are word-aligned
        }
        return Data()
    }
}

/// Runs a blocking call without occupying the actor.
///
/// The socket read blocks for as long as the caller is silent. Doing that on the
/// actor would mean an interruption cannot be processed while a turn is running,
/// which is precisely when it matters.
func withoutBlockingTheActor<T: Sendable>(
    _ work: @escaping @Sendable () throws -> T
) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                continuation.resume(returning: try work())
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

/// What was said earlier in this call.
///
/// A call is one conversation, so each turn needs what came before it —
/// otherwise the caller has to restate context they gave twenty seconds ago,
/// which is the difference between talking to something and querying it.
///
/// Bounded, because a long call would otherwise grow the prompt until it costs
/// more to send than to answer. The oldest exchanges go first: in a spoken
/// conversation, what was said a minute ago matters far less than what was said
/// just now.
public actor CallHistory {
    private var messages: [BrainMessage] = []
    private let limit: Int

    public init(limit: Int = 24) {
        self.limit = limit
    }

    public func recent() -> [BrainMessage] {
        messages
    }

    public func remember(_ conversation: [BrainMessage]) {
        // The first message is the system prompt, which ToolLoop supplies each
        // time. Passing it back would stack a second copy on every turn.
        var kept = Array(conversation.dropFirst())
        if kept.count > limit {
            kept = Array(kept.suffix(limit))
        }
        messages = kept
    }

    public func forget() {
        messages = []
    }
}
