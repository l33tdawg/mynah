import Foundation
import Observation
import OSLog
import SageVoiceCore
import SwiftUI

// MARK: - Who is on this node

private let agentsLog = Logger(subsystem: "com.sage.mynah", category: "agents")

/// One agent registered on the SAGE running on this Mac.
///
/// Every field is one the node publishes on `GET /v1/agents`, which is
/// unauthenticated by design — `rest-api.md` lists it among the public
/// exceptions to Ed25519 request signing. That matters more than it sounds:
/// this node is encrypted, so almost everything else answers 401 to an app that
/// cannot sign, and this is the one rich source a locked node will still hand
/// over. Checked against the owner's own node: twenty agents, each with a name,
/// a role, a clearance and a memory count.
struct NodeAgent: Identifiable, Equatable, Sendable {

    let id: String
    /// The mutable display name. `sage_rename` changes this; `registered_name`
    /// is the immutable one and is not shown, because the owner recognises the
    /// name they gave a thing.
    let name: String
    /// `admin`, `member` or `observer` — the node's own vocabulary, unchanged,
    /// so a row here matches what CEREBRUM says about the same agent.
    let role: String
    /// 0–4. Deliberately not translated into words: clearance is a number in
    /// CEREBRUM, and inventing a scale of adjectives would be a second
    /// vocabulary for one fact.
    let clearance: Int
    /// How many memories this agent has stored.
    ///
    /// Zero is a real and important answer — it is what "Mynah has never saved
    /// anything" looks like from outside. The node omits the field rather than
    /// sending `0`, which is why this is not optional here: absent means none,
    /// and that reading was confirmed against a row whose store really is empty.
    let memoryCount: Int
    /// From `status`. A deactivated agent is still listed, and still counts.
    let isActive: Bool
    let lastSeen: Date?
    /// SAGE's app-v22 capability mask for this agent, or zero when the node
    /// sends none.
    ///
    /// Absent means unrestricted, and that is the documented meaning rather
    /// than a convenient reading: agents already registered when app-v22
    /// activated keep mask `0` for upgrade compatibility, and the REST layer
    /// overlays current policy onto legacy rows so a stale zero cannot make a
    /// restricted agent look unrestricted. Checked live: of twenty agents on
    /// this node, exactly one carries the field.
    let capabilities: UInt32

    /// What this agent can actually do, which is not what its role suggests.
    var permissions: AgentPermissions { AgentPermissions(mask: capabilities) }
    /// Whether this row is the appliance itself.
    ///
    /// **Matched on the agent id, and an earlier version of this got it wrong
    /// in a way worth recording.** It matched on the display name, on the
    /// strength of my having derived a public key from the identity seed and
    /// found no row carrying it — a real experiment with a wrong input. There
    /// are two key files in the appliance's support directory, and I used the
    /// vestigial one: since "One appliance is one agent" the window signs as the
    /// appliance, so `MynahIdentity.keyURL()` is a leftover and
    /// `applianceKeyURL()` is the identity. `voice` caught it. Derived from the
    /// right file, the id matches exactly.
    ///
    /// It matters beyond tidiness: `SageRitual.adoptDisplayName` deliberately
    /// lets an owner's rename in CEREBRUM stand, so a name match would have
    /// silently stopped finding the appliance the first time somebody
    /// personalised it — and this screen would have said "not registered yet"
    /// about an agent sitting in the list above it.
    let isThisAppliance: Bool

    /// "4,068 memories", "1 memory", "nothing stored yet".
    var memoryLine: String {
        switch memoryCount {
        case 0: return "nothing stored yet"
        case 1: return "1 memory"
        default: return "\(memoryCount.formatted(.number.grouping(.automatic))) memories"
        }
    }

    /// The RBAC facts as one line: what it is in the org, and how much it is
    /// cleared to see.
    var standingLine: String { "\(role) · clearance \(clearance)" }
}

// MARK: - What an agent can actually do

/// SAGE's app-v22 capability mask, read as answers rather than as bits.
///
/// The screen this feeds shows *the effective result* — can it read, can it
/// write, and why not — because that is the only form of this an owner can act
/// on. The numbers exist (`internal/store/agent_capabilities.go`) and are
/// deliberately kept out of the sentences: "it can't be given a subject of its
/// own" is a fact somebody can do something about, and "DenyDomainClaim (bit 4)"
/// is a fact about a codebase they will never read.
///
/// Every meaning below is the source's own:
///
/// - `1` lifts domain and submitting-agent read filters, never above the
///   agent's numeric clearance.
/// - `2` denies writes to ownerless shared domains — `general`, `self`, `meta`,
///   `sage-*`.
/// - `4` denies every explicit and implicit path that would make it a domain
///   owner.
/// - `8` denies writes to a domain owned by another agent **even when a level-2
///   grant exists**.
/// - `16` denies federated recipient discovery and delivery; the local inbox is
///   untouched.
struct AgentPermissions: Equatable, Sendable {

    /// The bit semantics live in `SageVoiceCore`, not here.
    ///
    /// There is exactly one copy in the product and this is not it: the daemon
    /// and the setup flow need the same meanings and cannot import this module,
    /// so `ApplianceWriteReadiness.Capability` is the definition and this type
    /// is a per-row *view* of it. Two decoders of one mask is how the boot check
    /// and this screen would eventually tell the owner different things about
    /// the same agent.
    typealias Capability = ApplianceWriteReadiness.Capability

    let mask: UInt32

    /// The pre-app-v22 posture, and what nineteen of the twenty agents on the
    /// owner's node have: no mask, no restrictions.
    var isRestricted: Bool { mask != 0 }

    /// The named profile for a co-located voice appliance. Not a promise that
    /// writes now succeed — that additionally needs an owned subject, which no
    /// unsigned caller can see.
    var hasCompanionProfile: Bool { mask == Capability.companion }

    /// Whether anything at all stands between this agent and saving a memory.
    ///
    /// Deliberately not "cannot write". With the three write denials set, one
    /// route survives — a domain the agent *already owns* — and this app cannot
    /// see domain ownership, because the endpoint that would answer it needs a
    /// signature. So the screen says what is certain: every route except an
    /// already-owned subject is closed.
    var writesAreRestricted: Bool { mask & Capability.writeDenials != 0 }

    /// The one case where the answer is unambiguous: it may not claim a subject
    /// and may not write anybody else's, so unless a subject was *assigned* to
    /// it, there is nowhere it can write at all.
    var needsASubjectAssigned: Bool {
        mask & Capability.denyOwningASubject != 0 && mask & Capability.denyForeignWrite != 0
    }

    /// The headline answer about saving, in the owner's words.
    var writingLine: String {
        guard writesAreRestricted else { return "Can save what you tell it." }
        return needsASubjectAssigned
            ? "Can't save anything until it's given a subject of its own."
            : "Can only save to a subject that belongs to it."
    }

    /// **What is deliberately not here: the sentences.**
    ///
    /// This type used to carry its own `reasons` and `additions`, and they were
    /// good enough that `voice` took the best of them into the shared string.
    /// Keeping my copies afterwards would have left two sets of explanations for
    /// one mask, drifting apart the first time either was reworded — the exact
    /// thing the `typealias` above exists to prevent, one level up. What the
    /// page renders now is `ApplianceWriteReadiness.reasons`; what survives here
    /// is only what a *row* needs, which is the one-line effective answer.
}

/// Everyone on this node, and the appliance's own row among them.
struct AgentRoster: Sendable, Equatable {
    var agents: [NodeAgent] = []

    static let empty = AgentRoster()

    /// The appliance's own row, when the node has one under the name it
    /// registers with. `nil` is a real state — a first run before the ritual has
    /// registered — and reads as "not registered yet", never as "no access".
    var appliance: NodeAgent? { agents.first { $0.isThisAppliance } }

    /// Everyone else, most memories first. The busiest agents are the ones the
    /// owner actually runs; sorting by name buries them under whatever
    /// auto-registered first.
    var others: [NodeAgent] {
        agents.filter { !$0.isThisAppliance }.sorted { $0.memoryCount > $1.memoryCount }
    }
}

// MARK: - Other SAGEs, which are a different question

/// One reachable SAGE on the owner's network.
struct FederatedSAGE: Identifiable, Equatable, Sendable {
    /// The peer's chain id. Identity, shown only in short form — a full chain id
    /// is machinery.
    let id: String
    /// The network's own name, when the peer publishes one.
    let networkName: String?

    var title: String { networkName ?? "A SAGE on your network" }
}

/// An agent on somebody else's SAGE, when that peer advertises its contacts.
struct RemoteAgent: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    /// Which peer it belongs to, so a name here is never mistaken for something
    /// on this Mac.
    let network: String?
}

/// What a scan of the network found.
///
/// Its own value rather than more rows on the roster, deliberately. Agents *on
/// this node* and agents *on other SAGEs* are different questions with different
/// answers, and collapsing them is what made the owner's own question — "what
/// agents can you see?" — unanswerable.
struct FederationReport: Equatable, Sendable {
    var connections: [FederatedSAGE] = []
    /// Domains on those peers that this node is allowed to recall from.
    ///
    /// The direction is easy to get backwards and worth stating carefully.
    /// `sage_federation`'s own reply says "Use sage_recall with scope=auto and
    /// one of these exact domains", so these are the peers' subjects *this* node
    /// may read — not this node's subjects they may read. The screen says it
    /// that way round.
    var readableDomains: [String] = []
    /// Domains a peer has offered to copy wholesale, which is a separate
    /// two-sided arrangement from read access.
    var copyOfferedDomains: [String] = []
    var remoteAgents: [RemoteAgent] = []

    var foundNothing: Bool {
        connections.isEmpty && readableDomains.isEmpty && remoteAgents.isEmpty
    }
}

// MARK: - What can go wrong

/// Everything that can go wrong between this screen and the node, in shapes the
/// owner can act on.
///
/// Note what is *not* here: an empty roster. "Nobody is registered" is a result,
/// not a failure, and the two must never render the same — an owner with twenty
/// agents being told they have none because the node is locked is the failure
/// this enum exists to prevent.
enum AgentTrouble: Error, Equatable, Sendable {
    /// Mynah's memory and agents have never been set up on this Mac.
    case notSetUp
    /// Set up, and it did not answer.
    case unreachable
    /// It answered, and would not say. An encrypted node returns 401 to a caller
    /// that cannot sign; this is rendered as "locked", never as a zero.
    case locked
    /// It answered, and refused for some other reason.
    case refused
    /// It answered with something this app could not read.
    case unreadable

    var headline: String {
        switch self {
        case .notSetUp: return "Mynah hasn't got a memory on this Mac yet."
        case .unreachable: return "Mynah can't reach your node."
        case .locked: return "Your node is locked."
        case .refused: return "Your node wouldn't answer that."
        case .unreadable: return "Your node answered with something unexpected."
        }
    }

    /// Every one of these names something the owner can do, and none of them
    /// claims the agents are gone.
    var explanation: String {
        switch self {
        case .notSetUp:
            return "Set Mynah up again and it will build one. Nothing is lost — there was "
                + "nowhere to keep it yet."
        case .unreachable:
            return "It may still be starting up. Give it a moment and try again. Your agents "
                + "are unaffected."
        case .locked:
            return "Unlock it in CEREBRUM and come back. Your agents are all still there — this "
                + "screen simply isn't allowed to read them until you do."
        case .refused:
            return "Quit Mynah and open it again. If that doesn't help, set it up again."
        case .unreadable:
            return "Try again. If it keeps happening, quit Mynah and open it again."
        }
    }

    /// A "Try again" that cannot succeed teaches the owner their buttons are
    /// decorative. A locked node is not fixed by retrying; it is fixed in
    /// CEREBRUM, which the explanation says.
    var isWorthRetrying: Bool {
        self == .unreachable || self == .unreadable || self == .refused
    }
}

// MARK: - Reading the roster

/// Where the list of agents on this node comes from.
protocol AgentDirectorySource: Sendable {
    func roster() async throws -> AgentRoster
}

/// The real one: `GET /v1/agents` on the node's own HTTP port.
///
/// Chosen over anything under `/v1/dashboard/` for a reason that was checked
/// rather than assumed. This Mac's node is encrypted, so `/v1/dashboard/stats`,
/// `/v1/dashboard/tasks` and `/v1/dashboard/network/agents` all answer `401
/// {"login_required":true}` to an unsigned local caller, and
/// `/v1/access/grants/{agent_id}` answers 401 as well. `/v1/agents` is public
/// and answered in full. The whole screen is built on what a locked node will
/// still say, which is why it works at all.
struct NodeAgentDirectory: AgentDirectorySource {

    private let endpoint: URL
    private let session: URLSession

    init(endpoint: URL? = nil, timeout: TimeInterval = 10) {
        self.endpoint = endpoint ?? Self.defaultEndpoint()
        // No cookies, no credentials, no caching, and a refusal to follow a
        // redirect off the loopback interface.
        self.session = LoopbackSecurity.makeSession(timeout: timeout)
    }

    /// `127.0.0.1:8080` is the shipped REST default. `SAGE_API_URL` overrides it
    /// for anyone running the node elsewhere, and is ignored unless it points at
    /// this machine — a roster fetched from a stranger's node would be somebody
    /// else's agents rendered as the owner's.
    static func defaultEndpoint(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let fallback = URL(string: "http://127.0.0.1:8080")!
        let configured = environment["SAGE_API_URL"].flatMap(URL.init(string:))
        let base = LoopbackSecurity.isLoopback(configured) ? (configured ?? fallback) : fallback
        return base.appendingPathComponent("v1/agents")
    }

    func roster() async throws -> AgentRoster {
        try LoopbackSecurity.requireLoopback(endpoint)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            agentsLog.error("GET /v1/agents failed: \(String(describing: error), privacy: .public)")
            throw AgentTrouble.unreachable
        }
        try LoopbackSecurity.verifyResponseOrigin(response, expected: endpoint)

        guard let http = response as? HTTPURLResponse else { throw AgentTrouble.unreadable }
        switch http.statusCode {
        case 200:
            break
        case 401, 403:
            throw AgentTrouble.locked
        case 404:
            throw AgentTrouble.notSetUp
        default:
            agentsLog.error("GET /v1/agents returned \(http.statusCode, privacy: .public)")
            throw AgentTrouble.refused
        }

        guard let roster = AgentRosterReading.roster(from: data) else { throw AgentTrouble.unreadable }
        return roster
    }
}

/// Turning the node's reply into rows.
///
/// Its own type so it can be tested against the real payload without a node —
/// this is the seam where a change at the other end becomes a wrong screen.
enum AgentRosterReading {

    static func roster(
        from data: Data,
        applianceID: String? = SageAgentIdentity.applianceAgentID()
    ) -> AgentRoster? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return roster(fromToolText: text, applianceID: applianceID)
    }

    /// Brace-matched rather than decoded from the first byte, because the same
    /// reader has to survive a reply that arrives with the node's plain-text
    /// banner in front of it. That matcher already exists on the memories
    /// screen and is reused rather than written twice.
    ///
    /// `applianceID` is passed in rather than read here so a test can name it,
    /// and is `nil` when the key cannot be read at all — on that path the
    /// appliance's row falls back to the name it registers under, which is
    /// right more often than it is wrong and is never used to override a
    /// positive id match.
    static func roster(
        fromToolText text: String,
        applianceID: String? = SageAgentIdentity.applianceAgentID()
    ) -> AgentRoster? {
        guard let payload = SageMemoryStore.embeddedObject(in: text),
              let rows = payload["agents"]?.arrayValue else { return nil }
        return AgentRoster(agents: rows.compactMap { agent(from: $0, applianceID: applianceID) })
    }

    static func agent(from entry: JSONValue, applianceID: String? = nil) -> NodeAgent? {
        guard let id = entry["agent_id"]?.stringValue, !id.isEmpty else { return nil }
        // A row with no display name still exists and still holds memories.
        // Falling back to the registered name beats dropping it from a list the
        // owner is using to check what is on their machine.
        let name = [entry["name"]?.stringValue, entry["registered_name"]?.stringValue]
            .compactMap { $0 }
            .first { !$0.isEmpty }
        guard let name else { return nil }

        return NodeAgent(
            id: id,
            name: name,
            role: entry["role"]?.stringValue ?? "member",
            clearance: entry["clearance"]?.intValue ?? 0,
            memoryCount: entry["memory_count"]?.intValue ?? 0,
            isActive: (entry["status"]?.stringValue ?? "active") == "active",
            lastSeen: SageMemoryStore.date(from: entry["last_seen"]?.stringValue),
            // Absent is the unrestricted posture, not missing information.
            capabilities: UInt32(entry["capabilities"]?.intValue ?? 0),
            // Identity first, name only when there is no identity to compare
            // against. An owner who renames Mynah in CEREBRUM must not drop it
            // off its own screen.
            isThisAppliance: applianceID.map { $0 == id } ?? (name == SageRitual.applianceDisplayName)
        )
    }
}

// MARK: - Looking for other SAGEs

/// What the owner's "look for agents on your network" button does.
protocol FederationScanning: Sendable {
    func scan() async throws -> FederationReport
}

/// The real scan: the `sage_federation` MCP tool.
///
/// Read-only and caller-filtered by the node itself — the tool's own description
/// says "pairing, sharing, subscriptions, and other mutations remain
/// operator-only" — so a button that runs it cannot change anything about the
/// owner's federation. It takes no parameters, which is why the button needs no
/// form.
///
/// On demand rather than on appearance: this starts a SAGE child process, and
/// the app already runs others. Nobody should pay for a network scan by walking
/// past the screen.
actor SageFederationScan: FederationScanning {

    static let shared = SageFederationScan()

    private var client: MCPClient?

    /// Which binary should operate the store that already holds the owner's
    /// memories — not "which binary can this app find first".
    ///
    /// `EnvironmentProbe.defaultSageBundleExecutables` is vendored-first, which
    /// is the right answer to a different question. Used here it meant that on a
    /// Mac with SAGE already installed, a network scan spawned the copy we
    /// happened to vendor to drive the owner's existing `~/.sage`: one store,
    /// two binaries, whatever versions they happened to be. `SageNodeChoice` is
    /// the rule the owner asked for — if a node is already installed, Mynah uses
    /// it and changes nothing about it — and it is what the daemon, Memories and
    /// the board all resolve with, so every surface now agrees.
    private static var executableURL: URL? {
        SageNodeChoice.resolve(vendored: SageNodeLocator.vendoredExecutableURL())?.executable
    }

    /// The identity a spawned scan signs as, named so a test can pin it.
    ///
    /// Exposed rather than inlined because this exact line has been wrong twice
    /// and neither mistake was visible from a passing test: an unregistered key
    /// still gets an answer from `sage_federation`, just an empty one, so
    /// "the scan succeeded" proves nothing about who asked.
    static func spawnEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String: String] {
        MynahIdentity.applianceEnvironment(environment: environment, homeDirectory: homeDirectory)
    }

    private func connection() throws -> MCPClient {
        if let client { return client }
        guard let executable = Self.executableURL else { throw AgentTrouble.notSetUp }
        let made = MCPClient(
            executableURL: executable,
            arguments: ["mcp"],
            // `applianceEnvironment()`, which is the one that pins the key the
            // node has actually registered.
            //
            // This line has been wrong twice, and the second time is the
            // instructive one. It started as `resolvedKeyPath()`, which returns
            // the vestigial `agent.key` — an identity the node has never heard
            // of. I "fixed" it to `childEnvironment()` and wrote a comment
            // saying that was what every other spawn site used and that it
            // pinned the appliance key. Both halves were false, and the fix
            // changed nothing: `childEnvironment()` is `resolvedKeyPath()` in a
            // dictionary, its own doc comment still claims every spawn site must
            // use it, and after `chrome` moved Memories across, line 515 was its
            // only caller left in the product. `chrome` caught it.
            //
            // It matters because `sage_federation` is caller-filtered: a scan
            // signed as an unregistered key answers for nobody, and "no peers"
            // is exactly what that looks like — a reassuring sentence produced
            // by asking the wrong question.
            environment: Self.spawnEnvironment(),
            requestTimeoutSeconds: 30
        )
        client = made
        return made
    }

    /// Drops a dead child so the next attempt starts a fresh one. A retained
    /// dead client answers every later request with the same failure forever.
    private func reset() {
        client?.stop()
        client = nil
    }

    func scan() async throws -> FederationReport {
        let client = try connection()
        let text: String
        do {
            text = try await client.call(name: "sage_federation", arguments: [:])
        } catch let error as MCPClientError {
            agentsLog.error("sage_federation failed: \(String(describing: error), privacy: .public)")
            switch error {
            case .missingExecutable: throw AgentTrouble.notSetUp
            case .toolFailed, .rpcError: throw AgentTrouble.refused
            case .malformedResponse: throw AgentTrouble.unreadable
            case .launchFailed, .notStarted, .serverExited, .timedOut:
                reset()
                throw AgentTrouble.unreachable
            }
        } catch {
            agentsLog.error("sage_federation failed: \(String(describing: error), privacy: .public)")
            reset()
            throw AgentTrouble.unreachable
        }

        guard let report = FederationReading.report(fromToolText: text) else {
            throw AgentTrouble.unreadable
        }
        return report
    }
}

/// Reading `sage_federation`'s reply.
///
/// Every key is optional, and that is not defensiveness for its own sake: on a
/// node with no peers the tool answers `{"connections": [], "message": …,
/// "total": 0}` and omits the domain and agent keys entirely — checked live on
/// the owner's node. The populated shape comes from `mcp-tools.md` and could not
/// be checked here, because this Mac has no federated peer to check it against.
enum FederationReading {

    static func report(fromToolText text: String) -> FederationReport? {
        guard let payload = SageMemoryStore.embeddedObject(in: text) else { return nil }
        // `connections` is the one key the tool always writes, so its absence
        // means this is not a federation reply at all — an error object, or a
        // tool that changed underneath us. Reading that as "no peers" would turn
        // a broken call into a reassuring sentence.
        guard payload["connections"] != nil else { return nil }
        return report(from: payload)
    }

    static func report(from payload: JSONValue) -> FederationReport {
        FederationReport(
            connections: (payload["connections"]?.arrayValue ?? []).compactMap(connection(from:)),
            readableDomains: strings(payload["shared_read_domains"]),
            copyOfferedDomains: strings(payload["copy_offered_domains"]),
            remoteAgents: (payload["remote_agents"]?.arrayValue ?? []).compactMap(remoteAgent(from:))
        )
    }

    static func connection(from entry: JSONValue) -> FederatedSAGE? {
        guard let id = entry["remote_chain_id"]?.stringValue, !id.isEmpty else { return nil }
        let name = entry["network_name"]?.stringValue
        return FederatedSAGE(id: id, networkName: (name?.isEmpty == false) ? name : nil)
    }

    static func remoteAgent(from entry: JSONValue) -> RemoteAgent? {
        let id = entry["agent_id"]?.stringValue ?? entry["to"]?.stringValue
        guard let id, !id.isEmpty else { return nil }
        let name = [entry["name"]?.stringValue, entry["registered_name"]?.stringValue, id]
            .compactMap { $0 }
            .first { !$0.isEmpty } ?? id
        let network = entry["network_name"]?.stringValue ?? entry["remote_chain_id"]?.stringValue
        return RemoteAgent(id: id, name: name, network: (network?.isEmpty == false) ? network : nil)
    }

    private static func strings(_ value: JSONValue?) -> [String] {
        (value?.arrayValue ?? []).compactMap { $0.stringValue }.filter { !$0.isEmpty }
    }
}

// MARK: - What the owner is told about permissions

/// The only claims this app makes about SAGE's permission model.
///
/// **Every sentence here is checked against SAGE's own reference —
/// `docs/reference/concepts/rbac-orgs-federation.md` and `rest-api.md` — and
/// nothing beyond them is stated.** The citations are in the doc comments below.
/// This is a separate product's security model being explained to somebody who
/// did not ask to learn one, so the failure mode is not a typo — it is an owner
/// who grants more than they meant to because a screen simplified in the wrong
/// direction.
///
/// Held here rather than inline in the view so the honesty of it is testable.
enum FederationHelp {

    struct Level: Sendable, Hashable {
        /// The word CEREBRUM itself shows, so the owner recognises it there
        /// rather than translating this screen's vocabulary into that one.
        let name: String
        let meaning: String
    }

    /// The domain the appliance writes everything to.
    ///
    /// Taken from `SageRitual.memoryDomain` rather than spelled out again, so
    /// this screen cannot end up naming a subject the appliance stopped using.
    /// Naming the wrong one sends the owner to grant access to something that is
    /// not the problem.
    static var applianceDomain: String { SageRitual.memoryDomain }

    /// Steps 1 and 2 describe the registration path every agent on this node
    /// already took, Mynah's included.
    ///
    /// Step 3 names CEREBRUM and stops. There is deliberately no route through
    /// its interface: CEREBRUM is a separate product whose screens this app
    /// cannot see, and confident directions through a UI that may have moved are
    /// worse than naming the destination. The "its own memories and none of
    /// Mynah's" clause is the grant rule — access to another agent's domain
    /// needs an explicit grant, and org membership does not imply one.
    static let steps = [
        "Point the other agent — Claude Code, Codex, whatever you use — at the SAGE on this "
            + "Mac, over MCP. It is the same node Mynah uses.",
        "The first time it connects it registers itself, and its name appears in the list above.",
        "Open CEREBRUM and give it what it needs. Until you do it can reach its own memories "
            + "and none of Mynah's."
    ]

    /// **This replaced a claim that was wrong, and the correction is the point.**
    ///
    /// The screen used to say that if Mynah registered first it was the
    /// administrator — the intuition being that a sole install owns its own
    /// machine. The platform does not work that way, and an owner who believed
    /// it would go looking for a switch that does not exist. Checked in SAGE's
    /// own source: changing an agent's permissions after app-v22 requires a
    /// *global* administrator (`agent_handler.go` refuses any other caller with
    /// "only a global administrator can change agent permissions after
    /// app-v22"), and the capability check consults admin status nowhere — so
    /// being an administrator would not lift these restrictions even if Mynah
    /// were one.
    static let admin = "Being the only SAGE on this Mac doesn't make Mynah an administrator, and "
        + "it wouldn't help if it were — these limits sit on the key itself, not on its rank."

    /// The matrix issues Read (1), Write (2) and Modify (3), and "Modify
    /// includes Read and Write".
    ///
    /// The Write line carries the warning that matters: a memory write requires
    /// the effective owner or an explicit level-2 grant, and org membership and
    /// clearance do not imply write authority. An owner who assumes that adding
    /// an agent to their node has given it the ability to write is wrong in the
    /// direction that loses data — which is exactly what happened to Mynah.
    static let levels = [
        Level(
            name: "Read",
            meaning: "It can see what Mynah remembers about a subject you pick. "
                + "It cannot add anything."
        ),
        Level(
            name: "Write",
            meaning: "It can add memories too. Sharing a node is not enough on its own — "
                + "this one has to be given on purpose."
        ),
        Level(
            name: "Modify",
            meaning: "It can also change or retire what is already there. "
                + "Modify includes Read and Write."
        )
    ]

    /// The sentence that keeps the grant model and the capability model apart.
    ///
    /// Both exist, and the levels above are real — for an agent SAGE has not
    /// restricted. Somebody reading this section straight after Mynah's would
    /// otherwise reasonably conclude that a Write tick is the fix for it, which
    /// is the mistake this whole page was corrected to stop making.
    static let grantsDoNotLiftRestrictions = "These apply to agents SAGE hasn't restricted. Where "
        + "a key carries restrictions of its own, no amount of granting lifts them."

    /// Saving the matrix "reconciles the desired levels against the ACTUAL
    /// on-chain grant state and issues REAL `AccessGrant` / `AccessRevoke` txs
    /// for each divergence", each signed as the domain owner.
    ///
    /// Said in the owner's words and not softened: a grid of checkboxes that
    /// looks like a preferences panel and is in fact a consensus transaction is
    /// the one thing about this that a person could get badly wrong.
    static let grantsAreReal = "Saving that in CEREBRUM is not a setting — it grants the access "
        + "there and then, on your node, and takes it away again the same way."

    /// Why this screen cannot show the grants themselves.
    ///
    /// Checked rather than assumed: `GET /v1/access/grants/{agent_id}` answers
    /// `401 Missing authentication headers` to this app, which cannot sign
    /// requests. Saying "no grants" on the strength of a call that was refused
    /// would be inventing the most consequential fact on the screen.
    static let grantsAreNotReadableHere = "Mynah can't read the grant list itself — your node "
        + "only hands that to a signed request. CEREBRUM shows it in full."

    /// The remedy is deliberately NOT defined here.
    ///
    /// It is `ApplianceWriteReadiness.remedy` in `SageVoiceCore`, and this
    /// screen renders that string rather than its own. The owner can meet this
    /// restriction in two places — the boot check and this page — and two
    /// hand-written explanations of one mechanism is how they end up believing
    /// there are two problems. The sentence lives where both surfaces can reach
    /// it; the extra context below is this page's, because a page has room for
    /// it and a boot line does not.

    /// Said next to the remedy, because the obvious next move is to try it from
    /// here.
    ///
    /// `rbac-orgs-federation.md`: "A restricted process therefore cannot clear
    /// its own restrictions through REST, CEREBRUM, or a directly submitted
    /// transaction." Mynah asking on the owner's behalf is one of the routes
    /// that is closed, so a button here would be a button that cannot work.
    static let cannotFixItself = "Mynah can't lift this itself, and neither can this app — SAGE "
        + "refuses a restricted agent that asks, whichever way it asks."

    /// For the person who has to relay it to whoever administers the node.
    ///
    /// The one place a number appears, and it is a detail line rather than a
    /// control: an operator typing this into CEREBRUM needs the preset's real
    /// name, and "the companion profile" alone would leave them guessing.
    static var companionPresetDetail: String {
        "companion profile · mask 15 · owner of “\(SageRitual.memoryDomain)”, not a grant"
    }

    /// The state the owner actually hit: a row that looks completely ordinary
    /// and can do nothing.
    ///
    /// Worth its own sentence because every visible field says "fine". Mynah is
    /// `active`, a `member`, with a clearance — exactly like the nineteen agents
    /// beside it that write thousands of memories. The difference is a field
    /// most of those rows do not carry at all.
    static let looksOrdinaryButIsMuted = "Its role and clearance look ordinary, and they are. The "
        + "limit is on the key itself, which is why nothing on the row above hints at it."
}

// MARK: - Model

@MainActor
@Observable
final class AgentsModel {

    enum Phase: Equatable {
        case loading
        case ready
        case failed(AgentTrouble)
    }

    /// The network scan is its own state machine because it is the owner's
    /// button rather than the screen's own load: it can be idle for the whole
    /// visit, and a failure in it must not take the roster down with it.
    enum ScanPhase: Equatable {
        case idle
        case scanning
        case found(FederationReport)
        case failed(AgentTrouble)
    }

    private(set) var phase: Phase = .loading
    private(set) var roster = AgentRoster.empty
    private(set) var scan: ScanPhase = .idle

    private let source: any AgentDirectorySource
    private let federation: any FederationScanning

    init(
        source: any AgentDirectorySource = NodeAgentDirectory(),
        federation: any FederationScanning = SageFederationScan.shared
    ) {
        self.source = source
        self.federation = federation
    }

    func load() async {
        // The previous answer stays on screen while this runs. A refresh that
        // blanks the list first makes a working node look like it dropped out
        // every time the owner comes back to the pane.
        do {
            roster = try await source.roster()
            phase = .ready
        } catch let trouble as AgentTrouble {
            phase = .failed(trouble)
        } catch {
            agentsLog.error("roster failed: \(String(describing: error), privacy: .public)")
            phase = .failed(.unreachable)
        }
    }

    /// The owner's button. Never automatic: it starts a node process and asks
    /// the network a question, and neither should happen because somebody walked
    /// past this screen.
    func lookForAgents() async {
        guard scan != .scanning else { return }
        scan = .scanning
        do {
            scan = .found(try await federation.scan())
        } catch let trouble as AgentTrouble {
            scan = .failed(trouble)
        } catch {
            agentsLog.error("federation scan failed: \(String(describing: error), privacy: .public)")
            scan = .failed(.unreachable)
        }
    }
}

// MARK: - Screen

/// Who is on this Mac's SAGE, what Mynah itself is allowed to do, and what is
/// out there on the network.
///
/// Three questions in that order, kept apart on purpose. The owner asked Mynah
/// "what agents can you see" and was told "zero connected agents" while twenty
/// sat on his node — because "agents registered here" and "agents on other
/// SAGEs" had been collapsed into one idea that answered neither.
struct AgentsView: View {
    @State private var model: AgentsModel

    /// `@MainActor` because `AgentsModel` is, and a `View`'s initialiser is not
    /// isolated by default even though SwiftUI only ever calls it here.
    @MainActor
    init(
        source: any AgentDirectorySource = NodeAgentDirectory(),
        federation: any FederationScanning = SageFederationScan.shared
    ) {
        _model = State(initialValue: AgentsModel(source: source, federation: federation))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Your agents")
                    .mynahFont(.title1)
                    .foregroundStyle(Palette.ink.primary)
                    .accessibilityAddTraits(.isHeader)

                roster.padding(.top, s6)
                applianceAccess
                network
                joining
            }
            .frame(maxWidth: MynahWidth.settings, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, s8)
            .padding(.top, s7)
            .padding(.bottom, s9)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Palette.surface.canvas)
        .task { await model.load() }
    }

    // MARK: On this Mac

    @ViewBuilder
    private var roster: some View {
        switch model.phase {
        case .loading:
            // Nothing at all, on purpose. This is one local HTTP call, and a
            // breathing indicator on every visit is an appliance asking to be
            // watched.
            Color.clear.frame(height: 1)

        case .failed(let trouble):
            InlineBanner(
                tone: trouble == .locked ? .caution : .critical,
                headline: trouble.headline,
                explanation: trouble.explanation,
                actionTitle: trouble.isWorthRetrying ? "Try again" : nil,
                action: trouble.isWorthRetrying ? { Task { await model.load() } } : nil
            )

        case .ready:
            if model.roster.agents.isEmpty {
                EmptyState(
                    glyph: "person.2",
                    title: "Nobody is registered yet",
                    message: "Agents appear here the first time they connect to the SAGE on this "
                        + "Mac. Mynah registers itself the first time you talk to it."
                )
                .padding(.top, s8)
            } else if model.roster.others.isEmpty {
                SettingsGroup("On this Mac") {
                    SettingsRow(
                        "Only Mynah so far",
                        detail: "Nothing else has connected to this node yet. Adding one is below."
                    ) { EmptyView() }
                }
            } else {
                SettingsGroup("On this Mac") {
                    ForEach(Array(model.roster.others.enumerated()), id: \.element.id) { index, agent in
                        if index > 0 { MynahDivider() }
                        AgentRow(agent: agent)
                    }
                }
            }
        }
    }

    // MARK: Mynah's own standing
    //
    // The section the owner needed two days ago. Mynah had stored nothing on a
    // node holding thousands of memories, and until this screen said so there
    // was no way to find that out from inside the product.

    @ViewBuilder
    private var applianceAccess: some View {
        if case .ready = model.phase {
            SettingsGroup("Mynah's own access") {
                if let appliance = model.roster.appliance {
                    AgentRow(agent: appliance)
                    MynahDivider()
                    ApplianceStanding(agent: appliance)
                } else {
                    // Registration happens on the first turn. Before that there
                    // is genuinely no row, and that is not a permissions problem
                    // — saying so beats an empty space.
                    SettingsRow(
                        "Not registered yet",
                        detail: "Mynah registers itself with your node the first time you talk to "
                            + "it. Send it a voice note and it will appear here."
                    ) { EmptyView() }
                }
                MynahDivider()
                SettingsRow(
                    "What it's been granted",
                    detail: FederationHelp.grantsAreNotReadableHere
                ) { EmptyView() }
            }
        }
    }

    // MARK: The network

    /// The owner's button, and what came back. Separate from the roster above it
    /// because it answers a different question — nothing found here is on this
    /// Mac.
    private var network: some View {
        SettingsGroup("Other SAGEs on your network") {
            VStack(alignment: .leading, spacing: s5) {
                HStack(spacing: s4) {
                    MynahButton(
                        model.scan == .scanning ? "Looking…" : "Look for agents on your network",
                        kind: .secondary,
                        isEnabled: model.scan != .scanning
                    ) {
                        Task { await model.lookForAgents() }
                    }
                    Spacer(minLength: 0)
                }
                scanResult
            }
            .padding(.vertical, s4)
        }
    }

    @ViewBuilder
    private var scanResult: some View {
        switch model.scan {
        case .idle:
            Text("Mynah will ask your node which other SAGEs it can reach, and which of their "
                + "subjects it is allowed to read. It changes nothing.")
                .mynahFont(.callout)
                .foregroundStyle(Palette.ink.secondary)
                .fixedSize(horizontal: false, vertical: true)

        case .scanning:
            Text("Asking your node…")
                .mynahFont(.callout)
                .foregroundStyle(Palette.ink.secondary)

        case .failed(let trouble):
            InlineBanner(
                tone: .critical,
                headline: trouble.headline,
                explanation: trouble.explanation,
                actionTitle: trouble.isWorthRetrying ? "Try again" : nil,
                action: trouble.isWorthRetrying ? { Task { await model.lookForAgents() } } : nil
            )

        case .found(let report):
            if report.foundNothing {
                // True and unalarming. Nothing is shared in either direction,
                // which for most owners is both correct and what they want.
                Text("No other SAGEs answered. Nothing is shared with anyone else, and nothing "
                    + "of theirs is readable from here.")
                    .mynahFont(.callout)
                    .foregroundStyle(Palette.ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                FederationFindings(report: report)
            }
        }
    }

    // MARK: Getting another agent here

    /// What the owner does next, and what they are agreeing to when they do it.
    ///
    /// Present in every state including the failures, because an owner who
    /// cannot see their agents today is exactly the person who wants to know how
    /// this is supposed to work.
    @ViewBuilder
    private var joining: some View {
        if case .loading = model.phase {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                SettingsGroup("Adding another agent") {
                    VStack(alignment: .leading, spacing: s5) {
                        NumberedStepList(steps: FederationHelp.steps)
                        Text(FederationHelp.admin)
                            .mynahFont(.callout)
                            .foregroundStyle(Palette.ink.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, s4)
                }

                SettingsGroup("What you can let an agent do") {
                    ForEach(Array(FederationHelp.levels.enumerated()), id: \.element.name) { index, level in
                        if index > 0 { MynahDivider() }
                        SettingsRow(level.name, detail: level.meaning) { EmptyView() }
                    }
                }

                VStack(alignment: .leading, spacing: s3) {
                    // Keeps the two models apart. Granting is real; it is not
                    // what is stopping Mynah, and this section must not be read
                    // as the fix for the section above it.
                    Text(FederationHelp.grantsDoNotLiftRestrictions)
                        .mynahFont(.callout)
                        .foregroundStyle(Palette.ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // The candour line, and the reason this section exists.
                    Text(FederationHelp.grantsAreReal)
                        .mynahFont(.callout)
                        .foregroundStyle(Palette.ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, s5)
            }
        }
    }
}

// MARK: - One agent

/// A row: who it is, what it is allowed to be, and how much it has stored.
///
/// The memory count is the third thing the owner asked for — "what memories are
/// stored by mynah" — and because it is per agent, the same row answers it for
/// every other agent on the node too. It is also the only visible symptom of the
/// permissions problem this screen exists to surface, which is why a zero is
/// drawn in caution ink rather than as a quiet grey number nobody reads.
private struct AgentRow: View {
    let agent: NodeAgent

    var body: some View {
        SettingsRow(agent.name, detail: detail) {
            HStack(spacing: s3) {
                if !agent.isActive {
                    StatusPill("Inactive", tone: .caution)
                }
                // The mark the row otherwise has no way of carrying. Everything
                // else about a restricted agent reads as ordinary — same role,
                // same clearance, same active status as the nineteen beside it
                // that write freely.
                if agent.permissions.isRestricted {
                    StatusPill("Restricted", tone: .caution)
                }
                Text(agent.memoryLine)
                    .mynahFont(.label)
                    .foregroundStyle(
                        agent.memoryCount == 0 ? Palette.state.caution : Palette.ink.secondary
                    )
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(agent.name). \(detail). \(agent.memoryLine).")
    }

    /// Role and clearance, plus the effective answer when it differs from what
    /// they imply — which is the whole problem this row exists to expose.
    private var detail: String {
        guard agent.permissions.isRestricted else { return agent.standingLine }
        return "\(agent.standingLine) · \(agent.permissions.writingLine)"
    }
}

// MARK: - What Mynah itself can do

/// The effective answer for the appliance: what it can do, why not, and who has
/// to change it.
///
/// Shaped as SAGE's own team described the direction — "the UI shows the
/// effective result — can read / can write / why denied — instead of exposing
/// five cryptic checkboxes as the primary control". So there are no checkboxes
/// and no bit numbers in the sentences; the one number on the screen is the
/// preset name an operator has to type somewhere else.
private struct ApplianceStanding: View {
    let agent: NodeAgent

    /// The same value the boot check and the setup flow render, built from the
    /// row this screen already has rather than by asking the node twice.
    ///
    /// Sharing the *type* rather than the sentences is what keeps one mechanism
    /// from acquiring two explanations: `headline`, `reasons` and `remedy` below
    /// are `voice`'s strings, so an owner who meets this at boot and again here
    /// reads the same words both times.
    private var readiness: ApplianceWriteReadiness {
        ApplianceWriteReadiness(agentID: agent.id, standing: .registered(mask: agent.capabilities))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: s5) {
            if let headline = readiness.headline {
                InlineBanner(
                    tone: .caution,
                    headline: headline,
                    explanation: readiness.remedy ?? ""
                )
                reasons
                footnotes
            } else if agent.permissions.hasCompanionProfile {
                // Somebody has looked at this agent and assigned it the right
                // profile. Whether it can actually write additionally depends on
                // owning a subject, which no unsigned caller can see — so this
                // says what is true and stops.
                Text("An administrator has given Mynah the companion profile. Saving also needs a "
                    + "subject of its own; this screen can't see who owns what, so the proof is "
                    + "whether new memories appear below.")
                    .mynahFont(.callout)
                    .foregroundStyle(Palette.ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if agent.memoryCount == 0 {
                // Nothing on the key explains it, and the *other* gate — the
                // per-agent subject allowlist — needs a signed request to read.
                // Naming it as unknown beats implying the key is the only thing
                // that can stop a write.
                Text("Nothing on Mynah's key is holding it back, and it hasn't saved anything yet. "
                    + "The other thing that can stop it is the list of subjects it's allowed to "
                    + "write, which this screen can't read.")
                    .mynahFont(.callout)
                    .foregroundStyle(Palette.ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // And when the key is clear and memories exist: nothing at all. No
            // badge, no tick, no "all good" row. This section exists to say the
            // one thing that is wrong; a permissions screen that congratulates
            // itself is a permissions screen people stop reading.
        }
        .padding(.vertical, readiness.headline == nil && agent.memoryCount > 0 ? 0 : s4)
    }

    private var reasons: some View {
        VStack(alignment: .leading, spacing: s3) {
            Text("What it can and can't do")
                .mynahFont(.label)
                .foregroundStyle(Palette.ink.secondary)
            // Reading is unaffected by every bit in the mask, and saying so is
            // the difference between "Mynah is broken" and "Mynah can't
            // remember this yet" — it still answers, and it still knows what it
            // knew.
            ForEach(["It can still read what it already knows."] + readiness.reasons, id: \.self) { line in
                HStack(alignment: .firstTextBaseline, spacing: s3) {
                    Text("·")
                        .mynahFont(.body)
                        .foregroundStyle(Palette.ink.quaternary)
                    Text(line)
                        .mynahFont(.callout)
                        .foregroundStyle(Palette.ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var footnotes: some View {
        VStack(alignment: .leading, spacing: s3) {
            Text(FederationHelp.looksOrdinaryButIsMuted)
                .mynahFont(.callout)
                .foregroundStyle(Palette.ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(FederationHelp.cannotFixItself)
                .mynahFont(.callout)
                .foregroundStyle(Palette.ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // The only number on the screen, and it is here because the person
            // who has to act on this is typing it into another product.
            Text(FederationHelp.companionPresetDetail)
                .mynahFont(.mono)
                .foregroundStyle(Palette.ink.secondary)
                .textSelection(.enabled)
        }
    }
}

// MARK: - What a scan found

private struct FederationFindings: View {
    let report: FederationReport

    var body: some View {
        VStack(alignment: .leading, spacing: s5) {
            ForEach(report.connections) { connection in
                VStack(alignment: .leading, spacing: s2) {
                    Text(connection.title)
                        .mynahFont(.bodyEmphasis)
                        .foregroundStyle(Palette.ink.primary)
                    Text(Self.shortened(connection.id))
                        .mynahFont(.mono)
                        .foregroundStyle(Palette.ink.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if !report.readableDomains.isEmpty {
                // The direction, stated the way the node states it: these are
                // their subjects that this Mac may read.
                findingList(title: "Subjects Mynah may read from them", values: report.readableDomains)
            }
            if !report.copyOfferedDomains.isEmpty {
                findingList(
                    title: "Subjects they have offered to copy over",
                    values: report.copyOfferedDomains
                )
            }
            if !report.remoteAgents.isEmpty {
                findingList(
                    title: "Agents they have told us about",
                    values: report.remoteAgents.map { agent in
                        agent.network.map { "\(agent.name) — \($0)" } ?? agent.name
                    }
                )
            }
        }
    }

    private func findingList(title: String, values: [String]) -> some View {
        VStack(alignment: .leading, spacing: s2) {
            Text(title)
                .mynahFont(.label)
                .foregroundStyle(Palette.ink.secondary)
            ForEach(values, id: \.self) { value in
                Text(value)
                    .mynahFont(.body)
                    .foregroundStyle(Palette.ink.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A chain id is machinery. Enough of it to tell two peers apart, and no
    /// more.
    static func shortened(_ id: String) -> String {
        id.count > 16 ? String(id.prefix(8)) + "…" + String(id.suffix(4)) : id
    }
}

// MARK: - Previews

/// Preview data, and the reason the seams exist. Nothing in the app constructs
/// these — the app's defaults are the real node.
struct PreviewAgentDirectory: AgentDirectorySource {
    var fixture: AgentRoster = .empty
    var trouble: AgentTrouble?

    func roster() async throws -> AgentRoster {
        if let trouble { throw trouble }
        return fixture
    }

    /// Shaped after this Mac's actual `GET /v1/agents`, counts included — down
    /// to the appliance's own row having stored nothing at all.
    static let realistic = AgentRoster(agents: [
        NodeAgent(
            id: "74140c",
            name: SageRitual.applianceDisplayName,
            role: "member",
            clearance: 1,
            memoryCount: 0,
            isActive: true,
            lastSeen: Date(timeIntervalSinceNow: -600),
            // The real mask this Mac's appliance carries: no shared writes, no
            // claim, no foreign writes, no federated routing.
            capabilities: 30,
            isThisAppliance: true
        ),
        NodeAgent(
            id: "9e6182",
            name: "Claude Code",
            role: "member",
            clearance: 1,
            memoryCount: 4_068,
            isActive: true,
            lastSeen: Date(timeIntervalSinceNow: -3_600),
            capabilities: 0,
            isThisAppliance: false
        ),
        NodeAgent(
            id: "4a6eda",
            name: "codex-sage",
            role: "member",
            clearance: 2,
            memoryCount: 1_558,
            isActive: true,
            lastSeen: nil,
            capabilities: 0,
            isThisAppliance: false
        ),
        NodeAgent(
            id: "b036b5",
            name: "macmini",
            role: "member",
            clearance: 3,
            memoryCount: 105,
            isActive: false,
            lastSeen: nil,
            capabilities: 0,
            isThisAppliance: false
        )
    ])
}

struct PreviewFederationScan: FederationScanning {
    var report: FederationReport = .init()
    var trouble: AgentTrouble?

    func scan() async throws -> FederationReport {
        if let trouble { throw trouble }
        return report
    }

    static let peer = FederationReport(
        connections: [FederatedSAGE(id: "sage-ana-9f2c1d7e4b12", networkName: "Ana's SAGE")],
        readableDomains: ["household", "travel-plans"],
        remoteAgents: [RemoteAgent(id: "r1", name: "Perplexity", network: "Ana's SAGE")]
    )
}

private struct AgentsPreviewPair: View {
    var source = PreviewAgentDirectory(fixture: PreviewAgentDirectory.realistic)
    var federation = PreviewFederationScan()

    var body: some View {
        HStack(spacing: 0) {
            AgentsView(source: source, federation: federation)
                .environment(\.colorScheme, .light)
            AgentsView(source: source, federation: federation)
                .environment(\.colorScheme, .dark)
        }
    }
}

#Preview("Agents — this Mac") {
    AgentsPreviewPair().frame(width: 1440, height: 900)
}

#Preview("Agents — a peer answered") {
    AgentsPreviewPair(federation: PreviewFederationScan(report: PreviewFederationScan.peer))
        .frame(width: 1440, height: 900)
}

#Preview("Agents — nobody registered") {
    AgentsPreviewPair(source: PreviewAgentDirectory())
        .frame(width: 1440, height: 900)
}

/// The state that must never read as "you have no agents".
#Preview("Agents — node locked") {
    AgentsPreviewPair(source: PreviewAgentDirectory(trouble: .locked))
        .frame(width: 1440, height: 900)
}

#Preview("Agents — node stopped") {
    AgentsPreviewPair(source: PreviewAgentDirectory(trouble: .unreachable))
        .frame(width: 1440, height: 900)
}
