import XCTest
@testable import SageVoiceCore

/// `schedule_work`: the owner asking for something on a clock, in conversation.
///
/// The whole reason this tool is safe to give a 4B is that it does not decide
/// anything about time. It hands the owner's own phrase to the same reader
/// `//schedule` uses and gets back either a cadence or a refusal, and everything
/// here is about that boundary: what it accepts, what it hands back when a
/// phrase cannot be read, and that what it writes is exactly what the command
/// writes.
final class ScheduledWorkToolSourceTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("mynah-tool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private var file: URL { scratch.appendingPathComponent("scheduled-work.json") }

    private func tool(
        now: Date = Date(timeIntervalSince1970: 1_800_000_000),
        isPaused: Bool = false
    ) -> ScheduledWorkToolSource {
        ScheduledWorkToolSource(
            fileURL: file, now: { now }, isPaused: { isPaused }, log: { _ in }
        )
    }

    private func call(
        _ when: String, _ what: String, isPaused: Bool = false
    ) async throws -> String {
        try await tool(isPaused: isPaused).call(
            name: ScheduledWorkToolSource.toolName,
            arguments: ["when": .string(when), "what": .string(what)]
        )
    }

    private func kept() -> [ScheduledTask] {
        ScheduledWork.load(from: file).tasks
    }

    // MARK: What it publishes

    func testItPublishesOneToolAndDescribesWhatItDoesNotDo() async throws {
        let published = try await ScheduledWorkToolSource().listTools()
        XCTAssertEqual(published.map(\.name), [ScheduledWorkToolSource.toolName])

        let description = try XCTUnwrap(published.first?.description)
        // The three things the model must not get wrong, each said out loud in
        // the schema rather than hoped for: nothing happens now, a bare hour is
        // refused, and stopping one is not this tool's job.
        XCTAssertTrue(description.contains("Nothing happens now"), description)
        XCTAssertTrue(
            description.contains("Stopping one is not done here"), description
        )
        let when = try XCTUnwrap(
            published.first?.inputSchema.objectValue?["properties"]?.objectValue?["when"]?
                .objectValue?["description"]?.stringValue
        )
        XCTAssertTrue(when.contains("am/pm"), when)
    }

    // MARK: Creating one

    func testTheOwnerAskingInConversationPutsItOnTheClock() async throws {
        let result = try await call("every morning at 8am", "check my inbox and tell me what's waiting")

        XCTAssertTrue(result.hasPrefix("SCHEDULED."), result)
        XCTAssertTrue(result.contains("Every day at 08:00"), result)
        let tasks = kept()
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.cadence, .daily(hour: 8, minute: 0))
        XCTAssertEqual(tasks.first?.instruction, "check my inbox and tell me what's waiting")
    }

    /// **Whatever the owner said about the work, in his words.** The sentence the
    /// run executes later is the one he used, not a paraphrase the model made on
    /// the way in.
    func testTheWorkIsKeptInTheOwnersWords() async throws {
        let said = "look for anything new from Flint, and only tell me if there IS something"
        _ = try await call("every 30 minutes", said)
        XCTAssertEqual(kept().first?.instruction, said)
    }

    /// The one the tool and the command must not answer differently. Both go
    /// through `ScheduledWorkCommand.perform`, and this is the test that says so
    /// — a second implementation of the file write is how the two doors start
    /// disagreeing about the ceiling, the pause, or what "held" means.
    func testTheToolWritesExactlyWhatTheCommandWrites() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let viaTool = scratch.appendingPathComponent("via-tool.json")
        let viaCommand = scratch.appendingPathComponent("via-command.json")

        // `isPaused` is pinned false rather than left to the default. The
        // default reads the appliance's real pause file, which makes this test
        // depend on something outside itself — and it did: the release gate
        // failed here once while the same test passed in isolation, which is a
        // test reading the machine rather than the code. What is under test is
        // the write, so the pause state is stated.
        let written = try await ScheduledWorkToolSource(
            fileURL: viaTool, now: { now }, isPaused: { false }, log: { _ in }
        )
        .call(
            name: ScheduledWorkToolSource.toolName,
            arguments: [
                "when": .string("every Monday at 9:30am"),
                "what": .string("send me the week ahead")
            ]
        )
        _ = ScheduledWorkCommand.perform(
            .request(.create(
                instruction: "send me the week ahead",
                cadence: .weekly(weekday: 2, hour: 9, minute: 30)
            )),
            at: viaCommand,
            now: now
        )

        let fromTool = ScheduledWork.load(from: viaTool)
        let fromCommand = ScheduledWork.load(from: viaCommand)
        // The sentence first, so a failure names the reason rather than the
        // arithmetic that followed from it.
        XCTAssertTrue(written.hasPrefix("SCHEDULED"), written)
        XCTAssertEqual(fromTool.tasks.count, fromCommand.tasks.count)
        XCTAssertEqual(fromTool.tasks.first?.instruction, fromCommand.tasks.first?.instruction)
        XCTAssertEqual(fromTool.tasks.first?.cadence, fromCommand.tasks.first?.cadence)
        XCTAssertEqual(fromTool.tasks.first?.createdAt, fromCommand.tasks.first?.createdAt)
    }

    // MARK: What it refuses, and what the model is told to do about it

    /// **A bare hour comes back as a refusal, and the refusal names the fix.**
    /// The model's job on this result is to ask the owner, which is the only
    /// thing that turns "at 8" into a time without guessing at one.
    func testAnUnreadableTimeComesBackAsSomethingToAskAbout() async throws {
        let result = try await call("every day at 8", "check my inbox")

        XCTAssertTrue(result.hasPrefix("NOT SCHEDULED"), result)
        XCTAssertTrue(result.contains("am or pm"), result)
        XCTAssertTrue(result.contains("Ask him"), result)
        XCTAssertTrue(kept().isEmpty, "it scheduled something anyway")
    }

    func testWorkTheOwnerNeverDescribedIsRefused() async throws {
        let result = try await call("every day at 8am", "   ")
        XCTAssertTrue(result.contains("you did not say what to do"), result)
        XCTAssertTrue(kept().isEmpty)
    }

    func testATimeWithNoWorkIsRefusedTheSameWayTheCommandRefusesIt() async throws {
        let result = try await call("sometime", "check my inbox")
        XCTAssertTrue(result.contains("couldn't read when"), result)
        XCTAssertTrue(kept().isEmpty)
    }

    /// The ceiling is the store's, not a second number here — and the sentence
    /// the model gets is the command's, so the owner hears one story whichever
    /// door he came through.
    func testTheCeilingIsTheStores() async throws {
        for index in 1...ScheduledWork.maximumTasks {
            _ = try await call("every day at 8am", "check my inbox \(index)")
        }
        let result = try await call("every day at 9am", "one too many")

        XCTAssertTrue(result.hasPrefix("NOT SCHEDULED"), result)
        XCTAssertTrue(result.contains("\(ScheduledWork.maximumTasks)"), result)
        XCTAssertEqual(kept().count, ScheduledWork.maximumTasks)
    }

    /// Paused is the owner saying *not now*, and the tool is a write.
    func testNothingIsScheduledWhileTheApplianceIsPaused() async throws {
        let result = try await call("every day at 8am", "check my inbox", isPaused: true)
        XCTAssertTrue(result.contains("paused"), result)
        XCTAssertTrue(kept().isEmpty)
    }

    func testAnotherToolNameIsNotItsBusiness() async throws {
        do {
            _ = try await tool().call(name: "sage_recall", arguments: [:])
            XCTFail("it answered for a tool it does not publish")
        } catch let failure as CompositeToolSource.Failure {
            XCTAssertEqual(failure, .unknownTool("sage_recall"))
        }
    }
}
