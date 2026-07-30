import Foundation
import Observation
import OSLog
import SageVoiceCore
import SwiftUI

// MARK: - Who is on this node

private let agentsLog = MynahLog(category: "agents")

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

    /// Whether there is anybody on the other end.
    ///
    /// **`status: active` is a registration, not a heartbeat**, and building on
    /// it was the mistake the owner caught: *"that they are on the chain
    /// doesn't mean they're online and doesn't mean we can send them a message
    /// bro."* Checked against his node — **all twenty rows report `active`**,
    /// including three last seen 36, 88 and 89 days ago and two never seen at
    /// all. The field says enrolled and nothing else.
    ///
    /// `last_seen` is the field that means what `active` looks like it means,
    /// and it is already in the payload — this costs a reading, not a call.
    ///
    /// **Why it matters more than it looks.** `sage_pipe` queues into an inbox;
    /// SAGE's own words are that the target sees it *"on their next `sage_turn`
    /// or `sage_inbox` call"*. So a message to an agent last seen in April is
    /// accepted, delivered, and never read. Delivery is not receipt, and an
    /// interface that offers "Send a message" identically to both is promising
    /// a conversation with a gravestone.
    var activity: Activity {
        guard let lastSeen else { return .unknown }
        let days = Calendar.current.dateComponents([.day], from: lastSeen, to: .now).day ?? 0
        // **Seven days, and it is a judgement about his week rather than a
        // round number.** He works with several of these daily — three were
        // seen today on the node this was written against — so an agent absent
        // for longer than a working week has dropped out of what he is doing,
        // whatever it is still registered as. The boundary is deliberately
        // generous: calling something dormant that he used on Monday would be
        // the error that costs more.
        return days <= 7 ? .active(daysAgo: max(0, days)) : .dormant(daysAgo: days)
    }

    /// `thread`'s wording. **A fact, not a verdict** — "dormant" stays in the
    /// code and never reaches the owner. Their reasoning, which is the reason
    /// the seven-day constant stopped worrying me: show the age and the
    /// threshold decides only *emphasis*; show a label and it decides
    /// *information*, which is when a judgement call becomes load-bearing.
    ///
    /// "Never run" rather than "never seen" — he cares that it has not run, not
    /// that nobody observed it.
    /// **Optional, and the `nil` is the point.** When the node has no
    /// `last_seen` the card says nothing about recency rather than inventing
    /// "never run" — which was false for both rows that get it here.
    var recencyLine: String? {
        switch activity {
        case .active(let days), .dormant(let days):
            switch days {
            case 0: return "seen today"
            case 1: return "seen yesterday"
            default: return "seen \(days) days ago"
            }
        case .unknown:
            return nil
        }
    }

    /// Deliberately three cases rather than a `Bool`.
    ///
    /// **The third case used to be `neverSeen`, and calling it that was wrong.**
    /// It rendered as "never run", and on the owner's node the two rows that
    /// get it are:
    ///
    ///     macmini        role member  105 memories  last_seen absent
    ///     genesis-admin  role admin    74 memories  last_seen absent
    ///
    /// **An agent with 105 memories has demonstrably run.** `last_seen` means
    /// *last seen over MCP*, not *last active* — `genesis-admin` is the node
    /// operator key, and the owner acts as it through CEREBRUM's web interface,
    /// which never touches this field. So the roster was about to show the
    /// administrator its own remedy points at as the deadest thing on the page.
    ///
    /// Sixth time today a field has meant something narrower than its name and
    /// the interface read the name. So this one says **unknown** and the screen
    /// claims nothing: an absence must not be rendered as a measurement, which
    /// is the rule the old case name broke while quoting it.
    enum Activity: Equatable, Sendable {
        case active(daysAgo: Int)
        case dormant(daysAgo: Int)
        /// The node has no record of this agent connecting over MCP. It says
        /// nothing about whether the agent is doing anything.
        case unknown

        /// Whether a message sent now has somebody who will read it.
        var wouldBeRead: Bool {
            if case .active = self { return true }
            return false
        }
    }
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

    /// Whether this agent can send work to another agent at all.
    ///
    /// SAGE hands pipeline work only to an unrestricted, active, ordinary agent.
    /// A restricted key is refused outright — *"agent pipeline work is available
    /// only to an active ordinary agent on this SAGE"* — so this is what decides
    /// whether the roster has anybody in it.
    ///
    /// Deliberately keyed on the whole mask rather than the one `denyOtherSages`
    /// bit. That bit governs *federated* discovery and delivery, and the refusal
    /// the owner actually hit was broader than it: the node turned down a local
    /// inbox read as well. Reading the narrow bit would have this screen promising
    /// reach that SAGE has already denied in practice.
    var canReachOtherAgents: Bool { !isRestricted }

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

    /// The effective write answer for **any** agent on the node.
    ///
    /// The verb is "write", not "remember" and not "save", and that is a
    /// decision rather than a synonym. This line is rendered on every row,
    /// including other people's agents: "can remember what you tell it" is false
    /// of somebody else's research agent — the owner tells it nothing and its
    /// memory is not theirs — while "write" is what the mechanism is and what
    /// anybody reading a permissions table expects. `voice` made this argument
    /// and it is right; the appliance's own section speaks the memory verb
    /// instead, because there it *is* Mynah's memory being discussed with its
    /// owner.
    var writingLine: String {
        guard writesAreRestricted else { return "Can write memories." }
        return needsASubjectAssigned
            ? "Can't write anything until it's given a subject of its own."
            : "Can only write to a subject that belongs to it."
    }

    /// The effective read answer, and the reason this is a *standing fact*
    /// rather than a warning.
    ///
    /// Bit 1 is the only bit in the mask that grants rather than denies, and the
    /// Companion profile carries it: it lifts the domain and submitting-agent
    /// filters, so a companion reads across subjects it was never granted,
    /// bounded only by its clearance. On this owner's node that is nineteen
    /// other agents' subjects. Nothing the app says claims otherwise, but never
    /// saying it — and then falling silent entirely once the profile is assigned
    /// and the warning clears — is exactly the true-by-omission this screen
    /// exists to stop.
    /// **The second branch used to say "Only the subjects it's been given
    /// access to", and that reads as a restriction this appliance does not
    /// have.**
    ///
    /// The mask says nothing about reading — 30 is four write and pipe denials.
    /// Without bit 1 the ordinary rules apply, and the ordinary rule for an
    /// agent with an empty `DomainAccess` is no per-domain restriction at all.
    /// So absence of the bit is not evidence of a limit; it is the absence of a
    /// *lift*, and the app cannot see the grant list to tell which side of that
    /// this agent falls on.
    ///
    /// The owner disproved the old wording in one message: he asked Mynah what
    /// it had stored and it listed his subjects back, while this line said it
    /// could not see them.
    /// `thread`'s wording, and the change is which side of the line reading
    /// sits on.
    ///
    /// Both branches now describe *reach*, not permission. The earlier pair
    /// differed in kind — one said "every subject", the other "only what it has
    /// been given access to" — which made a grant look like the thing that
    /// makes reading possible. It is not. Bit 1 lifts discovery filters; its
    /// absence leaves the ordinary rules, and the ordinary rule for a `member`
    /// is that it reads what other active local members own.
    ///
    /// This branch renders on **every row**, which is why it was the worst
    /// instance of the false claim and the last one found.
    var readingLine: String {
        mask & Capability.readAcrossSubjects != 0
            ? "Every subject on this node, up to its clearance."
            : "Shared subjects, and anything it has been given access to."
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

    /// The agents Mynah can actually reach — which is the only set worth listing.
    ///
    /// **This page used to show the whole directory.** Twenty rows, sorted by
    /// size, regardless of whether Mynah could say a word to any of them. The
    /// owner's instruction was blunt and correct: *"the list should not populate
    /// based on ALL AGENTS IN THE DIRECTORY - only those that mynah can see AND
    /// talk to."* A list of names the appliance cannot reach is not a roster, it
    /// is a directory listing pretending to be one.
    ///
    /// **The gate is Mynah's own key, not each row's.** SAGE gives pipeline work
    /// only to an unrestricted, active, ordinary agent — the node's own words when
    /// it refuses are *"agent pipeline work is available only to an active
    /// ordinary agent on this SAGE"* — so a restricted appliance reaches nobody
    /// and the honest list is empty. It is not empty per-row for a different
    /// reason each time; one fact decides all of them.
    ///
    /// **Why not ask SAGE who is reachable:** `sage_find_agent` is the
    /// caller-scoped tool that would answer this properly, and on the owner's
    /// node it returns nothing at all — zero matches for `claude` with six
    /// `claude-code/*` agents registered, and zero for `mynah`, which is the
    /// example SAGE's own reference uses. Until that works, this derives what it
    /// can from the capability mask the roster already carries rather than
    /// inventing a reachability it cannot check.
    func reachable(fromAppliance appliance: NodeAgent?) -> [NodeAgent] {
        guard let appliance, appliance.permissions.canReachOtherAgents else { return [] }
        // Dormant is still reachable — a queued message is legitimate and the
        // agent reads it when it next runs. Only "never connected" is not.
        return others.filter { $0.isActive }
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
        // Not "Your node is locked", which this claimed and could not know.
        //
        // The roster comes from `GET /v1/agents` **unsigned**, so a 401 or 403
        // means the node declined an anonymous caller — not that anything is
        // sealed. Same door, same mistake and same day as the task board: an
        // app-level refusal described as a state of the owner's node, with
        // "unlock it in CEREBRUM" attached, sending him to fix something that
        // may be working perfectly. His was, throughout.
        case .locked: return "This window couldn't read the list."
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
            // The second half was already right — "this screen", not "Mynah" —
            // and it is the formulation the rest of the sweep was corrected to
            // match. What had to go is the instruction in front of it, which
            // asserted a lock nobody had established.
            return "Your agents are all still there. Your node declined this window's request, "
                + "and CEREBRUM can always show you the list."
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
            agentsLog.error("GET /v1/agents failed: \(String(describing: error))")
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
            agentsLog.error("GET /v1/agents returned \(http.statusCode)")
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
            agentsLog.error("sage_federation failed: \(String(describing: error))")
            switch error {
            case .missingExecutable: throw AgentTrouble.notSetUp
            case .toolFailed, .rpcError: throw AgentTrouble.refused
            case .malformedResponse: throw AgentTrouble.unreadable
            case .launchFailed, .notStarted, .serverExited, .timedOut:
                reset()
                throw AgentTrouble.unreachable
            }
        } catch {
            agentsLog.error("sage_federation failed: \(String(describing: error))")
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

    /// The one line above the roster, carrying both halves of the asymmetry.
    ///
    /// **Checked rather than assumed, which is the reason it can be this
    /// definite.** Sending needs no grant at all — a restricted key still has
    /// the local inbox, because mask bit 16 denies *federated* discovery and
    /// delivery and leaves local messaging untouched. Reading another agent's
    /// memories needs an explicit grant on its subjects, and org membership
    /// does not imply one. On this node no such grant exists, for any agent.
    ///
    /// Order matters: what Mynah *can* do comes first, so the line reads as a
    /// description rather than an apology. And it is written so the day a grant
    /// is finally made, the sentence stops being absolute rather than becoming
    /// false — "none has been given" is a fact about today that will read as
    /// stale rather than as a lie.
    /// **This said Mynah could not read what these agents remember. That was
    /// false, and the owner caught it by asking Mynah over Signal — it answered
    /// with a real inventory of his subjects while this line claimed it could
    /// not see them.**
    ///
    /// The mistake was mine to brief: `checkDomainAccess` does gate reads, but
    /// an agent whose `DomainAccess` is empty has no per-domain restriction at
    /// all, and the capability mask this appliance carries — 30 — is four
    /// *write* and *pipe* denials with nothing about reading in it. So the
    /// asymmetry is real and runs the other way: it reads freely and cannot
    /// write a word.
    /// **The fourth version, and the first anybody measured as the right
    /// identity.** Every earlier one was reasoned from something adjacent.
    ///
    /// `ApplianceReadReachProbe` signs with `MynahIdentity.applianceEnvironment()`
    /// — the appliance's own key — and answers the question directly:
    ///
    ///     READ general          ok — 2 of 897      (unowned)
    ///     READ sage-release     ok — 2 of 656      (unowned)
    ///     READ self             ok — 2 of  72      (unowned)
    ///     READ native-shell-ci  ok — 0 of   0      (owned by codex-sage)
    ///     READ voice-interface  ok — 0 of   0      (owned by genesis-admin)
    ///     READ <no filter>      ok — 0 of   0
    ///
    /// So it reads the parts of the node **no agent has claimed**, and gets
    /// nothing from a subject somebody owns. The last line is bit 1 doing what
    /// its source comment says — `ReadAllDomains` lifts *discovery* filters,
    /// mask 30 lacks it, so browsing without naming a subject returns nothing
    /// at all. That, and not a lock, is why the Memories page is empty.
    ///
    /// **The three wrong versions, because the pattern matters more than the
    /// sentence.** It first said Mynah could not read at all — reasoned from a
    /// capability mask. Then that it read everything — reasoned from
    /// `sage_status`, which returns ~700 subject names and their sizes to any
    /// signed caller and reads no content whatever; that table of contents is
    /// what Mynah recited to the owner and what we all took as proof it had
    /// read the book. Then that it read almost nothing — reasoned from
    /// `Access denied` replies that two of us collected **signed as our own
    /// keys rather than the appliance's**, which is the identity confusion this
    /// codebase has been chasing all day, arriving in the measuring instrument.
    ///
    /// **Ownership is the discriminator, and that was tested predictively
    /// rather than fitted.** `thread` flagged that five points fitting an
    /// explanation is not the explanation being true — which is precisely how
    /// the three wrong versions were written. So the hypothesis was taken from
    /// SAGE's own source, where `DenySharedDomainWrite` is documented as
    /// blocking writes to *"ownerless shared domains (general, self, meta,
    /// sage-*, and dynamic shared domains)"*, four predictions were written
    /// down, and then the probe was run:
    ///
    ///     meta             predicted open   → ok, 2 of 50
    ///     sage-federation  predicted open   → ok, 2 of 62
    ///     levelup-bugs     predicted closed → 0 of 0
    ///     quiettype-release predicted closed → 0 of 0
    ///
    /// Nine subjects, no exceptions. That is the first claim on this page all
    /// day that survived being told in advance what would falsify it.
    ///
    /// Written to age: "unless that agent shares it" is already true of a
    /// grant, so one landing makes this stale rather than false — it will
    /// understate Mynah, and understating is recoverable. Every version shipped
    /// today failed exactly that test. It claims nothing about *which* subjects
    /// have been shared, because the grant list is an operator view and no
    /// sentence here should imply this app can enumerate it.
    static let whatMynahMayDoWithTheseAgents =
        "Mynah can see every subject on this Mac — their names and how much is in each — "
            + "and can read the ones nobody owns. What another agent owns stays closed to "
            + "it unless that agent shares it."

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
    /// **The claim is true; its reason was not, and the reason is what taught
    /// the false lesson.**
    ///
    /// It said the grant list needs "a signed request", which reads as *Mynah
    /// is not signed* — and Mynah signs everything it does over MCP. That
    /// phrasing is the same conflation that put a false read claim on the
    /// roster and a locked vault on the task board: the *app* is the unsigned
    /// one, and three separate sentences quietly attributed its limitation to
    /// the appliance.
    ///
    /// The list genuinely is not reachable, for a different reason. Checked:
    /// `sage_scope_list` and `sage_scope_get` are app-v20 *quorum* scopes and
    /// are node-operator/admin only — they are not per-agent grants, and no MCP
    /// tool exposes those at all. So this is an operator view, like the task
    /// board, and it says so in the same words.
    static let grantsAreNotReadableHere = "Mynah can't read the grant list itself — that view "
        + "is operator-only. CEREBRUM shows it in full."

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
    /// **The one place in the owner-facing product where a mask number appears,
    /// and `chrome` was right to ask whether it belongs.** The rule it looks
    /// like it breaks is narrower than it sounds: no bit numbers *in sentences*,
    /// because "DenyDomainClaim (bit 4)" is a fact about a codebase nobody here
    /// will read. This is not a sentence and not a reason — it is SAGE's own
    /// identifier for the preset, quoted. Their reference calls it "the
    /// co-located voice/companion preset is mask 15", so somebody relaying this
    /// can match it against the platform's own words however that platform
    /// happens to present it. Naming the profile without its value would leave
    /// them guessing at exactly the moment they are acting on our say-so.
    ///
    /// It lost ", not a grant" after a render showed it wrapping to two lines
    /// inside the prose cap. The clause is made twice above it already — in the
    /// remedy and in the deny-foreign reason — so it was the cheapest thing to
    /// drop.
    static var companionPresetDetail: String {
        "companion profile · mask 15 · owns “\(SageRitual.memoryDomain)”"
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

    /// The roster is **not fetched here any more.** It comes from
    /// `ApplianceRoster`, filled once at app boot — the owner's ruling, and the
    /// reason is that this page used to read `GET /v1/agents` unsigned on every
    /// appearance. See that type for the whole argument.
    private let rosterStore: ApplianceRoster

    var phase: Phase {
        switch rosterStore.phase {
        // Boot has not run yet. Not `.ready`, because a screen that has not
        // asked must not answer — and not `.failed`, because nothing failed.
        case .notAsked, .loading: return .loading
        case .ready: return .ready
        case .unavailable(let trouble): return .failed(trouble)
        }
    }

    var roster: AgentRoster { rosterStore.roster }

    private(set) var scan: ScanPhase = .idle

    /// Subjects per agent, for the agents a node has actually answered about.
    ///
    /// Absent from this dictionary means "not answered", which is the ordinary
    /// case today and draws nothing. See `AgentSubjectSource`.
    private(set) var subjects: [String: [String]] = [:]

    private let federation: any FederationScanning
    private let subjectSource: any AgentSubjectSource

    init(
        rosterStore: ApplianceRoster? = nil,
        federation: any FederationScanning = SageFederationScan.shared,
        subjectSource: any AgentSubjectSource = UnaskableSubjects()
    ) {
        // Resolved here rather than as a default argument: `ApplianceRoster.shared`
        // is main-actor isolated and a default argument is evaluated in the
        // caller's context, which is not.
        self.rosterStore = rosterStore ?? .shared
        self.federation = federation
        self.subjectSource = subjectSource
    }

    /// Convenience for previews and tests that want a roster of their own
    /// without building a store around it.
    convenience init(
        source: any AgentDirectorySource,
        federation: any FederationScanning = SageFederationScan.shared,
        subjectSource: any AgentSubjectSource = UnaskableSubjects()
    ) {
        self.init(
            rosterStore: ApplianceRoster(source: source),
            federation: federation,
            subjectSource: subjectSource
        )
    }

    /// Asked for one agent at a time, when the owner selects it.
    ///
    /// Not fetched for the whole roster on load: twenty agents is twenty
    /// requests for something nineteen of them are not being looked at, and on
    /// every node shipping today all twenty would return nothing. The page is
    /// already drawn by the time this runs, so a slow or absent answer costs
    /// the owner nothing.
    func loadSubjects(forAgent id: String) async {
        guard subjects[id] == nil else { return }
        guard let found = await subjectSource.subjects(forAgent: id) else { return }
        subjects[id] = found
    }

    /// Makes sure the boot fetch has happened, and does nothing if it has.
    ///
    /// **Not a per-view read.** Opening this page a dozen times asks the node
    /// once. The only case that re-asks is a boot that failed — see
    /// `ApplianceRoster.loadOnce`.
    func load() async {
        await rosterStore.loadOnce()
    }

    /// The owner pressing "Try again" on the failure state.
    func retry() async {
        await rosterStore.reload()
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
            agentsLog.error("federation scan failed: \(String(describing: error))")
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
    /// Which agent's facts the right-hand pane is showing.
    ///
    /// Holds the *id* rather than the agent, because the roster is re-read and
    /// replaced wholesale: keeping a value would pin a stale copy and quietly
    /// stop updating the moment a poll landed.
    @State private var selectedID: String?

    /// Messaging is its own model because it fails on its own terms and must
    /// not take the roster down with it — same reason the network scan is
    /// separate. An inbox that cannot be read is not a roster that cannot be
    /// read, and one screen with one error state would conflate them.
    @State private var messaging = AgentMessagingModel(
        messaging: SageAgentMessaging(tools: ApplianceTools.shared)
    )

    /// Who the compose sheet is addressed to, or `nil` when it is closed.
    ///
    /// A wrapper rather than a bare `String` because `sheet(item:)` needs
    /// `Identifiable`, and an agent name is exactly the kind of value that
    /// should not silently become an identity.
    struct Recipient: Identifiable, Equatable {
        let name: String
        var id: String { name }
    }
    @State private var isWritingTo: Recipient?

    /// The roster column.
    ///
    /// Fixed rather than proportional. It holds one line of name and one of
    /// metadata, which does not get more readable with width — everything the
    /// extra room is worth goes to the detail pane, which holds sentences.
    /// 320 rather than 300, and the 20pt is a consequence rather than taste.
    /// Giving each row a leading kind mark cost it about 30pt of text width, and
    /// a render showed the metadata line wrapping — "member ·" on one line and
    /// "clearance 1 · 4,068 memories" on the next, in every row. A mark that
    /// makes the list scannable and then breaks the line under it has taken more
    /// than it gave.
    private static let rosterWidth: CGFloat = 320

    /// The shipping initialiser. **Takes no directory**, which is the point.
    ///
    /// It used to default `source:` to a live `NodeAgentDirectory`, so every
    /// `AgentsView()` built its own fetcher and read `GET /v1/agents` unsigned
    /// on every appearance. Moving the fetch to boot is worth nothing while the
    /// view can still open its own — so the default path now has no way to,
    /// and reaches the roster only through the store `RootView` fills at
    /// launch.
    ///
    /// ## A default argument that can build a real collaborator is a hidden constructor
    ///
    /// **This cost a day twice, and both times nothing failed.** In the
    /// morning, `AppModel.init` defaulted `backgroundServices` to the live
    /// manager, so tests about a pause marker deleted the owner's LaunchAgents
    /// and left his phone unanswered for an hour. In the afternoon, this
    /// initialiser defaulted `source` to a live directory, so the boot-time
    /// roster was wired, tested, green — and completely unused, with the
    /// per-view unsigned read exactly where it had always been.
    ///
    /// Neither was caught by a test. Both were caught by grepping for the type
    /// name afterwards, which is luck rather than method.
    ///
    /// The general form, worth more than either instance: **moving a dependency
    /// is not finished until the old path cannot be reached.** A default that
    /// can construct the real thing keeps the old path alive while looking like
    /// a convenience, and it survives exactly the review that reads the diff
    /// and sees a fetch move.
    ///
    /// `@MainActor` because `AgentsModel` is, and a `View`'s initialiser is not
    /// isolated by default even though SwiftUI only ever calls it here.
    @MainActor
    init(federation: any FederationScanning = SageFederationScan.shared) {
        _model = State(initialValue: AgentsModel(federation: federation))
    }

    /// Previews and tests, which want a roster of their own and no node.
    @MainActor
    init(source: any AgentDirectorySource, federation: any FederationScanning) {
        _model = State(initialValue: AgentsModel(source: source, federation: federation))
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Palette.surface.canvas)
            .task { await model.load() }
            // Mynah's own row is what the owner came to look at, so it is
            // selected the moment the roster arrives. Only ever fills an *empty*
            // selection: re-selecting on every poll would drag the owner off
            // whatever row they had clicked, every thirty seconds.
            .onChange(of: model.roster) { _, roster in
                if selectedID == nil { selectedID = roster.appliance?.id ?? roster.agents.first?.id }
            }
            // Asked per selection rather than for the whole roster, and after
            // the pane is already drawn. On every node shipping today this
            // returns nothing and draws nothing, so it must not be on the path
            // to seeing anything else.
            .task(id: selectedAgent?.id) {
                guard let id = selectedAgent?.id else { return }
                await model.loadSubjects(forAgent: id)
            }
            // Asked when the owner opens the page, never on a timer — see
            // `AgentMessaging`. A background poll against a node that may
            // refuse is a retry storm the owner generates by leaving a window
            // open.
            .task { await messaging.refreshInbox() }
            .sheet(item: $isWritingTo) { recipient in
                AgentMessageSheet(
                    agentName: recipient.name,
                    onClose: { isWritingTo = nil },
                    model: messaging
                )
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            // Nothing at all, on purpose. This is one local HTTP call, and a
            // breathing indicator on every visit is an appliance asking to be
            // watched.
            Color.clear

        case .failed(let trouble):
            // Full width, not in a column: with no roster there is no
            // master–detail to draw, and a failure squeezed into a 300pt gutter
            // reads as a footnote rather than the reason the screen is empty.
            centred {
                EmptyState(
                    glyph: "person.2",
                    title: trouble.headline,
                    message: trouble.explanation,
                    actionTitle: trouble.isWorthRetrying ? "Try again" : nil,
                    action: trouble.isWorthRetrying ? { Task { await model.retry() } } : nil
                )
            }

        case .ready:
            if model.roster.agents.isEmpty {
                centred {
                    EmptyState(
                        glyph: "person.2",
                        title: "Nobody is registered yet",
                        message: "Agents appear here the first time they connect to the SAGE on "
                            + "this Mac. Mynah registers itself the first time you talk to it."
                    )
                }
            } else {
                masterDetail
            }
        }
    }

    private func centred<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            content()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, s8)
    }

    /// Roster on the left, the selected agent on the right.
    ///
    /// An `HStack` with an explicit width rather than `HSplitView`, for two
    /// reasons that both come down to being able to check the work: a split view
    /// is AppKit-backed, so it will not draw in an `ImageRenderer` harness and
    /// nobody can look at this layout before it ships; and this pane already
    /// lives inside the shell's `NavigationSplitView`, where nesting another
    /// one is a good way to get two draggable dividers arguing about the same
    /// pixels.
    private var masterDetail: some View {
        HStack(spacing: 0) {
            rosterColumn
                .frame(width: Self.rosterWidth)
            Rectangle()
                .fill(Palette.line.divider)
                .frame(width: 1)
            detailColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    // MARK: The roster

    /// Only what Mynah can reach. See `AgentRoster.reachable`.
    private var reachableAgents: [NodeAgent] {
        model.roster.reachable(fromAppliance: model.roster.appliance)
    }

    private var rosterColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            columnHeader("On this Mac", count: reachableAgents.isEmpty ? nil : reachableAgents.count)
            // **No paragraph here any more.** There were two, and both are gone.
            //
            // The first explained subject ownership above a list of names, which
            // is a lecture on another product's permission model delivered to
            // somebody who opened a screen to see who is on their Mac. The
            // owner's verdict on this page was that it "says wayyyyyyy too much
            // nonsense the user doesn't need to know about", and this was the
            // largest single piece of it.
            //
            // What replaced it is not shorter prose but a shorter *list*: the
            // rows are now only agents Mynah can reach, so the asymmetry the
            // paragraph existed to explain no longer needs explaining. When the
            // list cannot be populated, one line says so and offers the fix.
            ScrollView {
                // Spacing between rows rather than none. Rows that touch read as
                // a table; rows with air between them read as a list of things,
                // which is what they are — and each one now carries its own
                // bounded shape rather than sharing an edge with its neighbour.
                LazyVStack(alignment: .leading, spacing: s2) {
                    // The appliance first and always, whatever it has stored.
                    // It is the row the owner opened this screen for, and
                    // sorting it in by memory count would bury it at the bottom
                    // precisely when it has none — which is the case that
                    // matters.
                    if let appliance = model.roster.appliance {
                        row(appliance)
                    }
                    ForEach(reachableAgents) { agent in
                        row(agent)
                    }
                    if reachableAgents.isEmpty { noReachableAgents }
                }
                .padding(.horizontal, s5)
                .padding(.bottom, s5)
            }
            .scrollBounceBehavior(.basedOnSize)
            Spacer(minLength: 0)
            MynahDivider()
            network
        }
    }

    /// What stands in for the list when Mynah cannot reach anybody.
    ///
    /// One sentence and the consequence, in the owner's terms. It names the same
    /// cause as the warning in the detail pane rather than a second one, because
    /// there is only one thing wrong and two descriptions of it would read as two
    /// problems.
    private var noReachableAgents: some View {
        VStack(alignment: .leading, spacing: s2) {
            Text("No other agents yet")
                .mynahFont(.bodyEmphasis)
                .foregroundStyle(Palette.ink.primary)
            Text("Mynah can't reach any of the other agents on this Mac until it has its "
                + "own memory. They'll appear here once it does.")
                .mynahFont(.label)
                .foregroundStyle(Palette.ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, s4)
        .padding(.vertical, s4)
    }

    private func row(_ agent: NodeAgent) -> some View {
        AgentListRow(agent: agent, isSelected: agent.id == selectedID)
            .contentShape(Rectangle())
            .onTapGesture { selectedID = agent.id }
    }

    private func columnHeader(_ title: String, count: Int?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: s3) {
            Text(title)
                .mynahFont(.eyebrow)
                .foregroundStyle(Palette.ink.secondary)
                .accessibilityAddTraits(.isHeader)
            if let count {
                Text("\(count)")
                    .mynahFont(.mono)
                    .monospacedDigit()
                    .foregroundStyle(Palette.ink.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, s6)
        .padding(.top, s6)
        .padding(.bottom, s4)
    }

    // MARK: The detail

    @ViewBuilder
    private var detailColumn: some View {
        if let agent = selectedAgent {
            ScrollView {
                VStack(alignment: .leading, spacing: s6) {
                    detailHeading(agent)
                    subjectPills(agent)
                    StandingFacts(agent: agent)
                    if agent.isThisAppliance {
                        ApplianceStanding(agent: agent)
                    } else {
                        otherAgentStanding(agent)
                        sendRow(agent)
                    }
                    AgentInboxSection(model: messaging)
                    joining
                }
                .frame(maxWidth: MynahWidth.prose + s9, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, s8)
                .padding(.vertical, s7)
            }
            .scrollBounceBehavior(.basedOnSize)
        } else {
            // Only reachable in the instant between the roster arriving and the
            // default selection landing.
            Color.clear
        }
    }

    /// The subjects this agent can reach, when the node has said.
    ///
    /// **Nothing at all when it has not**, which is every node shipping today.
    /// No placeholder, no "unknown", no spinner — see `AgentSubjectSource` for
    /// why those are three ways of drawing a fact the app does not have. The
    /// section simply is not there, and the pane above and below it closes up.
    @ViewBuilder
    private func subjectPills(_ agent: NodeAgent) -> some View {
        if let subjects = model.subjects[agent.id], !subjects.isEmpty {
            VStack(alignment: .leading, spacing: s3) {
                Text("Can reach")
                    .mynahFont(.eyebrow)
                    .foregroundStyle(Palette.ink.secondary)
                    .accessibilityAddTraits(.isHeader)
                // Wraps rather than scrolls: an agent with many subjects should
                // get taller, not hide the rest behind a gesture nobody knows
                // is available.
                FlowLayout(spacing: s2) {
                    ForEach(subjects, id: \.self) { subject in
                        Text(subject)
                            .mynahFont(.label)
                            .foregroundStyle(Palette.ink.primary)
                            .padding(.horizontal, s3)
                            .padding(.vertical, 3)
                            .background(Palette.surface.well, in: RoundedRectangle.mynah(r.chip))
                            .mynahBorder(r.chip)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Can reach \(subjects.joined(separator: ", "))")
        }
    }

    /// Writing to somebody else's agent.
    ///
    /// Absent on Mynah's own row rather than present and disabled: sending
    /// yourself a pipeline message is not a thing the owner wants, and a
    /// greyed-out button is a verb that leads nowhere — which every escape
    /// hatch in this app is written not to be.
    ///
    /// The recipient is the roster's *name*, so the ordinary path cannot
    /// misspell an agent into `noSuchAgent`. It still resolves through
    /// `findAgent`, because a display name and a wire address are different
    /// things and only the node maps between them.
    private func sendRow(_ agent: NodeAgent) -> some View {
        VStack(alignment: .leading, spacing: s3) {
            MynahButton(sendVerb(agent), kind: .secondary) {
                isWritingTo = Recipient(name: agent.name)
            }
            Text(sendNote(agent))
                .mynahFont(.label)
                .foregroundStyle(Palette.ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// **The verb carries it, not the state of the button.** `thread`'s design,
    /// and the register team-lead asked for: not the same act, not a broken
    /// one.
    ///
    /// The button stays live in all three cases. A queued message to a dormant
    /// agent is legitimate and he may well want to leave one — `sage_pipe`
    /// accepts it and the agent reads it whenever it next runs. Disabling would
    /// be the interface refusing something the transport allows.
    ///
    /// What it must not do is look identical for an agent seen today and one
    /// last seen in April. "Leave a message" is the honest description of
    /// posting into a queue nobody is currently reading, and it is a normal
    /// thing a person does willingly.
    private func sendVerb(_ agent: NodeAgent) -> String {
        agent.activity.wouldBeRead ? "Send" : "Leave a message"
    }

    /// The helper under it, which is the same mechanism stated calmly in all
    /// three cases rather than reassurance in one and a warning in the others.
    ///
    /// **Delivery is never receipt** — `sage_pipe` queues, and SAGE's own words
    /// are that the target sees it *"on their next `sage_turn` or `sage_inbox`
    /// call"*. An agent seen today is a better bet, not a different guarantee,
    /// and the active line says so rather than promising anything.
    private func sendNote(_ agent: NodeAgent) -> String {
        switch agent.activity {
        case .active:
            return "It picks up messages when it next runs."
        case .dormant:
            let seen = agent.recencyLine ?? "Not seen recently"
            return "\(seen.prefix(1).uppercased())\(seen.dropFirst()). "
                + "This waits in its inbox until it runs again."
        case .unknown:
            // Says what is true — the message queues — and nothing about the
            // agent, because there is nothing true to say. "This one has never
            // run" was here and it was false of both rows that reach it.
            return "Your node has no record of this one connecting. The message waits in its "
                + "inbox either way."
        }
    }

    private var selectedAgent: NodeAgent? {
        guard let selectedID else { return model.roster.appliance }
        return model.roster.agents.first { $0.id == selectedID } ?? model.roster.appliance
    }

    private func detailHeading(_ agent: NodeAgent) -> some View {
        VStack(alignment: .leading, spacing: s2) {
            Text(agent.name)
                .mynahFont(.title2)
                .foregroundStyle(Palette.ink.primary)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: s3) {
                Text(agent.standingLine)
                    .mynahFont(.label)
                    .foregroundStyle(Palette.ink.secondary)
                Text("·")
                    .mynahFont(.label)
                    .foregroundStyle(Palette.ink.quaternary)
                Text(agent.memoryLine)
                    .mynahFont(.label)
                    .foregroundStyle(
                        Palette.ink.secondary
                    )
                if !agent.isActive { StatusPill("Inactive", tone: .neutral) }
            }
        }
    }

    /// What this screen can and cannot say about somebody else's agent.
    ///
    /// Short by construction. The grant list needs a signed request, so for any
    /// agent but the appliance the honest answer is the mask and nothing more —
    /// and the mask is usually empty, which is worth one sentence rather than a
    /// section.
    @ViewBuilder
    private func otherAgentStanding(_ agent: NodeAgent) -> some View {
        VStack(alignment: .leading, spacing: s4) {
            // One short line, and only when there is something to say. The
            // unrestricted case used to get a sentence about grants and subjects
            // that told the owner nothing actionable about an agent they do not
            // administer.
            if agent.permissions.isRestricted {
                Text("SAGE has restricted this agent. Only an administrator can change that.")
                    .mynahFont(.callout)
                    .foregroundStyle(Palette.ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: The network

    /// The owner's button, at the foot of the roster because it answers the same
    /// question the roster does — who is out there — for a different somewhere.
    /// Nothing it finds is on this Mac, which the copy says.
    private var network: some View {
        VStack(alignment: .leading, spacing: s4) {
            MynahButton(
                model.scan == .scanning ? "Looking…" : "Look for agents on your network",
                kind: .secondary,
                isEnabled: model.scan != .scanning
            ) {
                Task { await model.lookForAgents() }
            }
            scanResult
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, s6)
        .padding(.vertical, s5)
    }

    @ViewBuilder
    private var scanResult: some View {
        switch model.scan {
        case .idle:
            // Nothing. "Asks your node which other SAGEs it can reach. It
            // changes nothing." was reassurance for a worry the button does not
            // create, under a button whose label already says what it does.
            EmptyView()

        case .scanning:
            Text("Asking your node…")
                .mynahFont(.label)
                .foregroundStyle(Palette.ink.secondary)

        case .failed(let trouble):
            VStack(alignment: .leading, spacing: s3) {
                Text(trouble.headline)
                    .mynahFont(.label)
                    .foregroundStyle(Palette.ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if trouble.isWorthRetrying {
                    MynahButton("Try again", kind: .quiet) {
                        Task { await model.lookForAgents() }
                    }
                    .padding(.leading, -s3)
                }
            }

        case .found(let report):
            if report.foundNothing {
                // True and unalarming. Nothing is shared in either direction,
                // which for most owners is both correct and what they want.
                Text("No other SAGEs answered. Nothing is shared with anyone else, and nothing "
                    + "of theirs is readable from here.")
                    .mynahFont(.label)
                    .foregroundStyle(Palette.ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                FederationFindings(report: report)
            }
        }
    }

    // MARK: Getting another agent here

    /// Behind a disclosure, closed by default.
    ///
    /// It is reference material — three steps and three permission levels — and
    /// it was previously the tallest thing on the screen, sitting under every
    /// visit whether or not anybody was adding an agent. Reachable in one click
    /// and out of the way otherwise.
    private var joining: some View {
        DisclosureGroup("Adding another agent") {
            VStack(alignment: .leading, spacing: s5) {
                NumberedStepList(steps: FederationHelp.steps)
                Text(FederationHelp.admin)
                    .mynahFont(.callout)
                    .foregroundStyle(Palette.ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(FederationHelp.levels, id: \.name) { level in
                    VStack(alignment: .leading, spacing: s1) {
                        Text(level.name)
                            .mynahFont(.bodyEmphasis)
                            .foregroundStyle(Palette.ink.primary)
                        Text(level.meaning)
                            .mynahFont(.callout)
                            .foregroundStyle(Palette.ink.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text(FederationHelp.grantsDoNotLiftRestrictions)
                    .mynahFont(.callout)
                    .foregroundStyle(Palette.ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(FederationHelp.grantsAreReal)
                    .mynahFont(.callout)
                    .foregroundStyle(Palette.ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, s4)
        }
        .mynahFont(.title3)
        .foregroundStyle(Palette.ink.primary)
        .padding(.top, s5)
    }
}

// MARK: - One row in the roster

/// Name, then everything else on one metadata line.
///
/// It was three stacked paragraphs in a card — table data set as prose, which is
/// what made this pane read like a web page. What survives the compression is
/// the pair that carries the whole point of the screen: the `Restricted` pill
/// and the caution-ink memory count. Those are the *only* visible difference
/// between an agent that works and one that is silently muted, and a density
/// pass that quietly ate them would have removed the reason this screen exists.
private struct AgentListRow: View {
    let agent: NodeAgent
    let isSelected: Bool

    @State private var isHovering = false

    var body: some View {
        // A mark, then the words. Twenty rows of name-over-metadata with no
        // marks and no edges is a table, which is what the owner called it. The
        // glyph also carries the distinction the list was not making: Mynah's
        // own row is not the same kind of thing as an agent somebody installed,
        // and an administrator is not the same kind as a member.
        HStack(alignment: .top, spacing: s2) {
            kindMark
                .frame(width: 18, alignment: .center)
                .padding(.top, 1)
            rowText
        }
        .padding(.horizontal, s4)
        .padding(.vertical, s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background, in: RoundedRectangle.mynah(r.control))
        .overlay {
            // An edge on every row, not only the selected one. Without it the
            // unselected rows have no shape at all and the selection looks like
            // the only object on the list rather than the chosen one.
            RoundedRectangle.mynah(r.control)
                .strokeBorder(
                    isSelected ? Palette.accent.fill.opacity(0.55) : Palette.line.hairline,
                    lineWidth: 1
                )
        }
        .mynahAnimation(Motion.fade, value: isSelected)
        .mynahAnimation(Motion.fade, value: isHovering)
        .onHover { isHovering = $0 }
        .pointingHandCursor()
        .accessibilityElement(children: .combine)
        // The dot is invisible to VoiceOver, so the word goes in the label —
        // the one place where the pill's text still has to exist for a row.
        .accessibilityLabel(
            "\(agent.name). \(agent.recencyLine.map { $0 + ". " } ?? "")"
                + "\(agent.standingLine). \(agent.memoryLine)."
                + (agent.permissions.isRestricted ? " Restricted." : "")
        )
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// What kind of thing this row is.
    ///
    /// Mynah's own row gets the app's own mark — the same bird as the Dock icon
    /// and the sidebar — because "which of these is me" is the first question
    /// the list has to answer and a name is a slower way to answer it than a
    /// picture. An administrator gets a key, which is literal rather than
    /// decorative: holding admin on this node is precisely the power to grant.
    /// Everyone else is a person, because that is how the owner talks about them
    /// — "ask Perplexity" — and it matches the sidebar glyph for this screen.
    @ViewBuilder
    private var kindMark: some View {
        if agent.isThisAppliance {
            MynahMark(side: 20)
        } else {
            Image(systemName: agent.role == "admin" ? "key" : "person")
                .mynahIcon(.row)
                .foregroundStyle(Palette.ink.secondary)
        }
    }

    private var rowText: some View {
        VStack(alignment: .leading, spacing: s1) {
            // The name gets the whole width. It shared the line with the
            // `Restricted` pill until a render showed what that costs: at 300pt
            // "Mynah - Sage Voice Bridge" came out as "Mynah -…oice Bridge",
            // truncating the one word that identifies it. Tail truncation, not
            // middle — middle is for paths and ids, where the end carries the
            // meaning; in a name the beginning does.
            HStack(spacing: s3) {
                Text(agent.name)
                    .mynahFont(.body)
                    .foregroundStyle(Palette.ink.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                // A dot, not the `Restricted` pill. The pill is the right
                // component and it does not fit: at 300pt beside the metadata it
                // wrapped and hyphenated itself to "Restrict / ed", and beside
                // the name it truncated the name. A 6pt caution dot costs ten
                // points, never wraps, and pairs with the caution-ink count
                // below it — two marks that say the same thing in a place the
                // eye already scans. The word itself survives in the detail
                // pane, where there is room for it.
                if agent.permissions.isRestricted {
                    StatusDot(.neutral)
                }
                Spacer(minLength: 0)
            }
            // Both marks on one line, which is also where they belong: the pill
            // and the caution-ink count are the two halves of one fact — this
            // agent is muted — and they now sit together instead of at opposite
            // corners of the row.
            // **Recency and volume, and role and clearance moved out.**
            //
            // `thread`'s call, and the reason is what a card is for: these two
            // answer "is this thing alive, and does it know anything", which is
            // what he is deciding at a glance. Role and clearance are RBAC
            // facts that mean little at this size and now live in the detail
            // pane, where there is room to say what they imply.
            //
            // A fourth fact was not an option — at 300pt the last addition to
            // this line hyphenated `Restricted` into "Restrict / ed".
            HStack(spacing: s2) {
                // Absent rather than "never run" when the node has no record.
                // A row that says nothing about recency is a row making no
                // claim, which is the honest state for an agent whose work
                // never goes through this channel.
                if let recency = agent.recencyLine {
                    Text(recency)
                        .mynahFont(.label)
                        .foregroundStyle(Palette.ink.secondary)
                        .lineLimit(1)
                    Text("·")
                        .mynahFont(.label)
                        .foregroundStyle(Palette.ink.quaternary)
                }
                Text(agent.memoryLine)
                    .mynahFont(.label)
                    .foregroundStyle(
                        Palette.ink.secondary
                    )
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
    }

    /// Selection takes the accent wash, which is what `OptionCard` uses for the
    /// same job — the one live thing on the screen is the row being read.
    ///
    /// Unselected rows are `surface.raised` rather than clear. On the canvas
    /// that is a card, and a card is a thing; clear was what made twenty of them
    /// a table.
    private var background: Color {
        if isSelected { return Palette.accent.wash }
        return isHovering ? Palette.surface.well : Palette.surface.raised
    }
}

// MARK: - What an agent can read and write

/// The standing facts, for whichever agent is selected.
///
/// Internal rather than private, and deliberately: this and `ApplianceStanding`
/// are pure SwiftUI, so a throwaway `ImageRenderer` harness can compose them and
/// draw the real thing rather than a lookalike. That is how the roster's
/// truncated name and the hyphenated "Restrict / ed" pill were found — neither
/// was visible in the code, and both were obvious in a PNG. `AgentListRow` stays
/// private because it carries `.pointingHandCursor()`, which is AppKit-backed
/// and refuses to render either way.
///
/// Always present, never in alarm ink, and unchanged by whether anything is
/// wrong. The warning below can clear; these cannot, because "what can it read"
/// stays a fact about the owner's machine after somebody has fixed the
/// permissions — and the Companion profile in particular *widens* reading, which
/// is the moment it most needs saying.
struct StandingFacts: View {
    let agent: NodeAgent

    var body: some View {
        VStack(alignment: .leading, spacing: s3) {
            fact("Can read", agent.permissions.readingLine)
            fact(agent.isThisAppliance ? "Can remember" : "Can write", writeLine)
        }
    }

    /// The appliance speaks the memory verb, because there it is Mynah's memory
    /// being discussed with its owner. Any other agent gets the permissions-table
    /// verb: "can remember what you tell it" is false of somebody else's research
    /// agent, which the owner tells nothing.
    private var writeLine: String {
        guard agent.isThisAppliance else { return agent.permissions.writingLine }
        guard agent.permissions.writesAreRestricted else { return "What you tell it." }
        return agent.permissions.needsASubjectAssigned
            ? "Nothing yet — it needs a subject of its own first."
            : "Only into a subject that already belongs to it."
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: s4) {
            Text(label)
                .mynahFont(.label)
                .foregroundStyle(Palette.ink.secondary)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .mynahFont(.callout)
                .foregroundStyle(Palette.ink.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}

// MARK: - What Mynah itself can do

/// The appliance's own standing: the warning when there is one, why, who has to
/// change it, and the notes a boot line has no room for.
///
/// Shaped as SAGE's own team described the direction — "the UI shows the
/// effective result — can read / can write / why denied — instead of exposing
/// five cryptic checkboxes as the primary control". The read/write half is
/// `StandingFacts` above; this is the "why denied" half, and it is the only part
/// that disappears when somebody has configured the agent correctly.
struct ApplianceStanding: View {
    let agent: NodeAgent

    /// The same value the boot check and the setup flow render, built from the
    /// row this screen already has rather than by asking the node twice.
    ///
    /// Sharing the *type* rather than the sentences is what keeps one mechanism
    /// from acquiring two explanations: `headline`, `reasons` and `remedy` are
    /// `voice`'s strings, so an owner who meets this at boot and again here
    /// reads the same words both times.
    private var readiness: ApplianceWriteReadiness {
        ApplianceWriteReadiness(agentID: agent.id, standing: .registered(mask: agent.capabilities))
    }

    /// `nil` is passed for the observed refusal because `ConversationModel.ritual`
    /// is private, so no view can reach `SageRitual.writeDenial` yet. That is the
    /// predictive half and it is exactly what this screen already did — when the
    /// denial is exposed, this argument is the only line that changes, and the
    /// page starts quoting what consensus actually said instead of inferring
    /// from a mask.
    private var status: ApplianceMemoryStatus? {
        readiness.status(observing: nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: s5) {
            if let status {
                // **Critical tone, because this is not working.** It was drawn in
                // the same neutral grey as ordinary information, and the owner's
                // objection was exactly that: *"its not clear things aren't
                // working atm fully"*. Mynah cannot remember a word in this
                // state — that is a failure, not a note.
                InlineBanner(
                    tone: .critical,
                    headline: status.headline,
                    explanation: shortRemedy
                )
                // Who has to act, in one line, immediately under it. Everything
                // else that used to sit here — the "Why" bullets, the note that
                // its role looks ordinary, the mask, the grant-list aside — is
                // gone from the front of the screen. It was four sections
                // explaining a permission model to somebody who needs to know one
                // thing: what to do, and who does it.
                whoToAsk
                administratorDetail
            } else if agent.permissions.hasCompanionProfile {
                // Somebody has looked at this agent and assigned it the right
                // profile. Whether it can actually write additionally depends on
                // owning a subject, which no unsigned caller can see — so this
                // says what is true and stops.
                note("An administrator has given Mynah the companion profile. Remembering also "
                    + "needs a subject of its own; this screen can't see who owns what, so the "
                    + "proof is whether new memories appear.")
            } else if agent.memoryCount == 0 {
                // Nothing on the key explains it, and the *other* gate — the
                // per-agent subject allowlist — needs a signed request to read.
                // Naming it as unknown beats implying the key is the only thing
                // that can stop a write.
                note("Nothing on Mynah's key is holding it back, and it hasn't remembered "
                    + "anything yet. The other thing that can stop it is the list of subjects "
                    + "it's allowed to write, which this screen can't read.")
            }
            // Beyond that, nothing. No badge, no tick, no "all good" row: the
            // *warning* disappears when somebody has configured this correctly.
            // The facts above it do not.
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .mynahFont(.callout)
            .foregroundStyle(Palette.ink.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The action, in two sentences, replacing a seven-line paragraph.
    ///
    /// The full remedy named CEREBRUM, the companion profile, the subject to
    /// assign, why an access grant will not do instead, and what changes on the
    /// Memories page afterwards. Every clause was true and the owner could not use
    /// any of it: the useful part is *what has to happen* and *that it is not
    /// something Mynah or this app can do*. The specifics an administrator needs
    /// are still on the screen, one disclosure away.
    private var shortRemedy: String {
        "Mynah needs its own memory before it can remember anything or reach the other "
            + "agents here. Somebody with administrator access to SAGE has to set that up — "
            + "Mynah can't do it itself, and neither can this app."
    }

    /// The exact words for whoever administers the node, closed by default.
    ///
    /// **Kept, but moved.** This is the one place a mask number appears in the
    /// owner-facing product, and it earns its place: the person acting on this is
    /// typing it into another product, and naming the profile without its value
    /// leaves them guessing at the moment they act on our say-so. What it must not
    /// be is the fifth paragraph of a wall the owner has to read past.
    private var administratorDetail: some View {
        DisclosureGroup("Details for your administrator") {
            VStack(alignment: .leading, spacing: s3) {
                Text(FederationHelp.companionPresetDetail)
                    .mynahFont(.mono)
                    .foregroundStyle(Palette.ink.secondary)
                    .textSelection(.enabled)
                // SAGE's own sentence about the refusal, when there has been one.
                // Never paraphrased, and visibly the node speaking rather than us.
                if let detail = status?.detail {
                    Text(detail)
                        .mynahFont(.callout)
                        .foregroundStyle(Palette.ink.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, s3)
        }
        .mynahFont(.label)
        .foregroundStyle(Palette.ink.secondary)
    }

    /// Who has to make the change — the one thing that genuinely differs by how
    /// SAGE got onto this Mac.
    ///
    /// **A description of today, not an architecture.** On the bundled SAGE the
    /// two install paths do not differ in Mynah's standing at all: a
    /// self-registered key gets the same mask either way, `role=admin` is
    /// downgraded to `member` at registration, and the mask is enforced with no
    /// admin exemption — so a nominally root agent still cannot write a word.
    /// What differs is only who the owner has to ask. When app-v23 ships and the
    /// bundled node is re-vendored, genesis provisions the Companion profile and
    /// a home subject before anybody sees a screen, and the vendored branch here
    /// stops being reachable — delete it then rather than preserving it.
    @ViewBuilder
    private var whoToAsk: some View {
        if let node = SageNodeChoice.resolve(vendored: SageNodeLocator.vendoredExecutableURL()) {
            note(node.isTheOwners
                 ? "Mynah is a guest on the SAGE that was already on this Mac, so whoever "
                    + "administers that node is who makes this change."
                 : "This Mac had no SAGE, so Mynah brought one. The node is yours and its "
                    + "administrator key is on this Mac — there is nobody else to ask.")
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
