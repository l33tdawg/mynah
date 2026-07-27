import Foundation

/// One OpenAI-shaped provider's quirks.
///
/// The `/v1/chat/completions` shape is the closest thing the industry has to a
/// lingua franca, but nobody implements it identically. Rather than a backend
/// per vendor, the differences that actually matter are data.
public struct OpenAICompatProvider: Sendable, Equatable {
    /// Stable short name for logs: `"deepseek"`, `"groq"`.
    public var identifier: String
    /// Human-readable name for error messages shown to the owner.
    public var displayName: String
    /// Root the `chat/completions` path is appended to.
    public var baseURL: URL
    /// Newer OpenAI reasoning models reject `max_tokens` and require
    /// `max_completion_tokens`; everyone else still expects `max_tokens`.
    public var usesMaxCompletionTokens: Bool
    /// Whether the provider accepts `reasoning_effort`. Sending it to one that
    /// does not is a 400 on some and a silent ignore on others, so it is opt-in.
    public var supportsReasoningEffort: Bool
    /// Whether the provider runs on this machine. LM Studio and llama.cpp do;
    /// that changes what we are allowed to tell the owner about privacy.
    public var isLocal: Bool

    public init(
        identifier: String,
        displayName: String,
        baseURL: URL,
        usesMaxCompletionTokens: Bool = false,
        supportsReasoningEffort: Bool = false,
        isLocal: Bool = false
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.baseURL = baseURL
        self.usesMaxCompletionTokens = usesMaxCompletionTokens
        self.supportsReasoningEffort = supportsReasoningEffort
        self.isLocal = isLocal
    }

    public static let openAI = OpenAICompatProvider(
        identifier: "openai",
        displayName: "OpenAI",
        baseURL: URL(string: "https://api.openai.com/v1")!,
        usesMaxCompletionTokens: true,
        supportsReasoningEffort: true
    )

    public static let deepSeek = OpenAICompatProvider(
        identifier: "deepseek",
        displayName: "DeepSeek",
        baseURL: URL(string: "https://api.deepseek.com/v1")!
    )

    /// Kimi. The vendor is Moonshot AI; the owner knows it as Kimi.
    public static let moonshot = OpenAICompatProvider(
        identifier: "moonshot",
        displayName: "Kimi",
        baseURL: URL(string: "https://api.moonshot.ai/v1")!
    )

    public static let groq = OpenAICompatProvider(
        identifier: "groq",
        displayName: "Groq",
        baseURL: URL(string: "https://api.groq.com/openai/v1")!
    )

    /// Google's OpenAI-compatibility layer.
    ///
    /// Worth knowing: this is the *API-key* path. The zero-friction "sign in
    /// with Google" path yields an OAuth token, which this same backend accepts
    /// via a `BrainCredential` that refreshes it — the wire format is identical.
    public static let gemini = OpenAICompatProvider(
        identifier: "gemini",
        displayName: "Google Gemini",
        baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta/openai")!
    )

    /// LM Studio's local server. Same wire format, nothing leaves the machine.
    public static func lmStudio(port: Int = 1234) -> OpenAICompatProvider {
        OpenAICompatProvider(
            identifier: "lmstudio",
            displayName: "LM Studio",
            baseURL: URL(string: "http://127.0.0.1:\(port)/v1")!,
            isLocal: true
        )
    }
}

/// `BrainBackend` over any `/v1/chat/completions` endpoint.
///
/// This one adapter is what makes "bring your own provider" cheap: DeepSeek,
/// Kimi, Groq, Gemini and a local LM Studio are all configuration, not code.
public final class OpenAICompatBackend: BrainBackend, @unchecked Sendable {
    public var identifier: String { provider.identifier }
    public let modelName: String
    public var isLocal: Bool { provider.isLocal }

    private let provider: OpenAICompatProvider
    private let credential: BrainCredential
    private let session: URLSession
    private let timeoutSeconds: TimeInterval

    public init(
        provider: OpenAICompatProvider,
        modelName: String,
        credential: BrainCredential,
        timeoutSeconds: TimeInterval = 120,
        session: URLSession? = nil
    ) {
        self.provider = provider
        self.modelName = modelName
        self.credential = credential
        self.timeoutSeconds = timeoutSeconds
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = timeoutSeconds
            configuration.timeoutIntervalForResource = timeoutSeconds
            self.session = URLSession(configuration: configuration)
        }
    }

    // MARK: Availability

    /// Lists models. Cheaper and more diagnostic than a completion: it proves
    /// the credential works *and* that the requested model is actually offered
    /// to this account, which is a common way "it just doesn't answer" happens.
    public func isAvailable() async -> Bool {
        var request = URLRequest(url: provider.baseURL.appendingPathComponent("models"))
        request.timeoutInterval = min(timeoutSeconds, 15)
        guard let headers = try? await credential.authorizationHeaders() else {
            return false
        }
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            return false
        }
        guard let ids = JSONValue.parse(data)?["data"]?.arrayValue?
            .compactMap({ $0["id"]?.stringValue }) else {
            // Some compatible servers do not implement /models. A 2xx is still
            // evidence the credential is accepted, so do not fail on that alone.
            return true
        }
        return ids.isEmpty || ids.contains(modelName)
    }

    // MARK: Completion

    public func complete(_ request: BrainRequest) async throws -> BrainReply {
        var body: [String: Any] = [
            "model": modelName,
            "messages": Self.encodeMessages(request.messages),
            "stream": false
        ]
        if !request.tools.isEmpty {
            body["tools"] = request.tools.map(\.openAIWireObject)
        }
        if let temperature = request.temperature {
            body["temperature"] = temperature
        }
        if let maxOutputTokens = request.maxOutputTokens {
            body[provider.usesMaxCompletionTokens ? "max_completion_tokens" : "max_tokens"] = maxOutputTokens
        }
        if provider.supportsReasoningEffort {
            switch request.reasoning {
            case .enabled:  body["reasoning_effort"] = "medium"
            case .disabled: body["reasoning_effort"] = "minimal"
            case .automatic: break
            }
        }

        var urlRequest = URLRequest(url: provider.baseURL.appendingPathComponent("chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeoutSeconds
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in try await credential.authorizationHeaders() {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        do {
            urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        } catch {
            throw BrainBackendError.malformedResponse("could not encode request: \(error)")
        }

        let started = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw BrainBackendError.unreachable(String(describing: error))
        }
        let elapsed = Date().timeIntervalSince(started)

        guard let http = response as? HTTPURLResponse else {
            throw BrainBackendError.malformedResponse("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.translate(
                status: http.statusCode,
                headers: http,
                body: data,
                providerName: provider.displayName
            )
        }
        guard let root = JSONValue.parse(data) else {
            throw BrainBackendError.malformedResponse(
                "body was not JSON: \(String(decoding: data.prefix(400), as: UTF8.self))"
            )
        }

        var reply = try Self.parseReply(root, fallbackModel: modelName)
        reply.wallClockSeconds = elapsed
        return reply
    }

    // MARK: Encoding

    /// Projects the neutral history onto the chat-completions message array.
    ///
    /// Unlike Anthropic this shape is nearly one-to-one — system stays a
    /// message, tool results stay their own turns — so the interesting parts
    /// are the two easy-to-get-wrong details handled in `openAIWireObject`:
    /// `arguments` is a JSON-encoded *string*, and a pure tool-call assistant
    /// turn carries null content.
    static func encodeMessages(_ messages: [BrainMessage]) -> [[String: Any]] {
        messages.map(\.openAIWireObject)
    }

    // MARK: Parsing

    /// Exposed so wire handling can be tested without a network call or a key.
    public static func parseReply(_ root: JSONValue, fallbackModel: String) throws -> BrainReply {
        if let message = root["error"]?["message"]?.stringValue {
            throw BrainBackendError.requestRejected(message)
        }
        guard let choice = root["choices"]?.arrayValue?.first else {
            throw BrainBackendError.malformedResponse("no choices array in the completion")
        }
        guard let messageObject = choice["message"]?.objectValue else {
            throw BrainBackendError.malformedResponse("no message object in the first choice")
        }

        // `content` is legitimately null on a pure tool-call turn.
        let content = messageObject["content"]?.stringValue ?? ""
        // DeepSeek names it `reasoning_content`; others use `reasoning`.
        let reasoning = messageObject["reasoning_content"]?.stringValue
            ?? messageObject["reasoning"]?.stringValue

        let toolCalls: [BrainToolCall] = (messageObject["tool_calls"]?.arrayValue ?? [])
            .compactMap { entry in
                let function = entry["function"]?.objectValue ?? entry.objectValue ?? [:]
                guard let name = function["name"]?.stringValue, !name.isEmpty else {
                    return nil
                }
                return BrainToolCall(
                    id: entry["id"]?.stringValue,
                    name: name,
                    // `arguments` is spec'd as a JSON *string*, so it always
                    // needs a second parse. `normalizeArguments` already handles
                    // that plus the double-encoded variant seen in the wild.
                    arguments: OllamaClient.normalizeArguments(function["arguments"])
                )
            }

        let stopReason: BrainStopReason
        switch choice["finish_reason"]?.stringValue {
        case "tool_calls":  stopReason = .toolUse
        case "stop":        stopReason = .endTurn
        case "length":      stopReason = .maxTokens
        case let other?:    stopReason = .other(other)
        // Absent finish_reason with tool calls present still means tool use.
        case nil:           stopReason = toolCalls.isEmpty ? .endTurn : .toolUse
        }

        let message = BrainMessage(
            role: .assistant,
            content: content,
            thinking: (reasoning?.isEmpty == false) ? reasoning : nil,
            toolCalls: toolCalls
        )

        return BrainReply(
            model: root["model"]?.stringValue ?? fallbackModel,
            message: message,
            stopReason: stopReason,
            usage: BrainUsage(
                inputTokens: root["usage"]?["prompt_tokens"]?.intValue,
                outputTokens: root["usage"]?["completion_tokens"]?.intValue
            )
        )
    }

    /// Maps an HTTP failure onto the neutral vocabulary.
    public static func translate(
        status: Int,
        headers: HTTPURLResponse?,
        body: Data,
        providerName: String
    ) -> BrainBackendError {
        let text = String(decoding: body.prefix(600), as: UTF8.self)
        let parsed = JSONValue.parse(body)
        let detail = parsed?["error"]?["message"]?.stringValue
            ?? parsed?["message"]?.stringValue
            ?? text

        switch status {
        case 401, 403:
            return .unauthorized(provider: providerName, detail: detail)
        case 429:
            let retryAfter = headers?
                .value(forHTTPHeaderField: "retry-after")
                .flatMap(TimeInterval.init)
            return .rateLimited(provider: providerName, retryAfterSeconds: retryAfter)
        case 400, 404, 413, 422:
            return .requestRejected(detail)
        default:
            return .badResponse(status: status, body: detail)
        }
    }
}

// MARK: - Wire encoding

extension BrainMessage {
    var openAIWireObject: [String: Any] {
        var object: [String: Any] = ["role": role.rawValue]

        switch role {
        case .tool:
            object["content"] = content
            // Matched by id here, unlike Ollama which matches by name. Fall back
            // to the name so a history built for Ollama still round-trips.
            object["tool_call_id"] = toolCallID ?? toolName ?? ""

        case .assistant:
            // A pure tool-call turn carries null content, which is what the
            // spec asks for; sending "" makes some providers reject the turn.
            object["content"] = content.isEmpty ? NSNull() : content
            if !toolCalls.isEmpty {
                object["tool_calls"] = toolCalls.enumerated().map { index, call in
                    [
                        "id": call.id ?? "call_\(index)",
                        "type": "function",
                        "function": [
                            "name": call.name,
                            // Spec'd as a JSON-encoded string, not an object.
                            "arguments": call.argumentsJSON
                        ]
                    ]
                }
            }

        case .system, .user:
            object["content"] = content
        }
        return object
    }
}

private extension BrainTool {
    var openAIWireObject: [String: Any] {
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
