import XCTest
@testable import SageVoiceCore

// MARK: - A node that has whatever the test needs

private struct ScriptedNode: ProactiveSource {
    var messages: [AgentInboxItem] = []
    var tasks: [WatchedTask] = []
    var refuses = false

    func waitingMessages(limit: Int) async throws -> [AgentInboxItem] {
        if refuses { throw AgentMessagingTrouble.nodeUnavailable }
        return messages
    }

    func openTasks() async throws -> [WatchedTask] {
        if refuses { throw AgentMessagingTrouble.nodeUnavailable }
        return tasks
    }
}

private func message(
    _ id: String,
    from sender: String = "Cerebrum",
    body: String = "The roof quote came back at 4,200.",
    intent: String? = nil,
    expectsAResult: Bool = false
) -> AgentInboxItem {
    AgentInboxItem(
        id: id,
        content: UntrustedAgentContent(sender: sender, trust: .anotherAgentHere, body: body),
        intent: intent,
        arrived: nil,
        expectsAResult: expectsAResult
    )
}

private func task(_ id: String, _ title: String, _ status: String = "planned") -> WatchedTask {
    WatchedTask(id: id, title: title, status: status)
}

// MARK: - Tests

/// Mynah speaking first.
///
/// Every test here is about the same risk in a different shape: this is the one
/// message the owner did not ask for, so the bar is that it never arrives
/// without something having genuinely happened. An appliance that repeats
/// itself hourly gets muted, and a muted appliance is worse than a silent one.
final class ProactiveWatchTests: XCTestCase {

    private func seeded() -> ProactiveLedger {
        ProactiveLedger(hasSeeded: true)
    }

    // MARK: The first look

    func testTheFirstCheckSaysNothingAndWritesDownWhatIsAlreadyThere() async {
        let node = ScriptedNode(
            messages: [message("p1"), message("p2")],
            tasks: [task("t1", "Book the hotel"), task("t2", "Send the car in")]
        )

        let report = await ProactiveWatch(source: node).check(against: ProactiveLedger())

        XCTAssertNil(
            report.message,
            "switching this on must not dump a fortnight of inbox and every open task "
                + "into one message"
        )
        XCTAssertTrue(report.ledger.hasSeeded)
        XCTAssertEqual(report.ledger.toldAboutMessages, ["p1", "p2"])
        XCTAssertEqual(report.ledger.knownTasks, ["t1": "planned", "t2": "planned"])
    }

    func testNothingNewMeansNothingSaid() async {
        let node = ScriptedNode(messages: [message("p1")], tasks: [task("t1", "Book the hotel")])
        var ledger = seeded()
        ledger.toldAboutMessages = ["p1"]
        ledger.knownTasks = ["t1": "planned"]

        let report = await ProactiveWatch(source: node).check(against: ledger)

        XCTAssertNil(report.message, "the same four open tasks every hour is a nag, not an agent")
    }

    // MARK: Messages

    func testANewMessageIsReportedOnceAndOnlyOnce() async {
        let node = ScriptedNode(messages: [message("p1", from: "Cerebrum")])
        let watch = ProactiveWatch(source: node)

        let first = await watch.check(against: seeded())
        XCTAssertEqual(
            first.message,
            "Cerebrum sent a message: “The roof quote came back at 4,200.”"
        )

        let second = await watch.check(against: first.ledger)
        XCTAssertNil(second.message)
    }

    func testWorkThatWantsAnAnswerSaysSo() async {
        let node = ScriptedNode(messages: [
            message("p1", intent: "research", expectsAResult: true)
        ])

        let report = await ProactiveWatch(source: node).check(against: seeded())

        XCTAssertTrue(report.message?.contains("sent work (research)") ?? false, report.message ?? "")
    }

    func testAnotherAgentsWordsAreCappedRatherThanRelayedWhole() async {
        let long = String(repeating: "a", count: 900)
        let node = ScriptedNode(messages: [message("p1", body: long)])

        let report = await ProactiveWatch(source: node).check(against: seeded())

        // An unbounded relay would let an agent elsewhere push whatever it
        // liked into the owner's Signal thread, unprompted.
        XCTAssertLessThan(report.message?.count ?? .max, 260)
        XCTAssertTrue(report.message?.hasSuffix("…”") ?? false, report.message ?? "")
    }

    func testTheSenderIsAlwaysNamed() async {
        let node = ScriptedNode(messages: [message("p1", from: "Kestrel", body: "")])

        let report = await ProactiveWatch(source: node).check(against: seeded())

        XCTAssertEqual(report.message, "Kestrel sent a message.")
    }

    func testAnItemTheNodeHasDroppedIsForgotten() async {
        var ledger = seeded()
        ledger.toldAboutMessages = ["old-1", "old-2"]
        let node = ScriptedNode(messages: [message("p1")])

        let report = await ProactiveWatch(source: node).check(against: ledger)

        XCTAssertEqual(
            report.ledger.toldAboutMessages, ["p1"],
            "an appliance up for a year should not carry every pipe id it ever saw"
        )
    }

    // MARK: Tasks

    func testANewTaskIsNews() async {
        var ledger = seeded()
        ledger.knownTasks = ["t1": "planned"]
        let node = ScriptedNode(tasks: [task("t1", "Book the hotel"), task("t2", "Renew the passport")])

        let report = await ProactiveWatch(source: node).check(against: ledger)

        XCTAssertEqual(report.message, "A new task landed: “Renew the passport”.")
    }

    func testATaskThatMovedIsNews() async {
        var ledger = seeded()
        ledger.knownTasks = ["t1": "planned"]
        let node = ScriptedNode(tasks: [task("t1", "Book the hotel", "in_progress")])

        let report = await ProactiveWatch(source: node).check(against: ledger)

        XCTAssertEqual(report.message, "“Book the hotel” is now in progress.")
    }

    func testATaskThatLeftTheListIsNotClaimedToBeDone() async {
        var ledger = seeded()
        ledger.knownTasks = ["t1": "planned"]
        let node = ScriptedNode(tasks: [])

        let report = await ProactiveWatch(source: node).check(against: ledger)

        // `sage_backlog` returns open tasks only, so an absence means finished
        // *or* dropped and this cannot tell which.
        XCTAssertEqual(report.message, "A task came off the list.")
    }

    // MARK: One message, not five

    func testEverythingThatHappenedArrivesAsOneMessage() async {
        var ledger = seeded()
        ledger.knownTasks = ["t1": "planned"]
        let node = ScriptedNode(
            messages: [message("p1", from: "Cerebrum", body: "One.")],
            tasks: [task("t1", "Book the hotel", "blocked"), task("t2", "Renew the passport")]
        )

        let report = await ProactiveWatch(source: node).check(against: ledger)

        let message = try? XCTUnwrap(report.message)
        XCTAssertEqual(message?.components(separatedBy: "\n\n").count, 3)
        XCTAssertTrue(message?.contains("Cerebrum") ?? false)
        XCTAssertTrue(message?.contains("Renew the passport") ?? false)
        XCTAssertTrue(message?.contains("blocked") ?? false)
    }

    func testALongListIsCountedRatherThanRecited() async {
        let node = ScriptedNode(
            messages: (1...9).map { message("p\($0)", body: "Message \($0).") }
        )

        let report = await ProactiveWatch(source: node).check(against: seeded())

        XCTAssertTrue(report.message?.contains("…and 5 more") ?? false, report.message ?? "")
    }

    // MARK: A node having a bad day

    func testANodeThatWillNotAnswerIsSilentRatherThanAnError() async {
        let node = ScriptedNode(refuses: true)

        let report = await ProactiveWatch(source: node).check(against: seeded())

        XCTAssertNil(
            report.message,
            "a check nobody asked for must not put an error on the owner's phone"
        )
    }
}

// MARK: - When it looks

final class ProactiveScheduleTests: XCTestCase {

    private let noon = Date(timeIntervalSince1970: 1_785_240_000)

    private func at(_ hour: Int) -> Date {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: noon)
        components.hour = hour
        return Calendar.current.date(from: components) ?? noon
    }

    func testTurnedOffMeansItNeverLooks() {
        XCTAssertFalse(ProactiveSchedule.isDue(
            now: at(12),
            lastChecked: nil,
            preferences: ProactivePreferences(isOn: false)
        ))
    }

    func testItLooksTheFirstTimeItIsSwitchedOn() {
        XCTAssertTrue(ProactiveSchedule.isDue(
            now: at(12),
            lastChecked: nil,
            preferences: ProactivePreferences(isOn: true)
        ))
    }

    func testItWaitsTheOwnersInterval() {
        let preferences = ProactivePreferences(isOn: true, everyMinutes: 60)

        XCTAssertFalse(ProactiveSchedule.isDue(
            now: at(12),
            lastChecked: at(12).addingTimeInterval(-59 * 60),
            preferences: preferences
        ))
        XCTAssertTrue(ProactiveSchedule.isDue(
            now: at(12),
            lastChecked: at(12).addingTimeInterval(-61 * 60),
            preferences: preferences
        ))
    }

    func testAnAbsurdIntervalIsClampedRatherThanObeyed() {
        // The file is editable by hand, and one minute is a phone that buzzes
        // all day.
        let preferences = ProactivePreferences(isOn: true, everyMinutes: 1)

        XCTAssertEqual(preferences.clampedMinutes, ProactivePreferences.fastest)
        XCTAssertFalse(ProactiveSchedule.isDue(
            now: at(12),
            lastChecked: at(12).addingTimeInterval(-5 * 60),
            preferences: preferences
        ))
    }

    func testAClockCorrectedBackwardsDoesNotStopItForever() {
        XCTAssertTrue(ProactiveSchedule.isDue(
            now: at(12),
            lastChecked: at(12).addingTimeInterval(60 * 60 * 24 * 365),
            preferences: ProactivePreferences(isOn: true)
        ))
    }

    func testItStaysQuietAtNight() {
        let preferences = ProactivePreferences(isOn: true, quietFrom: 22, quietUntil: 8)

        XCTAssertTrue(preferences.isQuiet(at: at(23)))
        XCTAssertTrue(preferences.isQuiet(at: at(3)))
        XCTAssertFalse(preferences.isQuiet(at: at(9)))
        XCTAssertFalse(ProactiveSchedule.isDue(
            now: at(3),
            lastChecked: nil,
            preferences: preferences
        ))
    }

    func testNoQuietHoursIsNotSilenceForever() {
        // `from == until` reads as an empty range, and the alternative reading —
        // silent always — would switch the feature off through the back door.
        let preferences = ProactivePreferences(isOn: true, quietFrom: 8, quietUntil: 8)

        XCTAssertFalse(preferences.isQuiet(at: at(8)))
        XCTAssertFalse(preferences.isQuiet(at: at(20)))
    }

    func testItIsOffUntilSomebodyTurnsItOn() {
        // The default that matters most in this file: every other message this
        // appliance sends is an answer to something.
        XCTAssertFalse(ProactivePreferences().isOn)
    }
}

// MARK: - Reading the node's backlog

final class SageBacklogReadingTests: XCTestCase {

    func testItReadsTheNodesOwnShape() {
        let reply = """
        {"message":"You have 2 assigned open tasks across 2 domains.",
         "tasks_by_domain":{
           "voice-interface":[{"memory_id":"a0c1","content":"[TASK] Apply for the UOB card",
                               "task_status":"planned"}],
           "mynah-home":[{"memory_id":"298e","content":"[TASK] Send car for servicing",
                          "task_status":"in_progress"}]},
         "total_open":2}
        """

        let tasks = SageProactiveSource.tasks(inBacklog: reply)

        XCTAssertEqual(tasks.count, 2)
        XCTAssertEqual(tasks.first?.id, "298e")
        XCTAssertEqual(
            tasks.first?.title, "Send car for servicing",
            "[TASK] is how the node stores it and not how anybody says it"
        )
        XCTAssertEqual(tasks.first?.status, "in_progress")
    }

    func testTheOrderIsTheSameTwiceRunning() {
        let reply = """
        {"tasks_by_domain":{"b":[{"memory_id":"2","content":"Two","task_status":"planned"}],
                            "a":[{"memory_id":"1","content":"One","task_status":"planned"}]}}
        """

        XCTAssertEqual(
            SageProactiveSource.tasks(inBacklog: reply).map(\.id),
            ["1", "2"],
            "a message whose lines shuffle between checks reads as more having happened"
        )
    }

    func testSomethingUnreadableIsAnEmptyBacklogRatherThanACrash() {
        XCTAssertEqual(SageProactiveSource.tasks(inBacklog: "Error: not authorised").count, 0)
        XCTAssertEqual(SageProactiveSource.tasks(inBacklog: "").count, 0)
        XCTAssertEqual(SageProactiveSource.tasks(inBacklog: "{}").count, 0)
    }
}
