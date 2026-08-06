import Foundation

/// One pass of putting dated tasks into the calendar.
///
/// Everything that decides *what* to write is in `CalendarMirror`, which is a
/// pure function; everything that decides *whether* is here, because that
/// depends on permission, on whether the node answered, and on a calendar that
/// might refuse. Both halves stay small enough to hold in the head.
public struct CalendarSync: Sendable {

    public struct Outcome: Sendable {
        public let ledger: CalendarLedger
        /// Task ids the calendar is currently holding an event for.
        ///
        /// Passed to `ReminderLadder` so it stops sending the run-up nudges for
        /// anything the OS is already going to shout about. The overdue
        /// check-ins are unaffected — those are a conversation, and a calendar
        /// alert has no reply channel.
        public let mirrored: Set<String>
        /// What went wrong, if anything, in words worth putting in a log.
        public let trouble: String?

        public init(ledger: CalendarLedger, mirrored: Set<String>, trouble: String? = nil) {
            self.ledger = ledger
            self.mirrored = mirrored
            self.trouble = trouble
        }
    }

    private let calendar: any CalendarWriting
    private let log: @Sendable (String) -> Void

    public init(calendar: any CalendarWriting, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.calendar = calendar
        self.log = log
    }

    /// Brings the calendar into line with the task list.
    ///
    /// - Parameter tasks: the open tasks, or `nil` when the node could not be
    ///   asked. **The distinction is the whole safety property.** Read as an
    ///   empty list, an unreachable node means every dated task has just been
    ///   finished — and unlike the proactive digest, which would merely say
    ///   something wrong, this would delete the owner's calendar entries. A
    ///   failed look changes nothing at all.
    public func run(
        tasks: [WatchedTask]?,
        ledger: CalendarLedger,
        clock: Calendar = .current,
        preferences: CalendarPreferences = CalendarPreferences.load()
    ) async -> Outcome {
        // **Switched off means stop writing, and it must never mean delete.**
        //
        // The tempting shape is to let an off switch fall through to a plan
        // computed against no tasks, because that reads as "mirror nothing". It
        // would empty the owner's calendar: every mirrored task becomes a
        // `plan.remove`, and somebody flicking a switch to see what it does
        // would lose their events. Taking them back is a separate, explicit act
        // — `EventKitCalendar.forget()` — so that destroying data is always
        // something the owner asked for in those words.
        //
        // The ledger and `mirrored` are returned untouched, which keeps
        // `ReminderLadder` quiet about tasks the calendar is still holding. The
        // events are still there and macOS will still shout about them; nothing
        // about turning off future writes makes the existing alarms stop.
        guard preferences.isOn else {
            return Outcome(ledger: ledger, mirrored: Set(ledger.events.keys))
        }
        guard let tasks else {
            return Outcome(ledger: ledger, mirrored: Set(ledger.events.keys))
        }
        let plan = CalendarMirror.plan(tasks: tasks, against: ledger, calendar: clock)
        guard !plan.isEmpty else {
            return Outcome(ledger: ledger, mirrored: Set(ledger.events.keys))
        }

        // **Said out loud, because on 6 August it was not.**
        //
        // Eleven events were removed in one tick and the only line about it was
        // "mirroring 0 dated task(s)" — true about the plan, silent about why.
        // The cause was upstream and is fixed there: `SageProactiveSource` used
        // to turn a reply it could not read into an empty backlog, so a node
        // that answered something else looked exactly like an owner who had
        // finished everything.
        //
        // This stays anyway, because the guard above it is a distinction that
        // has to be maintained by every future caller, and the failure mode is
        // silent deletion of the owner's calendar. Clearing the whole mirror in
        // one tick is a real thing he can ask for — finish the last dated task
        // and it is correct — but it is rare enough to be worth a line, and the
        // line is what turns the next occurrence into five minutes of reading
        // rather than an evening of inference.
        if !plan.remove.isEmpty, plan.remove.count == ledger.events.count, plan.add.isEmpty {
            log("[calendar] every mirrored event (\(plan.remove.count)) is about to be removed, "
                + "because this look saw \(tasks.count) dated task(s). If that is not what the "
                + "owner did, the backlog read is the thing to check, not the calendar.")
        }

        // Asked only now, on the first tick that genuinely has something to
        // write. This is the moment the owner's task actually gained a date, and
        // it is the only honest time to ask — a prompt at launch, before the
        // feature has done anything for them, is one people decline for ever.
        guard await calendar.prepare() else {
            return Outcome(
                ledger: ledger,
                mirrored: [],
                trouble: "no calendar access, so nothing is mirrored"
            )
        }

        var written: [String: String] = [:]
        var removed: Set<String> = []
        var failures: [String] = []

        for entry in plan.add {
            do { written[entry.taskID] = try await calendar.add(entry) }
            catch { failures.append("could not add “\(entry.title)”: \(error)") }
        }
        for (entry, eventID) in plan.update {
            do { written[entry.taskID] = try await calendar.update(entry, eventID: eventID) }
            catch { failures.append("could not update “\(entry.title)”: \(error)") }
        }
        for (taskID, eventID) in plan.remove {
            do {
                try await calendar.remove(eventID: eventID)
                removed.insert(taskID)
            } catch {
                failures.append("could not remove the event for \(taskID): \(error)")
            }
        }

        let settled = CalendarMirror.settled(ledger, after: plan, written: written, removed: removed)
        for failure in failures { log("[calendar] \(failure)") }
        return Outcome(
            ledger: settled,
            mirrored: Set(settled.events.keys),
            trouble: failures.isEmpty ? nil : failures.joined(separator: "; ")
        )
    }
}
