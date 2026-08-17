import Foundation

/// What the appliance can see on its own node.
///
/// Two calls, both of which the owner's agent already makes when asked — this
/// adds no capability, only a clock. That distinction is the whole safety
/// argument for the feature: nothing here can reach anything a conversation
/// could not already reach.
public struct SageProactiveSource: ProactiveSource {

    private let tools: any ToolProviding
    private let log: @Sendable (String) -> Void

    public init(tools: any ToolProviding, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.tools = tools
        self.log = log
    }

    /// What went wrong, when the node answered but not with a backlog.
    public enum Trouble: Error, Equatable {
        /// The reply parsed as neither a backlog nor an empty one.
        case unreadableBacklog(String)
    }

    /// `ProactiveWatch`'s lines about a check that used this source, into the
    /// same sink as the two below.
    ///
    /// **This one method is what makes the watch's logging real rather than
    /// declared.** The daemon already builds this type with `log: { note($0) }`
    /// (`sage-voiced/main.swift`), so implementing the protocol's `note` here
    /// puts "inbox: 3 waiting" and "inbox: could not read — …" into
    /// `bridge.log` without a line changing in the daemon. The default
    /// implementation on `ProactiveSource` is silence, which is right for a
    /// stub and would have been a fix that shipped doing nothing had it been
    /// left in place here.
    public func note(_ line: String) {
        log(line)
    }

    /// The inbox, with the same nil-versus-empty rule as `openTasks`.
    ///
    /// Items only, for the callers that want nothing else. Same single read as
    /// `waitingInbox`, and the reasoning for both is on `read(limit:)`.
    public func waitingMessages(limit: Int) async throws -> [AgentInboxItem] {
        try await read(limit: limit).items
    }

    /// The same read, with the scalar the node reports beside the items.
    ///
    /// **Implemented here rather than left to the protocol's default, because
    /// the default is what a fix that ships inert looks like.** It answers
    /// `.notReported`, which is honest for a stub and false for this type: the
    /// node does report it, `SageAgentMessaging.inboxRead` does parse it, and
    /// this is the one source the daemon actually runs — `SageProactiveSource(
    /// tools: mcp, log: { note($0) })` in `sage-voiced/main.swift`. Without
    /// this override the whole chain would compile, log "0 waiting" forever,
    /// and reproduce 17 August exactly.
    public func waitingInbox(limit: Int) async throws -> AgentInboxRead {
        try await read(limit: limit)
    }

    /// One `sage_inbox` call, shared by both of the above.
    ///
    /// **Not `waitingMessages` calling `waitingInbox` or the reverse.** The
    /// protocol's default implements `waitingInbox` *in terms of*
    /// `waitingMessages`, so a delegation in that direction here would become
    /// unbounded recursion the day somebody deletes the override — a crash the
    /// compiler cannot see. A private third method makes that shape
    /// impossible.
    ///
    /// **And it must stay one call.** `sage_inbox` atomically claims the rows
    /// it returns under the caller's session, with no expiry, so reading twice
    /// to fill in two return types would strand the second read's answer under
    /// a claim — the defect this same patch removes from `sage-voiced check`.
    ///
    /// Only the unreadable case is logged *here*, and the reason has changed.
    /// It used to be that "a node that is simply down already says so through
    /// `MCPClient`" — which was never true of this path. `MCPClient` throws a
    /// `MCPClientError` and logs nothing; the throw came through here, `try?`
    /// in `ProactiveWatch` dropped it, and 17 August's `bridge.log` has the
    /// proof: 105 checks, zero inbox lines of any kind.
    ///
    /// Every failure is logged now — by `ProactiveWatch.check`, one layer up,
    /// where the decision to stay quiet is actually taken and where *every*
    /// error passes rather than the one case this method can name. So this line
    /// stays what it always was and does not become a catch-all: the reply the
    /// node actually sent, which is the detail the outer line cannot carry and
    /// which nothing else records. The two together read as cause then
    /// consequence for this one case; every other failure gets the outer line
    /// alone, where before it got nothing.
    private func read(limit: Int) async throws -> AgentInboxRead {
        do {
            return try await SageAgentMessaging(tools: tools).inboxRead(limit: limit)
        } catch AgentMessagingTrouble.unreadableInbox(let reply) {
            log("[watch] sage_inbox answered with something that is not an inbox, so this "
                + "check changed nothing: \(Self.head(of: reply))")
            throw AgentMessagingTrouble.unreadableInbox(reply)
        }
    }

    /// **Throws rather than manufacturing an empty backlog, and that is the
    /// whole of this.**
    ///
    /// On 6 August 2026 the owner restarted his SAGE node, and eleven of his
    /// calendar events were deleted and re-created thirty-two minutes later. He
    /// read it right: *"seems like our app problem not a sage problem"*.
    ///
    /// `CalendarSync.run(tasks:)` takes an optional and its doc comment calls
    /// the nil-versus-empty distinction "the whole safety property" — an
    /// unreachable node changes nothing. `ProactiveWatch` feeds it `try? await
    /// source.openTasks()`, which is correct for a *throw*. But `tasks(inBacklog:)`
    /// used to turn any reply it could not read into `[]`, so a node answering
    /// something other than a backlog produced a successful empty list, `try?`
    /// saw no error, and the calendar was told every dated task had just been
    /// completed. The safety property was built carefully at the bottom and
    /// defeated one layer above it.
    ///
    /// Its old justification is quoted here because it was reasonable when it
    /// was written: *"a backlog this cannot read is indistinguishable from an
    /// empty one for the purpose of 'has anything changed'"*. True while the
    /// only consumer was the digest, where the cost is one quiet tick. It
    /// stopped being true when the calendar started reading the same value, and
    /// nothing revisited the sentence — the same twin-consumer drift that put
    /// `send_file` on a call and left `isPaused` replacing the composer.
    ///
    /// An empty `tasks_by_domain` is still an empty backlog and still returns
    /// `[]`: the owner finishing everything is a real state and must not read as
    /// a fault.
    public func openTasks() async throws -> [WatchedTask] {
        let reply = try await tools.call(name: "sage_backlog", arguments: [:])
        guard let tasks = Self.tasks(inBacklog: reply) else {
            // **The line that was missing on 6 August.** The calendar emptied
            // itself and the log said only "mirroring 0 dated task(s)", which is
            // a true statement about the plan and says nothing about why. The
            // reply is what makes the next one diagnosable rather than guessed
            // at, so a bounded head of it goes in the log verbatim.
            log("[watch] sage_backlog answered with something that is not a backlog, so this "
                + "check changed nothing: \(Self.head(of: reply))")
            throw Trouble.unreadableBacklog(Self.head(of: reply))
        }
        return tasks
    }

    /// Enough of a reply to recognise it, and not enough to fill the log.
    ///
    /// Newlines flattened because this shares a log with lines that are read by
    /// eye, and a JSON blob across forty lines buries whatever came next.
    static func head(of reply: String, limit: Int = 300) -> String {
        let flat = reply
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit)) + "…"
    }

    /// Reads `sage_backlog`'s answer.
    ///
    /// Shape, from the node: `{"tasks_by_domain": {"<domain>": [{"memory_id":…,
    /// "content":"[TASK] …", "task_status":"planned"}]}}`. Domains are not kept
    /// — the owner does not think in domains, and a message that named them
    /// would be the appliance describing its own filing system.
    ///
    /// `nil` when the reply is not a backlog at all — see `openTasks`. An empty
    /// list means the node was read and the owner has nothing dated, which is an
    /// ordinary state and must stay distinguishable from a failure.
    static func tasks(inBacklog reply: String) -> [WatchedTask]? {
        // Through `SageReply`, because the node appends prose after the JSON
        // every few calls and parsing the whole string fails on it. That is not
        // a hypothetical: it is why this returned nothing against a node
        // answering "You have 3 assigned open tasks".
        guard let root = SageReply.object(in: reply),
              let byDomain = root["tasks_by_domain"] as? [String: Any] else {
            return nil
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

    /// - Parameter wokenByMessage: the message wake bus says work was durably
    ///   inserted for this appliance. See `MessageWakeBus`.
    ///
    ///   **It skips the interval and nothing else.** The owner's switch and
    ///   their quiet hours are above it deliberately: the appliance being told
    ///   promptly is worth having, and it is worth exactly nothing if the price
    ///   is a phone lighting up at 3am because another agent answered something.
    ///   Nothing is lost by holding it — the latch is not cleared by a tick that
    ///   declines, so the wake survives until morning and is acted on then.
    public static func isDue(
        now: Date,
        lastChecked: Date?,
        preferences: ProactivePreferences,
        calendar: Calendar = .current,
        wokenByMessage: Bool = false
    ) -> Bool {
        guard preferences.isOn else { return false }
        // Asleep. Nothing is lost — the ledger is untouched, so whatever
        // arrives overnight is still new in the morning.
        guard !preferences.isQuiet(at: now, calendar: calendar) else { return false }
        if wokenByMessage { return true }
        guard let lastChecked else { return true }
        let elapsed = now.timeIntervalSince(lastChecked)
        // A negative interval means the Mac's clock went backwards, which would
        // otherwise stop the appliance checking until real time caught up.
        return elapsed >= Double(preferences.clampedMinutes) * 60 || elapsed < 0
    }
}
