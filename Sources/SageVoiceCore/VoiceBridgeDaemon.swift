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
        /// Conversation turns kept for context. Each turn re-sends the whole
        /// history plus 14 tool schemas, and prefill measured ~130 tok/s on the
        /// M2 — so history is the most expensive knob here, not the cheapest.
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

        public init(
            genericFailureReply: String = "Something went wrong handling that. It's logged.",
            replyPrefix: String = VoiceBridgeDaemon.Configuration.defaultReplyPrefix,
            historyTurnLimit: Int = 6,
            maximumTranscriptCharacters: Int = 4000,
            sendsThinkingAcknowledgement: Bool = false
        ) {
            self.genericFailureReply = genericFailureReply
            self.replyPrefix = replyPrefix
            self.historyTurnLimit = historyTurnLimit
            self.maximumTranscriptCharacters = maximumTranscriptCharacters
            self.sendsThinkingAcknowledgement = sendsThinkingAcknowledgement
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

    public init(
        signal: SignalClient,
        transcriber: AudioFileTranscribing,
        loop: ToolLoop,
        configuration: Configuration = Configuration(),
        ritual: SageRitual? = nil,
        log: @escaping (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    ) {
        self.signal = signal
        self.transcriber = transcriber
        self.loop = loop
        self.configuration = configuration
        self.ritual = ritual
        self.log = log
    }

    /// Runs until the message stream finishes (i.e. until `signal.stop()`).
    public func run() async {
        await signal.start()

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

        for await message in signal.incomingMessages {
            // Sequential on purpose. Two voice notes answered concurrently would
            // interleave their tool calls against one SAGE node and race on the
            // thread history — and the model is the bottleneck anyway, so there
            // is no throughput to win.
            let outcome = await handle(message)
            log("[daemon] \(message.logDescription) -> \(outcome.logDescription)")
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
        let started = Date()

        guard let recipient = message.replyRecipient else {
            // Nothing to reply to. Dropping is correct: the alternative is
            // guessing a destination, and guessing wrong means the owner's
            // agent messages a stranger.
            return .failed("no reply recipient on \(message.logDescription)")
        }

        let transcript: String
        do {
            guard let raw = try await resolveTranscript(message) else {
                return .ignoredEmpty
            }
            transcript = raw
        } catch {
            await reply("I couldn't read that voice note.", to: recipient)
            return .failed("transcription failed: \(error)")
        }

        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .ignoredBlankTranscript
        }
        guard transcript.count <= configuration.maximumTranscriptCharacters else {
            await reply("That was too long for me to act on — try a shorter one.", to: recipient)
            return .failed("transcript of \(transcript.count) characters exceeds the limit")
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
                history: histories[key] ?? []
            )
            histories[key] = Self.trimmed(
                Self.conversationOnly(result.messages),
                keepingLastTurns: configuration.historyTurnLimit
            )
            await reply(result.reply, to: recipient)
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
        return nil
    }

    private func toolCatalogue() async throws -> [MCPTool] {
        if let cachedTools {
            return cachedTools
        }
        let tools = try await loop.availableTools()
        cachedTools = tools
        return tools
    }

    private func reply(_ text: String, to recipient: SignalRecipient) async {
        let body = configuration.replyPrefix.isEmpty ? text : configuration.replyPrefix + text
        do {
            _ = try await signal.sendText(body, to: recipient)
        } catch {
            // Nowhere left to report to — the reply channel is what failed.
            log("[daemon] could not send reply to \(recipient): \(error)")
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
    static func conversationOnly(_ messages: [BrainMessage]) -> [BrainMessage] {
        messages.compactMap { message in
            switch message.role {
            case .system, .tool:
                return nil
            case .user:
                return message
            case .assistant:
                guard !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                // Strip the tool-call metadata; keep the sentence.
                return BrainMessage(role: .assistant, content: ToolLoop.speakable(message.content))
            }
        }
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
