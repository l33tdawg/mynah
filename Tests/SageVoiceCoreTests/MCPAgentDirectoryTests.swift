import XCTest
@testable import MynahMac
@testable import SageVoiceCore

/// **That the Agents page only shows agents Mynah can actually reach.**
///
/// The page read `GET /v1/agents` unsigned — the one endpoint a locked node
/// answers in full — and drew all twenty-one results as "who else is on this
/// Mac". Meanwhile Mynah, asked the same question over Signal, said it could see
/// nobody. Two surfaces, one question, and the louder one was asking as no
/// identity at all.
///
/// The owner's instruction: *"filter through sage_find_agent so we can show who
/// is online AND contactable"*, matched on *"the agent id field"*.
///
/// The id is the part worth testing. `sage_find_agent` resolves a **name**, and
/// a name is not an identity — so a match only counts as evidence about a row
/// when the id agrees.
final class MCPAgentDirectoryTests: XCTestCase {

    private func agent(
        id: String,
        name: String,
        isThisAppliance: Bool = false
    ) -> NodeAgent {
        NodeAgent(
            id: id,
            name: name,
            role: "member",
            clearance: 1,
            memoryCount: 10,
            isActive: true,
            lastSeen: nil,
            capabilities: 0,
            isThisAppliance: isThisAppliance
        )
    }

    /// A directory that answers with whatever the test hands it.
    private struct Candidates: AgentDirectorySource {
        let agents: [NodeAgent]
        func roster() async throws -> AgentRoster { AgentRoster(agents: agents) }
    }

    /// Built as values rather than parsed from a string: the shape under test is
    /// what the directory does with a match, not whether JSON decodes.
    private func match(id: String, name: String, status: String = "active") -> JSONValue {
        .object([
            "matches": .array([
                .object([
                    "agent_id": .string(id),
                    "name": .string(name),
                    "scope": .string("local"),
                    "status": .string(status),
                    "to": .string(id)
                ])
            ]),
            "total": .int(1)
        ])
    }

    private var noMatch: JSONValue { .object(["matches": .array([]), "total": .int(0)]) }

    private func directory(
        _ agents: [NodeAgent],
        answering: @escaping @Sendable (String) -> JSONValue
    ) -> MCPAgentDirectory {
        MCPAgentDirectory(candidates: Candidates(agents: agents), find: { answering($0) })
    }

    // MARK: The filter

    func testOnlyAgentsMCPVouchesForAreShown() async throws {
        let reachable = agent(id: "aaa", name: "Claude Code")
        let stranger = agent(id: "bbb", name: "codex-sage")

        let roster = try await directory([reachable, stranger]) { name in
            name == "Claude Code"
                ? self.match(id: "aaa", name: "Claude Code")
                : self.noMatch
        }.roster()

        XCTAssertEqual(roster.agents.map(\.id), ["aaa"])
    }

    /// **The owner's instruction, and the failure it prevents.**
    ///
    /// A name resolving to a *different* agent must not vouch for this row.
    /// Matching on the searched name instead of the returned id is how a page
    /// like this quietly reports the wrong agent as reachable.
    func testAMatchForADifferentAgentDoesNotVouchForThisOne() async throws {
        let row = agent(id: "aaa", name: "Claude Code")

        let roster = try await directory([row]) { _ in
            // Same name, different identity.
            self.match(id: "zzz", name: "Claude Code")
        }.roster()

        XCTAssertTrue(
            roster.agents.isEmpty,
            "a namesake was allowed to vouch for an agent it is not"
        )
    }

    /// The directory returns only active registrations, but the field is read
    /// rather than assumed — an inactive match is not a contactable agent.
    func testAnInactiveMatchIsNotContactable() async throws {
        let row = agent(id: "aaa", name: "Claude Code")

        let roster = try await directory([row]) { _ in
            self.match(id: "aaa", name: "Claude Code", status: "inactive")
        }.roster()

        XCTAssertTrue(roster.agents.isEmpty)
    }

    // MARK: What must not be claimed

    /// **Absence is not a verdict.** The tool's own reference says so: *"Do not
    /// turn an absent directory match into a statement that the agent cannot be
    /// contacted."* A lookup that throws hides the row for this launch and says
    /// nothing about the agent — so the roster must not report it as anything.
    func testALookupFailureHidesTheRowWithoutClaimingUnreachable() async throws {
        struct Offline: Error {}
        let row = agent(id: "aaa", name: "Claude Code")

        let subject = MCPAgentDirectory(
            candidates: Candidates(agents: [row]),
            find: { _ in throw Offline() }
        )
        let roster = try await subject.roster()

        XCTAssertTrue(roster.agents.isEmpty, "an unconfirmed agent was shown as contactable")
    }

    /// Mynah is the subject of this page, not a contact on it. It is shown
    /// whatever the directory says, or the appliance goes missing from its own
    /// screen the moment it cannot resolve itself.
    func testTheApplianceIsAlwaysOnItsOwnPage() async throws {
        let mynah = agent(id: "self", name: "Mynah", isThisAppliance: true)

        let roster = try await directory([mynah]) { _ in self.noMatch }.roster()

        XCTAssertEqual(roster.agents.map(\.id), ["self"])
        XCTAssertNotNil(roster.appliance)
    }

    /// An empty node is not an error, and a page that asked and found nobody
    /// must stay distinct from one that could not ask — `ApplianceRoster.Phase`
    /// draws that line and this must not blur it.
    func testAnEmptyNodeIsAnEmptyRosterRatherThanAFailure() async throws {
        let roster = try await directory([]) { _ in self.noMatch }.roster()
        XCTAssertTrue(roster.agents.isEmpty)
    }

    /// Every candidate is asked about, not just the first — the confirmation is
    /// per row, and a shortcut here would show unverified agents.
    func testEveryCandidateIsPutToTheDirectory() async throws {
        let asked = Asked()
        let agents = [
            agent(id: "a", name: "one"),
            agent(id: "b", name: "two"),
            agent(id: "c", name: "three")
        ]

        _ = try await MCPAgentDirectory(
            candidates: Candidates(agents: agents),
            find: { name in
                asked.record(name)
                return JSONValue.object(["matches": .array([])])
            }
        ).roster()

        XCTAssertEqual(asked.names.sorted(), ["one", "three", "two"])
    }
}

/// Collects names across the concurrent lookups the directory runs.
private final class Asked: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func record(_ name: String) {
        lock.lock()
        defer { lock.unlock() }
        stored.append(name)
    }

    var names: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
