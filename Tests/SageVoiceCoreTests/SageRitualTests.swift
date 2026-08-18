import XCTest
@testable import SageVoiceCore

/// A tool source that records what was called, and can hold a call *open*.
///
/// **Holding a call open is what distinguishes started from returned, and that
/// distinction is the whole reason this can be tested at all.** `names` records
/// the order calls START in, and the order two tasks start in belongs to the
/// scheduler, not to this codebase: `boot()` fires the domain scan as an
/// unstructured `Task` and then awaits inception, so on Darwin `sage_status` is
/// recorded after inception and on Linux it is recorded before it. The first
/// Linux CI run of the suite proved it — 1738 tests passed and this file's boot
/// test failed with `["sage_register", "sage_status"]`, having asserted an
/// ordering nothing in `boot()` promises.
///
/// What `boot()` does promise is that it never WAITS for the domain scan, and a
/// call that has returned cannot be un-returned by a scheduler. So a test holds
/// `sage_status` open and asks which calls had finished by the time boot came
/// back. That question has one answer on every platform.
private final class RecordingToolSource: ToolProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(name: String, arguments: [String: JSONValue])] = []
    private var completed: [String] = []
    private var releasedTools: Set<String> = []
    private let held: Set<String>
    private let failing: Set<String>
    private let replies: [String: String]

    init(replies: [String: String] = [:], failing: Set<String> = [], holding: Set<String> = []) {
        self.replies = replies
        self.failing = failing
        self.held = holding
    }

    func listTools() async throws -> [MCPTool] { [] }

    func call(name: String, arguments: [String: JSONValue]) async throws -> String {
        record(name, arguments)
        if held.contains(name) {
            await waitUntil { self.withLock { self.releasedTools.contains(name) } }
        }
        // Recorded before the throw as well as before the return: a call that
        // failed is a call the caller is no longer waiting on, which is the
        // only property `completed` is asked about.
        withLock { completed.append(name) }
        if failing.contains(name) {
            throw CompositeToolSource.Failure.unknownTool(name)
        }
        return replies[name] ?? "ok"
    }

    var recorded: [(name: String, arguments: [String: JSONValue])] { withLock { calls } }
    var names: [String] { recorded.map(\.name) }

    /// The calls that have RETURNED, in the order they returned.
    var completedNames: [String] { withLock { completed } }

    /// Lets a held call return, and does not come back until it has.
    ///
    /// The wait matters: without it the held task outlives the test, and what
    /// it outlives into is a `tearDown` that deletes the directory underneath
    /// it.
    func release(_ name: String) async {
        withLock { _ = releasedTools.insert(name) }
        await waitUntil { self.withLock { self.completed.contains(name) } }
    }

    /// Bounded, and the bound is the point.
    ///
    /// If `boot()` ever awaits the domain scan again, the call held here is the
    /// one the whole boot is parked behind, and an unbounded wait would park
    /// the process with it. `scripts/linux-test.sh` would then report the
    /// regression as HUNG — the word it reserves for the corelibs run-loop bug
    /// — and a real regression would be filed as a toolchain race. Five seconds
    /// turns the same regression into a named assertion failure instead.
    private func waitUntil(_ satisfied: @Sendable () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !satisfied() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

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

    private var directory = URL(fileURLWithPath: NSTemporaryDirectory())

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sage-ritual-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// **Every ritual in this file goes through here, and that is not tidiness.**
    ///
    /// `SageRitual` defaults its two records to the owner's real Application
    /// Support directory. A test that took the defaults would read — and, once
    /// `noteWhichDomainsItMaySearch` shipped, *write* — the live appliance's
    /// files while the suite ran.
    private func makeRitual(_ tools: ToolProviding) -> SageRitual {
        SageRitual(
            tools: tools,
            // **The third default is not a file, and it was the loud one.**
            //
            // Left out, `readinessCheck` is `ApplianceWriteReadinessCheck()`,
            // which resolves the SAGE node on this Mac and starts `sage-gui
            // mcp` under `MynahIdentity.applianceEnvironment()`: a second
            // process signing as the appliance's own key, spawned by the test
            // suite, asking the owner's live node a question. Six boot tests
            // did that six times a run, at about a second each — this file was
            // 7.3 seconds of a 249-second suite, nearly all of it here.
            //
            // Nothing in this file is about the answer.
            // `checkWhetherItCanSaveAnything` logs it and returns; every
            // assertion here is about the calls around it.
            readinessCheck: {
                ApplianceWriteReadiness(agentID: nil, standing: .unknown("not asked in tests"))
            },
            alreadySaidFile: directory.appendingPathComponent("said.json"),
            readableDomainsFile: directory.appendingPathComponent("domains.json")
        )
    }

    // MARK: Boot

    func testBootCallsInceptionAndKeepsItsReply() async {
        // **`sage_status` is held open for the whole of boot: called, never
        // answered.** That is the exact shape of the failure this guards. It
        // ran awaited for one build, and the owner watched start-up sit on
        // "Signing in" for three minutes — `sage_status` does not return for
        // this appliance on 11.16.4, so boot spent the client's full 90-second
        // timeout, twice, once per surface, before reaching inception.
        //
        // It runs unstructured now. Nothing waits on the answer: `ScopedRecall`
        // loads the file when it needs it, and falls back to the domains this
        // appliance is known to use until then. So a node that never replies is
        // what boot has to survive, and it is what this hands it.
        let tools = RecordingToolSource(
            replies: [SageRitual.Tool.inception: "You were migrating the voice bridge."],
            holding: [SageRitual.Tool.status]
        )
        let ritual = makeRitual(tools)

        let context = await ritual.boot()

        XCTAssertEqual(context, "You were migrating the voice bridge.")
        // **Calls that RETURNED, not calls that started.**
        //
        // This asserted `names.prefix(2)` until Linux CI ran it, and it failed
        // there with `["sage_register", "sage_status"]` while 1738 other tests
        // passed. Nothing had regressed: `boot()` starts the domain scan as an
        // unstructured `Task` and then awaits inception, so which of the two is
        // recorded first is the scheduler's decision, and Darwin and Linux
        // decide differently. The assertion was reading the scheduler.
        //
        // Completion order is not the scheduler's to reorder. `sage_status` is
        // still in flight here and will be until this test releases it, so
        // seeing it in this list at all would mean boot had waited for it —
        // which is the regression, stated as the thing that actually hurt.
        XCTAssertEqual(
            tools.completedNames,
            [SageRitual.Tool.register, SageRitual.Tool.inception]
        )

        await tools.release(SageRitual.Tool.status)
    }

    /// SAGE gates its task surface on identity: `sage_backlog` answers "only to
    /// signed agents or an authenticated CEREBRUM session", so an unregistered
    /// appliance gets HTTP 401 on every task question while memory recall works
    /// fine — which reads to the owner as a missing tool rather than a missing
    /// identity.
    func testBootClaimsAnOnChainIdentity() async {
        let tools = RecordingToolSource()
        let ritual = makeRitual(tools)

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
        let ritual = makeRitual(tools)

        let context = await ritual.boot()

        XCTAssertEqual(context, "prior context")
    }

    /// The whole point of calling inception: it must reach the model, or the
    /// appliance starts every restart with amnesia.
    func testBootContextIsFoldedIntoTheSystemPrompt() async {
        let tools = RecordingToolSource(replies: [SageRitual.Tool.inception: "Last task: fix the truncation bug."])
        let ritual = makeRitual(tools)
        await ritual.boot()

        let prompt = await ritual.systemPrompt(base: "BASE PROMPT")

        XCTAssertTrue(prompt.contains("BASE PROMPT"))
        XCTAssertTrue(prompt.contains("Last task: fix the truncation bug."))
    }

    /// An appliance that refuses to answer because it could not read its own
    /// history is worse than one that starts cold — the owner is on a phone.
    func testAFailedInceptionIsNotFatal() async {
        let tools = RecordingToolSource(failing: [SageRitual.Tool.inception])
        let ritual = makeRitual(tools)

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
        let ritual = makeRitual(tools)

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
        let ritual = makeRitual(tools)

        await ritual.recordTurn(
            transcript: "what is the population of Kuala Lumpur",
            reply: "About 1.8 million in the city proper.",
            usedTools: ["web_search"]
        )

        XCTAssertEqual(tools.names, [SageRitual.Tool.turn])
        let arguments = tools.recorded[0].arguments
        XCTAssertEqual(arguments["topic"]?.stringValue, "what is the population of Kuala Lumpur")
        // **No domain at all, which is the point.**
        //
        // The comment this replaces was right about the danger and reached for
        // the wrong remedy. It said the name "has to match a domain an
        // administrator actually assigns on the node, so it will change again",
        // and asserted the constant rather than the literal so a rename would
        // not turn into a failure. That made the test agree with the code by
        // construction — and both went on naming `voice-interface`, a subject
        // belonging to another agent, for as long as the constant said so. A
        // test pinned to a constant cannot notice the constant being wrong.
        //
        // So the invariant moved. SAGE routes a domainless write to this
        // agent's own approved home subject, and an explicit domain is never
        // remapped — so naming one can be wrong and omitting one cannot.
        XCTAssertNil(
            arguments["domain"],
            "naming a domain here is how every turn came to be filed under another agent's subject"
        )
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
        let ritual = makeRitual(tools)

        await ritual.recordTurn(transcript: "hello there", reply: "Hi.", usedTools: [])

        XCTAssertEqual(tools.names, [SageRitual.Tool.turn])
    }

    // MARK: Reflection

    func testReflectionHappensOnCadenceNotEveryTurn() async {
        let tools = RecordingToolSource()
        let ritual = makeRitual(tools)

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

    /// **`sage_reflect` used to be the exception, and the owner reversed it on
    /// 5 August 2026.**
    ///
    /// The previous reasoning is worth keeping because it is not wrong: *"'Save
    /// a lesson from that' is a thing the owner actually says, so the model
    /// keeps it — the daemon's cadence reflection is additional housekeeping,
    /// not a replacement."* Those really are different writes. The ritual
    /// reflects every ten turns on whatever has happened; a model-invoked
    /// reflect files the specific lesson somebody just asked to save.
    ///
    /// It went anyway, as part of trimming the catalogue back under the routing
    /// ceiling. Two reasons, and the second is the one that decided it:
    ///
    /// 1. It is a tool plausible after *any* turn, which is the exact shape the
    ///    26B run punished — `sage_turn` and `sage_inception` were excluded for
    ///    being attractors and this is the same silhouette.
    /// 2. **The capability does not actually disappear.** `sage_remember` is
    ///    still in the catalogue and "remember that X worked" lands there. What
    ///    is lost is the *type*: it is filed as an ordinary memory rather than
    ///    as a dos/don'ts reflection, so it no longer feeds the reflection
    ///    channel specifically.
    ///
    /// That is the whole cost, stated so a future reader can reverse it back
    /// with their eyes open rather than rediscovering the argument.
    func testReflectIsNoLongerOfferedToTheModel() {
        XCTAssertFalse(
            BrainPrompts.voiceToolAllowlist.contains(SageRitual.Tool.reflect),
            "sage_reflect is back in the model's catalogue — see this test's note for what that trades"
        )
        // The half that must keep working: the daemon still reflects on its own
        // cadence, so nothing stops being written down.
        XCTAssertEqual(SageRitual.reflectEveryTurns, 10)
    }

    /// And the browse-shaped memory tool went with it, for the reason the
    /// routing measurement in `BrainPrompts` names: `sage_list` is one of the
    /// three high-generality attractors it identifies, and the other two were
    /// already excluded for exactly that.
    ///
    /// `sage_recall` is what a spoken question wants anyway — it ranks by
    /// meaning, where `sage_list` browses a domain. The Memories page is
    /// unaffected: it calls the node directly, and this list only filters what
    /// the model is shown.
    func testTheBrowseShapedMemoryToolIsNotOfferedEither() {
        XCTAssertFalse(
            BrainPrompts.voiceToolAllowlist.contains("sage_list"),
            "sage_list is an attractor by this repository's own measurement"
        )
        XCTAssertTrue(
            BrainPrompts.voiceToolAllowlist.contains("sage_recall"),
            "the tool that answers the question sage_list was reached for is gone too"
        )
    }
}
