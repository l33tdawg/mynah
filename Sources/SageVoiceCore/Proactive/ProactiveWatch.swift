import Foundation

// MARK: - What a check can find

/// One task on the appliance's own list, as a check sees it.
public struct WatchedTask: Sendable, Equatable, Codable {
    public let id: String
    public let title: String
    public let status: String

    public init(id: String, title: String, status: String) {
        self.id = id
        self.title = title
        self.status = status
    }
}

/// What the appliance looks at when it checks on things by itself.
///
/// Narrow on purpose. A protocol that could reach anything would eventually
/// reach something the owner did not agree to be told about unprompted.
public protocol ProactiveSource: Sendable {
    /// Messages from the owner's other agents.
    func waitingMessages(limit: Int) async throws -> [AgentInboxItem]
    /// The appliance's own open tasks.
    func openTasks() async throws -> [WatchedTask]
}

// MARK: - What it has already said

/// What the last check saw, so this one can tell what is new.
///
/// **The whole feature lives or dies here.** An appliance that reports the same
/// four open tasks every hour is not proactive, it is a nag, and the owner
/// switches it off within a day. Nothing is said twice because everything said
/// once is written down.
public struct ProactiveLedger: Sendable, Equatable, Codable {

    /// Inbox items already reported. Ids only — the messages themselves are the
    /// node's to keep.
    public var toldAboutMessages: Set<String>

    /// Task id to the status it was in when last reported.
    public var knownTasks: [String: String]

    /// Task id to its title, so a task that *leaves* the list can be named.
    ///
    /// **Kept separately from `knownTasks` on purpose.** Folding them into one
    /// dictionary of a richer type would make an older build's ledger fail to
    /// decode under a key it already uses, and a ledger that fails to decode is
    /// a ledger that re-seeds — silent for one tick, then fine, but for no
    /// reason. A second key simply arrives empty on the first upgrade, which
    /// costs at most one unnamed removal.
    public var knownTaskTitles: [String: String]

    /// When the last check ran, whatever it found.
    ///
    /// Set on every attempt rather than every report, for the reason
    /// `UpdatePreferences.lastCheckedAt` is: this bounds how often the
    /// appliance asks its node, not how often it has something to say.
    public var lastCheckedAt: Date?

    /// Whether a first check has ever completed.
    ///
    /// The first one says nothing at all, and that is deliberate: the ledger is
    /// empty, so everything already on the list would read as having "just
    /// happened" — four tasks and a fortnight of inbox arriving in one message
    /// the moment the owner flicks the switch. What this feature is for is what
    /// changes *from now on*.
    public var hasSeeded: Bool

    /// Reminder rungs already delivered. See `ReminderLadder.Nudge.key`.
    public var saidReminders: Set<String>

    /// The open tasks as of the last check that actually reached the node.
    ///
    /// **Cached so reminders can be punctual without being expensive.** The
    /// owner set the check interval to fifteen minutes, and a rung that fires on
    /// a fifteen-minute grid cannot honestly say "in about half an hour". But
    /// the *dates* do not change between checks — only the clock moves. So the
    /// ladder is evaluated against this every tick, a minute apart, while the
    /// node is still only asked as often as he chose.
    ///
    /// Kept out of `knownTasks`, which stores statuses for a different question.
    public var lastSeenTasks: [WatchedTask]

    public init(
        toldAboutMessages: Set<String> = [],
        knownTasks: [String: String] = [:],
        knownTaskTitles: [String: String] = [:],
        lastCheckedAt: Date? = nil,
        hasSeeded: Bool = false,
        saidReminders: Set<String> = [],
        lastSeenTasks: [WatchedTask] = []
    ) {
        self.toldAboutMessages = toldAboutMessages
        self.knownTasks = knownTasks
        self.knownTaskTitles = knownTaskTitles
        self.lastCheckedAt = lastCheckedAt
        self.hasSeeded = hasSeeded
        self.saidReminders = saidReminders
        self.lastSeenTasks = lastSeenTasks
    }

    // Every field decodes as empty from a ledger written by an older build,
    // which is the correct upgrade: no reminder is "already said" on a Mac that
    // has never had reminders, and the first check refills the task cache.
    enum CodingKeys: String, CodingKey {
        case toldAboutMessages, knownTasks, knownTaskTitles
        case lastCheckedAt, hasSeeded, saidReminders, lastSeenTasks
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        toldAboutMessages = try container.decodeIfPresent(Set<String>.self, forKey: .toldAboutMessages) ?? []
        knownTasks = try container.decodeIfPresent([String: String].self, forKey: .knownTasks) ?? [:]
        knownTaskTitles = try container.decodeIfPresent([String: String].self, forKey: .knownTaskTitles) ?? [:]
        lastCheckedAt = try container.decodeIfPresent(Date.self, forKey: .lastCheckedAt)
        hasSeeded = try container.decodeIfPresent(Bool.self, forKey: .hasSeeded) ?? false
        saidReminders = try container.decodeIfPresent(Set<String>.self, forKey: .saidReminders) ?? []
        lastSeenTasks = try container.decodeIfPresent([WatchedTask].self, forKey: .lastSeenTasks) ?? []
    }

    /// Bounded, because this file is written forever and an appliance that runs
    /// for a year should not carry every pipe id it ever saw. Only ids still
    /// present in the inbox are worth keeping — an item the node has dropped
    /// cannot arrive again.
    public mutating func forgetMessagesNotIn(_ present: Set<String>) {
        toldAboutMessages.formIntersection(present)
    }

    public static func defaultFileURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/SAGE Voice Bridge", isDirectory: true)
            .appendingPathComponent("proactive-ledger.json", isDirectory: false)
    }

    public static func load(from url: URL = ProactiveLedger.defaultFileURL()) -> ProactiveLedger {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(ProactiveLedger.self, from: data) else {
            return ProactiveLedger()
        }
        return stored
    }

    public func save(to url: URL = ProactiveLedger.defaultFileURL()) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try OwnerOnlyFileSecurity.write(encoder.encode(self), to: url)
    }
}

// MARK: - What one check decided

/// The outcome of a single look, kept as a value so it can be tested without a
/// clock, a node or a phone.
public struct ProactiveReport: Sendable, Equatable {
    /// What to send, or `nil` when there is nothing worth saying — which is
    /// most checks, and is the point.
    public let message: String?
    public let ledger: ProactiveLedger

    /// The open tasks this check actually read, or `nil` when the node could
    /// not be asked.
    ///
    /// **Carried out separately from `ledger.lastSeenTasks`, which cannot answer
    /// the question.** That field deliberately keeps its old contents when a
    /// check fails, so "the node said nothing is dated any more" and "the node
    /// did not answer" look identical in it. The calendar mirror has to tell
    /// those apart: read as an empty list, an unreachable node would mean every
    /// dated task had just been finished, and the mirror would delete the
    /// owner's calendar entries.
    public let sawTasks: [WatchedTask]?

    /// Whether `message` carries words written by something other than Mynah.
    ///
    /// Task news is Mynah's own observation of the owner's own list. An inbox
    /// excerpt is another agent's prose, quoted. Those go to the same phone and
    /// must not go into the model's history the same way — see
    /// `VoiceBridgeDaemon.announce(_:to:quotingAnotherAgent:)`.
    public let relaysAnotherAgent: Bool

    public init(
        message: String?,
        ledger: ProactiveLedger,
        sawTasks: [WatchedTask]? = nil,
        relaysAnotherAgent: Bool = false
    ) {
        self.message = message
        self.ledger = ledger
        self.sawTasks = sawTasks
        self.relaysAnotherAgent = relaysAnotherAgent
    }
}

// MARK: - Checking without being asked

/// Looks at the inbox and the task list on a timer, and speaks only when
/// something has changed.
///
/// **This contradicts a note on `AgentMessaging`, and deliberately.** That type
/// says there is no polling, because a *window* polling a node that may refuse
/// is a retry storm somebody generates by leaving an app open. This is not a
/// window: it runs at an interval the owner chose, in the process that already
/// holds the Signal connection, and it stops entirely when they switch it off.
///
/// Three rules hold the whole design together:
///
/// 1. **Nothing is said twice.** Everything reported goes in the ledger.
/// 2. **The first check is silent.** It writes down what already exists so that
///    what follows is genuinely new.
/// 3. **Nothing is invented.** The message names what changed and stops; it
///    does not ask the model to have an opinion about it, which would cost a
///    turn on every check and could hallucinate on any of them.
public struct ProactiveWatch: Sendable {

    /// How much of another agent's message travels unprompted.
    ///
    /// Attributed and short. This text was written by something that is not
    /// Mynah — `UntrustedAgentContent` exists to keep that fact attached — and
    /// an unbounded relay would let an agent elsewhere push whatever it liked
    /// into the owner's Signal thread. Enough to know whether to go and read it
    /// is the right amount.
    public static let excerptCharacters = 160

    /// Items named in one message before it stops counting.
    public static let mostItemsNamed = 4

    private let source: any ProactiveSource

    public init(source: any ProactiveSource) {
        self.source = source
    }

    /// One check.
    ///
    /// Never throws. A node that is asleep, restarting or refusing is an
    /// ordinary state for a machine that runs all year, and a check that failed
    /// is simply a check that found nothing to say — it must not take the
    /// appliance down or produce an error message on the owner's phone.
    /// - Parameter announcingTaskChanges: `false` absorbs whatever the task
    ///   list has done since the last check without saying a word about it.
    ///
    ///   Set when the owner has just changed the list himself, which is the bug
    ///   he caught: he asked Mynah to move a deadline, Mynah confirmed it in
    ///   prose — *"I've replaced the old open-ended TDAC task with this one"* —
    ///   and then a second message reported the same edit back to him as news,
    ///   twice over, because a replacement is one arrival and one departure.
    ///
    ///   His own words for what these messages are for: *"the tasks coming on
    ///   and off the lists"*. A change he made thirty seconds ago is not one of
    ///   them. Inbox news is unaffected — a message from another agent is still
    ///   news whatever he was just doing.
    public func check(
        against ledger: ProactiveLedger,
        announcingTaskChanges: Bool = true,
        now: Date = Date(),
        calendar: Calendar = .current
    ) async -> ProactiveReport {
        // **`?? []` was the bug, and it was worse than silence.**
        //
        // A node that refuses used to be coalesced to an empty list, which is
        // not "nothing is there" — it is "I could not look", and the two are
        // opposite. Read as an empty backlog it meant every task the owner has
        // had just been completed, so the check announced *"A task came off the
        // list."* once per task and then overwrote the ledger with the empty
        // result. The next healthy tick, having forgotten everything, announced
        // the entire backlog and inbox again as new.
        //
        // Not hypothetical on this Mac. `sage_backlog failed: … connect:
        // connection refused` appears six times in one day in the owner's log,
        // and he has just set the interval to fifteen minutes.
        //
        // Nil, not empty, and the two halves fail independently: a reachable
        // inbox is still worth reporting when the backlog is down.
        let messages = try? await source.waitingMessages(limit: 20)
        let tasks = try? await source.openTasks()

        var updated = ledger

        // Every mutation below is guarded by "did we actually see it". The rule
        // this preserves is the one in the doc comment above — a failed check
        // says nothing — plus the one it was missing: a failed check must not
        // *forget* anything either.
        if let messages {
            updated.forgetMessagesNotIn(Set(messages.map(\.id)))
            updated.toldAboutMessages.formUnion(messages.map(\.id))
        }
        if let tasks {
            updated.knownTasks = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.status) })
            updated.knownTaskTitles = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.title) })
            // Refilled only on a check that actually read the node, for the same
            // reason as everything else in this block: a refusal must not empty
            // the cache, or the ladder would go quiet until the node came back.
            updated.lastSeenTasks = tasks
            updated.saidReminders = ReminderLadder.keysWorthKeeping(updated.saidReminders, tasks: tasks)
        }

        let newMessages = (messages ?? []).filter { !ledger.toldAboutMessages.contains($0.id) }
        // Absorbed above and unsaid here: the ledger is now current, so the next
        // check compares against the truth and this one carries nothing.
        let taskNews = announcingTaskChanges ? tasks.map {
            Self.taskNews(
                $0,
                against: ledger.knownTasks,
                titles: ledger.knownTaskTitles,
                seeded: ledger.hasSeeded,
                now: now,
                calendar: calendar
            )
        } ?? [] : []

        // The silent first pass. Everything above is written down; nothing is
        // said.
        //
        // Only counts as seeded once something was actually read. Seeding on a
        // check that reached nothing would mark a ledger "primed" against an
        // empty picture, and the *next* check would then report the owner's
        // whole backlog as newly arrived — which is the same fault as the one
        // above, arriving one tick later.
        guard ledger.hasSeeded else {
            updated.hasSeeded = messages != nil || tasks != nil
            return ProactiveReport(message: nil, ledger: updated, sawTasks: tasks)
        }

        let lines = newMessages.map(Self.line(forMessage:)) + taskNews
        guard !lines.isEmpty else {
            return ProactiveReport(message: nil, ledger: updated, sawTasks: tasks)
        }
        return ProactiveReport(
            message: Self.message(from: lines),
            ledger: updated,
            sawTasks: tasks,
// Task news is Mynah's own reading of the owner's own list. An inbox
            // line quotes an agent that is not Mynah, so the message as a whole
            // is a relay and has to be stored as one.
            //
            // **Deliberately still per-digest, after the 1.7.2 audit argued for
            // marking task news too.** It is right that a title can be written
            // by another agent — `sage_inbox` describes one-way task assignment
            // notices and `sage_backlog` returns what is assigned to this agent.
            // But marking every task digest as somebody else's words is the
            // worse error: it tells the model that the owner's own list is not
            // Mynah's business, on the surface whose whole job is his list. The
            // injection risk is answered where it lives, by not letting a title
            // forge structure — see `ending(_:)`.
            relaysAnotherAgent: !newMessages.isEmpty
        )
    }

    // MARK: What changed

    /// Added, moved and finished — in that order, because that is the order
    /// somebody cares about them.
    ///
    /// A task the appliance has never seen before is only news once it has been
    /// seeded; on an unseeded ledger every task is "new" and none of it is.
    static func taskNews(
        _ tasks: [WatchedTask],
        against known: [String: String],
        titles: [String: String] = [:],
        seeded: Bool,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [String] {
        guard seeded else { return [] }
        var lines: [String] = []

        for task in tasks where known[task.id] == nil {
            lines.append("A new task landed: “\(ending(task.title))”")
        }
        for task in tasks {
            guard let before = known[task.id], before != task.status else { continue }
            // Flattened like the other two. This line was left raw, which made
            // the claim beside `relaysAnotherAgent` — that the injection risk is
            // answered by not letting a title forge structure — false for a
            // third of the digest.
            lines.append("“\(flattened(task.title))” is now \(readable(task.status)).")
        }
        // Gone from the open list, which on this node means finished or dropped.
        // Which of the two is not knowable from an absence, so it does not claim
        // to know.
        //
        // ## Why almost all of these are now silent
        //
        // The owner, on being told *"“Call with TII IT at 18:00 on Monday 3
        // August 2026.” came off the list."* on the Tuesday morning: *"obviously
        // things from yesterday should come off the list — added, yes, removed I
        // think not meaningful?"*
        //
        // He is right, and the reason is the sentence three paragraphs up: this
        // line **cannot say why**. Finished, dropped, lapsed, and asked-for all
        // render identically, so the only thing it can communicate is that
        // something happened — and every cause he will actually meet is one he
        // already knows about, because he caused it.
        //
        // One cause is not: a task that leaves while nobody is touching it.
        // Decay on the node, another agent, a governance action. A task list that
        // quietly loses things is the worst thing a task list can be, and that
        // case was drowning in the noise of the others.
        //
        // So a departure has to be *unexplained* to be worth a sentence. Past its
        // date is explained — the moment has gone, and the ladder has already
        // asked him about it once a day since. Anything else is not.
        let present = Set(tasks.map(\.id))
        for (id, _) in known.sorted(by: { $0.key < $1.key }) where !present.contains(id) {
            // An unknown title is silent rather than generic. It happens for one
            // tick after upgrading from a build that never wrote the titles
            // dictionary, and the generic version — "A task came off the list."
            // — is the one he read twice in a row and correctly called useless.
            guard let title = titles[id] else { continue }
            guard ReminderLadder.lapseTime(of: title, calendar: calendar).map({ $0 > now }) ?? true
            else { continue }
            lines.append("“\(ending(title))” came off the list, and nothing here took it off.")
        }
        return lines
    }

    /// A task's own words, ending in a full stop exactly once.
    ///
    /// The owner writes these by speaking, so some end in a stop and some do
    /// not — and `“…the TBCERT event.”.` is the sort of detail that makes a
    /// message read as assembled rather than written.
    static func ending(_ title: String) -> String {
        // **Flattened and bounded, because a task title is not always the
        // owner's prose.**
        //
        // `sage_inbox` describes agents sending one-way task assignment notices
        // and `sage_backlog` returns what is assigned to *this* agent, so a
        // title can be written by something other than Mynah or its owner — and
        // `taskNews` interpolates it straight into a message that goes to his
        // phone and into the model's context.
        //
        // `excerpt(_:)` has flattened and truncated inbox text since it was
        // written, for exactly this reason. This did neither, so a multi-line
        // title forged extra paragraphs in the digest and an unbounded one could
        // fill it. The same treatment, applied to the other thing an agent can
        // write. Found by the 1.7.2 re-audit.
        //
        // Not framed as a relay, though: see `relaysAnotherAgent`. Telling the
        // model that the owner's own list is somebody else's words is the worse
        // error, so the answer is to stop a title forging structure rather than
        // to mislabel the digest that carries it.
        let bounded = flattened(title)
        guard let last = bounded.last else { return "" }
        return ".!?…".contains(last) ? bounded : bounded + "."
    }

    /// A title made safe to interpolate, without being made into a sentence.
    ///
    /// Split out from `ending(_:)` because the status-change line supplies its
    /// own full stop — `“\(x)” is now planned.` — so running the sentence-ender
    /// over it produced `“Book the hotel.” is now planned.` Flattening and
    /// bounding are what every line needs; the full stop is what only two of
    /// them need.
    static func flattened(_ title: String) -> String {
        let oneLine = title
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return oneLine.count > excerptCharacters
            ? String(oneLine.prefix(excerptCharacters)).trimmingCharacters(in: .whitespaces) + "…"
            : oneLine
    }

    static func readable(_ status: String) -> String {
        switch status.lowercased() {
        case "in_progress", "in progress": return "in progress"
        case "planned": return "planned"
        case "blocked": return "blocked"
        case "done", "completed": return "done"
        default: return status
        }
    }

    static func line(forMessage item: AgentInboxItem) -> String {
        let excerpt = Self.excerpt(item.content.read())
        let opening = item.expectsAResult
            ? "\(item.content.sender) sent work"
            : "\(item.content.sender) sent a message"
        let about = item.intent.map { " (\($0))" } ?? ""
        guard !excerpt.isEmpty else { return "\(opening)\(about)." }
        return "\(opening)\(about): “\(excerpt)”"
    }

    static func excerpt(_ body: String) -> String {
        let flat = body
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > Self.excerptCharacters else { return flat }
        return flat.prefix(Self.excerptCharacters).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// One message, however many things happened.
    ///
    /// Not one per item: four notifications arriving at once is the behaviour
    /// that makes people mute a thread, and the appliance shares a thread with
    /// the owner's own notes.
    static func message(from lines: [String]) -> String {
        let named = lines.prefix(Self.mostItemsNamed)
        var body = named.joined(separator: "\n\n")
        let remainder = lines.count - named.count
        if remainder > 0 {
            body += "\n\n…and \(remainder) more. Ask me and I'll go through them."
        }
        return body
    }
}
