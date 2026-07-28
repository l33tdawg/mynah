import Foundation

/// The loop that makes this a product rather than four smoke-test subcommands.
///
///     Signal message ──▶ ASR (if a voice note) ──▶ agent loop over SAGE MCP ──▶ reply
///
/// Text reply first, deliberately: it is the phase the owner asked to start
/// with, it needs no TTS wired, and it makes every other part of the chain
/// observable in a transcript you can scroll back through.
///
/// ## What it refuses to do
///
/// Every message is filtered by `SignalSenderAllowlist` inside `SignalClient`
/// before it reaches `incomingMessages`, so this type never sees a stranger's
/// message. It also never *initiates* — it only replies to a thread that was
/// already addressed to the appliance. An agent manager that can message people
/// unprompted is a different and much more dangerous product.
public actor VoiceBridgeDaemon {

    public struct Configuration: Sendable {
        /// Marks a message as the appliance's rather than the owner's.
        ///
        /// The appliance is driven from Note-to-Self, and Signal draws that
        /// entire thread as one column of the owner's own outgoing bubbles —
        /// there is no incoming side to render on the left, so no styling,
        /// alignment or read-receipt trick can separate the two speakers. The
        /// only lever left is the text itself.
        ///
        /// The real fix is to give the bridge its own Signal number, at which
        /// point the thread has two genuine parties and Signal does this for us.
        /// Until then, this does the job a whole column of layout would.
        ///
        /// Bracketed rather than bare: one glyph alone reads as punctuation
        /// while scrolling, and three in a row read as shouting. Delimiters do
        /// the work instead — they say "label", which is what this is.
        public static let defaultReplyPrefix = "‹🧠› "

        /// Spoken to the owner when a turn fails in a way we cannot explain.
        public var genericFailureReply: String
        /// Prefix on every reply, so a Signal thread makes it obvious which
        /// messages came from the appliance rather than from a person.
        public var replyPrefix: String
        /// Conversation turns kept for context.
        ///
        /// This was 6, on the grounds that every turn re-sends the whole history
        /// at ~130 tok/s of prefill, which made history the most expensive knob
        /// on the appliance. That was true, and it is not true any more.
        ///
        /// Prefill only costs anything when the prompt cache *misses*, and it
        /// was missing every turn for a reason unrelated to length: the tool
        /// schemas were being serialised with their JSON keys in a different
        /// order each time (Swift seeds dictionary hashing per process), so a
        /// byte-prefix cache matched nothing. With `.sortedKeys` the prefill of
        /// a warm turn fell from 3,572 tokens to 4, and a turn from 27.7 s to
        /// 11.0 s.
        ///
        /// That changes what history costs. Turn N's history is a *prefix* of
        /// turn N+1's prompt, so it is already in the cache — carrying it
        /// forward is close to free, and the ceiling is `num_ctx` rather than
        /// patience. Hence 16: the owner gets an appliance that remembers the
        /// whole conversation instead of one that forgets what they said four
        /// sentences ago and has to go ask SAGE.
        ///
        /// Not free, two ways, both worth watching: KV cache grows with context,
        /// and a 4B model's instruction-following degrades as context fills.
        /// Routing accuracy at 16 turns of history is *not* measured — the
        /// 12/12 figure quoted elsewhere was on short contexts.
        public var historyTurnLimit: Int
        /// Refuse transcripts longer than this. A 20-minute voice note is
        /// almost certainly a misfire, and it would cost minutes of model time.
        public var maximumTranscriptCharacters: Int
        /// Send a short acknowledgement before the slow part starts.
        ///
        /// Off by default, and the reasoning that put it there was wrong. The
        /// argument was that 40–70 s of silence reads as "it's broken" — true in
        /// a two-sided chat. But the appliance is used from Note-to-Self, where
        /// Signal renders *every* message as the owner's own outgoing bubble, so
        /// an acknowledgement is not reassurance: it is a third indistinguishable
        /// blue bubble between the question and the answer. Owner's verdict on
        /// seeing it: "they sound very fake and don't make sense."
        ///
        /// Kept as a switch rather than deleted, because in a thread with a real
        /// second party — the bridge on its own number — the original argument
        /// holds and this becomes worth turning back on.
        public var sendsThinkingAcknowledgement: Bool
        /// How long to wait for the rest of a thought before answering.
        ///
        /// "look up xyz and make a list" followed a second later by "oh and add
        /// abc" is one request finished late, not two requests. See
        /// `MessageCoalescer` for why this waits rather than starting and
        /// cancelling.
        public var messageQuietWindow: Duration

        public init(
            genericFailureReply: String = "Something went wrong handling that. It's logged.",
            replyPrefix: String = VoiceBridgeDaemon.Configuration.defaultReplyPrefix,
            historyTurnLimit: Int = 16,
            maximumTranscriptCharacters: Int = 4000,
            sendsThinkingAcknowledgement: Bool = false,
            messageQuietWindow: Duration = MessageCoalescer.defaultQuietWindow
        ) {
            self.genericFailureReply = genericFailureReply
            self.replyPrefix = replyPrefix
            self.historyTurnLimit = historyTurnLimit
            self.maximumTranscriptCharacters = maximumTranscriptCharacters
            self.sendsThinkingAcknowledgement = sendsThinkingAcknowledgement
            self.messageQuietWindow = messageQuietWindow
        }
    }

    /// What happened to one message. Returned for tests and logging; the owner
    /// sees only the reply text.
    public enum Outcome: Equatable, Sendable {
        case replied(transcript: String, reply: String, seconds: TimeInterval)
        /// Nothing actionable — no text and no audio.
        case ignoredEmpty
        /// Transcribed to nothing. Silence, or a failed download.
        case ignoredBlankTranscript
        case failed(String)
    }

    private let signal: SignalClient
    private let transcriber: AudioFileTranscribing
    private let loop: ToolLoop
    private let configuration: Configuration
    private let log: (String) -> Void

    /// Per-thread conversation history, keyed by the recipient we reply to.
    ///
    /// Keyed by thread rather than held globally so a group and a direct
    /// message cannot bleed into each other's context.
    private var histories: [String: [BrainMessage]] = [:]

    /// The last "hang on" line sent to each thread.
    ///
    /// Kept so the next one can avoid repeating it. Random choice from four
    /// options still repeats about a quarter of the time, and the same sentence
    /// twice running is *more* obviously mechanical than the same sentence
    /// always — it reads as something that tried to sound human and slipped.
    ///
    /// Per-thread, and deliberately not persisted: it is a conversational tic,
    /// not state worth surviving a restart.
    private var lastWorkingLines: [String: String] = [:]

    /// Whether this turn already said something when the message arrived.
    ///
    /// Turn-scoped rather than per-thread: it exists only to stop the
    /// tool-decision line repeating news the arrival line already gave, and that
    /// question is answered and finished within one turn. Safe as a single value
    /// because turns are answered sequentially — see the intake loop.
    private var spokeOnArrival = false

    /// Writes history after every turn.
    ///
    /// After, not on shutdown: the daemon is stopped with `pkill` on every
    /// deploy and dies outright on a crash, so a save that only runs on a clean
    /// exit is a save that never runs when it matters.
    ///
    /// Failures are logged and swallowed. Losing the ability to resume is a
    /// disappointment; failing the turn the owner is waiting on, because a cache
    /// file would not write, is a fault.
    private func persistConversations() {
        guard let conversations else { return }
        do {
            try conversations.save(histories)
        } catch {
            log("[daemon] could not save conversation history: \(error)")
        }
    }

    func lastWorkingLine(for key: String) -> String? { lastWorkingLines[key] }

    func rememberWorkingLine(_ line: String, for key: String) { lastWorkingLines[key] = line }

    /// Fetched once and reused. `tools/list` costs a round trip and the
    /// catalogue does not change while the server is up.
    private var cachedTools: [MCPTool]?

    /// Periodic re-prime. Cancelled on stop.
    private var keepWarmTask: Task<Void, Never>?

    /// Measured turn times, so the acknowledgement can quote a real number.
    private var estimator = TurnDurationEstimator()

    /// SAGE's own boot and per-turn discipline. Nil disables it — useful in
    /// tests and for a bridge pointed at a non-SAGE MCP server.
    private let ritual: SageRitual?

    /// The same instance the tool catalogue was built from, held here so the
    /// reply can carry the documents that turn produced.
    ///
    /// A concrete type rather than a protocol, deliberately. There is exactly
    /// one thing in this product that makes files, and the seam a protocol would
    /// buy has no second implementation to justify it — the same argument
    /// `CompositeToolSource` makes for web search not being an MCP server.
    private let notes: NotesToolSource?

    /// Where history goes so a deploy does not erase the conversation.
    /// `nil` disables persistence entirely, which is what the tests use.
    private let conversations: ConversationStore?

    public init(
        signal: SignalClient,
        transcriber: AudioFileTranscribing,
        loop: ToolLoop,
        configuration: Configuration = Configuration(),
        ritual: SageRitual? = nil,
        notes: NotesToolSource? = nil,
        conversations: ConversationStore? = nil,
        log: @escaping (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    ) {
        self.signal = signal
        self.transcriber = transcriber
        self.loop = loop
        self.configuration = configuration
        self.ritual = ritual
        self.notes = notes
        self.conversations = conversations
        self.log = log
    }

    /// Runs until the message stream finishes (i.e. until `signal.stop()`).
    public func run() async {
        await signal.start()

        // Before anything else the owner might reply into. A restart is
        // invisible from their side — they just carry on talking — so the
        // conversation has to be back before the first message can arrive.
        if let conversations {
            let restored = conversations.load()
            if !restored.isEmpty {
                histories = restored
                let turns = restored.values.reduce(0) { $0 + $1.count }
                log("[daemon] resumed \(restored.count) conversation(s), \(turns) turns")
            }
        }

        // SAGE's boot sequence, before the warm-up and not after. Inception's
        // reply becomes part of the system prompt, and the warm-up's only value
        // is a cached prefix that matches real requests byte for byte — warming
        // first would cache a prompt no turn ever sends.
        if let ritual {
            if await ritual.boot() != nil {
                loop.setSystemPrompt(await ritual.systemPrompt(base: loop.systemPrompt))
            }
        }

        // Pay the prefill before anyone is waiting on it. An appliance boots
        // once and then sits idle for hours, so this cost belongs at startup.
        //
        // Local models only, for the same reason keep-warm is: this primes an
        // on-device KV cache. A hosted model has none, so the request buys
        // nothing — and against Gemini's ten-per-minute free tier it spends a
        // tenth of the owner's first minute to do it.
        if loop.backendIsLocal, let tools = try? await toolCatalogue() {
            let started = Date()
            let warmed = await loop.warmUp(tools: tools)
            log(String(
                format: "[daemon] warm-up %@ in %.1fs",
                warmed ? "ok" : "FAILED (turns will be slower)",
                Date().timeIntervalSince(started)
            ))
            if warmed {
                startKeepWarm(tools: tools)
            }
        }

        log("[daemon] listening for Signal messages")

        // Reading and answering are split so a follow-up sent while the previous
        // one is still in flight lands somewhere, instead of sitting unread in
        // the stream behind a turn that can now run five minutes.
        let inbox = MessageInbox()
        let reader = Task { [signal] in
            for await message in signal.incomingMessages {
                await inbox.append(message)
            }
            await inbox.close()
        }
        defer { reader.cancel() }

        while true {
            await inbox.waitForArrival()
            let batch = await inbox.takeBatch(quietWindow: configuration.messageQuietWindow)
            if batch.isEmpty {
                if await inbox.isClosed { break }
                continue
            }
            if batch.count > 1 {
                log("[daemon] merging \(batch.count) messages sent together into one turn")
            }
            // Sequential on purpose. Two voice notes answered concurrently would
            // interleave their tool calls against one SAGE node and race on the
            // thread history — and the model is the bottleneck anyway, so there
            // is no throughput to win.
            let outcome = await handle(batch)
            log("[daemon] \(batch[0].logDescription) -> \(outcome.logDescription)")
        }
        log("[daemon] message stream finished")
    }

    public func stop() async {
        keepWarmTask?.cancel()
        keepWarmTask = nil
        await signal.stop()
    }

    /// Re-primes the cache on a timer so an idle appliance stays fast.
    ///
    /// Ollama drops the model — and its KV cache with it — after `keep_alive`
    /// elapses, which for this product is 30 minutes. An agent manager is idle
    /// for hours at a time and then wanted *immediately*, so paying 14 seconds
    /// of prefill on the owner's first sentence of the morning is exactly the
    /// wrong place to save power. The interval is deliberately well inside the
    /// eviction window rather than close to it.
    private func startKeepWarm(tools: [MCPTool]) {
        // Local models only. Re-warming preserves an on-device KV cache; a
        // hosted API has none to preserve, so the timer would spend quota to
        // buy nothing — 72 requests a day against Gemini's free tier before the
        // owner has said a word, and the same again in tokens on a paid one.
        guard loop.backendIsLocal else {
            log("[daemon] keep-warm off: a hosted backend has no local cache to keep warm")
            return
        }

        keepWarmTask?.cancel()
        keepWarmTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.keepWarmIntervalSeconds * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                await self.reWarm(tools: tools)
            }
        }
    }

    private func reWarm(tools: [MCPTool]) async {
        // Silent unless it fails — a heartbeat that logs every 20 minutes buries
        // the lines that matter.
        if await loop.warmUp(tools: tools) == false {
            log("[daemon] keep-warm failed; the next turn will pay full prefill")
        }
    }

    /// Comfortably inside Ollama's 30-minute `keep_alive`.
    static let keepWarmIntervalSeconds: TimeInterval = 20 * 60

    // MARK: One message

    /// Exposed so a test can drive a synthetic message without a live daemon.
    @discardableResult
    public func handle(_ message: SignalIncomingMessage) async -> Outcome {
        await handle([message])
    }

    /// Answers one turn, which may have arrived as several messages.
    ///
    /// Merging happens here rather than in the loop because a batch is not
    /// several requests — it is one request the owner finished typing late, and
    /// everything downstream (history, tools, the reply) should see exactly one
    /// turn. See `MessageCoalescer`.
    public func handle(_ batch: [SignalIncomingMessage]) async -> Outcome {
        let started = Date()

        guard let message = batch.first else { return .ignoredEmpty }
        guard let recipient = message.replyRecipient else {
            // Nothing to reply to. Dropping is correct: the alternative is
            // guessing a destination, and guessing wrong means the owner's
            // agent messages a stranger.
            return .failed("no reply recipient on \(message.logDescription)")
        }

        // One unreadable voice note in a batch must not discard the text that
        // came with it — the owner said both things.
        //
        // The comment said that before the code did. The do/catch wrapped the
        // whole loop, so a throw on the second item threw away the first item's
        // transcript too, and the owner got "I couldn't read that voice note"
        // for a message they had also typed out. Caught per item now, which is
        // what the sentence always claimed.
        var parts: [String] = []
        var failures = 0
        for item in batch {
            do {
                if let raw = try await resolveTranscript(item) { parts.append(raw) }
            } catch {
                failures += 1
                log("[daemon] could not transcribe one of \(batch.count) message(s): \(error)")
            }
        }
        let transcript = MessageCoalescer.merge(parts)
        guard !transcript.isEmpty else {
            guard failures == 0 else {
                await reply("I couldn't read that voice note.", to: recipient)
                return .failed("transcription failed for all \(failures) attachment(s)")
            }
            return .ignoredEmpty
        }

        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .ignoredBlankTranscript
        }
        guard transcript.count <= configuration.maximumTranscriptCharacters else {
            await reply("That was too long for me to act on — try a shorter one.", to: recipient)
            return .failed("transcript of \(transcript.count) characters exceeds the limit")
        }

        // Before the model, not after it. Everything else the appliance says
        // while working is gated on a tool decision, and deciding costs a whole
        // model call — which is why "Having a look." landed most of a minute
        // after the question. This is derived from the owner's own sentence, so
        // it needs nothing from the model and is not a prediction about it.
        spokeOnArrival = false
        let threadKey = recipient.description
        if let opener = WorkingReply.instantLine(
            forRequest: transcript,
            previous: lastWorkingLines[threadKey]
        ) {
            spokeOnArrival = true
            lastWorkingLines[threadKey] = opener
            await reply(opener, to: recipient)
        }

        // Anything left over from a turn that failed after writing a note. The
        // file stays on disk — it is the owner's, and the turn that made it may
        // simply have run out of iterations — but it must not ride out on the
        // next unrelated reply, which is what happens without this line.
        if let stale = notes?.drainWrittenNotes(), !stale.isEmpty {
            log("[daemon] discarding \(stale.count) undelivered note(s) from an earlier turn")
        }

        if configuration.sendsThinkingAcknowledgement {
            await reply(
                WaitingPhrases.acknowledgement(estimatedSeconds: estimator.typicalSeconds),
                to: recipient
            )
        }

        do {
            let tools = try await toolCatalogue()
            let key = recipient.description
            let result = try await loop.run(
                transcript: transcript,
                tools: tools,
                history: histories[key] ?? [],
                images: batch.flatMap { resolveImages($0) },
                onToolDecision: { [weak self] chosen in
                    guard let self else { return }
                    // Already spoke on arrival. Saying "having a look" a second
                    // time, seconds after "let me check your backlog", is the
                    // same news twice — the next thing the owner hears should be
                    // a progress update or the answer.
                    guard await !self.spokeOnArrival else { return }
                    let previous = await self.lastWorkingLine(for: key)
                    guard let line = WorkingReply.line(forTools: chosen, previous: previous) else {
                        return
                    }
                    await self.rememberWorkingLine(line, for: key)
                    await self.reply(line, to: recipient)
                },
                onProgress: { [weak self] update in
                    guard let self, let line = update.line else { return }
                    // "Looking that up online — give me a few seconds." followed
                    // by "Looking online for the rest of it." is two true
                    // sentences and one piece of news. Varying the wording was
                    // supposed to stop the appliance sounding mechanical; a
                    // stutter puts that back.
                    let previous = await self.lastWorkingLine(for: key)
                    guard !WorkingReply.saysTheSameThing(line, as: previous) else { return }
                    await self.rememberWorkingLine(line, for: key)
                    await self.reply(line, to: recipient)
                }
            )
            histories[key] = Self.trimmed(
                Self.conversationOnly(result.messages),
                keepingLastTurns: configuration.historyTurnLimit
            )
            persistConversations()
            // Documents this turn produced go out with the sentence that
            // announces them, not as a second message. On Note-to-Self every
            // message is the owner's own outgoing bubble, so a follow-up bubble
            // carrying the file would read as a third indistinguishable blue
            // block — the same reason the thinking acknowledgement is off.
            await reply(result.reply, to: recipient, attaching: notes?.drainWrittenNotes() ?? [])
            log("[daemon] \(result.trace.summary)")
            // Cleanup should tidy a reply, not amputate it. A large gap between
            // what the model produced and what the owner receives means
            // `speakable` ate something — most likely an unclosed <think> tag,
            // which strips to end-of-string.
            if let raw = result.messages.last?.content {
                let cleaned = result.reply.count
                if raw.count > 40, cleaned < raw.count / 2 {
                    log("[daemon] WARNING reply shrank \(raw.count) -> \(cleaned) chars during cleanup")
                }
            }
            estimator.record(Date().timeIntervalSince(started))

            // Put a prompt-cache checkpoint where the next turn will begin.
            //
            // qwen3.5 is hybrid attention/SSM, so llama.cpp cannot trim the KV
            // cache to an arbitrary position — "the context does not support
            // partial sequence removal" — and can only rewind to a checkpoint.
            // Checkpoints are spaced at least 8,192 tokens apart, more than this
            // whole conversation, so the only recent one sits at the END of the
            // last prompt: a few tokens past where the next turn diverges, hence
            // invalid, hence a rewind to something ancient. Measured on the
            // appliance, task 13434: a prompt matching the cache to 99.7% —
            // ten new tokens — re-evaluated 2,401 tokens and cost 11.4 s.
            //
            // Replaying the conversation *without* the owner's next sentence
            // plants a checkpoint exactly at the divergence, so the next turn
            // restores there. Synthetic measurement: 10.76 s → 0.33 s.
            //
            // After the reply, like the SAGE ritual below, because the owner is
            // no longer waiting. Ollama serves one slot at a time, so this does
            // occupy the model briefly — acceptable only because it is short and
            // nobody is blocked on it.
            await loop.anchorPromptCache(history: histories[key] ?? [], tools: tools)

            // After the reply, never before. SAGE's turn discipline is the
            // appliance's own housekeeping and the owner must not wait on it —
            // but it must happen, because the server starts refusing non-SAGE
            // tool calls once enough of them pile up without a sage_turn, and
            // web_search is a non-SAGE call. Skipping this would surface days
            // later as "web search broke".
            if let ritual {
                await ritual.recordTurn(
                    transcript: transcript,
                    reply: result.reply,
                    usedTools: result.trace.toolNames
                )
            }

            return .replied(
                transcript: transcript,
                reply: result.reply,
                seconds: Date().timeIntervalSince(started)
            )
        } catch let error as BrainBackendError {
            // These have sentences written for exactly this moment.
            await reply(error.spokenDescription, to: recipient)
            return .failed("\(error)")
        } catch {
            await reply(configuration.genericFailureReply, to: recipient)
            return .failed("\(error)")
        }
    }

    /// Voice note first, then text. A message carrying both is a voice note
    /// with a caption, and the spoken part is the instruction.
    private func resolveTranscript(_ message: SignalIncomingMessage) async throws -> String? {
        if let audio = message.voiceNoteURL {
            return try await transcriber.transcribe(
                audioFile: audio,
                options: AudioTranscriptionOptions()
            )
        }
        if message.hasText {
            return message.text
        }
        // A photo sent with no caption is still a request. Standing in for the
        // owner with a plain question is better than ignoring the message,
        // which is what "no text, no audio" used to do.
        if !message.imageURLs.isEmpty {
            return "What is in this picture?"
        }
        return nil
    }

    /// The images on this message, downscaled and encoded for the model.
    ///
    /// Never throws. A photo that cannot be read is worth a log line and a turn
    /// that proceeds on the words alone — refusing to answer "what is this?"
    /// because one attachment was a malformed HEIC would be a worse appliance
    /// than one that says it cannot see anything.
    private func resolveImages(_ message: SignalIncomingMessage) -> [Data] {
        // Logged unconditionally when anything is attached, because the failure
        // this catches is silent by construction: an attachment that is not
        // recognised as an image produces no error, no empty file and no
        // exception — just a model that says it cannot see pictures. Knowing
        // whether the MIME type, the on-disk lookup or the encoder was at fault
        // is the difference between a one-line fix and another round trip.
        if !message.attachments.isEmpty {
            let described = message.attachments.map { attachment in
                "\(attachment.contentType ?? "no-type")"
                    + " image=\(attachment.isImage)"
                    + " onDisk=\(attachment.localURL != nil)"
            }
            log("[daemon] attachments: \(described.joined(separator: ", "))")
        }

        return message.imageURLs.compactMap { url in
            do {
                let encoded = try VisionAttachment.encoded(contentsOf: url)
                log("[daemon] image ready: \(url.lastPathComponent), \(encoded.count) bytes")
                return encoded
            } catch {
                log("[daemon] could not read image \(url.lastPathComponent): \(error)")
                return nil
            }
        }
    }

    private func toolCatalogue() async throws -> [MCPTool] {
        if let cachedTools {
            return cachedTools
        }
        let tools = try await loop.availableTools()
        cachedTools = tools
        return tools
    }

    private func reply(
        _ text: String,
        to recipient: SignalRecipient,
        attaching attachments: [URL] = []
    ) async {
        // On the way out only. The model writes bare domains — "check their
        // website mamaison.com.my" — and Signal linkifies nothing without a
        // scheme, so the owner gets a phone screen of addresses to retype.
        // Applied here rather than to history: the model keeps seeing what it
        // actually said, and nothing about this can reach routing.
        let linked = Linkify.promotingBareDomains(in: text)
        let body = configuration.replyPrefix.isEmpty ? linked : configuration.replyPrefix + linked
        do {
            _ = try await signal.send(
                text: body,
                attachmentPaths: attachments.map(\.path),
                to: recipient
            )
        } catch {
            // The words matter more than the file. signal-cli rejects the whole
            // send if it cannot read one attachment, so a note with a name it
            // dislikes would otherwise swallow the answer as well — retry
            // without the files rather than leave the owner with silence.
            guard !attachments.isEmpty else {
                // Nowhere left to report to — the reply channel is what failed.
                log("[daemon] could not send reply to \(recipient): \(error)")
                return
            }
            log("[daemon] send with \(attachments.count) attachment(s) failed (\(error)); retrying as text")
            await reply(text, to: recipient)
        }
    }

    /// Reduces a finished turn to what the *next* turn should remember: the
    /// owner's words and the answer they were given. Nothing else.
    ///
    /// Persisting the tool calls and their results was a real bug, not just
    /// waste. Observed on the appliance: turn 2 called `sage_federation` and
    /// answered; turns 3, 4 and 5 then called **no tools at all** and recycled
    /// that answer, including for "Can you save a memory?" which should have
    /// written one. With last turn's tool output sitting in context, a 4B model
    /// concludes it already has the facts and answers from them — so the
    /// appliance goes stale the moment anything changes on the SAGE node, which
    /// for an agent manager is the whole job.
    ///
    /// It also drops the system turn (`ToolLoop` prepends its own) and every
    /// assistant turn that carried only tool calls and no speakable text, since
    /// replaying those without their results is incoherent.
    /// The one exception is URLs. See `SourceLinks`: dropping tool results also
    /// dropped every link `web_search` found, so "can you give me links for
    /// these please" could not be answered from context and forced a second
    /// search across a conversation that by then held two subjects. The links
    /// are kept, attached to the answer that used them; the facts are not.
    static func conversationOnly(_ messages: [BrainMessage]) -> [BrainMessage] {
        var carried: [BrainMessage] = []
        // Links seen since the last answer, so they land on the turn that used
        // them rather than on whatever comes next.
        var pendingLinks: [String] = []

        for message in messages {
            switch message.role {
            case .system:
                continue
            case .tool:
                for url in SourceLinks.extract(from: message.content)
                where !pendingLinks.contains(url) {
                    pendingLinks.append(url)
                }
            case .user:
                carried.append(message)
            case .assistant:
                guard !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continue
                }
                // Strip the tool-call metadata; keep the sentence.
                let spoken = ToolLoop.speakable(message.content)
                let links = Array(pendingLinks.prefix(SourceLinks.maximumPerTurn))
                pendingLinks = []
                carried.append(
                    BrainMessage(role: .assistant, content: SourceLinks.annotated(spoken, links: links))
                )
            }
        }
        return carried
    }

    /// Keeps the last `turns` user/assistant exchanges.
    ///
    /// Trimming from the front rather than summarising because a 4B model's
    /// context is small and prefill is the dominant cost per turn; an old
    /// exchange is not worth 15 seconds of re-prefill.
    static func trimmed(_ messages: [BrainMessage], keepingLastTurns turns: Int) -> [BrainMessage] {
        guard turns > 0 else { return [] }
        var userIndices: [Int] = []
        for (index, message) in messages.enumerated() where message.role == .user {
            userIndices.append(index)
        }
        guard userIndices.count > turns else { return messages }
        let cut = userIndices[userIndices.count - turns]
        return Array(messages[cut...])
    }
}

private extension VoiceBridgeDaemon.Outcome {
    var logDescription: String {
        switch self {
        case let .replied(transcript, _, seconds):
            return String(format: "replied in %.1fs to %@", seconds, transcript.prefix(60).description)
        case .ignoredEmpty:
            return "ignored (no text, no audio)"
        case .ignoredBlankTranscript:
            return "ignored (transcribed to nothing)"
        case .failed(let reason):
            return "FAILED \(reason)"
        }
    }
}
