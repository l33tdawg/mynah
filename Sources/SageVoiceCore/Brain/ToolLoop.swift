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
        String(
            format: "%@(%@) -> %@ in %.2fs",
            name,
            argumentsJSON,
            failed ? "ERROR" : "ok",
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
    public var totalDurationSeconds: TimeInterval

    public init(
        model: String,
        iterations: Int = 0,
        modelCalls: [ModelCallRecord] = [],
        toolCalls: [ToolCallRecord] = [],
        toolsOffered: Int = 0,
        hitIterationCap: Bool = false,
        totalDurationSeconds: TimeInterval = 0
    ) {
        self.model = model
        self.iterations = iterations
        self.modelCalls = modelCalls
        self.toolCalls = toolCalls
        self.toolsOffered = toolsOffered
        self.hitIterationCap = hitIterationCap
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
            hitIterationCap ? " [CAPPED]" : ""
        )
    }
}

/// The loop's answer: what to speak, plus how it got there.
public struct ToolLoopResult: Sendable, Equatable {
    /// Text to hand to TTS.
    public var reply: String
    public var trace: ToolLoopTrace
    /// The full message history, so a caller can continue the conversation.
    /// Pass `messages.dropFirst()` back in as `history` on the next turn.
    public var messages: [OllamaMessage]

    public init(reply: String, trace: ToolLoopTrace, messages: [OllamaMessage]) {
        self.reply = reply
        self.trace = trace
        self.messages = messages
    }
}

public enum ToolLoopError: Error, CustomStringConvertible, Equatable {
    case noTools
    case emptyReply

    public var description: String {
        switch self {
        case .noTools:
            return "The MCP server advertised no tools, so the brain has nothing to drive."
        case .emptyReply:
            return "The model produced no speakable reply."
        }
    }
}

// MARK: - Loop

/// The agent loop: transcript in, spoken reply out, MCP tools in the middle.
///
/// Tool schemas come from the MCP server's `tools/list` and are handed to the
/// model untouched. Nothing about SAGE's tool set is baked in here, so the loop
/// keeps working when the server grows a 28th tool.
public final class ToolLoop: @unchecked Sendable {
    /// Five is enough for the deepest chain this product actually needs
    /// (`sage_find_agent` then `sage_pipe`, plus slack) and short enough that a
    /// confused model cannot spin the Mac mini's fans for a minute.
    public static let defaultMaxIterations = 5

    public struct Configuration: Sendable {
        public var model: String
        public var systemPrompt: String
        public var maxIterations: Int
        public var temperature: Double?
        /// Leave `nil` on tool-selection turns — reasoning is what makes a 4B
        /// model route correctly. Measured on qwen3.5:4b with 14 tools:
        /// `nil` → 12/12 correct; `false` → 3/10 correct.
        public var think: Bool?
        /// `think` for the final tools-withheld wrap-up turn. `false` there is
        /// both faster (3.7 s vs 9.7 s measured) and immune to the reasoning
        /// runaway described on `maxGeneratedTokens`.
        public var thinkOnSummary: Bool?
        /// Hold the model resident between voice notes.
        public var keepAlive: String?
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
            model: String = "qwen3.5:4b",
            systemPrompt: String = BrainPrompts.voiceAgentManager,
            maxIterations: Int = ToolLoop.defaultMaxIterations,
            temperature: Double? = 0,
            think: Bool? = nil,
            thinkOnSummary: Bool? = false,
            keepAlive: String? = "30m",
            maxGeneratedTokens: Int? = 1024,
            maxToolResultCharacters: Int = 6000,
            allowedToolNames: Set<String> = BrainPrompts.voiceToolAllowlist
        ) {
            self.model = model
            self.systemPrompt = systemPrompt
            self.maxIterations = maxIterations
            self.temperature = temperature
            self.think = think
            self.thinkOnSummary = thinkOnSummary
            self.keepAlive = keepAlive
            self.maxGeneratedTokens = maxGeneratedTokens
            self.maxToolResultCharacters = maxToolResultCharacters
            self.allowedToolNames = allowedToolNames
        }
    }

    private let ollama: OllamaClient
    private let mcp: MCPClient
    private let configuration: Configuration

    public init(ollama: OllamaClient, mcp: MCPClient, configuration: Configuration = Configuration()) {
        self.ollama = ollama
        self.mcp = mcp
        self.configuration = configuration
    }

    /// The tools this loop will offer the model, straight from the MCP server.
    ///
    /// If the allowlist matches nothing the server publishes — a different MCP
    /// server, or SAGE renaming its tools — the full catalogue is offered
    /// rather than failing, so the loop degrades instead of breaking.
    public func availableTools() async throws -> [MCPTool] {
        let tools = try await mcp.listTools()
        guard !configuration.allowedToolNames.isEmpty else {
            return tools
        }
        let filtered = tools.filter { configuration.allowedToolNames.contains($0.name) }
        return filtered.isEmpty ? tools : filtered
    }

    /// Runs one voice turn.
    ///
    /// - Parameters:
    ///   - transcript: what the owner said, as ASR produced it.
    ///   - tools: pre-fetched catalogue. Omit to fetch (and cache) from MCP.
    ///     Passing it in is worth it per-utterance: it skips a `tools/list`.
    ///   - history: prior turns, to continue a conversation. The system prompt
    ///     is prepended automatically and must not be included here.
    public func run(
        transcript: String,
        tools: [MCPTool]? = nil,
        history: [OllamaMessage] = []
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
        let ollamaTools = catalogue.map(\.ollamaTool)
        let knownToolNames = Set(catalogue.map(\.name))

        var messages: [OllamaMessage] = [.system(configuration.systemPrompt)]
        messages.append(contentsOf: history.filter { $0.role != .system })
        messages.append(.user(transcript))

        var trace = ToolLoopTrace(model: configuration.model, toolsOffered: catalogue.count)
        var reply = ""
        let cap = max(1, configuration.maxIterations)

        for iteration in 1...cap {
            trace.iterations = iteration

            let response = try await ollama.chat(
                model: configuration.model,
                messages: messages,
                tools: ollamaTools,
                temperature: configuration.temperature,
                think: configuration.think,
                keepAlive: configuration.keepAlive,
                numPredict: configuration.maxGeneratedTokens
            )
            trace.modelCalls.append(
                ModelCallRecord(
                    iteration: iteration,
                    promptEvalCount: response.promptEvalCount,
                    evalCount: response.evalCount,
                    durationSeconds: response.wallClockSeconds,
                    requestedTools: response.toolCalls.map(\.name),
                    thinking: response.message.thinking,
                    truncated: response.wasTruncated
                )
            )
            messages.append(response.message)

            guard !response.toolCalls.isEmpty else {
                reply = Self.speakable(response.message.content)
                break
            }

            for call in response.toolCalls {
                let record = await execute(call, iteration: iteration, knownToolNames: knownToolNames)
                trace.toolCalls.append(record)
                messages.append(
                    .toolResult(
                        name: call.name,
                        content: Self.truncate(record.result, to: configuration.maxToolResultCharacters)
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
            messages.append(.user(BrainPrompts.forcedSummary))
            let response = try await ollama.chat(
                model: configuration.model,
                messages: messages,
                tools: [],
                temperature: configuration.temperature,
                think: configuration.thinkOnSummary,
                keepAlive: configuration.keepAlive,
                numPredict: configuration.maxGeneratedTokens
            )
            trace.modelCalls.append(
                ModelCallRecord(
                    iteration: trace.iterations + 1,
                    promptEvalCount: response.promptEvalCount,
                    evalCount: response.evalCount,
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
        _ call: OllamaToolCall,
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
