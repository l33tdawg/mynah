import EventKit
import XCTest
@testable import SageVoiceCore

/// **"the repeats is not set".**
///
/// 6 August 2026. The owner asked for a standing Thursday call, Mynah answered
/// *"the weekly recurrence is recorded as a permanent fact"*, and the event
/// landed in Calendar as a one-off on 6 August with `Repeat: Never` and the
/// words "recurring weekly" sitting in its title.
///
/// Both halves of that answer were true and neither helped. SAGE really did
/// record the fact. What the *calendar* got was a single event — so the alarm
/// that actually reaches his phone and watch fires once and never again, which
/// is the entire reason dated tasks are mirrored at all.
///
/// `EKRecurrenceRule` appeared nowhere in this codebase before this, so the
/// mirror could only ever produce one-offs. `tidied` already recognised "every,
/// recurring weekly" — as *wreckage to sweep up*.
final class CalendarRecurrenceTests: XCTestCase {

    // MARK: - Reading how often

    /// The owner's own title, verbatim from his list.
    func testTheTitleThatCausedThis() {
        let (repeats, _) = CalendarRepeat.read(
            from: "Call with MT & Biniam — recurring weekly. Do not remove after"
        )
        XCTAssertEqual(repeats, .weekly)
    }

    func testTheOrdinaryWaysOfSayingHowOften() {
        let cases: [(String, CalendarRepeat)] = [
            ("Call with MT & Biniam every Thursday at 6pm", .weekly),
            ("Standup every week", .weekly),
            ("Weekly review on Friday", .weekly),
            ("Water the plants each week", .weekly),
            ("Take the bins out every day", .daily),
            ("Daily standup at 9am", .daily),
            ("Rent every month", .monthly),
            ("Monthly invoice run", .monthly),
            ("Renew the domain every year", .yearly),
            ("Annual review in March", .yearly),
            ("Payday every two weeks", .fortnightly),
            ("Fortnightly one-to-one", .fortnightly),
            ("Cleaner every other week", .fortnightly)
        ]
        for (title, expected) in cases {
            let (repeats, _) = CalendarRepeat.read(from: title)
            XCTAssertEqual(repeats, expected, title)
        }
    }

    /// **Longest-first, or the loosest pattern wins and is wrong.** "every other
    /// week" contains "every ... week", and read as weekly it would put a
    /// fortnightly cleaner in the calendar twice as often as the owner asked
    /// for — a wrong repeat is worse than none, because it alarms.
    func testTheLongerPhraseBeatsTheShorterOne() {
        XCTAssertEqual(CalendarRepeat.read(from: "every other week").0, .fortnightly)
        XCTAssertEqual(CalendarRepeat.read(from: "every two weeks").0, .fortnightly)
    }

    /// A one-off is the common case and must not sprout a rule. Note "Thursday
    /// 13 August" — a weekday alone is a date, not a recurrence, and reading it
    /// as one would make every dated task repeat for ever.
    func testAOneOffHasNoRepeat() {
        for title in [
            "Dentist appointment — Tuesday 4 August 2026, 1pm",
            "Call with MT & Biniam is now set for Thursday 13 August at 6pm",
            "Donsak to Koh Phangan ferry",
            "Apply for Thailand Digital Arrival Card (TDAC)",
            "Pick up Cayenne from Prestige — morning most likely, 7 Aug"
        ] {
            XCTAssertNil(CalendarRepeat.read(from: title).0, title)
        }
    }

    // MARK: - And taking the words back out of the title

    /// **The phrase becomes structure, so it must stop being text.** Leaving it
    /// in gives a lock-screen alert reading "recurring weekly" on an event whose
    /// own Repeat field already says so.
    func testTheRecurrenceLeavesTheTitle() {
        let (_, rest) = CalendarRepeat.read(from: "Standup every week at 9am")
        XCTAssertFalse(rest.lowercased().contains("every week"), rest)
    }

    /// The owner's title again, all the way through: the recurrence goes, the
    /// instruction addressed to Mynah goes, and what is left is the thing
    /// itself.
    func testTheOwnersTitleComesOutReadable() {
        let (_, rest) = CalendarRepeat.read(
            from: "Call with MT & Biniam — recurring weekly. Do not remove after"
        )
        let cleaned = CalendarEntry.tidied(CalendarRepeat.tidiedAfterRemoval(rest))

        XCTAssertTrue(cleaned.hasPrefix("Call with MT & Biniam"), cleaned)
        XCTAssertFalse(cleaned.lowercased().contains("weekly"), cleaned)
        XCTAssertFalse(cleaned.lowercased().contains("recurring"), cleaned)
        XCTAssertFalse(cleaned.lowercased().contains("do not remove"), cleaned)
    }

    // MARK: - The whole entry

    private func task(_ title: String) -> WatchedTask {
        WatchedTask(id: "t1", title: title, status: "open")
    }

    /// **The date survives the recurrence being taken out**, which is the whole
    /// reason detection happens before the date is read and stripping after.
    /// Strip "every Thursday" first and `SpokenDate` finds no date, `from`
    /// returns nil, and the task silently stops being mirrored at all — a
    /// recurrence request that *removes* the event.
    func testAWeekdayRecurrenceStillPlacesTheFirstOccurrence() throws {
        var when = DateComponents()
        when.year = 2026; when.month = 8; when.day = 6; when.hour = 18; when.minute = 0
        let entry = try XCTUnwrap(
            CalendarEntry.from(task("Call with MT & Biniam every Thursday 6 August 2026 at 6pm"))
        )

        XCTAssertEqual(entry.repeats, .weekly)
        XCTAssertFalse(entry.isAllDay)
        XCTAssertEqual(
            Calendar.current.dateComponents([.year, .month, .day], from: entry.starts).day, 6
        )
    }

    /// **Without this the fix cannot land on an existing event.** The plan skips
    /// any task whose fingerprint matches, so a recurrence that is not in the
    /// fingerprint means "make that weekly" is agreed to and never written.
    func testTheFingerprintNoticesTheRecurrenceChanging() {
        let once = CalendarEntry(
            taskID: "t1", title: "Standup", starts: Date(timeIntervalSince1970: 1_000_000),
            isAllDay: false
        )
        let weekly = CalendarEntry(
            taskID: "t1", title: "Standup", starts: Date(timeIntervalSince1970: 1_000_000),
            isAllDay: false, repeats: .weekly
        )

        XCTAssertNotEqual(once.fingerprint, weekly.fingerprint)
    }

    // MARK: - What EventKit is handed

    func testAWeeklyEntryBecomesAWeeklyRule() throws {
        let entry = CalendarEntry(
            taskID: "t1", title: "Standup", starts: Date(), isAllDay: false, repeats: .weekly
        )
        let rule = try XCTUnwrap(EventKitCalendar.recurrence(for: entry))

        XCTAssertEqual(rule.frequency, .weekly)
        XCTAssertEqual(rule.interval, 1)
        XCTAssertNil(rule.recurrenceEnd, "an invented end date stops the reminders on a day nobody chose")
    }

    /// Fortnightly is weekly with an interval, because EventKit has no
    /// fortnightly frequency.
    func testFortnightlyIsEveryOtherWeek() throws {
        let entry = CalendarEntry(
            taskID: "t1", title: "Pay", starts: Date(), isAllDay: false, repeats: .fortnightly
        )
        let rule = try XCTUnwrap(EventKitCalendar.recurrence(for: entry))

        XCTAssertEqual(rule.frequency, .weekly)
        XCTAssertEqual(rule.interval, 2)
    }

    func testAOneOffGetsNoRule() {
        let entry = CalendarEntry(
            taskID: "t1", title: "Dentist", starts: Date(), isAllDay: false
        )
        XCTAssertNil(EventKitCalendar.recurrence(for: entry))
    }

    // MARK: - The span, which is where this would have shipped broken

    /// **`.thisEvent` on a recurring event deletes one occurrence and leaves the
    /// series.** So a task the owner finished would clear this week's entry and
    /// go on alarming every Thursday for ever, with no task behind it and
    /// nothing in Mynah that still knows it exists. All three writes used
    /// `.thisEvent` because until now nothing here could repeat.
    func testARecurringEventIsWrittenAcrossTheWholeSeries() {
        let store = EKEventStore()
        let recurring = EKEvent(eventStore: store)
        recurring.recurrenceRules = [
            EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: nil)
        ]

        XCTAssertEqual(EventKitCalendar.span(for: recurring), .futureEvents)
    }

    /// And a one-off keeps the span it always had, so nothing that worked
    /// before changes.
    func testAOneOffIsStillWrittenAsItself() {
        let store = EKEventStore()
        let once = EKEvent(eventStore: store)

        XCTAssertEqual(EventKitCalendar.span(for: once), .thisEvent)
    }
}
