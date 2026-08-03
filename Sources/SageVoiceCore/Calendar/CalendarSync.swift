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
        clock: Calendar = .current
    ) async -> Outcome {
        guard let tasks else {
            return Outcome(ledger: ledger, mirrored: Set(ledger.events.keys))
        }
        let plan = CalendarMirror.plan(tasks: tasks, against: ledger, calendar: clock)
        guard !plan.isEmpty else {
            return Outcome(ledger: ledger, mirrored: Set(ledger.events.keys))
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
