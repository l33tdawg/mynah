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

    /// Zhipu's GLM. The owner asked for it by that name; the vendor is Zhipu AI
    /// and the console is `open.bigmodel.cn`, so both appear where they help.
    public static let glm = OpenAICompatProvider(
        identifier: "glm",
        displayName: "GLM",
        baseURL: URL(string: "https://open.bigmodel.cn/api/paas/v4")!
    )

    /// Google's OpenAI-compatibility layer.
    ///
    /// This is the *API-key* path, and it is the only one this backend serves.
    ///
    /// An earlier comment here claimed the zero-friction "sign in with Google"
    /// path was the same wire format with a different `BrainCredential`. It is
    /// not. An OAuth token sent to `generativelanguage` is rejected with
    /// `403 ACCESS_TOKEN_SCOPE_INSUFFICIENT` — Google routes consumer sign-in to
    /// Code Assist at `cloudcode-pa.googleapis.com/v1internal`, which speaks a
    /// different request and response shape entirely. That path needs its own
    /// backend; see `CodeAssistBackend`.
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

    /// The tier's ceiling AND this model's own documented ability.
    ///
    /// Two tables because there are two naming worlds behind one wire format.
    /// A hosted id is a fixed string the vendor publishes, so
    /// `CloudBrainModelCatalog` matches it exactly. A model on an OpenAI-shaped
    /// server *on this Mac* is whatever the owner loaded into LM Studio, named
    /// with a quantisation and a build, so `LocalVisionModels` matches the
    /// family. Both default to blind for a name they do not recognise.
    public var seesImages: Bool {
        guard brain.mayCarryImages else { return false }
        return provider.isLocal
            ? LocalVisionModels.sees(modelName)
            : CloudBrainModelCatalog.seesImages(model: modelName)
    }

    /// Whether a given model on a given provider may be sent photos.
    ///
    /// Static and separate from the instance property so `requestBody` — which
    /// is `static` precisely so a test can read the wire without a network or a
    /// key — can derive the same answer. A test that had to construct a live
    /// backend to check the blind arm would be checking a different code path
    /// from the one that ships.
    static func carriesImages(model: String, provider: OpenAICompatProvider) -> Bool {
        let tier: BrainTier = provider.isLocal ? .onDevice : .hosted
        guard tier.capabilities.mayCarryImages else { return false }
        return provider.isLocal
            ? LocalVisionModels.sees(model)
            : CloudBrainModelCatalog.seesImages(model: model)
    }

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
        await availability().isUsable
    }

    /// The same round trip, with every distinction it establishes kept.
    ///
    /// This method always knew more than it said. It fetches the account's model
    /// list and checks our model is in it — then returned one bit, so a retired
    /// model, a rejected key and a dead network all arrived as `false`. The
    /// findings were being made and discarded in the same function.
    public func availability() async -> BrainAvailability {
        var request = URLRequest(url: provider.baseURL.appendingPathComponent("models"))
        request.timeoutInterval = min(timeoutSeconds, 15)

        guard let headers = try? await credential.authorizationHeaders() else {
            return .noCredential
        }
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else {
            return .unreachable("Could not reach \(provider.displayName).")
        }
        guard (200..<300).contains(http.statusCode) else {
            return .credentialRefused(status: http.statusCode)
        }

        guard let ids = JSONValue.parse(data)?["data"]?.arrayValue?
            .compactMap({ $0["id"]?.stringValue }) else {
            // Some compatible servers do not implement /models. A 2xx is still
            // evidence the credential is accepted — but it is *not* evidence
            // about the model, so this is `indeterminate` rather than `ready`.
            // Claiming `ready` here would be asserting something this request
            // never established.
            return .indeterminate
        }
        // An empty list is the same non-answer: a server that lists nothing has
        // not told us our model is missing, only that it does not enumerate.
        guard !ids.isEmpty else { return .indeterminate }

        return ids.contains(modelName)
            ? .ready
            : .modelNotOffered(model: modelName, offered: ids)
    }

    // MARK: Completion

    /// The JSON this backend puts on the wire.
    ///
    /// Static and separate from `complete` so a test can read it without a
    /// network. It was inline, and what it sent was therefore checked by nobody
    /// — which is how it shipped for three releases handing a hosted reasoning
    /// model a 1,024-token budget meant for a local 4B. `parseReply` was pulled
    /// out for the same reason and is well covered; this half was not.
    static func requestBody(
        for request: BrainRequest,
        model: String,
        provider: OpenAICompatProvider
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            // Derived from the model and the provider rather than taken as an
            // argument, so this function decides the same way `complete` does
            // and a static test can drive both arms.
            "messages": encodeMessages(
                request.messages,
                carryingImages: carriesImages(model: model, provider: provider)
            ),
            "stream": false
        ]
        if !request.tools.isEmpty {
            body["tools"] = request.tools.map(\.openAIWireObject)
        }
        if let temperature = request.temperature {
            body["temperature"] = temperature
        }
        // Floored, exactly as `AnthropicBackend` floors it — and for the reason
        // written there, which nobody carried across when this backend was
        // added. A caller that names no ceiling still gets the provider's own
        // default: silence is not a budget this loop chose, and overriding it
        // here would quietly cap models that were previously uncapped.
        //
        // **By the provider's own tier, not unconditionally.** This read
        // `hostedMaxOutputTokens`, which hardcodes `.hosted`, so an
        // OpenAI-shaped server *on this Mac* — LM Studio — had a cloud
        // reasoning model's floor applied to it and a deliberate 1,024 became
        // 4,096. The floor exists to stop a local model's budget starving a
        // model that spends its allowance thinking; a model on this Mac is
        // governed by `ReplyStyle` and by the 190-second runaway that number was
        // measured against.
        if request.maxOutputTokens != nil {
            body[provider.usesMaxCompletionTokens ? "max_completion_tokens" : "max_tokens"] =
                request.maxOutputTokens(
                    for: provider.isLocal ? .onDevice : .hosted,
                    default: BrainRequest.hostedMinimumOutputTokens
                )
        }
        if provider.supportsReasoningEffort {
            switch request.reasoning {
            case .enabled:  body["reasoning_effort"] = "medium"
            case .disabled: body["reasoning_effort"] = "minimal"
            case .automatic: break
            }
        }
        return body
    }

    public func complete(_ request: BrainRequest) async throws -> BrainReply {
        let body = Self.requestBody(for: request, model: modelName, provider: provider)

        var urlRequest = URLRequest(url: provider.baseURL.appendingPathComponent("chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeoutSeconds
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in try await credential.authorizationHeaders() {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        do {
            // Byte-stable for the same reason as Ollama, and here it is worth
            // money: DeepSeek prices a context-cache hit about ten times cheaper
            // than a miss, so an unsorted tool schema pays full price every turn.
            urlRequest.httpBody = try PromptStableJSON.data(from: body)
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
    ///
    /// - Parameter carryingImages: whether `BrainMessage.images` may go on the
    ///   wire. Defaulted so the existing text-only call sites read unchanged.
    static func encodeMessages(
        _ messages: [BrainMessage],
        carryingImages: Bool = false
    ) -> [[String: Any]] {
        messages.map { $0.openAIWireObject(carryingImages: carryingImages) }
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
                    arguments: OllamaClient.normalizeArguments(function["arguments"]),
                    // Gemini hides its thought_signature in here. Captured
                    // whole rather than reaching for the Google key, so a
                    // provider that puts something else in extra_content keeps
                    // working without another special case.
                    providerPayload: entry["extra_content"]
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
    /// - Parameter carryingImages: whether this turn's photos may go out. The
    ///   caller has already decided per model; this only shapes the bytes.
    func openAIWireObject(carryingImages: Bool = false) -> [String: Any] {
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
                object["tool_calls"] = toolCalls.enumerated().map { index, call -> [String: Any] in
                    var entry: [String: Any] = [
                        "id": call.id ?? "call_\(index)",
                        "type": "function",
                        "function": [
                            "name": call.name,
                            // Spec'd as a JSON-encoded string, not an object.
                            "arguments": call.argumentsJSON
                        ]
                    ]
                    // Replayed byte for byte. Gemini 3.x rejects the request
                    // that carries the tool result if this is missing.
                    if let payload = call.providerPayload {
                        entry["extra_content"] = payload.foundationObject
                    }
                    return entry
                }
            }

        case .system, .user:
            let photos = (role == .user && carryingImages) ? images : []
            guard !photos.isEmpty else {
                // **Content stays a plain String when there are no images**, and
                // that is worth money as well as bytes. Some compatible servers
                // reject a parts array on a text-only turn outright, and DeepSeek
                // prices a context-cache hit about ten times cheaper than a miss
                // — so promoting every text turn to the array shape would charge
                // full price on every request in the product for nothing.
                object["content"] = content
                break
            }
            // Text part first, matching the vendors' own examples for this
            // endpoint, and then one part per photo.
            var parts: [[String: Any]] = [["type": "text", "text": content]]
            for photo in photos {
                parts.append([
                    "type": "image_url",
                    // **A data URI, not bare base64.** `image_url.url` is what
                    // the chat-completions shape takes and what every provider
                    // here documents (OpenAI, Kimi, Gemini's compat layer, LM
                    // Studio). The `input_image` part belongs to the Responses
                    // API and none of these implement it on this endpoint.
                    //
                    // `detail` is omitted on purpose: `VisionAttachment` has
                    // already downscaled to 1024 px, `"low"` would force 512 px
                    // tiling and lose the text in a screenshot, and an omitted
                    // optional key is the one least likely to be rejected by a
                    // llama.cpp-shaped server that implements only the core of
                    // this schema.
                    "image_url": ["url": "data:image/jpeg;base64,\(photo.base64EncodedString())"]
                ])
            }
            object["content"] = parts
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
