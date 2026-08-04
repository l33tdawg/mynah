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

        /// How long a caller may be left on an open line before being told.
        ///
        /// **The daemon has had one of these since 1.5.4 and this surface had
        /// none**, which is the worse of the two places to be missing it: a
        /// Signal thread that goes quiet is a thread, and a phone line that goes
        /// quiet is a caller saying "hello? … hello?" into a live microphone
        /// while the appliance holds it open. See `withDeadline` for the class of
        /// hang this exists for, and why it is not a task group.
        ///
        /// **Ninety seconds, derived rather than picked.** `CallFiller` says its
        /// last word at 26 seconds — 6, then 6, 8, 6 — and then deliberately goes
        /// quiet, because a caller who has heard four "nearly there"s knows
        /// everything a fifth would tell them. So 26s is the moment the line
        /// genuinely falls silent, and this is roughly three times it: about a
        /// minute of silence is the most a caller absorbs before concluding the
        /// call has dropped.
        ///
        /// It is deliberately well under `ToolLoop.defaultDeadlineSeconds`, the
        /// loop's own 300-second brake, which is the right bound for a written
        /// thread and is five minutes of dead air on a phone. A call that needs
        /// that long is a call that should have been a message, and
        /// `CallTurnServer.tookTooLong` says exactly that to the caller.
        ///
        /// **On `Configuration` rather than a static, for the reason
        /// `VoiceBridgeDaemon.Configuration.turnCeilingSeconds` is**: while that
        /// one was a `static let`, nothing in the suite could build a surface that
        /// gave up in under six minutes, so every assertion anybody wrote was on
        /// the constant's arithmetic and deleting the line that *used* it left the
        /// suite green.
        public static let defaultTurnCeilingSeconds: TimeInterval = 90

        /// See `defaultTurnCeilingSeconds`.
        public var turnCeilingSeconds: TimeInterval

        public init(
            socketURL: URL = CallTurnServer.defaultSocket(),
            voice: String? = nil,
            speed: Double = 1.15,
            turnCeilingSeconds: TimeInterval = CallTurnServer.Configuration.defaultTurnCeilingSeconds
        ) {
            self.socketURL = socketURL
            self.voice = voice
            self.speed = speed
            self.turnCeilingSeconds = turnCeilingSeconds
        }
    }

    /// What the caller hears when the ceiling above is reached.
    ///
    /// **A dead end with a door in it.** "Something went wrong" down a phone line
    /// leaves the caller with a working appliance and no idea what to do next, so
    /// this names the thing that will work: the Signal thread, whose own ceiling
    /// is 360 seconds — four times this one — and which can take as long as the
    /// question needs because nobody is holding a line open while it thinks.
    ///
    /// Not a promise to come back. The abandoned turn is cancelled on the way out
    /// (see `withDeadline`) and there is nothing left running to come back *with*,
    /// so saying "I'll message you when it's done" would be a lie the caller then
    /// waits on.
    public static let tookTooLong = """
        Sorry — that one's taking longer than I can hold the line for. \
        Send it to me on Signal and I'll give it the time it needs.
        """

    /// How long the opening briefing may take before the call opens without it.
    ///
    /// Shorter than `Configuration.turnCeilingSeconds`, and the gap is the
    /// point: an overrun here costs a warmer first sentence, an overrun there
    /// costs the caller's actual answer. `//call` buys a handful of seconds of
    /// warning and this is meant to fit inside them — a briefing still being
    /// written when the caller picks up has already missed its purpose.
    ///
    /// The failure this bounds is not a slow briefing, though. It is a wedged
    /// one: `prepare()` is awaited by `handle(connection:)` before it reaches
    /// its read loop, so a briefing that never returns takes the whole call
    /// surface with it. See `buildOpening`.
    public static let openingCeilingSeconds: TimeInterval = 20

    private let configuration: Configuration
    private let transcriber: any AudioFileTranscribing
    private let synthesizer: any SpeechSynthesizing
    private let answer: @Sendable (String) async throws -> String

    /// The last few things said in messages, for the opening to pick up on.
    ///
    /// **A call is usually a continuation, not a status request.** The owner:
    /// *"most likely i'm calling you to continue the conversation"*, and before
    /// that, *"skip the open items on task list - look at what we were last
    /// talking about via text"*.
    ///
    /// Handed in rather than recalled, for the reason stated at
    /// `briefingRequest`: memory returns what is most *relevant*, and the
    /// thread he was in five minutes ago is rarely that. The same mistake once
    /// opened a call with "last we talked, you were heading to bed" on an
    /// evening whose actual last exchange had been about tonkatsu shops.
    private var recentMessages: @Sendable () async -> String?
    private let log: @Sendable (String) -> Void

    private var listening: Int32 = -1
    private var turn: Task<Void, Never>?

    /// Which turn `turn` is holding, so the one that finishes can only retire
    /// itself and never the one that superseded it.
    private var turnNumber = 0

    /// Whether a turn is actually in flight.
    ///
    /// **Three places asked this question by writing `turn.map { !$0.isCancelled }`,
    /// and all three were wrong in the same way.** `Task.isCancelled` is false
    /// for a task that finished normally, and `turn` was never cleared — so from
    /// the first turn the appliance ever took, for the rest of the process and
    /// across every later call, that expression was permanently true.
    ///
    /// What it cost, once each:
    ///
    /// - the courtesy guard swallowed every real "thanks", "okay" and "bye" the
    ///   caller said for the rest of the call, logging `heard "thanks" while
    ///   working` with nothing working. That is the failure `HeardSpeech`'s own
    ///   comment calls the worse one — ignoring the owner, who has no idea why.
    /// - `cutIn` gave every ordinary follow-up question the interrupted opening,
    ///   so asking a second thing sounded like being caught talking over it.
    /// - `quietFor` returned nil for ever, and `startIdleWatch` treated nil as a
    ///   reason to stop, so the watchdog that checks in and hangs up an
    ///   abandoned call died five seconds after the first utterance. A call
    ///   nobody was on stayed open indefinitely, microphone included.
    ///
    /// Found by the 1.7.0 audit, not by the suite: every test of these three
    /// exercised the predicate's inputs in isolation and none drove a turn to
    /// completion first.
    private var isAnswering: Bool { turn != nil }

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

    /// When the caller last said something. Drives the check-in below.
    private var lastHeard = Date()

    /// Watches for a call nobody is on any more.
    private var idleWatch: Task<Void, Never>?

    public init(
        configuration: Configuration,
        transcriber: any AudioFileTranscribing,
        synthesizer: any SpeechSynthesizing,
        answer: @escaping @Sendable (String) async throws -> String,
        recentMessages: @escaping @Sendable () async -> String? = { nil },
        log: @escaping @Sendable (String) -> Void = { print($0) }
    ) {
        self.configuration = configuration
        self.transcriber = transcriber
        self.synthesizer = synthesizer
        self.answer = answer
        self.recentMessages = recentMessages
        self.log = log
    }

    /// Where the opening reads the message thread from.
    ///
    /// Set after construction, like `onTranscript` and for the same reason: the
    /// call server is built before the daemon that owns the conversation,
    /// because `//call` needs its socket whether or not Signal ever comes up.
    public func onRecentMessages(_ provide: @escaping @Sendable () async -> String?) {
        recentMessages = provide
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
        let previous = LastCall.load()
        let request = CallTurnServer.briefingRequest(
            now: Date(),
            // From the record on disk when this process has not itself taken a
            // call — a restart is routine, and "what did we just talk about"
            // surviving only until the next one is the same bug again.
            sinceLastCall: (lastCallEnded ?? previous?.ended).map { Date().timeIntervalSince($0) },
            lastCall: previous,
            recentMessages: await recentMessages()
        )
        // **The other call site of the same closure, and it had no ceiling.**
        //
        // 1.7.0 bounded `speak`, and stopped there — the fifth time this release
        // cycle that a fix landed at one call site while an identical one went
        // unwatched. This one is worse than the one that was fixed. `speak` runs
        // inside `turn`, so a wedge there loses an answer; this runs inside
        // `prepare()`, which `handle(connection:)` awaits *before* it enters its
        // read loop. A wedge here means the caller is never recognised at all,
        // `defer { close(connection) }` never runs, and `run()` never returns to
        // `accept()`. The listen backlog is 1, so the second call queues
        // unaccepted and the third is refused outright: the call surface is dead
        // until the daemon restarts.
        //
        // Shorter than the turn ceiling on purpose. Nobody is on the line yet —
        // this is the few seconds of warning //call buys — so overrunning costs
        // a generic opening rather than a wrong answer, and `opening` already
        // holds one worth saying. Waiting the full 90 here would mean the caller
        // arrives to silence in the one place the appliance is supposed to be
        // ready and waiting.
        let brief = answer
        let briefing = try? await withDeadline(
            CallTurnServer.openingCeilingSeconds,
            label: "call opening"
        ) {
            try await brief(request)
        }
        if let briefing, !briefing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            opening = briefing
        } else {
            log("[call] the briefing did not arrive in time; opening with the plain line")
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
    /// **It no longer asks who it is talking to.**
    ///
    /// This used to open with "greet me by name — if you don't know my name,
    /// ask me for it". The owner: *"we also have the first call agent asks
    /// users for their name - we should probably just disable that; it isn't
    /// helpful"*.
    ///
    /// It is worse than unhelpful, and the reason is what this appliance is.
    /// Mynah answers exactly one person's phone — the allowlist refuses every
    /// other caller by construction — so there is no one it could be talking to
    /// whose name is in question. Asking spends the first thing said on a call
    /// establishing something already settled, and does it on a surface where
    /// the answer has to be spoken and recognised.
    ///
    /// Nothing replaced it. An appliance that greets its only owner with "hey"
    /// and then says what is open is doing the whole job of an opening.
    static func briefingRequest(
        now: Date,
        sinceLastCall: TimeInterval?,
        lastCall: LastCall? = nil,
        recentMessages: String? = nil
    ) -> String {
        let clock = DateFormatter()
        clock.dateFormat = "EEEE h:mm a"
        var context = "It is \(clock.string(from: now)) where I am."
        if let gap = sinceLastCall {
            context += " We last spoke on a call \(spokenGap(gap)) ago."
        } else {
            context += " This is our first call today."
        }

        // Stated, not recalled.
        //
        // Asking the model what we last talked about retrieves by relevance
        // rather than by time, and the most memorable exchange is rarely the
        // most recent one. Live, that produced "last we talked, you were heading
        // to bed" on an evening whose actual last conversation had been about
        // tonkatsu shops — both in memory, and nothing in the question said
        // which came last.
        if let lastCall {
            context += """


                This is how our last call actually ended. Use it rather than \
                searching your memory for what is most recent, because your \
                memory returns what is most relevant and that is not the same \
                thing:

                \(lastCall.closing)
                """
        }

        if let recentMessages, !recentMessages.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            context += """


                These are the last things we said to each other in messages, \
                oldest first. This is almost certainly what I am calling about:

                \(recentMessages)
                """
        }

        return """
            \(context)

            I'm about to join a voice call with you. Greet me in a few words,
            then pick up where our messages left off — say the one thing that is
            still open between us, or ask what I want to do about it.

            Two or three short sentences, spoken aloud — no lists, no markdown.
            Do not read my task list out and do not summarise everything we
            said; take the last thread and carry it on. If there is genuinely
            nothing to pick up, just say hello and ask what I need. Let the time
            of day and how long it's been sound natural rather than announced.
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
            // **Never let a dead endpoint kill the appliance.**
            //
            // Without this, a `write()` to a peer that has hung up raises
            // SIGPIPE, whose default disposition terminates the process — so the
            // call endpoint crashing mid-sentence would take Signal, the
            // proactive watch and everything else down with it, silently and
            // with no log line, because the appliance is gone before it can
            // write one. The endpoint is a separate binary this daemon launches
            // and restarts, so this is a thing that happens rather than a thing
            // that could.
            //
            // `SignalLineSocket` has done exactly this since the transport was
            // written, for exactly this reason. This socket was simply never
            // given the same line, and nothing noticed until a test drove a real
            // connection and closed it — the failure arrives as the whole
            // process dying with signal 13, which is not a shape anybody reading
            // a call log would recognise.
            var noSignalOnADeadPeer: Int32 = 1
            setsockopt(
                accepted, SOL_SOCKET, SO_NOSIGPIPE,
                &noSignalOnADeadPeer, socklen_t(MemoryLayout<Int32>.size)
            )
            // **No write may park forever.**
            //
            // Ending a call retires its `CallConnection`, and retiring waits for
            // any write already in flight — that wait is what stops the
            // descriptor being closed and reissued underneath a turn that is
            // still speaking. An unbounded write would therefore be an unbounded
            // wait, on the actor, with the whole call surface behind it.
            //
            // Fifteen seconds is far outside anything healthy. `enqueue` on the
            // endpoint side appends to an in-memory slice and never blocks, so a
            // working endpoint drains this socket as fast as the kernel will
            // hand it over; it does not pace reads to playback. Fifteen seconds
            // of *no progress at all* means the endpoint is wedged, and a wedged
            // endpoint is a dead call whether or not this side admits it.
            var sendTimeout = timeval(tv_sec: 15, tv_usec: 0)
            setsockopt(
                accepted, SOL_SOCKET, SO_SNDTIMEO,
                &sendTimeout, socklen_t(MemoryLayout<timeval>.size)
            )
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
        // The identity of *this* call, as distinct from the number the kernel
        // happens to be using for it.
        //
        // Retired before the descriptor is closed, never after. `retire()` waits
        // for any write in flight, so by the time `close` runs no turn can be
        // inside a write — which is what makes it safe for the next `accept()`
        // to be handed this same number, as POSIX will.
        let live = CallConnection(descriptor: connection)
        defer {
            live.retire()
            close(connection)
        }
        let reader = CallFrameReader(descriptor: connection)
        let writer = CallFrameWriter(live)
        log("[call] a call connected")
        transcript = CallTranscript()
        lastHeard = Date()
        startIdleWatch(over: writer)

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
                idleWatch?.cancel()
                lastCallEnded = Date()
                rememberThisCall()
                await postTranscript()
                return
            } catch {
                log("[call] the endpoint stopped: \(error)")
                idleWatch?.cancel()
                lastCallEnded = Date()
                rememberThisCall()
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
            case .replyAudio, .replyEnd, .turnFailed, .endCall:
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

        // Measured every turn, not only when something looks suspicious.
        //
        // The threshold in `CallAudioEnergy.silenceCeiling` is set from the
        // segmenter's own reported noise floors and has not yet been checked
        // against a real call on real hardware. Logging the amplitude of every
        // segment — the ones taken as speech included — is what turns that into
        // a measured number instead of a guess, and it costs one line per turn.
        let amplitude = CallAudioEnergy.rootMeanSquare(ofWAV: wav)
        let cameFromSilence = amplitude.map { $0 < CallAudioEnergy.silenceCeiling } ?? false

        guard !HeardSpeech.isNothing(
            heard,
            milliseconds: milliseconds,
            cameFromSilence: cameFromSilence
        ) else {
            // A cough, a door, a car, the appliance's own voice returning — or
            // Whisper filling silence with a phrase from its training data.
            // Nothing was said, so nothing changes, and in particular whatever
            // the appliance is already doing carries on.
            let what = heard.isEmpty ? "nothing" : "\"\(heard)\" (no one spoke)"
            let level = amplitude.map { String(format: "%.0f", $0) } ?? "unreadable"
            log("[call] heard \(what) in \(milliseconds)ms of audio, amplitude \(level)")
            return
        }

        // **A courtesy never takes an answer away.**
        //
        // `replaceTurn` cancels whatever is running, because words arriving
        // mid-answer normally mean the caller has moved on. "Thank you" does not
        // mean that, from either direction: said for real it is a pleasantry
        // over the top of work the caller still wants, and invented over silence
        // it is nothing at all. Either way, cancelling is the one response that
        // cannot be right.
        //
        // This is what actually cost a tester his answers on 1.6.3 — nine
        // phantom "Thank you." in one call, each one stopping the model
        // mid-thought so the appliance could say "you're welcome" instead of the
        // thing he asked for. Deliberately not gated on the amplitude: the
        // threshold is a measurement and this is an argument, and the argument
        // holds however loud the room was.
        if HeardSpeech.isCourtesy(heard), isAnswering {
            log("[call] heard \"\(heard)\" while working — not treating that as a new question")
            return
        }

        // Words. Now the previous turn is genuinely superseded.
        // Measurement only — `replaceTurn` already logs what was heard. This is
        // the number that tells us whether `silenceCeiling` is set anywhere near
        // right, and it is only useful beside the accepted turns as well as the
        // discarded ones.
        log("[call] accepted \(milliseconds)ms of audio, amplitude "
            + (amplitude.map { String(format: "%.0f", $0) } ?? "unreadable"))
        await replaceTurn(with: heard, recognisedIn: Date().timeIntervalSince(started), over: writer)
    }

    private func replaceTurn(
        with heard: String,
        recognisedIn recognition: TimeInterval,
        over writer: CallFrameWriter
    ) {
        // Whether this turn *cut another one off*, decided before the cancel
        // that makes it untrue. A turn still running when words arrive is the
        // caller talking over the appliance; one that finished a moment ago is
        // the caller simply saying the next thing, and those deserve different
        // opening words.
        let cutIn = isAnswering
        turn?.cancel()
        turnNumber += 1
        let mine = turnNumber
        turn = Task { [weak self] in
            await self?.speak(
                heard,
                recognisedIn: recognition,
                interrupting: cutIn,
                over: writer
            )
            await self?.finished(mine)
        }
    }

    /// Retires a turn that has run to the end.
    ///
    /// Numbered, because a turn that was cancelled and replaced must not clear
    /// the slot its replacement now occupies — it finishes later and would
    /// otherwise report the live turn as over.
    private func finished(_ number: Int) {
        guard number == turnNumber else { return }
        turn = nil
    }

    private func speak(
        _ heard: String,
        recognisedIn recognition: TimeInterval,
        interrupting: Bool = false,
        over writer: CallFrameWriter
    ) async {
        let started = Date().addingTimeInterval(-recognition)
        do {
            let recognised = Date()
            guard !Task.isCancelled else { return }
            log("[call] heard: \(heard)")
        lastHeard = Date()
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
            // Interrupting gets its own opening. Cutting in stops the audio
            // instantly, so from the caller's side the appliance goes abruptly
            // silent — and the next thing they hear is what tells them whether
            // it *heard* them or merely *stopped*. See
            // `WorkingReply.interruptedOpening`.
            let chosen = interrupting
                ? WorkingReply.interruptedOpening(forRequest: heard, previous: lastOpener)
                : WorkingReply.opening(forRequest: heard, previous: lastOpener)
            if let opener = chosen {
                lastOpener = opener.line
                if let audio = try? await synthesizer.synthesize(
                    SpeechRequest(text: opener.line, voice: configuration.voice, speed: configuration.speed)
                ) {
                    guard !Task.isCancelled else { return }
                    try? writer.send(.replyAudio(CallTurnServer.samples(fromWAV: audio.wav)))
                    log("[call] said \"\(opener.line)\" after \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
                }
            }

            // Filling the gap, rather than one line into the middle of it.
            //
            // The opener buys a few seconds. A tool call runs well past them,
            // and the silence *after* an opener is worse than the silence
            // before one — the caller has been told it is working and then
            // hears nothing, which reads as the thing having crashed
            // mid-sentence rather than merely being slow.
            //
            // A cadence of short sounds instead: see `CallFiller` for why they
            // are sounds rather than sentences, why they escalate, and why
            // there are only four.
            // **Cancelled on the way out, whichever way out it is.**
            //
            // `waiting.cancel()` used to sit after the answer, which meant every
            // path that did not reach that line left this running: a barge-in
            // (the caller's next question cancels the turn, `withDeadline`'s
            // handler settles the gate with `CancellationError`, and control
            // jumps past it), or any `BrainBackendError`. The orphan is
            // unstructured, so it inherits no cancellation and keeps going —
            // synthesising up to four filler lines into the live socket over
            // about 26 seconds, on top of the *next* turn's own filler and its
            // real answer. The caller hears two overlapping streams of "nearly
            // there" while being answered.
            //
            // None of it reached the transcript either, because `sayFiller`
            // deliberately does not record.
            let waiting = Task { [weak self] in
                var position = 0
                var previous: String?
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(CallFiller.delay(before: position)))
                    guard !Task.isCancelled, let self else { return }
                    guard let line = CallFiller.line(at: position, previous: previous) else {
                        // Past the cap. Going quiet is the right end: a caller
                        // who has heard five "nearly there"s knows exactly as
                        // much as one who heard two.
                        return
                    }
                    previous = line
                    position += 1
                    await self.sayFiller(line, over: writer)
                }
            }
            defer { waiting.cancel() }
            // **Bounded, because the line is open the whole time this runs.**
            //
            // The filler above stops at four lines and about 26 seconds, on
            // purpose. Everything after that is silence on a live call, and until
            // now there was no end to it: a turn parked in something cancellation
            // cannot interrupt — the node's pipe read is the known one — held the
            // caller on an open line indefinitely, with a hot microphone and no
            // word from the appliance. The daemon has had this bound since 1.5.4
            // and this surface never did.
            //
            // Read off the configuration rather than a constant so a test can
            // shorten it; see `Configuration.turnCeilingSeconds` for where 90
            // comes from.
            //
            // Hoisted out of `self` because the work runs outside this actor's
            // isolation. It captures the closure and the caller's sentence and
            // nothing else, which is what lets it be abandoned safely.
            let think = answer
            let fullReply: String
            do {
                fullReply = try await withDeadline(
                    configuration.turnCeilingSeconds,
                    label: "call turn"
                ) {
                    try await think(heard)
                }
            } catch let overrun as DeadlineExceeded {
                // Spoken, not thrown. `turnFailed` ends the turn at the endpoint
                // and the caller hears nothing at all — which is the failure
                // this whole change is about, arriving by a different route.
                log("[call] \(overrun); saying so rather than holding the line")
                fullReply = CallTurnServer.tookTooLong
            }
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
                var audio = CallTurnServer.samples(fromWAV: speech.wav)
                audio.append(CallTurnServer.pause(after: sentence))
                try writer.send(.replyAudio(audio))
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
        } catch CallFrameWriter.Failure.callEnded {
            // The caller hung up while this answer was being prepared.
            //
            // Not an error, and specifically not "could not answer" — it was
            // answered, there is simply nobody on the line to hear it. What
            // matters is that it stops here rather than writing into a
            // descriptor the kernel may already have handed to the next call.
            // See `CallConnection`.
            log("[call] the call ended before the answer did; leaving it unsaid")
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
    /// Asks whether the caller is still there, and eventually hangs up.
    ///
    /// A call nobody is on stays open indefinitely otherwise: the owner has
    /// wandered off, put the phone down, or forgotten the tab, and the line sits
    /// there holding a microphone. Waiting for them to remember is not a design.
    ///
    /// Two stages, because one is rude. A minute of quiet gets a question — the
    /// same thing a person would do, and often the owner is simply thinking. Only
    /// after a second minute with no answer does it say goodbye and end the call,
    /// which by then is describing what has already happened rather than deciding
    /// it.
    ///
    /// The check-ins are not counted as the appliance having heard anything, so
    /// a silent caller does not reset their own timer by being asked.
    private func startIdleWatch(over writer: CallFrameWriter) {
        idleWatch?.cancel()
        idleWatch = Task { [weak self] in
            var asked = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self else { return }
                // `continue`, not `return`. nil means a turn is in flight, which
                // is a transient and entirely ordinary state — treating it as a
                // reason to stop killed the watchdog at the first utterance and
                // left an abandoned call open for ever.
                guard let quiet = await self.quietFor() else { continue }

                if !asked, quiet > CallTurnServer.checkInAfter {
                    asked = true
                    await self.say(CallTurnServer.checkIns.randomElement() ?? "Still there?",
                                   over: writer)
                } else if asked, quiet > CallTurnServer.hangUpAfter {
                    await self.say("I'll let you go — call me back whenever.", over: writer)
                    await self.endCall(over: writer)
                    return
                } else if quiet < CallTurnServer.checkInAfter {
                    asked = false
                }
            }
        }
    }

    /// How long since the caller said anything, or nil if a turn is running.
    ///
    /// A turn in flight means the appliance is working on something they asked
    /// for, and asking "still there?" over the top of that is the appliance
    /// interrupting itself.
    /// What `quietFor` believes, for a test.
    ///
    /// **A seam, because the property could not be reached otherwise.** The bug
    /// this exists for lived in the second utterance of a call and killed the
    /// idle watch silently; the alternative to asking directly is a test that
    /// waits out the real 60-second check-in, which buys nothing and costs a
    /// minute of wall clock in every suite run.
    func quietForTesting() -> TimeInterval? { quietFor() }

    private func quietFor() -> TimeInterval? {
        if isAnswering { return nil }
        return Date().timeIntervalSince(lastHeard)
    }

    static let checkInAfter: TimeInterval = 60
    static let hangUpAfter: TimeInterval = 120

    static let checkIns = [
        "Still there? Anything else?",
        "Anything else you need?",
        "Still with me?",
        "Anything else, or shall I let you go?"
    ]

    /// A breath between sentences.
    ///
    /// Synthesised sentences are queued end to end, so the appliance runs them
    /// together with no gap at all — "there is Menya Musashi plus Marutama
    /// Gantetsu and Ton Chan" arrives as one breathless string, and a listener
    /// cannot hear where one item stops and the next starts. Nobody talks like
    /// that, and it is most obvious in exactly the answers that need it least
    /// obviously: lists.
    ///
    /// Longer after a colon, because a colon is a sentence announcing that a
    /// list is coming and the pause is what makes the announcement work.
    ///
    /// Silence rather than anything clever: this is the pause a speaker takes,
    /// not a sound.
    static func pause(after sentence: String) -> Data {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        let milliseconds: Int
        switch trimmed.last {
        case ":": milliseconds = 420
        case "?": milliseconds = 320
        default: milliseconds = 240
        }
        // 48 kHz mono, sixteen bits: the rate the endpoint encodes at.
        return Data(count: 48 * milliseconds * 2)
    }

    private func say(_ line: String, over writer: CallFrameWriter) async {
        guard let audio = try? await synthesizer.synthesize(
            SpeechRequest(text: line, voice: configuration.voice, speed: configuration.speed)
        ) else { return }
        try? writer.send(.replyAudio(CallTurnServer.samples(fromWAV: audio.wav)))
        transcript.said(line)
        log("[call] said \"\(line)\"")
    }

    private func endCall(over writer: CallFrameWriter) async {
        log("[call] no one has spoken for \(Int(CallTurnServer.hangUpAfter))s; ending the call")
        try? writer.send(.endCall)
    }

    /// Keeps what this call was about, for the next one to open with.
    private func rememberThisCall() {
        guard let record = LastCall.from(transcript) else { return }
        try? record.save()
    }

    private func postTranscript() async {
        guard let deliver = deliverTranscript else { return }
        guard CallPreferences.load().transcript else { return }
        guard let message = transcript.message() else { return }
        transcript = CallTranscript()
        await deliver(message)
        log("[call] transcript posted to the thread")
    }

    /// Fills a long think with something human.
    /// One short thing, said into the gap.
    ///
    /// Not `say(_:over:)`, and the difference is the transcript: that one
    /// records what it speaks, and filler is not something the appliance said.
    /// A call record reading "Mm. Bear with me. Still going." is a record of
    /// nothing, and it is what the owner would find posted into Signal after
    /// the call.
    ///
    /// Checked for cancellation on both sides of the synthesiser, because
    /// synthesis takes a few hundred milliseconds and the answer may land
    /// inside them — filler arriving *after* the reply has started is worse
    /// than the silence it was meant to cover.
    private func sayFiller(_ line: String, over writer: CallFrameWriter) async {
        guard !Task.isCancelled else { return }
        guard let audio = try? await synthesizer.synthesize(
            SpeechRequest(text: line, voice: configuration.voice, speed: configuration.speed)
        ) else { return }
        guard !Task.isCancelled else { return }
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
