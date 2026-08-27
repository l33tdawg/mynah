import XCTest
@testable import SageVoiceCore

/// Calendar is a task mirror, not a side effect of proactive messaging.
final class CalendarMirrorCoordinatorTests: XCTestCase {
    private final class Source: ProactiveSource, @unchecked Sendable {
        var tasks: [WatchedTask] = []
        var failure: Error?
        private(set) var reads = 0

        func waitingMessages(limit: Int) async throws -> [AgentInboxItem] { [] }
        func openTasks() async throws -> [WatchedTask] {
            reads += 1
            if let failure { throw failure }
            return tasks
        }
    }

    private final class CalendarWriter: CalendarWriting, @unchecked Sendable {
        private(set) var added: [CalendarEntry] = []

        func prepare() async -> Bool { true }
        func add(_ entry: CalendarEntry) async throws -> String {
            added.append(entry)
            return "event-\(added.count)"
        }
        func update(_ entry: CalendarEntry, eventID: String) async throws -> String { eventID }
        func remove(eventID: String) async throws {}
    }

    private enum Failure: Error { case nodeDown }

    private func temporaryLedger() -> (directory: URL, ledger: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("calendar-immediate-\(UUID().uuidString)", isDirectory: true)
        return (directory, directory.appendingPathComponent("calendar-ledger.json"))
    }

    func testSuccessfulTaskWriteCanMirrorImmediatelyWithoutAProactiveSchedule() async throws {
        let source = Source()
        source.tasks = [WatchedTask(
            id: "flight",
            title: "Flight to Dubai, Monday 31 August 2026, 09:30",
            status: "planned"
        )]
        let writer = CalendarWriter()
        let temporary = temporaryLedger()
        defer { try? FileManager.default.removeItem(at: temporary.directory) }
        let mirror = CalendarMirrorCoordinator(
            source: source,
            calendar: CalendarSync(calendar: writer),
            ledgerURL: temporary.ledger,
            preferences: { CalendarPreferences(isOn: true) }
        )

        let outcome = await mirror.refresh()

        XCTAssertEqual(source.reads, 1)
        XCTAssertEqual(writer.added.map(\.taskID), ["flight"])
        XCTAssertEqual(outcome?.mirrored, ["flight"])
        XCTAssertEqual(CalendarLedger.load(from: temporary.ledger).events.keys.sorted(), ["flight"])
    }

    func testAFailedImmediateReadLeavesTheExistingCalendarLedgerAlone() async throws {
        let source = Source()
        source.failure = Failure.nodeDown
        let writer = CalendarWriter()
        let temporary = temporaryLedger()
        defer { try? FileManager.default.removeItem(at: temporary.directory) }
        try CalendarLedger(events: ["existing": "event-1"]).save(to: temporary.ledger)
        let mirror = CalendarMirrorCoordinator(
            source: source,
            calendar: CalendarSync(calendar: writer),
            ledgerURL: temporary.ledger,
            preferences: { CalendarPreferences(isOn: true) }
        )

        let outcome = await mirror.refresh()
        XCTAssertNil(outcome)
        XCTAssertTrue(writer.added.isEmpty)
        XCTAssertEqual(CalendarLedger.load(from: temporary.ledger).events, ["existing": "event-1"])
    }
}
