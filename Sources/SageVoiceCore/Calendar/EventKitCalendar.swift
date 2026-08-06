import Foundation
import EventKit

// MARK: - What a calendar has to be able to do

/// The calendar, as the mirror needs it.
///
/// A protocol so that everything above it can be tested without granting
/// calendar access, without the owner's real appointments in scope, and without
/// a permission prompt appearing during `swift test`. `EventKitCalendar` is the
/// only implementation that touches anything real.
public protocol CalendarWriting: Sendable {
    /// Whether this Mac will let Mynah write, asking once if it has never been
    /// asked. `false` is an ordinary answer, not an error.
    func prepare() async -> Bool
    /// Writes an event and returns the identifier to remember it by.
    func add(_ entry: CalendarEntry) async throws -> String
    /// Changes an event that already exists. Returns the identifier again,
    /// because EventKit is entitled to give a new one.
    func update(_ entry: CalendarEntry, eventID: String) async throws -> String
    /// Removes an event. An event that is already gone is a success.
    func remove(eventID: String) async throws
}

// MARK: - The real one

/// Mynah's own calendar in the owner's Calendar app.
///
/// **A mirror, never an authority.** SAGE holds the tasks; this holds a copy of
/// the dated ones so that macOS can do the reminding — which it does better than
/// a 60-second tick in a daemon can, because its alerts fire from the OS, reach
/// the owner's phone and watch through iCloud, and survive the Mac being shut.
/// Nothing here ever reads the calendar back as truth: two writable stores with
/// no arbiter is how an appointment ends up existing in one and cancelled in the
/// other.
///
/// **It touches exactly one calendar**, the one it made, and it is the only
/// thing that ever writes there. Everything else the owner keeps is invisible to
/// it — not by good manners but by construction, because every operation goes
/// through an event identifier this appliance wrote down itself. Deleting the
/// "Mynah" calendar in Calendar.app is therefore a complete and obvious
/// uninstall.
public final class EventKitCalendar: CalendarWriting, @unchecked Sendable {

    /// What the calendar is called, and how the owner recognises it as Mynah's.
    public static let calendarTitle = "Mynah"

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case notAllowed
        case noCalendar(String)
        case eventVanished(String)

        public var description: String {
            switch self {
            case .notAllowed:
                return "this Mac has not given Mynah access to the calendar"
            case .noCalendar(let reason):
                return "Mynah's own calendar could not be made: \(reason)"
            case .eventVanished(let id):
                return "the event \(id) is no longer in the calendar"
            }
        }
    }

    private let store: EKEventStore
    private let title: String
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var mynahCalendar: EKCalendar?

    /// - Parameter title: the calendar's name. Overridden only by the end-to-end
    ///   test, which must not write into the owner's real one — everything else
    ///   uses `calendarTitle`, and two Mynahs sharing a Mac sharing a calendar is
    ///   the correct behaviour rather than a collision.
    public init(
        store: EKEventStore = EKEventStore(),
        title: String = EventKitCalendar.calendarTitle,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.store = store
        self.title = title
        self.log = log
    }

    /// Removes the calendar and everything in it.
    ///
    /// The complete uninstall, and the same thing dragging it to the bin in
    /// Calendar.app does. Used by the end-to-end test to clear up after itself.
    public func forget() throws {
        guard let existing = store.calendars(for: .event).first(where: {
            $0.title == title && $0.allowsContentModifications
        }) else { return }
        try store.removeCalendar(existing, commit: true)
        lock.lock()
        mynahCalendar = nil
        lock.unlock()
        log("[calendar] removed the “\(title)” calendar and everything in it")
    }

    // MARK: Permission

    /// Whether this Mac has already refused, so nothing asks again.
    ///
    /// Asking a second time does not show a prompt — macOS remembers the
    /// refusal — so a caller that retries every tick simply burns a call and
    /// learns nothing. Worth knowing separately from "not asked yet", which is
    /// the state where asking is the right thing to do.
    public static var wasRefused: Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .denied, .restricted: return true
        default: return false
        }
    }

    /// Refused with the status left at `notDetermined` — nobody was ever asked.
    ///
    /// **The state that cost this feature its whole life.** Under the hardened
    /// runtime a process without
    /// `com.apple.security.personal-information.calendars` is refused EventKit
    /// before macOS shows the owner anything: `requestFullAccessToEvents`
    /// returns `false`, no error is thrown, and the authorization status is
    /// still `notDetermined` afterwards. A genuine refusal leaves `.denied`.
    ///
    /// So the two are distinguishable, and telling them apart is the difference
    /// between "the owner said no" and "this build cannot ask" — which need
    /// opposite responses and which read identically in a log that only says
    /// "declined". `sage-voiced` shipped unentitled through 1.7.5 and wrote this
    /// line 177 times on the owner's Mac, once every sixteen minutes, while the
    /// mirror had never worked from the daemon at all.
    ///
    /// See `resources/SageVoiced.entitlements` for the measurements.
    static func wasNeverAsked(_ status: EKAuthorizationStatus) -> Bool {
        status == .notDetermined
    }

    public func prepare() async -> Bool {
        if Self.wasRefused {
            log("""
                [calendar] this Mac has refused calendar access, so nothing will be mirrored. \
                To change it: System Settings → Privacy & Security → Calendars → turn on Mynah.
                """)
            return false
        }
        do {
            // **Asked here, which is the first moment there is a dated task to
            // mirror.** Never at launch: an appliance that demands calendar
            // access on first run, before it has earned anything, is one people
            // decline permanently — and a refusal is remembered for ever.
            let granted = try await store.requestFullAccessToEvents()
            guard granted else {
                // Named separately, because these want opposite things from
                // whoever reads the log. One is the owner's decision; the other
                // is a build that cannot ask and will never be able to, and no
                // amount of clicking in System Settings fixes it — the process
                // does not even appear there.
                if Self.wasNeverAsked(EKEventStore.authorizationStatus(for: .event)) {
                    log("""
                        [calendar] macOS refused calendar access without asking, and left the \
                        status at "not determined". That is not the owner declining — it is this \
                        build lacking the calendar entitlement, so it cannot ask and cannot be \
                        switched on in System Settings either. Fix the build: see \
                        resources/SageVoiced.entitlements.
                        """)
                } else {
                    log("[calendar] calendar access was declined")
                }
                return false
            }
        } catch {
            log("[calendar] could not ask for calendar access: \(error)")
            return false
        }
        return (try? calendar()) != nil
    }

    // MARK: The calendar itself

    /// Mynah's calendar, made on first use.
    ///
    /// **Written into the iCloud account where there is one.** A `.local`
    /// calendar exists only on this Mac, and the entire reason for doing this
    /// rather than keeping the reminder ladder is that an alert should reach the
    /// owner's phone and watch. Falling back to local when there is no iCloud
    /// account keeps the feature working on a Mac that has none, at the cost of
    /// the thing that made it better — so which one happened is logged rather
    /// than left for somebody to deduce from a missing notification.
    private func calendar() throws -> EKCalendar {
        lock.lock()
        defer { lock.unlock() }
        if let mynahCalendar, store.calendar(withIdentifier: mynahCalendar.calendarIdentifier) != nil {
            return mynahCalendar
        }

        let existing = store.calendars(for: .event).first {
            $0.title == title && $0.allowsContentModifications
        }
        if let existing {
            mynahCalendar = existing
            return existing
        }

        let made = EKCalendar(for: .event, eventStore: store)
        made.title = title
        guard let source = writableSource() else {
            throw Failure.noCalendar("this Mac has no account that accepts a new calendar")
        }
        made.source = source
        do {
            try store.saveCalendar(made, commit: true)
        } catch {
            throw Failure.noCalendar(error.localizedDescription)
        }
        log("[calendar] made the “\(title)” calendar in \(source.title)")
        mynahCalendar = made
        return made
    }

    private func writableSource() -> EKSource? {
        let sources = store.sources.filter { source in
            source.calendars(for: .event).contains { $0.allowsContentModifications }
                || source.sourceType == .local
        }
        return sources.first { $0.sourceType == .calDAV && $0.title.lowercased() == "icloud" }
            ?? sources.first { $0.sourceType == .calDAV }
            ?? sources.first { $0.sourceType == .local }
            ?? store.defaultCalendarForNewEvents?.source
    }

    // MARK: Writing

    public func add(_ entry: CalendarEntry) async throws -> String {
        let event = EKEvent(eventStore: store)
        event.calendar = try calendar()
        Self.apply(entry, to: event)
        try store.save(event, span: .thisEvent, commit: true)
        guard let identifier = event.eventIdentifier else {
            throw Failure.eventVanished(entry.taskID)
        }
        log("[calendar] added “\(entry.title)”")
        return identifier
    }

    public func update(_ entry: CalendarEntry, eventID: String) async throws -> String {
        // **Gone is not an error worth failing on.** The owner is entitled to
        // delete an event from his own calendar, and when he has, the honest
        // response is to put the current one back rather than to report a fault
        // he caused on purpose.
        guard let event = store.event(withIdentifier: eventID) else {
            log("[calendar] “\(entry.title)” was no longer there; writing it again")
            return try await add(entry)
        }
        Self.apply(entry, to: event)
        try store.save(event, span: .thisEvent, commit: true)
        log("[calendar] updated “\(entry.title)”")
        return event.eventIdentifier ?? eventID
    }

    public func remove(eventID: String) async throws {
        guard let event = store.event(withIdentifier: eventID) else { return }
        let name = event.title ?? eventID
        try store.remove(event, span: .thisEvent, commit: true)
        log("[calendar] removed “\(name)”")
    }

    /// The zone an event is written in, or `nil` to let it float.
    ///
    /// **A timed event with no zone is not "local", it is undefined.** EventKit
    /// calls that floating, and a floating event syncing through iCloud is
    /// re-read by whatever device opens it — so "1pm" written on a Mac in Kuala
    /// Lumpur can come back as 1pm somewhere four hours away, which is a
    /// different instant and a missed appointment. The task said 1pm *here*,
    /// because the owner said it here, so the event has to say where here was.
    ///
    /// **All-day events float on purpose, and must.** A day is not an instant.
    /// Pin "Sunday 9 August" to a zone and it becomes midnight-to-midnight in
    /// that zone, which on a phone one timezone east is a hotel check-in that
    /// starts on the Saturday.
    static func timeZone(for entry: CalendarEntry, current: TimeZone = .current) -> TimeZone? {
        entry.isAllDay ? nil : current
    }

    /// Writes a task's fields onto an event.
    ///
    /// **Static and internal so it can be tested, and it had to be.** Every test
    /// of the timezone rule called `timeZone(for:current:)` and none of them
    /// could see whether anything ever *assigned* what it returned — the pure
    /// function was right for four releases while this method was free to drop
    /// it, and the failure that would have caused is a floating event, which
    /// looks to the owner like his calendar being "set to GMT" and to us like a
    /// missed appointment.
    ///
    /// Nothing here touches the store or the instance: the whole method reads a
    /// `CalendarEntry` and sets properties, so `static` costs nothing and lets a
    /// test hand it a bare `EKEvent`.
    ///
    /// - Parameter current: where this Mac is, injectable for the same reason
    ///   `timeZone(for:current:)` and `alarms(for:now:)` take theirs. **A test
    ///   that let this default could not see the assignment at all**: a fresh
    ///   `EKEvent` already reports `TimeZone.current`, measured on this Mac on 4
    ///   August 2026, so "the event carries the Mac's zone" is true of an event
    ///   nothing has touched. Handing in a zone the Mac is not in is what makes
    ///   the assignment visible.
    static func apply(_ entry: CalendarEntry, to event: EKEvent, current: TimeZone = .current) {
        event.title = entry.title
        event.isAllDay = entry.isAllDay
        event.timeZone = Self.timeZone(for: entry, current: current)
        event.startDate = entry.starts
        event.endDate = entry.isAllDay ? entry.starts : entry.ends
        // Replaced rather than added to. Without this an event edited on four
        // ticks carries four copies of every alarm, and the owner's phone goes
        // off four times.
        event.alarms = Self.alarms(for: entry, now: Date()).map { EKAlarm(relativeOffset: $0) }
        event.url = entry.link
        // The rest of the task's own words first, then one line about where this
        // came from — so somebody looking at their calendar in six months knows
        // what deleting it will and will not do.
        event.notes = [
            entry.detail,
            "Added by Mynah from your task list. Changing it here does not change the task."
        ].compactMap { $0 }.joined(separator: "\n\n")
    }

    /// When the alerts fire, in seconds relative to the start.
    ///
    /// **The reminder ladder's own rungs, handed to the OS.** A timed task got
    /// a day, two hours and half an hour; an all-day one got the morning before
    /// and the morning of. Those were the right moments — what was wrong was
    /// the delivery, which needed this Mac awake and the daemon running.
    ///
    /// All-day offsets are measured from midnight, so nine in the morning is
    /// `+9h` on the day and `-15h` the day before.
    ///
    /// **Nothing already past gets an alarm.** The first sync on a Mac that has
    /// been running for weeks writes every dated task at once, and several of
    /// them have been and gone — putting three alarms on each would mean a
    /// burst of notifications for things that already happened, which is a
    /// spectacular first impression of a feature meant to reduce noise. The task
    /// stays in the calendar as a record; it simply does not shout.
    static func alarms(for entry: CalendarEntry, now: Date = Date()) -> [TimeInterval] {
        let offsets: [TimeInterval] = entry.isAllDay
            ? {
                let morning = TimeInterval(ReminderLadder.morningHour * 60 * 60)
                return [morning - 24 * 60 * 60, morning]
            }()
            : [-24 * 60 * 60, -2 * 60 * 60, -15 * 60]
        return offsets.filter { entry.starts.addingTimeInterval($0) > now }
    }
}
