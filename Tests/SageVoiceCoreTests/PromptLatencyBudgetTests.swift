import XCTest
@testable import SageVoiceCore

/// Latency regression tests for the prompt itself.
///
/// Every optimisation this appliance has had was to the *prompt*, not the model:
/// sorting JSON keys so the prefix cache stops missing (turn 28.9 s → 11.0 s),
/// cutting the catalogue from 27 tools to 14 (routing 5/12 → 12/12), planting a
/// checkpoint where the next turn begins (10.76 s → 0.33 s on the synthetic
/// measurement). Not one of those had a test, and none of them can fail loudly:
/// a prompt that has quietly stopped being cacheable still returns the right
/// answer, just twenty seconds later, and the owner reports it as "feels slow"
/// weeks after whoever caused it moved on.
///
/// So these assert on the two things that decide a turn's cost before the model
/// is even reached — how many bytes the prompt is, and whether consecutive turns
/// share a byte-identical prefix — and they carry the measured numbers they were
/// set from, so a future change can argue with the budget instead of guessing.
///
/// What they cannot do is measure seconds. A wall-clock assertion on a machine
/// under load is a flaky test, and a flaky latency test gets deleted. These
/// measure the inputs to latency, which are deterministic.
final class PromptLatencyBudgetTests: XCTestCase {

    // MARK: - Size budgets

    /// The system prompt is the front of every prompt, so it is prefilled on
    /// every cold turn and occupies context on every warm one.
    ///
    /// Measured at the time of writing: 5,724 characters, about 1,430 tokens.
    ///
    /// Raised from 6,000 to 8,000, and the reason it exists changed with it.
    ///
    /// It was set as a *latency* budget: cold prefill runs at roughly 130 tok/s,
    /// so every 500 characters is about a second of the owner's morning. That
    /// framing turned out to overstate the cost badly. The system prompt is the
    /// most cacheable thing in the request — byte-identical on every turn, at the
    /// very front of the prefix — so on a warm appliance it is prefilled once and
    /// then costs nothing. `num_ctx` is 65536 precisely so those prefixes stay
    /// resident. Growing it is close to free in seconds.
    ///
    /// What it is *not* free in is attention. Every rule added to a 4B model is
    /// another instruction competing for the same limited capacity to follow any
    /// of them, and that cost does not show up in a character count, a token
    /// count, or a stopwatch. It shows up as a tool call that should have
    /// happened and did not.
    ///
    /// So this is now a sprawl budget. It leaves room for the rules still owed —
    /// `sage_forget` on correction, documents written in full — while keeping
    /// the failure that starts the argument. When it fires, the question to ask
    /// is not "can we afford the prefill" (yes) but "is this rule earning its
    /// place against the ones already here", which is the question that actually
    /// matters and the one a latency framing was hiding.
    ///
    /// **8,000 to 8,300 on 7 August, for the directory-scope rule.** Asked what
    /// was on the network, Mynah read a local-only roster and answered "No
    /// federated SAGEs connected" while a federated peer sat on another Mac. The
    /// rule that fixes it has two halves and both are load-bearing: always pass
    /// `{"scope":"all"}`, and *say so* when the reply is incomplete. The second
    /// half is what cost the 271 characters, because a model told to report
    /// `"complete": false` has to be shown what that looks like and what to say
    /// — a rule stated abstractly gets paraphrased away by a 4B.
    ///
    /// It earns its place on the test this comment sets: the rules it competes
    /// with are guarding failures that were *reported*, and so is this one. The
    /// owner made the call with the cost stated.
    static let systemPromptCharacterBudget = 8_300

    func testTheSystemPromptStaysWithinItsPrefillBudget() {
        let count = BrainPrompts.voiceAgentManager.count
        XCTAssertLessThanOrEqual(
            count,
            Self.systemPromptCharacterBudget,
            """
            The system prompt is \(count) characters, over the \(Self.systemPromptCharacterBudget) budget, \
            roughly \(count / 4) tokens. **This is a sprawl budget, not a latency one** — read the comment \
            on systemPromptCharacterBudget before reacting to that number. The prompt is byte-identical \
            every turn and sits at the front of the prefix, so it caches and costs close to nothing in \
            seconds. What it costs is a 4B's attention: every rule here competes with every other rule \
            for the same limited capacity to follow any of them. So the question is not "can we afford \
            this" but "is this rule earning its place against the ones already here". Cut something or \
            move the budget deliberately — but move it in the same commit, with the reason.
            """
        )
    }

    /// Catalogue size, not prompt wording, was the dominant factor in routing
    /// accuracy for this model: 27 tools scored 5–6/12 where 14 scored 12/12.
    /// Every tool also carries its schema into the prefill.
    ///
    /// 18 was where the note tools left it. It is now 20, and this is the "raise
    /// this line and say why" the paragraph below always asked for.
    ///
    /// **Re-measured 2026-07-31, qwen3.5:4b, via `scripts/measure-tool-routing.py`
    /// with `SYSTEM_PROMPT_FILE` set to the real 7,644-character voice prompt:**
    ///
    ///     curated(16 SAGE tools) = 9/12
    ///     full(27 SAGE tools)    = 9/12     delta +0
    ///
    /// So the claim this budget was built on — 27 tools = 5–6/12, 14 = 12/12 —
    /// **did not reproduce**, and adding `sage_corroborate` and `sage_link` cost
    /// no measured accuracy. Two things are now true and should not be conflated:
    /// the two new tools are paid for, and the original degradation is in doubt.
    ///
    /// What this run does NOT establish, stated so nobody quotes it as more than
    /// it is: neither set scored 12/12, so this is not the same measurement the
    /// old numbers came from and something differs beyond tool count. The
    /// per-turn latency it printed is worthless for comparison — curated ran
    /// first on a cold model and full ran second on a warm one, which is exactly
    /// the confound the script's own header warns about. And it is one sample per
    /// utterance at temperature 0.
    ///
    /// The budget still has no headroom, on purpose. Tool twenty-one turns this
    /// red and whoever adds it re-runs the script.
    static let voiceCatalogueBudget = 20

    func testTheVoiceCatalogueDoesNotSilentlyGrow() {
        let count = BrainPrompts.voiceToolAllowlist.count
        XCTAssertLessThanOrEqual(
            count,
            Self.voiceCatalogueBudget,
            """
            The voice catalogue is \(count) tools, over the \(Self.voiceCatalogueBudget) budget. \
            Routing accuracy was last measured at 14 tools (12/12) and 27 tools (5-6/12); adding to \
            this without re-measuring spends accuracy nobody has counted.
            """
        )
    }

    /// The schemas this repository owns — the ones SAGE does not publish — go
    /// into the same prefill as the prompt above.
    ///
    /// Measured against the tool sources rather than a hardcoded string, so a
    /// verbose description added to `NotesToolSource` shows up here rather than
    /// in a "feels slower" report from a phone.
    static let ownedToolSchemaByteBudget = 3_000

    func testOurOwnToolSchemasStayWithinTheirPrefillBudget() async throws {
        let published = try await NotesToolSource(directory: Self.scratchDirectory()).listTools()
            + WebSearchToolSource(backends: []).listTools()

        let bytes = try PromptStableJSON.data(from: published.map(\.brainTool.ollamaWireObject)).count
        XCTAssertLessThanOrEqual(
            bytes,
            Self.ownedToolSchemaByteBudget,
            """
            The tool schemas this repo owns are \(bytes) bytes, over the \(Self.ownedToolSchemaByteBudget) \
            budget. Descriptions are prompt text: they are prefilled on every cold turn and they compete \
            with the owner's question for a 4B model's attention.
            """
        )
    }

    // MARK: - Prefix stability

    /// The invariant the whole cache rests on: the anchor turn's prompt must be
    /// a byte-exact prefix of the next real turn's prompt.
    ///
    /// This is the mechanism of the checkpoint fix, and it is the one most
    /// likely to break by accident, because nothing about it is local. Change
    /// how `conversationOnly` shapes history, or let the system prompt differ by
    /// a space between the anchor and the turn, and the checkpoint lands on a
    /// sequence the next turn never asks for. Measured cost of getting this
    /// wrong: a prompt matching the cache to 99.7% re-evaluated 2,401 tokens and
    /// spent 11.4 s doing it.
    ///
    /// Nothing else in the suite would notice. The reply is identical either way.
    func testTheAnchorIsAByteExactPrefixOfTheTurnThatFollowsIt() async throws {
        let tools = [
            MCPTool(name: "sage_recall", description: "recall", inputSchema: .object(["type": .string("object")]))
        ]

        // Turn one, then the history the daemon would keep from it.
        let firstBackend = ScriptedReplayBackend([.answering("Daikanyama, November 14th.")])
        let firstLoop = Self.makeLoop(backend: firstBackend, tools: tools)
        let first = try await firstLoop.run(
            transcript: "where can I perform in Japan",
            tools: tools,
            history: []
        )
        let history = VoiceBridgeDaemon.trimmed(
            VoiceBridgeDaemon.conversationOnly(first.messages),
            keepingLastTurns: 16
        )
        XCTAssertFalse(history.isEmpty, "the rest of this test proves nothing on an empty history")

        // The anchor the daemon plants after replying.
        let anchorBackend = ScriptedReplayBackend([.answering("")])
        let anchorLoop = Self.makeLoop(backend: anchorBackend, tools: tools)
        _ = await anchorLoop.anchorPromptCache(history: history, tools: tools)
        let anchor = try XCTUnwrap(anchorBackend.requests.first)

        // The next real turn, starting from that same history.
        let nextBackend = ScriptedReplayBackend([.answering("Here are the links.")])
        let nextLoop = Self.makeLoop(backend: nextBackend, tools: tools)
        _ = try await nextLoop.run(
            transcript: "can you give me links for these please",
            tools: tools,
            history: history
        )
        let next = try XCTUnwrap(nextBackend.requests.first)

        XCTAssertEqual(
            anchor.messages.count + 1,
            next.messages.count,
            "the next turn should be the anchor plus exactly the owner's new sentence"
        )
        for (index, anchored) in anchor.messages.enumerated() {
            XCTAssertEqual(
                try PromptStableJSON.data(from: anchored.ollamaWireObject),
                try PromptStableJSON.data(from: next.messages[index].ollamaWireObject),
                "message \(index) differs between the anchor and the turn it was meant to warm"
            )
        }
        XCTAssertEqual(
            try PromptStableJSON.data(from: anchor.tools.map(\.ollamaWireObject)),
            try PromptStableJSON.data(from: next.tools.map(\.ollamaWireObject)),
            "the catalogue differs between the anchor and the turn, so the checkpoint lands nowhere useful"
        )
    }

    /// Within one turn the loop calls the model repeatedly, and each call should
    /// extend the last rather than rewrite it — otherwise a tool-using turn pays
    /// full prefill two or three times over.
    func testEachIterationOfATurnExtendsThePreviousPromptRatherThanReplacingIt() async throws {
        let tools = [
            MCPTool(name: "web_search", description: "search", inputSchema: .object(["type": .string("object")]))
        ]
        let backend = ScriptedReplayBackend([
            .calling("web_search", arguments: ["query": .string("modular tokyo")]),
            .answering("Festival of Modular, Daikanyama.")
        ])
        let loop = Self.makeLoop(
            backend: backend,
            tools: tools,
            results: ["web_search": "1. Festival of Modular\n   https://tfom.info/"]
        )
        _ = try await loop.run(transcript: "where can I perform", tools: tools, history: [])

        XCTAssertGreaterThanOrEqual(backend.requests.count, 2, "expected a tool call and an answer")
        for (index, request) in backend.requests.enumerated().dropFirst() {
            let previous = backend.requests[index - 1]
            XCTAssertGreaterThan(request.messages.count, previous.messages.count)
            for (position, earlier) in previous.messages.enumerated() {
                XCTAssertEqual(
                    try PromptStableJSON.data(from: earlier.ollamaWireObject),
                    try PromptStableJSON.data(from: request.messages[position].ollamaWireObject),
                    "iteration \(index) rewrote message \(position); everything after it re-prefills"
                )
            }
        }
    }

    /// The same turn, built twice, must be the same bytes.
    ///
    /// The end-to-end version of `PromptStableJSONTests`, which proves the
    /// helper sorts but not that the real prompt goes through it. This one is
    /// built from the actual system prompt and actual tool schemas, which is
    /// where the ordering bug lived: nested two levels down inside `inputSchema`,
    /// not at the top level anyone was looking at.
    func testTheSameTurnSerialisesToTheSameBytesTwice() async throws {
        let tools = try await NotesToolSource(directory: Self.scratchDirectory()).listTools()

        func body() async throws -> Data {
            let backend = ScriptedReplayBackend([.answering("ok")])
            let loop = Self.makeLoop(backend: backend, tools: tools)
            _ = try await loop.run(transcript: "write that down", tools: tools, history: [])
            let request = try XCTUnwrap(backend.requests.first)
            return try PromptStableJSON.data(from: [
                "messages": request.messages.map(\.ollamaWireObject),
                "tools": request.tools.map(\.ollamaWireObject)
            ])
        }

        let once = try await body()
        let twice = try await body()
        XCTAssertEqual(once, twice)
    }

    // MARK: - Helpers

    private static func makeLoop(
        backend: BrainBackend,
        tools: [MCPTool],
        results: [String: String] = [:]
    ) -> ToolLoop {
        ToolLoop(
            backend: backend,
            mcp: ReplayToolSource(tools: tools, results: results),
            configuration: ToolLoop.Configuration(systemPrompt: BrainPrompts.voiceAgentManager)
        )
    }

    private static func scratchDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prompt-budget-\(UUID().uuidString)", isDirectory: true)
    }
}

// MARK: - Doubles

/// `ToolLoopTests` has an equivalent, but it is `private` to that file and these
/// assertions are about a different property, so duplicating twenty lines beats
/// coupling two suites through a shared stub that then has to serve both.
private final class ScriptedReplayBackend: BrainBackend, @unchecked Sendable {
    let identifier = "scripted"
    let modelName = "stub-model"
    let isLocal = true

    private let lock = NSLock()
    private var script: [BrainReply]
    private var recorded: [BrainRequest] = []

    var requests: [BrainRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    init(_ script: [BrainReply]) {
        self.script = script
    }

    func isAvailable() async -> Bool { true }

    func complete(_ request: BrainRequest) async throws -> BrainReply {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(request)
        guard !script.isEmpty else {
            return .answering("")
        }
        return script.removeFirst()
    }
}

private extension BrainReply {
    static func answering(_ text: String) -> BrainReply {
        BrainReply(
            model: "stub-model",
            message: .assistant(text),
            stopReason: .endTurn,
            usage: BrainUsage(inputTokens: 10, outputTokens: 5)
        )
    }

    static func calling(_ name: String, arguments: [String: JSONValue] = [:]) -> BrainReply {
        BrainReply(
            model: "stub-model",
            message: BrainMessage(
                role: .assistant,
                content: "",
                toolCalls: [BrainToolCall(id: "call_1", name: name, arguments: arguments)]
            ),
            stopReason: .toolUse,
            usage: BrainUsage(inputTokens: 10, outputTokens: 5)
        )
    }
}

private final class ReplayToolSource: ToolProviding, @unchecked Sendable {
    private let tools: [MCPTool]
    private let results: [String: String]

    init(tools: [MCPTool], results: [String: String]) {
        self.tools = tools
        self.results = results
    }

    func listTools() async throws -> [MCPTool] { tools }

    func call(name: String, arguments: [String: JSONValue]) async throws -> String {
        results[name] ?? "ok"
    }
}

// MARK: - What the model is told it cannot see

/// The prompt has to correct a belief the model will otherwise hold.
///
/// The owner asked *"anything in the inbox?"* and Mynah answered *"Still
/// nothing — Codex hasn't replied to the 11.16.4 question yet."* The first half
/// was true and the second was invented: `sage_inbox` holds messages addressed
/// *to* this agent and by SAGE's own definition does not contain replies to
/// work it sent, so an empty inbox says nothing whatever about whether anyone
/// answered. The model read one and reported the other, confidently, twice.
final class InboxScopePromptTests: XCTestCase {

    private var prompt: String { BrainPrompts.voiceAgentManager }

    func testItIsToldTheInboxDoesNotHoldReplies() {
        XCTAssertTrue(
            prompt.contains("sage_inbox does not hold replies to work you sent"),
            "without this the model treats an empty inbox as proof nobody answered"
        )
    }

    func testItIsForbiddenFromSayingAnAgentHasNotReplied() {
        // The specific false sentence, named. A general "do not speculate"
        // would not have stopped it, because from the model's side this did not
        // feel like speculation — it had just read a tool result.
        XCTAssertTrue(prompt.contains("NEVER say a named agent has not replied"))
    }

    func testItIsToldToStopRepeatingAnUnchangedAnswer() {
        XCTAssertTrue(prompt.contains("If nothing changed since your last answer"))
    }
}
