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
                turn?.cancel()
                turn = Task { [weak self] in
                    await self?.speak(answerTo: wav, over: writer)
                }
            case .interrupted:
                // The caller cut in. Cancelling stops the model and the
                // synthesiser; the endpoint has already silenced the audio.
                log("[call] interrupted")
                turn?.cancel()
                turn = nil
            case .replyAudio, .replyEnd, .turnFailed:
                break // Ours to send, not to receive.
            }
        }
    }

    private func speak(answerTo wav: Data, over writer: CallFrameWriter) async {
        let started = Date()
        do {
            let heard = try await transcribe(wav)
            guard !Task.isCancelled else { return }
            guard !heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                // Recognition found nothing — a cough, a door, a car. Saying
                // "I didn't catch that" to a noise the caller never made is
                // worse than saying nothing.
                log("[call] heard nothing in \(Int(wav.count / 32))ms of audio")
                return
            }
            log("[call] heard: \(heard)")

            let reply = try await answer(heard)
            guard !Task.isCancelled else { return }
            log("[call] replying: \(reply)")

            for sentence in CallTurnServer.sentences(in: reply) {
                guard !Task.isCancelled else { return }
                let speech = try await synthesizer.synthesize(
                    SpeechRequest(text: sentence, voice: configuration.voice)
                )
                guard !Task.isCancelled else { return }
                try writer.send(.replyAudio(CallTurnServer.samples(fromWAV: speech.wav)))
            }
            try writer.send(.replyEnd)
            log("[call] answered in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        } catch is CancellationError {
            return
        } catch {
            log("[call] could not answer: \(error)")
            try? writer.send(.turnFailed("\(error)"))
        }
    }

    private func transcribe(_ wav: Data) async throws -> String {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("mynah-call-\(UUID().uuidString).wav")
        try wav.write(to: scratch)
        defer { try? FileManager.default.removeItem(at: scratch) }
        return try await transcriber.transcribe(audioFile: scratch)
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
