import Foundation

/// `AgentMessaging` over the node's own MCP tools.
///
/// Thin by intention: every capability here is one the node already publishes
/// and the appliance already carries in its allowlist. What this adds is a
/// typed surface — an unforgeable address, content that resists being rendered
/// as Mynah's own words, and a failure per thing that can go wrong.
public struct SageAgentMessaging: AgentMessaging {

    private let tools: any ToolProviding
    private let journal: AgentSendJournal

    public init(tools: any ToolProviding, journal: AgentSendJournal = AgentSendJournal()) {
        self.tools = tools
        self.journal = journal
    }

    // MARK: Finding

    public func findAgent(named name: String) async throws -> AgentAddress {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AgentMessagingTrouble.noSuchAgent(name: name) }

        let reply: String
        do {
            reply = try await tools.call(name: "sage_find_agent", arguments: ["name": .string(trimmed)])
        } catch {
            throw Self.trouble(from: "\(error)", name: trimmed)
        }

        guard let root = Self.object(in: reply) else {
            throw AgentMessagingTrouble.noSuchAgent(name: trimmed)
        }

        // More than one match is refused rather than guessed at. The prompt
        // rule the model follows says the same thing — "if sage_find_agent
        // finds nobody, say so plainly and do not guess an address" — and a
        // wrong guess here delivers the owner's instructions to the wrong
        // agent, which is worse than an error.
        if let matches = root["matches"] as? [[String: Any]], matches.count > 1 {
            let names = matches.compactMap { $0["name"] as? String }
            throw AgentMessagingTrouble.ambiguousName(name: trimmed, candidates: names)
        }

        let match = (root["matches"] as? [[String: Any]])?.first ?? root
        guard let wire = Self.string(match, "to") ?? Self.string(match, "address") ?? Self.string(match, "agent_id"),
              !wire.isEmpty else {
            throw AgentMessagingTrouble.noSuchAgent(name: trimmed)
        }

        return AgentAddress(
            wire: wire,
            displayName: Self.string(match, "name") ?? trimmed,
            isForeign: (match["foreign"] as? Bool) ?? wire.contains("@")
        )
    }

    // MARK: Sending

    public func send(
        _ message: String,
        to recipient: AgentAddress,
        intent: String?
    ) async throws -> SentAgentMessage {
        // **One key per logical send, written down before the request.**
        //
        // `sage_message_send` requires it and SAGE says what it is for: a retry
        // returns the original `message_id` rather than creating a duplicate,
        // and it is "reused only when retrying this exact send". Fresh per call,
        // never derived from the message text — a content-derived key would make
        // two deliberate sends of the same sentence collide, and the second
        // would report success while nothing arrived. See `AgentSendJournal`.
        let key = AgentSendJournal.newKey()
        journal.starting(key: key, to: recipient.wire, message: message)

        var arguments: [String: JSONValue] = [
            // The resolved wire value, never the display name. `AgentAddress`
            // exists so this cannot accidentally be the thing the owner typed.
            "to": .string(recipient.wire),
            "payload": .string(message),
            "idempotency_key": .string(key)
        ]
        if let intent, !intent.isEmpty { arguments["intent"] = .string(intent) }

        let reply: String
        do {
            // **`sage_message_send`, not `sage_pipe`.** The owner: "message
            // inbox outbox is the official way now". The pipe aliases still
            // work — no 11.17.x removal is scheduled — but they are the older
            // surface, and the messages one is what gets durability: 11.17.7
            // keeps agent messages for 24 hours by default, where a pipe did
            // not.
            reply = try await tools.call(name: "sage_message_send", arguments: arguments)
        } catch {
            // Deliberately left in the journal. The request went out and the
            // answer never came back, so whether it was delivered is genuinely
            // unknown — `sage_message_status` is the way to find out, and it
            // needs a `message_id` this appliance does not have. An entry with
            // no matching id is exactly that state, recorded.
            throw Self.trouble(from: "\(error)", name: recipient.displayName)
        }

        let root = Self.object(in: reply)
        // The node's receipt. Without one nothing was queued, and reporting
        // success would leave the owner waiting for a reply to a message that
        // does not exist.
        //
        // `pipe_id` is still read: a node on the older surface answers with
        // that name, and refusing it would break sending against every 11.17.x
        // before the messages tools landed.
        guard let messageID = root.flatMap({
            Self.string($0, "message_id") ?? Self.string($0, "pipe_id") ?? Self.string($0, "id")
        }) else {
            throw Self.trouble(from: reply, name: recipient.displayName)
        }
        journal.finished(key: key)
        return SentAgentMessage(messageID: messageID, to: recipient, sent: Date())
    }

    // MARK: Reading

    public func inbox(limit: Int) async throws -> [AgentInboxItem] {
        let reply: String
        do {
            // The node caps this at 20; asking for more is not an error there
            // and clamping here keeps the two from disagreeing silently.
            reply = try await tools.call(
                name: "sage_inbox",
                arguments: ["limit": .int(max(1, min(limit, 20)))]
            )
        } catch {
            throw Self.trouble(from: "\(error)", name: "your agents")
        }

        guard let root = Self.object(in: reply),
              let items = root["items"] as? [[String: Any]] else {
            // An empty inbox and an unparseable one are the same to a screen
            // that has nothing to show. A thrown error here would put a red
            // banner on a page whose honest state is "nothing yet".
            return []
        }
        return items.compactMap(Self.item(from:))
    }

    // MARK: Shapes

    static func item(from raw: [String: Any]) -> AgentInboxItem? {
        guard let id = string(raw, "message_id") ?? string(raw, "pipe_id") ?? string(raw, "id") else { return nil }
        let sender = string(raw, "from") ?? string(raw, "from_network") ?? "another agent"

        // Trust is read from the node rather than inferred. `foreign` and the
        // explicit `trust` field can both be present; the stronger of the two
        // wins, because weakening a trust label is the one direction that
        // cannot be recovered from downstream.
        let declared = string(raw, "trust")
        let isForeign = (raw["foreign"] as? Bool) ?? false
        let trust: UntrustedAgentContent.Trust =
            (declared == "external_untrusted" || isForeign) ? .anotherSageEntirely : .anotherAgentHere

        return AgentInboxItem(
            id: id,
            content: UntrustedAgentContent(
                sender: sender,
                trust: trust,
                body: string(raw, "payload") ?? string(raw, "content") ?? ""
            ),
            intent: string(raw, "intent"),
            arrived: (string(raw, "created_at")).flatMap(ISO8601DateFormatter().date(from:)),
            expectsAResult: (raw["requires_result"] as? Bool) ?? false
        )
    }

    /// Turns whatever the node said into the failure the owner can act on.
    ///
    /// Matching on text, and the reason is the same as for write denials:
    /// `ToolProviding.call` returns a `String`, so a failure arrives as prose
    /// whatever the node meant by it. Unrecognised text becomes `.refused` with
    /// the node's own words attached rather than a sentence we invented.
    static func trouble(from message: String, name: String) -> AgentMessagingTrouble {
        let lowered = message.lowercased()
        if lowered.contains("no agent") || lowered.contains("not found")
            || lowered.contains("unknown agent") || lowered.contains("no match") {
            return .noSuchAgent(name: name)
        }
        if lowered.contains("paused") || lowered.contains("offline")
            || lowered.contains("unavailable") || lowered.contains("not accepting")
            || lowered.contains("stale") {
            return .unreachable(name: name, why: condensed(message))
        }
        if lowered.contains("connection refused") || lowered.contains("could not connect")
            || lowered.contains("no such file") || lowered.contains("not running") {
            return .nodeUnavailable
        }
        return .refused(condensed(message))
    }

    private static func condensed(_ text: String) -> String {
        let flat = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count <= 200 ? flat : String(flat.prefix(200)) + "…"
    }

    /// **Was `JSONSerialization` over the whole reply, and that silently emptied
    /// this owner's inbox.** The node appends a `[SAGE] Reminder: …` line after
    /// the JSON every few calls, trailing bytes make the parse fail, and the
    /// failure lands in the branch that returns `[]` — so an inbox with
    /// messages in it reported as clear, intermittently, for as long as this
    /// has shipped. See `SageReply`.
    static func object(in reply: String) -> [String: Any]? {
        SageReply.object(in: reply)
    }

    private static func string(_ object: [String: Any], _ key: String) -> String? {
        guard let value = object[key] as? String, !value.isEmpty else { return nil }
        return value
    }
}
