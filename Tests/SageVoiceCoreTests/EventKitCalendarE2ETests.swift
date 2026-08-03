import XCTest
import EventKit
@testable import SageVoiceCore

/// The half `CalendarMirrorTests` cannot reach: a real calendar, on this Mac.
///
/// **Off unless two things are true**, and both matter:
///
///   - `MYNAH_E2E_CALENDAR=1`, because this writes to the Calendar database.
///   - macOS has *already* granted full calendar access to whatever is running
///     the tests. Nothing here ever asks. A process with no
///     `NSCalendarsFullAccessUsageDescription` in its bundle — which a bare
///     `xctest` runner does not have — is killed by the system for asking, so a
///     test that requested access would not fail, it would take the whole suite
///     down with it.
///
/// It writes into a calendar of its own named "Mynah tests", never the real one,
/// and removes it at the end whatever happens.
///
/// The permission-granting path itself is exercised by `sage-voiced calendar`,
/// which runs inside the app bundle where the usage string is.
final class EventKitCalendarE2ETests: XCTestCase {

    private static let testCalendarTitle = "Mynah tests"

    private func liveCalendar() throws -> EventKitCalendar {
        guard ProcessInfo.processInfo.environment["MYNAH_E2E_CALENDAR"] == "1" else {
            throw XCTSkip("set MYNAH_E2E_CALENDAR=1 to run against the real Calendar")
        }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw XCTSkip(
                "this process has not been granted full calendar access, and asking for it "
                    + "from a bare test runner would kill the suite — run "
                    + "`sage-voiced calendar` from inside Mynah.app instead"
            )
        }
        return EventKitCalendar(title: Self.testCalendarTitle, log: { print($0) })
    }

    private func entry(_ id: String, _ title: String, hoursFromNow: Double, allDay: Bool = false) -> CalendarEntry {
        CalendarEntry(
            taskID: id,
            title: title,
            starts: Date().addingTimeInterval(hoursFromNow * 3600),
            isAllDay: allDay
        )
    }

    /// Add, find it again, change it, remove it — the whole life of one mirrored
    /// task, against the real EventKit.
    ///
    /// The identifier surviving between steps is the part worth proving: without
    /// it nothing can ever be updated or deleted, and every sync would pile a
    /// second copy on top of the first.
    func testAnEventCanBeWrittenFoundChangedAndRemoved() async throws {
        let calendar = try liveCalendar()
        defer { try? calendar.forget() }

        let granted = await calendar.prepare()
        XCTAssertTrue(granted, "access is granted, so preparing must succeed")

        let eventID = try await calendar.add(entry("task-1", "Dentist", hoursFromNow: 26))
        XCTAssertFalse(eventID.isEmpty)

        // A separate store, because the question is whether this survived being
        // written rather than whether one object still holds it in memory.
        let reader = EKEventStore()
        let written = try XCTUnwrap(reader.event(withIdentifier: eventID), "the event is not in the calendar")
        XCTAssertEqual(written.title, "Dentist")
        XCTAssertEqual(written.calendar.title, Self.testCalendarTitle)
        XCTAssertEqual(written.alarms?.count, 3, "a timed event gets the ladder's three rungs")

        let moved = entry("task-1", "Dentist, moved", hoursFromNow: 50)
        let sameEvent = try await calendar.update(moved, eventID: eventID)
        let changed = try XCTUnwrap(EKEventStore().event(withIdentifier: sameEvent))
        XCTAssertEqual(changed.title, "Dentist, moved")
        XCTAssertEqual(
            changed.alarms?.count, 3,
            "alarms are replaced, not appended — four ticks would otherwise mean twelve"
        )

        try await calendar.remove(eventID: sameEvent)
        XCTAssertNil(EKEventStore().event(withIdentifier: sameEvent), "the event is still there")
    }

    /// An all-day task comes out as an all-day event with two alarms, not as
    /// something at midnight.
    func testAnAllDayTaskIsAnAllDayEvent() async throws {
        let calendar = try liveCalendar()
        defer { try? calendar.forget() }
        _ = await calendar.prepare()

        let eventID = try await calendar.add(
            entry("task-2", "Meeting with TII IT", hoursFromNow: 48, allDay: true)
        )
        let written = try XCTUnwrap(EKEventStore().event(withIdentifier: eventID))

        XCTAssertTrue(written.isAllDay)
        XCTAssertEqual(written.alarms?.count, 2)
    }

    /// **The owner deleted it himself.** He is entitled to; the honest response
    /// is to put the current one back rather than to report a fault he caused on
    /// purpose.
    func testAnEventTheOwnerDeletedIsWrittenAgainRatherThanFailing() async throws {
        let calendar = try liveCalendar()
        defer { try? calendar.forget() }
        _ = await calendar.prepare()

        let replacement = try await calendar.update(
            entry("task-3", "Chiro", hoursFromNow: 5),
            eventID: "an-identifier-that-is-not-in-any-calendar"
        )

        let written = try XCTUnwrap(EKEventStore().event(withIdentifier: replacement))
        XCTAssertEqual(written.title, "Chiro")
    }

    /// Removing something already gone is a success, because the end state is
    /// the one that was asked for.
    func testRemovingSomethingAlreadyGoneIsFine() async throws {
        let calendar = try liveCalendar()
        defer { try? calendar.forget() }
        _ = await calendar.prepare()

        try await calendar.remove(eventID: "an-identifier-that-is-not-in-any-calendar")
    }

    /// A whole sync, driven the way the daemon drives it: two dated tasks in,
    /// one moved, one finished.
    func testASyncFollowsTheTaskListThroughARound() async throws {
        let calendar = try liveCalendar()
        defer { try? calendar.forget() }
        let sync = CalendarSync(calendar: calendar, log: { print($0) })

        let year = Calendar.current.component(.year, from: Date()) + 1
        let dentist = WatchedTask(
            id: "a", title: "Dentist — Tuesday 4 August \(year), 1pm", status: "open"
        )
        let chiro = WatchedTask(
            id: "b", title: "Chiro — Wednesday 5 August \(year), 11am", status: "open"
        )

        let first = await sync.run(tasks: [dentist, chiro], ledger: CalendarLedger())
        XCTAssertEqual(first.ledger.events.count, 2, first.trouble ?? "")
        XCTAssertEqual(first.mirrored, ["a", "b"])

        // Same list again: nothing to do, and nothing done.
        let second = await sync.run(tasks: [dentist, chiro], ledger: first.ledger)
        XCTAssertEqual(second.ledger, first.ledger)

        // One finished, one moved.
        let moved = WatchedTask(
            id: "b", title: "Chiro — Thursday 6 August \(year), 4pm", status: "open"
        )
        let third = await sync.run(tasks: [moved], ledger: second.ledger)
        XCTAssertNil(third.ledger.events["a"], "the finished task's event should be gone")
        XCTAssertNotNil(third.ledger.events["b"])

        let survivor = try XCTUnwrap(EKEventStore().event(withIdentifier: third.ledger.events["b"]!))
        XCTAssertEqual(survivor.title, "Chiro")
    }
}
