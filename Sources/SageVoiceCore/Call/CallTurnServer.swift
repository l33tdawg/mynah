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

    /// Runs the opening briefing, kept apart from `answer` on purpose.
    ///
    /// **`answer` remembers, and the briefing must not be remembered.** The
    /// daemon's `answer` closure ends in `callHistory.remember(result.messages)`,
    /// so running the briefing through it made the *request* — a machine-written
    /// instruction beginning "I'm about to join a voice call with you" — message
    /// zero of the conversation, attributed to the owner, who never said it. It
    /// was then re-sent on every turn until twelve turns pushed it out, and
    /// carried into the next call because the history is never cleared between
    /// them.
    ///
    /// What the caller *heard* is kept, through `onOpening`. That part has to
    /// stay: the first thing anybody says on a call answers the opening, and
    /// "I haven't picked it up yet" is unintelligible without the sentence that
    /// asked.
    ///
    /// Falls back to `answer` when nothing has been handed over, so a server
    /// built without a daemon still opens.
    private var brief: (@Sendable (String) async throws -> String)?

    /// Handed the opening the caller actually hears, briefed or plain, so the
    /// conversation can start where they started.
    ///
    /// Called from `openTheCall` rather than from `buildOpening`, and that is
    /// deliberate: `//call` may be pressed several times before anybody picks
    /// up, and seeding at build time would reset the history once per press —
    /// including, if a call were already up, in the middle of it.
    private var onOpening: (@Sendable (String) async -> Void)?

    /// See `onTurnSpoken`. Does nothing until the daemon that owns the model
    /// hands it something, which is the same shape as `recentMessages`.
    private var afterSpeaking: @Sendable () async -> Void = {}
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

    /// The recognition warm-up, deliberately **not** part of `preparation`.
    ///
    /// `handle(connection:)` awaits `preparation` before it enters its read
    /// loop, so anything folded into that task delays the greeting by its own
    /// duration. This one is the opposite shape: it exists to be finished by the
    /// time the caller stops talking, and nothing should ever wait on it. Its
    /// own handle so `//call` twice in a row does not stack two of them.
    private var recognitionWarming: Task<Void, Never>?

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

    /// **Which call this is**, minted per connection.
    ///
    /// Not decoration and not a log line: it is what tells a turn abandoned by
    /// `withDeadline` that it belongs to a call which has already ended. Without
    /// an identity per call, a queue entry arriving from an orphan is
    /// indistinguishable from one the current caller just asked for.
    private var callID: String?

    /// Where "do this after we hang up" is recorded. Nil until wired, which is
    /// what keeps every existing test constructing this server unchanged.
    private var afterTheCallQueue: CallActionQueue?

    /// Started once the line is down, with this call's claimed work.
    private var startTheDrain: (@Sendable ([CallActionQueue.Entry], [CallActionQueue.Entry]) -> Void)?

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

    /// How to run the opening briefing without it becoming part of the call.
    /// See `brief`.
    public func onBriefing(_ run: @escaping @Sendable (String) async throws -> String) {
        brief = run
    }

    /// Where the sentence the caller heard goes, so the conversation starts
    /// there. See `onOpening`.
    public func onOpeningSpoken(_ note: @escaping @Sendable (String) async -> Void) {
        onOpening = note
    }

    /// Where finished transcripts are posted.
    public func onTranscript(_ deliver: @escaping @Sendable (String) async -> Void) {
        deliverTranscript = deliver
    }

    /// Where after-the-call work is recorded, and what runs it once the line is
    /// down. Set after construction, like `onTranscript` and for the same
    /// reason: the thing that can reach Signal is built after this is.
    ///
    /// `drain` must start a **detached** task. A drain that inherited this
    /// actor's task tree would be cancelled by the very shutdown that makes the
    /// work outstanding.
    public func onAfterTheCall(
        _ queue: CallActionQueue,
        drain: @escaping @Sendable ([CallActionQueue.Entry], [CallActionQueue.Entry]) -> Void
    ) {
        afterTheCallQueue = queue
        startTheDrain = drain
    }

    /// Housekeeping to run once a turn has actually been spoken.
    ///
    /// **The distinction the daemon already makes, and this surface did not
    /// have anywhere to make.** `answer` returns before a word is synthesised,
    /// so anything hung off it is paid for in dead air on the caller's ear.
    /// This runs after `replyEnd` — the caller is listening to the answer rather
    /// than waiting for it, which is precisely when the appliance is free.
    ///
    /// Awaited rather than detached. What goes here is `anchorPromptCache`, and
    /// Ollama serves one slot: two anchors in flight queue against each other or
    /// thrash the KV cache, which costs more than it saves.
    public func onTurnSpoken(_ housekeeping: @escaping @Sendable () async -> Void) {
        afterSpeaking = housekeeping
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
        // **The third thing `//call` buys time for, and it was never bought.**
        //
        // The call site's own comment says this warms "the model, SAGE, the
        // voice and recognition". It warmed three of those. `buildOpening` runs
        // a brain turn and a synthesis; nothing in `prepare` has ever touched
        // the transcriber, and the parts written for it — `silence(_:)`,
        // `WhisperKitServerSupervisor.startWarming()`,
        // `WhisperKitServerTranscriber.warmupTimeoutSeconds` — have no callers
        // between them. The feature was designed, its pieces were written, the
        // wiring was skipped, and the comment claimed it anyway.
        //
        // Measured on the owner's call, 6 August 2026:
        //
        //     15:38:40 [asr] transcribed  54kB in 10.7s — somebody else's server
        //     15:38:43 [asr] transcribed  32kB in  2.0s — somebody else's server
        //     15:38:57 [asr] transcribed 111kB in  1.2s — somebody else's server
        //
        // Twice the audio in a ninth of the time, three turns later. That is a
        // cold model, and the log line proves it is not a cold *process*: it
        // appends ", after Ns starting it" whenever the supervisor spent over
        // half a second, and none of these carry it. The server was up and idle
        // with its weights unloaded — on this Mac it is QuietType's, which
        // Mynah cannot start or stop, so the only way to make it load them is to
        // ask it to transcribe something.
        //
        // The caller pays that 10.7s twice over, because the opener cannot fire
        // until there is a transcript to react to: the first filler on that call
        // came at 11.5s, and everything after it at 1.8s.
        recognitionWarming?.cancel()
        recognitionWarming = Task { [weak self] in
            await self?.warmRecognition()
        }
    }

    /// Pushes a moment of silence through the real transcriber so the model is
    /// resident before the caller speaks.
    ///
    /// **Through the same object a turn uses, not a fresh one.** The cascade
    /// picks a backend at call time, so warming anything else would warm a path
    /// the caller may not take — and on a Mac where WhisperKit is missing, this
    /// correctly warms whichever fallback will actually answer.
    ///
    /// Every outcome is discarded, including the errors. Silence is exactly what
    /// Whisper confabulates over, so `emptyTranscript` and `noiseOnlyTranscript`
    /// are the *expected* results; the transcript was never the point, the model
    /// load was. A failure here costs the caller the same 10.7s they pay today
    /// and nothing more, which is why it must never be able to fail a call.
    private func warmRecognition() async {
        let started = Date()
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("mynah-call-warmup-\(UUID().uuidString).wav")
        guard (try? CallTurnServer.silence(milliseconds: 250).write(to: scratch)) != nil else { return }
        defer { try? FileManager.default.removeItem(at: scratch) }

        // **`withDeadline` orphaning its work is the desired behaviour here**,
        // for once. Everywhere else in this file an orphan is the hazard — an
        // abandoned turn that comes back and speaks, or queues into the next
        // call. This one has no result anybody reads and no side effect beyond
        // the one it exists for, so a warm-up that outruns the deadline goes on
        // loading the model while we stop waiting for it, which is the whole
        // job. The bound is on our own bookkeeping, not on the server.
        let warm = transcriber
        _ = try? await withDeadline(
            WhisperKitServerTranscriber.warmupTimeoutSeconds,
            label: "recognition warm-up"
        ) {
            try? await warm.transcribe(audioFile: scratch)
        }
        guard !Task.isCancelled else { return }
        log("[call] recognition warmed in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
    }

    private func buildOpening() async -> Data? {
        let started = Date()
        let greeting = CallTurnServer.greetings.randomElement() ?? "Hey, I'm here."

        // The briefing is best-effort. A call that opens with a plain hello is
        // fine; a call that opens with nothing because a tool timed out is not.
        var opening = greeting

        // **No thread to carry on means no brain turn at all.**
        //
        // The briefing exists to continue the conversation the owner was
        // already having — *"most likely i'm calling you to continue the
        // conversation"*, *"skip the open items on task list - look at what we
        // were last talking about via text"*. With nothing said in messages
        // there is no thread, and asking the model anyway is how his task list
        // got read out on 8 August 2026: no traffic since the daemon started at
        // 06:44, so `recentMessages` was nil, and a model told to say what is
        // still open with nothing to continue found something open in the
        // backlog instead.
        //
        // The request has forbidden that in so many words since it was written
        // — "Do not read my task list out" — and being forbidden did not stop
        // it, because the same paragraph also asked for the one thing still
        // open. Deciding it here costs a model call and a tool round trip less
        // on exactly the calls where the briefing has nothing to add, and it
        // cannot be talked out of.
        //
        // The fallback is the one the request itself names: "just say hello and
        // ask what I need".
        guard let recent = await recentMessages(),
              !recent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            log("[call] nothing said in messages to pick up on; opening with a plain hello")
            return await preparedGreeting(opening, started: started)
        }

        let previous = LastCall.load()
        let request = CallTurnServer.briefingRequest(
            now: Date(),
            // From the record on disk when this process has not itself taken a
            // call — a restart is routine, and "what did we just talk about"
            // surviving only until the next one is the same bug again.
            sinceLastCall: (lastCallEnded ?? previous?.ended).map { Date().timeIntervalSince($0) },
            lastCall: previous,
            recentMessages: recent
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
        // `brief` when the daemon handed one over, `answer` otherwise. The
        // difference is only whether the request lands in the conversation —
        // see `brief`.
        let ask = brief ?? answer
        let briefing = try? await withDeadline(
            CallTurnServer.openingCeilingSeconds,
            label: "call opening"
        ) {
            try await ask(request)
        }
        if let briefing, !briefing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            opening = briefing
        } else {
            log("[call] the briefing did not arrive in time; opening with the plain line")
        }
        return await preparedGreeting(opening, started: started)
    }

    /// Synthesises whatever the call will open with, briefed or plain.
    ///
    /// Shared by both paths so a plain hello is prepared exactly the way a
    /// briefing is: cancelled at the same point, logged in the same line, and
    /// recorded in `preparedOpening` — which `openTheCall` hands on to the
    /// transcript and to the conversation.
    private func preparedGreeting(_ opening: String, started: Date) async -> Data? {
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
            then pick up where our messages left off — carry on the last thing
            we were talking about, or ask me what I want to do about it.

            Two or three short sentences, spoken aloud — no lists, no markdown.
            Do not read my task list out, and do not go looking for one: if the
            messages above give you nothing to carry on, say hello and ask what
            I need. That is a complete answer. Do not summarise everything we
            said either; take the last thread and continue it. Let the time of
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
            // **One site, so every exit is covered.** Patching the two `return`
            // paths worked and was fragile: a third way out of this function —
            // a throw, a future early return — would silently not stop the turn
            // again. The defer is where `retire()` already lives for the same
            // reason.
            endTheCurrentTurn()
            // The daemon-shutdown exit leaves through here and nowhere else —
            // `while !Task.isCancelled` falls out without reaching either catch
            // arm, so nothing is claimed and nothing is posted. Closing the call
            // means the entries keep their now-dead call id, and the next
            // startup finds them and tells the owner rather than performing
            // them.
            afterTheCallQueue?.closeCall()
            // A warm-up still in flight has outlived its purpose: the caller has
            // hung up, so nothing is about to be transcribed. Cancelling only
            // stops us waiting — the request itself is already orphaned inside
            // `withDeadline` and the server will finish loading either way,
            // which costs nothing and leaves the next call warmer.
            recognitionWarming?.cancel()
            recognitionWarming = nil
            live.retire()
            close(connection)
        }
        let reader = CallFrameReader(descriptor: connection)
        let writer = CallFrameWriter(live)
        log("[call] a call connected")
        transcript = CallTranscript()
        let thisCall = UUID().uuidString
        callID = thisCall
        afterTheCallQueue?.beginCall(thisCall)
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
                // **Before `postTranscript`, not at scope exit.**
                //
                // The `defer` below is the backstop and covers every other way
                // out, but it fires *after* this body — so an abandoned turn
                // that resumed during `postTranscript()`'s await was still live
                // and still pushed its links message. Stopping it first is the
                // difference between a turn that cannot file anything and one
                // that merely usually does not.
                endTheCurrentTurn()
                idleWatch?.cancel()
                lastCallEnded = Date()
                queueTheAfterCallWork()
                rememberThisCall()
                await postTranscript()
                return
            } catch {
                log("[call] the endpoint stopped: \(error)")
                // **Before `postTranscript`, not at scope exit.**
                //
                // The `defer` below is the backstop and covers every other way
                // out, but it fires *after* this body — so an abandoned turn
                // that resumed during `postTranscript()`'s await was still live
                // and still pushed its links message. Stopping it first is the
                // difference between a turn that cannot file anything and one
                // that merely usually does not.
                endTheCurrentTurn()
                idleWatch?.cancel()
                lastCallEnded = Date()
                queueTheAfterCallWork()
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

    /// Ends the turn along with the call it belongs to.
    ///
    /// **`CallConnection`'s doc said this already happened, and nothing did it.**
    /// Four findings of the 1.7.2 re-audit were this one omission, each surviving
    /// three independent skeptics:
    ///
    ///  - an abandoned turn reached `transcript.said(fullReply)` and
    ///    `deliverTranscript(links)`, which belong to whatever call is current
    ///    when it finally finishes — so the Signal record of call two carried a
    ///    question and an answer from call one that nobody ever heard, plus a
    ///    stray links message;
    ///  - `turn` was never cleared, so `isAnswering` was true as the next call
    ///    opened: its first "hey" was swallowed by the courtesy guard and its
    ///    first real question got the interrupted opening;
    ///  - and the doc on `CallConnection` told the next reader all of this was
    ///    handled, which is how a guard gets deleted.
    ///
    /// Retiring the connection is still what makes it *safe* — cancellation is
    /// cooperative, so a turn parked on the model does not stop for this, and
    /// the descriptor guard is what catches it when it wakes. This is what stops
    /// it doing the rest: filing a transcript, pushing links, and leaving the
    /// appliance believing it is busy.
    ///
    /// `turn = nil` rather than only cancelling, because `isAnswering` reads the
    /// reference and a cancelled task is still a task. That was the exact shape
    /// of the 1.7.0 bug this surface has already had once.
    private func endTheCurrentTurn() {
        guard turn != nil else { return }
        log("[call] the call ended mid-answer; stopping that turn")
        turn?.cancel()
        turn = nil
        turnNumber += 1
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
        // **A transcription that finishes after the hang-up must not start a
        // turn on the dead call.** The utterance tasks spawned by the read loop
        // are not cancelled when the call ends — recognition of the caller's
        // last words can land seconds later — and without this they would open
        // a fresh turn, write `transcript.heard` into whatever call is current,
        // and speak into a connection that belongs to somebody else now.
        guard writer.isUsable else {
            log("[call] recognised after the call ended; not starting a turn for it")
            return
        }

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

        // **Every turn reports, including the ones that do not finish.**
        //
        // This log used to be the last statement of the success path, which made
        // it a record of turns that went well rather than a record of turns.
        // Measured on this Mac: 20 turns reached `heard:`, and 12 produced a
        // timing line. The eight missing ones left by a `guard
        // !Task.isCancelled` or a `catch` — barged in on, hung up on, failed —
        // and they are the *slow* ones, because a turn is only barged in on when
        // the caller got bored waiting.
        //
        // So the two slowest thinks on this machine, at roughly 15s and 9s, are
        // invisible in the very dataset used to argue that the filler ladder
        // never gets past its first rung. A measurement that discards its own
        // tail cannot answer a question about the tail. `defer`, therefore, and
        // the exit is named.
        var recognised: Date?
        var thought: Date?
        var firstSpoken: Date?
        var outcome = "stopped before it began"
        // Per turn, and deliberately not an actor field. The filler task is
        // unstructured and can outlive its own turn — that is the orphan
        // documented below — so a shared counter would credit this turn's
        // fillers to the next one. A box created here is incremented only by the
        // task that captured it and read only by this turn's log.
        let fillers = FillerTally()
        defer {
            let seconds = { (from: Date, to: Date) in
                String(format: "%.1f", to.timeIntervalSince(from))
            }
            let now = Date()
            // **A stage that did not finish is reported as unfinished, not as a
            // duration.** Printing "thought in 12.4s" for a turn that was barged
            // in on while thinking states a completed measurement that never
            // completed — and this log's whole purpose is to be the dataset the
            // filler budget is decided from, so a number that means "elapsed so
            // far" sitting in a column that means "took" is worse than a blank.
            // The suffix marks it: `12.4s+` reads as at-least.
            let heardIn = recognised.map { "\(seconds(started, $0))s" } ?? "?"
            let thoughtIn = recognised.map { r in
                thought.map { "\(seconds(r, $0))s" } ?? "\(seconds(r, now))s+"
            } ?? "?"
            let spokeIn = thought.map { t in
                firstSpoken.map { "\(seconds(t, $0))s" } ?? "\(seconds(t, now))s+"
            } ?? "?"
            let talkingAfter = firstSpoken.map { "\(seconds(started, $0))s" } ?? "never"
            log("[call] \(outcome): heard in \(heardIn), thought in \(thoughtIn), "
                + "spoke in \(spokeIn) — talking after \(talkingAfter)"
                + ", \(fillers.spoken) filler(s)")
        }

        do {
            recognised = Date()
            guard !Task.isCancelled else { outcome = "cancelled before answering"; return }
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
            // `CallOpening.interruptedOpening`.
            //
            // **`CallOpening`, not `WorkingReply`.** These read the shared
            // pool until 1.7.5, and the shared catch-all promises to come back
            // later — true on Signal, and on a call a promise to a line that is
            // about to drop. See `CallOpening` for the owner's ruling.
            let chosen = interrupting
                ? CallOpening.interruptedOpening(forRequest: heard, previous: lastOpener)
                : CallOpening.opening(forRequest: heard, previous: lastOpener)
            if let opener = chosen {
                lastOpener = opener.line
                if let audio = try? await synthesizer.synthesize(
                    SpeechRequest(text: opener.line, voice: configuration.voice, speed: configuration.speed)
                ) {
                    // The guard that was missed when the outcomes were added.
                    // Without it this exit reported "stopped before it began"
                    // about a turn that had already been heard, transcribed and
                    // had an opener synthesised for it — which is the precise
                    // kind of mislabelling the outcome strings exist to end.
                    guard !Task.isCancelled else { outcome = "barged in on during the opener"; return }
                    try? await send(.replyAudio(CallTurnServer.samples(fromWAV: audio.wav)), over: writer)
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
                    // Counted on the way out, not on the way in: `position` and
                    // `previous` govern the ladder and are about what was
                    // chosen; the tally is about what was heard.
                    if await self.sayFiller(line, over: writer) { fillers.fired() }
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
            // **Stamped with the call and turn this work belongs to, before the
            // model is asked anything.**
            //
            // `withDeadline` runs `think` in an unstructured task and walks away
            // from it on overrun, and `MCPClient` reads the node's pipe with no
            // deadline at all — so that orphan can come back minutes later, on a
            // call the caller was told had failed, and still dispatch its tool
            // calls. A task-local is the one mechanism with the right
            // inheritance: an unstructured `Task {}` carries it, so the orphan
            // still knows which call it was, while `Task.detached` does not,
            // which is what stops the drain from ever queueing anything.
            let generation = callID.map {
                CallActionQueue.Generation(call: $0, turn: turnNumber)
            }
            var fullReply: String
            do {
                fullReply = try await CallActionQueue.$current.withValue(generation) {
                    try await withDeadline(
                        configuration.turnCeilingSeconds,
                        label: "call turn"
                    ) {
                        try await think(heard)
                    }
                }
            } catch let overrun as DeadlineExceeded {
                // Spoken, not thrown. `turnFailed` ends the turn at the endpoint
                // and the caller hears nothing at all — which is the failure
                // this whole change is about, arriving by a different route.
                log("[call] \(overrun); saying so rather than holding the line")
                fullReply = CallTurnServer.tookTooLong
            }
            // **The moment the waiting is over, stop saying so.**
            //
            // The `defer` above is a backstop and must stay: it is what covers
            // the paths that never reach this line — a throw out of the
            // synthesiser, a cancellation, the `callEnded` return. But a defer
            // fires at *scope exit*, which here is after the whole
            // synthesise-and-send loop, after `replyEnd`, and after
            // `afterSpeaking()`. Left to it alone, the filler stayed alive for
            // the entire time the answer was being spoken and went on waking on
            // its cadence — so the caller got "Nearly there." spliced between
            // two sentences of the answer he had already started hearing, or
            // spoken as an orphan a beat after it finished.
            //
            // That is a regression I introduced moving this into the defer: the
            // old code cancelled here and covered only the success path, so
            // widening the cover silently delayed it. Both, not either.
            // `Task.cancel()` is idempotent.
            waiting.cancel()

            // **The caller is told out loud, whether or not the model remembers
            // to say it.**
            //
            // The tool result instructs the model to promise it, and mostly it
            // will. But there are six early returns below the model call and a
            // barge-in right after a tool call is the ordinary way a second
            // request arrives — so "mostly" here means a caller who asked for
            // something, was told nothing, and gets a file an hour later with no
            // idea why.
            //
            // Counted per turn rather than from a running total: a shared
            // counter would report an abandoned turn's queueing against
            // whichever turn happens to be running, which is precisely backwards
            // and is the defect `FillerTally` was made a per-turn box for.
            if let generation,
               let queue = afterTheCallQueue,
               queue.queued(inTurn: generation) > 0,
               // `tookTooLong` exists to hand the work to Signal — "send it to
               // me there and I'll give it the time it needs". Promising to
               // handle it after the call in the same breath tells the caller to
               // do both, and if they comply it happens twice.
               fullReply != CallTurnServer.tookTooLong {
                fullReply = AfterTheCall.promising(fullReply)
            }
            // **The inverse, and it is the half that actually shipped broken.**
            //
            // Above: something was queued and the model did not say so, so it
            // gets said. Here: the model said so and the queue is empty, so the
            // sentence is a promise nobody is going to keep. Asked for a ferry
            // ticket on 1.8.0's first real call, the model answered *"Will do —
            // I'll send the ferry ticket to your Signal thread right after we
            // hang up"* without ever calling `after_the_call`. The caller heard
            // a promise, hung up, and waited for a file that did not exist as a
            // request anywhere on this Mac.
            //
            // `ToolLoop` catches this per turn and sends the model back with the
            // tools still attached, which is the repair. This is the ground
            // truth underneath it — the queue itself, which the trace cannot
            // see — and it covers the one case the trace gets wrong: a turn
            // orphaned by `withDeadline` calling `after_the_call` after its call
            // has ended gets `notOnACall` back, which is a perfectly successful
            // tool call recording nothing.
            //
            // `else if`, because these two are opposites and running both on one
            // reply would append a promise and then contradict it.
            else if let generation,
                    let queue = afterTheCallQueue,
                    !queue.anythingQueued(onCall: generation.call),
                    fullReply != CallTurnServer.tookTooLong,
                    AfterTheCall.commitsToDoingItLater(fullReply) {
                log("[call] the reply promised after-the-call work with nothing queued; corrected")
                fullReply = AfterTheCall.couldNotQueue
            }

            thought = Date()
            guard !Task.isCancelled else { outcome = "barged in on while thinking"; return }
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
            for sentence in CallTurnServer.sentences(in: reply) {
                guard !Task.isCancelled else { outcome = "barged in on mid-answer"; return }
                let speech = try await synthesizer.synthesize(
                    SpeechRequest(text: sentence, voice: configuration.voice, speed: configuration.speed)
                )
                guard !Task.isCancelled else { outcome = "barged in on mid-answer"; return }
                var audio = CallTurnServer.samples(fromWAV: speech.wav)
                audio.append(CallTurnServer.pause(after: sentence))
                try await send(.replyAudio(audio), over: writer)
                if firstSpoken == nil { firstSpoken = Date() }
            }
            try await send(.replyEnd, over: writer)
            outcome = "answered"

            // The answer is on its way to the caller's ear; the appliance is
            // free until they speak again. See `onTurnSpoken`.
            await afterSpeaking()
        } catch is CancellationError {
            outcome = "cancelled"
            return
        } catch CallFrameWriter.Failure.callEnded {
            // The caller hung up while this answer was being prepared.
            //
            // Not an error, and specifically not "could not answer" — it was
            // answered, there is simply nobody on the line to hear it. What
            // matters is that it stops here rather than writing into a
            // descriptor the kernel may already have handed to the next call.
            // See `CallConnection`.
            outcome = "hung up on before the answer"
            log("[call] the call ended before the answer did; leaving it unsaid")
        } catch {
            outcome = "failed"
            log("[call] could not answer: \(error)")
            try? await send(.turnFailed("\(error)"), over: writer)
        }
    }

    /// How many filler lines one turn actually spoke.
    ///
    /// A box rather than a field on the actor, because the filler task is
    /// unstructured: cancellation is best-effort, and an orphan can speak — and
    /// count — after its own turn has returned. A shared counter would report
    /// that filler against whichever turn happens to be running, which is
    /// precisely backwards for a measurement meant to decide how many fillers a
    /// turn needs.
    private final class FillerTally: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func fired() {
            lock.lock()
            count += 1
            lock.unlock()
        }

        var spoken: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    /// Answers the phone.
    ///
    /// Varied, because the same words every single time is the tell that turns
    /// a greeting into a recording — and this is the first thing anyone hears.
    private func openTheCall(over writer: CallFrameWriter) async {
        // Prepared at //call, so this is usually already waiting.
        if let prepared = await preparation?.value {
            try? await send(.replyAudio(prepared), over: writer)
            log("[call] opened with the prepared briefing")
            if let opening = preparedOpening {
                transcript.said(opening)
                await onOpening?(opening)
            }
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
        try? await send(.replyAudio(CallTurnServer.samples(fromWAV: audio.wav)), over: writer)
        log("[call] greeted: \(greeting)")
        transcript.said(greeting)
        await onOpening?(greeting)
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

    /// The prepared opening, awaited exactly the way `openTheCall` awaits it.
    ///
    /// **A seam, for the same reason as the one above.** The guarantee being
    /// tested is that the recognition warm-up is not folded into `preparation`:
    /// `handle(connection:)` awaits that task before its read loop, so a warm-up
    /// living inside it would delay the greeting by its own duration — and the
    /// warm-up is, by design, the slow thing. Asking through the socket instead
    /// would mean standing up a connection to observe a property, and would
    /// still be reading this same value at the end of it.
    func openingForTesting() async -> Data? { await preparation?.value }

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
        try? await send(.replyAudio(CallTurnServer.samples(fromWAV: audio.wav)), over: writer)
        transcript.said(line)
        log("[call] said \"\(line)\"")
    }

    /// Sends a frame without holding the actor while it goes.
    ///
    /// **`CallFrameWriter.send` is a blocking `write`, and every call site was on
    /// the actor.** One reply frame carries a sentence plus `pause(after:)` — up
    /// to 600ms of 48 kHz 16-bit, which is tens of kilobytes and more than a unix
    /// socket buffers for a peer that is not draining fast enough. Parked in
    /// there, the actor answers nothing at all: not the next utterance, not the
    /// interruption that by definition arrives mid-turn, not the idle watch.
    ///
    /// The endpoint drains eagerly, so this is rare — but `SO_SNDTIMEO` now bounds
    /// a stuck write at fifteen seconds, and fifteen seconds is precisely how long
    /// the whole call surface would have been deaf for.
    ///
    /// Same reason `accept()` and `reader.next()` already go through
    /// `withoutBlockingTheActor`. This was the third blocking syscall on this
    /// surface and the one still holding the lock.
    ///
    /// Ordering survives: each caller awaits its own sends in sequence, and
    /// `CallConnection` serialises anything that overlaps.
    private func send(_ frame: CallFrame, over writer: CallFrameWriter) async throws {
        try await withoutBlockingTheActor { try writer.send(frame) }
    }

    private func endCall(over writer: CallFrameWriter) async {
        log("[call] no one has spoken for \(Int(CallTurnServer.hangUpAfter))s; ending the call")
        try? await send(.endCall, over: writer)
    }

    /// **Takes ownership of what this call asked for, and starts the work.**
    ///
    /// Synchronous, deliberately. The accept loop awaits `handle(connection:)`
    /// to completion behind a listen backlog of one, so a suspension here would
    /// hold the next call off for as long as the drain takes — and a drain that
    /// sends files can take minutes. This does one claim and one file write; the
    /// work itself is a detached task started inside `startTheDrain`.
    ///
    /// Placed before `rememberThisCall()` so what was promised rides into
    /// `LastCall` and the next call opens knowing about it, and before
    /// `postTranscript()` because that resets the transcript before it awaits
    /// delivery — anything appended after it is never posted.
    private func queueTheAfterCallWork() {
        guard let queue = afterTheCallQueue, let id = callID else { return }
        callID = nil
        let taken = queue.claim(forCall: id)
        guard !taken.mine.isEmpty || !taken.abandoned.isEmpty else { return }
        if !taken.mine.isEmpty {
            transcript.queued(taken.mine.map(\.spokenLine))
            log("[call] \(taken.mine.count) action(s) queued for after the call")
        }
        startTheDrain?(taken.mine, taken.abandoned)
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
    /// - Returns: whether the caller actually heard it.
    ///
    /// Three of the four exits here speak nothing — two cancellations and a
    /// synthesiser failure — and the count that feeds the turn log has to know
    /// the difference. Counting at the decision instead would over-report by one
    /// on precisely the barge-in paths that log was widened to cover: a filler
    /// chosen and then cancelled by the answer landing is not a filler the
    /// caller sat through.
    @discardableResult
    private func sayFiller(_ line: String, over writer: CallFrameWriter) async -> Bool {
        guard !Task.isCancelled else { return false }
        guard let audio = try? await synthesizer.synthesize(
            SpeechRequest(text: line, voice: configuration.voice, speed: configuration.speed)
        ) else { return false }
        guard !Task.isCancelled else { return false }
        // **`try?` swallows a failed write, so the send has to be checked.**
        //
        // Reporting `true` after it threw would log "said …" about audio that
        // never left the Mac, and count a filler the caller did not hear — which
        // is the same over-count this return value was added to remove, arriving
        // one line further down. The likeliest thrower is `callEnded`: the
        // caller hung up mid-filler.
        do {
            try await send(.replyAudio(CallTurnServer.samples(fromWAV: audio.wav)), over: writer)
        } catch {
            return false
        }
        log("[call] said \"\(line)\" while working")
        return true
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
    private let turns: Int

    /// Twelve exchanges, counted as the daemon counts them.
    ///
    /// **Turns, not messages, and that is the whole point.** This was
    /// `suffix(24)` over raw messages, which slides by one on nearly every
    /// append — so the byte prefix the model is asked to prefill moved almost
    /// every turn, and Ollama's KV checkpoint matched nothing. Cutting only at a
    /// user message means the prefix is stable until a turn genuinely falls out
    /// of the window.
    public init(keepingLastTurns turns: Int = 12) {
        self.turns = turns
    }

    public func recent() -> [BrainMessage] {
        messages
    }

    /// **The daemon's own filter, called rather than reimplemented.**
    ///
    /// This stored `conversation.dropFirst()` unfiltered: assistant tool-call
    /// turns and whole `.toolResult` messages included, and a result can run to
    /// six thousand characters. The daemon strips those through
    /// `conversationOnly` for a reason it writes down — with last turn's tool
    /// output still in context a 4B model concludes it already has the facts and
    /// stops calling the tool — and the call path had neither that protection
    /// nor the tokens back.
    ///
    /// Calling the daemon's function instead of copying it is deliberate. A
    /// second copy of this idea is exactly how the two surfaces drifted apart in
    /// the first place, and `conversationOnly` has since grown a fix (the empty
    /// assistant turn that bricks a thread) that a copy here would not have.
    ///
    /// No `dropFirst` any more either: that assumed message zero is the system
    /// prompt, and `conversationOnly` drops every system message wherever it is.
    public func remember(_ conversation: [BrainMessage]) {
        messages = VoiceBridgeDaemon.trimmed(
            VoiceBridgeDaemon.conversationOnly(conversation),
            keepingLastTurns: turns
        )
    }

    /// Starts a call at the sentence the caller actually heard.
    ///
    /// **The opening is kept and the briefing that produced it is not.** The
    /// request that writes an opening is a machine-written instruction the owner
    /// never spoke; storing it made it message zero of the conversation, in his
    /// voice, re-sent on every turn. What he hears has to stay, because the
    /// first thing he says answers it — "I haven't picked it up yet" needs the
    /// sentence that asked whether he had.
    ///
    /// Replaces rather than appends, so a call starts on itself. The previous
    /// call's tail is not lost to the model: `briefingRequest` is handed
    /// `LastCall.closing` for exactly that, and it says which is which rather
    /// than leaving two calls to run together as one conversation.
    public func open(with opening: String) {
        let said = opening.trimmingCharacters(in: .whitespacesAndNewlines)
        messages = said.isEmpty ? [] : [BrainMessage(role: .assistant, content: said)]
    }

    public func forget() {
        messages = []
    }
}
