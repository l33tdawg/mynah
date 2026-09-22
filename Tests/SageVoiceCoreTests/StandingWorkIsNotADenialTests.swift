import XCTest
@testable import SageVoiceCore

/// **Mynah has to know it has a clock, and this suite is about that half.**
///
/// The conversation that started this feature was not a missing mechanism. It
/// was an answer, on 22 September 2026: *"I have no timer or scheduler on my
/// end. I only run when you speak to me, so a poll would need something outside
/// me to wake me up on a clock, and I have no tool that does that."* Every word
/// of that was true, and the owner read it as the appliance being unable to do
/// what he wanted. A scheduler nobody has told the model about is a scheduler
/// the owner hears about only as a denial — so what `ScheduledWork` puts on the
/// turn is as load-bearing as `WhereWeAre.rightNow`, and this file tests it the
/// same way that one does: by running a turn and reading what the backend was
/// actually sent.
final class StandingWorkIsNotADenialTests: XCTestCase {

    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func text(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func task(
        _ instruction: String,
        _ cadence: ScheduleCadence = .daily(hour: 8, minute: 0),
        enabled: Bool = true
    ) -> ScheduledTask {
        ScheduledTask(
            id: UUID().uuidString, instruction: instruction, cadence: cadence,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000), isEnabled: enabled
        )
    }

    // MARK: What the model is told

    /// The empty case still has to teach the capability, because "nothing is set
    /// up" and "I cannot do that" are the two answers that must never be the
    /// same answer.
    func testWithNothingSetUpTheNoteStillSaysTheApplianceCan() {
        let note = ScheduledWork().note()

        XCTAssertTrue(note.contains("STANDING WORK"), note)
        XCTAssertTrue(note.contains("//schedule"), note)
        XCTAssertTrue(note.contains("Nothing is set up"), note)
    }

    func testWhatIsSetUpIsListedNumberedAndNotedWhenHeld() {
        var work = ScheduledWork()
        _ = work.add(
            instruction: "check my inbox and tell me what's waiting",
            cadence: .daily(hour: 8, minute: 0)
        )
        _ = work.add(instruction: "send me the week ahead", cadence: .weekly(weekday: 2, hour: 9, minute: 30))
        _ = work.pause(number: 2)

        let note = work.note()
        XCTAssertTrue(note.contains("every day at 08:00 — check my inbox"), note)
        XCTAssertTrue(note.contains("every Monday at 09:30 — send me the week ahead"), note)
        XCTAssertTrue(note.contains("1 held"), note)
    }

    /// **Deliberately not in the system prompt.** That string is the prompt
    /// cache's prefix and is held for the life of the process, so a list that
    /// changes when the owner sets something up would be a cache miss on every
    /// turn that followed — and stale in the one direction that matters.
    /// `PromptLatencyBudgetTests` holds the prompt under 8,300 characters with a
    /// handful left, which is the other half of the same reason.
    func testThePromptDoesNotCarryTheList() {
        for style in ReplyStyle.allCases {
            XCTAssertFalse(
                BrainPrompts.voiceAgentManager(style: style).contains("//schedule"),
                "the schedules moved into the cached prefix"
            )
        }
    }

    /// And the other end of it: the turn carries the note, on every surface that
    /// builds its configuration the way the appliance does.
    func testTheTurnCarriesWhatIsSetUp() async throws {
        let backend = RecordingBackend()
        let loop = ToolLoop(
            backend: backend,
            mcp: OneTool(),
            configuration: ToolLoop.Configuration(
                allowedToolNames: ["sage_recall"],
                standingWork: { "STUB STANDING WORK" }
            )
        )

        _ = try await loop.run(transcript: "what have you got set up?", history: [])

        let sent = try XCTUnwrap(backend.requests.first)
        let turn = try XCTUnwrap(sent.messages.last)
        XCTAssertTrue(turn.content.contains("what have you got set up?"), turn.content)
        XCTAssertTrue(turn.content.contains("STUB STANDING WORK"), turn.content)
    }

    /// A `Configuration()` built by a test or a one-shot command must not read
    /// the developer's own schedule file, and `forStyle` — the one every real
    /// surface builds from — must.
    func testTheRealSurfacesGetItAndABareConfigurationDoesNot() {
        XCTAssertNil(ToolLoop.Configuration().standingWork)
        let installed = ToolLoop.Configuration.forStyle(.default).standingWork
        XCTAssertNotNil(installed)
        XCTAssertTrue(installed?()?.contains("STANDING WORK") ?? false)
    }

    // MARK: What the work runs as

    /// Nobody is waiting, and the model has to be told so: its whole working life
    /// is answering a message that just arrived, and the answer that comes out of
    /// forgetting is a question — sent to a phone with nobody at the other end
    /// to answer it.
    func testTheRunSaysOutLoudThatNobodyJustSpoke() {
        let transcript = ScheduledWork.transcript("check my inbox and tell me what's waiting")

        XCTAssertTrue(transcript.contains("He has not just spoken"), transcript)
        XCTAssertTrue(transcript.contains("nobody is waiting to answer a question"), transcript)
        XCTAssertTrue(
            transcript.hasSuffix("check my inbox and tell me what's waiting"),
            "the owner's own words must arrive verbatim"
        )
    }

    // MARK: The wiring

    /// The pieces above are worth what they are wired to. Three connections have
    /// no other test that can see them — the daemon answering the command before
    /// the model ever sees it, the watch claiming work on its tick, and the run
    /// being framed as standing work rather than as a reply — because the
    /// components they join need a live Signal client and a live node.
    func testTheApplianceIsWiredToItsOwnClock() throws {
        let daemon = try text("Sources/SageVoiceCore/VoiceBridgeDaemon.swift")
        XCTAssertTrue(
            daemon.contains("ScheduledWorkCommand.read(transcript)"),
            "//schedule never reaches the code that reads it, so a language model answers it"
        )
        XCTAssertTrue(
            daemon.contains("ScheduledWork.transcript(task.instruction)"),
            "the scheduled run is not framed as standing work, so it answers as if a message had just arrived"
        )
        XCTAssertTrue(
            daemon.contains("public func runScheduledWork("),
            "nothing runs the work"
        )
        // **The instruction it ran is fed to the model and not written down.**
        // `ConversationStore` renders a user turn as the owner speaking, and the
        // turn this work is fed is framed — so storing it would put machine text
        // in his mouth on the Home screen. What belongs in the transcript is the
        // answer, which is the shape every other unprompted message already has.
        XCTAssertTrue(
            daemon.contains("BrainMessage(role: .assistant, content: words)"),
            "the scheduled run's frame is being stored as if the owner had said it"
        )

        let main = try text("Sources/sage-voiced/main.swift")
        XCTAssertTrue(
            main.contains("ScheduledWorkRunner(log:"),
            "the watch has no runner, so nothing claims what is due"
        )
        XCTAssertTrue(
            main.contains("for task in scheduledWork.claimDue(at: now)"),
            "the tick never claims standing work"
        )
        XCTAssertTrue(
            main.contains("scheduledWork: standingWork"),
            "the runner is built and not handed to the loop"
        )
    }

    func testHelpIsWhereSomebodyFindsOutItExists() {
        let help = CallInvitation.help(callRefusal: nil)

        XCTAssertTrue(help.contains("//schedule"), help)
        XCTAssertTrue(help.contains("//schedules"), help)
        XCTAssertTrue(help.contains("every day at 8am"), help)
    }
}

// MARK: - Doubles

/// Records what it was asked, then answers.
private final class RecordingBackend: BrainBackend, @unchecked Sendable {
    let identifier = "recording"
    let modelName = "stub-model"
    let isLocal = true

    private let lock = NSLock()
    private var recorded: [BrainRequest] = []

    var requests: [BrainRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func isAvailable() async -> Bool { true }

    func complete(_ request: BrainRequest) async throws -> BrainReply {
        lock.lock()
        recorded.append(request)
        lock.unlock()
        return BrainReply(
            model: "stub-model",
            message: .assistant("Right, noted."),
            stopReason: .endTurn,
            usage: BrainUsage(inputTokens: 10, outputTokens: 5)
        )
    }
}

/// One tool and nothing else. This suite is about what the model is *told*, not
/// what it can call, and the loop refuses an empty catalogue on purpose — that
/// means the node is not there — so the smallest catalogue it will accept is
/// one stub tool.
private struct OneTool: ToolProviding {
    func listTools() async throws -> [MCPTool] {
        [MCPTool(name: "sage_recall", description: "stub", inputSchema: .object([:]))]
    }
    func call(name: String, arguments: [String: JSONValue]) async throws -> String {
        "ok"
    }
}
