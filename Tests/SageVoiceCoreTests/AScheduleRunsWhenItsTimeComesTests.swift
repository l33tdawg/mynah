import XCTest
@testable import SageVoiceCore

/// The clock behind `//schedule`.
///
/// **Everything here is about the one question the feature cannot get wrong**:
/// whether a piece of work runs now, once, and never again until its next time
/// comes round. The owner asked for this because nothing on this side had a
/// clock (22 September 2026), and the ways a clock goes wrong are all invisible
/// from his phone — a miss is silence and a repeat is a nag. So the rules are
/// pure and clock-injected, in the shape `ReminderLadder` and `ProactiveSchedule`
/// already use: a rule that can only be checked by waiting a day is a rule
/// nobody will ever check.
final class AScheduleRunsWhenItsTimeComesTests: XCTestCase {

    private let malaysia = TimeZone(identifier: "Asia/Kuala_Lumpur")!

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = malaysia
        return calendar
    }

    /// A wall-clock moment in Kuala Lumpur, which is where this Mac stands and
    /// therefore what "eight in the morning" means to it.
    private func at(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int,
        zone: TimeZone? = nil
    ) -> Date {
        var parts = DateComponents()
        parts.year = year
        parts.month = month
        parts.day = day
        parts.hour = hour
        parts.minute = minute
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone ?? malaysia
        return calendar.date(from: parts)!
    }

    private func work(
        _ cadence: ScheduleCadence,
        created: Date,
        lastRun: Date? = nil
    ) -> ScheduledTask {
        ScheduledTask(
            id: "t1", instruction: "check my inbox", cadence: cadence,
            createdAt: created, lastRunAt: lastRun
        )
    }

    // MARK: A daily time

    /// The one that would have buzzed the owner within a minute of setting it
    /// up: work written at nine in the morning for eight o'clock.
    func testWorkSetUpAfterTodaysTimeWaitsForTomorrows() {
        let eight = ScheduleCadence.daily(hour: 8, minute: 0)
        let createdAt = at(2026, 9, 21, 9, 0)

        XCTAssertFalse(
            eight.isDue(
                lastRun: nil, createdAt: createdAt, now: at(2026, 9, 21, 9, 5),
                calendar: calendar
            ),
            "work written at 09:00 ran at once for a time that had already gone"
        )
        XCTAssertTrue(
            eight.isDue(
                lastRun: nil, createdAt: createdAt, now: at(2026, 9, 22, 8, 0),
                calendar: calendar
            )
        )
    }

    func testWorkSetUpBeforeTodaysTimeRunsToday() {
        let eight = ScheduleCadence.daily(hour: 8, minute: 0)
        let created = at(2026, 9, 21, 7, 0)

        XCTAssertFalse(
            eight.isDue(
                lastRun: nil, createdAt: created, now: at(2026, 9, 21, 7, 59),
                calendar: calendar
            )
        )
        XCTAssertTrue(
            eight.isDue(
                lastRun: nil, createdAt: created, now: at(2026, 9, 21, 8, 0),
                calendar: calendar
            )
        )
    }

    /// **The property the whole design is for.** A Mac that was asleep at eight
    /// runs the work when it wakes — once — and not once for every occurrence it
    /// missed. A laptop closed for a weekend must not produce three days of
    /// messages in one tick.
    func testAMacThatSleptRunsItOnceNotOncePerOccurrence() {
        let eight = ScheduleCadence.daily(hour: 8, minute: 0)
        var ledger = ScheduledWork(tasks: [
            work(eight, created: at(2026, 9, 14, 8, 0), lastRun: at(2026, 9, 21, 8, 0))
        ])

        XCTAssertTrue(
            eight.isDue(
                lastRun: at(2026, 9, 21, 8, 0), createdAt: at(2026, 9, 14, 8, 0),
                now: at(2026, 9, 22, 15, 4), calendar: calendar
            ),
            "a day that was slept through is a run that has not happened yet"
        )

        let wokeLate = ledger.claimDue(at: at(2026, 9, 22, 15, 4), calendar: calendar)
        XCTAssertEqual(wokeLate.count, 1)
        XCTAssertTrue(
            ledger.claimDue(at: at(2026, 9, 22, 15, 5), calendar: calendar).isEmpty,
            "the same morning ran twice"
        )
        XCTAssertEqual(
            ledger.claimDue(at: at(2026, 9, 23, 8, 0), calendar: calendar).count, 1,
            "tomorrow's eight o'clock did not come round"
        )

        // Three mornings missed, one run: the tick that wakes up does not work
        // through a backlog, whatever the Mac was doing for those days.
        var sleptThroughThreeMornings = ScheduledWork(tasks: [
            work(eight, created: at(2026, 9, 14, 8, 0), lastRun: at(2026, 9, 19, 8, 0))
        ])
        XCTAssertEqual(
            sleptThroughThreeMornings.claimDue(at: at(2026, 9, 22, 15, 4), calendar: calendar).count,
            1
        )
    }

    /// A run that lands hours late is still *that day's* run: the next one is
    /// the next day's eight o'clock, not an interval measured from the late one.
    func testRunningLateDoesNotShiftTomorrow() {
        let eight = ScheduleCadence.daily(hour: 8, minute: 0)
        var ledger = ScheduledWork(tasks: [
            work(eight, created: at(2026, 9, 14, 8, 0), lastRun: at(2026, 9, 21, 8, 0))
        ])

        _ = ledger.claimDue(at: at(2026, 9, 22, 23, 30), calendar: calendar)
        XCTAssertEqual(
            ledger.claimDue(at: at(2026, 9, 23, 8, 0), calendar: calendar).count, 1,
            "an 08:00 that ran at 23:30 was treated as tomorrow's run"
        )
    }

    // MARK: A weekday

    func testAWeeklyRequestRunsOnItsOwnDay() {
        // 1 = Sunday in Calendar's numbering, so 2 is Monday.
        let monday = ScheduleCadence.weekly(weekday: 2, hour: 9, minute: 0)
        let setUpOnFriday = at(2026, 9, 18, 10, 0)

        XCTAssertFalse(
            monday.isDue(
                lastRun: nil, createdAt: setUpOnFriday, now: at(2026, 9, 20, 12, 0),
                calendar: calendar
            ),
            "Sunday is not Monday"
        )
        XCTAssertTrue(
            monday.isDue(
                lastRun: nil, createdAt: setUpOnFriday, now: at(2026, 9, 21, 9, 0),
                calendar: calendar
            )
        )
        XCTAssertFalse(
            monday.isDue(
                lastRun: at(2026, 9, 21, 9, 0), createdAt: setUpOnFriday,
                now: at(2026, 9, 24, 18, 0), calendar: calendar
            ),
            "the Thursday after a Monday was due again"
        )
        XCTAssertTrue(
            monday.isDue(
                lastRun: at(2026, 9, 21, 9, 0), createdAt: setUpOnFriday,
                now: at(2026, 9, 28, 9, 0), calendar: calendar
            )
        )
    }

    // MARK: An interval

    func testAnIntervalIsMeasuredFromWhenItLastRan() {
        let halfHourly = ScheduleCadence.every(minutes: 30)
        var ledger = ScheduledWork(tasks: [
            work(halfHourly, created: at(2026, 9, 21, 10, 0))
        ])

        XCTAssertFalse(
            halfHourly.isDue(
                lastRun: nil, createdAt: at(2026, 9, 21, 10, 0),
                now: at(2026, 9, 21, 10, 29), calendar: calendar
            )
        )
        XCTAssertEqual(ledger.claimDue(at: at(2026, 9, 21, 10, 30), calendar: calendar).count, 1)
        // Late by a minute, and the next one counts from the late run rather
        // than from the slot that was missed.
        XCTAssertEqual(ledger.claimDue(at: at(2026, 9, 21, 11, 1), calendar: calendar).count, 1)
        XCTAssertTrue(ledger.claimDue(at: at(2026, 9, 21, 11, 28), calendar: calendar).isEmpty)
    }

    /// The tick is a minute wide, so a request to run more often than that is a
    /// promise this appliance cannot keep. Clamped rather than refused at this
    /// layer — the refusal belongs to the owner's sentence, in
    /// `ScheduledWorkCommand` — and the clamp is what a hand-edited file meets.
    func testAnIntervalIsHeldToTheFloorTheTickCanHonour() {
        let everyMinute = ScheduleCadence.every(minutes: 1)
        let created = at(2026, 9, 21, 10, 0)

        XCTAssertFalse(
            everyMinute.isDue(
                lastRun: nil, createdAt: created, now: at(2026, 9, 21, 10, 3),
                calendar: calendar
            )
        )
        XCTAssertTrue(
            everyMinute.isDue(
                lastRun: nil, createdAt: created, now: at(2026, 9, 21, 10, 5),
                calendar: calendar
            )
        )
    }

    // MARK: Clocks that move

    /// A Mac whose clock went backwards — a manual correction, a bad NTP
    /// resync — must not stop running everything until real time catches up.
    /// `ProactiveSchedule.isDue` makes the same exception.
    func testAClockThatWentBackwardsStillRuns() {
        let eight = ScheduleCadence.daily(hour: 8, minute: 0)
        XCTAssertTrue(
            eight.isDue(
                lastRun: at(2026, 9, 22, 8, 0), createdAt: at(2026, 9, 1, 8, 0),
                now: at(2026, 9, 21, 8, 0), calendar: calendar
            )
        )
    }

    /// **A day is not 86,400 seconds.** In a country that moves its clocks, a
    /// cadence computed by adding seconds drifts by an hour for half the year,
    /// and nobody would think to look for it: eight o'clock quietly becomes
    /// seven. Read through the calendar, it is eight o'clock on both sides of
    /// the change.
    func testEightOClockIsEightOClockOnBothSidesOfAClockChange() {
        let london = TimeZone(identifier: "Europe/London")!
        var londonCalendar = Calendar(identifier: .gregorian)
        londonCalendar.timeZone = london
        let eight = ScheduleCadence.daily(hour: 8, minute: 0)

        // The night of 29 March 2026 is when the UK moves to summer time.
        let beforeTheChange = at(2026, 3, 22, 8, 0, zone: london)
        let afterTheChange = at(2026, 3, 29, 8, 0, zone: london)
        XCTAssertNotEqual(
            beforeTheChange.timeIntervalSince1970.truncatingRemainder(dividingBy: 86_400),
            afterTheChange.timeIntervalSince1970.truncatingRemainder(dividingBy: 86_400),
            "this test is vacuous unless the clocks really moved"
        )

        for now in [beforeTheChange, afterTheChange] {
            XCTAssertEqual(
                eight.latestOccurrence(onOrBefore: now, calendar: londonCalendar), now,
                "the run drifted off eight o'clock local time"
            )
        }
    }

    // MARK: A row that is not a time

    /// A hand-edited file with an hour of 25 has no next time, and the honest
    /// answer to "when does this run?" is "never" — not "at one in the morning".
    /// `isDue` cannot invent an occurrence, so the work quietly stops mattering
    /// rather than running at the wrong hour.
    func testAnHourThatIsNotATimeNeverComesRound() {
        let nonsense = ScheduleCadence.daily(hour: 25, minute: 0)
        XCTAssertNil(
            nonsense.latestOccurrence(onOrBefore: at(2026, 9, 21, 10, 0), calendar: calendar)
        )
        XCTAssertFalse(
            nonsense.isDue(
                lastRun: nil, createdAt: at(2026, 9, 1, 0, 0),
                now: at(2026, 9, 21, 10, 0), calendar: calendar
            )
        )
    }

    // MARK: Held work

    /// Pausing is not deleting and it is not losing: nothing is claimed while
    /// the work is held, and switching it back on anchors the clock at that
    /// moment — so a request held for a fortnight does not come back by firing
    /// everything it missed, and does not fire the instant it is resumed either.
    func testHeldWorkIsNotClaimedAndDoesNotCatchUpWhenResumed() {
        let eight = ScheduleCadence.daily(hour: 8, minute: 0)
        var ledger = ScheduledWork(tasks: [
            work(eight, created: at(2026, 9, 14, 8, 0), lastRun: at(2026, 9, 14, 8, 0))
        ])

        XCTAssertEqual(ledger.pause(number: 1)?.isEnabled, false)
        XCTAssertTrue(
            ledger.claimDue(at: at(2026, 9, 21, 9, 0), calendar: calendar).isEmpty,
            "held work ran anyway"
        )

        XCTAssertEqual(ledger.resume(number: 1, now: at(2026, 9, 21, 9, 0))?.isEnabled, true)
        XCTAssertTrue(
            ledger.claimDue(at: at(2026, 9, 21, 9, 0), calendar: calendar).isEmpty,
            "a request resumed mid-morning fired at once for the morning it had missed"
        )
        XCTAssertEqual(
            ledger.claimDue(at: at(2026, 9, 22, 8, 0), calendar: calendar).count, 1,
            "the next eight o'clock did not come round"
        )
    }

    // MARK: Written down before it runs

    /// **The claim is on disk before the work starts.** A daemon that dies
    /// mid-turn loses one run; the other order repeats it every minute for as
    /// long as the failure lasts, which is a phone that says the same thing
    /// sixty times an hour.
    func testTheRunTimeIsWrittenDownBeforeTheWorkRuns() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mynah-scheduled-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("scheduled-work.json")

        var seeded = ScheduledWork()
        _ = seeded.add(
            instruction: "check my inbox",
            cadence: .daily(hour: 8, minute: 0),
            now: at(2026, 9, 14, 8, 0)
        )
        try seeded.save(to: file)

        let claimed = ScheduledWorkRunner(fileURL: file)
            .claimDue(at: at(2026, 9, 21, 8, 0), calendar: calendar)
        XCTAssertEqual(claimed.count, 1)

        // Also true across a restart: a second runner reads the file rather
        // than a cache, and the run is not in it again.
        XCTAssertTrue(
            ScheduledWorkRunner(fileURL: file)
                .claimDue(at: at(2026, 9, 21, 8, 1), calendar: calendar).isEmpty
        )
        XCTAssertEqual(
            ScheduledWork.load(from: file).tasks.first?.lastRunAt, at(2026, 9, 21, 8, 0)
        )
    }

    // MARK: What it says

    func testACadenceReadsBackTheWayTheOwnerWouldSayIt() {
        XCTAssertEqual(ScheduleCadence.daily(hour: 8, minute: 0).spoken, "every day at 08:00")
        XCTAssertEqual(ScheduleCadence.daily(hour: 8, minute: 30).spoken, "every day at 08:30")
        XCTAssertEqual(
            ScheduleCadence.weekly(weekday: 2, hour: 9, minute: 30).spoken,
            "every Monday at 09:30"
        )
        XCTAssertEqual(ScheduleCadence.every(minutes: 30).spoken, "every 30 minutes")
        XCTAssertEqual(ScheduleCadence.every(minutes: 60).spoken, "every hour")
        XCTAssertEqual(ScheduleCadence.every(minutes: 120).spoken, "every 2 hours")
    }
}
