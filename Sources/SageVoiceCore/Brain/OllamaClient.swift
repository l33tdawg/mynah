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
}

// MARK: - Wire types

/// A chat turn as Ollama's `/api/chat` understands it.
public struct OllamaMessage: Sendable, Equatable {
    public enum Role: String, Sendable, Equatable {
        case system
        case user
        case assistant
        case tool
    }

    public var role: Role
    public var content: String
    /// Reasoning text some models emit alongside `content`. Never spoken aloud.
    public var thinking: String?
    /// Present on assistant turns that requested tools; replayed back verbatim.
    public var toolCalls: [OllamaToolCall]
    /// Set on `.tool` turns so the model can match a result to its request.
    public var toolName: String?

    public init(
        role: Role,
        content: String,
        thinking: String? = nil,
        toolCalls: [OllamaToolCall] = [],
        toolName: String? = nil
    ) {
        self.role = role
        self.content = content
        self.thinking = thinking
        self.toolCalls = toolCalls
        self.toolName = toolName
    }

    public static func system(_ content: String) -> OllamaMessage {
        OllamaMessage(role: .system, content: content)
    }

    public static func user(_ content: String) -> OllamaMessage {
        OllamaMessage(role: .user, content: content)
    }

    public static func toolResult(name: String, content: String) -> OllamaMessage {
        OllamaMessage(role: .tool, content: content, toolName: name)
    }

    var wireObject: [String: Any] {
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
            object["tool_calls"] = toolCalls.map(\.wireObject)
        }
        return object
    }
}

/// One function the model asked us to run.
public struct OllamaToolCall: Sendable, Equatable {
    public var id: String?
    public var name: String
    public var arguments: [String: JSONValue]

    public init(id: String? = nil, name: String, arguments: [String: JSONValue]) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }

    /// Compact JSON rendering of `arguments`, handy for traces and logging.
    public var argumentsJSON: String {
        JSONValue.object(arguments).jsonString()
    }

    var wireObject: [String: Any] {
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

/// A JSON-schema function definition offered to the model.
public struct OllamaTool: Sendable, Equatable {
    public var name: String
    public var description: String
    /// JSON Schema object describing the arguments. Passed through untouched.
    public var parameters: JSONValue

    public init(name: String, description: String, parameters: JSONValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }

    var wireObject: [String: Any] {
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

/// One `/api/chat` reply, including the counters callers need to report latency.
public struct OllamaChatResponse: Sendable, Equatable {
    public var model: String
    public var message: OllamaMessage
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
        message: OllamaMessage,
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

    public var toolCalls: [OllamaToolCall] { message.toolCalls }

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
        messages: [OllamaMessage],
        tools: [OllamaTool] = [],
        temperature: Double? = 0,
        think: Bool? = nil,
        keepAlive: String? = nil,
        numPredict: Int? = nil,
        extraOptions: [String: JSONValue] = [:]
    ) async throws -> OllamaChatResponse {
        try validateBaseURL()

        var body: [String: Any] = [
            "model": model,
            "messages": messages.map(\.wireObject),
            "stream": false
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map(\.wireObject)
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
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
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

        let role = OllamaMessage.Role(rawValue: messageObject["role"]?.stringValue ?? "assistant") ?? .assistant
        let thinking = messageObject["thinking"]?.stringValue
            ?? messageObject["reasoning"]?.stringValue
        let message = OllamaMessage(
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
    public static func parseToolCalls(_ value: JSONValue?) -> [OllamaToolCall] {
        guard let entries = value?.arrayValue else {
            return []
        }
        return entries.compactMap { entry -> OllamaToolCall? in
            guard let object = entry.objectValue else {
                return nil
            }
            let function = object["function"]?.objectValue ?? object
            guard let name = function["name"]?.stringValue, !name.isEmpty else {
                return nil
            }
            let id = object["id"]?.stringValue ?? function["id"]?.stringValue
            return OllamaToolCall(
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
