import XCTest
@testable import MynahMac
@testable import SageVoiceCore

/// **"if there's a clash, can we put them like into 1 bounding box - so its
/// clear it happens at the same time".**
///
/// Observed on his board: a dentist appointment and a Google Meet, both written
/// for Tuesday 4 August at 1pm, drawn as two ordinary cards with another task
/// between them. Both were correctly dated and correctly ordered; nothing said
/// they were the same slot.
///
/// The thing this must not become is a warning. His own example of a clash is
/// two errands that share a slot perfectly well — *"some things can be done
/// simultaneously; like send car to car wash and get groceries"* — so grouping
/// states a fact about the clock and leaves the judgement where it belongs.
final class TaskClusterTests: XCTestCase {

    private func task(_ title: String, id: String = UUID().uuidString) -> BoardTask {
        BoardTask(id: id, title: title)
    }

    private func clustered(_ titles: [String]) -> [TaskCluster] {
        TaskBoard.clustered(titles.enumerated().map { task($1, id: "\($0)") })
    }

    // MARK: - The board he was looking at

    func testTwoThingsAtTheSameHourShareABox() {
        let boxes = clustered([
            "Dentist appointment — Tuesday 4 August 2026, 1pm",
            "Call with Daniel & Tenzai — Tuesday 4 August 2026, 1pm on Google Meet"
        ])

        XCTAssertEqual(boxes.count, 1)
        XCTAssertTrue(boxes[0].isShared)
        XCTAssertEqual(boxes[0].tasks.count, 2)
        XCTAssertEqual(boxes[0].sharedTime, "1pm")
    }

    func testDifferentHoursOnTheSameDayStayApart() {
        let boxes = clustered([
            "Call with Credence Tuesday 4 August 2026 at 11am on Microsoft Teams",
            "Dentist appointment — Tuesday 4 August 2026, 1pm"
        ])

        XCTAssertEqual(boxes.count, 2)
        XCTAssertFalse(boxes.contains(where: \.isShared))
        XCTAssertNil(boxes[0].sharedTime)
    }

    func testThreeAtOnceIsOneBoxNotTwo() {
        let boxes = clustered([
            "Car wash — Tuesday 4 August 2026, 1pm",
            "Groceries — Tuesday 4 August 2026, 1pm",
            "Dentist appointment — Tuesday 4 August 2026, 1pm"
        ])

        XCTAssertEqual(boxes.count, 1)
        XCTAssertEqual(boxes[0].tasks.count, 3)
    }

    // MARK: - What is not the same moment

    /// **A shared day is not a shared time**, and this is the distinction the
    /// whole feature turns on. Two things due Friday with no hour written are
    /// not happening at once; a day holds plenty. It is the same rule
    /// `ReminderLadder` follows — no hour was named, so none may be invented.
    func testTwoTasksOnTheSameDayWithNoTimeAreNotBoxed() {
        let boxes = clustered([
            "Apply for Thailand Digital Arrival Card by Friday 7 August 2026",
            "Renew the road tax before Friday 7 August 2026"
        ])

        XCTAssertEqual(boxes.count, 2)
        XCTAssertFalse(boxes.contains(where: \.isShared))
    }

    /// One dated, one not, at what would be the same day. Still two boxes.
    func testADatedAndAnUndatedTaskNeverShareABox() {
        let boxes = clustered([
            "Dentist appointment — Tuesday 4 August 2026, 1pm",
            "Apply for the UOB card"
        ])

        XCTAssertEqual(boxes.count, 2)
        XCTAssertFalse(boxes.contains(where: \.isShared))
    }

    func testTheSameHourOnDifferentDaysIsNotAClash() {
        let boxes = clustered([
            "Dentist appointment — Tuesday 4 August 2026, 1pm",
            "Chiropractor — Wednesday 5 August 2026, 1pm"
        ])

        XCTAssertEqual(boxes.count, 2)
    }

    /// Every task undated: the board still renders, one box each.
    func testAnUndatedBoardIsAllSingles() {
        let boxes = clustered(["Apply for the UOB card", "Fix the gate", "Call the plumber"])

        XCTAssertEqual(boxes.count, 3)
        XCTAssertFalse(boxes.contains(where: \.isShared))
    }

    func testAnEmptyColumnProducesNoBoxes() {
        XCTAssertTrue(TaskBoard.clustered([]).isEmpty)
    }

    // MARK: - Only what is adjacent

    /// **Contiguity is a correctness rule, not an optimisation.** The list
    /// arrives sorted by `byWhenTheyHappen`, so anything simultaneous is already
    /// adjacent — and boxing across a task that happens *between* two others
    /// would draw a box whose contents are not contiguous in time, which is a
    /// lie about the day.
    ///
    /// The input here is deliberately mis-sorted to prove the rule holds.
    func testTasksAreOnlyBoxedWithTheirNeighbours() {
        let boxes = clustered([
            "Dentist appointment — Tuesday 4 August 2026, 1pm",
            "Call with Credence — Tuesday 4 August 2026, 11am",
            "Call with Daniel — Tuesday 4 August 2026, 1pm"
        ])

        XCTAssertEqual(boxes.count, 3, "the 11am sits between them, so nothing is boxed")
        XCTAssertFalse(boxes.contains(where: \.isShared))
    }

    /// Sorted first, which is how the column actually calls it — the two 1pms
    /// become adjacent and box.
    func testTheSameThreeTasksBoxOnceTheyAreInOrder() {
        let tasks = [
            task("Dentist appointment — Tuesday 4 August 2026, 1pm", id: "a"),
            task("Call with Credence — Tuesday 4 August 2026, 11am", id: "b"),
            task("Call with Daniel — Tuesday 4 August 2026, 1pm", id: "c")
        ]
        let boxes = TaskBoard.clustered(TaskBoard.byWhenTheyHappen(tasks))

        XCTAssertEqual(boxes.count, 2)
        XCTAssertEqual(boxes.map(\.tasks.count), [1, 2], "11am alone, then the two 1pms")
    }

    // MARK: - Identity

    /// The id has to survive a redraw or SwiftUI re-creates the box on every
    /// tick, and has to differ between boxes or two of them collapse into one.
    func testABoxIsIdentifiedByWhatIsInIt() {
        let first = clustered([
            "Dentist — Tuesday 4 August 2026, 1pm",
            "Meet — Tuesday 4 August 2026, 1pm"
        ])
        let again = clustered([
            "Dentist — Tuesday 4 August 2026, 1pm",
            "Meet — Tuesday 4 August 2026, 1pm"
        ])

        XCTAssertEqual(first.map(\.id), again.map(\.id))
        XCTAssertEqual(Set(first.map(\.id)).count, first.count)
    }

    // MARK: - How the shared time is written

    /// Written the way the owner's own titles spell it. A board whose every task
    /// says "1pm" must not sprout a label saying "13:00" — and `Date.formatted`
    /// is locale-driven, so it would on a 24-hour Mac.
    func testTheSharedTimeIsSpelledTheWayTheTasksSpellIt() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kuala_Lumpur") ?? .current

        func at(_ hour: Int, _ minute: Int) -> Date {
            calendar.date(from: DateComponents(
                year: 2026, month: 8, day: 4, hour: hour, minute: minute
            ))!
        }

        XCTAssertEqual(TaskBoard.clock(at(13, 0), calendar: calendar), "1pm")
        XCTAssertEqual(TaskBoard.clock(at(11, 0), calendar: calendar), "11am")
        XCTAssertEqual(TaskBoard.clock(at(10, 30), calendar: calendar), "10:30am")
        XCTAssertEqual(TaskBoard.clock(at(0, 0), calendar: calendar), "12am")
        XCTAssertEqual(TaskBoard.clock(at(12, 0), calendar: calendar), "12pm")
        XCTAssertEqual(TaskBoard.clock(at(23, 45), calendar: calendar), "11:45pm")
    }
}
