import Foundation
import SageVoiceCore

/// Who Mynah may actually contact, asked through MCP as the appliance.
///
/// ## What this replaces, and why twice was not enough
///
/// The Agents page read `GET /v1/agents` **unsigned**. That endpoint was chosen
/// deliberately — it is the one a locked node still answers in full — and that
/// property is exactly what makes it the wrong source. An unsigned read returns
/// the node's public registry: everything on the chain, filtered by nobody, for
/// a caller with no identity. It cannot answer "who may *Mynah* contact",
/// because it was never asked as Mynah.
///
/// So the page showed twenty-one agents while Mynah, asked the same question
/// over Signal, said it could see none. The owner caught that contradiction and
/// ruled on it — *"you only see the agents you can actually talk to"*, then
/// again — *"we already said only use mcp tools"*, and again — *"must be
/// reachable and contactable, i.e. within the rbac allow list"*.
///
/// **Mynah was right and the page was wrong.** `sage_federation` returns zero
/// connections for this appliance. The page was not showing a fuller truth; it
/// was showing somebody else's.
///
/// ## Why this does not simply filter the old list
///
/// The obvious repair — keep the twenty-one and check each against
/// `sage_find_agent` — is forbidden by the tool's own reference, which says it
/// plainly: *"This is discovery metadata, not presence or a reachability probe.
/// Zero matches does not mean that a previously known recipient is offline or
/// undeliverable... Do not turn an absent directory match into a statement that
/// the agent cannot be contacted."*
///
/// It is also a substring search capped at twenty results against a node
/// carrying twenty-one agents, so it cannot enumerate even if it were allowed
/// to. Building on it would produce a list that is wrong in a new way and has to
/// be torn out when the real tool lands — and the owner has said it is coming.
///
/// ## What it reports instead
///
/// Only what MCP will answer for this caller. `sage_federation` is documented as
/// *"caller-filtered"*, which is the RBAC allow list the owner asked for. Local
/// contactable agents have no enumeration yet, so this reports that it cannot
/// know rather than substituting a public list for an authorised one — the
/// distinction `ApplianceRoster.Phase` already draws between `unavailable` and
/// `ready(.empty)`, and the one this codebase has spent a day restoring.
///
/// When SAGE ships the enumeration, it lands in `roster()` and nothing above
/// this type changes.
actor MCPAgentDirectory: AgentDirectorySource {

    private let log = MynahLog(category: "roster")
    private let call: @Sendable (String, [String: JSONValue]) async throws -> JSONValue

    /// Defaults to the connection `SageMemoryStore` already holds, so this costs
    /// no second node process and signs as the same appliance identity the
    /// Memories page does.
    init(
        call: @escaping @Sendable (String, [String: JSONValue]) async throws -> JSONValue = {
            try await SageMemoryStore.shared.callTool($0, arguments: $1)
        }
    ) {
        self.call = call
    }

    func roster() async throws -> AgentRoster {
        let payload: JSONValue
        do {
            payload = try await call("sage_federation", [:])
        } catch {
            log.error("sage_federation failed: \(String(describing: error))")
            throw Self.trouble(for: error)
        }

        // Present and empty is a real answer: the node was asked *as Mynah* and
        // said there is nobody federated. That is what Mynah tells the owner
        // over Signal, and the two surfaces finally agree.
        guard let connections = payload["connections"]?.arrayValue else {
            log.error("sage_federation returned no connections array")
            throw AgentTrouble.unreadable
        }

        let reachable = connections.compactMap(Self.agent(from:))
        log.info("roster: \(reachable.count) contactable agent(s) via MCP")
        return AgentRoster(agents: reachable)
    }

    /// One federated contact, or nil for a shape this app should not guess at.
    ///
    /// Deliberately tolerant of missing fields and deliberately not inventive:
    /// a contact with no name is dropped rather than drawn as "Unknown", because
    /// a row the owner cannot act on is worse than a row that is not there.
    private static func agent(from value: JSONValue) -> NodeAgent? {
        guard let name = value["name"]?.stringValue ?? value["agent_name"]?.stringValue,
              !name.isEmpty else { return nil }
        let id = value["agent_id"]?.stringValue ?? value["to"]?.stringValue ?? name
        return NodeAgent(
            id: id,
            name: name,
            role: value["role"]?.stringValue ?? "member",
            clearance: value["clearance"]?.intValue ?? 0,
            memoryCount: value["memory_count"]?.intValue ?? 0,
            isActive: value["status"]?.stringValue.map { $0 == "active" } ?? true,
            lastSeen: nil,
            // **Zero rather than a guess.** `sage_federation` is documented as
            // exposing no endpoint, CA, agreement or other mutation material,
            // and capabilities are not in it. Drawing a restriction dot off an
            // absent field would put a warning on an agent nobody has claimed
            // anything about — the same substitution of silence for an answer
            // this file exists to remove.
            capabilities: 0,
            // A federated contact is by definition not this appliance.
            isThisAppliance: false
        )
    }

    /// MCP failures, mapped to what the owner can do about them.
    ///
    /// `notSetUp` and `unreachable` stay distinct for the reason the rest of this
    /// screen keeps them distinct: one means Mynah has no memory node on this
    /// Mac, the other that it has one and it did not answer. They send somebody
    /// to two different places.
    private static func trouble(for error: Error) -> AgentTrouble {
        guard let mcp = error as? MCPClientError else { return .unreachable }
        switch mcp {
        case .missingExecutable:
            return .notSetUp
        case .toolFailed, .rpcError:
            return .refused
        case .malformedResponse:
            return .unreadable
        case .launchFailed, .notStarted, .serverExited, .timedOut:
            return .unreachable
        }
    }
}
