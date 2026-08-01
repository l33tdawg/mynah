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

    public init(
        toldAboutMessages: Set<String> = [],
        knownTasks: [String: String] = [:],
        lastCheckedAt: Date? = nil,
        hasSeeded: Bool = false
    ) {
        self.toldAboutMessages = toldAboutMessages
        self.knownTasks = knownTasks
        self.lastCheckedAt = lastCheckedAt
        self.hasSeeded = hasSeeded
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
    public func check(against ledger: ProactiveLedger) async -> ProactiveReport {
        let messages = (try? await source.waitingMessages(limit: 20)) ?? []
        let tasks = (try? await source.openTasks()) ?? []

        var updated = ledger
        updated.forgetMessagesNotIn(Set(messages.map(\.id)))

        let newMessages = messages.filter { !ledger.toldAboutMessages.contains($0.id) }
        let taskNews = Self.taskNews(tasks, against: ledger.knownTasks, seeded: ledger.hasSeeded)

        updated.toldAboutMessages.formUnion(messages.map(\.id))
        updated.knownTasks = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.status) })

        // The silent first pass. Everything above is written down; nothing is
        // said.
        guard ledger.hasSeeded else {
            updated.hasSeeded = true
            return ProactiveReport(message: nil, ledger: updated)
        }

        let lines = newMessages.map(Self.line(forMessage:)) + taskNews
        guard !lines.isEmpty else {
            return ProactiveReport(message: nil, ledger: updated)
        }
        return ProactiveReport(message: Self.message(from: lines), ledger: updated)
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
        seeded: Bool
    ) -> [String] {
        guard seeded else { return [] }
        var lines: [String] = []

        for task in tasks where known[task.id] == nil {
            lines.append("A new task landed: “\(task.title)”.")
        }
        for task in tasks {
            guard let before = known[task.id], before != task.status else { continue }
            lines.append("“\(task.title)” is now \(readable(task.status)).")
        }
        // Gone from the open list, which on this node means finished or
        // dropped. Which of the two is not knowable from an absence, so it does
        // not claim to know.
        let present = Set(tasks.map(\.id))
        for (id, _) in known where !present.contains(id) {
            _ = id
            lines.append("A task came off the list.")
        }
        return lines
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
