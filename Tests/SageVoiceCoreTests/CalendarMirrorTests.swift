import XCTest
@testable import SageVoiceCore

/// **The owner's idea, 3 August 2026:** *"we should just use the ical calendar
/// thing - like give mynah its own calendar category in ical that the owner can
/// subscribe to - this would solve the reminder issue and we can just offload to
/// ical which does reminders better than we can"*, with the scoping that matters
/// most: *"the main thing would be adding / removing items but still keeping a
/// list on our end as we do now"*.
///
/// So SAGE stays the source of truth, the board stays as it is, and this is a
/// **mirror** of the dated items. Everything below is the difference engine,
/// tested without a calendar, without permission and without the owner's real
/// appointments anywhere near it.
final class CalendarMirrorTests: XCTestCase {

    private func task(_ id: String, _ title: String, status: String = "open") -> WatchedTask {
        WatchedTask(id: id, title: title, status: status)
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Singapore") ?? .current
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute
        ))!
    }

    // MARK: - What becomes an event

    /// The date comes out of the title, because it is the event's own field now.
    /// Left in, a calendar reads "Dentist — Tuesday 4 August 2026, 1pm" on
    /// Tuesday 4 August at 1pm.
    func testTheTitleLosesTheDateItIsAlreadyFiledUnder() {
        let entry = CalendarEntry.from(
            task("a", "Dentist appointment — Tuesday 4 August 2026, 1pm"),
            calendar: calendar
        )

        XCTAssertEqual(entry?.title, "Dentist appointment")
        XCTAssertEqual(entry?.starts, date(2026, 8, 4, 13))
        XCTAssertEqual(entry?.isAllDay, false)
    }

    /// **A day with no hour in it stays a day.** `SpokenDate` refused to invent a
    /// time at the point of storage, and an event at midnight would put the same
    /// invention back through a different door.
    func testADayWithNoClockTimeIsAnAllDayEvent() {
        let entry = CalendarEntry.from(
            task("a", "Meeting with TII IT on Tuesday 4 August 2026"),
            calendar: calendar
        )

        XCTAssertEqual(entry?.isAllDay, true)
        XCTAssertEqual(entry?.starts, date(2026, 8, 4))
    }

    /// An undated task is a real task and belongs on the board. Putting it in a
    /// calendar would mean choosing a day for it.
    func testATaskWithNoDateIsNotMirrored() {
        XCTAssertNil(CalendarEntry.from(task("a", "Look into the visa thing"), calendar: calendar))
    }

    /// A title that is nothing but a date leaves nothing to call the event, so
    /// its own words stand rather than an empty string.
    func testATitleMadeOnlyOfADateKeepsItsWords() {
        let entry = CalendarEntry.from(task("a", "Tuesday 4 August 2026"), calendar: calendar)

        XCTAssertEqual(entry?.title, "Tuesday 4 August 2026")
    }

    /// A timed event needs an end. Half an hour is a display convention and the
    /// doc comment says so — what matters is that it is not zero, because a
    /// calendar cannot draw that.
    func testATimedEventHasAnEnd() {
        let entry = CalendarEntry.from(
            task("a", "Chiro on Wednesday 5 August 2026 at 11am"),
            calendar: calendar
        )

        XCTAssertEqual(entry?.ends.timeIntervalSince(entry!.starts), 30 * 60)
    }

    // MARK: - Titles worth putting on a lock screen

    /// **Every one of these came out of the owner's real task list**, from
    /// `sage-voiced calendar --plan` against his fifteen dated tasks. Taking the
    /// date out of a sentence leaves the preposition that led into it, and it
    /// never mattered while the ladder was saying these mid-sentence. A calendar
    /// puts them on a phone in bold.
    func testTheWreckageARemovedDateLeaves() {
        let repairs = [
            "Call with Daniel & Tenzai —, on Google Meet": "Call with Daniel & Tenzai — on Google Meet",
            "Call with Credence at on Microsoft Teams": "Call with Credence on Microsoft Teams",
            "Call with David / Remah and TII,, Malaysian time": "Call with David / Remah and TII, Malaysian time",
            "Call with MT & Biniam — every, recurring weekly": "Call with MT & Biniam — recurring weekly",
            "Apply for the TDAC — must be done by, latest": "Apply for the TDAC — must be done, latest",
            "Call with Najwa at": "Call with Najwa",
            "Call with Credence on Microsoft Teams — link:": "Call with Credence on Microsoft Teams"
        ]

        for (before, after) in repairs {
            XCTAssertEqual(CalendarEntry.tidied(before), after, before)
        }
    }

    /// An ordinary title is not "repaired" into something else.
    func testATitleWithNothingWrongWithItIsUntouched() {
        for title in [
            "Dentist appointment",
            "Send Cayenne to Prestige",
            "Haircut at Trufitt & Hill Bangsar",
            "Donsak to Koh Phangan ferry",
            "Call with David / Remah and TII, Malaysian time"
        ] {
            XCTAssertEqual(CalendarEntry.tidied(title), title, title)
        }
    }

    /// **A 300-character Teams URL in a title is not a title.** It goes in the
    /// event's own link field, where the calendar app makes it a button.
    func testAMeetingLinkLeavesTheTitleAndBecomesTheEventsLink() {
        let entry = CalendarEntry.from(
            task("a", "Call with Florian on Microsoft Teams. Link: "
                + "https://teams.microsoft.com/l/meetup-join/19%3ameeting_NjYwN2Yz "
                + "on Tuesday 4 August 2026, 2pm"),
            calendar: calendar
        )

        XCTAssertEqual(entry?.title, "Call with Florian on Microsoft Teams")
        XCTAssertEqual(
            entry?.link?.absoluteString,
            "https://teams.microsoft.com/l/meetup-join/19%3ameeting_NjYwN2Yz"
        )
        XCTAssertFalse(entry?.title.contains("http") ?? true)
    }

    /// The booking number matters when you arrive at the hotel. It just does not
    /// belong in the title, so it goes in the notes rather than being lost.
    func testWhatWillNotFitBecomesTheNotesRatherThanBeingThrownAway() {
        let entry = CalendarEntry.from(
            task("a", "Check in at Brillianest Hotel, Hatyai. Booking no. 1688900029056686. "
                + "on Tuesday 18 August 2026"),
            calendar: calendar
        )

        XCTAssertEqual(entry?.title, "Check in at Brillianest Hotel, Hatyai")
        XCTAssertTrue(entry?.detail?.contains("1688900029056686") ?? false, entry?.detail ?? "nil")
    }

    /// A long title with no sentence in it is cut at a word, with an ellipsis so
    /// it is obviously cut rather than obviously wrong.
    func testALongTitleWithNoSentenceIsCutAtAWord() {
        let entry = CalendarEntry.from(
            task("a", "Apply for the Thailand Digital Arrival Card which cannot be filled in "
                + "more than three days before arrival on Tuesday 4 August 2026"),
            calendar: calendar
        )

        let title = try? XCTUnwrap(entry?.title)
        XCTAssertLessThanOrEqual(title?.count ?? 999, CalendarEntry.longestTitle + 1)
        XCTAssertTrue(title?.hasSuffix("…") ?? false, title ?? "nil")
        XCTAssertFalse(title?.contains("  ") ?? true)
        XCTAssertNotNil(entry?.detail)
    }

    /// A short title is left whole, with no notes and no ellipsis.
    func testAShortTitleIsLeftWhole() {
        let entry = CalendarEntry.from(
            task("a", "Dentist appointment — Tuesday 4 August 2026, 1pm"), calendar: calendar
        )

        XCTAssertEqual(entry?.title, "Dentist appointment")
        XCTAssertNil(entry?.detail)
        XCTAssertNil(entry?.link)
    }

    /// The fingerprint has to cover everything that reaches the event, or a task
    /// whose link changed would never be rewritten.
    func testTheFingerprintNoticesALinkChanging() {
        let base = CalendarEntry(
            taskID: "a", title: "Call", starts: date(2026, 8, 4, 13), isAllDay: false
        )
        let withLink = CalendarEntry(
            taskID: "a", title: "Call", starts: date(2026, 8, 4, 13), isAllDay: false,
            link: URL(string: "https://example.com/meet")
        )
        let withDetail = CalendarEntry(
            taskID: "a", title: "Call", starts: date(2026, 8, 4, 13), isAllDay: false,
            detail: "and the room number"
        )

        XCTAssertNotEqual(base.fingerprint, withLink.fingerprint)
        XCTAssertNotEqual(base.fingerprint, withDetail.fingerprint)
    }

    // MARK: - The plan

    func testAFreshTaskIsAdded() {
        let plan = CalendarMirror.plan(
            tasks: [task("a", "Dentist — Tuesday 4 August 2026, 1pm")],
            against: CalendarLedger(),
            calendar: calendar
        )

        XCTAssertEqual(plan.add.map(\.taskID), ["a"])
        XCTAssertTrue(plan.update.isEmpty)
        XCTAssertTrue(plan.remove.isEmpty)
    }

    /// **The one that stops the owner's phone buzzing four times an hour.** An
    /// unchanged task must produce no work at all: rewriting an identical event
    /// is a modification his other devices sync.
    func testAnUnchangedTaskIsLeftCompletelyAlone() {
        let task = task("a", "Dentist — Tuesday 4 August 2026, 1pm")
        let entry = CalendarEntry.from(task, calendar: calendar)!
        let ledger = CalendarLedger(
            events: ["a": "event-1"],
            written: ["a": entry.fingerprint]
        )

        let plan = CalendarMirror.plan(tasks: [task], against: ledger, calendar: calendar)

        XCTAssertTrue(plan.isEmpty, "\(plan)")
    }

    /// He moved the deadline. The event moves, and it moves rather than being
    /// added again beside the old one.
    func testAMovedDeadlineUpdatesTheEventItAlreadyHas() {
        let before = CalendarEntry.from(
            task("a", "Dentist — Tuesday 4 August 2026, 1pm"), calendar: calendar
        )!
        let ledger = CalendarLedger(events: ["a": "event-1"], written: ["a": before.fingerprint])

        let plan = CalendarMirror.plan(
            tasks: [task("a", "Dentist — Wednesday 5 August 2026, 3pm")],
            against: ledger,
            calendar: calendar
        )

        XCTAssertTrue(plan.add.isEmpty)
        XCTAssertEqual(plan.update.map(\.eventID), ["event-1"])
        XCTAssertEqual(plan.update.first?.entry.starts, date(2026, 8, 5, 15))
    }

    /// Gone from the open list means done or dropped, and either way the alarm
    /// should stop.
    func testATaskThatLeftTheListLosesItsEvent() {
        let ledger = CalendarLedger(events: ["a": "event-1"], written: ["a": "whatever"])

        let plan = CalendarMirror.plan(tasks: [], against: ledger, calendar: calendar)

        XCTAssertEqual(plan.remove.map(\.eventID), ["event-1"])
    }

    /// A task that loses its date is no longer a calendar entry, and leaving the
    /// event behind would mean an alarm for a deadline nobody has any more.
    func testATaskThatLosesItsDateLosesItsEvent() {
        let ledger = CalendarLedger(events: ["a": "event-1"], written: ["a": "whatever"])

        let plan = CalendarMirror.plan(
            tasks: [task("a", "Dentist, at some point")],
            against: ledger,
            calendar: calendar
        )

        XCTAssertEqual(plan.remove.map(\.taskID), ["a"])
    }

    /// The same tasks give the same plan twice. Dictionary iteration does not
    /// promise an order, and a plan that shuffles is one nobody can assert on.
    func testThePlanIsTheSamePlanTwice() {
        let tasks = ["c", "a", "b"].map { task($0, "Thing \($0) — Tuesday 4 August 2026, 1pm") }
        let ledger = CalendarLedger(events: ["x": "1", "y": "2", "z": "3"])

        let first = CalendarMirror.plan(tasks: tasks, against: ledger, calendar: calendar)
        let again = CalendarMirror.plan(tasks: tasks, against: ledger, calendar: calendar)

        XCTAssertEqual(first, again)
        XCTAssertEqual(first.add.map(\.taskID), ["a", "b", "c"])
        XCTAssertEqual(first.remove.map(\.taskID), ["x", "y", "z"])
    }

    // MARK: - Settling up

    func testWhatSucceededIsWrittenDownAndWhatFailedIsNot() {
        let entries = ["a", "b"].map {
            CalendarEntry.from(task($0, "Thing \($0) — Tuesday 4 August 2026, 1pm"), calendar: calendar)!
        }
        let plan = CalendarMirror.Plan(add: entries)

        let settled = CalendarMirror.settled(
            CalendarLedger(), after: plan, written: ["a": "event-1"], removed: []
        )

        XCTAssertEqual(settled.events, ["a": "event-1"])
        XCTAssertEqual(settled.written["a"], entries[0].fingerprint)
        XCTAssertNil(settled.events["b"], "an add that threw must be tried again next tick")
    }

    /// **A delete that failed keeps its row.** Forgetting the identifier would
    /// orphan the event for ever: nothing would ever again know which one it was.
    func testAFailedRemovalKeepsItsIdentifier() {
        let ledger = CalendarLedger(events: ["a": "event-1"], written: ["a": "old"])
        let plan = CalendarMirror.Plan(remove: [(taskID: "a", eventID: "event-1")])

        let stillThere = CalendarMirror.settled(ledger, after: plan, written: [:], removed: [])
        XCTAssertEqual(stillThere.events["a"], "event-1")

        let gone = CalendarMirror.settled(ledger, after: plan, written: [:], removed: ["a"])
        XCTAssertNil(gone.events["a"])
        XCTAssertNil(gone.written["a"])
    }

    // MARK: - One sync

    private final class StubCalendar: CalendarWriting, @unchecked Sendable {
        var allowed = true
        var failOn: Set<String> = []
        private(set) var added: [CalendarEntry] = []
        private(set) var updated: [(CalendarEntry, String)] = []
        private(set) var removed: [String] = []
        private(set) var asked = 0
        private var next = 0

        struct Refused: Error {}

        func prepare() async -> Bool { asked += 1; return allowed }

        func add(_ entry: CalendarEntry) async throws -> String {
            if failOn.contains(entry.taskID) { throw Refused() }
            added.append(entry)
            next += 1
            return "event-\(next)"
        }

        func update(_ entry: CalendarEntry, eventID: String) async throws -> String {
            if failOn.contains(entry.taskID) { throw Refused() }
            updated.append((entry, eventID))
            return eventID
        }

        func remove(eventID: String) async throws {
            if failOn.contains(eventID) { throw Refused() }
            removed.append(eventID)
        }
    }

    func testASyncWritesWhatThePlanSaysAndRemembersIt() async {
        let stub = StubCalendar()
        let sync = CalendarSync(calendar: stub)

        let outcome = await sync.run(
            tasks: [task("a", "Dentist — Tuesday 4 August 2026, 1pm")],
            ledger: CalendarLedger(),
            clock: calendar
        )

        XCTAssertEqual(stub.added.map(\.taskID), ["a"])
        XCTAssertEqual(outcome.ledger.events["a"], "event-1")
        XCTAssertEqual(outcome.mirrored, ["a"])
        XCTAssertNil(outcome.trouble)
    }

    /// **Permission is asked for on the first tick that has something to write,
    /// and not before.** An appliance that demands calendar access at launch,
    /// before it has done anything for you, is one people decline permanently —
    /// and a refusal is remembered for ever.
    func testNothingIsAskedForUntilThereIsSomethingToMirror() async {
        let stub = StubCalendar()
        let sync = CalendarSync(calendar: stub)

        _ = await sync.run(
            tasks: [task("a", "Look into the visa thing")],
            ledger: CalendarLedger(),
            clock: calendar
        )

        XCTAssertEqual(stub.asked, 0, "an undated task must not trigger a permission prompt")
    }

    func testARefusedCalendarChangesNothingAndSaysSo() async {
        let stub = StubCalendar()
        stub.allowed = false
        let sync = CalendarSync(calendar: stub)

        let outcome = await sync.run(
            tasks: [task("a", "Dentist — Tuesday 4 August 2026, 1pm")],
            ledger: CalendarLedger(),
            clock: calendar
        )

        XCTAssertEqual(outcome.ledger, CalendarLedger())
        XCTAssertTrue(outcome.mirrored.isEmpty, "the ladder must keep working when the calendar cannot")
        XCTAssertNotNil(outcome.trouble)
    }

    /// **The dangerous one.** `nil` means the node could not be asked. Read as an
    /// empty list — the `?? []` bug from `ProactiveWatch` — this would not merely
    /// say something wrong, it would delete the owner's calendar entries.
    func testANodeThatCouldNotBeAskedDeletesNothing() async {
        let stub = StubCalendar()
        let sync = CalendarSync(calendar: stub)
        let ledger = CalendarLedger(events: ["a": "event-1"], written: ["a": "old"])

        let outcome = await sync.run(tasks: nil, ledger: ledger, clock: calendar)

        XCTAssertTrue(stub.removed.isEmpty)
        XCTAssertEqual(outcome.ledger, ledger)
        XCTAssertEqual(outcome.mirrored, ["a"], "and the ladder stays quiet for what is still mirrored")
    }

    func testOneFailureDoesNotStopTheRest() async {
        let stub = StubCalendar()
        stub.failOn = ["a"]
        let sync = CalendarSync(calendar: stub)

        let outcome = await sync.run(
            tasks: [
                task("a", "Dentist — Tuesday 4 August 2026, 1pm"),
                task("b", "Chiro — Wednesday 5 August 2026, 11am")
            ],
            ledger: CalendarLedger(),
            clock: calendar
        )

        XCTAssertEqual(stub.added.map(\.taskID), ["b"])
        XCTAssertNil(outcome.ledger.events["a"], "so the next tick tries it again")
        XCTAssertNotNil(outcome.ledger.events["b"])
        XCTAssertNotNil(outcome.trouble)
    }

    /// Two syncs in a row: the second has nothing to do, which is what makes the
    /// first one's bookkeeping worth having.
    func testTheSecondSyncOfTheSameListDoesNothingAtAll() async {
        let stub = StubCalendar()
        let sync = CalendarSync(calendar: stub)
        let tasks = [task("a", "Dentist — Tuesday 4 August 2026, 1pm")]

        let first = await sync.run(tasks: tasks, ledger: CalendarLedger(), clock: calendar)
        let second = await sync.run(tasks: tasks, ledger: first.ledger, clock: calendar)

        XCTAssertEqual(stub.added.count, 1)
        XCTAssertTrue(stub.updated.isEmpty)
        XCTAssertEqual(stub.asked, 1, "and permission is not asked for again either")
        XCTAssertEqual(second.ledger, first.ledger)
    }

    // MARK: - The alarms

    /// The ladder's own rungs, handed to the OS. What was wrong with them was
    /// the delivery, not the moments.
    func testATimedEventGetsTheLaddersOwnRungs() {
        let entry = CalendarEntry(taskID: "a", title: "Dentist", starts: date(2026, 8, 4, 13), isAllDay: false)

        XCTAssertEqual(
            EventKitCalendar.alarms(for: entry, now: date(2026, 8, 1)),
            [-86_400, -7_200, -900]
        )
    }

    /// All-day offsets are measured from midnight, so nine in the morning is
    /// `+9h` on the day and `-15h` the day before — exactly where
    /// `ReminderLadder` put them.
    func testAnAllDayEventIsToldTheMorningBeforeAndTheMorningOf() {
        let entry = CalendarEntry(taskID: "a", title: "Meeting", starts: date(2026, 8, 4), isAllDay: true)
        let morning = Double(ReminderLadder.morningHour * 3600)

        XCTAssertEqual(
            EventKitCalendar.alarms(for: entry, now: date(2026, 8, 1)),
            [morning - 86_400, morning]
        )

        // And half of them once the day before has passed.
        XCTAssertEqual(
            EventKitCalendar.alarms(for: entry, now: date(2026, 8, 3, 20)),
            [morning]
        )
    }

    /// **The first sync on a Mac that has been running for weeks writes every
    /// dated task at once, and several have been and gone.** Three alarms each
    /// would be a burst of notifications about things that already happened —
    /// a spectacular first impression for a feature meant to reduce noise.
    func testNothingAlreadyPastGetsAnAlarm() {
        let entry = CalendarEntry(
            taskID: "a", title: "Dentist", starts: date(2026, 8, 4, 13), isAllDay: false
        )

        XCTAssertTrue(EventKitCalendar.alarms(for: entry, now: date(2026, 8, 5)).isEmpty)
        XCTAssertEqual(
            EventKitCalendar.alarms(for: entry, now: date(2026, 8, 4, 12)),
            [-900],
            "the rung that has not passed yet still stands"
        )
    }

    // MARK: - Who says what

    /// **The split the owner asked for.** iCal owns "it is happening soon";
    /// Mynah owns "it did not happen, what now". Sending both would mean being
    /// told about the dentist twice, which is how somebody switches the whole
    /// thing off.
    func testTheRunUpNudgesStopForAnythingTheCalendarHas() {
        let task = task("a", "Dentist — Tuesday 4 August 2026, 1pm")
        let anHourBefore = date(2026, 8, 4, 12)

        let unmirrored = ReminderLadder.due(
            tasks: [task], alreadySaid: [], now: anHourBefore, calendar: calendar
        )
        let mirrored = ReminderLadder.due(
            tasks: [task], alreadySaid: [], now: anHourBefore, mirrored: ["a"], calendar: calendar
        )

        XCTAssertEqual(unmirrored.count, 1, "unchanged where there is no calendar entry")
        XCTAssertTrue(mirrored.isEmpty, "\(mirrored)")
    }

    /// **The overdue check-in is a question, and a calendar alert has nowhere to
    /// put the answer.** So it survives being mirrored.
    func testTheOverdueCheckInSurvivesBeingMirrored() {
        let task = task("a", "Dentist — Tuesday 4 August 2026, 1pm")
        let theNextMorning = date(2026, 8, 5, 10)

        let nudges = ReminderLadder.due(
            tasks: [task], alreadySaid: [], now: theNextMorning, mirrored: ["a"], calendar: calendar
        )

        XCTAssertEqual(nudges.count, 1)
        XCTAssertTrue(nudges[0].text.contains("did that happen"), nudges[0].text)
    }

    /// An all-day task's run-up rungs go the same way, and for the same reason.
    func testTheAllDayRungsAlsoStopWhenTheCalendarHasIt() {
        let task = task("a", "Meeting with TII IT on Tuesday 4 August 2026")
        let theMorningOf = date(2026, 8, 4, 10)

        XCTAssertEqual(
            ReminderLadder.due(tasks: [task], alreadySaid: [], now: theMorningOf, calendar: calendar).count,
            1
        )
        XCTAssertTrue(
            ReminderLadder.due(
                tasks: [task], alreadySaid: [], now: theMorningOf, mirrored: ["a"], calendar: calendar
            ).isEmpty
        )
    }

    // MARK: - The ledger on disk

    func testTheLedgerSurvivesARestart() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mynah-calendar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("calendar-ledger.json")
        let ledger = CalendarLedger(events: ["a": "event-1"], written: ["a": "print"])

        try ledger.save(to: url)

        XCTAssertEqual(CalendarLedger.load(from: url), ledger)
    }

    /// A missing file is an empty ledger, not a crash — which is the state every
    /// Mac is in before the first dated task.
    func testAMissingLedgerIsAnEmptyOne() {
        let nowhere = URL(fileURLWithPath: "/nowhere/calendar-ledger.json")

        XCTAssertEqual(CalendarLedger.load(from: nowhere), CalendarLedger())
    }
}
