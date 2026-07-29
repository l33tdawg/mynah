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
/// ## How "contactable" is decided
///
/// The node's own list supplies the **candidate names and nothing else**. Every
/// row is then put to `sage_find_agent`, which is caller-scoped and returns only
/// registrations that are active and accepting work — the RBAC allow list the
/// owner asked for. A candidate survives only if a match comes back **and its
/// `agent_id` equals the candidate's**.
///
/// The id comparison is the owner's instruction and it is the load-bearing part.
/// `sage_find_agent` resolves a *name*, and a name is not an identity: matching
/// on the string would let a renamed or colliding registration vouch for a row
/// it has nothing to do with, which is how a page like this ends up quietly
/// showing the wrong agent as reachable.
///
/// So REST supplies text and MCP decides what is true. The page's claim — "you
/// can talk to these" — is entirely MCP-backed even though the names are not,
/// which is the part that was wrong before: the old page made that claim off an
/// **unsigned** read, as nobody.
///
/// **One caveat, stated because the tool's own reference states it.** Absence of
/// a match is not proof of unreachability — *"Do not turn an absent directory
/// match into a statement that the agent cannot be contacted"* — and a saved
/// exact `agent_id` can still be piped to. So a hidden row means *unconfirmed*,
/// not *impossible*, and nothing here tells the owner an agent is unreachable.
/// It shows the ones it can vouch for.
///
actor MCPAgentDirectory: AgentDirectorySource {

    private let log = MynahLog(category: "roster")
    private let candidates: any AgentDirectorySource
    private let find: @Sendable (String) async throws -> JSONValue

    /// Defaults to the node's list for names and the MCP connection
    /// `SageMemoryStore` already holds for the verdict — no second node process,
    /// and the same appliance identity the Memories page signs as.
    init(
        candidates: any AgentDirectorySource = NodeAgentDirectory(),
        find: @escaping @Sendable (String) async throws -> JSONValue = { name in
            try await SageMemoryStore.shared.callTool(
                "sage_find_agent",
                arguments: ["name": .string(name), "limit": .int(20)]
            )
        }
    ) {
        self.candidates = candidates
        self.find = find
    }

    func roster() async throws -> AgentRoster {
        let all = try await candidates.roster()

        // Concurrently, because this runs once at launch over ~20 names and
        // sequential round trips would put the Agents page behind a visible
        // wait for something the owner did not ask to happen.
        let confirmed: [NodeAgent] = await withTaskGroup(of: NodeAgent?.self) { group in
            for agent in all.agents {
                group.addTask { [weak self] in
                    // The appliance is the subject of this page, not a contact
                    // on it. It is shown whatever the directory says, or Mynah
                    // would be missing from its own screen the moment it could
                    // not resolve itself.
                    guard !agent.isThisAppliance else { return agent }
                    guard let self else { return nil }
                    return await self.contactable(agent) ? agent : nil
                }
            }
            var kept: [NodeAgent] = []
            for await agent in group where agent != nil { kept.append(agent!) }
            return kept
        }

        log.info("roster: \(confirmed.count) of \(all.agents.count) confirmed contactable over MCP")
        return AgentRoster(agents: confirmed)
    }

    /// Whether MCP will vouch for this exact agent, right now.
    ///
    /// Matched on `agent_id` rather than on the name that was searched for. The
    /// tool resolves names, and two registrations can wear one name — an id
    /// comparison is the only thing that makes a match evidence about *this*
    /// row.
    private func contactable(_ agent: NodeAgent) async -> Bool {
        let payload: JSONValue
        do {
            payload = try await find(agent.name)
        } catch {
            // Unconfirmed, not unreachable. A failed lookup hides a row for
            // this launch; it never claims anything about the agent.
            log.info("could not confirm \(agent.name): \(String(describing: error))")
            return false
        }
        guard let matches = payload["matches"]?.arrayValue else { return false }
        return matches.contains { match in
            match["agent_id"]?.stringValue == agent.id
                && (match["status"]?.stringValue ?? "active") == "active"
        }
    }

    /// MCP failures, mapped to what the owner can do about them.
    ///
    /// `notSetUp` and `unreachable` stay distinct for the reason the rest of this
    /// screen keeps them distinct: one means Mynah has no memory node on this
    /// Mac, the other that it has one and it did not answer. They send somebody
    /// to two different places.
    static func trouble(for error: Error) -> AgentTrouble {
        guard let mcp = error as? MCPClientError else { return .unreachable }
        switch mcp {
        case .missingExecutable: return .notSetUp
        case .toolFailed, .rpcError: return .refused
        case .malformedResponse: return .unreadable
        case .launchFailed, .notStarted, .serverExited, .timedOut: return .unreachable
        }
    }
}
