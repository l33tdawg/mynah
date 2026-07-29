import Foundation

/// Whether Mynah can save anything, asked *before* it tries.
///
/// ## Why this exists
///
/// The appliance stored zero memories on the author's node for the entire life
/// of an identity, and said nothing about it. Every screen showed "nothing
/// stored yet", which is the same thing a brand-new install says, so the fault
/// was indistinguishable from being new. It was found by reading the chain, not
/// by using the product.
///
/// The cause was not a bug in this codebase. Under app-v22 SAGE gives any key
/// that self-registers a fail-closed capability mask — `30`, denying writes to
/// shared domains, denying claiming a domain, and denying writing a domain
/// owned by anyone else. The appliance was refused on every route, and the only
/// remedy is an administrator's decision in CEREBRUM.
///
/// So the appliance can, and therefore must, find this out for itself. The mask
/// is readable without authentication from `GET /v1/agents`, which means Mynah
/// can know at boot that it will not be able to save a word — before the owner
/// spends a week telling it things it silently discards.
///
/// ## What it deliberately does not do
///
/// It does not attempt a write to find out. A probe write is a real consensus
/// transaction on the owner's node, and one that is expected to fail is a
/// strange thing to put in a boot path.
///
/// It does not diagnose the *other* silent write gate. `checkDomainAccess`
/// enforces a per-agent `DomainAccess` allowlist that this endpoint does not
/// expose to an unauthenticated caller, so an agent can be blocked by an
/// allowlist while showing a clear mask here. That case is caught after the
/// fact by `SageRitual.WriteDenial`, which reports the server's own reason.
/// This type answers one question and says which one — an over-broad "all good"
/// would be worse than nothing, and `.canSave` is worded to promise only what
/// it checked.
public struct ApplianceWriteReadiness: Sendable, Equatable {

    /// SAGE's app-v22 capability bits.
    ///
    /// Named after their consequences rather than their source spellings, and
    /// deliberately matching the vocabulary the Agents screen renders, so one
    /// mechanism does not acquire two names in one product.
    ///
    /// From `internal/store/agent_capabilities.go`:
    /// `1` read across subjects · `2` deny shared-domain write · `4` deny
    /// claiming a domain · `8` deny writing a domain owned by another agent,
    /// *even with a level-2 grant* · `16` deny federated delivery.
    public enum Capability {
        public static let readAcrossSubjects: UInt32 = 1
        public static let denySharedWrite: UInt32 = 2
        public static let denyOwningASubject: UInt32 = 4
        public static let denyForeignWrite: UInt32 = 8
        public static let denyOtherSages: UInt32 = 16

        /// The three that stand between the appliance and saving a memory.
        public static let writeDenials = denySharedWrite | denyOwningASubject | denyForeignWrite

        /// `DefaultSelfRegisteredAgentCapabilities` — what consensus stamps on
        /// any key that self-registers after app-v22, with nobody having looked
        /// at it. SAGE's own model calls this **pending review**.
        public static let pendingReview = denySharedWrite | denyOwningASubject
            | denyForeignWrite | denyOtherSages

        /// The named Companion profile an administrator assigns to a co-located
        /// voice appliance. Kept here because the distinction between this and
        /// `pendingReview` is the whole of the logic below.
        public static let companion = readAcrossSubjects | denySharedWrite
            | denyOwningASubject | denyForeignWrite
    }

    /// What the node says about this agent, or that it has never heard of it.
    public enum Standing: Sendable, Equatable {
        /// Found, with its mask.
        case registered(mask: UInt32)
        /// The roster came back and this agent is not in it. Normal on a first
        /// run before the first boot completes; a fault if it persists.
        case notRegistered
        /// The node could not be reached or did not answer usefully. NOT the
        /// same as "restricted" — an appliance that cannot see its node must
        /// not tell the owner their permissions are wrong.
        case unknown(String)
    }

    public let agentID: String?
    public let standing: Standing

    public init(agentID: String?, standing: Standing) {
        self.agentID = agentID
        self.standing = standing
    }

    private var mask: UInt32? {
        if case .registered(let mask) = standing { return mask }
        return nil
    }

    /// Whether anything needs saying at all.
    ///
    /// True for exactly one state: the mask consensus assigns to a key nobody
    /// has reviewed. False for a clear mask, an unreachable node, a first run
    /// before registration, **and for any mask an administrator has actually
    /// assigned** — including the Companion profile.
    ///
    /// That last exclusion is the one worth explaining, because the obvious
    /// implementation gets it wrong and a test here caught it doing so. The
    /// Companion profile still contains all three write denials: under it the
    /// one surviving route is a domain the agent *owns*, which is exactly the
    /// arrangement the remedy asks the owner to set up. Warning on "any write
    /// denial" would therefore keep shouting after the owner had done
    /// everything correctly, forever, because this check cannot see domain
    /// ownership — that needs a signed request. A warning that never clears is
    /// worse than no warning: it teaches the owner to ignore the one place we
    /// have to tell them something true.
    ///
    /// So the signal is not "is it restricted" but "has anybody looked at it".
    /// A mask that is still the untouched self-registration default means no
    /// administrator has, which is the state SAGE itself calls pending review.
    /// If an assigned profile turns out to be wrong, the refusal speaks for
    /// itself through `SageRitual.WriteDenial`, with the server's own reason.
    public var needsTheOwner: Bool {
        mask == Capability.pendingReview
    }

    /// Whether an administrator has assigned this agent the named profile for a
    /// co-located voice appliance. Not a promise that writes will succeed — that
    /// additionally needs an owned domain, which is not visible from here.
    public var hasCompanionProfile: Bool {
        mask == Capability.companion
    }

    /// Reading is unaffected by every bit here — the mask restricts writing and
    /// federated delivery. Bit 1 *widens* reading rather than narrowing it.
    public var canRead: Bool { true }

    /// Deliberately not the inverse of `needsTheOwner`.
    ///
    /// With all three write denials set, one route survives: a domain the agent
    /// already owns. This type cannot see domain ownership — that needs a
    /// signed request — so it reports what is certain, which is that every
    /// other route is closed. Claiming "cannot write" outright would be a
    /// stronger statement than the evidence supports.
    public var canSave: Bool { !needsTheOwner }

    /// The one-line headline, or nil when there is nothing wrong.
    public var headline: String? {
        needsTheOwner ? "Mynah can't save anything yet." : nil
    }

    /// The consequences, in the owner's terms, worst first.
    ///
    /// The bit numbers never appear. "Mynah can't be given its own memory
    /// domain yet" is something a person can act on; "DenyDomainClaim (bit 4)"
    /// is a fact about a codebase they will never read.
    /// "subject", never "domain".
    ///
    /// SAGE's word is domain and this file's comments keep it, because that is
    /// what the code and the node call it. Everything an owner reads says
    /// subject, because that is what the rest of the app already says to them
    /// — `MemoriesView`'s empty state is "Mynah hasn't learned anything on this
    /// subject", and no owner-facing string in the product says domain. One
    /// mechanism explained in two vocabularies is worse than either.
    public var reasons: [String] {
        guard needsTheOwner, let mask else { return [] }
        var out: [String] = []
        if mask & Capability.denyOwningASubject != 0 {
            out.append("It can't claim a subject of its own — one has to be assigned to it.")
        }
        if mask & Capability.denyForeignWrite != 0 {
            // Says the grant part outright. An owner told only "it can't write
            // to someone else's subject" reaches for the access matrix, which
            // is the one remedy that looks obvious and does not work.
            out.append(
                "It can't write to a subject that belongs to another agent. Being granted "
                    + "access to one doesn't change that — the restriction is checked first."
            )
        }
        if mask & Capability.denySharedWrite != 0 {
            out.append("It can't write to shared subjects like “general”.")
        }
        return out
    }

    /// What the owner has to do, and who has to do it.
    ///
    /// Names the Companion profile and an owned domain, and never a level-2
    /// grant. That distinction is the whole point: a level-2 grant looks like
    /// the obvious remedy, is what SAGE's own MCP documentation currently
    /// suggests, and does not work — the deny-foreign-write bit is checked
    /// before the grant is consulted, so a granted domain the agent does not
    /// own is still refused. The SAGE team confirmed it in as many words: "a
    /// level-2 grant is not a substitute."
    public var remedy: String? {
        guard needsTheOwner else { return nil }
        // Names the subject from the constant rather than spelling it, so the
        // sentence cannot survive a rename of the thing it is telling somebody
        // to assign. That mismatch would fail exactly the way the original bug
        // did: writes refused, nothing said.
        return "Someone with administrator access to your SAGE node has to give Mynah the "
            + "companion profile and make it the owner of the subject “\(SageRitual.memoryDomain)”, "
            + "in CEREBRUM. An access grant won't do it — the restriction is checked before "
            + "grants are. Until then Mynah will answer you, but it won't remember anything."
    }

    /// The one-line version, for a moment when the owner is waiting rather than
    /// reading.
    ///
    /// A boot is not a settings page. `thread`'s point, and it is right: the
    /// mechanism belongs in the one place someone goes to understand it, and
    /// everywhere else should say the fact and point there.
    public var shortRemedy: String? {
        guard needsTheOwner else { return nil }
        return "Mynah can't save anything yet — SAGE restricted its key when it registered "
            + "itself. The Agents page explains what to change."
    }

    /// One line for a log, so this is discoverable from a terminal too.
    public var logLine: String? {
        guard let headline, let mask else { return nil }
        return "[sage] \(headline) \(reasons.joined(separator: " ")) "
            + "\(remedy ?? "") (agent \(agentID?.prefix(16) ?? "unknown"), capability mask \(mask))"
    }
}

// MARK: - Asking the node

/// Reads the appliance's own standing from the node's public agent roster.
///
/// Unauthenticated on purpose, and that is a property of the endpoint rather
/// than a shortcut: `GET /v1/agents` needs no signature, so this works at setup
/// before any identity has been established and from the daemon without holding
/// a signing context open.
public struct ApplianceWriteReadinessCheck: Sendable {

    private let endpoint: URL
    private let session: URLSession

    public init(endpoint: URL? = nil, timeout: TimeInterval = 5) {
        self.endpoint = endpoint ?? Self.defaultEndpoint()
        // No cookies, no credentials, no caching, and no redirect off loopback.
        self.session = LoopbackSecurity.makeSession(timeout: timeout)
    }

    /// `127.0.0.1:8080` is the shipped REST default. `SAGE_API_URL` overrides it
    /// for a node running elsewhere, and is ignored unless it points at this
    /// machine — a mask read from a stranger's node would be somebody else's
    /// permissions reported as the owner's.
    public static func defaultEndpoint(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let fallback = URL(string: "http://127.0.0.1:8080")!
        let configured = environment["SAGE_API_URL"].flatMap(URL.init(string:))
        let base = LoopbackSecurity.isLoopback(configured) ? (configured ?? fallback) : fallback
        return base.appendingPathComponent("v1/agents")
    }

    public func check(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) async -> ApplianceWriteReadiness {
        guard let agentID = SageAgentIdentity.applianceAgentID(homeDirectory: homeDirectory) else {
            // No key yet is a first run, not a permissions problem.
            return ApplianceWriteReadiness(agentID: nil, standing: .unknown("no identity on this Mac yet"))
        }
        do {
            try LoopbackSecurity.requireLoopback(endpoint)
            var request = URLRequest(url: endpoint)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            try LoopbackSecurity.verifyResponseOrigin(response, expected: endpoint)
            guard let code = (response as? HTTPURLResponse)?.statusCode, code == 200 else {
                return ApplianceWriteReadiness(agentID: agentID, standing: .unknown("the node did not answer"))
            }
            return ApplianceWriteReadiness(
                agentID: agentID,
                standing: Self.standing(inRoster: data, for: agentID)
            )
        } catch {
            return ApplianceWriteReadiness(agentID: agentID, standing: .unknown("\(error)"))
        }
    }

    /// Finds this agent's row and reads its mask.
    ///
    /// An absent `capabilities` field means unrestricted, and that is the
    /// documented meaning rather than a convenient reading of a missing key:
    /// agents already registered when app-v22 activated keep mask `0`, and the
    /// REST layer overlays live policy onto legacy rows so a stale zero cannot
    /// make a restricted agent look unrestricted.
    static func standing(inRoster data: Data, for agentID: String) -> ApplianceWriteReadiness.Standing {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let agents = root["agents"] as? [[String: Any]] else {
            return .unknown("the node's answer could not be read")
        }
        for agent in agents where (agent["agent_id"] as? String)?.lowercased() == agentID.lowercased() {
            let mask = (agent["capabilities"] as? NSNumber)?.uint32Value ?? 0
            return .registered(mask: mask)
        }
        return .notRegistered
    }
}
