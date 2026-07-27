import Foundation

// MARK: - Neutral conversation types

/// Who produced a turn.
///
/// Deliberately the lowest common denominator across Ollama, the Anthropic
/// Messages API and the OpenAI chat-completions shape. Providers that model
/// system prompts differently (Anthropic hoists them to a top-level `system`
/// field) handle that in their own adapter rather than leaking it here.
public enum BrainRole: String, Sendable, Equatable, Codable {
    case system
    case user
    case assistant
    case tool
}

/// One conversation turn, provider-neutral.
public struct BrainMessage: Sendable, Equatable {
    public var role: BrainRole

    /// The speakable/readable text of the turn. Empty on assistant turns that
    /// only requested tools.
    public var content: String

    /// Reasoning text emitted alongside `content` by models that expose it.
    /// Never spoken and never shown to the owner — it exists so traces can
    /// explain a routing decision.
    public var thinking: String?

    /// Tools this assistant turn asked for. Replayed back to the provider
    /// verbatim on the following request.
    public var toolCalls: [BrainToolCall]

    /// Name of the tool a `.tool` turn is answering. Ollama matches results to
    /// requests by name; the others match by `toolCallID`.
    public var toolName: String?

    /// Identifier of the call a `.tool` turn is answering. Required by the
    /// Anthropic (`tool_use_id`) and OpenAI (`tool_call_id`) shapes, optional
    /// for Ollama.
    public var toolCallID: String?

    /// Opaque, provider-owned rendering of this turn.
    ///
    /// The escape hatch that keeps the neutral layer honest. Anthropic's
    /// extended thinking blocks carry a cryptographic `signature` that must be
    /// replayed byte-for-byte on the next request or the API rejects it, and no
    /// provider-neutral field can represent that. A backend may stash its native
    /// content array here on the way out and use it verbatim on the way back in;
    /// every other backend ignores it.
    ///
    /// Never inspected by `ToolLoop` — only round-tripped.
    public var providerPayload: JSONValue?

    public init(
        role: BrainRole,
        content: String,
        thinking: String? = nil,
        toolCalls: [BrainToolCall] = [],
        toolName: String? = nil,
        toolCallID: String? = nil,
        providerPayload: JSONValue? = nil
    ) {
        self.role = role
        self.content = content
        self.thinking = thinking
        self.toolCalls = toolCalls
        self.toolName = toolName
        self.toolCallID = toolCallID
        self.providerPayload = providerPayload
    }

    public static func system(_ content: String) -> BrainMessage {
        BrainMessage(role: .system, content: content)
    }

    public static func user(_ content: String) -> BrainMessage {
        BrainMessage(role: .user, content: content)
    }

    public static func assistant(_ content: String) -> BrainMessage {
        BrainMessage(role: .assistant, content: content)
    }

    public static func toolResult(name: String, content: String, id: String? = nil) -> BrainMessage {
        BrainMessage(role: .tool, content: content, toolName: name, toolCallID: id)
    }
}

/// One function the model asked us to run.
public struct BrainToolCall: Sendable, Equatable {
    /// Provider-assigned call identifier. Ollama often omits it; Anthropic and
    /// OpenAI always supply one and require it back on the matching result.
    public var id: String?
    public var name: String
    public var arguments: [String: JSONValue]

    /// Opaque provider data attached to this call, replayed verbatim.
    ///
    /// Gemini 3.x puts an encrypted `thought_signature` here and rejects the
    /// *following* request without it — the turn that carries the tool result:
    ///
    ///     400 INVALID_ARGUMENT
    ///     Function call is missing a thought_signature in functionCall parts.
    ///
    /// Which makes it invisible to any check that sends one request. A key can
    /// pass validation, answer a single question, and fail every turn that
    /// actually uses a tool result. Nothing here interprets the contents; the
    /// bytes go back exactly as they arrived.
    public var providerPayload: JSONValue?

    public init(
        id: String? = nil,
        name: String,
        arguments: [String: JSONValue],
        providerPayload: JSONValue? = nil
    ) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.providerPayload = providerPayload
    }

    /// Compact JSON rendering of `arguments`, for traces and logging.
    public var argumentsJSON: String {
        JSONValue.object(arguments).jsonString()
    }
}

/// A JSON-Schema function definition offered to the model.
///
/// `parameters` is passed through untouched: the schemas come from the MCP
/// server's `tools/list` and nothing here understands SAGE's tool set.
public struct BrainTool: Sendable, Equatable {
    public var name: String
    public var description: String
    public var parameters: JSONValue

    public init(name: String, description: String, parameters: JSONValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

// MARK: - Request

/// Whether to let the model reason before answering.
///
/// Reasoning is not a nicety for this product — on qwen3.5:4b with 14 tools,
/// letting the model think scored 12/12 on routing and suppressing it scored
/// 3/10. It is also the single largest latency cost. Hence a three-way
/// preference rather than a bool: `.automatic` means "whatever this backend
/// does by default", which is the only correct answer for a provider we have
/// not measured.
public enum ReasoningPreference: Sendable, Equatable {
    case automatic
    case enabled
    case disabled
}

/// One completion request, provider-neutral.
public struct BrainRequest: Sendable {
    public var messages: [BrainMessage]
    public var tools: [BrainTool]
    public var temperature: Double?
    /// Hard cap on generated tokens, including reasoning tokens on providers
    /// that bill them as output.
    public var maxOutputTokens: Int?
    public var reasoning: ReasoningPreference

    public init(
        messages: [BrainMessage],
        tools: [BrainTool] = [],
        temperature: Double? = 0,
        maxOutputTokens: Int? = nil,
        reasoning: ReasoningPreference = .automatic
    ) {
        self.messages = messages
        self.tools = tools
        self.temperature = temperature
        self.maxOutputTokens = maxOutputTokens
        self.reasoning = reasoning
    }
}

// MARK: - Reply

/// Why generation stopped.
public enum BrainStopReason: Sendable, Equatable {
    /// The model finished its answer.
    case endTurn
    /// The model wants tools run before it can finish.
    case toolUse
    /// Generation hit the output-token cap. The reply is incomplete.
    case maxTokens
    /// A provider-specific reason we do not model.
    case other(String)
}

/// Token counters, where the provider reports them.
public struct BrainUsage: Sendable, Equatable {
    public var inputTokens: Int?
    public var outputTokens: Int?

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

/// One completion, provider-neutral.
public struct BrainReply: Sendable, Equatable {
    /// The model identifier that actually served the request, which is not
    /// always the one asked for (aliases, provider-side routing).
    public var model: String
    public var message: BrainMessage
    public var stopReason: BrainStopReason
    public var usage: BrainUsage
    /// Wall-clock seconds measured around the call by the adapter.
    public var wallClockSeconds: TimeInterval

    public init(
        model: String,
        message: BrainMessage,
        stopReason: BrainStopReason,
        usage: BrainUsage = BrainUsage(),
        wallClockSeconds: TimeInterval = 0
    ) {
        self.model = model
        self.message = message
        self.stopReason = stopReason
        self.usage = usage
        self.wallClockSeconds = wallClockSeconds
    }

    public var toolCalls: [BrainToolCall] { message.toolCalls }

    /// True when generation was cut off at the token cap rather than finishing.
    public var wasTruncated: Bool { stopReason == .maxTokens }

    /// Generated tokens per second, or `nil` when the provider omits counters.
    public var tokensPerSecond: Double? {
        guard let outputTokens = usage.outputTokens, wallClockSeconds > 0 else { return nil }
        return Double(outputTokens) / wallClockSeconds
    }
}

// MARK: - Errors

/// Failure modes shared by every brain backend.
///
/// Adapters translate provider errors into these so the daemon can decide what
/// to say out loud — "I've run out of quota" is a very different sentence from
/// "I can't reach the model" and the owner is listening, not reading a stack
/// trace.
public enum BrainBackendError: Error, CustomStringConvertible, Equatable {
    /// The configured endpoint or model identifier is unusable.
    case misconfigured(String)
    /// No credential available for a provider that needs one.
    case missingCredential(provider: String)
    /// The credential was rejected (401/403).
    case unauthorized(provider: String, detail: String)
    /// Rate limited or out of quota. `retryAfterSeconds` when the provider says.
    case rateLimited(provider: String, retryAfterSeconds: TimeInterval?)
    /// The transport failed: connection refused, timeout, DNS.
    case unreachable(String)
    /// A non-2xx the other cases do not cover.
    case badResponse(status: Int, body: String)
    /// 2xx, but the body was not what the wire format promises.
    case malformedResponse(String)
    /// The provider refused the request itself (context too long, bad schema).
    case requestRejected(String)

    public var description: String {
        switch self {
        case .misconfigured(let detail):
            return "Brain backend is misconfigured: \(detail)"
        case .missingCredential(let provider):
            return "No credential configured for \(provider)."
        case .unauthorized(let provider, let detail):
            return "\(provider) rejected the credential: \(detail)"
        case .rateLimited(let provider, let retryAfter):
            if let retryAfter {
                return "\(provider) is rate limiting; retry in \(Int(retryAfter.rounded()))s."
            }
            return "\(provider) is rate limiting or the quota is exhausted."
        case .unreachable(let detail):
            return "Could not reach the model: \(detail)"
        case .badResponse(let status, let body):
            return "Model returned HTTP \(status): \(body)"
        case .malformedResponse(let detail):
            return "Model response could not be understood: \(detail)"
        case .requestRejected(let detail):
            return "Model rejected the request: \(detail)"
        }
    }

    /// Whether retrying the identical request could plausibly succeed.
    public var isTransient: Bool {
        switch self {
        case .rateLimited, .unreachable:
            return true
        case .badResponse(let status, _):
            return status >= 500 || status == 408 || status == 429
        case .misconfigured, .missingCredential, .unauthorized,
             .malformedResponse, .requestRejected:
            return false
        }
    }

    /// A sentence safe to speak to the owner. Deliberately short: this comes out
    /// of a speaker, not a log file.
    public var spokenDescription: String {
        switch self {
        case .missingCredential, .unauthorized:
            return "I can't sign in to the model right now. Check the settings."
        case .rateLimited:
            return "I've hit the usage limit on the model. Try again shortly."
        case .unreachable:
            return "I can't reach the model right now."
        case .misconfigured, .badResponse, .malformedResponse, .requestRejected:
            return "Something went wrong talking to the model."
        }
    }
}

// MARK: - Credentials

/// Supplies the auth headers for a cloud backend.
///
/// A protocol rather than a `String` because not every credential is static.
/// The Google sign-in path this product defaults to yields an OAuth access
/// token that expires in an hour, and an appliance that runs for weeks must
/// refresh it without anyone being present to retype anything. Resolving per
/// request is the only shape that supports both.
///
/// Implementations must never log the credential value.
public protocol BrainCredential: Sendable {
    /// Headers to attach to the outgoing request. Called once per request, so
    /// an implementation may refresh an expired token here.
    func authorizationHeaders() async throws -> [String: String]
}

/// A fixed API key sent under a named header.
///
/// Providers disagree about the header: Anthropic wants `x-api-key`, the
/// OpenAI-shaped ones want `Authorization: Bearer …`.
public struct StaticAPIKeyCredential: BrainCredential {
    private let headerName: String
    private let headerValue: String
    /// Short label for errors, so a failure can name the provider without
    /// anything derived from the key itself appearing in a log.
    public let providerLabel: String

    public init(headerName: String, headerValue: String, providerLabel: String) {
        self.headerName = headerName
        self.headerValue = headerValue
        self.providerLabel = providerLabel
    }

    /// `x-api-key: <key>` — the Anthropic shape.
    public static func anthropic(apiKey: String) -> StaticAPIKeyCredential {
        StaticAPIKeyCredential(headerName: "x-api-key", headerValue: apiKey, providerLabel: "Anthropic")
    }

    /// `Authorization: Bearer <key>` — the OpenAI shape, which the
    /// OpenAI-compatible providers (DeepSeek, Moonshot/Kimi, Groq, Gemini's
    /// compatibility endpoint, LM Studio) all copy.
    public static func bearer(_ token: String, providerLabel: String) -> StaticAPIKeyCredential {
        StaticAPIKeyCredential(
            headerName: "Authorization",
            headerValue: "Bearer \(token)",
            providerLabel: providerLabel
        )
    }

    public func authorizationHeaders() async throws -> [String: String] {
        guard !headerValue.isEmpty,
              headerValue != "Bearer " else {
            throw BrainBackendError.missingCredential(provider: providerLabel)
        }
        return [headerName: headerValue]
    }
}

// MARK: - The protocol

/// A source of completions with tool calling.
///
/// One instance is bound to one model. That is deliberate: the model is chosen
/// once at setup — by detection, by the owner, or by falling back to local — and
/// the daemon should not be able to silently drift onto a different one
/// mid-conversation.
///
/// Local and cloud providers are peers here. Nothing downstream of this
/// protocol knows whether the tokens came off the Neural Engine or a datacentre,
/// which is what makes "start on the cloud brain, migrate to fully local later"
/// a settings change rather than a rewrite.
public protocol BrainBackend: Sendable {
    /// Stable short name for logs and metrics: `"ollama"`, `"anthropic"`.
    var identifier: String { get }

    /// The model this instance is bound to.
    var modelName: String { get }

    /// Whether this backend keeps the owner's words on the machine.
    ///
    /// Surfaced in the UI, so it must describe where the *text* goes, not where
    /// the vendor is headquartered.
    var isLocal: Bool { get }

    /// Cheap liveness/credential probe. Returns `false` rather than throwing so
    /// the setup flow can rank several candidates without exception plumbing.
    func isAvailable() async -> Bool

    /// One completion round trip.
    func complete(_ request: BrainRequest) async throws -> BrainReply
}

public extension BrainBackend {
    /// Human-readable one-liner for the setup UI and logs.
    var displayDescription: String {
        "\(identifier) · \(modelName)\(isLocal ? " · local" : " · cloud")"
    }
}
