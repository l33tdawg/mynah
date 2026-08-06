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
        intent: String?,
        retrying resumed: String?
    ) async throws -> SentAgentMessage {
        // **One key per logical send, written down before the request.**
        //
        // `sage_message_send` requires it and SAGE says what it is for: a retry
        // returns the original `message_id` rather than creating a duplicate,
        // and it is "reused only when retrying this exact send". Fresh per call,
        // never derived from the message text — a content-derived key would make
        // two deliberate sends of the same sentence collide, and the second
        // would report success while nothing arrived. See `AgentSendJournal`.
        //
        // **Unless the caller already has one.** A queued after-the-call message
        // mints its key at enqueue and persists it, so every drain of that entry
        // presents the same key and "this exact send" stays true across a
        // restart. Minting a fresh one here would make a re-drain a second
        // message, which is the one thing the key exists to prevent.
        let key = resumed ?? AgentSendJournal.newKey()
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
            // surface, and the messages one is where durability landed.
            //
            // **That durability is not a 24-hour window.** This said "11.17.7
            // keeps agent messages for 24 hours by default", which was true of
            // .7 and is not true of what ships today: 11.17.9 made the default
            // `ttl_minutes` **0**, meaning no expiry at all. Nothing in this
            // codebase pins `ttl_minutes` — there is no message-protocol hit
            // anywhere in Sources/ — so Mynah's sends have been durable since
            // the .9 revendor without anything being changed here.
            //
            // Left as a correction rather than deleted, because a comment
            // stating a shorter window than reality is how a future reader
            // talks themselves into a re-send loop for messages that never
            // expired.
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
            // **`requires_reply`, and it was `requires_result` until 1.7.5.**
            //
            // SAGE renamed this at 11.17.4. Mynah has been vendoring .7 and
            // later ever since, so `expectsAResult` has been false for every
            // message that ever arrived — and `ProactiveWatch.line(forMessage:)`
            // has announced every one of them on the owner's phone as *"X sent
            // a message"* when the node was telling us *"X sent work"*.
            //
            // Live on the shipped build, not a latent risk. Worth stating
            // plainly because the shape is the one this release keeps finding:
            // a key that vanishes reads as `false`, `false` is a legal value,
            // and nothing anywhere fails.
            //
            // The old name is still read as a fallback, and it is not merely
            // defensive. Two reasons, one of them measured:
            //
            // 1. A Mac that has not updated SAGE runs 11.16.x or earlier, where
            //    `requires_result` is the only spelling — and this appliance
            //    ships a vendored node without forcing it on a machine that
            //    already has one. See `SageNodeChoice`.
            // 2. **The rename was not global.** A live `sage_turn` on 11.17.10,
            //    6 August 2026, returns `task_assignments` entries carrying
            //    `requires_result: false`. So the two spellings coexist in one
            //    node's vocabulary today, on different notification kinds.
            //    Reading only the new one would be the identical mistake in the
            //    opposite direction.
            expectsAResult: (raw["requires_reply"] as? Bool)
                ?? (raw["requires_result"] as? Bool)
                ?? false
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
