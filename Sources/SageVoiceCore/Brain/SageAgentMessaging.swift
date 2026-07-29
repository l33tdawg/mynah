import Foundation

/// `AgentMessaging` over the node's own MCP tools.
///
/// Thin by intention: every capability here is one the node already publishes
/// and the appliance already carries in its allowlist. What this adds is a
/// typed surface — an unforgeable address, content that resists being rendered
/// as Mynah's own words, and a failure per thing that can go wrong.
public struct SageAgentMessaging: AgentMessaging {

    private let tools: any ToolProviding

    public init(tools: any ToolProviding) {
        self.tools = tools
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
        var arguments: [String: JSONValue] = [
            // The resolved wire value, never the display name. `AgentAddress`
            // exists so this cannot accidentally be the thing the owner typed.
            "to": .string(recipient.wire),
            "payload": .string(message)
        ]
        if let intent, !intent.isEmpty { arguments["intent"] = .string(intent) }

        let reply: String
        do {
            reply = try await tools.call(name: "sage_pipe", arguments: arguments)
        } catch {
            throw Self.trouble(from: "\(error)", name: recipient.displayName)
        }

        let root = Self.object(in: reply)
        // A pipe id is the node's receipt. Without one nothing was queued, and
        // reporting success would leave the owner waiting for a reply to a
        // message that does not exist.
        guard let pipeID = root.flatMap({ Self.string($0, "pipe_id") ?? Self.string($0, "id") }) else {
            throw Self.trouble(from: reply, name: recipient.displayName)
        }
        return SentAgentMessage(pipeID: pipeID, to: recipient, sent: Date())
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
        guard let id = string(raw, "pipe_id") ?? string(raw, "id") else { return nil }
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

    static func object(in reply: String) -> [String: Any]? {
        guard let data = reply.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func string(_ object: [String: Any], _ key: String) -> String? {
        guard let value = object[key] as? String, !value.isEmpty else { return nil }
        return value
    }
}
