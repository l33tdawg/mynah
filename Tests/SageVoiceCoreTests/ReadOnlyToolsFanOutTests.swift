import XCTest
@testable import SageVoiceCore

/// **Reads asked for together are run together; everything else runs alone.**
///
/// The owner's complaint about a half-done job produced the fan-out *width* fix
/// — `maximumToolCallsPerIteration` went from three to twelve so a reply asking
/// for four corrections got four. This is the other half of the same sentence:
/// *"its better the agent does all the jobs and takes longer than reply with a
/// half done task"*. Doing all the jobs sequentially, when three of them are
/// independent reads against one Go process, spends the owner's wait on nothing.
///
/// **Scoped to `ToolLoopTrace.readOnlyTools`, whose inversion is what makes
/// this safe.** A tool nobody listed — including a name the model invented —
/// counts as having acted and therefore runs alone, in order. The failure mode
/// of a missing entry is a lost speed-up, never two writes racing.
final class ReadOnlyToolsFanOutTests: XCTestCase {

    // MARK: Grouping

    /// The grouping is asserted directly rather than only through wall clock: a
    /// test that pins timings on a shared CI box is a test that fails for
    /// reasons nobody caused. The timing test below still exists, with generous
    /// margins, because grouping that never actually overlaps is not fan-out.
    func testConsecutiveReadsShareABatchAndWritesDoNot() {
        let groups = ToolLoop.concurrentGroups(of: [
            call("sage_recall"), call("sage_recall"),
            call("sage_remember"),
            call("web_search")
        ])

        XCTAssertEqual(groups.map(\.count), [2, 1, 1])
        XCTAssertEqual(groups[0].map(\.name), ["sage_recall", "sage_recall"])
        XCTAssertEqual(groups[1].map(\.name), ["sage_remember"])
        XCTAssertEqual(groups[2].map(\.name), ["web_search"])
    }

    /// **Order-preserving, not reads-first.** `[remember(X), recall()]` is a
    /// legal thing for a model to ask for, and hoisting the recall above the
    /// write would silently change what it returns. Reordering a model's work is
    /// not an optimisation, it is a different request.
    func testAReadAfterAWriteIsNotHoistedAboveIt() {
        let groups = ToolLoop.concurrentGroups(of: [
            call("sage_remember"), call("sage_recall")
        ])
        XCTAssertEqual(groups.map { $0.map(\.name) }, [["sage_remember"], ["sage_recall"]])
    }

    /// Width is capped under the per-iteration ceiling: a fifth consecutive read
    /// opens a second batch rather than widening the first.
    func testTheBatchWidthIsCapped() {
        let groups = ToolLoop.concurrentGroups(of: Array(repeating: call("sage_recall"), count: 9))
        XCTAssertEqual(groups.map(\.count), [4, 4, 1])
        XCTAssertEqual(ToolLoop.maximumConcurrentReadOnlyCalls, 4)
        XCTAssertLessThan(
            ToolLoop.maximumConcurrentReadOnlyCalls,
            ToolLoop.maximumToolCallsPerIteration,
            "the width cap must sit under the runaway backstop"
        )
    }

    /// **The inverted list still governs.** A name absent from `readOnlyTools`
    /// never shares a batch, which is the property that makes an unknown tool
    /// safe rather than dangerous.
    func testAnUnknownToolIsTreatedAsAWriteAndRunsAlone() {
        let groups = ToolLoop.concurrentGroups(of: [
            call("sage_recall"), call("a_tool_nobody_listed"), call("sage_recall")
        ])
        XCTAssertEqual(groups.map(\.count), [1, 1, 1])
    }

    // MARK: Running

    /// Three reads that each sleep finish in well under the sequential time, and
    /// the source's own high-water mark shows they genuinely overlapped.
    func testThreeReadsRunAtTheSameTime() async throws {
        let tools = ConcurrencyWatchingToolSource(seconds: 0.4)
        let loop = ToolLoop(
            backend: ScriptedBackend(names: ["sage_recall", "sage_recall", "sage_recall"]),
            mcp: tools,
            configuration: ToolLoop.Configuration(
                maxIterations: 1, deadlineSeconds: nil, allowedToolNames: []
            )
        )

        let started = Date()
        let result = try await loop.run(transcript: "what shops did we talk about")
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(tools.peakConcurrency, 3, "the reads were still run one at a time")
        XCTAssertEqual(result.trace.toolCalls.count, 3)
        XCTAssertEqual(result.trace.concurrentToolCalls, 3)
        // Sequential would be ~1.2 s. Deliberately generous: this asserts that
        // overlap happened, never a precise duration.
        XCTAssertLessThan(elapsed, 1.0, "three 0.4s reads took \(elapsed)s — they did not overlap")
    }

    /// **A write never runs beside anything.** Against SAGE a tool call can be
    /// an on-chain write, so "confused model" and "consensus load" are the same
    /// sentence — and a consensus-ledger `remember`/`forget` pair must still go
    /// strictly one at a time, in the order asked.
    func testAWriteNeverRunsBesideAnything() async throws {
        let tools = ConcurrencyWatchingToolSource(seconds: 0.15)
        let loop = ToolLoop(
            backend: ScriptedBackend(names: ["sage_recall", "sage_remember", "sage_recall"]),
            mcp: tools,
            configuration: ToolLoop.Configuration(
                maxIterations: 1, deadlineSeconds: nil, allowedToolNames: []
            )
        )

        let result = try await loop.run(transcript: "fix that and then check it")

        XCTAssertEqual(tools.peakConcurrency, 1, "a write shared a batch")
        XCTAssertEqual(result.trace.concurrentToolCalls, 0, "no batch had more than one member")
        // Strictly serialised, in the model's order: each call must have started
        // only after the previous one finished.
        XCTAssertEqual(tools.order, ["sage_recall", "sage_remember", "sage_recall"])
        XCTAssertTrue(tools.wasStrictlySequential, "the calls overlapped in time")
    }

    /// Every requested call is answered exactly once, in the order it was asked
    /// — the invariant a cap broke once already, observed live as "Something
    /// went wrong talking to the model" on a voice note. Anthropic refuses a
    /// thread with an unanswered `tool_use`, and a prompt prefix whose byte
    /// order depends on which tool won a race never hits the cache twice.
    func testEveryToolCallStillGetsExactlyOneResultInTheOrderItWasAsked() async throws {
        let names = ["sage_recall", "sage_backlog", "sage_inbox", "sage_timeline"]
        // **Completion order is deliberately the reverse of call order.** With
        // equal sleeps a bug that appends results as they land would pass on a
        // quiet machine and fail on a busy one, which is worse than no test.
        let loop = ToolLoop(
            backend: ScriptedBackend(names: names),
            mcp: ConcurrencyWatchingToolSource(seconds: 0.05, delays: [
                "sage_recall": 0.40,
                "sage_backlog": 0.30,
                "sage_inbox": 0.20,
                "sage_timeline": 0.05
            ]),
            configuration: ToolLoop.Configuration(
                maxIterations: 1, deadlineSeconds: nil, allowedToolNames: []
            )
        )

        let result = try await loop.run(transcript: "catch me up")

        XCTAssertEqual(result.trace.toolCalls.map(\.name), names, "results came back out of order")
        let ids = result.messages.filter { $0.role == .tool }.compactMap(\.toolCallID)
        XCTAssertEqual(ids, names.indices.map { "call_\($0)" })
        XCTAssertEqual(Set(ids).count, ids.count, "a call was answered twice")
    }

    /// **One member failing must not take its siblings down.** `execute` never
    /// throws — every failure path already returns a `ToolCallRecord` carrying
    /// the error as text — so the group is a `withTaskGroup`, not a throwing
    /// one, and the failure reaches the model as a result it can act on.
    func testAFailingToolInABatchDoesNotTakeTheOthersDown() async throws {
        let loop = ToolLoop(
            backend: ScriptedBackend(names: ["sage_recall", "sage_backlog", "sage_inbox"]),
            mcp: OneFailingToolSource(failing: "sage_backlog"),
            configuration: ToolLoop.Configuration(
                maxIterations: 1, deadlineSeconds: nil, allowedToolNames: []
            )
        )

        let result = try await loop.run(transcript: "catch me up")

        XCTAssertEqual(result.trace.toolCalls.count, 3, "a sibling was cancelled by the failure")
        let failed = try XCTUnwrap(result.trace.toolCalls.first { $0.name == "sage_backlog" })
        XCTAssertTrue(failed.failed)
        XCTAssertTrue(failed.result.contains("Error:"), failed.result)
        for name in ["sage_recall", "sage_inbox"] {
            let other = try XCTUnwrap(result.trace.toolCalls.first { $0.name == name })
            XCTAssertFalse(other.failed, "\(name) was lost to a sibling's failure")
        }
        // The failure reaches the model as text rather than ending the turn.
        let answered = result.messages.filter { $0.role == .tool }.map(\.content)
        XCTAssertTrue(answered.contains { $0.contains("Error:") })
    }

    /// A fan-out that happened is visible in the log, in the idiom of
    /// `[DROPPED n]` — a behaviour that only shows up as "the turn felt
    /// quicker" is one nobody can confirm or regress.
    func testTheLogSaysWhenCallsRanTogether() {
        var trace = ToolLoopTrace(model: "m", iterations: 1)
        trace.concurrentToolCalls = 3
        XCTAssertTrue(trace.summary.contains("[PARALLEL 3]"))

        let quiet = ToolLoopTrace(model: "m", iterations: 1)
        XCTAssertFalse(quiet.summary.contains("PARALLEL"))
    }

    // MARK: Helpers

    private func call(_ name: String) -> BrainToolCall {
        BrainToolCall(id: "call_\(name)", name: name, arguments: [:])
    }
}

// MARK: - Doubles

/// Asks for a fixed list of tools by name on its first turn, then answers.
private final class ScriptedBackend: BrainBackend, @unchecked Sendable {
    let identifier = "scripted"
    let modelName = "scripted-model"
    let isLocal = true
    private let names: [String]

    init(names: [String]) { self.names = names }

    func isAvailable() async -> Bool { true }

    func complete(_ request: BrainRequest) async throws -> BrainReply {
        guard !request.tools.isEmpty else {
            return BrainReply(
                model: modelName,
                message: .assistant("here is what I found"),
                stopReason: .endTurn,
                usage: BrainUsage(inputTokens: 1, outputTokens: 1)
            )
        }
        let calls = names.enumerated().map {
            BrainToolCall(id: "call_\($0.offset)", name: $0.element, arguments: [:])
        }
        return BrainReply(
            model: modelName,
            message: BrainMessage(role: .assistant, content: "", toolCalls: calls),
            stopReason: .toolUse,
            usage: BrainUsage(inputTokens: 1, outputTokens: 1)
        )
    }
}

/// Records how many calls were in flight at once, and whether any two overlapped
/// at all — the second is what proves a write was serialised rather than merely
/// happening to peak at one.
private final class ConcurrencyWatchingToolSource: ToolProviding, @unchecked Sendable {
    private let seconds: Double
    /// Per-tool durations, so a test can make completion order deliberately
    /// disagree with call order. Equal sleeps would let an order-losing bug pass
    /// by luck on a quiet machine.
    private let delays: [String: Double]
    private let lock = NSLock()
    private var inFlight = 0
    private var peak = 0
    private var everOverlapped = false
    private var started: [String] = []

    init(seconds: Double, delays: [String: Double] = [:]) {
        self.seconds = seconds
        self.delays = delays
    }

    var peakConcurrency: Int {
        lock.lock(); defer { lock.unlock() }
        return peak
    }

    var order: [String] {
        lock.lock(); defer { lock.unlock() }
        return started
    }

    var wasStrictlySequential: Bool {
        lock.lock(); defer { lock.unlock() }
        return !everOverlapped
    }

    func listTools() async throws -> [MCPTool] {
        ["sage_recall", "sage_backlog", "sage_inbox", "sage_timeline", "sage_remember"].map {
            MCPTool(name: $0, description: "stub", inputSchema: .object(["type": .string("object")]))
        }
    }

    func call(name: String, arguments: [String: JSONValue]) async throws -> String {
        lock.lock()
        inFlight += 1
        peak = max(peak, inFlight)
        if inFlight > 1 { everOverlapped = true }
        started.append(name)
        lock.unlock()

        try? await Task.sleep(for: .seconds(delays[name] ?? seconds))

        lock.lock()
        inFlight -= 1
        lock.unlock()
        return "ok"
    }
}

/// Throws for exactly one tool name, so a batch can be watched surviving it.
private final class OneFailingToolSource: ToolProviding, @unchecked Sendable {
    private let failing: String

    init(failing: String) { self.failing = failing }

    struct Boom: Error, CustomStringConvertible {
        var description: String { "the node hung up" }
    }

    func listTools() async throws -> [MCPTool] {
        ["sage_recall", "sage_backlog", "sage_inbox"].map {
            MCPTool(name: $0, description: "stub", inputSchema: .object(["type": .string("object")]))
        }
    }

    func call(name: String, arguments: [String: JSONValue]) async throws -> String {
        try? await Task.sleep(for: .milliseconds(30))
        if name == failing { throw Boom() }
        return "ok"
    }
}
