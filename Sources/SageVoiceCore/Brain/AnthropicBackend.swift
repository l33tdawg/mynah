import Foundation

/// `BrainBackend` over the Anthropic Messages API.
///
/// Raw HTTP rather than an SDK because Anthropic ships no official Swift SDK,
/// and this package deliberately has zero external dependencies.
///
/// Non-streaming. That is a considered choice, not an oversight: a voice turn
/// caps generation at ~1–4k tokens and the reply is not spoken until it is
/// complete anyway, so SSE parsing would add real surface area and buy nothing.
/// It would start to matter if this ever drives a live call, where the first
/// sentence must leave before the last one is generated.
public final class AnthropicBackend: BrainBackend, @unchecked Sendable {
    public let identifier = "anthropic"
    public let modelName: String
    /// The owner's transcript is sent to Anthropic.
    public let isLocal = false

    /// Wire version pinned per Anthropic's versioning policy. Bumping it is a
    /// deliberate act, not something to leave floating.
    public static let apiVersion = "2023-06-01"

    public static let defaultBaseURL = URL(string: "https://api.anthropic.com")!

    /// The Messages API requires `max_tokens`. This is the fallback when the
    /// caller does not specify one.
    public static let defaultMaxOutputTokens = 4096

    private let baseURL: URL
    private let credential: BrainCredential
    private let session: URLSession
    private let timeoutSeconds: TimeInterval

    public init(
        modelName: String = "claude-opus-5",
        credential: BrainCredential,
        baseURL: URL = AnthropicBackend.defaultBaseURL,
        timeoutSeconds: TimeInterval = 120,
        session: URLSession? = nil
    ) {
        self.modelName = modelName
        self.credential = credential
        self.baseURL = baseURL
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

    /// Convenience for the common case.
    public convenience init(
        modelName: String = "claude-opus-5",
        apiKey: String,
        baseURL: URL = AnthropicBackend.defaultBaseURL
    ) {
        self.init(
            modelName: modelName,
            credential: StaticAPIKeyCredential.anthropic(apiKey: apiKey),
            baseURL: baseURL
        )
    }

    // MARK: Availability

    /// Sends the smallest possible real request.
    ///
    /// There is no free "is my key good" endpoint, so this costs one token of
    /// input. That is the honest price of not telling the owner "you're all set"
    /// and then failing on the first thing they say out loud.
    public func isAvailable() async -> Bool {
        let probe = BrainRequest(
            messages: [.user("hi")],
            tools: [],
            temperature: nil,
            maxOutputTokens: 1,
            reasoning: .disabled
        )
        do {
            _ = try await complete(probe)
            return true
        } catch let error as BrainBackendError {
            // A `maxTokens` stop is a success: the credential worked and the
            // model answered, we just cut it off after one token.
            if case .requestRejected = error { return false }
            if case .missingCredential = error { return false }
            if case .unauthorized = error { return false }
            // Rate limited means the key is real and the account is live.
            if case .rateLimited = error { return true }
            return false
        } catch {
            return false
        }
    }

    // MARK: Completion

    public func complete(_ request: BrainRequest) async throws -> BrainReply {
        let wantsThinking = request.reasoning == .enabled

        var body: [String: Any] = [
            "model": modelName,
            "max_tokens": request.maxOutputTokens ?? Self.defaultMaxOutputTokens,
            "messages": try Self.encodeMessages(request.messages)
        ]

        // Anthropic carries the system prompt in a top-level field, not as a
        // message. Several system turns are legal upstream, so join them.
        let systemText = request.messages
            .filter { $0.role == .system }
            .map(\.content)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        if !systemText.isEmpty {
            body["system"] = systemText
        }

        if !request.tools.isEmpty {
            body["tools"] = request.tools.map(\.anthropicWireObject)
        }

        if wantsThinking {
            // Adaptive thinking on Claude 4.6 and newer. `budget_tokens` is
            // deprecated on 4.6 and rejected outright by Opus 5, so it must not
            // appear here.
            body["thinking"] = ["type": "adaptive"]
            // Extended thinking requires the default temperature; sending one
            // alongside is a 400.
        } else if let temperature = request.temperature {
            body["temperature"] = temperature
        }

        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("v1/messages"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeoutSeconds
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
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
            throw Self.translate(status: http.statusCode, headers: http, body: data)
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

    /// Projects the neutral history onto Anthropic's content-block shape.
    ///
    /// Two constraints drive this and neither is optional:
    ///
    /// 1. **Tool results must be batched.** If an assistant turn emits N
    ///    `tool_use` blocks, the very next user turn must carry all N matching
    ///    `tool_result` blocks. The neutral history stores them as N separate
    ///    `.tool` messages, so consecutive runs are merged into one user turn.
    ///
    /// 2. **Assistant turns are replayed verbatim when we have the original.**
    ///    Extended-thinking blocks carry a cryptographic `signature` that the
    ///    API re-validates on the following request; re-synthesising the turn
    ///    from `content` + `toolCalls` would drop it and the request would be
    ///    rejected. `providerPayload` holds the original content array for
    ///    exactly this.
    static func encodeMessages(_ messages: [BrainMessage]) throws -> [[String: Any]] {
        var encoded: [[String: Any]] = []
        var pendingToolResults: [[String: Any]] = []

        func flushToolResults() {
            guard !pendingToolResults.isEmpty else { return }
            encoded.append(["role": "user", "content": pendingToolResults])
            pendingToolResults = []
        }

        for message in messages {
            switch message.role {
            case .system:
                // Hoisted to the top-level `system` field by the caller.
                continue

            case .tool:
                guard let id = message.toolCallID else {
                    // Without an id there is nothing to attach the result to and
                    // the API will reject the turn. Fail here with a message
                    // that names the cause rather than shipping a 400 upstream.
                    throw BrainBackendError.requestRejected(
                        "a tool result for '\(message.toolName ?? "?")' has no tool-call id; " +
                        "Anthropic matches results to requests by id"
                    )
                }
                pendingToolResults.append([
                    "type": "tool_result",
                    "tool_use_id": id,
                    "content": message.content
                ])

            case .user:
                flushToolResults()
                encoded.append([
                    "role": "user",
                    "content": [["type": "text", "text": message.content]]
                ])

            case .assistant:
                flushToolResults()
                if let original = message.providerPayload?.arrayValue {
                    encoded.append([
                        "role": "assistant",
                        "content": original.map(\.foundationObject)
                    ])
                    continue
                }
                var blocks: [[String: Any]] = []
                if !message.content.isEmpty {
                    blocks.append(["type": "text", "text": message.content])
                }
                for call in message.toolCalls {
                    blocks.append([
                        "type": "tool_use",
                        "id": call.id ?? call.name,
                        "name": call.name,
                        "input": call.arguments.mapValues(\.foundationObject)
                    ])
                }
                // An assistant turn with no blocks is invalid; skip rather than
                // send something the API will refuse.
                guard !blocks.isEmpty else { continue }
                encoded.append(["role": "assistant", "content": blocks])
            }
        }
        flushToolResults()

        // Merge adjacent same-role turns.
        //
        // `ToolLoop`'s forced-summary path emits a user turn directly after a
        // batch of tool results, which lands here as two consecutive user
        // turns. Anthropic expects strictly alternating roles, so fold them
        // into one turn with the blocks concatenated in order.
        var merged: [[String: Any]] = []
        for turn in encoded {
            guard
                let role = turn["role"] as? String,
                let blocks = turn["content"] as? [[String: Any]],
                var previous = merged.last,
                previous["role"] as? String == role,
                let previousBlocks = previous["content"] as? [[String: Any]]
            else {
                merged.append(turn)
                continue
            }
            previous["content"] = previousBlocks + blocks
            merged[merged.count - 1] = previous
        }
        return merged
    }

    // MARK: Parsing

    /// Exposed so wire handling can be tested without a network call or a key.
    public static func parseReply(_ root: JSONValue, fallbackModel: String) throws -> BrainReply {
        if let type = root["type"]?.stringValue, type == "error" {
            let detail = root["error"]?["message"]?.stringValue ?? "unspecified"
            throw BrainBackendError.requestRejected(detail)
        }
        guard let content = root["content"]?.arrayValue else {
            throw BrainBackendError.malformedResponse("no content array in the Messages reply")
        }

        var text = ""
        var thinking = ""
        var toolCalls: [BrainToolCall] = []

        for block in content {
            switch block["type"]?.stringValue {
            case "text":
                text += block["text"]?.stringValue ?? ""
            case "thinking":
                thinking += block["thinking"]?.stringValue ?? ""
            case "redacted_thinking":
                // Encrypted; nothing readable, but it still has to be replayed,
                // which `providerPayload` below takes care of.
                break
            case "tool_use":
                guard let name = block["name"]?.stringValue else { continue }
                toolCalls.append(
                    BrainToolCall(
                        id: block["id"]?.stringValue,
                        name: name,
                        arguments: block["input"]?.objectValue ?? [:]
                    )
                )
            default:
                break
            }
        }

        let stopReason: BrainStopReason
        switch root["stop_reason"]?.stringValue {
        case "tool_use":     stopReason = .toolUse
        case "end_turn":     stopReason = .endTurn
        case "max_tokens":   stopReason = .maxTokens
        case "stop_sequence": stopReason = .endTurn
        case let other?:     stopReason = .other(other)
        case nil:            stopReason = .endTurn
        }

        let message = BrainMessage(
            role: .assistant,
            content: text,
            thinking: thinking.isEmpty ? nil : thinking,
            toolCalls: toolCalls,
            // Keep the blocks exactly as they arrived so the next request can
            // replay them with their thinking signatures intact.
            providerPayload: root["content"]
        )

        return BrainReply(
            model: root["model"]?.stringValue ?? fallbackModel,
            message: message,
            stopReason: stopReason,
            usage: BrainUsage(
                inputTokens: root["usage"]?["input_tokens"]?.intValue,
                outputTokens: root["usage"]?["output_tokens"]?.intValue
            )
        )
    }

    /// Maps an HTTP failure onto the neutral vocabulary.
    ///
    /// Exposed for testing: the difference between "your key is wrong" and
    /// "you're out of quota" is what the owner hears out of a speaker, so it is
    /// worth asserting on.
    public static func translate(status: Int, headers: HTTPURLResponse?, body: Data) -> BrainBackendError {
        let text = String(decoding: body.prefix(600), as: UTF8.self)
        let detail = JSONValue.parse(body)?["error"]?["message"]?.stringValue ?? text

        switch status {
        case 401, 403:
            return .unauthorized(provider: "Anthropic", detail: detail)
        case 429, 529:
            let retryAfter = headers?
                .value(forHTTPHeaderField: "retry-after")
                .flatMap(TimeInterval.init)
            return .rateLimited(provider: "Anthropic", retryAfterSeconds: retryAfter)
        case 400, 404, 413, 422:
            return .requestRejected(detail)
        default:
            return .badResponse(status: status, body: detail)
        }
    }
}

// MARK: - Wire encoding

private extension BrainTool {
    /// Anthropic calls the schema field `input_schema`, not `parameters`.
    var anthropicWireObject: [String: Any] {
        [
            "name": name,
            "description": description,
            "input_schema": parameters.foundationObject
        ]
    }
}
