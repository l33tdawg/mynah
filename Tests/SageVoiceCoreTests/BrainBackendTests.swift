import XCTest
@testable import SageVoiceCore

/// Wire-format tests for the `BrainBackend` adapters.
///
/// These assert on the bytes each provider actually receives, because that is
/// where the adapters can be wrong in ways nothing else catches: the package
/// builds, the types line up, and the API returns a 400 the first time the
/// owner says something out loud.
final class BrainBackendTests: XCTestCase {

    // A conversation in exactly the shape `ToolLoop` produces: system prompt,
    // owner's transcript, an assistant turn requesting two tools, then the two
    // results.
    private var toolLoopShapedHistory: [BrainMessage] {
        [
            .system("You are the agent manager."),
            .user("What's on the mini's plate?"),
            BrainMessage(
                role: .assistant,
                content: "",
                toolCalls: [
                    BrainToolCall(id: "toolu_01", name: "sage_find_agent", arguments: ["query": .string("mini")]),
                    BrainToolCall(id: "toolu_02", name: "sage_inbox", arguments: [:])
                ]
            ),
            .toolResult(name: "sage_find_agent", content: "sage-mini", id: "toolu_01"),
            .toolResult(name: "sage_inbox", content: "3 items", id: "toolu_02")
        ]
    }

    // MARK: - Anthropic encoding

    /// Anthropic requires every `tool_result` for one assistant turn to arrive
    /// in the *single* user turn that follows. The neutral history stores them
    /// as separate `.tool` messages, so the encoder has to batch them.
    func testAnthropicBatchesConsecutiveToolResultsIntoOneTurn() throws {
        let encoded = try AnthropicBackend.encodeMessages(toolLoopShapedHistory)

        // system is hoisted out, so: user, assistant, user(2 tool_results)
        XCTAssertEqual(encoded.count, 3, "\(encoded)")
        XCTAssertEqual(encoded[0]["role"] as? String, "user")
        XCTAssertEqual(encoded[1]["role"] as? String, "assistant")
        XCTAssertEqual(encoded[2]["role"] as? String, "user")

        let results = try XCTUnwrap(encoded[2]["content"] as? [[String: Any]])
        XCTAssertEqual(results.count, 2, "both tool results must share one turn")
        XCTAssertEqual(results.map { $0["tool_use_id"] as? String }, ["toolu_01", "toolu_02"])
        XCTAssertTrue(results.allSatisfy { $0["type"] as? String == "tool_result" })
    }

    /// The system prompt is a top-level field, never a message.
    func testAnthropicDropsSystemTurnsFromTheMessageArray() throws {
        let encoded = try AnthropicBackend.encodeMessages(toolLoopShapedHistory)
        XCTAssertFalse(
            encoded.contains { $0["role"] as? String == "system" },
            "system must be hoisted to the top-level field, not sent as a message"
        )
    }

    /// A tool result with no call id cannot be attached to anything. Fail here,
    /// with a message naming the tool, rather than shipping a 400 upstream.
    func testAnthropicRejectsToolResultWithoutAnID() {
        let history: [BrainMessage] = [
            .user("hi"),
            BrainMessage(role: .assistant, content: "", toolCalls: [
                BrainToolCall(id: nil, name: "sage_inbox", arguments: [:])
            ]),
            .toolResult(name: "sage_inbox", content: "3 items", id: nil)
        ]
        XCTAssertThrowsError(try AnthropicBackend.encodeMessages(history)) { error in
            guard case BrainBackendError.requestRejected(let detail) = error else {
                return XCTFail("expected .requestRejected, got \(error)")
            }
            XCTAssertTrue(detail.contains("sage_inbox"), detail)
        }
    }

    /// `ToolLoop`'s forced-summary turn lands directly after a batch of tool
    /// results. Two consecutive user turns is not the alternating shape the
    /// API expects, so they must be folded into one.
    func testAnthropicMergesTheForcedSummaryIntoThePrecedingToolResultTurn() throws {
        let history = toolLoopShapedHistory + [.user("Answer now without calling tools.")]
        let encoded = try AnthropicBackend.encodeMessages(history)

        XCTAssertEqual(encoded.count, 3, "the trailing user turn must merge, not append: \(encoded)")
        let final = try XCTUnwrap(encoded[2]["content"] as? [[String: Any]])
        XCTAssertEqual(final.count, 3, "2 tool_results + 1 text block")
        XCTAssertEqual(final.last?["type"] as? String, "text")
    }

    /// Extended-thinking blocks carry a signature the API re-validates on the
    /// next request. Re-synthesising the turn from `content` would drop it, so
    /// the original blocks are replayed verbatim.
    func testAnthropicReplaysProviderPayloadVerbatimToPreserveThinkingSignature() throws {
        let originalBlocks = JSONValue.array([
            .object([
                "type": .string("thinking"),
                "thinking": .string("The mini is the appliance."),
                "signature": .string("SIG-DO-NOT-LOSE-ME")
            ]),
            .object([
                "type": .string("tool_use"),
                "id": .string("toolu_99"),
                "name": .string("sage_inbox"),
                "input": .object([:])
            ])
        ])
        let history: [BrainMessage] = [
            .user("check the inbox"),
            BrainMessage(
                role: .assistant,
                content: "",
                thinking: "The mini is the appliance.",
                toolCalls: [BrainToolCall(id: "toolu_99", name: "sage_inbox", arguments: [:])],
                providerPayload: originalBlocks
            ),
            .toolResult(name: "sage_inbox", content: "3 items", id: "toolu_99")
        ]

        let encoded = try AnthropicBackend.encodeMessages(history)
        let assistant = try XCTUnwrap(encoded[1]["content"] as? [[String: Any]])
        XCTAssertEqual(assistant.count, 2, "the thinking block must survive")
        XCTAssertEqual(assistant[0]["signature"] as? String, "SIG-DO-NOT-LOSE-ME")
    }

    // MARK: - Anthropic parsing

    func testAnthropicParsesToolUseReply() throws {
        let raw = """
        {"id":"msg_1","type":"message","role":"assistant","model":"claude-opus-5",
         "content":[{"type":"thinking","thinking":"pick a tool","signature":"abc"},
                    {"type":"tool_use","id":"toolu_7","name":"sage_pipe",
                     "input":{"target":"sage-mini","message":"stand up"}}],
         "stop_reason":"tool_use","usage":{"input_tokens":812,"output_tokens":64}}
        """
        let reply = try AnthropicBackend.parseReply(
            XCTUnwrap(JSONValue.parse(Data(raw.utf8))),
            fallbackModel: "claude-opus-5"
        )

        XCTAssertEqual(reply.stopReason, .toolUse)
        XCTAssertEqual(reply.toolCalls.count, 1)
        XCTAssertEqual(reply.toolCalls.first?.name, "sage_pipe")
        XCTAssertEqual(reply.toolCalls.first?.id, "toolu_7")
        XCTAssertEqual(reply.toolCalls.first?.arguments["target"]?.stringValue, "sage-mini")
        XCTAssertEqual(reply.message.thinking, "pick a tool")
        XCTAssertEqual(reply.usage.inputTokens, 812)
        XCTAssertEqual(reply.usage.outputTokens, 64)
        XCTAssertNotNil(reply.message.providerPayload, "blocks must be retained for replay")
    }

    /// A `max_tokens` stop means the reply is incomplete. `ToolLoop` reports it
    /// in the trace, so it must not be silently flattened to a normal end.
    func testAnthropicSurfacesTruncation() throws {
        let raw = """
        {"content":[{"type":"text","text":"You have th"}],"stop_reason":"max_tokens",
         "usage":{"input_tokens":10,"output_tokens":1024}}
        """
        let reply = try AnthropicBackend.parseReply(
            XCTUnwrap(JSONValue.parse(Data(raw.utf8))),
            fallbackModel: "claude-opus-5"
        )
        XCTAssertEqual(reply.stopReason, .maxTokens)
        XCTAssertTrue(reply.wasTruncated)
    }

    // MARK: - Error translation

    /// "Your key is wrong" and "you're out of quota" are different sentences
    /// out of a speaker, and only one of them is worth retrying.
    func testHTTPFailuresTranslateToDistinctNeutralErrors() {
        let unauthorized = AnthropicBackend.translate(
            status: 401,
            headers: nil,
            body: Data(#"{"error":{"message":"invalid x-api-key"}}"#.utf8)
        )
        guard case .unauthorized(let provider, let detail) = unauthorized else {
            return XCTFail("401 must map to .unauthorized, got \(unauthorized)")
        }
        XCTAssertEqual(provider, "Anthropic")
        XCTAssertEqual(detail, "invalid x-api-key")
        XCTAssertFalse(unauthorized.isTransient, "a bad key will not fix itself on retry")

        let rateLimited = AnthropicBackend.translate(
            status: 429,
            headers: HTTPURLResponse(
                url: URL(string: "https://api.anthropic.com/v1/messages")!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: ["retry-after": "30"]
            ),
            body: Data(#"{"error":{"message":"rate_limit_error"}}"#.utf8)
        )
        XCTAssertEqual(rateLimited, .rateLimited(provider: "Anthropic", retryAfterSeconds: 30))
        XCTAssertTrue(rateLimited.isTransient)

        // Distinct sentences reach the owner.
        XCTAssertNotEqual(unauthorized.spokenDescription, rateLimited.spokenDescription)
    }

    // MARK: - OpenAI-compatible encoding

    /// The spec says `arguments` is a JSON-encoded *string*, not an object.
    /// Sending an object is accepted by some providers and rejected by others,
    /// which is the worst kind of bug to find in production.
    func testOpenAICompatEncodesToolArgumentsAsAJSONString() throws {
        let history: [BrainMessage] = [
            BrainMessage(role: .assistant, content: "", toolCalls: [
                BrainToolCall(id: "call_1", name: "sage_pipe", arguments: [
                    "target": .string("sage-mini")
                ])
            ])
        ]
        let object = try XCTUnwrap(encodeOpenAI(history).first)
        let calls = try XCTUnwrap(object["tool_calls"] as? [[String: Any]])
        let function = try XCTUnwrap(calls[0]["function"] as? [String: Any])

        let arguments = try XCTUnwrap(function["arguments"] as? String,
                                      "arguments must be a String, not \(type(of: function["arguments"]))")
        XCTAssertEqual(
            JSONValue.parse(Data(arguments.utf8))?["target"]?.stringValue,
            "sage-mini"
        )
    }

    /// A pure tool-call assistant turn carries null content per the spec.
    /// Sending `""` makes some providers reject the turn.
    func testOpenAICompatSendsNullContentOnAPureToolCallTurn() throws {
        let history: [BrainMessage] = [
            BrainMessage(role: .assistant, content: "", toolCalls: [
                BrainToolCall(id: "call_1", name: "sage_inbox", arguments: [:])
            ])
        ]
        let object = try XCTUnwrap(encodeOpenAI(history).first)
        XCTAssertTrue(object["content"] is NSNull, "expected null, got \(String(describing: object["content"]))")
    }

    /// This shape matches results to requests by id, unlike Ollama which matches
    /// by name — so a history built for one must still round-trip through the
    /// other.
    func testOpenAICompatFallsBackToToolNameWhenNoIDIsPresent() throws {
        let history: [BrainMessage] = [.toolResult(name: "sage_inbox", content: "3 items", id: nil)]
        let object = try XCTUnwrap(encodeOpenAI(history).first)
        XCTAssertEqual(object["tool_call_id"] as? String, "sage_inbox")
    }

    // MARK: - OpenAI-compatible parsing

    func testOpenAICompatParsesToolCallsWithStringEncodedArguments() throws {
        let raw = """
        {"id":"c1","model":"deepseek-chat","choices":[{"index":0,"finish_reason":"tool_calls",
          "message":{"role":"assistant","content":null,
            "tool_calls":[{"id":"call_9","type":"function",
              "function":{"name":"sage_pipe","arguments":"{\\"target\\":\\"sage-mini\\"}"}}]}}],
         "usage":{"prompt_tokens":700,"completion_tokens":40}}
        """
        let reply = try OpenAICompatBackend.parseReply(
            XCTUnwrap(JSONValue.parse(Data(raw.utf8))),
            fallbackModel: "deepseek-chat"
        )

        XCTAssertEqual(reply.stopReason, .toolUse)
        XCTAssertEqual(reply.toolCalls.first?.name, "sage_pipe")
        XCTAssertEqual(reply.toolCalls.first?.id, "call_9")
        XCTAssertEqual(
            reply.toolCalls.first?.arguments["target"]?.stringValue,
            "sage-mini",
            "the JSON-string arguments must be parsed back into an object"
        )
        XCTAssertEqual(reply.usage.inputTokens, 700)
    }

    /// DeepSeek's reasoner returns `reasoning_content`; others use `reasoning`.
    /// Either way it must land in `thinking` and never in the spoken text.
    func testOpenAICompatMapsBothReasoningFieldNames() throws {
        for field in ["reasoning_content", "reasoning"] {
            let raw = """
            {"choices":[{"finish_reason":"stop","message":
              {"role":"assistant","content":"Three items.","\(field)":"internal notes"}}]}
            """
            let reply = try OpenAICompatBackend.parseReply(
                XCTUnwrap(JSONValue.parse(Data(raw.utf8))),
                fallbackModel: "m"
            )
            XCTAssertEqual(reply.message.thinking, "internal notes", "field: \(field)")
            XCTAssertEqual(reply.message.content, "Three items.")
        }
    }

    /// Some compatible servers omit `finish_reason`. Tool calls in the payload
    /// still mean tool use; treating it as a finished turn would make the loop
    /// speak an empty reply.
    func testOpenAICompatInfersToolUseWhenFinishReasonIsMissing() throws {
        let raw = """
        {"choices":[{"message":{"role":"assistant","content":null,
          "tool_calls":[{"id":"c","type":"function",
            "function":{"name":"sage_inbox","arguments":"{}"}}]}}]}
        """
        let reply = try OpenAICompatBackend.parseReply(
            XCTUnwrap(JSONValue.parse(Data(raw.utf8))),
            fallbackModel: "m"
        )
        XCTAssertEqual(reply.stopReason, .toolUse)
    }

    func testOpenAICompatMapsLengthToTruncation() throws {
        let raw = #"{"choices":[{"finish_reason":"length","message":{"role":"assistant","content":"You have th"}}]}"#
        let reply = try OpenAICompatBackend.parseReply(
            XCTUnwrap(JSONValue.parse(Data(raw.utf8))),
            fallbackModel: "m"
        )
        XCTAssertTrue(reply.wasTruncated)
    }

    // MARK: - Ollama projection

    /// The Ollama response carries richer counters than the neutral type; the
    /// projection must not lose the ones the trace reports.
    func testOllamaResponseProjectsOntoTheNeutralReply() throws {
        let raw = """
        {"model":"qwen3.5:4b","message":{"role":"assistant","content":"Three items."},
         "done_reason":"stop","prompt_eval_count":900,"eval_count":33,
         "eval_duration":4000000000,"total_duration":4120000000}
        """
        let response = try OllamaClient.parseChatResponse(
            XCTUnwrap(JSONValue.parse(Data(raw.utf8))),
            fallbackModel: "qwen3.5:4b"
        )
        let reply = response.asBrainReply

        XCTAssertEqual(reply.stopReason, .endTurn)
        XCTAssertEqual(reply.usage.inputTokens, 900)
        XCTAssertEqual(reply.usage.outputTokens, 33)
        XCTAssertEqual(reply.wallClockSeconds, 4.12, accuracy: 0.001)
        XCTAssertFalse(reply.wasTruncated)
    }

    func testOllamaLengthStopProjectsToMaxTokens() throws {
        let raw = """
        {"model":"qwen3.5:4b","message":{"role":"assistant","content":"partial"},
         "done_reason":"length","eval_count":1024}
        """
        let response = try OllamaClient.parseChatResponse(
            XCTUnwrap(JSONValue.parse(Data(raw.utf8))),
            fallbackModel: "qwen3.5:4b"
        )
        XCTAssertEqual(response.asBrainReply.stopReason, .maxTokens)
    }

    /// An Ollama 404 means the model was never pulled, which is the single most
    /// common failure on a fresh machine. "HTTP 404" tells the owner nothing.
    func testOllama404BecomesAMisconfigurationNotABareStatus() {
        let error = OllamaClientError
            .badResponse(404, #"{"error":"model 'qwen3.5:4b' not found"}"#)
            .asBrainBackendError

        guard case .misconfigured(let detail) = error else {
            return XCTFail("expected .misconfigured, got \(error)")
        }
        XCTAssertTrue(detail.contains("pull"), detail)
        XCTAssertFalse(error.isTransient)
    }

    // MARK: - Helper

    private func encodeOpenAI(_ messages: [BrainMessage]) -> [[String: Any]] {
        OpenAICompatBackend.encodeMessages(messages)
    }

    // MARK: - Anthropic parameter gating (regression)

    /// `temperature` was removed on Opus 4.7+. ToolLoop defaults to 0, so
    /// sending it made every real voice turn a 400 — while isAvailable()
    /// passed nil and succeeded, so setup said "you're all set" and the first
    /// thing the owner said out loud failed.
    func testTemperatureIsOmittedOnModelsThatRejectIt() {
        for model in ["claude-opus-5", "claude-opus-4-8", "claude-opus-4-7", "claude-fable-5"] {
            XCTAssertFalse(
                AnthropicBackend.acceptsTemperature(model),
                "\(model) rejects temperature outright; sending it is a 400"
            )
        }
        for model in ["claude-opus-4-6", "claude-sonnet-4-6", "claude-haiku-4-5"] {
            XCTAssertTrue(AnthropicBackend.acceptsTemperature(model), model)
        }
    }

    /// A local 4B's 1024-token budget is not a sane cap for a cloud reasoning
    /// model: thinking can consume it entirely, yielding empty content and —
    /// through ToolLoop's forced summary — silence for the owner.
    func testMaxTokensFloorProtectsReasoningModelsButLeavesProbesAlone() {
        XCTAssertGreaterThanOrEqual(AnthropicBackend.minimumMaxOutputTokens, 4096)
        XCTAssertLessThan(
            1024, AnthropicBackend.minimumMaxOutputTokens,
            "ToolLoop's default must be raised by the floor, not passed through"
        )
    }
}
