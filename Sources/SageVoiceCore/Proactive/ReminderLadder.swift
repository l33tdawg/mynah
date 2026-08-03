import Foundation

/// When to speak up about a task that has a date on it.
///
/// **The owner's rulings, made mechanical.** He asked for *"some way for Mynah
/// to set itself a reminder to send a message to the user like 24 hours before
/// and 1 hour or 2 hours before the due date and to keep tasks past their
/// deadline but remind the user about it again from time to time to ask if they
/// want it moved to a later date or removed"*. Then, on overdue work: ask at a
/// decaying rate — the morning after, then roughly weekly. Never silent, never
/// nagging.
///
/// Pure, total and clock-injected, for the reason `SpokenDate` is: this decides
/// when the appliance interrupts somebody, and a rule that can only be observed
/// by waiting a day is a rule nobody will ever check.
///
/// ## Bands, not alarms
///
/// The obvious design is three alarms — 24h, 2h, 30m — each firing when its
/// moment arrives. It is wrong on any Mac that sleeps. Miss the 24h alarm and it
/// fires late, on the first tick after waking, announcing an appointment
/// "tomorrow" three hours before it starts.
///
/// So the ladder asks a different question: *how far away is this, actually?*
/// The remaining time falls in exactly one band, each band fires at most once,
/// and the words come from the real gap rather than the band's name. A Mac that
/// slept through the whole of yesterday says "in about two hours", because that
/// is what is true when it wakes.
///
/// ## What it will not say
///
/// A task whose title names a day and no hour — "Meeting with TII IT on Tuesday
/// 4 August 2026" — gets day-shaped rungs and nothing finer. There is no hour in
/// it. `SpokenDate` refused to invent a time at the point of storage, and
/// inventing one here would put the same guess back through a different door.
public enum ReminderLadder {

    // MARK: The rungs

    /// The bands for a task with a clock time, longest first. A gap belongs to
    /// the *smallest* band it fits inside, so three hours out is the day band
    /// and ninety minutes out is the two-hour band.
    ///
    /// Half an hour is honest here only because the loop looks every 60 seconds
    /// — the owner's interval gates the *network* check, not this one. Riding a
    /// fifteen-minute tick, a "half an hour" rung could land anywhere from 15 to
    /// 30 minutes out, and it would have to go.
    static let bands: [(name: String, within: TimeInterval)] = [
        ("day", 24 * 60 * 60),
        ("hours", 2 * 60 * 60),
        ("soon", 30 * 60)
    ]

    /// The hour a check-in counts as morning.
    ///
    /// Quiet hours already stop the appliance speaking at night, so this is not
    /// about waking anybody. It is about not asking "did the chiro happen?" at
    /// one minute past midnight, sixty seconds after a deadline lapsed.
    public static let morningHour = 9

    /// How often the overdue check-ins repeat after the first. Weekly: the decay
    /// the owner asked for, and slow enough that a stale task stays a mention
    /// rather than becoming a grievance.
    public static let overdueRepeatDays = 7

    // MARK: What one look decides

    /// A single thing to say, and the key that stops it being said twice.
    public struct Nudge: Equatable, Sendable {
        /// Stable across ticks, unique per task per rung. Never reused between
        /// rungs — that is what lets the two-hour rung fire after the day rung
        /// already has.
        public let key: String
        public let text: String

        public init(key: String, text: String) {
            self.key = key
            self.text = text
        }
    }

    /// Everything worth saying right now about the tasks in hand.
    ///
    /// Never throws, never reads a clock, never touches a network. The same
    /// tasks at the same instant against the same ledger return the same answer
    /// forever, which is what makes any of this testable.
    /// - Parameter mirrored: task ids the calendar is already holding an event
    ///   for. Their run-up rungs are left to the OS; see `nudge(for:…)`.
    public static func due(
        tasks: [WatchedTask],
        alreadySaid: Set<String>,
        now: Date,
        mirrored: Set<String> = [],
        calendar: Calendar = .current
    ) -> [Nudge] {
        tasks
            .compactMap {
                nudge(for: $0, now: now, inCalendar: mirrored.contains($0.id), calendar: calendar)
            }
            .filter { !alreadySaid.contains($0.key) }
    }

    /// Keys still worth keeping; everything else belongs to a task that is gone.
    ///
    /// The ledger is written forever, and an appliance that runs for a year must
    /// not carry a rung for every task the owner has ever finished.
    public static func keysWorthKeeping(_ said: Set<String>, tasks: [WatchedTask]) -> Set<String> {
        let live = Set(tasks.map(\.id))
        return said.filter { live.contains(String($0.prefix(while: { $0 != "#" }))) }
    }

    // MARK: One task

    /// The one thing worth saying about this task now, if anything.
    ///
    /// At most one, deliberately. A task cannot be both two hours away and eight
    /// days overdue, and a version that returned every rung a task had passed
    /// would deliver the entire ladder in one message the first time the ledger
    /// was empty.
    /// - Parameter inCalendar: whether an event for this task exists in Mynah's
    ///   own calendar.
    ///
    ///   **The run-up rungs then belong to the OS.** A calendar alert fires
    ///   whether or not this Mac is awake and reaches the owner's phone and
    ///   watch, which is strictly better than a 60-second tick in a daemon —
    ///   and sending both would mean being told about the dentist twice, which
    ///   is how somebody turns the whole feature off.
    ///
    ///   The overdue check-in is deliberately unaffected. *"That was yesterday,
    ///   move it or drop it?"* is a question, and a calendar alert has nowhere to
    ///   put the answer. So the split is: iCal owns "it is happening soon",
    ///   Mynah owns "it did not happen, what now".
    static func nudge(
        for task: WatchedTask,
        now: Date,
        inCalendar: Bool = false,
        calendar: Calendar
    ) -> Nudge? {
        guard let written = SpokenDate.writtenDateMatch(in: task.title, calendar: calendar) else {
            return nil
        }
        let what = SpokenDate.withoutWrittenDate(in: task.title, calendar: calendar)

        // **A day-shaped task is not due at midnight.** "Meeting with TII IT on
        // Tuesday" is due *during* Tuesday, so it lapses when Tuesday ends. Read
        // literally, its `Date` is 00:00 and the task would be overdue for the
        // whole of the day it is meant to happen on.
        let lapsesAt = written.granularity == .minute
            ? written.at
            : calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: written.at)) ?? written.at

        guard now < lapsesAt else {
            return overdue(task: task, what: what, due: written.at, now: now, calendar: calendar)
        }
        // Everything below this line is a run-up rung, and the calendar has them.
        guard !inCalendar else { return nil }
        guard written.granularity == .minute else {
            return dayShaped(task: task, what: what, due: written.at, now: now, calendar: calendar)
        }

        let remaining = written.at.timeIntervalSince(now)
        guard let band = bands.last(where: { remaining <= $0.within }) else { return nil }
        return Nudge(
            key: "\(task.id)#\(band.name)",
            text: "\(what) — \(gap(remaining, due: written.at, now: now, calendar: calendar))."
        )
    }

    /// Two rungs for an all-day thing: the morning before, and the morning of.
    ///
    /// No hour-based band, because there is no hour. Anything tighter would be
    /// counting down to midnight, which is not when the meeting is.
    private static func dayShaped(
        task: WatchedTask,
        what: String,
        due: Date,
        now: Date,
        calendar: Calendar
    ) -> Nudge? {
        let day = calendar.startOfDay(for: due)
        guard let morningOf = calendar.date(bySettingHour: morningHour, minute: 0, second: 0, of: day),
              let dayBefore = calendar.date(byAdding: .day, value: -1, to: day),
              let morningBefore = calendar.date(bySettingHour: morningHour, minute: 0, second: 0, of: dayBefore)
        else { return nil }

        if now >= morningOf {
            return Nudge(key: "\(task.id)#today", text: "\(what) — today.")
        }
        // Bounded at both ends. Without the upper bound, the small hours of the
        // day itself still satisfy "after the morning before", and 2am on
        // Tuesday would be told the Tuesday meeting is tomorrow.
        if now >= morningBefore, now < day {
            return Nudge(key: "\(task.id)#tomorrow", text: "\(what) — tomorrow.")
        }
        return nil
    }

    // MARK: After

    /// The decaying check-in: the morning after, then weekly.
    ///
    /// The owner keeps tasks past their deadline on purpose — *"keep tasks past
    /// their deadline but remind the user about it again from time to time to
    /// ask if they want it moved to a later date or removed"*. So this asks a
    /// question rather than reporting a fact, and it asks it less and less
    /// often. Nothing here ever moves or drops a task by itself: a date the
    /// owner did not give is exactly what the rest of this subsystem exists to
    /// avoid inventing.
    private static func overdue(
        task: WatchedTask,
        what: String,
        due: Date,
        now: Date,
        calendar: Calendar
    ) -> Nudge? {
        guard let firstMorning = calendar.date(
            bySettingHour: morningHour,
            minute: 0,
            second: 0,
            of: calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: due)) ?? due
        ) else { return nil }

        // Before the first check-in is even due — a deadline that lapsed an hour
        // ago has not yet earned a question.
        guard now >= firstMorning else { return nil }

        let days = calendar.dateComponents([.day], from: firstMorning, to: now).day ?? 0
        let round = max(0, days / overdueRepeatDays)

        if round == 0 {
            return Nudge(
                key: "\(task.id)#overdue-0",
                text: "\(what) was \(passed(due, now: now, calendar: calendar)) — "
                    + "did that happen, or should I move it?"
            )
        }
        return Nudge(
            key: "\(task.id)#overdue-\(round)",
            text: "Still got \(what) open, from \(written(due, now: now, calendar: calendar)). "
                + "Move it or drop it?"
        )
    }

    // MARK: Words

    /// How far off it is, in words that do not promise a minute.
    ///
    /// The owner reads this on a phone while doing something else, and an
    /// appliance that says "in 2 hours" has made a promise about a message sent
    /// from a timer it does not control. "About" is not hedging: the tick is a
    /// minute wide and the message has a network to cross.
    static func gap(
        _ remaining: TimeInterval,
        due: Date,
        now: Date,
        calendar: Calendar
    ) -> String {
        let minutes = Int((remaining / 60).rounded())
        let clock = spokenClock(due, calendar: calendar)

        // `Calendar.isDateInTomorrow` answers relative to the *system* clock,
        // not to the `now` it was handed, so it cannot be tested and quietly
        // disagrees with every other line in this file. Counted from `now`
        // instead.
        let days = dayOffset(from: now, to: due, calendar: calendar)
        if days != 0 {
            return days == 1
                ? "tomorrow at \(clock)"
                : "on \(weekday(due, calendar: calendar)) at \(clock)"
        }
        if minutes >= 90 {
            return "in about \(Int((Double(minutes) / 60).rounded())) hours, at \(clock)"
        }
        if minutes >= 50 { return "in about an hour, at \(clock)" }
        if minutes >= 20 { return "in about half an hour, at \(clock)" }
        if minutes >= 5 { return "in about \(minutes) minutes, at \(clock)" }
        return "in a few minutes, at \(clock)"
    }

    /// When a lapsed deadline was, said the way somebody would say it.
    static func passed(_ due: Date, now: Date, calendar: Calendar) -> String {
        let ago = -dayOffset(from: now, to: due, calendar: calendar)
        if ago == 1 { return "yesterday" }
        if ago < 7 { return "on \(weekday(due, calendar: calendar))" }
        return "on \(written(due, now: now, calendar: calendar))"
    }

    /// Whole days between two instants, counted from midnight to midnight so
    /// "tomorrow" means the next calendar day rather than 24 hours away.
    ///
    /// Everything here takes `now` rather than reading the clock, which
    /// `Calendar.isDateInTomorrow` and its siblings cannot do.
    static func dayOffset(from now: Date, to date: Date, calendar: Calendar) -> Int {
        calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: date)
        ).day ?? 0
    }

    /// "the 5th of August" — a date old enough that a weekday no longer places
    /// it.
    static func written(_ due: Date, now: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = calendar.component(.year, from: due) == calendar.component(.year, from: now)
            ? "d MMMM"
            : "d MMMM yyyy"
        return formatter.string(from: due)
    }

    static func spokenClock(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = calendar.component(.minute, from: date) == 0 ? "h a" : "h:mm a"
        return formatter.string(from: date)
    }

    static func weekday(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "EEEE"
        return formatter.string(from: date)
    }
}
