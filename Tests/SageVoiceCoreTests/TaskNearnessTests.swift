import XCTest
@testable import MynahMac
@testable import SageVoiceCore

/// **Which cards get a border, and which deliberately do not.**
///
/// The owner, looking at a 10am task sitting four cards down: *"things that are
/// due today should be at the top probably with a 'blue' border for the card
/// perhaps to show its something happening soon"*, then *"use orange then for
/// due tomorrow"*.
@MainActor
final class TaskNearnessTests: XCTestCase {

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kuala_Lumpur")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    /// Monday 3 August 2026, 07:40 in Kuala Lumpur.
    private let now = Date(timeIntervalSince1970: 1_785_714_000)

    private func task(_ title: String) -> BoardTask {
        BoardTask(id: UUID().uuidString, title: title, domain: "mynah-home", createdAt: nil)
    }

    private func nearness(_ title: String) -> TaskNearness? {
        TaskNearness.of(task(title), now: now, calendar: calendar)
    }

    // MARK: The two he asked for

    func testDueTodayIsMarked() {
        XCTAssertEqual(nearness("Call Amy — Monday 3 August 2026 at 10:00"), .today)
    }

    func testDueTomorrowIsMarked() {
        XCTAssertEqual(nearness("Meeting with TII IT on Tuesday 4 August 2026"), .tomorrow)
    }

    /// Later today still counts as today after the hour has passed — the card is
    /// about the day, and a 10am task read at 11am is still today's business
    /// until the ladder asks about it tomorrow morning.
    func testEarlierTodayStillReadsAsToday() {
        let later = calendar.date(from: DateComponents(year: 2026, month: 8, day: 3, hour: 23, minute: 0))!

        XCTAssertEqual(
            TaskNearness.of(task("Call Amy — Monday 3 August 2026 at 10:00"), now: later, calendar: calendar),
            .today
        )
    }

    // MARK: What stays plain

    func testTheRestOfHisBoardIsUnmarked() {
        XCTAssertNil(nearness("Chiropractor appointment at One Spine TTDI Wednesday 5 August 2026, 11am"))
        XCTAssertNil(nearness("Haircut at Trufitt & Hill Bangsar, Thursday 6 August 2026, 11am"))
        XCTAssertNil(nearness("Donsak to Koh Phangan ferry at 14:30, Monday 10 August 2026"))
        XCTAssertNil(nearness("Check in at Brillianest Hotel, Hatyai on Wednesday 19 August 2026."))
    }

    /// Undated work is not soon. It has no deadline at all, and a border would
    /// be claiming one.
    func testUndatedWorkIsNeverMarked() {
        XCTAssertNil(nearness("buy eggs"))
        XCTAssertNil(nearness("Apply for Thailand Digital Arrival Card before travelling"))
        XCTAssertNil(nearness("Apply for UOB Visa Infinite — contact a UOB agent"))
    }

    /// **Overdue is deliberately unmarked**, and this is the assertion that
    /// records the decision rather than leaving it to look like an oversight.
    ///
    /// A third colour on this board would be the fourth job a colour has done
    /// here, and the last time that happened the owner read a yellow mark on a
    /// stale list as "Signal has crashed". The ladder already handles lapsed
    /// work properly — in a message, in words, with a way to answer. A border
    /// cannot be answered.
    func testOverdueGetsNoBorder() {
        XCTAssertNil(nearness("Something that was due Sunday 2 August 2026, 11am"))
        XCTAssertNil(nearness("Long gone, Wednesday 1 July 2026"))
    }

    /// The bug that started all of this: an undated "today" sorts and marks as
    /// nothing. `DatedTaskWrites` is what stops it being written that way, and
    /// this pins why the border alone would not have been enough.
    func testARelativeDateInStorageIsNotADate() {
        XCTAssertNil(nearness("Call Amy — reminder set for today at 10:00"))
    }

    // MARK: Ordering, which he also asked about

    /// With a real date on it, the 10am task goes to the top on its own — the
    /// sort was already right and was being fed a task it could not read.
    func testTheDatedCallGoesToTheTop() {
        let board = [
            task("Check in at Butterfly Hotel Betong — booking number 1755889226, Sunday 9 August 2026"),
            task("Donsak to Koh Phangan ferry at 14:30, Monday 10 August 2026"),
            task("Check in at Brillianest Hotel, Hatyai on Wednesday 19 August 2026."),
            task("Call Amy — Monday 3 August 2026 at 10:00"),
            task("Apply for Thailand Digital Arrival Card before travelling"),
            task("Chiropractor appointment at One Spine TTDI Wednesday 5 August 2026, 11am")
        ]

        let ordered = TaskBoard.byWhenTheyHappen(board)

        XCTAssertTrue(ordered.first?.title.hasPrefix("Call Amy") ?? false, ordered.map(\.title).description)
        XCTAssertTrue(ordered.last?.title.hasPrefix("Apply for Thailand") ?? false, "undated goes last")
    }
}
