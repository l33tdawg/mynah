import Foundation

// MARK: - Errors

public enum OllamaClientError: Error, CustomStringConvertible, Equatable {
    case invalidBaseURL(String)
    case requestFailed(String)
    case badResponse(Int, String)
    case malformedResponse(String)

    public var description: String {
        switch self {
        case .invalidBaseURL(let value):
            return "Ollama base URL is not usable: \(value)"
        case .requestFailed(let detail):
            return "Ollama request failed: \(detail)"
        case .badResponse(let status, let body):
            return "Ollama returned HTTP \(status): \(body)"
        case .malformedResponse(let detail):
            return "Ollama response could not be understood: \(detail)"
        }
    }

    /// Translate to the neutral vocabulary the daemon reacts to.
    public var asBrainBackendError: BrainBackendError {
        switch self {
        case .invalidBaseURL(let value):
            return .misconfigured("Ollama base URL is not usable: \(value)")
        case .requestFailed(let detail):
            return .unreachable(detail)
        case .badResponse(let status, let body):
            // Ollama has no auth, so a 404 here means the model was never
            // pulled — by far the most common failure on a fresh machine, and
            // worth a message that says so instead of "HTTP 404".
            if status == 404 {
                return .misconfigured("model not found on the Ollama daemon — pull it first (\(body))")
            }
            return .badResponse(status: status, body: body)
        case .malformedResponse(let detail):
            return .malformedResponse(detail)
        }
    }
}

// MARK: - Wire encoding

private extension BrainMessage {
    /// Ollama's `/api/chat` message shape.
    var ollamaWireObject: [String: Any] {
        var object: [String: Any] = [
            "role": role.rawValue,
            "content": content
        ]
        if let toolName, role == .tool {
            // Ollama 0.32+ matches results to requests by name. Older builds
            // ignore the key, so sending it is always safe.
            object["tool_name"] = toolName
        }
        if !toolCalls.isEmpty {
            object["tool_calls"] = toolCalls.map(\.ollamaWireObject)
        }
        return object
    }
}

private extension BrainToolCall {
    var ollamaWireObject: [String: Any] {
        var function: [String: Any] = [
            "name": name,
            "arguments": arguments.mapValues(\.foundationObject)
        ]
        if let id {
            function["id"] = id
        }
        var object: [String: Any] = ["function": function]
        if let id {
            object["id"] = id
        }
        return object
    }
}

private extension BrainTool {
    var ollamaWireObject: [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": parameters.foundationObject
            ]
        ]
    }
}

// MARK: - Response

/// One `/api/chat` reply, including the counters needed to report latency.
///
/// Kept as a distinct type from `BrainReply` because Ollama reports a richer
/// breakdown (prompt-eval vs eval nanoseconds) that is genuinely useful when
/// tuning a local model, and which no cloud provider exposes.
public struct OllamaChatResponse: Sendable, Equatable {
    public var model: String
    public var message: BrainMessage
    public var doneReason: String?
    public var promptEvalCount: Int?
    public var promptEvalDurationNanoseconds: Int?
    public var evalCount: Int?
    public var evalDurationNanoseconds: Int?
    public var totalDurationNanoseconds: Int?
    /// Wall-clock time this client measured around the HTTP call.
    public var wallClockSeconds: TimeInterval

    public init(
        model: String,
        message: BrainMessage,
        doneReason: String? = nil,
        promptEvalCount: Int? = nil,
        promptEvalDurationNanoseconds: Int? = nil,
        evalCount: Int? = nil,
        evalDurationNanoseconds: Int? = nil,
        totalDurationNanoseconds: Int? = nil,
        wallClockSeconds: TimeInterval = 0
    ) {
        self.model = model
        self.message = message
        self.doneReason = doneReason
        self.promptEvalCount = promptEvalCount
        self.promptEvalDurationNanoseconds = promptEvalDurationNanoseconds
        self.evalCount = evalCount
        self.evalDurationNanoseconds = evalDurationNanoseconds
        self.totalDurationNanoseconds = totalDurationNanoseconds
        self.wallClockSeconds = wallClockSeconds
    }

    public var toolCalls: [BrainToolCall] { message.toolCalls }

    /// Server-reported total, in seconds. Falls back to the measured wall clock.
    public var totalDurationSeconds: TimeInterval {
        guard let totalDurationNanoseconds else {
            return wallClockSeconds
        }
        return Double(totalDurationNanoseconds) / 1_000_000_000
    }

    /// Generated tokens per second, or `nil` when Ollama omitted the counters.
    public var tokensPerSecond: Double? {
        guard let evalCount, let evalDurationNanoseconds, evalDurationNanoseconds > 0 else {
            return nil
        }
        return Double(evalCount) / (Double(evalDurationNanoseconds) / 1_000_000_000)
    }

    /// True when generation stopped because it hit the `num_predict` cap.
    public var wasTruncated: Bool { doneReason == "length" }

    /// One-line summary for logs: `qwen3.5:4b 33 tok in 4.12s (8.0 tok/s)`.
    public var latencySummary: String {
        let tokens = evalCount.map(String.init) ?? "?"
        let rate = tokensPerSecond.map { String(format: " (%.1f tok/s)", $0) } ?? ""
        return String(format: "%@ %@ tok in %.2fs%@", model, tokens, totalDurationSeconds, rate)
    }

    /// Project onto the provider-neutral reply type.
    public var asBrainReply: BrainReply {
        let stopReason: BrainStopReason
        if !message.toolCalls.isEmpty {
            stopReason = .toolUse
        } else if wasTruncated {
            stopReason = .maxTokens
        } else if let doneReason, doneReason != "stop" {
            stopReason = .other(doneReason)
        } else {
            stopReason = .endTurn
        }
        return BrainReply(
            model: model,
            message: message,
            stopReason: stopReason,
            usage: BrainUsage(inputTokens: promptEvalCount, outputTokens: evalCount),
            wallClockSeconds: totalDurationSeconds
        )
    }
}

// MARK: - Client

/// Async client for Ollama's `/api/chat`, non-streaming.
///
/// Deliberately Foundation-only: one `URLSession`, one `JSONSerialization`
/// round trip, no code generation.
public final class OllamaClient: @unchecked Sendable {
    /// A 4B model on an M2 answers a routing turn in ~10s, but a cold model
    /// load or a long tool-result context can easily blow past 30s.
    public static let defaultTimeoutSeconds: TimeInterval = 180

    public static let defaultBaseURL = URL(string: "http://localhost:11434")!

    private let baseURL: URL
    private let session: URLSession
    private let timeoutSeconds: TimeInterval

    public init(
        baseURL: URL = OllamaClient.defaultBaseURL,
        timeoutSeconds: TimeInterval = OllamaClient.defaultTimeoutSeconds,
        session: URLSession? = nil
    ) {
        self.baseURL = baseURL
        self.timeoutSeconds = timeoutSeconds
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = timeoutSeconds
            configuration.timeoutIntervalForResource = timeoutSeconds
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
    }

    /// Absolute URL for an Ollama API path, preserving any prefix in `baseURL`.
    private func endpoint(_ path: String) -> URL {
        baseURL.appendingPathComponent(path)
    }

    /// True when the daemon answers `/api/version` promptly.
    public func isReachable(timeoutSeconds: TimeInterval = 2) async -> Bool {
        var request = URLRequest(url: endpoint("api/version"))
        request.timeoutInterval = timeoutSeconds
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else {
            return false
        }
        return (200..<300).contains(http.statusCode)
    }

    /// Model names currently pulled on the daemon.
    public func listModels() async throws -> [String] {
        try validateBaseURL()
        var request = URLRequest(url: endpoint("api/tags"))
        request.timeoutInterval = min(timeoutSeconds, 15)
        let data = try await send(request)
        guard let root = JSONValue.parse(data), let models = root["models"]?.arrayValue else {
            throw OllamaClientError.malformedResponse("no models array in /api/tags")
        }
        return models.compactMap { $0["name"]?.stringValue }
    }

    /// One non-streaming `/api/chat` round trip.
    ///
    /// - Parameters:
    ///   - think: leave `nil` for tool-selection turns. Ollama 0.32.4 does not
    ///     suppress reasoning for qwen3 when told `false` — it relocates it into
    ///     `content` and runs slower. qwen3.5 does honour it, and measurably
    ///     needs it on turns where no tools are attached (see `numPredict`).
    ///   - keepAlive: e.g. `"30m"` to hold the model resident between voice
    ///     notes and avoid paying the load cost on every utterance.
    ///   - numPredict: hard cap on generated tokens. Worth setting: with no
    ///     tools attached and a thin context, qwen3.5:4b has been observed to
    ///     loop inside its reasoning block for 4069 tokens / 190s and return
    ///     empty `content`.
    public func chat(
        model: String,
        messages: [BrainMessage],
        tools: [BrainTool] = [],
        temperature: Double? = 0,
        think: Bool? = nil,
        keepAlive: String? = nil,
        numPredict: Int? = nil,
        extraOptions: [String: JSONValue] = [:]
    ) async throws -> OllamaChatResponse {
        try validateBaseURL()

        var body: [String: Any] = [
            "model": model,
            "messages": messages.map(\.ollamaWireObject),
            "stream": false
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map(\.ollamaWireObject)
        }
        var options: [String: Any] = extraOptions.mapValues(\.foundationObject)
        if let temperature {
            options["temperature"] = temperature
        }
        if let numPredict {
            options["num_predict"] = numPredict
        }
        if !options.isEmpty {
            body["options"] = options
        }
        if let think {
            body["think"] = think
        }
        if let keepAlive {
            body["keep_alive"] = keepAlive
        }

        var request = URLRequest(url: endpoint("api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            // Byte-stable, or llama.cpp's prefix cache matches nothing and the
            // appliance re-prefills 3,572 tokens on every turn. See
            // `PromptStableJSON` for the measurement.
            request.httpBody = try PromptStableJSON.data(from: body)
        } catch {
            throw OllamaClientError.malformedResponse("could not encode request: \(error)")
        }

        let started = Date()
        let data = try await send(request)
        let elapsed = Date().timeIntervalSince(started)

        guard let root = JSONValue.parse(data) else {
            let preview = String(decoding: data.prefix(400), as: UTF8.self)
            throw OllamaClientError.malformedResponse("body was not JSON: \(preview)")
        }
        var response = try Self.parseChatResponse(root, fallbackModel: model)
        response.wallClockSeconds = elapsed
        return response
    }

    private func validateBaseURL() throws {
        guard let scheme = baseURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              baseURL.host != nil else {
            throw OllamaClientError.invalidBaseURL(baseURL.absoluteString)
        }
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorTimedOut {
                throw OllamaClientError.requestFailed(
                    "timed out after \(Int(timeoutSeconds.rounded()))s — the model may still be loading"
                )
            }
            throw OllamaClientError.requestFailed(String(describing: error))
        }
        guard let http = response as? HTTPURLResponse else {
            throw OllamaClientError.badResponse(-1, "non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OllamaClientError.badResponse(
                http.statusCode,
                String(decoding: data.prefix(600), as: UTF8.self)
            )
        }
        return data
    }

    // MARK: Parsing

    /// Exposed so callers can unit-test wire handling without a live daemon.
    public static func parseChatResponse(_ root: JSONValue, fallbackModel: String) throws -> OllamaChatResponse {
        if let apiError = root["error"]?.stringValue {
            throw OllamaClientError.requestFailed(apiError)
        }
        guard let messageObject = root["message"]?.objectValue else {
            throw OllamaClientError.malformedResponse("no message object in /api/chat reply")
        }

        let role = BrainRole(rawValue: messageObject["role"]?.stringValue ?? "assistant") ?? .assistant
        let thinking = messageObject["thinking"]?.stringValue
            ?? messageObject["reasoning"]?.stringValue
        let message = BrainMessage(
            role: role,
            content: messageObject["content"]?.stringValue ?? "",
            thinking: (thinking?.isEmpty == false) ? thinking : nil,
            toolCalls: parseToolCalls(messageObject["tool_calls"])
        )

        return OllamaChatResponse(
            model: root["model"]?.stringValue ?? fallbackModel,
            message: message,
            doneReason: root["done_reason"]?.stringValue,
            promptEvalCount: root["prompt_eval_count"]?.intValue,
            promptEvalDurationNanoseconds: root["prompt_eval_duration"]?.intValue,
            evalCount: root["eval_count"]?.intValue,
            evalDurationNanoseconds: root["eval_duration"]?.intValue,
            totalDurationNanoseconds: root["total_duration"]?.intValue
        )
    }

    /// Normalises the several shapes Ollama and its model templates emit.
    ///
    /// Observed in the wild:
    ///  - `[{"function": {"name": ..., "arguments": {...}}}]`  (documented)
    ///  - `[{"function": {"name": ..., "arguments": "{\"q\":1}"}}]` (arguments
    ///    double-encoded as a JSON string — common with OpenAI-shaped templates)
    ///  - `[{"name": ..., "arguments": {...}}]` (function wrapper omitted)
    public static func parseToolCalls(_ value: JSONValue?) -> [BrainToolCall] {
        guard let entries = value?.arrayValue else {
            return []
        }
        return entries.compactMap { entry -> BrainToolCall? in
            guard let object = entry.objectValue else {
                return nil
            }
            let function = object["function"]?.objectValue ?? object
            guard let name = function["name"]?.stringValue, !name.isEmpty else {
                return nil
            }
            let id = object["id"]?.stringValue ?? function["id"]?.stringValue
            return BrainToolCall(
                id: id,
                name: name,
                arguments: normalizeArguments(function["arguments"])
            )
        }
    }

    public static func normalizeArguments(_ value: JSONValue?) -> [String: JSONValue] {
        guard let value else {
            return [:]
        }
        if let object = value.objectValue {
            return object
        }
        if let text = value.stringValue {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return [:]
            }
            // Double-encoded arguments. One parse usually suffices; a second
            // pass covers templates that escape the payload twice.
            if let parsed = JSONValue.parse(trimmed) {
                if let object = parsed.objectValue {
                    return object
                }
                if let inner = parsed.stringValue,
                   let reparsed = JSONValue.parse(inner)?.objectValue {
                    return reparsed
                }
            }
        }
        return [:]
    }
}

// MARK: - BrainBackend adapter

/// `BrainBackend` over a local Ollama daemon.
///
/// Holds the Ollama-specific knobs that have no neutral equivalent — `think`,
/// `keep_alive` — so the rest of the system never has to know they exist.
public final class OllamaBackend: BrainBackend, @unchecked Sendable {
    public let identifier = "ollama"
    public let modelName: String
    /// Ollama runs on this machine; nothing leaves it.
    public let isLocal = true

    /// Context window to ask Ollama for, in tokens.
    ///
    /// Ollama does not use the model's own context length — it defaults
    /// `num_ctx` to 4096 regardless, and qwen3.5:4b advertises 262144. Under
    /// that default this appliance overflows, and it overflows *silently*: the
    /// prompt is kept and the generation is cut, so a turn reports success with
    /// a healthy token count and the owner gets half a sentence. Measured:
    ///
    ///   system prompt + 15 tool schemas   ~3,000 tokens
    ///   one web_search result             ~  400 tokens
    ///   conversation history              ~  300 tokens
    ///                                     ------------
    ///                                      ~3,700, leaving ~400 of 4096
    ///
    /// which is why the answers died mid-sentence at 150–250 tokens, and why
    /// this only became reproducible once search results entered the prompt —
    /// before that the appliance was living just inside the ceiling.
    ///
    /// 8192 doubled the headroom and still left the KV cache small enough for
    /// a 4B model on a 16 GB machine also running SAGE and WhisperKit.
    ///
    /// It is now 24576, and the reason has nothing to do with headroom: on this
    /// build of Ollama, `num_ctx` also sets the size of the *prompt cache*, and
    /// that is the appliance's dominant latency term. From `ollama.log`:
    ///
    ///     cache state: 6 prompts, 1909 MiB (limits: 8192 MiB, 8192 tokens, ...)
    ///
    /// The budget is a token count, and it equals `num_ctx`. The system prompt
    /// and 14 tool schemas are ~3,572 tokens *before the owner says anything*,
    /// so at 8192 the cache held two prefixes and six live conversations
    /// thrashed over them. A prefix that gets evicted is re-prefilled at about
    /// 219 tok/s — 16.3 seconds, measured, every time it happens.
    ///
    /// 65536 buys room for many prefixes and, just as importantly, for a long
    /// conversation: `historyTurnLimit` is 16 now that a cached prefix makes
    /// carrying history nearly free, and that history has to fit somewhere.
    ///
    /// The cost is KV cache, which is unusually cheap here because qwen3.5 is a
    /// hybrid-attention model with only 8 cached layers — 256 MiB at 8192, so
    /// ~2 GiB at 65536. Against a 3.5 GB model on a 16 GB machine that also runs
    /// SAGE and WhisperKit, that fits with room to spare.
    public static let defaultContextTokens = 65536

    private let client: OllamaClient
    private let keepAlive: String?
    /// Applied when the request asks for `.automatic`.
    private let defaultThink: Bool?
    private let contextTokens: Int?

    public init(
        client: OllamaClient = OllamaClient(),
        model: String = "qwen3.5:4b",
        keepAlive: String? = "30m",
        defaultThink: Bool? = nil,
        contextTokens: Int? = OllamaBackend.defaultContextTokens
    ) {
        self.client = client
        self.modelName = model
        self.keepAlive = keepAlive
        self.defaultThink = defaultThink
        self.contextTokens = contextTokens
    }

    public func isAvailable() async -> Bool {
        guard await client.isReachable() else {
            return false
        }
        // Reachable is not enough — a daemon without the model pulled fails at
        // the first real request, which on a voice turn means dead air.
        guard let models = try? await client.listModels() else {
            return false
        }
        return models.contains { $0 == modelName || $0 == "\(modelName):latest" }
    }

    public func complete(_ request: BrainRequest) async throws -> BrainReply {
        let think: Bool?
        switch request.reasoning {
        case .automatic: think = defaultThink
        case .enabled:   think = true
        case .disabled:  think = false
        }

        do {
            let response = try await client.chat(
                model: modelName,
                messages: request.messages,
                tools: request.tools,
                temperature: request.temperature,
                think: think,
                keepAlive: keepAlive,
                numPredict: request.maxOutputTokens,
                // Must be identical on every request including the warm-up, or
                // Ollama reloads the model with different runtime settings and
                // throws away the prompt cache the warm-up just paid for.
                extraOptions: contextTokens.map { ["num_ctx": .int($0)] } ?? [:]
            )
            return response.asBrainReply
        } catch let error as OllamaClientError {
            throw error.asBrainBackendError
        }
    }
}
