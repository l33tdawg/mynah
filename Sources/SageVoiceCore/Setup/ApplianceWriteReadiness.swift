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
        /// The node answered about the caller that signed the question.
        ///
        /// **This carried a bare `mask: UInt32` until 1.7.5**, read out of an
        /// unsigned roster row that on any 11.17.x node comes back `401`. It now
        /// carries the node's own statement — see `ApplianceStanding` for why a
        /// signed self-report is the only thing that can answer this at all.
        case registered(ApplianceStanding)
        /// The node answered and does not know this agent. Normal on a first
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

    /// The raw mask, when the node has one for this agent.
    ///
    /// Public so a caller can assert on the *cause* rather than only on the
    /// sentences — a test that pins "Companion still carries write denials"
    /// is what stops someone re-introducing the warn-on-any-denial bug that a
    /// test caught here once already. Not for owner-facing display: nothing a
    /// person reads should contain this number.
    public var mask: UInt32? { self.reported?.capabilities }

    /// The node's own statement, when it made one.
    public var reported: ApplianceStanding? {
        if case .registered(let standing) = self.standing { return standing }
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
    ///
    /// ## This was `mask == 30`, and it could not fire in any state
    ///
    /// Two independent reasons, either of which alone was fatal. The mask was
    /// read from an unsigned `GET /v1/agents`, which answers `401` on every
    /// 11.17.x node — so `mask` was always nil and `standing` was always
    /// `.unknown`. And even with the read working, the appliance's live mask is
    /// **31**, not 30, so the equality could not hold. The Ready-screen warning
    /// that exists to catch a never-reviewed appliance key was dead from both
    /// ends at once.
    ///
    /// It now asks the node instead of inferring: `approval_required` and
    /// `can_write` are stated in a signed `sage_status`, which is necessarily
    /// about whoever signed it. See `ApplianceStanding`.
    ///
    /// The exclusion that used to be the interesting part is now free. Warning
    /// on "any write denial" would keep shouting after the owner had done
    /// everything correctly — the Companion profile still carries all three
    /// write denials, and the one surviving route is a domain the agent owns.
    /// Reading `approval_required` cannot make that mistake, because it is the
    /// node reporting a review state rather than us reconstructing one.
    public var needsTheOwner: Bool {
        self.reported?.needsReview ?? false
    }

    /// Whether an administrator has assigned this agent the named profile for a
    /// co-located voice appliance. Not a promise that writes will succeed — that
    /// additionally needs an owned domain.
    ///
    /// **Read as a name now, and that was a third dead guard.** This was
    /// `mask == Capability.companion`, which is 15. The owner's node reports
    /// `profile: "companion"` alongside `capabilities: 31` — companion plus the
    /// federated-delivery denial — so the appliance held the profile and the
    /// predicate for it was false.
    public var hasCompanionProfile: Bool {
        self.reported?.profile?.lowercased() == "companion"
    }

    /// What the node says about reading, rather than what the bits imply.
    ///
    /// Still true in every state it has been observed in — the mask restricts
    /// writing and federated delivery, and bit 1 *widens* reading rather than
    /// narrowing it — but a hardcoded `true` is a claim this type is in no
    /// position to make, and the node states the answer.
    public var canRead: Bool { self.reported?.canRead ?? true }

    /// Deliberately not the inverse of `needsTheOwner`.
    ///
    /// With all three write denials set, one route survives: a domain the agent
    /// already owns. This type cannot see domain ownership — that needs a
    /// signed request — so it reports what is certain, which is that every
    /// other route is closed. Claiming "cannot write" outright would be a
    /// stronger statement than the evidence supports.
    public var canSave: Bool { !needsTheOwner }

    /// The one-line headline, or nil when there is nothing wrong.
    /// "remember", not "save".
    ///
    /// "Save" was chosen to protect a distinction: the restriction blocks
    /// storing, not recalling, and *remember* covers both. But the state this
    /// sentence renders in is the untouched self-registration mask, which the
    /// agent has carried since it registered — so it has never stored anything,
    /// so there is nothing to recall either, and both readings are true. The
    /// ambiguity is unreachable here rather than merely unlikely.
    ///
    /// Against that, remember is the product's word and not narrowly: the pane
    /// is titled "What Mynah remembers", Welcome says "you can read everything
    /// it remembers", and this type's own remedy ends "it won't remember
    /// anything". Save appeared once, in this line, at the highest-stakes
    /// moment in the product.
    ///
    /// ## Why this is an instruction and not a diagnosis
    ///
    /// It used to read "Mynah can't remember anything yet." — true, accurate,
    /// and the wrong sentence. It reports a defect and leaves the owner holding
    /// it, which invites the two responses that cannot work: reinstall the app,
    /// or file a bug against SAGE. Neither touches the actual state, which is
    /// that a key is sitting in SAGE waiting for a human to approve it. Nothing
    /// is broken here — a review step has not happened yet.
    ///
    /// So the sentence names the next action. The owner may not be the person
    /// with administrator access; `remedy` says who is, and says it in the same
    /// breath. A headline that instructs and a remedy that names the actor is
    /// the right division — the reverse, a headline that complains and a remedy
    /// buried a screen away, is what this replaced.
    public var headline: String? {
        needsTheOwner ? Self.ownHeadline : nil
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
        // Names the subject from the constant rather than spelling it, so the
        // sentence cannot survive a rename of the thing it is telling somebody
        // to assign. That mismatch would fail exactly the way the original bug
        // did: writes refused, nothing said.
        guard needsTheOwner else { return nil }
        // Names the agent, because CEREBRUM lists every agent on the node by
        // id and "approve Mynah" is not an instruction in front of a table of
        // hex. This is also the check that would have caught the identity bug:
        // an owner comparing this id against the row they approved would have
        // seen two different keys.
        guard let agentID, !agentID.isEmpty else { return Self.ownRemedy }
        return "Mynah is the agent whose id starts \(agentID.prefix(16)). " + Self.ownRemedy
    }

    /// The one-line version, for a moment when the owner is waiting rather than
    /// reading.
    ///
    /// A boot is not a settings page. `thread`'s point, and it is right: the
    /// mechanism belongs in the one place someone goes to understand it, and
    /// everywhere else should say the fact and point there.
    public var shortRemedy: String? {
        guard needsTheOwner else { return nil }
        // Same verb as `headline`, and a test pins that. Changing one of these
        // and not the other is how a screen ends up saying "can't remember" in
        // its title and "can't save" in its banner — one mechanism, two words,
        // which is the thing we collapsed "subject" versus "domain" to avoid.
        //
        // Leads with the same action as `headline` for the same reason: this is
        // the string the Ready screen renders, so it is the one most owners
        // read, and it is read at a moment when they are waiting rather than
        // investigating. "Registered and waiting" is the state; it is not a
        // fault, and saying so costs nothing.
        return "\(Self.ownHeadline) It registered itself and is waiting for review. "
            + "The Agents page has the steps."
    }

    /// One line for a log, so this is discoverable from a terminal too.
    public var logLine: String? {
        guard let headline, let mask else { return nil }
        return "[sage] \(headline) \(reasons.joined(separator: " ")) "
            + "\(remedy ?? "") (agent \(agentID?.prefix(16) ?? "unknown"), capability mask \(mask))"
    }
}

// MARK: - The two signals, combined

/// What to tell the owner about Mynah's memory, given everything known.
///
/// There are two signals and they fail in opposite ways, so neither is enough
/// alone:
///
/// | | before any write | after a real refusal |
/// |---|---|---|
/// | `ApplianceWriteReadiness` | predicts | can be stale |
/// | `SageRitual.WriteDenial` | silent | authoritative |
///
/// The readiness check reads a capability mask, which is a *prediction* about
/// what will happen. A latched denial is an *observation* of what did happen,
/// carrying SAGE's own reason code and per-cause remedy. So an observation
/// outranks a prediction of the same thing — and it must, because the mask
/// cannot see the other silent write gate at all: a `DomainAccess` allowlist
/// refuses writes with a clear mask, and only a real refusal reveals it.
///
/// This type exists so that rule lives in one place. Two screens render this —
/// the Agents page and Ready — and a precedence rule reimplemented twice is a
/// precedence rule that will eventually disagree with itself.
public struct ApplianceMemoryStatus: Sendable, Equatable {

    /// The one-line fact, in the product's voice.
    public let headline: String
    /// SAGE's own sentence about the refusal, when there has been one. Never
    /// paraphrased — if consensus said it, the owner sees it verbatim.
    public let detail: String?
    /// What has to change, and by whom.
    public let remedy: String
    /// True when this came from a real refusal rather than from reading a mask.
    ///
    /// **Not for display.** "We watched this fail" and "we expect this to fail"
    /// read identically to an owner — the distinction is ours, not theirs, and
    /// a badge drawing it would be the product explaining its own internals
    /// instead of the owner's problem. It is exposed because a *caller* may
    /// legitimately care: a diagnostic dump, a log line, or a future decision
    /// about how hard to insist. Every screen should render `headline`,
    /// `detail` and `remedy` the same way regardless of this flag.
    public let isObserved: Bool

    public init(headline: String, detail: String?, remedy: String, isObserved: Bool) {
        self.headline = headline
        self.detail = detail
        self.remedy = remedy
        self.isObserved = isObserved
    }
}

extension ApplianceWriteReadiness {

    /// The single thing a screen should render, or nil when there is nothing to
    /// say.
    ///
    /// Nil is the common case and the important one: when Mynah is working this
    /// state does not exist at all — no badge, no green tick, no "all good" row.
    ///
    /// - Parameter denial: the latched refusal from `SageRitual.writeDenial`,
    ///   if any. Pass it whenever it is available; a caller that cannot reach it
    ///   still gets the predictive half.
    public func status(observing denial: SageRitual.WriteDenial?) -> ApplianceMemoryStatus? {
        if let denial {
            return ApplianceMemoryStatus(
                headline: Self.ownHeadline,
                detail: denial.detail,
                // SAGE's own remedy when it sent one: it is per-cause and
                // maintained by the people who own the rule. Ours is the
                // fallback for a server too old to have an opinion — which is
                // any server before v11.14.2, and therefore not rare.
                remedy: denial.remedy ?? Self.ownRemedy,
                isObserved: true
            )
        }
        guard let headline, let remedy else { return nil }
        return ApplianceMemoryStatus(
            headline: headline,
            detail: nil,
            remedy: remedy,
            isObserved: false
        )
    }

    /// The remedy we write ourselves, for the predictive path and for a server
    /// that sent no per-cause one.
    /// ## Why this names a second effect
    ///
    /// The companion profile is mask 15, and **bit 1 is `ReadAllDomains`** —
    /// SAGE's own reference says the preset *"can recall globally only within
    /// its clearance"*. So applying this advice does two things and we used to
    /// name one: Mynah becomes able to remember, **and** its discovery filters
    /// come off, so the Memories page goes from showing nothing to showing a
    /// slice of what every other agent on the node has stored.
    ///
    /// That is a privacy consequence of an action this product actively
    /// instructs somebody to take, and leaving it unsaid is the same failure as
    /// every other one this week — a true sentence that stops being the whole
    /// truth because something else changed.
    ///
    /// **Stated evenly, and deliberately not as a caution.** The remedy is
    /// right and the owner should apply it; it is his machine, his appliance,
    /// and it still cannot write anywhere it does not own. Wording that made
    /// the fix sound risky would be its own kind of dishonesty — it would
    /// discourage the correct action to look careful.
    ///
    /// The clearance bound is named because it is real and because it is the
    /// part that makes this calm rather than alarming: reading is lifted only
    /// up to the agent's own clearance, which on this appliance is 1. Anything
    /// classified above that stays invisible.
    ///
    /// It lives on the *remedy* rather than as a standing fact, which is the
    /// distinction that matters: "here is what changes when you do this" is a
    /// different sentence from "here is how things are", and only the first is
    /// true today.
    /// The one sentence, written once.
    ///
    /// Both paths into `ApplianceMemoryStatus` render it — the predictive one
    /// through `headline` and the observed one from a `WriteDenial` — and a
    /// test asserts the two agree. They agreed by coincidence before, because
    /// the string was typed out in both places; now they agree by construction.
    static let ownHeadline = "Approve Mynah in CEREBRUM so it can start remembering."

    static let ownRemedy = "Someone with administrator access to your SAGE node has to give "
        + "Mynah the companion profile and make it the owner of the subject "
        + "“\(SageRitual.memoryDomain)”, in CEREBRUM. An access grant won't do it — the "
        + "restriction is checked before grants are. That profile also lets Mynah read "
        + "across subjects it wasn't given, up to its own clearance, so the Memories page "
        // "remembered", not "stored" — `OneVerbForMemoryTests` caught this and
        // the rule is right even though the clause is about *other* agents:
        // this product has one verb for memory, and an owner reading "stored"
        // here and "remembers" everywhere else has to work out whether they are
        // the same thing. `voice`'s clause, one word changed.
        + "will start showing what your other agents have remembered as well as Mynah's own. "
        + "Until then Mynah will answer you, but it won't remember anything."
}

// MARK: - Asking the node

/// Asks the node about the appliance, **signed as the appliance**.
///
/// ## This read an unsigned roster until 1.7.5, and never once succeeded
///
/// The old comment here said `GET /v1/agents` "needs no signature, so this works
/// at setup before any identity has been established". That was false on every
/// node this product has shipped against. The route sits inside the group that
/// applies `Ed25519AuthMiddleware` and is additionally wrapped in
/// `appV23PipelineAgentBoundary`, which 403s any non-active caller; only
/// `/health` and `/ready` are public. Measured on the owner's node on 5 August
/// 2026: `/v1/agents` → `401 Missing authentication headers`, `/health` → `200`.
///
/// So every call landed in `.unknown(...)`, `needsTheOwner` was permanently
/// false, and the Ready-screen warning that exists to catch a never-reviewed
/// appliance key could not fire in any state. Nothing reported this, because a
/// check that silently answers "I don't know" looks exactly like a check that
/// answers "all fine".
///
/// The premise underneath the mistake is worth naming, because it is the same
/// one that put the wrong agent id in `SageAgentIdentity`: a *developer's* MCP
/// session on this Mac signs with more standing than the appliance, so a SAGE
/// surface verified through it green-lights screens that are broken for Mynah.
/// The route was almost certainly checked, and checked as the wrong caller.
///
/// ## Why signing is not the obstacle it was taken for
///
/// The worry the old comment encodes is real — this runs at setup, before an
/// identity exists. That is handled by `checkStartingNodeIfNeeded`, which starts
/// a node and mints the key, and by the no-identity branch below returning
/// `.unknown` rather than a verdict. There is no state in which an unsigned read
/// was necessary, and one in which it was actively wrong.
public struct ApplianceWriteReadinessCheck: Sendable {

    /// Asks the node `sage_status` and returns its raw reply.
    ///
    /// Injected so the window can hand over the connection it already holds.
    /// `SageMemoryStore` keeps one long-lived `sage-gui mcp` child signing as
    /// the appliance, and a second child would be a second process answering as
    /// the same identity — which this codebase has already paid for once.
    public typealias StatusSource = @Sendable () async throws -> String

    private let status: StatusSource

    public init(status: StatusSource? = nil, timeout: TimeInterval = 30) {
        self.status = status ?? { try await Self.signedStatus(timeout: timeout) }
    }

    /// The default source: a short-lived signed MCP connection.
    ///
    /// Resolved the way `sage-voiced` and the Memories page resolve it, so all
    /// three operate the same node rather than whichever binary each happened to
    /// find — `SageNodeChoice` is the owner's rule that an already-installed
    /// SAGE is used and left alone.
    ///
    /// The environment is pinned to the appliance's. Without it the node derives
    /// identity from the launch working directory, which would make the `cd` in
    /// a launch script decide whose standing this reports.
    static func signedStatus(timeout: TimeInterval) async throws -> String {
        guard let executable = SageNodeChoice.resolve(
            vendored: SageNodeLocator.vendoredExecutableURL()
        )?.executable else {
            throw MCPClientError.missingExecutable("no SAGE node on this Mac to ask")
        }
        let client = MCPClient(
            executableURL: executable,
            arguments: ["mcp"],
            environment: MynahIdentity.applianceEnvironment(),
            requestTimeoutSeconds: timeout
        )
        defer { client.stop() }
        return try await client.call(name: SageRitual.Tool.status, arguments: [:])
    }

    public func check(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) async -> ApplianceWriteReadiness {
        guard let agentID = SageAgentIdentity.applianceAgentID(homeDirectory: homeDirectory) else {
            // No key yet is a first run, not a permissions problem.
            return ApplianceWriteReadiness(agentID: nil, standing: .unknown("no identity on this Mac yet"))
        }
        do {
            return try await roster(for: agentID)
        } catch {
            return ApplianceWriteReadiness(agentID: agentID, standing: .unknown("\(error)"))
        }
    }

    /// The same check, but starts a node first if nothing is listening.
    ///
    /// This is the boot path. `check` alone reports "the node did not answer"
    /// on a Mac where the answer is that *nobody ever started one* — Mynah
    /// spawns `sage-gui mcp`, which is a client, and until this existed no code
    /// in this app ran `serve`. A fresh install therefore looked configured and
    /// silently remembered nothing.
    ///
    /// Deliberately still lazy, which is QuietType's rule: a node is started
    /// only after a real connection failure, so a Mac already running SAGE
    /// never gets a second one started beside it.
    ///
    /// The no-identity branch starts a node too, and that is the case this was
    /// built for rather than an edge: on a first run genesis is what *mints*
    /// the companion key, so returning early because no key exists yet would
    /// skip the one action that creates one. The standing reported immediately
    /// afterwards is usually still `.unknown` — a chain takes longer to come up
    /// than any settle delay worth blocking a launch on — and a later recheck
    /// is what sees the enrolled agent.
    public func checkStartingNodeIfNeeded(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        supervisor: SageNodeSupervisor = .shared
    ) async -> ApplianceWriteReadiness {
        guard let agentID = SageAgentIdentity.applianceAgentID(homeDirectory: homeDirectory) else {
            _ = await supervisor.startAndSettle(homeDirectory: homeDirectory)
            guard let minted = SageAgentIdentity.applianceAgentID(homeDirectory: homeDirectory) else {
                return ApplianceWriteReadiness(
                    agentID: nil,
                    standing: .unknown("no identity on this Mac yet")
                )
            }
            return await settledStanding(for: minted)
        }
        do {
            return try await roster(for: agentID)
        } catch {
            guard SageNodeSupervisor.isNodeNotRunning(error) else {
                return ApplianceWriteReadiness(agentID: agentID, standing: .unknown("\(error)"))
            }
            switch await supervisor.startAndSettle(homeDirectory: homeDirectory) {
            case .started, .openedApplication, .alreadyRunning:
                return await settledStanding(for: agentID)
            case .noNodeAvailable, .vendoredNodeTooOld, .cooledDown, .failed:
                return ApplianceWriteReadiness(agentID: agentID, standing: .unknown("\(error)"))
            }
        }
    }

    private func settledStanding(for agentID: String) async -> ApplianceWriteReadiness {
        do {
            return try await roster(for: agentID)
        } catch {
            return ApplianceWriteReadiness(agentID: agentID, standing: .unknown("\(error)"))
        }
    }

    private func roster(for agentID: String) async throws -> ApplianceWriteReadiness {
        ApplianceWriteReadiness(
            agentID: agentID,
            standing: Self.standing(inStatus: try await status(), expecting: agentID)
        )
    }

    /// Reads a signed `sage_status` reply into standing.
    ///
    /// ## The one check a roster could not do
    ///
    /// The reply is compared against the key this Mac signs with, and a
    /// disagreement is reported as `.unknown` rather than silently accepted.
    /// That is not defensive padding — it is the check that would have caught
    /// the bug in `SageAgentIdentity`, where a comment asserted with total
    /// confidence that the appliance signed as an id belonging to a developer's
    /// MCP session on the same machine.
    ///
    /// It is only possible because the answer is signed. A roster row can be
    /// matched by name or by id and both match the wrong agent; a signed reply
    /// is *by construction* about whoever signed it, so "does the node's answer
    /// name the key I hold" is a real question with a real answer.
    ///
    /// Reported as unknown rather than as a fault because the honest reading is
    /// "this appliance cannot tell whose standing it just read", and telling an
    /// owner their permissions are wrong on that basis would be worse than
    /// saying nothing.
    static func standing(
        inStatus reply: String,
        expecting agentID: String
    ) -> ApplianceWriteReadiness.Standing {
        guard let reported = ApplianceStanding.fromStatus(reply) else {
            return .unknown("the node's answer could not be read")
        }
        // An empty `agent_id` is an older node that does not echo it, not a
        // mismatch. Only a stated, different id is evidence of one.
        if let signed = reported.agentID, !signed.isEmpty,
           signed.lowercased() != agentID.lowercased() {
            return .unknown(
                "the node answered for agent \(signed.prefix(16)), "
                    + "but this Mac signs as \(agentID.prefix(16))"
            )
        }
        // `pending_review` is the node naming the state this whole type exists
        // for, so it is honoured even when the booleans below it look clear.
        if reported.registrationStatus == "unregistered" { return .notRegistered }
        return .registered(reported)
    }
}
