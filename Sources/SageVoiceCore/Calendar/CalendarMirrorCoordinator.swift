import Foundation

/// The one serialized doorway into the task-to-calendar mirror.
///
/// Calendar mirroring used to happen only as a side effect of the proactive
/// watch. That coupled two independent switches: with proactive checks off, an
/// enabled calendar never received anything; with them on, a task could still
/// wait for the owner's next check interval. A dated `sage_task` write now asks
/// this coordinator to refresh immediately, while the watch still reconciles
/// through the same doorway as a safety net.
///
/// Keeping the ledger here also prevents the immediate refresh and a periodic
/// check from loading the same old ledger and racing two EventKit writes.
public actor CalendarMirrorCoordinator {
    private let source: any ProactiveSource
    private let calendar: CalendarSync
    private let ledgerURL: URL
    private let preferences: @Sendable () -> CalendarPreferences
    private let log: @Sendable (String) -> Void

    public init(
        source: any ProactiveSource,
        calendar: CalendarSync,
        ledgerURL: URL = CalendarLedger.defaultFileURL(),
        preferences: @escaping @Sendable () -> CalendarPreferences = { CalendarPreferences.load() },
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.source = source
        self.calendar = calendar
        self.ledgerURL = ledgerURL
        self.preferences = preferences
        self.log = log
    }

    /// Re-read the task list and mirror it now.
    ///
    /// Used after a successful task write. Failure is deliberately a no-op for
    /// the existing calendar: an unreachable or unreadable backlog must never
    /// be mistaken for an empty one and remove the owner's events.
    @discardableResult
    public func refresh() async -> CalendarSync.Outcome? {
        do {
            return await sync(tasks: try await source.openTasks())
        } catch {
            log("[calendar] could not refresh after the task write, so nothing was changed: \(error)")
            return nil
        }
    }

    /// Mirror a task snapshot another reader already obtained.
    ///
    /// The proactive watch uses this overload so it does not ask SAGE twice.
    @discardableResult
    public func sync(tasks: [WatchedTask]?) async -> CalendarSync.Outcome {
        let before = CalendarLedger.load(from: ledgerURL)
        let outcome = await calendar.run(
            tasks: tasks,
            ledger: before,
            preferences: preferences()
        )
        if outcome.ledger != before {
            do {
                try outcome.ledger.save(to: ledgerURL)
                log("[calendar] mirroring \(outcome.ledger.events.count) dated task(s)")
            } catch {
                log("[calendar] mirrored events but could not save the ledger: \(error)")
            }
        }
        if let trouble = outcome.trouble { log("[calendar] \(trouble)") }
        return outcome
    }

    /// What Calendar already holds, for suppressing duplicate run-up nudges.
    public func mirroredTaskIDs() -> Set<String> {
        Set(CalendarLedger.load(from: ledgerURL).events.keys)
    }
}
