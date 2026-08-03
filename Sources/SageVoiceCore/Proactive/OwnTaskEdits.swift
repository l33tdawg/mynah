import Foundation

/// A note that the owner has just changed his own task list, so the next check
/// should absorb the difference rather than report it.
///
/// ## The message that earned this
///
/// He asked Mynah to pin a deadline to an open-ended task. Mynah did it and said
/// so, in prose, naming both halves: *"I've replaced the old open-ended TDAC
/// task with this one so the reminder fires with the deadline attached."* Then,
/// separately, the watch told him:
///
///     A new task landed: "Apply for Thailand Digital Arrival Card (TDAC) …"
///     A new task landed: "Dentist appointment — Tuesday 4 August 2026, 1pm."
///     A task came off the list.
///     A task came off the list.
///
/// Four lines, all of them his own two edits reported back to him as news, and
/// two of them saying nothing at all. He asked the right question about it:
/// *"the tasks coming on and off the lists; what do you think - useful;
/// annoying ? too often ?"*
///
/// Useful — for a task an *agent* added, or one that moved while he was asleep.
/// That is what the feature is for. Not for the edit he made thirty seconds ago
/// and already had confirmed in words.
///
/// ## Why in memory rather than in the ledger
///
/// The ledger is a file, and the daemon and the watch loop would both be doing
/// load-modify-write on it — the watch holds a copy across a node round trip, so
/// a flag written during that window is simply overwritten. Both live in the
/// same process, so an actor is the honest mechanism: the flag cannot be lost to
/// a race, only to a restart.
///
/// **And losing it to a restart is the safe direction.** The flag suppresses; a
/// missing flag means one extra announcement, while a persisted flag surviving a
/// crash could swallow a genuinely new task forever.
public actor OwnTaskEdits {

    private var pending = false

    public init() {}

    /// Called after a turn that wrote to the task list.
    public func record() {
        pending = true
    }

    /// Whether the coming check should stay quiet about tasks, clearing the note
    /// as it goes.
    ///
    /// Take-and-clear rather than read-then-clear, so two checks racing cannot
    /// both decide to stay quiet — the second one has news to deliver and must.
    public func takeSuppression() -> Bool {
        defer { pending = false }
        return pending
    }
}
