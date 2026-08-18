// **Mac-only, because it tests `MynahMac`.**
//
// `MynahMac` is the AppKit/SwiftUI half of this package, and Package.swift does
// not declare that target off Darwin — so the import below resolves on a Mac
// and nowhere else. The guard wraps the whole file rather than just the import,
// because every test in here drives a Mac type: a file that compiled down to an
// empty test class would let Linux report a green suite that ran nothing, which
// is the exact failure this branch exists to stop. See `coreTestDependencies`
// in Package.swift.
#if os(macOS)
import XCTest
@testable import MynahMac
@testable import SageVoiceCore

/// Day headings down the task column.
///
/// The owner: *"can we add day markers to the left hand column - would be really
/// useful"*, and then the half that decides the design: *"so if there's something
/// on thursday it says so, friday if nothing says open / free"*.
///
/// **The empty days are the whole feature.** He can read the dates off the
/// cards; what a list of cards cannot tell him is where the gaps are, and that
/// is the question he actually puts to the board — when can this go?
final class TaskDayMarkerTests: XCTestCase {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kuala_Lumpur")!
        return calendar
    }

    /// Tuesday 4 August 2026, 09:00 — the morning of his screenshot.
    private var tuesday: Date {
        var parts = DateComponents()
        parts.year = 2026
        parts.month = 8
        parts.day = 4
        parts.hour = 9
        return calendar.date(from: parts)!
    }

    private func task(_ title: String, id: String = UUID().uuidString) -> BoardTask {
        BoardTask(id: id, title: title, progress: .planned, domain: "mynah-home")
    }

    private func days(_ rows: [TaskRow]) -> [String] {
        rows.compactMap {
            if case .day(let day) = $0 {
                return day.isFree ? "\(day.title) FREE" : day.title
            }
            return nil
        }
    }

    // MARK: Naming the days

    func testTodayAndTomorrowAreNamedRatherThanDated() {
        let rows = TaskBoard.rows(
            TaskBoard.byWhenTheyHappen([
                task("Send Cayenne to Prestige — Tuesday 4 August 2026, 10:00"),
                task("Call with Najwa at 5pm on Wednesday 5 August 2026")
            ]),
            now: tuesday,
            calendar: calendar
        )

        XCTAssertEqual(days(rows).prefix(2).map { $0 }, ["Today", "Tomorrow"])
    }

    func testAFurtherDayIsWrittenOutWithItsWeekday() {
        let rows = TaskBoard.rows(
            TaskBoard.byWhenTheyHappen([
                task("Haircut at Trufitt & Hill Bangsar, Thursday 6 August 2026, 11am")
            ]),
            now: tuesday,
            calendar: calendar
        )

        XCTAssertTrue(days(rows).contains("Thursday 6 August"), "\(days(rows))")
    }

    /// One heading per day however many cards sit under it — the clash box
    /// already says what two cards at 1pm have in common.
    func testADayWithSeveralThingsIsHeadedOnce() {
        let rows = TaskBoard.rows(
            TaskBoard.byWhenTheyHappen([
                task("Dentist appointment — Tuesday 4 August 2026, 1pm"),
                task("Call with Daniel & Tenzai — Tuesday 4 August 2026, 1pm"),
                task("Send Cayenne to Prestige — Tuesday 4 August 2026, 10:00")
            ]),
            now: tuesday,
            calendar: calendar
        )

        XCTAssertEqual(days(rows).filter { $0 == "Today" }.count, 1, "\(days(rows))")
    }

    // MARK: The free days, which are the point

    func testADayWithNothingOnSaysSo() {
        let rows = TaskBoard.rows(
            TaskBoard.byWhenTheyHappen([
                task("Haircut at Trufitt & Hill Bangsar, Thursday 6 August 2026, 11am")
            ]),
            now: tuesday,
            calendar: calendar
        )

        // Wednesday sits between today and the haircut with nothing on it.
        XCTAssertTrue(days(rows).contains("Tomorrow FREE"), "\(days(rows))")
    }

    /// The stretch *after* the last appointment is the part he asks about most,
    /// and the part a naive "group by day" would say nothing at all about.
    func testTheRestOfTheWeekIsReportedFreeAfterTheLastThing() {
        let rows = TaskBoard.rows(
            TaskBoard.byWhenTheyHappen([
                task("Call with Najwa at 5pm on Wednesday 5 August 2026")
            ]),
            now: tuesday,
            calendar: calendar
        )

        for day in ["Thursday 6 August FREE", "Friday 7 August FREE", "Saturday 8 August FREE"] {
            XCTAssertTrue(days(rows).contains(day), "missing \(day) in \(days(rows))")
        }
    }

    /// **Bounded, or the gaps become the list.** His own board runs to the
    /// nineteenth; eleven consecutive free rows before it would bury the two
    /// things that are actually on.
    func testFreeDaysStopAtTheHorizon() {
        let rows = TaskBoard.rows(
            TaskBoard.byWhenTheyHappen([
                task("Check in at Brillianest Hotel, Hatyai on Wednesday 19 August 2026")
            ]),
            now: tuesday,
            calendar: calendar
        )

        let free = days(rows).filter { $0.hasSuffix("FREE") }
        XCTAssertEqual(free.count, TaskBoard.freeDayHorizon)
        XCTAssertFalse(free.contains { $0.contains("18 August") }, "\(free)")
        XCTAssertTrue(days(rows).contains("Wednesday 19 August"), "\(days(rows))")
    }

    /// A gap that has already gone is not an opening.
    func testYesterdayIsNeverOfferedAsFree() {
        let rows = TaskBoard.rows(
            TaskBoard.byWhenTheyHappen([
                task("Call with TII IT at 18:00 on Monday 3 August 2026"),
                task("Dentist appointment — Tuesday 4 August 2026, 1pm")
            ]),
            now: tuesday,
            calendar: calendar
        )

        XCTAssertFalse(days(rows).contains { $0.hasSuffix("FREE") && $0.contains("August") && $0.contains("3") },
                       "\(days(rows))")
        XCTAssertTrue(days(rows).contains("Monday 3 August"), "an overdue day lost its heading: \(days(rows))")
    }

    // MARK: Work with no day at all

    func testUndatedWorkGetsItsOwnHeadingAtTheEnd() {
        let rows = TaskBoard.rows(
            TaskBoard.byWhenTheyHappen([
                task("Apply for UOB Visa Infinite — contact a UOB agent"),
                task("Dentist appointment — Tuesday 4 August 2026, 1pm")
            ]),
            now: tuesday,
            calendar: calendar
        )

        XCTAssertEqual(days(rows).last, "No date")
        // And it is last in the rows, not merely last among the headings.
        guard case .cluster(let tail) = rows.last else {
            return XCTFail("the undated heading has no cards under it: \(rows.map(\.id))")
        }
        XCTAssertTrue(tail.tasks[0].title.contains("UOB"), tail.tasks[0].title)
    }

    func testThereIsNoUndatedHeadingWhenEverythingHasADate() {
        let rows = TaskBoard.rows(
            TaskBoard.byWhenTheyHappen([task("Dentist appointment — Tuesday 4 August 2026, 1pm")]),
            now: tuesday,
            calendar: calendar
        )

        XCTAssertFalse(days(rows).contains("No date"), "\(days(rows))")
    }

    /// An empty column draws nothing rather than a week of "free" — the column
    /// already has a sentence for having no work, and seven blank days is not an
    /// improvement on it.
    func testAnEmptyListProducesNoHeadingsAtAll() {
        XCTAssertEqual(TaskBoard.rows([], now: tuesday, calendar: calendar).count, 0)
    }

    /// Nothing scheduled at all is the same case one step along: "No date" says
    /// it in one row, and a week of "free" above it would be seven rows saying
    /// the same thing louder.
    func testABoardWithNoScheduledWorkDoesNotOpenWithAFreeWeek() {
        let rows = TaskBoard.rows(
            TaskBoard.byWhenTheyHappen([
                task("Apply for UOB Visa Infinite — contact a UOB agent"),
                task("Look into the Betong road trip")
            ]),
            now: tuesday,
            calendar: calendar
        )

        XCTAssertEqual(days(rows), ["No date"], "\(days(rows))")
    }

    // MARK: Every card survives

    /// The headings are additions. A row that filtered a card out would be
    /// hiding work, which is the one thing this column may never do.
    func testEveryTaskStillAppears() {
        let titles = [
            "Send Cayenne to Prestige — Tuesday 4 August 2026, 10:00",
            "Dentist appointment — Tuesday 4 August 2026, 1pm",
            "Call with Daniel & Tenzai — Tuesday 4 August 2026, 1pm",
            "Haircut at Trufitt & Hill Bangsar, Thursday 6 August 2026, 11am",
            "Apply for UOB Visa Infinite — contact a UOB agent",
            "Check in at Brillianest Hotel, Hatyai on Wednesday 19 August 2026"
        ]
        let rows = TaskBoard.rows(
            TaskBoard.byWhenTheyHappen(titles.map { task($0) }),
            now: tuesday,
            calendar: calendar
        )

        let shown = rows.flatMap { row -> [String] in
            if case .cluster(let cluster) = row { return cluster.tasks.map(\.title) }
            return []
        }
        XCTAssertEqual(Set(shown), Set(titles), "a card was lost between the headings")
    }
}
#endif  // os(macOS)
