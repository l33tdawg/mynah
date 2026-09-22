import Foundation

/// When a piece of scheduled work comes round.
///
/// **The owner, 22 September 2026: "we need to add the ability for mynah to run
/// scheduled tasks."** The conversation that produced it is the shape of the
/// gap. He asked whether Mynah could check its inbox "from time to time", and
/// the honest answer was that nothing on this side had a clock: everything the
/// appliance did, it did because somebody had just spoken to it, with two
/// exceptions that are not this — the proactive watch, which looks on a fixed
/// cadence at a fixed question, and the reminder ladder, which reads dates out
/// of the owner's own task list.
///
/// So this is the clock, and it is deliberately three shapes wide: a time of
/// day, a weekday and a time, or an interval. **Not a cron expression**, and not
/// a general recurrence language. Every shape here is one the owner says out
/// loud in one breath and can be read back to him in one sentence, which is the
/// test the rest of this feature is built on. Anything else he asks for is a
/// sentence saying so — see `ScheduledWorkCommand`, which is where his words are
/// read.
///
/// ## Bands, not alarms
///
/// The same ruling the reminder ladder made, for the same machine: a Mac that
/// sleeps through eight in the morning has not missed eight in the morning, it
/// has woken up. So nothing here asks *"has this moment arrived?"* — a question
/// that has to be asked at the moment, or the answer is a lie. It asks *"how far
/// back is the last moment this came round?"* and compares that with when the
/// work last ran. A lap that was slept through therefore runs once, late, on the
/// first tick after waking, and never twice: the claim is written before the
/// work runs, and the next occurrence is then ahead of it.
public enum ScheduleCadence: Equatable, Sendable {

    /// Every day at this local time.
    case daily(hour: Int, minute: Int)

    /// Every week on this weekday (`Calendar`'s own numbering, 1 = Sunday), at
    /// this local time.
    case weekly(weekday: Int, hour: Int, minute: Int)

    /// Every so many minutes, measured from when the work last ran.
    case every(minutes: Int)

    /// The most often this appliance will run anything the owner is not
    /// watching.
    ///
    /// Five minutes is the proactive watch's own floor (`ProactivePreferences
    /// .fastest`) and it is the floor here for a second reason: the loop ticks a
    /// minute at a time, so an interval shorter than the tick is a request that
    /// cannot be honoured, and a promise that cannot be honoured is worse than a
    /// refusal.
    public static let fastestEveryMinutes = 5

    /// A day. Past this, the shape he wants is a day of the week rather than
    /// "every 2880 minutes".
    public static let slowestEveryMinutes = 24 * 60

    // MARK: - What it says

    /// How the cadence reads back to the owner.
    ///
    /// 24-hour, because it is the one reading with no argument in it: "every
    /// day at 08:00" cannot be misread by anybody, where "8:00" is the eighth
    /// hour to half the world and the twentieth to the other half. `SpokenDate`
    /// makes the same call from the other side — a bare hour is refused rather
    /// than guessed at.
    public var spoken: String {
        switch self {
        case .daily(let hour, let minute):
            return "every day at \(Self.clock(hour, minute))"
        case .weekly(let weekday, let hour, let minute):
            return "every \(Self.weekdayName(weekday)) at \(Self.clock(hour, minute))"
        case .every(let minutes):
            return "every \(Self.spokenInterval(minutes))"
        }
    }

    static func clock(_ hour: Int, _ minute: Int) -> String {
        String(format: "%02d:%02d", hour, minute)
    }

    /// Public because the Mac's Scheduled screen writes the same words into its
    /// interval picker: two spellings of "every 2 hours" is how the screen and
    /// the read-back start disagreeing about what the owner chose.
    public static func spokenInterval(_ minutes: Int) -> String {
        // Hours only when they divide exactly: "every 90 minutes" is a cadence,
        // "every 1.5 hours" is arithmetic.
        if minutes >= 60, minutes % 60 == 0 {
            let hours = minutes / 60
            return hours == 1 ? "hour" : "\(hours) hours"
        }
        return minutes == 1 ? "minute" : "\(minutes) minutes"
    }

    /// English weekday names, in `Calendar`'s numbering.
    ///
    /// A fixed table rather than `Calendar.weekdaySymbols`, because this string
    /// is read back to the owner in his own language of the two dozen this
    /// appliance speaks, and because a table is checkable by a test.
    public static func weekdayName(_ weekday: Int) -> String {
        let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        guard names.indices.contains(weekday - 1) else { return "day" }
        return names[weekday - 1]
    }

    // MARK: - When it comes round

    /// The most recent moment this cadence came round, at or before `now`.
    ///
    /// `nil` for an interval, which has no wall-clock moment to point at: it is
    /// measured from when the work last ran, and `isDue` is where that is
    /// decided.
    ///
    /// **Reads the calendar rather than adding seconds.** A day is not 86,400
    /// seconds in a country that moves its clocks, and "every day at 08:00" that
    /// has drifted to 07:00 half the year is a bug nobody would think to look
    /// for. `date(bySettingHour:)` also answers a time that does not exist —
    /// the 02:30 that a spring-forward skips — with the next one that does,
    /// which is the only sensible reading of "every day at 02:30" in a country
    /// where one 02:30 of the year is missing.
    public func latestOccurrence(
        onOrBefore now: Date,
        calendar: Calendar = .current
    ) -> Date? {
        switch self {
        case .every:
            return nil
        case .daily(let hour, let minute):
            guard let today = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now)
            else { return nil }
            if today <= now { return today }
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now) else { return nil }
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: yesterday)
        case .weekly(let weekday, let hour, let minute):
            guard (1...7).contains(weekday) else { return nil }
            let today = calendar.component(.weekday, from: now)
            let daysBack = ((today - weekday) % 7 + 7) % 7
            guard let day = calendar.date(byAdding: .day, value: -daysBack, to: now),
                  let candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
            else { return nil }
            if candidate <= now { return candidate }
            guard let aWeekEarlier = calendar.date(byAdding: .day, value: -7, to: day) else { return nil }
            return calendar.date(
                bySettingHour: hour, minute: minute, second: 0, of: aWeekEarlier
            )
        }
    }

    /// Whether this piece of work is due, given what it knows about itself.
    ///
    /// - Parameters:
    ///   - lastRun: when it last ran, or `nil` if it never has.
    ///   - createdAt: when the owner set it up. **The anchor for a schedule that
    ///     has never run, and the reason setting one up at nine in the morning
    ///     does not fire yesterday's or today's eight o'clock at him.** A
    ///     cadence starts at the next occurrence *after* the moment it was
    ///     written — which is also why the comparison below is `>` and not
    ///     `>=`: work created at exactly 08:00:00 waits for tomorrow.
    public func isDue(
        lastRun: Date?,
        createdAt: Date,
        now: Date,
        calendar: Calendar = .current
    ) -> Bool {
        let anchor = lastRun ?? createdAt
        // A Mac whose clock went backwards would otherwise stop running
        // anything until real time caught up. `ProactiveSchedule.isDue` makes
        // the same exception for the same reason.
        if now < anchor { return true }

        switch self {
        case .every(let minutes):
            let interval = TimeInterval(min(max(minutes, Self.fastestEveryMinutes), Self.slowestEveryMinutes))
            return now.timeIntervalSince(anchor) >= interval * 60
        case .daily, .weekly:
            guard let occurrence = latestOccurrence(onOrBefore: now, calendar: calendar) else {
                // An unreadable cadence — a hand-edited hour of 25 — runs
                // nothing rather than guessing at a time.
                return false
            }
            return occurrence > anchor
        }
    }
}

// MARK: - On disk

extension ScheduleCadence: Codable {

    private enum Kind: String, Codable {
        case daily, weekly, every
    }

    private enum CodingKeys: String, CodingKey {
        case kind, hour, minute, weekday, minutes
    }

    /// Flat rather than nested, so the file reads as what it holds when somebody
    /// opens it: `{"kind":"daily","hour":8,"minute":0}`.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .daily(let hour, let minute):
            try container.encode(Kind.daily, forKey: .kind)
            try container.encode(hour, forKey: .hour)
            try container.encode(minute, forKey: .minute)
        case .weekly(let weekday, let hour, let minute):
            try container.encode(Kind.weekly, forKey: .kind)
            try container.encode(weekday, forKey: .weekday)
            try container.encode(hour, forKey: .hour)
            try container.encode(minute, forKey: .minute)
        case .every(let minutes):
            try container.encode(Kind.every, forKey: .kind)
            try container.encode(minutes, forKey: .minutes)
        }
    }

    /// **The one boundary that validates.** The enum's cases are public so that
    /// callers and tests can pattern-match them, which means the compiler cannot
    /// stop somebody constructing `daily(hour: 91, minute: 0)`. The two places
    /// that create one are this initialiser and the parser that reads the
    /// owner's own sentence, and both refuse a cadence that is not a time —
    /// `latestOccurrence` then treats anything that slips through as work that
    /// never comes round, which is silent rather than at the wrong hour.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .daily:
            let hour = try container.decode(Int.self, forKey: .hour)
            let minute = try container.decode(Int.self, forKey: .minute)
            guard (0...23).contains(hour), (0...59).contains(minute) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .hour, in: container,
                    debugDescription: "\(ScheduleCadence.clock(hour, minute)) is not a time of day"
                )
            }
            self = .daily(hour: hour, minute: minute)
        case .weekly:
            let weekday = try container.decode(Int.self, forKey: .weekday)
            let hour = try container.decode(Int.self, forKey: .hour)
            let minute = try container.decode(Int.self, forKey: .minute)
            guard (1...7).contains(weekday), (0...23).contains(hour), (0...59).contains(minute) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .weekday, in: container,
                    debugDescription: "\(weekday) at \(ScheduleCadence.clock(hour, minute)) is not a weekday"
                )
            }
            self = .weekly(weekday: weekday, hour: hour, minute: minute)
        case .every:
            let minutes = try container.decode(Int.self, forKey: .minutes)
            guard (Self.fastestEveryMinutes...Self.slowestEveryMinutes).contains(minutes) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .minutes, in: container,
                    debugDescription: "every \(minutes) minutes is outside "
                        + "\(Self.fastestEveryMinutes)–\(Self.slowestEveryMinutes)"
                )
            }
            self = .every(minutes: minutes)
        }
    }
}
