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
///
/// ## The half that was missing, and the message that proved it
///
/// All of the above is true of *this process*. The window is a different one,
/// and it edits the same list.
///
/// On the morning of Tuesday 4 August 2026 the owner typed into the window:
/// *"remove the monday items from our task list bro - its already tuesday"*. It
/// did, and said so. Six seconds later the daemon's watch read the backlog, saw
/// a task missing that had been there at the last check, and reported his own
/// edit back to him over Signal as news — the exact message this type exists to
/// prevent, arriving through the one door it could not see.
///
/// So the flag is now asked in two places: this actor for the daemon's own
/// turns, and a marker file for everybody else's. The file is the only mechanism
/// available across a process boundary, and it keeps the same discipline: the
/// reader deletes it as it reads it, so two checks racing cannot both stay
/// quiet.
///
/// The restart argument above survives, only weaker. A marker written while the
/// daemon is down is consumed by the first check after it comes back, which
/// costs at most one check's worth of silence — bounded, once, and in exchange
/// for never reporting his own edit to him again.
public actor OwnTaskEdits {

    /// The tools that change the owner's task list.
    ///
    /// Here rather than on either surface, because both must agree on it and a
    /// second copy would be a second thing to forget. `VoiceBridgeDaemon` had
    /// the only copy, which is part of why the window never suppressed anything.
    ///
    /// Deliberately the opposite policy to `ToolLoop.readOnlyTools`, which treats
    /// an unlisted tool as having acted because the dangerous direction there is
    /// missing a real write. Here the dangerous direction is the reverse: a tool
    /// wrongly listed suppresses genuine news, so this names only what actually
    /// writes tasks and a new one costs an extra announcement rather than a
    /// silence.
    public static let taskWritingTools: Set<String> = ["sage_task"]

    /// Whether a finished turn changed the list.
    ///
    /// Failed calls do not count. A `sage_task` the node refused changed nothing,
    /// so there is nothing for the watch to report and nothing to suppress —
    /// and suppressing on it would swallow whatever *did* change in that window.
    public static func wroteToTheTaskList(_ trace: ToolLoopTrace) -> Bool {
        trace.toolCalls.contains { taskWritingTools.contains($0.name) && !$0.failed }
    }

    private var pending = false
    private let marker: URL

    public init(marker: URL = OwnTaskEdits.defaultMarkerURL()) {
        self.marker = marker
    }

    public static func defaultMarkerURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/SAGE Voice Bridge", isDirectory: true)
            .appendingPathComponent("own-task-edit", isDirectory: false)
    }

    /// Called after a turn in *this* process that wrote to the task list.
    public func record() {
        pending = true
    }

    /// Called after a turn in any *other* process that wrote to the task list —
    /// which today means the window.
    ///
    /// Static, and deliberately not an actor method: the writer does not own the
    /// daemon's actor and in the window's case is not even in the same program.
    ///
    /// A failure here does not fail the turn — the edit was made and confirmed,
    /// and refusing to answer because a hint could not be written would be
    /// absurd. It is *said*, though. A write that cannot happen means he gets his
    /// own edit read back to him over Signal a quarter of an hour later, and the
    /// only thing worse than that message is that message with nothing in the log
    /// to explain it.
    public static func recordFromAnotherProcess(
        marker: URL = OwnTaskEdits.defaultMarkerURL(),
        log: (String) -> Void = { _ in }
    ) {
        do {
            try OwnerOnlyFileSecurity.write(Data(), to: marker)
        } catch {
            log("could not note your own task edit at \(marker.path), "
                + "so the watch may report it back to you: \(error)")
        }
    }

    /// Whether the coming check should stay quiet about tasks, clearing the note
    /// as it goes.
    ///
    /// Take-and-clear rather than read-then-clear, so two checks racing cannot
    /// both decide to stay quiet — the second one has news to deliver and must.
    /// The file half is taken the same way, by deleting it.
    public func takeSuppression() -> Bool {
        let fromHere = pending
        pending = false
        // Removal *is* the read. `fileExists` then `removeItem` would be two
        // syscalls with a window between them; this is one answer.
        let fromElsewhere = (try? FileManager.default.removeItem(at: marker)) != nil
        return fromHere || fromElsewhere
    }
}
