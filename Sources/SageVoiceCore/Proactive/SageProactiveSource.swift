import Foundation

/// What the appliance can see on its own node.
///
/// Two calls, both of which the owner's agent already makes when asked — this
/// adds no capability, only a clock. That distinction is the whole safety
/// argument for the feature: nothing here can reach anything a conversation
/// could not already reach.
public struct SageProactiveSource: ProactiveSource {

    private let tools: any ToolProviding

    public init(tools: any ToolProviding) {
        self.tools = tools
    }

    public func waitingMessages(limit: Int) async throws -> [AgentInboxItem] {
        try await SageAgentMessaging(tools: tools).inbox(limit: limit)
    }

    public func openTasks() async throws -> [WatchedTask] {
        let reply = try await tools.call(name: "sage_backlog", arguments: [:])
        return Self.tasks(inBacklog: reply)
    }

    /// Reads `sage_backlog`'s answer.
    ///
    /// Shape, from the node: `{"tasks_by_domain": {"<domain>": [{"memory_id":…,
    /// "content":"[TASK] …", "task_status":"planned"}]}}`. Domains are not kept
    /// — the owner does not think in domains, and a message that named them
    /// would be the appliance describing its own filing system.
    ///
    /// Anything unparseable becomes an empty list rather than an error. A check
    /// nobody asked for must not put a failure on the owner's phone, and a
    /// backlog this cannot read is indistinguishable from an empty one for the
    /// purpose of "has anything changed".
    static func tasks(inBacklog reply: String) -> [WatchedTask] {
        // Through `SageReply`, because the node appends prose after the JSON
        // every few calls and parsing the whole string fails on it. That is not
        // a hypothetical: it is why this returned nothing against a node
        // answering "You have 3 assigned open tasks".
        guard let root = SageReply.object(in: reply),
              let byDomain = root["tasks_by_domain"] as? [String: Any] else {
            return []
        }
        var found: [WatchedTask] = []
        // Sorted, so two checks that saw the same backlog produce the same
        // order — a message whose lines shuffle between checks reads as more
        // having happened than did.
        for domain in byDomain.keys.sorted() {
            guard let rows = byDomain[domain] as? [[String: Any]] else { continue }
            for row in rows {
                guard let id = row["memory_id"] as? String,
                      let content = row["content"] as? String else { continue }
                found.append(WatchedTask(
                    id: id,
                    title: Self.title(from: content),
                    status: (row["task_status"] as? String) ?? "planned"
                ))
            }
        }
        return found.sorted { $0.id < $1.id }
    }

    /// `[TASK] Send car for servicing on Tuesday` is how the node stores it and
    /// not how anybody says it.
    static func title(from content: String) -> String {
        var text = content.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("[TASK]") {
            text = String(text.dropFirst("[TASK]".count))
        }
        return text.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - When to look

/// Whether a check is due.
///
/// Separated from the loop that runs it so the rule can be tested without
/// waiting an hour, and so the loop stays what it should be: sleep, ask, act.
public enum ProactiveSchedule {

    /// How often the loop wakes to ask this question. Not how often it checks —
    /// the owner sets that — but the granularity at which their setting takes
    /// effect, including switching the whole thing off.
    public static let tick: TimeInterval = 60

    public static func isDue(
        now: Date,
        lastChecked: Date?,
        preferences: ProactivePreferences,
        calendar: Calendar = .current
    ) -> Bool {
        guard preferences.isOn else { return false }
        // Asleep. Nothing is lost — the ledger is untouched, so whatever
        // arrives overnight is still new in the morning.
        guard !preferences.isQuiet(at: now, calendar: calendar) else { return false }
        guard let lastChecked else { return true }
        let elapsed = now.timeIntervalSince(lastChecked)
        // A negative interval means the Mac's clock went backwards, which would
        // otherwise stop the appliance checking until real time caught up.
        return elapsed >= Double(preferences.clampedMinutes) * 60 || elapsed < 0
    }
}
