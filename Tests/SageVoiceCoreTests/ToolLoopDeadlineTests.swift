import XCTest
@testable import SageVoiceCore

/// The turn budget.
///
/// Until this existed the iteration count was the only brake in the loop —
/// `ToolLoopTrace.totalDurationSeconds` was measured and never enforced — so the
/// real ceiling was "N iterations times however long each happens to take". On
/// the appliance that meant a 5-iteration turn costing 101 seconds, and raising
/// the cap to 10 without a clock would have doubled it.
///
/// The owner's reasoning for 90 s is the thing these tests are protecting: two
/// exchanges of 45 beat one wait of 200, because a partial answer they can push
/// on is worth more than a complete one that arrives after they have stopped
/// waiting. That only works if a timed-out turn still *speaks*, which is why
/// most of what follows is about the wrap-up rather than the break itself.
final class ToolLoopDeadlineTests: XCTestCase {

    // MARK: Doubles

    /// A backend that burns wall clock. Every call sleeps, then either asks for
    /// a tool again (so the loop keeps going) or answers.
    private final class SlowBackend: BrainBackend, @unchecked Sendable {
        let identifier = "slow"
        let modelName = "slow-model"
        let isLocal = true

        private let lock = NSLock()
        private let delay: Duration
        private let toolName: String?
        private(set) var callCount = 0
        /// Requests that arrived with no tools attached — the wrap-up turn.
        private(set) var toolFreeCallCount = 0

        /// - Parameter toolName: a tool to request forever, or `nil` to answer
        ///   immediately. "Forever" is what makes the brake observable; a
        ///   backend that stops on its own would pass whether or not one exists.
        init(delay: Duration, callingForever toolName: String?) {
            self.delay = delay
            self.toolName = toolName
        }

        func isAvailable() async -> Bool { true }

        func complete(_ request: BrainRequest) async throws -> BrainReply {
            try? await Task.sleep(for: delay)
            lock.lock()
            callCount += 1
            if request.tools.isEmpty { toolFreeCallCount += 1 }
            let wrapUp = request.tools.isEmpty
            lock.unlock()

            // The loop withholds tools on the wrap-up, so a backend that kept
            // requesting one there would loop forever. Answering on an empty
            // catalogue is what a real model does under `forcedSummary`.
            guard let toolName, !wrapUp else {
                return BrainReply(
                    model: "slow-model",
                    message: .assistant("here is what I found"),
                    stopReason: .endTurn,
                    usage: BrainUsage(inputTokens: 10, outputTokens: 5)
                )
            }
            return BrainReply(
                model: "slow-model",
                message: BrainMessage(
                    role: .assistant,
                    content: "",
                    toolCalls: [BrainToolCall(id: "call_\(callCount)", name: toolName, arguments: [:])]
                ),
                stopReason: .toolUse,
                usage: BrainUsage(inputTokens: 10, outputTokens: 5)
            )
        }
    }

    private final class EchoToolSource: ToolProviding, @unchecked Sendable {
        private let name: String
        init(name: String) { self.name = name }

        func listTools() async throws -> [MCPTool] {
            [MCPTool(name: name, description: "stub", inputSchema: .object(["type": .string("object")]))]
        }

        func call(name: String, arguments: [String: JSONValue]) async throws -> String { "ok" }
    }

    /// A tool that takes real time, so the brake inside an iteration has
    /// something to brake against. Margins are generous on purpose — these
    /// assert *which* brake fired, never a precise duration.
    private final class SlowEchoToolSource: ToolProviding, @unchecked Sendable {
        private let seconds: Double
        init(seconds: Double) { self.seconds = seconds }

        func listTools() async throws -> [MCPTool] {
            [MCPTool(name: "sage_recall", description: "stub", inputSchema: .object(["type": .string("object")]))]
        }

        func call(name: String, arguments: [String: JSONValue]) async throws -> String {
            try? await Task.sleep(for: .seconds(seconds))
            return "ok"
        }
    }

    /// Deliberately generous margins. These assert *that* a brake exists and
    /// which one fired, never a precise duration — a test that pins wall clock
    /// on a shared CI box is a test that fails for reasons nobody caused.
    private func makeLoop(
        delay: Duration,
        callingForever tool: String?,
        deadline: TimeInterval?,
        reserve: TimeInterval,
        maxIterations: Int = 10
    ) -> (ToolLoop, SlowBackend) {
        let backend = SlowBackend(delay: delay, callingForever: tool)
        let loop = ToolLoop(
            backend: backend,
            mcp: EchoToolSource(name: "sage_recall"),
            configuration: ToolLoop.Configuration(
                maxIterations: maxIterations,
                deadlineSeconds: deadline,
                summaryReserveSeconds: reserve,
                allowedToolNames: []
            )
        )
        return (loop, backend)
    }

    // MARK: The brake

    func testAModelThatNeverStopsCallingToolsIsStoppedByTheClockNotTheCap() async throws {
        let (loop, _) = makeLoop(
            delay: .milliseconds(120),
            callingForever: "sage_recall",
            deadline: 0.6,
            reserve: 0.2
        )

        let result = try await loop.run(transcript: "what shops did we talk about")

        XCTAssertTrue(result.trace.hitDeadline, "the clock did not stop a turn that would run forever")
        XCTAssertLessThan(
            result.trace.iterations,
            10,
            "the turn used every iteration, so the deadline did nothing"
        )
    }

    /// The whole point of stopping early. A turn that goes quiet is worse than
    /// a slow one — the owner has no idea whether to ask again.
    func testATimedOutTurnStillSpeaks() async throws {
        let (loop, backend) = makeLoop(
            delay: .milliseconds(120),
            callingForever: "sage_recall",
            deadline: 0.6,
            reserve: 0.2
        )

        let result = try await loop.run(transcript: "what shops did we talk about")

        XCTAssertFalse(result.reply.isEmpty, "a timed-out turn returned nothing to say")
        XCTAssertEqual(backend.toolFreeCallCount, 1, "the wrap-up turn did not run")
    }

    /// The reserve is the difference between a budget and a suggestion: the loop
    /// has to stop early enough that the wrap-up it still owes fits inside the
    /// number the owner was promised.
    func testTheLoopStopsCallingToolsBeforeTheDeadlineNotAtIt() async throws {
        let deadline: TimeInterval = 1.0
        let reserve: TimeInterval = 0.5
        let (loop, _) = makeLoop(
            delay: .milliseconds(100),
            callingForever: "sage_recall",
            deadline: deadline,
            reserve: reserve
        )

        let started = Date()
        let result = try await loop.run(transcript: "what shops did we talk about")
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertTrue(result.trace.hitDeadline)
        // The last model call may start just under the budget and still run its
        // full delay, so the ceiling is budget + one call + the wrap-up call.
        XCTAssertLessThan(
            elapsed,
            deadline + 1.0,
            "the reserve did not hold: a \(deadline)s budget delivered at \(elapsed)s"
        )
    }

    /// A turn with a whole budget left must not be cut short. This is the test
    /// that fails if the elapsed check is ever moved before the first call, or
    /// compared against the deadline rather than the deadline minus reserve.
    func testAFastTurnIsUntouchedByTheDeadline() async throws {
        let (loop, backend) = makeLoop(
            delay: .milliseconds(1),
            callingForever: nil,
            deadline: 90,
            reserve: 12
        )

        let result = try await loop.run(transcript: "morning mate")

        XCTAssertFalse(result.trace.hitDeadline)
        XCTAssertFalse(result.trace.hitIterationCap)
        XCTAssertEqual(result.reply, "here is what I found")
        XCTAssertEqual(backend.callCount, 1)
        XCTAssertEqual(backend.toolFreeCallCount, 0, "a turn that answered on its own paid for a wrap-up")
    }

    /// Even with nothing left to spend, one model call has to happen — the
    /// wrap-up summarises the turn's own results, and a turn with zero calls has
    /// no results to summarise. An exhausted budget should degrade to "one
    /// honest attempt", not to silence.
    func testAnAlreadyExhaustedBudgetStillMakesOneAttempt() async throws {
        let (loop, backend) = makeLoop(
            delay: .milliseconds(10),
            callingForever: "sage_recall",
            deadline: 0,
            reserve: 0
        )

        let result = try await loop.run(transcript: "what shops did we talk about")

        XCTAssertEqual(result.trace.iterations, 1, "the first iteration was skipped")
        XCTAssertGreaterThanOrEqual(backend.callCount, 2, "no wrap-up followed the single attempt")
        XCTAssertFalse(result.reply.isEmpty)
    }

    func testWithNoDeadlineTheIterationCapIsStillTheBackstop() async throws {
        let (loop, _) = makeLoop(
            delay: .milliseconds(1),
            callingForever: "sage_recall",
            deadline: nil,
            reserve: 12,
            maxIterations: 3
        )

        let result = try await loop.run(transcript: "what shops did we talk about")

        XCTAssertFalse(result.trace.hitDeadline)
        XCTAssertTrue(result.trace.hitIterationCap)
        XCTAssertEqual(result.trace.iterations, 3)
    }

    // MARK: What the log says

    /// The two brakes mean opposite things about what to change — a cap means a
    /// model that would not stop, a timeout means one that was working fine and
    /// too slowly. A log that calls both `[CAPPED]` cannot tell you which.
    func testTheLogDistinguishesATimeoutFromACap() {
        var timedOut = ToolLoopTrace(model: "m", iterations: 4)
        timedOut.hitDeadline = true
        XCTAssertTrue(timedOut.summary.contains("[TIMEOUT]"))
        XCTAssertFalse(timedOut.summary.contains("[CAPPED]"))

        var capped = ToolLoopTrace(model: "m", iterations: 10)
        capped.hitIterationCap = true
        XCTAssertTrue(capped.summary.contains("[CAPPED]"))

        // Both fire when the clock runs out on the last allowed iteration. The
        // clock is the useful fact, so it wins.
        var both = ToolLoopTrace(model: "m", iterations: 10)
        both.hitIterationCap = true
        both.hitDeadline = true
        XCTAssertTrue(both.summary.contains("[TIMEOUT]"))
        XCTAssertFalse(both.summary.contains("[CAPPED]"))

        let clean = ToolLoopTrace(model: "m", iterations: 2)
        XCTAssertFalse(clean.summary.contains("["))
    }

    /// The failure that a fixed budget could not see.
    ///
    /// Measured on the appliance: a 90 s deadline delivered at 175 s, because
    /// passing the line at 78 s still admitted one 43 s iteration plus a 42 s
    /// wrap-up. A slow backend has to stop *earlier* than a fast one, not at the
    /// same wall-clock mark, and the only way to know which it is is to have
    /// timed it.
    func testASlowBackendStopsSoonerThanAFastOneOnTheSameBudget() async throws {
        // Sized so the slow backend runs out of predicted room well before the
        // cap; a budget that only bites at iteration 10 is being enforced by the
        // cap, and would pass this test without the prediction existing at all.
        let (slowLoop, slowBackend) = makeLoop(
            delay: .milliseconds(400),
            callingForever: "sage_recall",
            deadline: 1.5,
            reserve: 0.05
        )
        let (fastLoop, fastBackend) = makeLoop(
            delay: .milliseconds(20),
            callingForever: "sage_recall",
            deadline: 1.5,
            reserve: 0.05
        )

        let slow = try await slowLoop.run(transcript: "what shops did we talk about")
        let fast = try await fastLoop.run(transcript: "what shops did we talk about")

        XCTAssertTrue(slow.trace.hitDeadline)
        XCTAssertLessThan(
            slow.trace.iterations,
            fast.trace.iterations,
            """
            Both backends stopped after the same number of iterations, so the budget is \
            still being spent as wall clock rather than as predicted remaining work — \
            the fault that turned 90s into 175s.
            """
        )
        XCTAssertGreaterThan(slowBackend.callCount, 1)
        XCTAssertGreaterThan(fastBackend.callCount, slowBackend.callCount)
    }

    /// The promise, end to end. A budget that is routinely blown by the work it
    /// forgot to count is not a budget.
    func testTheTurnLandsInsideItsBudgetOnASlowBackend() async throws {
        let deadline: TimeInterval = 1.5
        let (loop, _) = makeLoop(
            delay: .milliseconds(200),
            callingForever: "sage_recall",
            deadline: deadline,
            reserve: 0.05
        )

        let started = Date()
        let result = try await loop.run(transcript: "what shops did we talk about")
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertTrue(result.trace.hitDeadline)
        XCTAssertFalse(result.reply.isEmpty)
        // **Slack, because this is a clock on a machine we do not own.**
        //
        // It was 1.3x, and CI failed the v1.6.2 release at 1.9525s against a
        // 1.9500s bound — two and a half milliseconds, on a shared runner, in a
        // test that sleeps five times. That is not a regression, and a red
        // release build that means "the runner was busy" teaches everybody to
        // ignore red release builds.
        //
        // 1.6x keeps the guard honest: the fault it exists to catch overshot by
        // 1.94x, which is still comfortably outside this, while the real figure
        // measured here and in CI sits at about 1.30x.
        XCTAssertLessThan(
            elapsed,
            deadline * 1.6,
            "a \(deadline)s budget delivered at \(elapsed)s"
        )
    }

    // MARK: The numbers themselves

    /// 90 → 300. The first number was chosen against *silence*: waiting was
    /// cheap only while waiting meant staring at nothing. Measured at 90, the
    /// appliance got two `sage_recall`s and then the clock, so a request for a
    /// note came back as "would you like me to proceed?" — a question the owner
    /// then has to answer and wait through again, which is strictly worse than
    /// the wait it was avoiding.
    ///
    /// `WorkingReply` now reports progress on a cadence, so the turn is audible
    /// while it works and the tradeoff moved. The budget is only defensible
    /// while that remains true, which is what the second half of this asserts.
    func testTheShippedBudgetIsTheOneTheApplianceWasTunedFor() {
        XCTAssertEqual(ToolLoop.defaultDeadlineSeconds, 300)
        XCTAssertEqual(ToolLoop.summaryReserveSeconds, 12)
        XCTAssertEqual(ToolLoop.defaultMaxIterations, 10)

        // A long budget without progress messages is just a long silence, which
        // is the configuration the owner has already reported twice as a hang.
        XCTAssertGreaterThan(WorkingReply.maximumProgressMessages, 0)
        XCTAssertLessThan(
            WorkingReply.progressAfterSeconds,
            ToolLoop.defaultDeadlineSeconds / 2,
            "the turn can outlast its first check-in by more than half the budget"
        )

        // The cap has to be loose enough that it is not what ends a normal
        // research turn. Recall, recall again, search, write is four before
        // anything goes wrong; five was measured ending three real turns.
        XCTAssertGreaterThan(
            ToolLoop.defaultMaxIterations,
            5,
            "back at the dispatcher-era cap that truncated the shop list"
        )
        XCTAssertLessThan(
            ToolLoop.summaryReserveSeconds,
            ToolLoop.defaultDeadlineSeconds,
            "the reserve ate the whole budget, so no tool would ever be called"
        )
    }

    /// The wrap-up is reached both by running out of iterations and by running
    /// out of time, and the difference only reaches the owner through this text.
    func testTheWrapUpAsksToContinueRatherThanJustReportingFailure() {
        let prompt = BrainPrompts.forcedSummary
        XCTAssertTrue(prompt.contains("ran out of time"))
        XCTAssertTrue(prompt.contains("keep going"), "a timed-out turn cannot be resumed by the owner")
        XCTAssertTrue(
            prompt.contains("what you already found"),
            "stopping early is only cheaper than waiting if the partial result comes back"
        )
    }

    // MARK: Reporting what the turn actually did

    /// `ModelCallRecord.truncated` was recorded from day one and read by
    /// nothing, so an answer cut at the token ceiling looked exactly like an
    /// answer that had finished. Survivable at 40 words; not once the written
    /// style lists shops with full map URLs, where a list cut after item four is
    /// indistinguishable from a list that had four items.
    func testTruncationReachesTheLogLine() {
        var trace = ToolLoopTrace(model: "m", iterations: 2)
        trace.modelCalls = [
            ModelCallRecord(iteration: 1, promptEvalCount: 10, evalCount: 5, durationSeconds: 1, requestedTools: []),
            ModelCallRecord(
                iteration: 2, promptEvalCount: 10, evalCount: 2048, durationSeconds: 9,
                requestedTools: [], truncated: true
            )
        ]
        XCTAssertTrue(trace.wasTruncated)
        XCTAssertTrue(trace.summary.contains("[TRUNCATED]"))
    }

    /// Truncation is not exclusive with the brakes: a turn can run out of time
    /// AND have had an answer cut short, and those need different fixes — one is
    /// the budget, the other is the token ceiling.
    func testTruncationIsReportedAlongsideABrake() {
        var trace = ToolLoopTrace(model: "m", iterations: 10)
        trace.hitDeadline = true
        trace.modelCalls = [
            ModelCallRecord(
                iteration: 1, promptEvalCount: 1, evalCount: 1, durationSeconds: 1,
                requestedTools: [], truncated: true
            )
        ]
        XCTAssertTrue(trace.summary.contains("[TIMEOUT]"))
        XCTAssertTrue(trace.summary.contains("[TRUNCATED]"))
    }

    func testACleanTurnSaysNothingExtra() {
        let trace = ToolLoopTrace(
            model: "m",
            iterations: 2,
            modelCalls: [ModelCallRecord(iteration: 1, promptEvalCount: 1, evalCount: 1, durationSeconds: 1, requestedTools: [])]
        )
        XCTAssertFalse(trace.summary.contains("["))
    }

    // MARK: Fan-out inside one iteration

    /// **A job asked for in one go is done in one go.**
    ///
    /// The cap was three, and its reasoning was about chain *depth* — "the
    /// deepest chain this product needs is find-then-pipe" — while the number
    /// bounds fan-out *width*. Asked to correct four stored records, the model
    /// had its fourth refused for a reason that had nothing to do with it. The
    /// owner watched it half-finish and wait to be asked again: *"we should
    /// queue them - its better the agent does all the jobs and takes longer than
    /// reply with a half done task only making the user request for it to
    /// finish - thats like a not very smart personal assistant"*.
    func testAWideFanOutIsRunRatherThanHalfRefused() async throws {
        let backend = FanOutBackend(callsPerIteration: 8)
        let loop = ToolLoop(
            backend: backend,
            mcp: EchoToolSource(name: "sage_recall"),
            configuration: ToolLoop.Configuration(maxIterations: 1, deadlineSeconds: nil, allowedToolNames: [])
        )

        let result = try await loop.run(transcript: "fix all four of those and save the preference")

        XCTAssertEqual(result.trace.toolCalls.count, 8, "the job came back half done")
        XCTAssertEqual(result.trace.droppedToolCalls, 0)
    }

    /// The backstop survives, because against SAGE a tool call can be an
    /// on-chain write and a model looping on one must not put a hundred of them
    /// through. It is a runaway guard now, not a work limit.
    func testARunawayIsStillBounded() async throws {
        let backend = FanOutBackend(callsPerIteration: 40)
        let loop = ToolLoop(
            backend: backend,
            mcp: EchoToolSource(name: "sage_recall"),
            configuration: ToolLoop.Configuration(maxIterations: 1, deadlineSeconds: nil, allowedToolNames: [])
        )

        let result = try await loop.run(transcript: "do everything at once")

        XCTAssertEqual(result.trace.toolCalls.count, ToolLoop.maximumToolCallsPerIteration)
        XCTAssertGreaterThan(result.trace.droppedToolCalls, 0)
        XCTAssertTrue(result.trace.summary.contains("[DROPPED"), "a capped fan-out was swallowed silently")
    }

    /// **What replaced the arbitrary number.** A wide fan-out is eight round
    /// trips inside one iteration, and the between-iterations check cannot see
    /// any of them. The clock now stops it partway rather than a count stopping
    /// it at three.
    func testAWideFanOutStopsWhenTheTurnRunsOutOfTime() async throws {
        let backend = FanOutBackend(callsPerIteration: 8)
        let loop = ToolLoop(
            backend: backend,
            // **0.3 s per tool, not 0.15.** `sage_recall` is read-only, so
            // eight of them now run as two batches of four rather than eight
            // sequential calls — the fan-out this file's own comment asked for.
            // At 0.15 s the first batch left enough budget for the second and
            // the brake never fired, so the test would have passed while
            // asserting nothing. The numbers move; what is asserted does not.
            mcp: SlowEchoToolSource(seconds: 0.3),
            configuration: ToolLoop.Configuration(
                maxIterations: 1,
                deadlineSeconds: 0.4,
                summaryReserveSeconds: 0.05,
                allowedToolNames: []
            )
        )

        let result = try await loop.run(transcript: "do all of it")

        XCTAssertGreaterThan(result.trace.toolCalls.count, 0, "the first call must always run")
        XCTAssertLessThan(result.trace.toolCalls.count, 8, "the clock never stopped it")
        XCTAssertTrue(result.trace.hitDeadline)
    }

    /// **The invariant that a cap broke once already.** Every `tool_call_id` in
    /// an assistant message must be answered before the next turn, or the API
    /// refuses the whole thread — observed live as "Something went wrong talking
    /// to the model" on a voice note, from a cap meant to bound fan-out that
    /// corrupted the history instead. It holds however the turn ends.
    func testEveryRequestedCallIsAnsweredEvenWhenTimeRunsOut() async throws {
        let backend = FanOutBackend(callsPerIteration: 8)
        let loop = ToolLoop(
            backend: backend,
            // **0.3 s per tool, not 0.15.** `sage_recall` is read-only, so
            // eight of them now run as two batches of four rather than eight
            // sequential calls — the fan-out this file's own comment asked for.
            // At 0.15 s the first batch left enough budget for the second and
            // the brake never fired, so the test would have passed while
            // asserting nothing. The numbers move; what is asserted does not.
            mcp: SlowEchoToolSource(seconds: 0.3),
            configuration: ToolLoop.Configuration(
                maxIterations: 1,
                deadlineSeconds: 0.4,
                summaryReserveSeconds: 0.05,
                allowedToolNames: []
            )
        )

        let result = try await loop.run(transcript: "do all of it")

        XCTAssertEqual(
            result.trace.toolCalls.count + result.trace.droppedToolCalls,
            8,
            "a requested call went unanswered, which poisons every later turn"
        )
    }

    /// **The protocol survives fan-out.** A group skipped for time is several
    /// calls skipped at once, and every one of them still owes the model a
    /// result — an unanswered `tool_call_id` poisons the whole thread, which is
    /// the failure that reached the owner as "Something went wrong talking to
    /// the model" on a voice note. Same invariant as the test above, now that
    /// the thing being skipped is a batch rather than a call.
    func testAWideFanOutThatRunsOutOfTimeStillAnswersEveryCall() async throws {
        let backend = FanOutBackend(callsPerIteration: 8)
        let loop = ToolLoop(
            backend: backend,
            mcp: SlowEchoToolSource(seconds: 0.3),
            configuration: ToolLoop.Configuration(
                maxIterations: 1,
                deadlineSeconds: 0.4,
                summaryReserveSeconds: 0.05,
                allowedToolNames: []
            )
        )

        let result = try await loop.run(transcript: "do all of it")

        XCTAssertTrue(result.trace.hitDeadline)
        XCTAssertGreaterThan(result.trace.droppedToolCalls, 0, "no batch was skipped")
        XCTAssertEqual(
            result.trace.toolCalls.count + result.trace.droppedToolCalls, 8,
            "a member of a skipped batch went unanswered, which poisons every later turn"
        )

        // And the ones that did not run say so, rather than returning a stub the
        // model would read as "the tool is empty".
        let skipped = result.messages.filter {
            $0.role == .tool && $0.content.contains("ran out of time")
        }
        XCTAssertEqual(skipped.count, result.trace.droppedToolCalls)
    }

    /// An ordinary turn must not be clipped. The cap is a guard against a
    /// confused model, not a limit on find-then-pipe.
    func testANormalNumberOfCallsIsUntouched() async throws {
        let backend = FanOutBackend(callsPerIteration: 2)
        let loop = ToolLoop(
            backend: backend,
            mcp: EchoToolSource(name: "sage_recall"),
            configuration: ToolLoop.Configuration(maxIterations: 1, deadlineSeconds: nil, allowedToolNames: [])
        )

        let result = try await loop.run(transcript: "find them and send it")
        XCTAssertEqual(result.trace.toolCalls.count, 2)
        XCTAssertEqual(result.trace.droppedToolCalls, 0)
    }
}

/// Asks for a fixed number of tools every iteration, so the fan-out cap can be
/// exercised without a real model deciding to behave.
private final class FanOutBackend: BrainBackend, @unchecked Sendable {
    let identifier = "fanout"
    let modelName = "fanout-model"
    let isLocal = true
    private let callsPerIteration: Int

    init(callsPerIteration: Int) { self.callsPerIteration = callsPerIteration }

    func isAvailable() async -> Bool { true }

    func complete(_ request: BrainRequest) async throws -> BrainReply {
        guard !request.tools.isEmpty else {
            return BrainReply(
                model: modelName,
                message: .assistant("done"),
                stopReason: .endTurn,
                usage: BrainUsage(inputTokens: 1, outputTokens: 1)
            )
        }
        let calls = (0..<callsPerIteration).map {
            BrainToolCall(id: "call_\($0)", name: "sage_recall", arguments: [:])
        }
        return BrainReply(
            model: modelName,
            message: BrainMessage(role: .assistant, content: "", toolCalls: calls),
            stopReason: .toolUse,
            usage: BrainUsage(inputTokens: 1, outputTokens: 1)
        )
    }
}
