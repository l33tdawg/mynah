import Foundation

/// One piece of work the owner has put on a clock.
///
/// The instruction is kept in **his own words**, deliberately: it is the prompt
/// this appliance runs through the ordinary brain when the time comes, and
/// paraphrasing it at the point of storage would be this file editing the
/// request. `SpokenDate` makes the same ruling for dates from the other side —
/// "resolved from the owner's own words and never from anything the model
/// wrote" — and the same reason applies: at the moment the thing runs, there is
/// nobody in the room to ask what he meant.
public struct ScheduledTask: Codable, Equatable, Sendable, Identifiable {

    public let id: String
    /// What to do, in the owner's words.
    public let instruction: String
    public let cadence: ScheduleCadence
    public let createdAt: Date
    /// Whether it may run. Pausing is not deleting: a standing request the owner
    /// wants back after a trip should not have to be typed again.
    public var isEnabled: Bool
    /// When its clock was last dealt with: when it last ran, or when it was
    /// switched back on. Set on the attempt rather than on the answer, for the
    /// reason `ProactiveLedger.lastCheckedAt` is — this bounds how often the
    /// appliance acts, not how often it has something to say.
    ///
    /// **Resuming writes this too, and the second meaning is deliberate.** A
    /// request held for a fortnight and switched back on has missed fifteen
    /// occurrences, and firing the moment it is resumed would be the appliance
    /// acting on a clock the owner cannot see. Resuming therefore anchors it
    /// here and the next occurrence is the next real one. One field rather than
    /// two, because a second date that means "this is where the counting
    /// restarted" is a second thing to keep in step with the first.
    public var lastRunAt: Date?

    public init(
        id: String,
        instruction: String,
        cadence: ScheduleCadence,
        createdAt: Date,
        isEnabled: Bool = true,
        lastRunAt: Date? = nil
    ) {
        self.id = id
        self.instruction = instruction
        self.cadence = cadence
        self.createdAt = createdAt
        self.isEnabled = isEnabled
        self.lastRunAt = lastRunAt
    }

    /// How it reads in a list or a read-back: "every day at 08:00 — check my
    /// inbox and tell me what's waiting."
    public var summary: String {
        "\(cadence.spoken) — \(ScheduledWork.flattened(instruction))"
    }
}

/// Everything the owner has put on a clock, and the file it lives in.
///
/// A file on this Mac rather than a memory on the node, and that is a decision
/// worth stating because the opposite is the house default: SAGE is the source
/// of truth for what Mynah remembers, and the task list lives there. This is not
/// a memory. **It is a property of this appliance's clock** — the thing that
/// decides when this Mac runs something — and it has to be readable by the
/// process that owns the minute-by-minute loop, with no node in the path. The
/// same argument put `proactive-preferences.json` and the ledger on disk, and
/// the calendar mirror keeps the same relationship from the other end: SAGE
/// holds the meaning, the Mac holds the mechanism.
///
/// **One bad row costs one piece of work, not the file.** The list is decoded
/// element by element, so a schedule somebody edited by hand into nonsense is
/// dropped on its own rather than taking the owner's other four with it. That is
/// the same reasoning `ProactivePreferences.load` gives for never throwing on a
/// file that will not parse: a bad edit should cost a setting, not the feature.
public struct ScheduledWork: Equatable, Sendable, Codable {

    public var tasks: [ScheduledTask]

    /// How many pieces of standing work one appliance will carry.
    ///
    /// **Not a disk limit — a context limit.** Everything here is read back into
    /// the model's turn on every message (see `note`), so an unbounded list is
    /// an unbounded prefill on a 4B model that is already the slow part of the
    /// product. Ten is more than anybody has asked for and few enough that the
    /// list stays a paragraph; past it the owner is told rather than quietly
    /// served a longer prompt.
    public static let maximumTasks = 10

    public init(tasks: [ScheduledTask] = []) {
        self.tasks = tasks
    }

    // MARK: Where it lives

    public static func defaultFileURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/SAGE Voice Bridge", isDirectory: true)
            .appendingPathComponent("scheduled-work.json", isDirectory: false)
    }

    /// Never throws, for the reason on the type: a file somebody edited by hand
    /// should cost a schedule, not the appliance.
    public static func load(from url: URL = ScheduledWork.defaultFileURL()) -> ScheduledWork {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(ScheduledWork.self, from: data) else {
            return ScheduledWork()
        }
        return stored
    }

    public func save(to url: URL = ScheduledWork.defaultFileURL()) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try OwnerOnlyFileSecurity.write(encoder.encode(self), to: url)
    }

    /// Decoded one element at a time. See the type's note.
    private struct LenientTask: Decodable {
        let task: ScheduledTask?
        init(from decoder: any Decoder) throws {
            task = try? ScheduledTask(from: decoder)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case tasks
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rows = try container.decodeIfPresent([LenientTask].self, forKey: .tasks) ?? []
        tasks = rows.compactMap(\.task)
    }

    // MARK: What the owner does to it

    /// 1-based numbering, oldest first.
    ///
    /// The owner refers to these out loud and on a phone keypad, so the number
    /// he sees in the list is the number he types. Order is by when each was set
    /// up rather than by when it runs, so the numbering does not move underneath
    /// him when he adds one.
    public func numbered() -> [(number: Int, task: ScheduledTask)] {
        tasks
            .sorted { $0.createdAt < $1.createdAt }
            .enumerated()
            .map { (number: $0.offset + 1, task: $0.element) }
    }

    public func task(number: Int) -> ScheduledTask? {
        numbered().first { $0.number == number }?.task
    }

    public mutating func add(
        instruction: String,
        cadence: ScheduleCadence,
        now: Date = Date(),
        id: String = UUID().uuidString
    ) -> ScheduledTask {
        let task = ScheduledTask(
            id: id, instruction: instruction, cadence: cadence, createdAt: now
        )
        tasks.append(task)
        return task
    }

    public mutating func remove(number: Int) -> ScheduledTask? {
        guard let task = task(number: number),
              let index = tasks.firstIndex(where: { $0.id == task.id })
        else { return nil }
        tasks.remove(at: index)
        return task
    }

    /// Stops it running without forgetting it.
    public mutating func pause(number: Int) -> ScheduledTask? {
        guard let task = task(number: number),
              let index = tasks.firstIndex(where: { $0.id == task.id })
        else { return nil }
        tasks[index].isEnabled = false
        return tasks[index]
    }

    /// Switches it back on with its clock anchored at `now`. See `lastRunAt`.
    ///
    /// Already running means already running: saying "resume" about something
    /// that was never held must not move its clock, or the second time the owner
    /// says it the request quietly slips by an hour.
    public mutating func resume(number: Int, now: Date) -> ScheduledTask? {
        guard let task = task(number: number),
              let index = tasks.firstIndex(where: { $0.id == task.id })
        else { return nil }
        guard !tasks[index].isEnabled else { return tasks[index] }
        tasks[index].isEnabled = true
        tasks[index].lastRunAt = now
        return tasks[index]
    }

    /// Everything due at `now`, with each one's run time written down *before*
    /// this returns.
    ///
    /// **The write-before-run order is the whole crash story.** The caller saves
    /// this value and only then runs the work, so a process that dies mid-turn
    /// loses one run and never repeats it — where the other order would repeat
    /// it on every tick for as long as the failure lasted, which is a phone that
    /// says the same thing every minute. `ReminderLadder`'s nudges are claimed
    /// the same way, for the same reason.
    ///
    /// A paused or disabled task is not claimed at all, so nothing is lost by a
    /// pause: whatever came round while it was off is still due when it comes
    /// back on.
    public mutating func claimDue(at now: Date, calendar: Calendar = .current) -> [ScheduledTask] {
        var claimed: [ScheduledTask] = []
        for index in tasks.indices where tasks[index].isEnabled {
            let task = tasks[index]
            guard task.cadence.isDue(
                lastRun: task.lastRunAt, createdAt: task.createdAt, now: now, calendar: calendar
            ) else { continue }
            tasks[index].lastRunAt = now
            claimed.append(tasks[index])
        }
        return claimed
    }
}

// MARK: - What the model is told

public extension ScheduledWork {

    /// One line for the turn being answered, or `nil` when there is nothing this
    /// appliance can do about it.
    ///
    /// **This is here because the failure this feature exists to fix was a
    /// sentence, not a missing timer.** Asked on 22 September 2026 whether it
    /// could check its inbox on its own, Mynah answered *"I have no timer or
    /// scheduler on my end. I only run when you speak to me, so a poll would
    /// need something outside me to wake me up on a clock, and I have no tool
    /// that does that."* Every word of that was true when it was said, and the
    /// owner read it as the appliance having no way to do what he wanted. A
    /// clock nobody has told the model about is a clock the owner hears about
    /// only as a denial.
    ///
    /// ## Where it goes, and why not in the system prompt
    ///
    /// The turn, beside `WhereWeAre.rightNow`, and not the prompt: the system
    /// prompt is the cache's prefix (`PromptLatencyBudgetTests` holds it under
    /// 8,300 characters, with a handful left) and it is held for the life of the
    /// process, so a list that changes when the owner sets something up would be
    /// both a cache miss on every turn that followed and — worse — stale, and
    /// stale in the direction of denying work he has just asked for.
    ///
    /// ## What it deliberately does not say
    ///
    /// The shapes. `//help` carries them, it is one keystroke away on the same
    /// thread, and a model reciting a grammar it half-remembers is worse than
    /// one pointing at the command — or, since `ScheduledWorkToolSource` exists,
    /// worse than one just reaching for the tool that reads the shape properly.
    /// What this gives the model is the three facts it needs to answer honestly:
    /// that standing work exists, what is currently set up, and **both** ways it
    /// gets there — asked for in conversation, or typed as a command — plus
    /// where the owner goes to turn one off, which is the Mac and not this
    /// thread.
    func note() -> String {
        let listed = numbered().map { "\($0.number)) \($0.task.summary)" }
        let holding = tasks.filter { !$0.isEnabled }.count
        let managing = "He adds one by asking you — \(ScheduledWorkToolSource.toolName) — or by "
            + "typing //schedule <when>: <what to do>, and turns them off or kills them in "
            + "Mynah's Scheduled screen on the Mac."
        guard !listed.isEmpty else {
            return """
                (STANDING WORK ON A CLOCK: work that runs by itself and messages him, whether \
                or not he is talking to you. \(managing) Nothing is set up right now.)
                """
        }
        return """
            (STANDING WORK ON A CLOCK, running by itself and messaging him: \
            \(listed.joined(separator: "; "))\(holding == 0 ? "" : "; \(holding) held"). \
            \(managing))
            """
    }

    /// The turn a piece of standing work runs as.
    ///
    /// **The frame is load-bearing and it is not politeness.** This text goes to
    /// a model whose entire working life is answering a message somebody just
    /// sent, and the failure of leaving it out is not silence — it is an answer
    /// shaped like a reply: *"I'll check now — did you want everything, or just
    /// what's unread?"*, sent to a phone with nobody at the other end to answer
    /// it. Same class as the call briefing, which had to say out loud that it
    /// was already on a call.
    ///
    /// It carries the owner's instruction verbatim underneath, because that is
    /// the request: he wrote it when he set the work up, and nothing here edits
    /// his words on the way in.
    static func transcript(_ instruction: String) -> String {
        """
        [Standing work the owner set up in advance, running now because its time came \
        round. He has not just spoken, and nobody is waiting to answer a question — carry \
        it out and report what you found or did, in one message he will read on his phone.]

        \(instruction)
        """
    }

    /// A phrase made safe to read back, in the house style of
    /// `ProactiveWatch.flattened`: one line, bounded.
    ///
    /// The instruction is the owner's own prose, so this is not the injection
    /// guard the same helper is on a task title. It is the *read-back* guard: a
    /// paragraph pasted in with a newline in it would otherwise put an
    /// unindented block in the middle of a numbered list he is trying to scan.
    static func flattened(_ instruction: String, limit: Int = 200) -> String {
        let oneLine = instruction
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return oneLine.count > limit
            ? String(oneLine.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
            : oneLine
    }
}

// MARK: - Running it

/// Claims what is due and hands it over, once.
///
/// A value with a file in it rather than an actor, because the caller is the
/// watch loop — one sequence of ticks in one process, which never has two of
/// these in flight. What it must not be is *stateless*: the only thing standing
/// between the owner and the same message every sixty seconds is the run time
/// written down here before the work starts.
public struct ScheduledWorkRunner: Sendable {

    private let fileURL: URL
    private let log: @Sendable (String) -> Void

    public init(
        fileURL: URL = ScheduledWork.defaultFileURL(),
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.fileURL = fileURL
        self.log = log
    }

    /// Everything due at `now`, saved as claimed before it is returned.
    ///
    /// A file that cannot be written is not a reason to run nothing: the work is
    /// still returned, and the log says the claim did not land — which is the
    /// one case where the same piece of work can run twice, and a fact worth
    /// having in writing rather than a silence.
    public func claimDue(at now: Date, calendar: Calendar = .current) -> [ScheduledTask] {
        var work = ScheduledWork.load(from: fileURL)
        let claimed = work.claimDue(at: now, calendar: calendar)
        guard !claimed.isEmpty else { return [] }
        do {
            try work.save(to: fileURL)
        } catch {
            log("[schedule] could not record the run time, so this may run again: \(error)")
        }
        return claimed
    }
}
