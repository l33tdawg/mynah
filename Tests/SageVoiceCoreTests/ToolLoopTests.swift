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

    /// One reply asking for several tools at once, which is what the
    /// per-iteration cap exists to bound.
    static func callingMany(_ name: String, count: Int) -> BrainReply {
        BrainReply(
            model: "stub-model",
            message: BrainMessage(
                role: .assistant,
                content: "",
                toolCalls: (0..<count).map {
                    BrainToolCall(id: "call_\($0)", name: name, arguments: [:])
                }
            ),
            stopReason: .toolUse,
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

    // MARK: The per-iteration tool cap

    /// Every tool call the model makes gets an answer, including the ones the
    /// cap refuses to run.
    ///
    /// The assistant message carries all of them. Running three of five and
    /// appending three results leaves a conversation the API rejects outright —
    /// "an assistant message with tool_calls must be followed by tool messages
    /// responding to each tool_call_id" — and because the failure is in the
    /// history rather than the request, every later turn in that thread fails
    /// the same way. Observed live as "Something went wrong talking to the
    /// model" in reply to an ordinary voice note.
    func testCappedToolCallsStillGetAResult() async throws {
        let asked = ToolLoop.maximumToolCallsPerIteration + 2
        let backend = ScriptedBackend([
            ScriptedBackend.callingMany("remember", count: asked),
            ScriptedBackend.answering("Done.")
        ])
        let tools = StubToolSource(toolNames: ["remember"], results: ["remember": "ok"])

        let result = try await makeLoop(backend: backend, tools: tools).run(transcript: "do it all")

        let answered = result.messages.filter { $0.role == .tool }.count
        XCTAssertEqual(
            answered, asked,
            "the model asked for \(asked) tools and \(answered) got results; an assistant "
                + "message with unanswered tool_calls poisons every later turn in the thread"
        )
        XCTAssertEqual(result.trace.droppedToolCalls, asked - ToolLoop.maximumToolCallsPerIteration)
    }

    /// The dropped ones must say why, rather than looking like an empty result.
    ///
    /// A stub saying nothing tells the model the tool is empty; this tells it
    /// the call was refused for volume, which is the difference between asking
    /// again and concluding there is nothing there.
    func testARefusedToolCallSaysItWasNotRun() async throws {
        let backend = ScriptedBackend([
            ScriptedBackend.callingMany("remember", count: ToolLoop.maximumToolCallsPerIteration + 1),
            ScriptedBackend.answering("Done.")
        ])
        let tools = StubToolSource(toolNames: ["remember"], results: ["remember": "ok"])

        let result = try await makeLoop(backend: backend, tools: tools).run(transcript: "do it all")

        let refused = result.messages.filter { $0.role == .tool && $0.content.contains("Not run") }
        XCTAssertEqual(refused.count, 1, "the dropped call was answered with something else")
    }

    // MARK: Prompt-cache stability

    /// The catalogue must come back in the same order every time, whatever
    /// order the server sent it in.
    ///
    /// This is a latency test wearing a correctness test's clothes. SAGE builds
    /// `tools/list` by iterating a Go map, which Go randomises on purpose — so
    /// the same 14 tools arrive shuffled on every fetch. Those schemas are
    /// rendered into the front of the prompt, so a reshuffle changes the prompt
    /// from roughly its first token, llama.cpp's prefix cache matches nothing,
    /// and the appliance re-prefills ~3,500 tokens at about 16 seconds a go.
    /// Measured in `ollama.log`: `matched=3012` cost 0.4 s, `matched=1` cost
    /// 16.4 s, on prompts of the same size.
    func testCatalogueOrderIsStableRegardlessOfServerOrder() async throws {
        let names = ["sage_recall", "sage_remember", "sage_task", "web_search"]
        let forward = StubToolSource(toolNames: names)
        let reversed = StubToolSource(toolNames: names.reversed())

        let fromForward = try await makeLoop(backend: ScriptedBackend([]), tools: forward)
            .availableTools().map(\.name)
        let fromReversed = try await makeLoop(backend: ScriptedBackend([]), tools: reversed)
            .availableTools().map(\.name)

        XCTAssertEqual(fromForward, fromReversed, "a reshuffled server reply must not reshuffle the prompt")
        XCTAssertEqual(fromForward, names.sorted())
    }

    /// The allowlist path must sort too — it is the one the appliance runs.
    func testAllowlistedCatalogueIsAlsoStablyOrdered() async throws {
        let tools = StubToolSource(toolNames: ["web_search", "sage_task", "sage_recall", "sage_forget"])
        let loop = makeLoop(
            backend: ScriptedBackend([]),
            tools: tools,
            configuration: ToolLoop.Configuration(allowedToolNames: ["sage_recall", "sage_task", "web_search"])
        )

        let names = try await loop.availableTools().map(\.name)
        XCTAssertEqual(names, ["sage_recall", "sage_task", "web_search"])
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

/// Regression tests for the conversation-history bug found on the live
/// appliance: after one tool call, later turns stopped calling tools at all and
/// recycled the previous answer.
final class DaemonHistoryTests: XCTestCase {

    /// Observed on the Mini: turn 2 called `sage_federation` and answered;
    /// turns 3-5 called NO tools and reused that answer — including for
    /// "Can you save a memory?", which should have written one. With last
    /// turn's tool output in context a 4B model answers from it instead of
    /// asking again, so the appliance goes stale exactly when the SAGE node
    /// changes — which is the entire job of an agent manager.
    func testToolCallsAndResultsAreNotCarriedIntoTheNextTurn() {
        let finished: [BrainMessage] = [
            .system("prompt"),
            .user("Are you connected to sage?"),
            BrainMessage(role: .assistant, content: "", toolCalls: [
                BrainToolCall(id: "c1", name: "sage_federation", arguments: [:])
            ]),
            .toolResult(name: "sage_federation", content: "{\"peers\":0}", id: "c1"),
            .assistant("You're connected; federation shows zero peers.")
        ]

        let carried = VoiceBridgeDaemon.conversationOnly(finished)

        XCTAssertEqual(carried.map(\.role), [.user, .assistant])
        XCTAssertFalse(
            carried.contains { !$0.toolCalls.isEmpty },
            "a stale tool call must not reach the next turn"
        )
        XCTAssertFalse(
            carried.contains { $0.role == .tool },
            "a stale tool RESULT must not reach the next turn"
        )
        XCTAssertFalse(
            carried.contains { $0.content.contains("{\"peers\"") },
            "the raw tool payload must not reach the next turn"
        )
        XCTAssertEqual(carried.last?.content, "You're connected; federation shows zero peers.")
    }

    /// The system prompt is prepended fresh by ToolLoop every turn; carrying it
    /// would duplicate it.
    func testSystemPromptIsNotCarried() {
        let carried = VoiceBridgeDaemon.conversationOnly([.system("prompt"), .user("hi")])
        XCTAssertEqual(carried.count, 1)
        XCTAssertEqual(carried.first?.role, .user)
    }

    /// The estimate quoted to the owner must ignore a single slow outlier.
    func testDurationEstimateUsesMedianNotMean() {
        var estimator = TurnDurationEstimator()
        [20.0, 22.0, 21.0, 300.0].forEach { estimator.record($0) }
        let typical = estimator.typicalSeconds ?? 0
        XCTAssertLessThan(typical, 60, "one 300s recall must not make every reply promise minutes")
    }

    /// Under ten seconds, an estimate is noise — the answer arrives before the
    /// owner finishes reading it.
    func testNoDurationHintForFastTurns() {
        XCTAssertNil(WaitingPhrases.durationHint(4))
        XCTAssertNotNil(WaitingPhrases.durationHint(25))
    }

    func testPhrasePoolIsLargeAndUnique() {
        XCTAssertGreaterThanOrEqual(WaitingPhrases.all.count, 100)
        XCTAssertEqual(Set(WaitingPhrases.all).count, WaitingPhrases.all.count, "duplicates")
    }
}

/// Two defaults that are product decisions rather than implementation details,
/// both made after watching the appliance be used from Note-to-Self.
final class DaemonPresentationTests: XCTestCase {

    /// Signal draws Note-to-Self as a single column of the owner's own bubbles,
    /// so an acknowledgement is not reassurance — it is a third identical blue
    /// bubble between the question and the answer.
    func testAcknowledgementsAreOffByDefault() {
        XCTAssertFalse(VoiceBridgeDaemon.Configuration().sendsThinkingAcknowledgement)
    }

    /// The only thing that can distinguish speaker from appliance in a
    /// one-sided thread is the text itself.
    func testRepliesAreMarkedAsComingFromTheAppliance() {
        let prefix = VoiceBridgeDaemon.Configuration().replyPrefix
        XCTAssertFalse(prefix.isEmpty)
        XCTAssertTrue(prefix.hasSuffix(" "), "the marker must not run into the first word")
    }

    /// Kept switchable rather than deleted: on a thread with a real second
    /// party the original argument for acknowledgements comes back.
    func testAcknowledgementsCanStillBeTurnedOn() {
        let configuration = VoiceBridgeDaemon.Configuration(sendsThinkingAcknowledgement: true)
        XCTAssertTrue(configuration.sendsThinkingAcknowledgement)
    }
}

// MARK: - Links the owner can actually tap

/// Signal renders plain text and linkifies bare URLs; it does not parse
/// markdown. These are the exact replies that failed on the appliance.
final class SpeakableLinkTests: XCTestCase {

    /// The real one. A maps link, on a phone, that could not be tapped.
    func testMarkdownMapsLinkBecomesATappableEncodedURL() {
        let raw = "Here's a direct Google Maps link: "
            + "[Google Maps](https://www.google.com/maps/search/?query=日枝あかさか+山王茶寮)"
        let spoken = ToolLoop.speakable(raw)

        XCTAssertFalse(spoken.contains("[Google Maps]"), "markdown wrapper must go — Signal cannot parse it")
        XCTAssertFalse(spoken.contains("]("), "no markdown link syntax may survive")
        XCTAssertTrue(spoken.contains("https://www.google.com/maps/search/?query="))
        XCTAssertFalse(
            spoken.contains("日"),
            "raw non-ASCII in a URL truncates Signal's linkifier mid-address"
        )
        XCTAssertTrue(spoken.contains("%E6%97%A5"), "Japanese must survive as percent-encoded UTF-8")
        // The `+` is a legal query separator and must NOT be encoded away.
        XCTAssertTrue(spoken.contains("+"))
    }

    /// A URL the model wrote without markdown still needs encoding.
    func testBareURLWithNonASCIIIsEncoded() {
        let spoken = ToolLoop.speakable("Try https://example.com/search?q=山王茶寮 for more.")
        XCTAssertTrue(spoken.contains("%E5%B1%B1"))
        XCTAssertTrue(spoken.hasSuffix("for more."))
    }

    /// An already-encoded URL must not be encoded twice into nonsense.
    func testAlreadyEncodedURLIsLeftAlone() {
        let url = "https://www.google.com/maps/search/?query=%E5%B1%B1%E7%8E%8B"
        XCTAssertTrue(ToolLoop.speakable("See \(url)").contains(url))
    }

    /// Ordinary ASCII links must pass through untouched.
    func testPlainURLIsUnchanged() {
        let url = "https://github.com/l33tdawg/sage"
        XCTAssertTrue(ToolLoop.speakable("Repo: \(url)").contains(url))
    }
}
