// The agents on this node, as data.
//
// **There is no Agents screen any more.** CEREBRUM already does agent viewing,
// management and permissions properly, so a second worse copy inside a voice
// appliance was a surface with no purpose. What survived the deletion is only
// what still has a reader: `ApplianceRoster` needs to know whether Mynah itself
// is registered and what its key allows, and the Memories page needs that
// answer too.
//
// So this file is a model with no view. Everything owner-facing that used to
// live below — the permission explanations, the roster screen, the standing
// panels, the network scan results — went with the panel.

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
/// `/v1/access/grants/{agent_id}` answers 401 as well.
///
/// **`/v1/agents` is not public either, and that was believed until 1.7.5.**
/// Measured on the owner's node on 5 August 2026: `GET /v1/agents` → `401
/// Missing authentication headers`; only `/health` and `/ready` answer unsigned.
/// The route sits inside the group that applies `Ed25519AuthMiddleware` and is
/// wrapped in `appV23PipelineAgentBoundary`, which 403s any non-active caller.
///
/// It very likely *was* public when this comment was written and the boundary
/// closed underneath it. Either way, "the whole screen is built on what a locked
/// node will still say" is no longer true of this type, and
/// `ApplianceWriteReadinessCheck` — which was built on the same belief — silently
/// reported "I don't know" for every launch until it was moved to a signed
/// `sage_status`. `MCPAgentDirectory` is what the Agents page actually uses; this
/// supplies candidate names to it and nothing the page claims rests on it.
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
