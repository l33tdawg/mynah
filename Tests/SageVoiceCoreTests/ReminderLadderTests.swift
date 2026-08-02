import XCTest
@testable import SageVoiceCore

/// **When the appliance interrupts somebody, and what it says when it does.**
///
/// The owner asked for *"some way for Mynah to set itself a reminder … like 24
/// hours before and 1 hour or 2 hours before the due date and to keep tasks past
/// their deadline but remind the user about it again from time to time"*, and
/// then ruled on the shape: overdue work is asked about at a decaying rate — the
/// morning after, then roughly weekly.
///
/// Every case here is a fixed instant in his zone. A reminder rule that can only
/// be observed by waiting until Wednesday is a rule nobody will ever check
/// again, which is how one ends up shipping an appliance that wakes somebody at
/// 3am.
final class ReminderLadderTests: XCTestCase {

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kuala_Lumpur")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    /// The three tasks actually on his board.
    private let chiro = WatchedTask(
        id: "t-chiro",
        title: "Chiropractor appointment at One Spine TTDI Wednesday 5 August 2026, 11am",
        status: "planned"
    )
    private let meeting = WatchedTask(
        id: "t-meeting",
        title: "Meeting with TII IT on Tuesday 4 August 2026",
        status: "planned"
    )
    private let eggs = WatchedTask(id: "t-eggs", title: "buy eggs", status: "planned")

    /// A moment in his zone, spelled out so the test reads like a clock.
    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: day, hour: hour, minute: minute))!
    }

    private func nudge(_ task: WatchedTask, at moment: Date) -> ReminderLadder.Nudge? {
        ReminderLadder.nudge(for: task, now: moment, calendar: calendar)
    }

    // MARK: Before a timed appointment

    /// Three days out is not news. The ladder starts at a day.
    func testNothingIsSaidDaysAhead() {
        XCTAssertNil(nudge(chiro, at: at(2, 14)))
    }

    func testTheDayBefore() {
        guard let nudge = nudge(chiro, at: at(4, 12)) else { return XCTFail("expected a nudge") }

        XCTAssertEqual(nudge.key, "t-chiro#day")
        XCTAssertTrue(nudge.text.lowercased().contains("tomorrow at 11 am"), nudge.text)
        // The date is not read back out — the reminder is about to say when it
        // is in its own words.
        XCTAssertTrue(nudge.text.hasPrefix("Chiropractor appointment at One Spine TTDI"), nudge.text)
        XCTAssertFalse(nudge.text.contains("2026"), nudge.text)
    }

    func testTwoHoursOut() {
        guard let nudge = nudge(chiro, at: at(5, 9, 30)) else { return XCTFail("expected a nudge") }

        XCTAssertEqual(nudge.key, "t-chiro#hours")
        XCTAssertTrue(nudge.text.contains("in about 2 hours"), nudge.text)
    }

    func testHalfAnHourOut() {
        guard let nudge = nudge(chiro, at: at(5, 10, 45)) else { return XCTFail("expected a nudge") }

        XCTAssertEqual(nudge.key, "t-chiro#soon")
        XCTAssertTrue(nudge.text.contains("in about 15 minutes"), nudge.text)
    }

    /// **The reason this is bands rather than alarms.**
    ///
    /// A Mac asleep from Monday night until Wednesday morning misses the day
    /// rung entirely. Three fixed alarms would fire it late, announcing an
    /// appointment "tomorrow" ninety minutes before it starts. The words come
    /// from the real gap, so a machine that wakes up late tells the truth.
    func testAMacThatSleptThroughTheDayRungDoesNotSayTomorrow() {
        guard let nudge = nudge(chiro, at: at(5, 9, 30)) else { return XCTFail("expected a nudge") }

        XCTAssertFalse(nudge.text.contains("tomorrow"), nudge.text)
    }

    /// It never promises a minute. The tick is 60 seconds wide and the message
    /// has a network to cross.
    func testItNeverPromisesPunctuality() {
        for moment in [at(5, 9, 30), at(5, 10, 45), at(5, 10, 58)] {
            guard let text = nudge(chiro, at: moment)?.text else { return XCTFail("expected a nudge") }
            XCTAssertTrue(text.contains("in about") || text.contains("in a few"), text)
        }
    }

    // MARK: Nothing twice

    func testARungAlreadySaidIsNotSaidAgain() {
        let said: Set<String> = ["t-chiro#hours"]
        let due = ReminderLadder.due(tasks: [chiro], alreadySaid: said, now: at(5, 9, 30), calendar: calendar)

        XCTAssertTrue(due.isEmpty)
    }

    /// Different rungs are different keys, so the tighter one still lands after
    /// the looser one has been delivered.
    func testATighterRungStillFiresAfterALooserOne() {
        let said: Set<String> = ["t-chiro#day"]
        let due = ReminderLadder.due(tasks: [chiro], alreadySaid: said, now: at(5, 9, 30), calendar: calendar)

        XCTAssertEqual(due.map(\.key), ["t-chiro#hours"])
    }

    /// One task can only be at one point on the ladder at a time. Two hours out
    /// is not also a day out.
    func testOnlyOneRungPerTaskPerLook() {
        let due = ReminderLadder.due(tasks: [chiro], alreadySaid: [], now: at(5, 9, 30), calendar: calendar)

        XCTAssertEqual(due.count, 1)
    }

    // MARK: A day with no hour in it

    /// The title says Tuesday and nothing else. `SpokenDate` refused to invent a
    /// time when this was stored, and the ladder must not invent one now — "in
    /// about two hours" would be counting down to midnight, which is not when
    /// the meeting is.
    func testADayWithNoTimeGetsNoHourlyRung() {
        for moment in [at(4, 9), at(4, 12), at(3, 10)] {
            let text = nudge(meeting, at: moment)?.text ?? ""
            XCTAssertFalse(text.contains("in about"), "\(moment): \(text)")
        }
    }

    func testTheMorningBefore() {
        guard let nudge = nudge(meeting, at: at(3, 9)) else { return XCTFail("expected a nudge") }

        XCTAssertEqual(nudge.key, "t-meeting#tomorrow")
        XCTAssertTrue(nudge.text.hasSuffix("— tomorrow."), nudge.text)
    }

    func testTheMorningOf() {
        guard let nudge = nudge(meeting, at: at(4, 9)) else { return XCTFail("expected a nudge") }

        XCTAssertEqual(nudge.key, "t-meeting#today")
        XCTAssertTrue(nudge.text.hasSuffix("— today."), nudge.text)
    }

    /// Before the morning hour there is nothing to say. Quiet hours would
    /// usually cover this; the ladder does not rely on them to avoid asking
    /// about Tuesday at one minute past midnight.
    func testNothingBeforeTheMorningHour() {
        XCTAssertNil(nudge(meeting, at: at(3, 7)))
    }

    /// **The small hours of the day itself are not "tomorrow".** Without an
    /// upper bound, 2am on Tuesday still satisfies "after the morning before".
    func testTwoInTheMorningOnTheDayItselfIsNotTomorrow() {
        let text = nudge(meeting, at: at(4, 2))?.text ?? ""

        XCTAssertFalse(text.contains("tomorrow"), text)
    }

    /// All day Tuesday, the Tuesday meeting has not lapsed. Read literally its
    /// date is 00:00, which would make it overdue for the whole of the day it is
    /// meant to happen on.
    func testADayTaskIsNotOverdueDuringItsOwnDay() {
        let text = nudge(meeting, at: at(4, 23))?.text ?? ""

        XCTAssertFalse(text.contains("should I move it"), text)
        XCTAssertTrue(text.hasSuffix("— today."), text)
    }

    // MARK: After it lapses

    /// A deadline that passed an hour ago has not earned a question yet.
    func testNoQuestionTheMomentItLapses() {
        XCTAssertNil(nudge(chiro, at: at(5, 12)))
        XCTAssertNil(nudge(chiro, at: at(5, 20)))
    }

    func testTheMorningAfter() {
        guard let nudge = nudge(chiro, at: at(6, 9)) else { return XCTFail("expected a nudge") }

        XCTAssertEqual(nudge.key, "t-chiro#overdue-0")
        XCTAssertTrue(nudge.text.contains("yesterday"), nudge.text)
        XCTAssertTrue(nudge.text.contains("should I move it"), nudge.text)
    }

    /// **The decay the owner asked for.** Day +1, then +8, then +15 — never
    /// silent, never daily.
    func testItAsksAgainAWeekLaterAndNotBefore() {
        // Days two through seven produce the same key, which the ledger has
        // already seen, so nothing is said.
        for day in 7...12 {
            XCTAssertEqual(nudge(chiro, at: at(day, 9))?.key, "t-chiro#overdue-0", "6+\(day)")
        }
        XCTAssertEqual(nudge(chiro, at: at(13, 9))?.key, "t-chiro#overdue-1")
        XCTAssertEqual(nudge(chiro, at: at(20, 9))?.key, "t-chiro#overdue-2")
    }

    func testTheWeeklyQuestionOffersTheWayOut() {
        guard let nudge = nudge(chiro, at: at(13, 9)) else { return XCTFail("expected a nudge") }

        XCTAssertTrue(nudge.text.contains("5 August"), nudge.text)
        XCTAssertTrue(nudge.text.contains("Move it or drop it?"), nudge.text)
    }

    /// Silence between the rounds is what makes it a reminder rather than a nag.
    func testTheDaysInBetweenAreSilent() {
        let said: Set<String> = ["t-chiro#overdue-0"]
        for day in 7...12 {
            XCTAssertTrue(
                ReminderLadder.due(tasks: [chiro], alreadySaid: said, now: at(day, 9), calendar: calendar).isEmpty,
                "August \(day) should be silent"
            )
        }
    }

    /// It never moves or drops anything by itself. A date the owner did not give
    /// is the exact thing the rest of this subsystem exists to avoid inventing.
    func testItAsksRatherThanReschedules() {
        guard let nudge = nudge(chiro, at: at(13, 9)) else { return XCTFail("expected a nudge") }

        XCTAssertTrue(nudge.text.hasSuffix("?"), nudge.text)
        XCTAssertFalse(nudge.text.lowercased().contains("i've moved"), nudge.text)
        XCTAssertFalse(nudge.text.lowercased().contains("moved it to"), nudge.text)
    }

    // MARK: Undated work

    /// "buy eggs" has no deadline, and something with no deadline must never
    /// produce a reminder — that is a notification for a thing that cannot be
    /// late.
    func testUndatedTasksAreNeverRemindedAbout() {
        for day in 1...30 {
            XCTAssertNil(nudge(eggs, at: at(day, 9)), "August \(day)")
            XCTAssertNil(nudge(eggs, at: at(day, 18)), "August \(day)")
        }
    }

    /// A numeric date still yields nothing, all the way through. "5/8" is two
    /// different days depending on who wrote it, and a reminder three months
    /// early is worse than none.
    func testNumericDatesProduceNoReminders() {
        let ambiguous = WatchedTask(id: "t-x", title: "Chiro on 5/8", status: "planned")

        for day in 1...30 {
            XCTAssertNil(nudge(ambiguous, at: at(day, 9)), "August \(day)")
        }
    }

    // MARK: The ledger does not grow forever

    func testKeysForTasksThatAreGoneAreDropped() {
        let said: Set<String> = ["t-chiro#day", "t-chiro#hours", "t-gone#overdue-0", "t-meeting#today"]
        let kept = ReminderLadder.keysWorthKeeping(said, tasks: [chiro, meeting])

        XCTAssertEqual(kept, ["t-chiro#day", "t-chiro#hours", "t-meeting#today"])
    }

    // MARK: His actual board

    /// **The seven tasks in the live ledger on 3 August 2026**, because a parser
    /// that passes on tidy fixtures and fails on what is really stored is a
    /// parser that has not been tested. Two of these are awkward shapes that no
    /// invented example would have produced.
    ///
    /// The whole point of a reminder is that nobody is watching it work, so the
    /// failure mode is silence — and silence is indistinguishable from "nothing
    /// was due".
    func testTheRealBoardParsesTheWayItLooks() {
        let board = [
            ("Apply for UOB Visa Infinite — contact a UOB agent to start the application", nil),
            ("Check in at Butterfly Hotel Betong — booking number 1755889226, Deluxe King Room", nil),
            ("Haircut at Trufitt & Hill Bangsar, Thursday 6 August 2026, 11am", "2026-08-06 11:00"),
            ("Chiropractor appointment at One Spine TTDI Wednesday 5 August 2026, 11am", "2026-08-05 11:00"),
            // The time comes *before* the date here. Nothing was designed for
            // that; it works because the two are found independently.
            ("Donsak to Koh Phangan ferry at 14:30, Monday 10 August 2026", "2026-08-10 14:30"),
            ("Apply for Thailand Digital Arrival Card before travelling", nil),
            // A ten-digit booking number sitting next to a real date. The date
            // must win and the number must not become one.
            ("Check in at Brillianest Hotel, Hatyai on Wednesday 19 August 2026. Booking no. 1755889226",
             "2026-08-19 00:00")
        ]

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        for (title, expected) in board {
            let parsed = SpokenDate.writtenDate(in: title, calendar: calendar).map(formatter.string(from:))
            XCTAssertEqual(parsed, expected, title)
        }
    }

    /// And that nothing on it fires at 07:27 on 3 August, when the nearest thing
    /// is two days away. A ladder that announced all seven the moment it woke up
    /// would be the worst possible first impression.
    func testNothingOnTheRealBoardFiresTwoDaysOut() {
        let board = [
            "Apply for UOB Visa Infinite — contact a UOB agent to start the application",
            "Check in at Butterfly Hotel Betong — booking number 1755889226, Deluxe King Room",
            "Haircut at Trufitt & Hill Bangsar, Thursday 6 August 2026, 11am",
            "Chiropractor appointment at One Spine TTDI Wednesday 5 August 2026, 11am",
            "Donsak to Koh Phangan ferry at 14:30, Monday 10 August 2026",
            "Apply for Thailand Digital Arrival Card before travelling",
            "Check in at Brillianest Hotel, Hatyai on Wednesday 19 August 2026. Booking no. 1755889226"
        ].enumerated().map { WatchedTask(id: "real-\($0.offset)", title: $0.element, status: "planned") }

        let due = ReminderLadder.due(
            tasks: board,
            alreadySaid: [],
            now: at(3, 7, 27),
            calendar: calendar
        )

        XCTAssertTrue(due.isEmpty, "would have said: \(due.map(\.text))")
    }

    /// The live test the owner asked for, run as arithmetic first: a task added
    /// this morning for 9:30 the same morning.
    func testATaskAddedTwoHoursBeforeItHappens() {
        let test = WatchedTask(
            id: "t-live",
            title: "Test reminder Monday 3 August 2026, 9:30am",
            status: "planned"
        )

        // 07:35, just after it is added and picked up by the next check. One
        // hour fifty-five is inside two hours, so this is the *hours* rung and
        // not the day rung — a task added this close never gets a day rung at
        // all, because there was never a moment when it was a day away.
        guard let first = nudge(test, at: at(3, 7, 35)) else {
            return XCTFail("nothing at 07:35, two hours out")
        }
        XCTAssertEqual(first.key, "t-live#hours")
        XCTAssertTrue(first.text.contains("in about 2 hours"), first.text)
        XCTAssertTrue(first.text.contains("9:30 am"), first.text)

        // 09:00, half an hour out — a different rung, so it lands even though
        // the first one already did.
        guard let second = nudge(test, at: at(3, 9, 0)) else {
            return XCTFail("nothing at 09:00, half an hour out")
        }
        XCTAssertEqual(second.key, "t-live#soon")
        XCTAssertTrue(second.text.contains("half an hour"), second.text)

        // And the morning after, if it is never marked done.
        XCTAssertEqual(nudge(test, at: at(4, 9))?.key, "t-live#overdue-0")
    }

    // MARK: It is a function

    func testTheSameTasksAtTheSameInstantGiveTheSameAnswer() {
        let once = ReminderLadder.due(tasks: [chiro, meeting, eggs], alreadySaid: [], now: at(5, 9, 30), calendar: calendar)
        let twice = ReminderLadder.due(tasks: [chiro, meeting, eggs], alreadySaid: [], now: at(5, 9, 30), calendar: calendar)

        XCTAssertEqual(once, twice)
    }
}

/// The title, with the date taken back out.
///
/// A reminder is about to say when something is in its own words, so reading the
/// stored date out as well makes it "Chiro Wednesday 5 August 2026 11am — in
/// about two hours", which is the sort of sentence that reads as assembled
/// rather than written.
final class TitleWithoutDateTests: XCTestCase {

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kuala_Lumpur")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    private func stripped(_ text: String) -> String {
        SpokenDate.withoutWrittenDate(in: text, calendar: calendar)
    }

    func testTheTasksOnHisBoard() {
        XCTAssertEqual(
            stripped("Chiropractor appointment at One Spine TTDI Wednesday 5 August 2026, 11am"),
            "Chiropractor appointment at One Spine TTDI"
        )
        XCTAssertEqual(
            stripped("Meeting with TII IT on Tuesday 4 August 2026"),
            "Meeting with TII IT"
        )
        XCTAssertEqual(
            stripped("Haircut at Trufitt & Hill Bangsar, Thursday 6 August 2026, 11am"),
            "Haircut at Trufitt & Hill Bangsar"
        )
    }

    /// Nothing to remove is not an error.
    func testAnUndatedTitleIsUntouched() {
        XCTAssertEqual(stripped("buy eggs"), "buy eggs")
        XCTAssertEqual(stripped("Apply for the UOB Visa Infinite"), "Apply for the UOB Visa Infinite")
    }

    /// **A reminder that reads long is fine; one that reads mangled is not.** If
    /// the surgery leaves a stub, the owner's own sentence comes back whole.
    func testAStubFallsBackToTheWholeTitle() {
        XCTAssertEqual(stripped("5 August 2026"), "5 August 2026")
        XCTAssertEqual(stripped("Wednesday 5 August 2026, 11am"), "Wednesday 5 August 2026, 11am")
    }

    func testCapitalisationSurvives() {
        XCTAssertEqual(stripped("Dentist August 5 2026"), "Dentist")
    }
}
