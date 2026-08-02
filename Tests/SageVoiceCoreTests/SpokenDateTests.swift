import XCTest
@testable import SageVoiceCore

/// **The owner's ruling, made mechanical.**
///
/// *"next wednesday means the coming wednesday - its basic logic; in 2 weeks
/// from now; next month; next week - tomorrow, day after - those are normal
/// human turn of phrases bro; its deterministic"*
///
/// Every case below is a fixed instant in a fixed zone, so these assert
/// arithmetic rather than a mood. The zone is his — Asia/Kuala_Lumpur — because
/// a parser tested only in UTC is one that has never met a day boundary that
/// matters.
final class SpokenDateTests: XCTestCase {

    /// Sunday 2 August 2026, 14:00 in Kuala Lumpur.
    private let now = Date(timeIntervalSince1970: 1_785_657_600)

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kuala_Lumpur")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    private func resolved(_ text: String) -> OwnerDate? {
        guard case .one(let date) = SpokenDate.resolve(in: text, now: now, calendar: calendar) else {
            return nil
        }
        return date
    }

    /// The day it lands on, as "yyyy-MM-dd HH:mm" in his zone.
    private func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private func assertDay(_ text: String, is expected: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let date = resolved(text) else {
            return XCTFail("\"\(text)\" resolved to nothing", file: file, line: line)
        }
        XCTAssertEqual(stamp(date.at), expected, "\"\(text)\"", file: file, line: line)
    }

    // MARK: The phrases he named

    func testTodayIsToday() { assertDay("do it today", is: "2026-08-02 00:00") }
    func testTomorrow() { assertDay("chiro tomorrow", is: "2026-08-03 00:00") }
    func testTheDayAfter() { assertDay("call them the day after", is: "2026-08-04 00:00") }
    func testDayAfterTomorrow() { assertDay("day after tomorrow", is: "2026-08-04 00:00") }
    func testNextWeek() { assertDay("haircut next week", is: "2026-08-09 00:00") }
    func testNextMonth() { assertDay("renew it next month", is: "2026-09-02 00:00") }
    func testInTwoWeeks() { assertDay("in 2 weeks", is: "2026-08-16 00:00") }
    func testInTwoWeeksFromNow() { assertDay("in 2 weeks from now", is: "2026-08-16 00:00") }
    func testWordNumbers() { assertDay("in three days", is: "2026-08-05 00:00") }
    func testInAMonth() { assertDay("in a month", is: "2026-09-02 00:00") }

    /// **The one call that actually needed making.** Half the world reads "next
    /// Wednesday" as the Wednesday after the coming one. He ruled: the coming
    /// one. A week's error on an appointment is the alternative.
    func testNextWednesdayIsTheComingWednesday() {
        assertDay("chiro next wednesday", is: "2026-08-05 00:00")
    }

    func testThisWednesdayIsTheSameDay() {
        assertDay("chiro this wednesday", is: "2026-08-05 00:00")
    }

    func testABareWeekdayIsTheSameDay() {
        assertDay("meeting with TII IT on tuesday", is: "2026-08-04 00:00")
    }

    /// Said on a Sunday, "Sunday" is the next one and never today. An
    /// appointment named by its weekday is being planned; resolving it to a day
    /// already half gone is the one reading guaranteed to be useless.
    func testAWeekdayNamedOnThatVeryDayMeansTheNextOne() {
        assertDay("brunch on sunday", is: "2026-08-09 00:00")
    }

    // MARK: Times refine a day, they do not make one

    func testAWeekdayWithATime() {
        assertDay("chiro wednesday 11am", is: "2026-08-05 11:00")
        XCTAssertEqual(resolved("chiro wednesday 11am")?.granularity, .minute)
    }

    func testAfternoonTimes() { assertDay("call them tomorrow at 3pm", is: "2026-08-03 15:00") }
    func testMinutesPastTheHour() { assertDay("tomorrow at 11:30am", is: "2026-08-03 11:30") }
    func testTwentyFourHourClock() { assertDay("tomorrow at 14:30", is: "2026-08-03 14:30") }
    func testNoon() { assertDay("lunch tomorrow at noon", is: "2026-08-03 12:00") }
    func testMidnightIsTheStartOfTheDay() { assertDay("tomorrow at midnight", is: "2026-08-03 00:00") }
    func testTwelvePM() { assertDay("tomorrow 12pm", is: "2026-08-03 12:00") }
    func testTwelveAM() { assertDay("tomorrow 12am", is: "2026-08-03 00:00") }

    /// A day named with no time stays a day. Nothing here invents nine in the
    /// morning because a `Date` has an hour field.
    func testADayWithNoTimeStaysADay() {
        XCTAssertEqual(resolved("chiro next wednesday")?.granularity, .day)
    }

    /// A time with no day is not a date. Reading it as today's 11am would
    /// schedule something for a day the owner never mentioned.
    func testATimeAloneIsNotADate() {
        XCTAssertNil(resolved("at 11am"))
    }

    // MARK: What it refuses, and why refusing is the feature

    /// "5/8" is the fifth of August to him and the eighth of May to half the
    /// internet. There is no correct guess, so there is no guess.
    func testNumericDatesAreRefused() {
        XCTAssertNil(resolved("chiro on 5/8"))
        XCTAssertNil(resolved("chiro on 05-08-2026"))
    }

    /// "at 11" has two answers eleven hours apart.
    func testABareHourIsRefused() {
        guard let date = resolved("chiro tomorrow at 11") else {
            return XCTFail("the day should still resolve")
        }
        XCTAssertEqual(date.granularity, .day, "an hour with no am/pm must not become a time")
    }

    /// Parts of a day are not times. Turning one into a clock reading would be
    /// inventing precision the owner did not offer.
    func testPartsOfADayAreNotTimes() {
        XCTAssertEqual(resolved("chiro tomorrow morning")?.granularity, .day)
        XCTAssertEqual(resolved("call them tomorrow evening")?.granularity, .day)
    }

    func testOrdinaryTextHasNoDate() {
        XCTAssertNil(resolved("remind me to buy eggs"))
        XCTAssertNil(resolved("what did the roofer say"))
    }

    // MARK: Two days in one sentence

    /// "move the chiro from Wednesday to Friday" has two anchors, and silently
    /// taking the first is how the wrong appointment gets the reminder.
    func testTwoDaysAreAmbiguousRatherThanTheFirstOne() {
        guard case .ambiguous(let phrases) = SpokenDate.resolve(
            in: "move the chiro from wednesday to friday",
            now: now,
            calendar: calendar
        ) else {
            return XCTFail("two weekdays in one sentence must not resolve silently")
        }
        XCTAssertEqual(phrases.count, 2)
    }

    /// The same day said twice is not two days. "tomorrow, so Monday" is one
    /// appointment described twice over, and asking which he meant would be
    /// pedantry.
    func testTheSameDaySaidTwiceIsOneDay() {
        assertDay("chiro tomorrow, so monday", is: "2026-08-03 00:00")
    }

    // MARK: It is a function, not a mood

    func testTheSameWordsAtTheSameInstantAlwaysGiveTheSameAnswer() {
        let once = SpokenDate.resolve(in: "chiro next wednesday 11am", now: now, calendar: calendar)
        let twice = SpokenDate.resolve(in: "chiro next wednesday 11am", now: now, calendar: calendar)

        XCTAssertEqual(once, twice)
    }

    /// Across a day boundary the answer moves with the day, which is the point
    /// of taking `now` rather than reading the clock.
    func testTomorrowMovesWithTheDay() {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
        guard case .one(let date) = SpokenDate.resolve(in: "tomorrow", now: tomorrow, calendar: calendar) else {
            return XCTFail("no date")
        }
        XCTAssertEqual(stamp(date.at), "2026-08-04 00:00")
    }
}

/// **The order a list is read in is the order it gets done in.**
///
/// Sorted by when it was written down, the board put Thursday's haircut above
/// Tuesday's meeting because the haircut was typed two seconds later. The
/// owner: *"i'm talking about the order in which they should be 'executed' /
/// reminder sent to you based on the timing - like don't remind me about
/// thursday on monday instead of telling me about things on tuesday /
/// wednesday"*.
///
/// The date is read back out of the task's own words, because that is where
/// Mynah writes it. No store of its own, and it works on tasks already on the
/// node.
final class WrittenDateTests: XCTestCase {

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kuala_Lumpur")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    private func stamp(_ text: String) -> String? {
        guard let date = SpokenDate.writtenDate(in: text, calendar: calendar) else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    /// The three the owner is actually looking at.
    func testTheTasksOnHisBoard() {
        XCTAssertEqual(stamp("Meeting with TII IT on Tuesday 4 August 2026"), "2026-08-04 00:00")
        XCTAssertEqual(
            stamp("Chiropractor appointment at One Spine TTDI Wednesday 5 August 2026, 11am"),
            "2026-08-05 11:00"
        )
        XCTAssertEqual(
            stamp("Haircut at Trufitt & Hill Bangsar, Thursday 6 August 2026, 11am"),
            "2026-08-06 11:00"
        )
    }

    func testMonthFirstAlsoReads() {
        XCTAssertEqual(stamp("Dentist August 5 2026"), "2026-08-05 00:00")
    }

    func testOrdinalsAndShortMonths() {
        XCTAssertEqual(stamp("Renewal on 5th Aug 2026"), "2026-08-05 00:00")
        XCTAssertEqual(stamp("Renewal on 5 Sept 2026"), "2026-09-05 00:00")
    }

    /// Undated work is genuinely undated — it must not acquire a date by
    /// accident, because that is a reminder for something with no deadline.
    func testTasksWithNoDateHaveNoDate() {
        XCTAssertNil(stamp("Apply for Thailand Digital Arrival Card before travelling"))
        XCTAssertNil(stamp("Apply for UOB Visa Infinite — contact a UOB agent to start the application"))
        XCTAssertNil(stamp("buy eggs"))
    }

    /// Still no numeric dates, for the same reason as everywhere else: "5/8" is
    /// two different days depending on who wrote it. It sorts with the undated,
    /// which is a task the owner can fix rather than a reminder months early.
    func testNumericDatesStillYieldNothing() {
        XCTAssertNil(stamp("Chiro on 5/8"))
        XCTAssertNil(stamp("Chiro on 05-08-2026"))
    }
}
