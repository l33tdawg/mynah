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

        /// How fast it speaks, as a multiplier on the voice's natural rate.
        ///
        /// Slightly quick, deliberately. A synthesiser at its default rate reads
        /// at the pace of an audiobook, which is right for listening to a
        /// chapter and wrong for an exchange where the caller already knows what
        /// they asked. Past about 1.3 the words start running together on a
        /// phone speaker.
        public var speed: Double

        public init(
            socketURL: URL = CallTurnServer.defaultSocket(),
            voice: String? = nil,
            speed: Double = 1.15
        ) {
            self.socketURL = socketURL
            self.voice = voice
            self.speed = speed
        }
    }

    private let configuration: Configuration
    private let transcriber: any AudioFileTranscribing
    private let synthesizer: any SpeechSynthesizing
    private let answer: @Sendable (String) async throws -> String
    private let log: @Sendable (String) -> Void

    private var listening: Int32 = -1
    private var turn: Task<Void, Never>?

    /// The opening line, made ready before anyone is listening.
    private var preparation: Task<Data?, Never>?

    /// Its words, so the transcript opens with what the caller actually heard.
    private var preparedOpening: String?

    /// When the last call ended, so the opening can know how long it has been.
    private var lastCallEnded: Date?

    /// What has been said on the call in progress.
    private var transcript = CallTranscript()

    /// Where a finished transcript goes. Set after construction, because the
    /// thing that can post to Signal is built after this is.
    private var deliverTranscript: (@Sendable (String) async -> Void)?

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

    /// Where finished transcripts are posted.
    public func onTranscript(_ deliver: @escaping @Sendable (String) async -> Void) {
        deliverTranscript = deliver
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

    /// Gets ready for a call that has been asked for but not yet joined.
    ///
    /// `//call` is several seconds of warning: the owner has to receive the
    /// link, read it, tap it and grant a microphone. All of that is time this
    /// appliance currently spends idle, and every second of it is a second the
    /// caller would otherwise wait through after saying hello.
    ///
    /// So the opening is built now — greeting and briefing together, through
    /// the same brain and tools as any other turn, so it can say what is
    /// actually open rather than something generic. By the time the call
    /// connects it is a buffer to hand over rather than work to start.
    ///
    /// Discarded if the call never happens. That costs one model call the owner
    /// asked for by typing //call, which is the cheapest thing in this exchange.
    public func prepare() {
        preparation?.cancel()
        preparation = Task { [weak self] in
            guard let self else { return nil }
            return await self.buildOpening()
        }
    }

    private func buildOpening() async -> Data? {
        let started = Date()
        let greeting = CallTurnServer.greetings.randomElement() ?? "Hey, I'm here."

        // The briefing is best-effort. A call that opens with a plain hello is
        // fine; a call that opens with nothing because a tool timed out is not.
        var opening = greeting
        let request = CallTurnServer.briefingRequest(
            now: Date(),
            sinceLastCall: lastCallEnded.map { Date().timeIntervalSince($0) }
        )
        if let briefing = try? await answer(request),
           !briefing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            opening = briefing
        }
        guard !Task.isCancelled else { return nil }

        guard let audio = try? await synthesizer.synthesize(
            SpeechRequest(text: opening, voice: configuration.voice, speed: configuration.speed)
        ) else {
            log("[call] could not prepare an opening")
            return nil
        }
        log("[call] opening ready in \(String(format: "%.1f", Date().timeIntervalSince(started)))s: \(opening)")
        preparedOpening = opening
        return CallTurnServer.samples(fromWAV: audio.wav)
    }

    /// What the appliance is asked before the caller arrives.
    ///
    /// Written as an instruction about a call rather than a question, because
    /// the answer is spoken to someone who has just picked up the phone and
    /// wants to know where things stand — not read on a screen.
    ///
    /// Given the context a person answering the phone would already have —
    /// what time it is, how long since they last spoke — rather than a list of
    /// phrases to pick from. Canned warmth is worse than none: it is identical
    /// every time, so it stops meaning anything by the third call. Real context
    /// produces "morning" in the morning and "that was quick" when it was,
    /// without anyone writing either line.
    ///
    /// The name is asked for rather than assumed. It is in memory if they have
    /// ever said it, and if it is not, asking once and remembering is what a
    /// person would do — far better than an appliance that either guesses or
    /// never uses it.
    static func briefingRequest(now: Date, sinceLastCall: TimeInterval?) -> String {
        let clock = DateFormatter()
        clock.dateFormat = "EEEE h:mm a"
        var context = "It is \(clock.string(from: now)) where I am."
        if let gap = sinceLastCall {
            context += " We last spoke on a call \(spokenGap(gap)) ago."
        } else {
            context += " This is our first call today."
        }

        return """
            \(context)

            I'm about to join a voice call with you. Greet me by name in a few
            words — if you don't know my name, ask me for it and remember it when
            I tell you. Then say where things stand: anything open on my task
            list, and what we were last working on.

            Two or three short sentences, spoken aloud — no lists, no markdown.
            If there's genuinely nothing open, say so briefly. Let the time of
            day and how long it's been sound natural rather than announced.
            """
    }

    /// "a few minutes", "about an hour", "two days" — the way someone would say
    /// it, not a duration.
    static func spokenGap(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<120: return "a minute or two"
        case ..<3600: return "\(Int(seconds / 60)) minutes"
        case ..<7200: return "about an hour"
        case ..<86400: return "\(Int(seconds / 3600)) hours"
        case ..<172800: return "a day"
        default: return "\(Int(seconds / 86400)) days"
        }
    }

    /// A short stretch of silence, as a WAV recognition will accept.
    ///
    /// Used only to warm the path — the transcript is discarded, and would be
    /// discarded anyway, since silence is precisely what Whisper confabulates
    /// over.
    static func silence(milliseconds: Int) -> Data {
        let rate = 16000
        let samples = rate * milliseconds / 1000
        var wav = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) }
        }
        wav.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + samples * 2))
        wav.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(rate))
        append(UInt32(rate * 2))
        append(UInt16(2))
        append(UInt16(16))
        wav.append(contentsOf: Array("data".utf8))
        append(UInt32(samples * 2))
        wav.append(Data(count: samples * 2))
        return wav
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
            // Off the actor, because accept() blocks until a call arrives —
            // which is most of the time.
            //
            // Holding the actor in a blocking syscall makes every other entry
            // point unreachable, and the ones that matter are exactly the ones
            // that arrive while nothing is connected: setting the transcript
            // sink at startup, and preparing an opening when //call is typed.
            // The first of those deadlocked the daemon's own startup — it never
            // reached Signal at all, so the appliance sat there answering
            // nothing, with a log that stopped after "[call] ready".
            let accepted = await withoutBlockingTheActor { accept(descriptor, nil, nil) }
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
        transcript = CallTranscript()

        // Speak first.
        //
        // A call that opens in silence gives the caller nothing to react to:
        // they cannot tell a connected line from a broken one, so they say
        // "hello?" into it and wait. Answering the phone is the other party's
        // job, and here the appliance is the one being called.
        //
        // Safe to send immediately — this connection is only made once media is
        // already flowing from the caller, so the path back is up.
        await openTheCall(over: writer)

        while !Task.isCancelled {
            let frame: CallFrame
            do {
                // Blocking, off the actor: a read that parks here would stop the
                // actor answering anything, including the interruption that has
                // to arrive while a turn is running.
                frame = try await withoutBlockingTheActor { try reader.next() }
            } catch CallFrameReader.Failure.closed {
                log("[call] the call ended")
                lastCallEnded = Date()
                await postTranscript()
                return
            } catch {
                log("[call] the endpoint stopped: \(error)")
                lastCallEnded = Date()
                await postTranscript()
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
        transcript.heard(heard)

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
                    SpeechRequest(text: opener.line, voice: configuration.voice, speed: configuration.speed)
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
            let fullReply = try await answer(heard)
            waiting.cancel()
            let thought = Date()
            guard !Task.isCancelled else { return }
            log("[call] replying: \(fullReply)")

            // A link read aloud is useless: nobody writes down a maps URL while
            // holding a phone to their ear, and the synthesiser spends seconds
            // delivering something the caller cannot act on. They leave by the
            // channel that can carry them — the Signal thread is already open,
            // and a link in it is one tap.
            let split = SpokenReply.split(fullReply)
            if let links = SpokenReply.message(links: split.links) {
                await deliverTranscript?(links)
                log("[call] sent \(split.links.count) link(s) to the thread")
            }
            let reply = split.spoken
            transcript.said(fullReply)

            // Timed per stage rather than end to end. "A bit slow" is three
            // different problems — recognition, the model, synthesis — and they
            // have nothing in common except that the caller waits through all of
            // them. Only the first-sentence figure is what they actually
            // experience; the rest is spoken while they are already listening.
            var firstSpoken: Date?
            for sentence in CallTurnServer.sentences(in: reply) {
                guard !Task.isCancelled else { return }
                let speech = try await synthesizer.synthesize(
                    SpeechRequest(text: sentence, voice: configuration.voice, speed: configuration.speed)
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

    /// Answers the phone.
    ///
    /// Varied, because the same words every single time is the tell that turns
    /// a greeting into a recording — and this is the first thing anyone hears.
    private func openTheCall(over writer: CallFrameWriter) async {
        // Prepared at //call, so this is usually already waiting.
        if let prepared = await preparation?.value {
            try? writer.send(.replyAudio(prepared))
            log("[call] opened with the prepared briefing")
            if let opening = preparedOpening { transcript.said(opening) }
            preparation = nil
            return
        }

        // Nothing prepared — the endpoint was started some other way, or the
        // briefing failed. A plain hello beats silence.
        let greeting = CallTurnServer.greetings.randomElement() ?? "Hey, I'm here."
        guard let audio = try? await synthesizer.synthesize(
            SpeechRequest(text: greeting, voice: configuration.voice, speed: configuration.speed)
        ) else {
            log("[call] could not greet")
            return
        }
        try? writer.send(.replyAudio(CallTurnServer.samples(fromWAV: audio.wav)))
        log("[call] greeted: \(greeting)")
        transcript.said(greeting)
    }

    static let greetings = [
        "Hey, I'm here.",
        "Hey — what's up?",
        "I'm listening.",
        "Hey. Go ahead.",
        "Yep, I'm here."
    ]

    /// Posts what was said, if the owner wants it and anything was.
    private func postTranscript() async {
        guard let deliver = deliverTranscript else { return }
        guard CallPreferences.load().transcript else { return }
        guard let message = transcript.message() else { return }
        transcript = CallTranscript()
        await deliver(message)
        log("[call] transcript posted to the thread")
    }

    /// Fills a long think with something human.
    private func sayStillWorking(over writer: CallFrameWriter) async {
        let line = WorkingReply.progressLine(completed: [], pending: nil)
            ?? "Still on it."
        guard let audio = try? await synthesizer.synthesize(
            SpeechRequest(text: line, voice: configuration.voice, speed: configuration.speed)
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
    _ work: @escaping @Sendable () -> T
) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(returning: work())
        }
    }
}

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
