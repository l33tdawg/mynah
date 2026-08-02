import XCTest
@testable import SageVoiceCore

/// **A task with no date is a task nothing can act on.**
///
/// Caught live on 3 August 2026. Asked to be reminded to call somebody at ten,
/// Mynah stored:
///
///     Call Amy — reminder set for today at 10:00
///
/// Fine to read, useless to a machine. `SpokenDate.writtenDate` refuses it —
/// correctly, since "today" only means anything beside the moment it was
/// written, and a stored task outlives that moment by design. So the task had no
/// date: it sorted with the undated at the bottom of the board, and the reminder
/// ladder never looked at it. Two symptoms, one cause.
///
/// The prompt already told the model to write the full date. It did this anyway,
/// and when the owner asked it directly it fixed the task without complaint —
/// which is the whole argument for doing it here instead. "Usually complies"
/// produces a list that is usually sorted and reminders that usually fire, and
/// the failures are silent.
final class DatedTaskWritesTests: XCTestCase {

    /// Monday 3 August 2026, 07:13 in Kuala Lumpur — when he actually asked.
    private let now = Date(timeIntervalSince1970: 1_785_712_380)

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kuala_Lumpur")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    private func dated(_ title: String) -> String {
        DatedTaskWrites.dated(title, now: now, calendar: calendar)
    }

    /// Reads it back with the same parser the board and the ladder use. A
    /// rewrite that this cannot read is a rewrite that changed nothing.
    private func readsBack(_ title: String) -> String? {
        guard let date = SpokenDate.writtenDate(in: dated(title), calendar: calendar) else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    // MARK: The one that happened

    func testTheCallAmyTask() {
        XCTAssertEqual(readsBack("Call Amy — reminder set for today at 10:00"), "2026-08-03 10:00")
    }

    func testTheOwnerCanStillReadIt() {
        let rewritten = dated("Call Amy — reminder set for today at 10:00")

        XCTAssertTrue(rewritten.hasPrefix("Call Amy"), rewritten)
        XCTAssertTrue(rewritten.contains("Monday 3 August 2026"), rewritten)
    }

    // MARK: The rest of the phrases

    func testTomorrow() { XCTAssertEqual(readsBack("chiro tomorrow at 11am"), "2026-08-04 11:00") }
    func testNextWeek() { XCTAssertEqual(readsBack("haircut next week"), "2026-08-10 00:00") }
    func testAWeekday() { XCTAssertEqual(readsBack("meeting on wednesday"), "2026-08-05 00:00") }
    func testInTwoWeeks() { XCTAssertEqual(readsBack("renew it in 2 weeks"), "2026-08-17 00:00") }

    /// A day with no time stays a day. The stamp must not acquire an hour on the
    /// way through, or the ladder would start counting down to a time nobody
    /// named.
    func testADayWithNoTimeGetsNoTime() {
        let rewritten = dated("haircut next week")

        XCTAssertFalse(rewritten.contains(":"), rewritten)
        XCTAssertFalse(rewritten.lowercased().contains("am"), rewritten)
    }

    // MARK: What it leaves alone

    /// Already readable. Rewriting a sentence that works is how you get
    /// "Chiro Wednesday 5 August 2026 (Wednesday 5 August 2026)".
    func testATitleThatAlreadyHasADateIsUntouched() {
        let already = "Chiropractor appointment at One Spine TTDI Wednesday 5 August 2026, 11am"

        XCTAssertEqual(dated(already), already)
    }

    /// Mynah's own corrected version, which must survive a second pass through
    /// this untouched.
    func testTheTitleTheModelFixedByHandIsUntouched() {
        let fixed = "Call Amy — Monday 3 August 2026 at 10:00"

        XCTAssertEqual(dated(fixed), fixed)
    }

    /// **Something with no deadline must not acquire one.** Stamping today's
    /// date on "buy eggs" would invent a reminder for a thing that cannot be
    /// late — the exact failure the date parser refuses everywhere else.
    func testUndatedWorkStaysUndated() {
        for title in [
            "buy eggs",
            "Apply for the UOB Visa Infinite — contact a UOB agent to start the application",
            "Apply for Thailand Digital Arrival Card before travelling"
        ] {
            XCTAssertEqual(dated(title), title)
            XCTAssertNil(SpokenDate.writtenDate(in: dated(title), calendar: calendar), title)
        }
    }

    /// Two days in one sentence stays ambiguous. Picking one silently is how the
    /// wrong appointment gets the reminder, and an undated task is something the
    /// owner can still fix.
    func testTwoDaysInOneSentenceAreNotGuessedAt() {
        let two = "move the chiro from wednesday to friday"

        XCTAssertEqual(dated(two), two)
    }

    /// A numeric date is refused at the parser and must not be rescued here —
    /// "5/8" is two different days depending on who wrote it.
    func testNumericDatesAreStillRefused() {
        let numeric = "Chiro on 5/8"

        XCTAssertEqual(dated(numeric), numeric)
    }

    // MARK: Shape

    /// The year is always written. Without it a date is read as the current
    /// year, which is right until the last week of December and then wrong for a
    /// fortnight, in the direction that matters.
    func testTheYearIsAlwaysThere() {
        for title in ["call them tomorrow at 3pm", "haircut next week", "renew it next month"] {
            XCTAssertTrue(dated(title).contains("2026"), dated(title))
        }
    }

    /// No doubled punctuation where the sentence already ended.
    func testItDoesNotLeaveDanglingPunctuation() {
        let rewritten = dated("Call Amy — reminder set for today at 10:00.")

        XCTAssertFalse(rewritten.contains(". ("), rewritten)
    }

    /// Same words, same instant, same answer. This runs on every task write, so
    /// it had better be a function.
    func testItIsAFunction() {
        XCTAssertEqual(dated("chiro tomorrow at 11am"), dated("chiro tomorrow at 11am"))
    }
}
