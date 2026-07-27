import Foundation

// MARK: - Trace

/// One tool invocation, as it actually happened.
public struct ToolCallRecord: Sendable, Equatable {
    public var iteration: Int
    public var name: String
    public var arguments: [String: JSONValue]
    /// Text the MCP server returned, or the failure description.
    public var result: String
    public var failed: Bool
    public var durationSeconds: TimeInterval

    public init(
        iteration: Int,
        name: String,
        arguments: [String: JSONValue],
        result: String,
        failed: Bool,
        durationSeconds: TimeInterval
    ) {
        self.iteration = iteration
        self.name = name
        self.arguments = arguments
        self.result = result
        self.failed = failed
        self.durationSeconds = durationSeconds
    }

    public var argumentsJSON: String { JSONValue.object(arguments).jsonString() }

    public var summary: String {
        // The failure text, not just the word ERROR. A tool that failed in
        // 0.02s is a rejection with a reason attached — logging only that it
        // failed throws away the one thing needed to fix it.
        let outcome = failed
            ? "ERROR \(result.prefix(200).replacingOccurrences(of: "\n", with: " "))"
            : "ok"
        return String(
            format: "%@(%@) -> %@ in %.2fs",
            name,
            argumentsJSON,
            outcome,
            durationSeconds
        )
    }
}

/// One round trip to the model.
public struct ModelCallRecord: Sendable, Equatable {
    public var iteration: Int
    public var promptEvalCount: Int?
    public var evalCount: Int?
    public var durationSeconds: TimeInterval
    public var requestedTools: [String]
    /// Reasoning the model emitted, if any. Never spoken.
    public var thinking: String?
    /// True when generation stopped at the `num_predict` cap.
    public var truncated: Bool

    public init(
        iteration: Int,
        promptEvalCount: Int?,
        evalCount: Int?,
        durationSeconds: TimeInterval,
        requestedTools: [String],
        thinking: String? = nil,
        truncated: Bool = false
    ) {
        self.iteration = iteration
        self.promptEvalCount = promptEvalCount
        self.evalCount = evalCount
        self.durationSeconds = durationSeconds
        self.requestedTools = requestedTools
        self.thinking = thinking
        self.truncated = truncated
    }
}

/// Everything the loop did, for logging and for latency reporting.
public struct ToolLoopTrace: Sendable, Equatable {
    public var model: String
    public var iterations: Int
    public var modelCalls: [ModelCallRecord]
    public var toolCalls: [ToolCallRecord]
    public var toolsOffered: Int
    public var hitIterationCap: Bool
    /// The turn ran out of wall clock and was sent to the wrap-up early.
    ///
    /// Separate from `hitIterationCap` because they mean opposite things about
    /// what to change. A capped turn is a model that would not stop calling
    /// tools; a timed-out turn is a model that was working fine and too slowly.
    /// Collapsing both into `[CAPPED]` is how the log stops being able to tell
    /// you which knob to turn.
    public var hitDeadline: Bool
    public var totalDurationSeconds: TimeInterval

    public init(
        model: String,
        iterations: Int = 0,
        modelCalls: [ModelCallRecord] = [],
        toolCalls: [ToolCallRecord] = [],
        toolsOffered: Int = 0,
        hitIterationCap: Bool = false,
        hitDeadline: Bool = false,
        totalDurationSeconds: TimeInterval = 0
    ) {
        self.model = model
        self.iterations = iterations
        self.modelCalls = modelCalls
        self.toolCalls = toolCalls
        self.toolsOffered = toolsOffered
        self.hitIterationCap = hitIterationCap
        self.hitDeadline = hitDeadline
        self.totalDurationSeconds = totalDurationSeconds
    }

    public var toolNames: [String] { toolCalls.map(\.name) }

    public var modelSeconds: TimeInterval { modelCalls.reduce(0) { $0 + $1.durationSeconds } }

    public var toolSeconds: TimeInterval { toolCalls.reduce(0) { $0 + $1.durationSeconds } }

    public var generatedTokens: Int { modelCalls.reduce(0) { $0 + ($1.evalCount ?? 0) } }

    /// One-line log summary, e.g.
    /// `qwen3.5:4b 2 iters, tools: sage_find_agent,sage_pipe, 8.31s (model 6.02s / tools 2.29s), 71 tok`
    public var summary: String {
        let tools = toolNames.isEmpty ? "none" : toolNames.joined(separator: ",")
        return String(
            format: "%@ %d iters, tools: %@, %.2fs (model %.2fs / tools %.2fs), %d tok%@",
            model,
            iterations,
            tools,
            totalDurationSeconds,
            modelSeconds,
            toolSeconds,
            generatedTokens,
            stopNote
        )
    }

    /// At most one note, deadline first: when a turn runs out of time on its
    /// last allowed iteration both flags are true, and the useful fact is that
    /// the clock is what ended it.
    private var stopNote: String {
        if hitDeadline { return " [TIMEOUT]" }
        if hitIterationCap { return " [CAPPED]" }
        return ""
    }
}

/// The loop's answer: what to speak, plus how it got there.
public struct ToolLoopResult: Sendable, Equatable {
    /// Text to hand to TTS.
    public var reply: String
    public var trace: ToolLoopTrace
    /// The full message history, so a caller can continue the conversation.
    /// Pass `messages.dropFirst()` back in as `history` on the next turn.
    public var messages: [BrainMessage]

    public init(reply: String, trace: ToolLoopTrace, messages: [BrainMessage]) {
        self.reply = reply
        self.trace = trace
        self.messages = messages
    }
}

public enum ToolLoopError: Error, CustomStringConvertible, Equatable {
    case noTools
    case emptyReply
    /// The curated tool allowlist matched none of the tools the server publishes.
    /// Deliberately fatal rather than silently falling back to the full
    /// catalogue — see `ToolLoop.availableTools()`.
    case toolAllowlistMatchedNothing(expected: [String], published: [String])

    public var description: String {
        switch self {
        case .noTools:
            return "The MCP server advertised no tools, so the brain has nothing to drive."
        case .emptyReply:
            return "The model produced no speakable reply."
        case .toolAllowlistMatchedNothing(let expected, let published):
            return """
            None of the \(expected.count) allowlisted tools are published by this MCP server. \
            Refusing to fall back to the full catalogue, because routing accuracy roughly halves \
            on the full set and it contains irreversible operations. \
            Expected any of: \(expected.joined(separator: ", ")). \
            Server publishes: \(published.joined(separator: ", ")).
            """
        }
    }
}

// MARK: - Tool source

/// Where the loop gets its tools, and where it runs them.
///
/// The counterpart to `BrainBackend` on the other side of the loop. `MCPClient`
/// is the only implementation that ships, but welding the loop to a concrete
/// process-spawning class made it impossible to test without a live SAGE
/// install — which is why it had no tests at all.
public protocol ToolProviding: Sendable {
    /// The catalogue this source publishes.
    func listTools() async throws -> [MCPTool]

    /// Runs a tool and returns its text output.
    func call(name: String, arguments: [String: JSONValue]) async throws -> String
}

extension MCPClient: ToolProviding {
    /// The protocol requirement takes no arguments; a defaulted parameter does
    /// not satisfy it, so forward explicitly.
    public func listTools() async throws -> [MCPTool] {
        try await listTools(useCache: true)
    }
}

// MARK: - Loop

/// The agent loop: transcript in, spoken reply out, MCP tools in the middle.
///
/// Tool schemas come from the MCP server's `tools/list` and are handed to the
/// model untouched. Nothing about SAGE's tool set is baked in here, so the loop
/// keeps working when the server grows a 28th tool.
public final class ToolLoop: @unchecked Sendable {
    /// The backstop, not the brake. `defaultDeadlineSeconds` is the brake.
    ///
    /// This was 5, sized for the deepest chain the product had when it was a
    /// dispatcher: `sage_find_agent` then `sage_pipe`, plus slack. That is the
    /// wrong workload now. Answering "the shops we talked about" is recall,
    /// recall again in different words, search what memory missed, then write —
    /// five before anything goes wrong, and three real turns were observed
    /// hitting the cap, including the one that produced a thin document from a
    /// single `sage_recall` followed by three consolation web searches.
    ///
    /// Ten is high enough that the cap stops being the thing that ends a normal
    /// turn. Time ends it instead, which is the honest unit: the owner is
    /// waiting on seconds, not on iterations.
    public static let defaultMaxIterations = 10

    /// Wall clock for the whole turn, tools included.
    ///
    /// Until now the iteration count was the only brake in the loop —
    /// `totalDurationSeconds` was measured and never enforced — so the real
    /// ceiling was "10 iterations times however long each happens to take",
    /// which on a capped turn was already 101 s at five.
    ///
    /// 90 s is the owner's number and the reasoning behind it is right: two
    /// exchanges of 45 beat one wait of 200, because a partial answer they can
    /// push on ("keep digging") is worth more than a complete one that arrives
    /// after they have put the phone down. That only holds if the wrap-up says
    /// what it was still doing — see `BrainPrompts.forcedSummary`.
    public static let defaultDeadlineSeconds: TimeInterval = 90

    /// Floor for what the wrap-up is assumed to cost, and the estimate used
    /// before this turn has measured anything.
    ///
    /// It is a floor rather than a subtraction. Subtracting a constant was the
    /// first attempt and it failed on the appliance by a factor of two: 12 s
    /// came from a 3.7 s measurement against a thin context, while a real
    /// deadline turn wraps up over every tool result the turn produced, on a
    /// model whose calls cost 40–60 s. The loop now estimates from the turn's
    /// own timings and only falls back here on the first iteration, where there
    /// is nothing measured yet.
    public static let summaryReserveSeconds: TimeInterval = 12

    public struct Configuration: Sendable {
        public var systemPrompt: String
        public var maxIterations: Int
        /// Wall clock for the turn, or `nil` to let iterations be the only
        /// brake. Enforced between iterations, never mid-call: cancelling a
        /// model call in flight throws away work already paid for and, on
        /// Ollama, leaves the prompt cache holding a prefix nothing will reuse.
        public var deadlineSeconds: TimeInterval?
        /// Withheld from `deadlineSeconds` for the wrap-up turn. Configurable
        /// because it is a property of the backend, not of the loop: a local 4B
        /// paying a full prefill over a turn's worth of tool results is not the
        /// same cost as an API call, and a reserve tuned for the slower one
        /// silently shortens every turn on the faster one.
        public var summaryReserveSeconds: TimeInterval
        public var temperature: Double?
        /// Reasoning on tool-selection turns. Leave `.automatic` — reasoning is
        /// what makes a small model route correctly. Measured on qwen3.5:4b
        /// with 14 tools: reasoning on → 12/12 correct; off → 3/10.
        public var reasoning: ReasoningPreference
        /// Reasoning on the final tools-withheld wrap-up turn. `.disabled` there
        /// is both faster (3.7 s vs 9.7 s measured) and immune to the reasoning
        /// runaway described on `maxGeneratedTokens`.
        public var reasoningOnSummary: ReasoningPreference
        /// Hard token cap per model turn. Guards against a reasoning runaway:
        /// with no tools attached and a thin context, qwen3.5:4b was measured
        /// generating 4069 tokens over 190 s and returning empty content.
        public var maxGeneratedTokens: Int?
        /// Tool results longer than this are truncated before going back to the
        /// model; a 4B model's context is not the place for a 40 KB memory dump.
        public var maxToolResultCharacters: Int
        /// Restrict the catalogue offered to the model to these names. Schemas
        /// still come from the server. Empty means "offer everything"; the
        /// default trades unreachable tools for a large accuracy win — see
        /// `BrainPrompts.voiceToolAllowlist`.
        public var allowedToolNames: Set<String>

        public init(
            systemPrompt: String = BrainPrompts.voiceAgentManager,
            maxIterations: Int = ToolLoop.defaultMaxIterations,
            deadlineSeconds: TimeInterval? = ToolLoop.defaultDeadlineSeconds,
            summaryReserveSeconds: TimeInterval = ToolLoop.summaryReserveSeconds,
            temperature: Double? = 0,
            reasoning: ReasoningPreference = .automatic,
            reasoningOnSummary: ReasoningPreference = .disabled,
            maxGeneratedTokens: Int? = 1024,
            maxToolResultCharacters: Int = 6000,
            allowedToolNames: Set<String> = BrainPrompts.voiceToolAllowlist
        ) {
            self.systemPrompt = systemPrompt
            self.maxIterations = maxIterations
            self.deadlineSeconds = deadlineSeconds
            self.summaryReserveSeconds = summaryReserveSeconds
            self.temperature = temperature
            self.reasoning = reasoning
            self.reasoningOnSummary = reasoningOnSummary
            self.maxGeneratedTokens = maxGeneratedTokens
            self.maxToolResultCharacters = maxToolResultCharacters
            self.allowedToolNames = allowedToolNames
        }
    }

    private let backend: BrainBackend
    private let mcp: ToolProviding
    private let configuration: Configuration

    /// Overrides `configuration.systemPrompt` once the session's SAGE context
    /// is known. Set at boot, before the warm-up, and not touched again — the
    /// lock is for publication rather than contention.
    private let promptLock = NSLock()
    private var systemPromptOverride: String?

    /// The prompt actually sent. Every path must use this, including `warmUp`:
    /// the warm-up's only value is that its prefix matches real requests byte
    /// for byte, and a warm-up on the base prompt while turns use the augmented
    /// one silently buys nothing.
    public var systemPrompt: String {
        promptLock.lock()
        defer { promptLock.unlock() }
        return systemPromptOverride ?? configuration.systemPrompt
    }

    /// Waits out a rate limit instead of failing the turn.
    ///
    /// A turn costs two to four model calls, and Gemini's free tier allows ten
    /// a minute — so a normal conversation runs out of allowance mid-turn,
    /// after tools have already run. Killing the turn there wastes the work and
    /// tells the owner their assistant is broken when it is merely busy.
    ///
    /// Only rate limits are retried. A rejected credential or a malformed
    /// request will fail identically every time, and retrying those would just
    /// make a permanent failure take three times as long to report.
    ///
    /// The provider's own `retryAfterSeconds` is preferred over a guess; the
    /// fallback doubles, because a fixed delay against a per-minute window
    /// tends to retry straight back into the same exhausted quota.
    static let rateLimitRetries = 2
    static let rateLimitFallbackDelaySeconds: TimeInterval = 6

    private func completeWithRateLimitRetry(_ request: BrainRequest) async throws -> BrainReply {
        var attempt = 0
        while true {
            do {
                return try await backend.complete(request)
            } catch let error as BrainBackendError {
                guard case .rateLimited(_, let retryAfter) = error, attempt < Self.rateLimitRetries else {
                    throw error
                }
                let delay = retryAfter ?? Self.rateLimitFallbackDelaySeconds * pow(2, Double(attempt))
                attempt += 1
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    /// Whether the model runs on this machine.
    ///
    /// Exposed because keeping a prompt cache warm is a purely local idea: it
    /// preserves an on-device KV cache. Against a hosted API the same timer
    /// buys nothing and spends real quota.
    public var backendIsLocal: Bool { backend.isLocal }

    public func setSystemPrompt(_ prompt: String) {
        promptLock.lock()
        defer { promptLock.unlock() }
        systemPromptOverride = prompt
    }

    /// The loop drives whatever `BrainBackend` it is handed. Which model — and
    /// whether it runs on this machine at all — is decided at setup and is not
    /// this type's business.
    public init(backend: BrainBackend, mcp: ToolProviding, configuration: Configuration = Configuration()) {
        self.backend = backend
        self.mcp = mcp
        self.configuration = configuration
    }

    /// The tools this loop will offer the model, straight from the MCP server —
    /// but sorted by name, which is not cosmetic.
    ///
    /// SAGE builds its `tools/list` reply by iterating a Go map, and Go
    /// deliberately randomises map iteration order. Its own test suite says so
    /// (`internal/mcp/http_transport_test.go:437`: "tools/list iterates a map
    /// and ordering is non-deterministic"). So the same 14 tools come back in a
    /// different order on every fetch.
    ///
    /// That order is load-bearing here, because the tool schemas are rendered
    /// into the *front* of the prompt, ahead of the owner's words. Reshuffle
    /// them and the prompt is a different byte string from position ~1 — so
    /// llama.cpp's prefix cache matches nothing and re-prefills the whole thing.
    /// Measured on the appliance, straight from `ollama.log`:
    ///
    ///     total=3021 matched=3012   →  prompt eval    0.4 s
    ///     total=3568 matched=1      →  prompt eval   16.4 s
    ///
    /// Three of eight requests in that sample were full misses. Sorting costs
    /// nothing and makes the prefix byte-identical every turn, which is also
    /// what `warmUp()` has been quietly assuming since the day it was written.
    public func availableTools() async throws -> [MCPTool] {
        let tools = try await mcp.listTools().sorted { $0.name < $1.name }
        guard !configuration.allowedToolNames.isEmpty else {
            return tools
        }
        let filtered = tools.filter { configuration.allowedToolNames.contains($0.name) }
        guard filtered.isEmpty else {
            return filtered
        }

        // The allowlist matched nothing — SAGE has renamed or re-prefixed its
        // tools, or we are pointed at a differently-branded build.
        //
        // Fail CLOSED. Silently widening to the whole catalogue is the worst
        // possible response: routing accuracy roughly halves at 27 tools
        // (measured 5-6/12 vs 12/12 on the curated set), so the model would be
        // at its least reliable exactly when its blast radius is widest — and
        // the widened set includes irreversible verbs like sage_forget,
        // sage_register and the governance tools, driven by an ASR transcript
        // that may contain mishearings.
        throw ToolLoopError.toolAllowlistMatchedNothing(
            expected: configuration.allowedToolNames.sorted(),
            published: tools.map(\.name).sorted()
        )
    }

    /// Puts the model and its prompt prefix in cache before anyone is waiting.
    ///
    /// Every turn re-sends the same system prompt and the same 14 tool schemas
    /// — about 2,833 tokens before the owner's words even start. Measured on
    /// the M2 appliance:
    ///
    ///     cold          prompt_eval 2833 tok / 13.95s
    ///     warm prefix   prompt_eval 2836 tok /  2.90s
    ///     warm again    prompt_eval 2835 tok /  2.74s
    ///
    /// A ~5x drop, and a turn makes at least two model calls, so this is worth
    /// roughly 22 seconds of the owner's waiting per request. The cost is paid
    /// once at boot, when nobody is listening.
    ///
    /// The throwaway turn must carry the *identical* system prompt and tool
    /// catalogue a real turn will, or the prefix does not match and nothing is
    /// reused. That is why this lives here rather than in the daemon: this type
    /// owns the prompt.
    ///
    /// Never throws. A failed warm-up costs latency, not correctness, and must
    /// not stop an appliance from booting.
    @discardableResult
    public func warmUp(tools: [MCPTool]? = nil) async -> Bool {
        do {
            let catalogue: [MCPTool]
            if let tools {
                catalogue = tools
            } else {
                catalogue = try await availableTools()
            }
            _ = try await backend.complete(
                BrainRequest(
                    messages: [
                        .system(systemPrompt),
                        .user(BrainPrompts.warmUpProbe)
                    ],
                    tools: catalogue.map(\.brainTool),
                    temperature: configuration.temperature,
                    // One token. We want the prefill, not the answer.
                    maxOutputTokens: 1,
                    reasoning: .disabled
                )
            )
            return true
        } catch {
            return false
        }
    }

    /// Plants a prompt-cache checkpoint where the *next* turn will diverge.
    ///
    /// Worth the whole comment, because the bug it fixes is invisible and the
    /// fix looks like wasted work.
    ///
    /// qwen3.5 is a hybrid attention/SSM architecture, and its recurrent state
    /// cannot be truncated to an arbitrary position — llama.cpp says so at load:
    /// "the context does not support partial sequence removal". So unlike a
    /// plain transformer, it cannot cut the KV cache at the longest common
    /// prefix. It can only rewind to a saved *checkpoint*, and checkpoints are
    /// pruned to a minimum spacing of 8,192 tokens — larger than this appliance's
    /// entire conversation, so in practice only two survive: one ancient, and one
    /// at the end of the last prompt.
    ///
    /// That end-of-prompt checkpoint always lands a few tokens *past* where the
    /// next turn diverges, which makes it invalid, which sends the runtime back
    /// to the ancient one. Measured, task 13434:
    ///
    ///     prompt 3,925 tokens, matched the cache to 3,915 — 10 new tokens
    ///     checkpoints at 3987, 3924, 1523; 3924 erased as invalidated
    ///     restored from 1524 → prompt eval 2,401 tokens / 11.4 s
    ///
    /// Ten new tokens cost eleven and a half seconds. Across 34 consecutive
    /// calls that was 30,620 tokens of recomputed, byte-identical cache.
    ///
    /// The cure is not to change the prompt — it is already a 99.7% match. It is
    /// to make a checkpoint exist in the right place. Sending the next turn's
    /// prompt *minus the owner's next sentence* plants one exactly at the
    /// divergence, so the next real turn restores there and prefills only what is
    /// genuinely new. Measured on a synthetic harness: 10.76 s → 0.33 s.
    ///
    /// This is `warmUp()` generalised from boot to every turn, and it costs the
    /// owner nothing because it runs after their reply has already been sent.
    ///
    /// Never throws. A failed anchor costs latency, not correctness.
    @discardableResult
    public func anchorPromptCache(history: [BrainMessage], tools: [MCPTool]? = nil) async -> Bool {
        guard !history.isEmpty else { return false }
        do {
            let catalogue: [MCPTool]
            if let tools {
                catalogue = tools
            } else {
                catalogue = try await availableTools()
            }
            // The catalogue and system prompt must match a real turn byte for
            // byte, or the anchor plants its checkpoint on a sequence the next
            // turn never asks for. Same discipline as `warmUp()`.
            var messages: [BrainMessage] = [.system(systemPrompt)]
            messages.append(contentsOf: history.filter { $0.role != .system })
            _ = try await backend.complete(
                BrainRequest(
                    messages: messages,
                    tools: catalogue.map(\.brainTool),
                    temperature: configuration.temperature,
                    // One token. We want the checkpoint, not the answer.
                    maxOutputTokens: 1,
                    reasoning: .disabled
                )
            )
            return true
        } catch {
            return false
        }
    }

    /// Runs one voice turn.
    ///
    /// - Parameters:
    ///   - transcript: what the owner said, as ASR produced it.
    ///   - tools: pre-fetched catalogue. Omit to fetch (and cache) from MCP.
    ///     Passing it in is worth it per-utterance: it skips a `tools/list`.
    ///   - history: prior turns, to continue a conversation. The system prompt
    ///     is prepended automatically and must not be included here.
    ///   - images: photos attached to this turn, already downscaled and encoded
    ///     by `VisionAttachment`. Ignored by models without vision.
    ///   - onToolDecision: called once, the moment the model has chosen its
    ///     first tools and before any of them run. The appliance uses this to
    ///     say something true while the owner waits — see `WorkingReply`.
    public func run(
        transcript: String,
        tools: [MCPTool]? = nil,
        history: [BrainMessage] = [],
        images: [Data] = [],
        onToolDecision: (@Sendable ([String]) async -> Void)? = nil
    ) async throws -> ToolLoopResult {
        let started = Date()
        let catalogue: [MCPTool]
        if let tools {
            catalogue = tools
        } else {
            catalogue = try await availableTools()
        }
        guard !catalogue.isEmpty else {
            throw ToolLoopError.noTools
        }
        let brainTools = catalogue.map(\.brainTool)
        let knownToolNames = Set(catalogue.map(\.name))

        var messages: [BrainMessage] = [.system(systemPrompt)]
        messages.append(contentsOf: history.filter { $0.role != .system })
        messages.append(.user(transcript, images: images))

        var trace = ToolLoopTrace(model: backend.modelName, toolsOffered: catalogue.count)
        var reply = ""
        let cap = max(1, configuration.maxIterations)

        for iteration in 1...cap {
            // Checked before the call, not after, and never on the first pass:
            // a turn that spends its whole budget in tools still owes the owner
            // one model call, and a turn with no model call at all has nothing
            // for the wrap-up to summarise.
            // Stop when the work still owed would not fit, not when the budget
            // is already gone.
            //
            // The first version compared elapsed against a fixed budget, and on
            // the appliance a 90 s promise delivered at 175 s. Nothing was wrong
            // with the check; the estimate behind it was. A model call here
            // costs 40–60 s, so passing the line at 78 s still admitted one full
            // iteration *and* the wrap-up — two calls, ~85 s of work, none of it
            // visible to a comparison that only knows how long it has been.
            //
            // So the loop predicts instead, from this turn's own measurements:
            // one more tool-calling iteration, plus the wrap-up it already owes.
            // A fast backend measures itself fast and keeps its iterations; a
            // slow one stops early, which is the honest outcome rather than a
            // budget that quietly means nothing.
            if iteration > 1, let deadline = configuration.deadlineSeconds {
                let elapsed = Date().timeIntervalSince(started)
                // Worst observed, not mean: a promise is kept against the bad
                // case, and one 60 s call among three 40 s ones is exactly the
                // case that broke the fixed budget.
                let expectedCall = trace.modelCalls.map(\.durationSeconds).max()
                    ?? configuration.summaryReserveSeconds
                // The wrap-up runs with reasoning withheld — measured at roughly
                // half a reasoning turn (3.7 s vs 9.7 s) — but never assumed
                // cheaper than the configured floor.
                let wrapUp = max(configuration.summaryReserveSeconds, expectedCall * 0.5)
                if elapsed + expectedCall + wrapUp > deadline {
                    trace.hitDeadline = true
                    break
                }
            }

            trace.iterations = iteration

            let response = try await completeWithRateLimitRetry(
                BrainRequest(
                    messages: messages,
                    tools: brainTools,
                    temperature: configuration.temperature,
                    maxOutputTokens: configuration.maxGeneratedTokens,
                    reasoning: configuration.reasoning
                )
            )
            trace.modelCalls.append(
                ModelCallRecord(
                    iteration: iteration,
                    promptEvalCount: response.usage.inputTokens,
                    evalCount: response.usage.outputTokens,
                    durationSeconds: response.wallClockSeconds,
                    requestedTools: response.toolCalls.map(\.name),
                    thinking: response.message.thinking,
                    truncated: response.wasTruncated
                )
            )
            messages.append(response.message)

            guard !response.toolCalls.isEmpty else {
                reply = Self.speakable(response.message.content)
                Self.warnIfSpeakableAteTheAnswer(raw: response.message.content, spoken: reply)
                break
            }

            // Only on the first decision, and only once the model has actually
            // committed to a tool. Announcing before this point would mean
            // guessing, and a turn that says "looking that up" and then answers
            // from memory is exactly the fake-sounding filler this replaced.
            if iteration == 1, let onToolDecision {
                await onToolDecision(response.toolCalls.map(\.name))
            }

            for call in response.toolCalls {
                let record = await execute(call, iteration: iteration, knownToolNames: knownToolNames)
                trace.toolCalls.append(record)
                messages.append(
                    .toolResult(
                        name: call.name,
                        content: Self.truncate(record.result, to: configuration.maxToolResultCharacters),
                        // Carried so backends that match results to requests by
                        // id (Anthropic, OpenAI) can pair them up. Ollama
                        // matches by name and ignores it.
                        id: call.id
                    )
                )
            }

            if iteration == cap {
                trace.hitIterationCap = true
            }
        }

        // Either the model burned every iteration on tools, or it answered with
        // nothing but reasoning. Force one more turn with no tools attached so
        // it has to produce something speakable.
        if reply.isEmpty {
            trace.hitIterationCap = trace.hitIterationCap || trace.iterations >= cap
            // Build the wrap-up request in a LOCAL copy. This control message is
            // an instruction to stop calling tools; persisting it into the
            // history we hand back would leave a standing "stop calling tools"
            // user turn in the conversation, so the next thing the owner asks
            // gets answered from nothing instead of hitting SAGE.
            let summaryMessages = messages + [.user(BrainPrompts.forcedSummary)]
            let response = try await completeWithRateLimitRetry(
                BrainRequest(
                    messages: summaryMessages,
                    tools: [],
                    temperature: configuration.temperature,
                    maxOutputTokens: configuration.maxGeneratedTokens,
                    reasoning: configuration.reasoningOnSummary
                )
            )
            trace.modelCalls.append(
                ModelCallRecord(
                    iteration: trace.iterations + 1,
                    promptEvalCount: response.usage.inputTokens,
                    evalCount: response.usage.outputTokens,
                    durationSeconds: response.wallClockSeconds,
                    requestedTools: [],
                    thinking: response.message.thinking,
                    truncated: response.wasTruncated
                )
            )
            messages.append(response.message)
            reply = Self.speakable(response.message.content)
        }

        trace.totalDurationSeconds = Date().timeIntervalSince(started)

        guard !reply.isEmpty else {
            throw ToolLoopError.emptyReply
        }
        return ToolLoopResult(reply: reply, trace: trace, messages: messages)
    }

    // MARK: Tool execution

    private func execute(
        _ call: BrainToolCall,
        iteration: Int,
        knownToolNames: Set<String>
    ) async -> ToolCallRecord {
        let started = Date()

        // A hallucinated tool name is fed back as an error rather than thrown:
        // the model usually recovers on the next iteration if you tell it what
        // it actually has.
        guard knownToolNames.contains(call.name) else {
            return ToolCallRecord(
                iteration: iteration,
                name: call.name,
                arguments: call.arguments,
                result: "Error: no tool named '\(call.name)' exists. Use one of the tools you were given, or answer without a tool.",
                failed: true,
                durationSeconds: Date().timeIntervalSince(started)
            )
        }

        do {
            let output = try await mcp.call(name: call.name, arguments: call.arguments)
            return ToolCallRecord(
                iteration: iteration,
                name: call.name,
                arguments: call.arguments,
                result: output.isEmpty ? "(the tool returned no content)" : output,
                failed: false,
                durationSeconds: Date().timeIntervalSince(started)
            )
        } catch {
            return ToolCallRecord(
                iteration: iteration,
                name: call.name,
                arguments: call.arguments,
                result: "Error: \(error)",
                failed: true,
                durationSeconds: Date().timeIntervalSince(started)
            )
        }
    }

    // MARK: Text hygiene

    /// Strips reasoning blocks and markdown scaffolding that TTS would read out
    /// as literal punctuation.
    /// Also useful directly from the TTS layer.
    /// Shouts when the sanitiser removed most of the model's answer.
    ///
    /// This bug is invisible from the outside: the loop reports a healthy turn
    /// with 151 tokens generated and the owner receives four words. Everything
    /// upstream — token counts, timings, tool traces — looks correct, because
    /// the damage happens after all of it. Set `SAGE_VOICE_DEBUG_RAW=1` to dump
    /// the raw content and see exactly which rule ate it.
    static func warnIfSpeakableAteTheAnswer(raw: String, spoken: String) {
        let dumpRaw = ProcessInfo.processInfo.environment["SAGE_VOICE_DEBUG_RAW"] == "1"
        guard raw.count > 80, spoken.count * 2 < raw.count else {
            if dumpRaw { FileHandle.standardError.write(Data("[raw] \(raw)\n".utf8)) }
            return
        }
        var message = "[warn] sanitiser cut the reply from \(raw.count) to \(spoken.count) characters"
        if dumpRaw {
            message += "\n[raw] \(raw)"
        }
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    /// Turns `[label](url)` into a bare, tappable URL.
    ///
    /// Signal renders plain text and linkifies bare URLs itself — it does not
    /// parse markdown. So a model that helpfully writes
    /// `[Google Maps](https://…)` produces a link the owner cannot tap, on a
    /// phone, which is the one place a maps link is worth anything. The system
    /// prompt already says "no markdown"; this is the belt to that braces,
    /// because the model does it anyway when it is being helpful.
    ///
    /// Also percent-encodes the URL. The same reply carried
    /// `?query=日枝あかさか+山王茶寮` with the Japanese raw, and a URL with
    /// non-ASCII bytes in it is not a URL — Signal's linkifier stops at the
    /// first one, so even the flattened link would have been truncated
    /// mid-address. Encoding happens per-character so an already-encoded URL is
    /// left alone rather than double-encoded into nonsense.
    static func flattenedLinks(_ text: String) -> String {
        let pattern = "\\[([^\\]\\n]*)\\]\\((https?://[^)\\s]+)\\)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }

        var result = text
        // Back to front, so each replacement cannot shift the ranges of the ones
        // still to be made.
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let whole = Range(match.range, in: result),
                  let urlRange = Range(match.range(at: 2), in: result) else { continue }
            result.replaceSubrange(whole, with: encodedURL(String(result[urlRange])))
        }
        return encodedBareURLs(result)
    }

    /// Percent-encodes anything in a URL that cannot travel as itself.
    private static func encodedURL(_ url: String) -> String {
        // Everything legal in a URL, plus `%` so an already-encoded triplet
        // survives untouched.
        let safe = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
            + "-._~:/?#[]@!$&'()*+,;=%"
        )
        return url.unicodeScalars.map { scalar in
            if safe.contains(scalar) { return String(scalar) }
            return String(scalar).utf8.map { String(format: "%%%02X", $0) }.joined()
        }.joined()
    }

    /// The same treatment for a URL the model wrote without markdown around it.
    private static func encodedBareURLs(_ text: String) -> String {
        let pattern = "https?://[^\\s<>\"']+"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: encodedURL(String(result[range])))
        }
        return result
    }

    public static func speakable(_ content: String) -> String {
        var text = stripThinkTags(content)
        text = text.replacingOccurrences(
            of: "```[\\s\\S]*?```",
            with: " ",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "^\\s*[*\\-\\u{2022}]\\s+",
            with: "",
            options: [.regularExpression]
        )
        text = text.replacingOccurrences(
            of: "\\n\\s*[*\\-\\u{2022}]\\s+",
            with: "\n",
            options: [.regularExpression]
        )
        text = Self.flattenedLinks(text)
        text = text.replacingOccurrences(of: "**", with: "")
        text = text.replacingOccurrences(of: "__", with: "")
        text = text.replacingOccurrences(of: "`", with: "")
        text = text.replacingOccurrences(
            of: "[ \\t]+",
            with: " ",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "\\n{2,}",
            with: "\n",
            options: .regularExpression
        )
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes `<think>...</think>` blocks, including an unterminated trailing
    /// one (which is what a truncated reasoning stream looks like).
    public static func stripThinkTags(_ content: String) -> String {
        var text = content.replacingOccurrences(
            of: "<(think|thinking|reasoning)>[\\s\\S]*?</\\1>",
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(
            of: "<(think|thinking|reasoning)>[\\s\\S]*$",
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(
            of: "</(think|thinking|reasoning)>",
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )
        return text
    }

    public static func truncate(_ text: String, to limit: Int) -> String {
        guard limit > 0, text.count > limit else {
            return text
        }
        let head = text.prefix(limit)
        return "\(head)\n… (truncated, \(text.count - limit) more characters)"
    }
}
