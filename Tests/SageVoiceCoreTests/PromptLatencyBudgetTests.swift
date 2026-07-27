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
    /// Measured at the time of writing: 5,100 characters, about 1,275 tokens.
    /// Cold prefill on the appliance runs at roughly 130 tok/s, so this is ~10 s
    /// of the owner's morning every time the model has been evicted, and it grew
    /// three times in one day — a vision section, a notes section and a
    /// pronoun-resolution section — with nobody watching the total.
    ///
    /// The budget is deliberately close, not generous: 900 characters of room,
    /// about one more section. It is a conversation starter, not a wall — if a
    /// change needs more than this, the right move is usually to cut something
    /// that stopped earning its place, and the failure is where that
    /// conversation happens.
    static let systemPromptCharacterBudget = 6_000

    func testTheSystemPromptStaysWithinItsPrefillBudget() {
        let count = BrainPrompts.voiceAgentManager.count
        XCTAssertLessThanOrEqual(
            count,
            Self.systemPromptCharacterBudget,
            """
            The system prompt is \(count) characters, over the \(Self.systemPromptCharacterBudget) budget. \
            That is roughly \(count / 4) tokens on every cold turn, about \(count / 4 / 130) seconds of \
            prefill before the model has read a word of the owner's question. Cut something or move the \
            budget deliberately — but move it in the same commit, with the reason.
            """
        )
    }

    /// Catalogue size, not prompt wording, was the dominant factor in routing
    /// accuracy for this model: 27 tools scored 5–6/12 where 14 scored 12/12.
    /// Every tool also carries its schema into the prefill.
    ///
    /// 18 is where the note tools left it, and the budget is 18 — no headroom at
    /// all, on purpose. 18 has only been spot-checked (6/6 on the appliance),
    /// not run against the 12-utterance set those numbers come from, so the next
    /// tool added turns this red and whoever adds it has to either measure
    /// properly or raise this line and say why. That is the whole point: the
    /// cost of tool nineteen is unknown, and it should not be possible to spend
    /// it without noticing.
    static let voiceCatalogueBudget = 18

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
