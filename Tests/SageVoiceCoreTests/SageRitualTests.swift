import XCTest
@testable import SageVoiceCore

private final class RecordingToolSource: ToolProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(name: String, arguments: [String: JSONValue])] = []
    private let failing: Set<String>
    private let replies: [String: String]

    init(replies: [String: String] = [:], failing: Set<String> = []) {
        self.replies = replies
        self.failing = failing
    }

    func listTools() async throws -> [MCPTool] { [] }

    func call(name: String, arguments: [String: JSONValue]) async throws -> String {
        record(name, arguments)
        if failing.contains(name) {
            throw CompositeToolSource.Failure.unknownTool(name)
        }
        return replies[name] ?? "ok"
    }

    var recorded: [(name: String, arguments: [String: JSONValue])] { withLock { calls } }
    var names: [String] { recorded.map(\.name) }

    private func record(_ name: String, _ arguments: [String: JSONValue]) {
        withLock { calls.append((name, arguments)) }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

final class SageRitualTests: XCTestCase {

    // MARK: Boot

    func testBootCallsInceptionAndKeepsItsReply() async {
        let tools = RecordingToolSource(replies: [SageRitual.Tool.inception: "You were migrating the voice bridge."])
        let ritual = SageRitual(tools: tools)

        let context = await ritual.boot()

        XCTAssertEqual(tools.names, [SageRitual.Tool.register, SageRitual.Tool.inception])
        XCTAssertEqual(context, "You were migrating the voice bridge.")
    }

    /// SAGE gates its task surface on identity: `sage_backlog` answers "only to
    /// signed agents or an authenticated CEREBRUM session", so an unregistered
    /// appliance gets HTTP 401 on every task question while memory recall works
    /// fine — which reads to the owner as a missing tool rather than a missing
    /// identity.
    func testBootClaimsAnOnChainIdentity() async {
        let tools = RecordingToolSource()
        let ritual = SageRitual(tools: tools)

        await ritual.boot()

        XCTAssertEqual(tools.names.first, SageRitual.Tool.register)
        XCTAssertEqual(tools.recorded[0].arguments["name"]?.stringValue, SageRitual.agentName)
    }

    /// Memory still works unregistered, so a node that refuses registration
    /// must not cost the owner everything else.
    func testAFailedRegistrationStillBoots() async {
        let tools = RecordingToolSource(
            replies: [SageRitual.Tool.inception: "prior context"],
            failing: [SageRitual.Tool.register]
        )
        let ritual = SageRitual(tools: tools)

        let context = await ritual.boot()

        XCTAssertEqual(context, "prior context")
    }

    /// The whole point of calling inception: it must reach the model, or the
    /// appliance starts every restart with amnesia.
    func testBootContextIsFoldedIntoTheSystemPrompt() async {
        let tools = RecordingToolSource(replies: [SageRitual.Tool.inception: "Last task: fix the truncation bug."])
        let ritual = SageRitual(tools: tools)
        await ritual.boot()

        let prompt = await ritual.systemPrompt(base: "BASE PROMPT")

        XCTAssertTrue(prompt.contains("BASE PROMPT"))
        XCTAssertTrue(prompt.contains("Last task: fix the truncation bug."))
    }

    /// An appliance that refuses to answer because it could not read its own
    /// history is worse than one that starts cold — the owner is on a phone.
    func testAFailedInceptionIsNotFatal() async {
        let tools = RecordingToolSource(failing: [SageRitual.Tool.inception])
        let ritual = SageRitual(tools: tools)

        let context = await ritual.boot()

        XCTAssertNil(context)
        let prompt = await ritual.systemPrompt(base: "BASE")
        XCTAssertEqual(prompt, "BASE", "a failed boot must leave the prompt untouched")
    }

    /// Inception's reply joins the ~3,000-token prompt in front of every
    /// request for the life of the process. This appliance has already been
    /// over the context ceiling once.
    func testBootContextIsCapped() async {
        let huge = String(repeating: "memory ", count: 2000)
        let tools = RecordingToolSource(replies: [SageRitual.Tool.inception: huge])
        let ritual = SageRitual(tools: tools)

        let context = await ritual.boot()

        XCTAssertNotNil(context)
        XCTAssertLessThanOrEqual(context!.count, SageRitual.maximumBootContextCharacters + 1)
    }

    // MARK: Turn discipline

    /// Regression test for a live fault: SAGE refuses non-SAGE tool calls once
    /// enough accumulate without a sage_turn, and web_search is a non-SAGE
    /// call. Without this the appliance degrades the more it is used.
    func testEveryTurnIsRecordedWithSage() async {
        let tools = RecordingToolSource()
        let ritual = SageRitual(tools: tools)

        await ritual.recordTurn(
            transcript: "what is the population of Kuala Lumpur",
            reply: "About 1.8 million in the city proper.",
            usedTools: ["web_search"]
        )

        XCTAssertEqual(tools.names, [SageRitual.Tool.turn])
        let arguments = tools.recorded[0].arguments
        XCTAssertEqual(arguments["topic"]?.stringValue, "what is the population of Kuala Lumpur")
        XCTAssertEqual(arguments["domain"]?.stringValue, "voice-appliance")
    }

    /// SAGE silently drops observations under 30 characters as low-value, so a
    /// terse exchange must still produce a substantial one.
    func testObservationsCarryBothSidesAndClearTheLowValueFloor() {
        let observation = SageRitual.observation(transcript: "done?", reply: "Yes.", usedTools: [])

        XCTAssertGreaterThan(observation.count, 30)
        XCTAssertTrue(observation.contains("done?"))
        XCTAssertTrue(observation.contains("Yes."))
        XCTAssertTrue(observation.contains("no tools"))
    }

    func testToolsUsedAreNamedInTheObservation() {
        let observation = SageRitual.observation(
            transcript: "who runs TII",
            reply: "Dr Najwa Aaraj.",
            usedTools: ["web_search", "sage_remember"]
        )
        XCTAssertTrue(observation.contains("web_search, sage_remember"))
    }

    func testTopicIsBoundedForRecall() {
        let long = (1...50).map { "word\($0)" }.joined(separator: " ")
        let topic = SageRitual.topic(from: long)

        XCTAssertLessThanOrEqual(topic.split(separator: " ").count, 12)
        XCTAssertTrue(long.hasPrefix(topic))
    }

    func testAnEmptyTranscriptStillYieldsATopic() {
        XCTAssertFalse(SageRitual.topic(from: "   \n  ").isEmpty)
    }

    /// A failed sage_turn must not fail the owner's turn — the reply has
    /// already been sent by the time this runs.
    func testAFailedTurnIsSwallowed() async {
        let tools = RecordingToolSource(failing: [SageRitual.Tool.turn])
        let ritual = SageRitual(tools: tools)

        await ritual.recordTurn(transcript: "hello there", reply: "Hi.", usedTools: [])

        XCTAssertEqual(tools.names, [SageRitual.Tool.turn])
    }

    // MARK: Reflection

    func testReflectionHappensOnCadenceNotEveryTurn() async {
        let tools = RecordingToolSource()
        let ritual = SageRitual(tools: tools)

        for index in 1...SageRitual.reflectEveryTurns {
            await ritual.recordTurn(
                transcript: "question number \(index) about the network",
                reply: "answer \(index)",
                usedTools: []
            )
        }

        let turns = tools.names.filter { $0 == SageRitual.Tool.turn }.count
        let reflections = tools.names.filter { $0 == SageRitual.Tool.reflect }.count
        XCTAssertEqual(turns, SageRitual.reflectEveryTurns)
        XCTAssertEqual(reflections, 1, "reflection is for significant work, not every 'what's the weather'")
    }

    /// The model must never reach these two — it calling them is the failure
    /// mode the daemon-driven ritual exists to replace. A 4B model forgets the
    /// discipline three turns in, and inception mid-conversation would reset
    /// the session the owner is in the middle of.
    func testBootAndTurnToolsAreNotOfferedToTheModel() {
        for tool in [SageRitual.Tool.inception, SageRitual.Tool.turn] {
            XCTAssertFalse(
                BrainPrompts.voiceToolAllowlist.contains(tool),
                "\(tool) must stay out of the model's catalogue"
            )
        }
    }

    /// `sage_reflect` is deliberately the exception. "Save a lesson from that"
    /// is a thing the owner actually says, so the model keeps it — the daemon's
    /// cadence reflection is additional housekeeping, not a replacement.
    func testReflectStaysReachableByTheModel() {
        XCTAssertTrue(BrainPrompts.voiceToolAllowlist.contains(SageRitual.Tool.reflect))
    }
}
