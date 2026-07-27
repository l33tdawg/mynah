import XCTest
@testable import SageVoiceCore

// MARK: - Stubs

/// A backend that replays a scripted list of replies, one per call.
private final class ScriptedBackend: BrainBackend, @unchecked Sendable {
    let identifier = "scripted"
    let modelName = "stub-model"
    let isLocal = true

    private let lock = NSLock()
    private var script: [BrainReply]
    /// Every request the loop made, in order — this is what the tests assert on.
    private(set) var requests: [BrainRequest] = []

    init(_ script: [BrainReply]) {
        self.script = script
    }

    func isAvailable() async -> Bool { true }

    func complete(_ request: BrainRequest) async throws -> BrainReply {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        guard !script.isEmpty else {
            throw BrainBackendError.requestRejected("the stub ran out of scripted replies")
        }
        return script.removeFirst()
    }

    static func answering(_ text: String) -> BrainReply {
        BrainReply(
            model: "stub-model",
            message: .assistant(text),
            stopReason: .endTurn,
            usage: BrainUsage(inputTokens: 10, outputTokens: 5)
        )
    }

    static func calling(_ name: String, id: String = "call_1", arguments: [String: JSONValue] = [:]) -> BrainReply {
        BrainReply(
            model: "stub-model",
            message: BrainMessage(
                role: .assistant,
                content: "",
                toolCalls: [BrainToolCall(id: id, name: name, arguments: arguments)]
            ),
            stopReason: .toolUse,
            usage: BrainUsage(inputTokens: 10, outputTokens: 5)
        )
    }
}

/// A tool source backed by a dictionary, with a recorded call log.
private final class StubToolSource: ToolProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let tools: [MCPTool]
    private let results: [String: String]
    private(set) var calls: [(name: String, arguments: [String: JSONValue])] = []

    init(toolNames: [String], results: [String: String] = [:]) {
        self.tools = toolNames.map {
            MCPTool(name: $0, description: "stub \($0)", inputSchema: .object(["type": .string("object")]))
        }
        self.results = results
    }

    func listTools() async throws -> [MCPTool] { tools }

    func call(name: String, arguments: [String: JSONValue]) async throws -> String {
        lock.lock()
        defer { lock.unlock() }
        calls.append((name, arguments))
        return results[name] ?? "ok"
    }
}

// MARK: - Tests

/// Tests for the agent loop itself.
///
/// These exist because `ToolLoop` had none: it was welded to a concrete
/// `MCPClient` that spawns a process, so exercising it required a live SAGE
/// install. Several of the behaviours below are fixes from an adversarial
/// review that until now were only argued for in a commit message.
final class ToolLoopTests: XCTestCase {

    private func makeLoop(
        backend: ScriptedBackend,
        tools: StubToolSource,
        configuration: ToolLoop.Configuration = ToolLoop.Configuration(allowedToolNames: [])
    ) -> ToolLoop {
        ToolLoop(backend: backend, mcp: tools, configuration: configuration)
    }

    // MARK: Allowlist

    /// Falling back to the full catalogue when the allowlist matches nothing is
    /// the worst available response: routing accuracy roughly halves at 27
    /// tools (measured 5-6/12 vs 12/12 curated), so the model would be least
    /// reliable exactly when its blast radius is widest — and the wider set
    /// contains irreversible verbs driven by an ASR transcript that may
    /// contain mishearings.
    func testAllowlistMatchingNothingFailsClosed() async {
        let tools = StubToolSource(toolNames: ["renamed_tool_a", "renamed_tool_b"])
        let loop = makeLoop(
            backend: ScriptedBackend([]),
            tools: tools,
            configuration: ToolLoop.Configuration(allowedToolNames: ["sage_inbox", "sage_pipe"])
        )

        do {
            _ = try await loop.availableTools()
            XCTFail("expected the loop to refuse rather than widen the catalogue")
        } catch let error as ToolLoopError {
            guard case .toolAllowlistMatchedNothing(let expected, let published) = error else {
                return XCTFail("wrong case: \(error)")
            }
            XCTAssertEqual(expected, ["sage_inbox", "sage_pipe"])
            XCTAssertEqual(published, ["renamed_tool_a", "renamed_tool_b"])
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testAllowlistFiltersToTheCuratedSubset() async throws {
        let tools = StubToolSource(toolNames: ["sage_inbox", "sage_forget", "sage_pipe"])
        let loop = makeLoop(
            backend: ScriptedBackend([]),
            tools: tools,
            configuration: ToolLoop.Configuration(allowedToolNames: ["sage_inbox", "sage_pipe"])
        )
        let offered = try await loop.availableTools().map(\.name).sorted()
        XCTAssertEqual(offered, ["sage_inbox", "sage_pipe"])
        XCTAssertFalse(offered.contains("sage_forget"), "an irreversible verb must stay out")
    }

    // MARK: Forced summary

    /// The forced-summary turn is an instruction to stop calling tools. It must
    /// not be persisted: leaving a standing "answer without tools" user turn in
    /// the history means the next thing the owner asks gets answered from
    /// nothing instead of hitting SAGE.
    func testForcedSummaryTurnIsNotPersistedIntoTheReturnedHistory() async throws {
        let backend = ScriptedBackend([
            ScriptedBackend.calling("sage_inbox"),
            ScriptedBackend.answering("You have three items.")
        ])
        let tools = StubToolSource(toolNames: ["sage_inbox"], results: ["sage_inbox": "3 items"])
        let loop = makeLoop(
            backend: backend,
            tools: tools,
            configuration: ToolLoop.Configuration(maxIterations: 1, allowedToolNames: [])
        )

        let result = try await loop.run(transcript: "check my inbox")

        XCTAssertEqual(result.reply, "You have three items.")
        XCTAssertFalse(
            result.messages.contains { $0.content == BrainPrompts.forcedSummary },
            "the control message leaked into the history the caller replays"
        )
        // It must still have been *sent*, just not kept.
        XCTAssertTrue(
            backend.requests.last?.messages.contains { $0.content == BrainPrompts.forcedSummary } == true,
            "the wrap-up turn was never actually sent"
        )
    }

    /// The wrap-up turn must withhold tools, or the model can just call more.
    func testForcedSummaryWithholdsTools() async throws {
        let backend = ScriptedBackend([ScriptedBackend.calling("sage_inbox"), ScriptedBackend.answering("Three items.")])
        let tools = StubToolSource(toolNames: ["sage_inbox"])
        let loop = makeLoop(
            backend: backend,
            tools: tools,
            configuration: ToolLoop.Configuration(maxIterations: 1, allowedToolNames: [])
        )

        _ = try await loop.run(transcript: "check my inbox")

        XCTAssertFalse(backend.requests[0].tools.isEmpty, "the first turn should offer tools")
        XCTAssertTrue(backend.requests[1].tools.isEmpty, "the wrap-up turn must withhold them")
    }

    // MARK: Iteration cap

    func testHittingTheIterationCapIsRecordedInTheTrace() async throws {
        let backend = ScriptedBackend([
            ScriptedBackend.calling("sage_inbox", id: "c1"),
            ScriptedBackend.calling("sage_inbox", id: "c2"),
            ScriptedBackend.answering("Three items.")
        ])
        let tools = StubToolSource(toolNames: ["sage_inbox"])
        let loop = makeLoop(
            backend: backend,
            tools: tools,
            configuration: ToolLoop.Configuration(maxIterations: 2, allowedToolNames: [])
        )

        let result = try await loop.run(transcript: "check my inbox")

        XCTAssertTrue(result.trace.hitIterationCap)
        XCTAssertEqual(result.trace.iterations, 2)
        XCTAssertEqual(tools.calls.count, 2, "the loop must stop calling tools at the cap")
    }

    // MARK: Hallucinated tools

    /// A model that invents a tool name recovers if you tell it what it has.
    /// Throwing would end the turn in silence instead.
    func testHallucinatedToolNameIsFedBackAsAnErrorRatherThanThrown() async throws {
        let backend = ScriptedBackend([
            ScriptedBackend.calling("sage_send_email"),
            ScriptedBackend.answering("I can't send email, but your inbox has three items.")
        ])
        let tools = StubToolSource(toolNames: ["sage_inbox"])
        let loop = makeLoop(backend: backend, tools: tools)

        let result = try await loop.run(transcript: "email the mini")

        XCTAssertTrue(tools.calls.isEmpty, "an unknown tool must never reach the tool source")
        XCTAssertEqual(result.trace.toolCalls.count, 1)
        XCTAssertTrue(result.trace.toolCalls[0].failed)
        XCTAssertTrue(result.trace.toolCalls[0].result.contains("no tool named"), result.trace.toolCalls[0].result)
        XCTAssertFalse(result.reply.isEmpty, "the turn must still produce something speakable")
    }

    // MARK: Tool results

    /// A 4B model's context is not the place for a 40 KB memory dump.
    func testOversizedToolResultsAreTruncatedBeforeGoingBackToTheModel() async throws {
        let dump = String(repeating: "m", count: 40_000)
        let backend = ScriptedBackend([ScriptedBackend.calling("sage_recall"), ScriptedBackend.answering("Summarised.")])
        let tools = StubToolSource(toolNames: ["sage_recall"], results: ["sage_recall": dump])
        let loop = makeLoop(
            backend: backend,
            tools: tools,
            configuration: ToolLoop.Configuration(maxToolResultCharacters: 500, allowedToolNames: [])
        )

        _ = try await loop.run(transcript: "what do you remember")

        let sent = try XCTUnwrap(backend.requests.last?.messages.first { $0.role == .tool })
        XCTAssertLessThan(sent.content.count, 700, "the dump reached the model nearly whole")
        XCTAssertTrue(sent.content.contains("truncated"), "truncation must be visible to the model")
    }

    /// Anthropic and OpenAI match a result to its request by id. Dropping the
    /// id here would surface as a 400 from those providers and nowhere else.
    func testToolCallIDIsCarriedOntoTheResultMessage() async throws {
        let backend = ScriptedBackend([
            ScriptedBackend.calling("sage_inbox", id: "toolu_abc"),
            ScriptedBackend.answering("Three items.")
        ])
        let tools = StubToolSource(toolNames: ["sage_inbox"])
        let loop = makeLoop(backend: backend, tools: tools)

        _ = try await loop.run(transcript: "check my inbox")

        let result = try XCTUnwrap(backend.requests.last?.messages.first { $0.role == .tool })
        XCTAssertEqual(result.toolCallID, "toolu_abc")
        XCTAssertEqual(result.toolName, "sage_inbox")
    }

    /// A tool that throws must be reported to the model, not up the stack: the
    /// owner is waiting on a spoken answer and "SAGE said no" is one.
    func testToolFailureIsReportedToTheModelRatherThanEndingTheTurn() async throws {
        struct RefusingSource: ToolProviding {
            func listTools() async throws -> [MCPTool] {
                [MCPTool(name: "sage_pipe", description: "", inputSchema: .object([:]))]
            }
            func call(name: String, arguments: [String: JSONValue]) async throws -> String {
                throw MCPClientError.toolFailed(name, "scope grant required")
            }
        }
        let backend = ScriptedBackend([
            ScriptedBackend.calling("sage_pipe"),
            ScriptedBackend.answering("I don't have permission to message that agent.")
        ])
        let loop = ToolLoop(
            backend: backend,
            mcp: RefusingSource(),
            configuration: ToolLoop.Configuration(allowedToolNames: [])
        )

        let result = try await loop.run(transcript: "tell the mini to stand up")

        XCTAssertTrue(result.trace.toolCalls[0].failed)
        XCTAssertTrue(result.trace.toolCalls[0].result.contains("scope grant"), result.trace.toolCalls[0].result)
        XCTAssertEqual(result.reply, "I don't have permission to message that agent.")
    }

    // MARK: Conversation continuity

    /// The history handed back must be replayable as `history` on the next turn.
    func testReturnedHistoryOmitsTheSystemPromptSoItCanBeReplayed() async throws {
        let backend = ScriptedBackend([ScriptedBackend.answering("Three items."), ScriptedBackend.answering("Two now.")])
        let tools = StubToolSource(toolNames: ["sage_inbox"])
        let loop = makeLoop(backend: backend, tools: tools)

        let first = try await loop.run(transcript: "check my inbox")
        _ = try await loop.run(transcript: "and now?", history: Array(first.messages.dropFirst()))

        let systemTurns = backend.requests[1].messages.filter { $0.role == .system }
        XCTAssertEqual(systemTurns.count, 1, "replaying history must not duplicate the system prompt")
        XCTAssertEqual(systemTurns.first?.content, BrainPrompts.voiceAgentManager)
    }

    // MARK: Empty replies

    /// Reasoning-only output with nothing speakable is a failure, not a reply
    /// of "". Dead air with no error logged is the worst outcome.
    func testAReplyWithNothingSpeakableThrows() async {
        let backend = ScriptedBackend([
            ScriptedBackend.answering("<think>hmm, let me consider that</think>"),
            ScriptedBackend.answering("<think>still thinking</think>")
        ])
        let tools = StubToolSource(toolNames: ["sage_inbox"])
        let loop = makeLoop(backend: backend, tools: tools)

        do {
            _ = try await loop.run(transcript: "check my inbox")
            XCTFail("expected .emptyReply")
        } catch let error as ToolLoopError {
            XCTAssertEqual(error, .emptyReply)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// Reasoning must never be spoken, even when the model emits it inline.
    func testReasoningIsStrippedFromTheSpokenReply() async throws {
        let backend = ScriptedBackend([
            ScriptedBackend.answering("<think>the owner means the mini</think>You have three items.")
        ])
        let tools = StubToolSource(toolNames: ["sage_inbox"])
        let loop = makeLoop(backend: backend, tools: tools)

        let result = try await loop.run(transcript: "check my inbox")
        XCTAssertEqual(result.reply, "You have three items.")
    }

    /// An empty catalogue means the brain has nothing to drive; say so rather
    /// than letting the model improvise answers about the owner's agents.
    func testNoToolsIsAnError() async {
        let loop = makeLoop(backend: ScriptedBackend([]), tools: StubToolSource(toolNames: []))
        do {
            _ = try await loop.run(transcript: "check my inbox")
            XCTFail("expected .noTools")
        } catch let error as ToolLoopError {
            XCTAssertEqual(error, .noTools)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
