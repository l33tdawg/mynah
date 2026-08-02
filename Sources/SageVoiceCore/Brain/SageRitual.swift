import Foundation

/// SAGE's boot and per-turn discipline, performed by the appliance itself.
///
/// SAGE's operating contract is three calls: `sage_inception` before anything
/// else in a session, `sage_turn` every turn, and `sage_reflect` after
/// significant work. The appliance was doing none of them, and that was not a
/// missed nicety — it was two live faults.
///
/// **The appliance had amnesia.** Conversation history lives in memory keyed by
/// thread, so every restart — crash, reboot, deploy — silently dropped it. The
/// owner saw this directly: after a restart, "done?" got an answer about their
/// backlog, because the question it referred to no longer existed anywhere. The
/// layer designed to survive exactly this was installed, running, and unused.
///
/// **The appliance was about to be blocked.** SAGE enforces turn discipline
/// server-side: non-SAGE tool calls are refused after 7 of them without a
/// `sage_turn`, or after 5 minutes once 2 have accumulated. `web_search` is a
/// non-SAGE call, so the more the owner used the feature, the sooner their
/// agent's tools would start failing — and the symptom would have surfaced as
/// "web search broke", days from the cause.
///
/// These calls are made by the daemon, not the model. The model is told never
/// to call bootstrap tools, a 4B model would forget three turns in, and this
/// discipline must not compete with the owner's request for the loop's five
/// iterations. It is the appliance's own housekeeping, so the appliance does it.
public actor SageRitual {

    /// A write the node will never accept, however often it is retried.
    ///
    /// Distinct from an ordinary failure on purpose. A refused *permission* and
    /// a refused *connection* look identical at the call site and want opposite
    /// handling: one is fixed by trying again, the other is only ever fixed by
    /// the owner granting something in CEREBRUM. Conflating them is a known,
    /// expensive bug — an untyped 403 was read as a stale session, so every
    /// single write paid a full re-registration plus a backoff ladder before
    /// failing anyway, on a machine nobody is sitting at.
    public struct WriteDenial: Sendable, Equatable {
        /// The domain the appliance was trying to write. Named so the owner is
        /// told what to grant rather than that "something" was refused.
        ///
        /// Usually the domain we asked for rather than one the server named. A
        /// v11.14.2+ node deliberately withholds it — the typed denial "does
        /// not disclose the agent ID, requested domain, owner ID, raw
        /// capability mask, or raw consensus log" — so the only party that
        /// knows which domain was refused is the caller, which is us.
        public let domain: String
        /// What the node said, for the log and for the settings row.
        public let detail: String
        /// SAGE's stable reason code, when the server sent one.
        ///
        /// The thing to branch on. Seven exist; `nil` means an older server
        /// that only produced prose, which is the fallback path below.
        public let reasonCode: String?
        /// The server's own operator remedy, when it sent one.
        ///
        /// Authoritative and preferred over anything we would write: it is
        /// per-cause and maintained by the people who own the rule. We reported
        /// the old single remedy string as wrong precisely because one sentence
        /// could not be right for every cause; having asked for that, using
        /// ours in preference to theirs would be perverse.
        public let remedy: String?

        public init(domain: String, detail: String, reasonCode: String? = nil, remedy: String? = nil) {
            self.domain = domain
            self.detail = detail
            self.reasonCode = reasonCode
            self.remedy = remedy
        }
    }

    /// SAGE's own tool names. Not in the voice allowlist on purpose: the model
    /// must never reach these, because *it* calling them is the failure mode
    /// this type exists to replace.
    public enum Tool {
        public static let inception = "sage_inception"
        public static let turn = "sage_turn"
        public static let reflect = "sage_reflect"
        public static let register = "sage_register"
        public static let rename = "sage_rename"
        public static let status = "sage_status"
    }

    /// What the phone appliance registers as.
    ///
    /// Unchanged, and it must stay unchanged: at registration the node copies
    /// this into `RegisteredName`, which is immutable forever
    /// (`internal/abci/app.go:6935`). Every appliance already on a node carries
    /// it, and `sage_find_agent` matches against it — so renaming this constant
    /// would not rename anything, it would make the next fresh install
    /// unreachable by the name the existing ones answer to.
    public static let applianceAgentName = "SAGE Voice Bridge"

    /// Deliberately absent: a separate name for the Mac app.
    ///
    /// There was one, and it registered a second agent. The window and the
    /// daemon are one appliance — they answer the same owner, from the same
    /// Mac, about the same things — but they signed with different keys and so
    /// became "MYNAH (Mac App)" and "MYNAH (SAGE Voice Bridge Agent)" on the
    /// node, each holding memories the other could not see, each needing its own
    /// grant from the operator.
    ///
    /// The argument for the split was that "Mynah" is what a person says out
    /// loud. That is a good argument for what the ONE agent should be called,
    /// not for having two.

    /// What CEREBRUM shows for the appliance.
    ///
    /// Changed from "MYNAH (SAGE Voice Bridge Agent)", which read like a
    /// component in a system diagram rather than the name of the thing the
    /// owner installed. The registered name above is deliberately NOT changed
    /// with it — it is immutable on the node, every appliance already carries
    /// it, and renaming the constant would only make the next fresh install
    /// unreachable by the name the existing ones answer to.
    ///
    /// The operator grants domain access per agent, so the row has to say which
    /// agent it is. `Name` is mutable (`sage_rename` → AgentUpdate) while
    /// `RegisteredName` is not, and `sage_find_agent` matches both — so the
    /// descriptive name here and the spoken name above are two views of one
    /// agent rather than a trade-off.
    public static let applianceDisplayName = "Mynah - Sage Voice Bridge"


    /// Back-compatible alias. New code should name which one it means.
    public static let agentName = SageRitual.applianceAgentName

    /// How much of `sage_inception`'s reply to carry into the system prompt.
    ///
    /// Inception returns boot instructions plus recalled memories and can run to
    /// several KB. That text joins the ~3,000-token system prompt and tool
    /// catalogue in front of *every* request for the life of the process, so it
    /// is the most expensive string in the system — and this appliance has
    /// already been over the context ceiling once.
    public static let maximumBootContextCharacters = 1200

    /// Turns between `sage_reflect` calls.
    ///
    /// Reflection is for significant work, not every "what's the weather". Too
    /// often and the ledger fills with noise that dilutes real recall.
    public static let reflectEveryTurns = 10

    /// The one domain this appliance writes.
    ///
    /// Everything it stores goes here and nowhere else, and that is now a
    /// requirement rather than tidiness. Under app-v22 an agent carries a
    /// capability mask; the fail-closed mask a self-registered key receives
    /// denies writes to the shared domains (`general`, `self`, `meta`,
    /// `sage-*`), denies claiming an unowned domain, and denies writing a
    /// domain owned by anybody else — the last one *even when a level-2 grant
    /// exists*. So a domain invented per subject is a domain the appliance can
    /// never write, and `general` — the default when no domain is passed — is
    /// among the ones explicitly closed.
    ///
    /// One domain the appliance owns is therefore the only shape that can work,
    /// and subject has to be carried some other way. `sage_remember` takes a
    /// `tags` array for exactly that; `sage_turn` does not take one at all, so
    /// the per-turn record below carries subject in its topic string and
    /// nothing else. Do not "fix" that by splitting the domain.
    ///
    /// Not named `sage-voice-bridge`, deliberately: `sage-*` is a reserved
    /// ownerless shared prefix, so that name is unwritable by construction.
    ///
    /// ## Why `voice-interface` and not `voice-appliance`
    ///
    /// This was `voice-appliance`, which the appliance had never once succeeded
    /// in writing. The remedy is for an administrator to *transfer ownership* of
    /// a domain to this agent, and transfer needs a domain that already exists —
    /// the appliance cannot bring one into being, because every path that would
    /// make it an owner is denied to it (first-write auto-registration and
    /// explicit registration alike).
    ///
    /// `voice-interface` already exists on the owner's node, owned by the
    /// genesis admin, so the ownership transfer has something to transfer and
    /// CEREBRUM can drive it end to end. It is also the name SAGE's own RBAC
    /// reference uses when describing this exact arrangement. `voice-appliance`
    /// would have required the administrator to create it first, which is a
    /// further step for no gain.
    ///
    /// **This name must match the domain that is actually assigned.** A
    /// mismatch fails the same silent way the original bug did — writes refused,
    /// nothing said. A test asserts the system prompt names the same domain this
    /// constant does, so the two cannot drift apart unnoticed.
    public static let memoryDomain = "voice-interface"

    private let tools: ToolProviding
    private let log: @Sendable (String) -> Void

    private var turnsSinceReflect = 0
    private var turnCount = 0
    /// What `sage_inception` returned, trimmed. Nil until boot, and nil forever
    /// if boot failed — the appliance still works, it just starts cold.
    public private(set) var bootContext: String?

    /// Set once the node has permanently refused a write, and never cleared.
    ///
    /// Latched rather than re-tested per turn. Nothing the appliance can do
    /// changes the answer — only the owner can, in CEREBRUM — so every
    /// subsequent attempt would spend a round trip to be told the same thing,
    /// forever, at one per spoken turn. Reading this is how the app and the
    /// daemon know to tell the owner that Mynah cannot save what it is being
    /// told, and which domain it wanted.
    public private(set) var writeDenial: WriteDenial?

    /// What the node said about this agent's standing at boot.
    ///
    /// The forward-looking half of `writeDenial`: that one is what happened
    /// when a write was refused, this one is known before any write is
    /// attempted. Both exist because they catch different gates — the mask is
    /// visible here, and a `DomainAccess` allowlist is not visible to an
    /// unauthenticated reader and only shows up as a refusal.
    public private(set) var readiness: ApplianceWriteReadiness?

    /// - Parameter agentName: what this process registers as. Defaults to the
    ///   appliance so existing call sites keep their identity.
    /// - Parameters:
    ///   - agentName: the immutable name to register under.
    ///   - displayName: the mutable name CEREBRUM shows, or `nil` to leave it
    ///     alone. Applied after registration via `sage_rename`.
    ///   - displayName: the mutable name CEREBRUM shows, or `nil` to leave it
    ///     alone. Defaults to `nil`: renaming is a consensus write, so it
    ///     happens only where a call site has asked for it by name.
    ///   - displayNameMarker: where the applied name is recorded, so the rename
    ///     happens once rather than on every boot.
    ///   - readinessCheck: asks the node whether this agent may write. Injected
    ///     so a test can drive every standing without a node, and so the check
    ///     stays one line at the call site.
    public init(
        tools: ToolProviding,
        agentName: String = SageRitual.applianceAgentName,
        displayName: String? = nil,
        displayNameMarker: URL? = SageRitual.defaultDisplayNameMarker(),
        readinessCheck: (@Sendable () async -> ApplianceWriteReadiness)? = nil,
        alreadySaidFile: URL = SageRitual.defaultAlreadySaidFile(),
        readableDomainsFile: URL = ReadableDomains.defaultFileURL(),
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.tools = tools
        self.agentName = agentName
        self.displayName = displayName
        self.displayNameMarker = displayNameMarker
        self.readinessCheck = readinessCheck ?? { await ApplianceWriteReadinessCheck().check() }
        self.alreadySaidFile = alreadySaidFile
        self.alreadySaid = AlreadySaid.load(from: alreadySaidFile)
        self.readableDomainsFile = readableDomainsFile
        self.log = log
    }

    /// Replies already said out loud, so none is said twice.
    ///
    /// **The bug this exists to stop was shipped and seen.** `sage_turn` keeps
    /// returning the same `pipe_results` on later turns — draining them from
    /// this object clears *this* object, not the node — so every subsequent
    /// turn announced the same reply again. The owner's thread filled with
    /// "one of your agents replied:" repeating an acknowledgement and a long
    /// status update, over and over.
    ///
    /// On disk rather than in memory, because the daemon restarts often — a
    /// changed setting, an update, a launchd reconcile — and an in-memory set
    /// would replay everything SAGE still holds on every one of those.
    struct AlreadySaid: Codable, Equatable {
        /// In arrival order, so the oldest can be dropped. An appliance that
        /// runs for a year should not carry every pipe id it ever saw.
        var ids: [String] = []

        /// Whether this ledger has ever seen a turn.
        ///
        /// **The first one says nothing, and that is not caution — it is the
        /// only correct answer.** The node goes on returning results for hours,
        /// so on the first turn after this ledger exists, everything it still
        /// holds arrives at once and every one of it looks new. The owner
        /// upgraded and his thread immediately filled with three replies he had
        /// already read twice: *"you repeated yourself two three tiems."*
        ///
        /// Nothing already sitting there when the ledger is born is news. It is
        /// written down and not spoken, and what follows is genuinely new.
        ///
        /// Optional so a ledger written by 1.2.13 — which had no such field and
        /// no such rule — decodes rather than being thrown away, and is treated
        /// as already seeded. Its contents are proof it has seen a turn.
        ///
        /// **The cost, stated rather than hidden:** on a brand-new install the
        /// very first reply that ever comes back is written down and not
        /// spoken, because there is no way to tell it apart from a backlog the
        /// node has been holding. The results carry no timestamp this can read,
        /// so the choice is between swallowing one reply once and replaying
        /// hours of them on every upgrade. The second is what the owner already
        /// experienced twice.
        var hasSeeded: Bool? = nil

        static let mostKept = 200

        mutating func remember(_ id: String) {
            ids.append(id)
            if ids.count > Self.mostKept {
                ids.removeFirst(ids.count - Self.mostKept)
            }
        }

        func has(_ id: String) -> Bool { ids.contains(id) }

        static func load(from url: URL) -> AlreadySaid {
            guard let data = try? Data(contentsOf: url),
                  let stored = try? JSONDecoder().decode(AlreadySaid.self, from: data) else {
                return AlreadySaid()
            }
            return stored
        }

        func save(to url: URL) {
            guard let data = try? JSONEncoder().encode(self) else { return }
            try? OwnerOnlyFileSecurity.write(data, to: url)
        }
    }

    /// One ledger per surface, and that is not an implementation detail.
    ///
    /// **A single shared file would have hidden replies from the window.** The
    /// app and the daemon are separate processes with separate `SageRitual`s,
    /// both calling `sage_turn`, and the node offers the same `pipe_results` to
    /// each. With one ledger, whichever asked first would mark the reply said
    /// and the other would never show it — which is precisely what the owner
    /// reported: *"via signal you get the inbox, via the app it says i have
    /// nothing."* The daemon runs constantly and would win that race every
    /// time.
    ///
    /// Two surfaces telling the owner once each is not a repeat. It is a phone
    /// and a Mac, and somebody looking at one of them has not seen the other.
    public static func defaultAlreadySaidFile(
        surface: String = "app",
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/SAGE Voice Bridge", isDirectory: true)
            .appendingPathComponent("said-replies-\(surface).json", isDirectory: false)
    }

    private let alreadySaidFile: URL
    private var alreadySaid: AlreadySaid

    /// Where the searchable domains are written for `ScopedRecall` to read.
    ///
    /// One file for both surfaces, unlike `alreadySaidFile`: this records what
    /// the *node* permits this agent, which is a property of the identity and
    /// identical whichever process asks. Two copies could only ever disagree by
    /// being differently stale.
    private let readableDomainsFile: URL

    private let readinessCheck: @Sendable () async -> ApplianceWriteReadiness

    public static func defaultDisplayNameMarker(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/SAGE Voice Bridge", isDirectory: true)
            .appendingPathComponent("display-name", isDirectory: false)
    }

    private let agentName: String
    private let displayName: String?
    private let displayNameMarker: URL?

    // MARK: - Boot

    /// Runs `sage_inception` and keeps its reply as session context.
    ///
    /// Must complete *before* the prompt-cache warm-up. The warm-up's whole
    /// value is that the cached prefix matches the real requests byte for byte,
    /// and this changes the prefix — warming first would throw away the 5×
    /// prefill saving on the owner's first sentence.
    /// - Parameter onSignedIn: called once the identity is claimed and its
    ///   standing checked, before the slow part. This is two owner-visible
    ///   steps in one method — signing in, then reading back what happened
    ///   before — and on the owner's Mac they took 31 and 14 seconds. A caller
    ///   drawing a start-up line has no other way to tell them apart, and one
    ///   label held for three quarters of a minute is what he read as a hang.
    @discardableResult
    public func boot(onSignedIn: @Sendable () -> Void = {}) async -> String? {
        await register()
        await checkWhetherItCanSaveAnything()
        onSignedIn()
        // **Deliberately not awaited, and this line is the reason.**
        //
        // Awaiting it shipped, for about an hour, and the owner watched it:
        // registered at 16:11:00, nothing until he gave up and quit at
        // 16:11:38. `sage_status` aggregates memory counts per domain, which on
        // an agent with a real history is a bounded authorization scan over all
        // of them — the node says as much in `counts_degraded_reason` — and
        // start-up sat behind it for 38 seconds saying "Signing in".
        //
        // Nothing waits on the answer. `ScopedRecall` loads the file at the
        // moment it needs it, so a discovery that lands ten seconds from now is
        // in force for every recall after that. The only turn that can lose the
        // race is a recall issued in the first seconds of the first launch
        // ever, and it loses by being sent the way the model wrote it.
        Task { [weak self] in await self?.noteWhichDomainsItMaySearch() }
        do {
            let reply = try await tools.call(name: Tool.inception, arguments: [:])
            let trimmed = Self.condense(reply, to: Self.maximumBootContextCharacters)
            bootContext = trimmed.isEmpty ? nil : trimmed
            log("[sage] inception ok, \(trimmed.count) chars of session context")
            return bootContext
        } catch {
            // Non-fatal by design. An appliance that refuses to answer because
            // it could not read its own history is worse than one that starts
            // cold — the owner is on a phone and cannot fix a SAGE node.
            log("[sage] inception failed, starting without prior context: \(error)")
            return nil
        }
    }

    /// Asks the node whether this agent is allowed to save anything, at boot,
    /// before a single turn has been discarded.
    ///
    /// Runs after `register()` so a first run has had its chance to appear on
    /// the roster, and before `inception` so the answer is in the log above the
    /// first turn rather than buried under it.
    ///
    /// It never blocks or fails the boot. A node that cannot be reached, or an
    /// agent not yet on the roster, is reported as unknown and says nothing —
    /// an appliance that cannot see its node must not tell the owner their
    /// permissions are wrong.
    private func checkWhetherItCanSaveAnything() async {
        let readiness = await self.readinessCheck()
        self.readiness = readiness
        guard let line = readiness.logLine else { return }
        // Logged at boot, every boot, for as long as it is true. Not once and
        // not on first failure: the whole failure this replaces was a fault
        // that was perfectly silent for the life of an identity, and a line
        // that scrolls past once would have been just as silent.
        log(line)
    }

    /// Asks the node which domains this agent may search, and writes them down.
    ///
    /// **11.16.4 stopped answering recall with no `domain`**, and the model
    /// omits it most of the time — so without this, "what do you remember about
    /// X" is refused rather than answered. See `ScopedRecall`, which reads the
    /// file this writes.
    ///
    /// Skipped entirely while the record is fresh. The answer only changes when
    /// a person grants this agent something in CEREBRUM, which is rare and
    /// deliberate, and a daily round trip is the right price for noticing it.
    ///
    /// Never fatal, and never blocking. A node that will not answer leaves the
    /// previous set in place; an appliance that refused to start because it
    /// could not enumerate its own permissions would be trading a degraded
    /// recall for no appliance at all.
    private func noteWhichDomainsItMaySearch(now: Date = Date()) async {
        var record = ReadableDomains.load(from: readableDomainsFile)
        guard !record.isFresh(now: now) else { return }
        // Stamped before the call, not after, and kept whatever happens below.
        // `sage_status` on this appliance's key does not return on 11.16.4 — it
        // spends the client's full 90-second timeout — so an attempt that is
        // only recorded on success is an attempt repeated at every launch for
        // as long as that bug lives. What it costs to give up for a day is
        // nothing: `ReadableDomains.wellKnown` already names the two domains
        // this appliance uses, and discovery only ever adds to them.
        record.checkedAt = now
        defer { record.save(to: readableDomainsFile) }
        do {
            let reply = try await tools.call(name: Tool.status, arguments: [:])
            guard let discovered = ReadableDomains.fromStatus(reply, writesTo: Self.memoryDomain) else {
                log("[sage] sage_status did not name any searchable domains; using the known ones")
                return
            }
            record = discovered
            log("[sage] recall is scoped to \(discovered.domains.joined(separator: ", "))")
        } catch {
            log("[sage] could not ask which domains are searchable, using the known ones: \(error)")
        }
    }

    /// Claims an on-chain identity for the appliance.
    ///
    /// Not cosmetic. SAGE gates its task surface on identity — `sage_backlog`
    /// answers "only to signed agents or an authenticated CEREBRUM session"
    /// (`web/handler.go:2046`), so an unregistered appliance gets HTTP 401 on
    /// every task question while memory recall works fine. The owner saw this
    /// as the agent insisting it could not check its backlog, and reasonably
    /// read it as a missing tool — but the tool was there and the identity
    /// behind it was not.
    ///
    /// Idempotent server-side, so this runs every boot and returns the existing
    /// record when there is one. Registration is a property of the appliance,
    /// not a thing the owner should ever have to ask for by voice, which is why
    /// it happens here rather than in the model's catalogue.
    private func register() async {
        do {
            let reply = try await tools.call(
                name: Tool.register,
                arguments: [
                    "name": .string(agentName),
                    // Was omitted, and the omission shipped. `sage_inception`
                    // auto-registers too, and when it gets there first the node
                    // keeps ITS name and bio forever — `RegisteredName` is
                    // immutable. That is why the appliance on the author's node
                    // reads `registered_name: "agent-74140c2d"` with the bio
                    // "Auto-registered  agent for project ''" (the double space
                    // is an empty provider): `autoAgentName()` falls back to
                    // "agent-" + the first 8 hex of the key when provider and
                    // project are both empty, which they are for a launchd
                    // daemon.
                    //
                    // Registering BEFORE inception is what makes this the name
                    // that sticks, so this call must stay ahead of it in
                    // `boot()`. The bio is the part a person reads in CEREBRUM
                    // when deciding what to grant, so it says what the agent is
                    // for rather than what registered it.
                    "boot_bio": .string(Self.bootBio)
                ]
            )
            log("[sage] registered as \(agentName): \(Self.condense(reply, to: 200))")
            await adoptDisplayName()
        } catch {
            // Non-fatal: memory still works unregistered, and an appliance that
            // refuses to answer anything because it could not claim an identity
            // is strictly worse than one that cannot read its backlog.
            log("[sage] registration failed, task tools may return 401: \(error)")
        }
    }

    /// What CEREBRUM shows under the agent's name.
    ///
    /// Written for the person deciding whether to grant this agent anything.
    /// It names the domain it needs, because that decision is otherwise made
    /// with no information at all — the previous bio said only that something
    /// had auto-registered itself.
    static let bootBio = """
    Mynah, the voice appliance on this Mac. Answers the owner's Signal messages \
    and calls, and stores what it is told in the \(memoryDomain) domain.
    """

    /// Sets the name CEREBRUM shows, if it is not already set.
    ///
    /// Registration cannot do this. `processAgentRegister` is idempotent and
    /// copies `Name` straight off the existing record
    /// (`internal/abci/app.go:6876`), so re-registering under a new name renames
    /// nothing and silently succeeds — which is why the appliance kept showing
    /// its original name no matter what was passed. Renaming is a separate
    /// self-only AgentUpdate transaction.
    ///
    /// Guarded on the current name because that transaction goes through
    /// consensus. An unguarded rename on every boot would put a write on the
    /// chain each time the owner restarts the appliance, to change nothing.
    private func adoptDisplayName() async {
        guard let desired = displayName, let marker = displayNameMarker else { return }
        // Once, ever. Recorded locally rather than read back from the node
        // because no MCP tool returns the agent's current display name —
        // `sage_status` describes the node, not the caller — so a read-back
        // guard would never match and this would put a consensus write on the
        // chain every time the owner restarted the appliance, to change nothing.
        //
        // The happier consequence: if the operator renames this agent in
        // CEREBRUM, their choice stands. The app names itself once and then
        // stops having an opinion.
        guard (try? String(contentsOf: marker, encoding: .utf8)) != desired else { return }
        do {
            _ = try await tools.call(name: Tool.rename, arguments: ["name": .string(desired)])
            try? OwnerOnlyFileSecurity.prepareDirectory(marker.deletingLastPathComponent())
            try? Data(desired.utf8).write(to: marker, options: .atomic)
            log("[sage] display name set to \(desired)")
        } catch {
            // Cosmetic. The agent works under whatever name it has, and failing
            // a boot because a label would not update would be absurd.
            log("[sage] could not set display name: \(error)")
        }
    }

    /// The session context folded into a system prompt.
    public func systemPrompt(base: String) -> String {
        guard let bootContext else { return base }
        return """
        \(base)

        WHAT YOU WERE DOING BEFORE
        This is your own memory from previous sessions, recalled at start-up. \
        Use it to pick up where you left off. Do not read it aloud unless asked.
        \(bootContext)
        """
    }

    // MARK: - Per turn

    /// Records the turn and recalls anything relevant to it.
    ///
    /// Called after the reply is sent, not before: the owner waits ~40s for a
    /// turn already, and this is housekeeping they should never pay latency for.
    /// The recall half of `sage_turn` therefore lands in SAGE for *next* time
    /// rather than this time, which is the right trade for an appliance whose
    /// dominant cost is the model.
    public func recordTurn(transcript: String, reply: String, usedTools: [String]) async {
        turnCount += 1
        turnsSinceReflect += 1

        let topic = Self.topic(from: transcript)
        let observation = Self.observation(transcript: transcript, reply: reply, usedTools: usedTools)

        // Already refused once. See `writeDenial`: retrying is the bug, not the
        // fix. The turn still counted above so the reflect cadence stays honest
        // if the owner grants access and restarts.
        guard writeDenial == nil else { return }

        do {
            let answer = try await tools.call(
                name: Tool.turn,
                arguments: [
                    "topic": .string(topic),
                    "observation": .string(observation),
                    // A dedicated domain, so the appliance's episodic chatter
                    // does not dilute recall in the domains real work uses —
                    // and, since app-v22, the only domain it is able to write.
                    // See `memoryDomain`.
                    "domain": .string(Self.memoryDomain)
                ]
            )
            // **This answer used to be `_`, and that discarded every reply the
            // owner's other agents ever sent back.**
            //
            // A reply to work Mynah piped out does not arrive in the inbox.
            // `sage_inbox` says so itself: *"This does not return results for
            // pipes you sent; completed results arrive separately in
            // sage_turn.pipe_results, so a clean inbox is not evidence that no
            // reply exists."* This is the only place this appliance calls
            // `sage_turn`, so this was the only place a result could have been
            // seen — and it was thrown away.
            //
            // The owner watched it happen: he had Mynah send a test note, it
            // was delivered and acknowledged within seconds, and when he asked
            // *"anything in the inbox?"* Mynah answered *"Inbox is clear."*
            // Truthfully. It had checked the one place the answer could not be.
            noteResults(in: answer)
        } catch {
            note(error, whileDoing: "turn")
        }

        if writeDenial == nil, turnsSinceReflect >= Self.reflectEveryTurns {
            turnsSinceReflect = 0
            await reflect()
        }
    }

    // MARK: - Replies to work this appliance sent out

    /// A reply from another agent to work Mynah piped to it.
    public struct PipeReply: Sendable, Equatable {
        /// Who answered, as the node names them.
        public let from: String
        /// What they said. Untrusted, like everything else that arrives from
        /// another agent — see `UntrustedAgentContent`.
        public let text: String

        /// One sentence for the owner, attributed.
        public var spokenDescription: String {
            "\(from) replied: \(text)"
        }
    }

    private var arrivedReplies: [PipeReply] = []

    /// Replies that have come back since this was last called, and clears them.
    ///
    /// Draining rather than reading, for the reason `NotesToolSource` drains:
    /// the caller says these out loud once, and a reply that rode along with a
    /// second message because nobody cleared the list is a confusing thing to
    /// chase from a phone.
    public func drainReplies() -> [PipeReply] {
        let drained = arrivedReplies
        arrivedReplies = []
        return drained
    }

    /// Pulls any `pipe_results` out of a `sage_turn` answer.
    ///
    /// **Read tolerantly and logged the first time, because the exact shape is
    /// not documented and this appliance cannot afford to be wrong about it in
    /// either direction.** A key that turns out to be named something else
    /// would silently reproduce the very bug this fixes, so the raw payload is
    /// logged whenever the field is present — one line, once per arrival, and
    /// the log then says what the real keys are rather than this comment
    /// guessing.
    func noteResults(in answer: String) {
        guard let root = SageReply.object(in: answer) else { return }
        guard let results = root["pipe_results"] as? [[String: Any]], !results.isEmpty else {
            return
        }
        log("[sage] \(results.count) pipe result(s) came back: \(String(describing: results).prefix(300))")

        // Born on this turn. Everything the node is holding gets written down
        // and none of it is said — see `AlreadySaid.hasSeeded`.
        let seeding = !(alreadySaid.hasSeeded ?? !alreadySaid.ids.isEmpty)
        if seeding {
            log("[sage] first look at pipe results: noting \(results.count) without saying them")
        }

        var changed = false
        for result in results {
            let from = Self.text(result, ["from", "from_name", "agent", "responder"])
                ?? "one of your agents"
            guard let said = Self.text(result, ["result", "payload", "content", "text", "message"]) else {
                continue
            }
            // Once, ever. The node goes on offering a result after it has been
            // handed over, so what stops a repeat is this ledger and nothing
            // else. The pipe id when there is one; otherwise what was said, by
            // whom — two replies identical in both are indistinguishable to a
            // reader anyway, so treating them as one costs nothing.
            let identity = Self.text(result, ["pipe_id", "id"]) ?? "\(from)|\(said)"
            guard !alreadySaid.has(identity) else { continue }
            alreadySaid.remember(identity)
            changed = true
            guard !seeding else { continue }
            arrivedReplies.append(PipeReply(from: Self.shortened(from), text: said))
        }
        if seeding {
            alreadySaid.hasSeeded = true
            changed = true
        }
        if changed { alreadySaid.save(to: alreadySaidFile) }
    }

    private static func text(_ object: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    /// A 64-character hex agent id is not a name anybody can hear read out.
    private static func shortened(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > 24, trimmed.allSatisfy({ $0.isHexDigit }) else { return trimmed }
        return String(trimmed.prefix(8)) + "…"
    }

    private func reflect() async {
        do {
            _ = try await tools.call(
                name: Tool.reflect,
                arguments: [
                    "task_summary": .string(
                        "Voice appliance handled \(turnCount) spoken turns for the owner over Signal."
                    ),
                    "domain": .string(Self.memoryDomain)
                ]
            )
            log("[sage] reflected after \(turnCount) turns")
        } catch {
            note(error, whileDoing: "reflect")
        }
    }

    // MARK: - Telling a refusal from a failure

    /// Records a failed write, latching the permanent kind.
    ///
    /// The distinction is the whole point of this function: a transport failure
    /// is worth trying again next turn and a permission refusal is not, and the
    /// appliance previously logged both with the same sentence and forgot them
    /// both just as fast.
    private func note(_ error: Error, whileDoing what: String) {
        guard let denial = Self.permanentDenial(in: "\(error)") else {
            log("[sage] \(what) failed: \(error)")
            return
        }
        writeDenial = denial
        // Loud, once, and naming the domain. This is the sentence someone reads
        // in a log six months from now while wondering why an appliance that
        // has answered thousands of questions remembers none of them.
        // Prefers SAGE's own remedy when it sent one — it is per-cause and
        // maintained by the people who own the rule. Ours is the fallback for a
        // server too old to have an opinion.
        let remedy = denial.remedy
            ?? "The owner has to assign this agent a companion profile and a subject it owns, in CEREBRUM."
        log(
            "[sage] PERMANENTLY REFUSED (\(denial.reasonCode ?? "no reason code")): this agent cannot "
                + "write \"\(denial.domain)\", so nothing said to Mynah is being stored. "
                + "\(remedy) Not retrying. Node said: \(denial.detail)"
        )
    }

    /// The RFC 7807 problem type SAGE returns for a refusal that will not change
    /// on its own (`api/rest/memory_handler.go`, `internal/mcp/server.go`).
    ///
    /// This string is the contract, so it is matched first and exactly.
    static let domainWriteDeniedProblemType = "https://sage.dev/errors/domain-write-denied"

    /// Whether a failure is a permission refusal rather than a bad moment.
    ///
    /// Matching on message text is normally how a UI ends up rewritten by a
    /// reworded sentence, and this file's own neighbours say so. It is done here
    /// because there is no typed channel to read instead: `ToolProviding.call`
    /// returns a `String`, so a tool failure arrives as prose whatever the node
    /// meant by it.
    ///
    /// So the problem-type URI is tried first and is a real contract. The
    /// consensus phrases below are the fallback for a denial that reaches us as
    /// a raw ABCI log rather than through the REST problem shape — they are
    /// quoted from `processMemorySubmit` and are NOT a contract. A denial this
    /// misses is logged as an ordinary failure and retried next turn, which is
    /// the safe direction to be wrong in: noisy, not silent.
    static func permanentDenial(in message: String) -> WriteDenial? {
        // The typed channel first. SAGE v11.14.2 returns a stable `reason_code`
        // with `retryable:false` and a per-cause `remedy`, which is exactly what
        // this function had to reconstruct from prose before it existed.
        if let code = jsonString(forKey: "reason_code", in: message), knownReasonCodes.contains(code) {
            return WriteDenial(
                domain: domain(in: message) ?? memoryDomain,
                detail: condense(message, to: 300),
                reasonCode: code,
                remedy: jsonString(forKey: "remedy", in: message)
            )
        }

        // Older servers, and only older servers. The reference is explicit that
        // "generic denials from older servers retain the bounded compatibility
        // recovery path", so this stays rather than being replaced.
        let lowered = message.lowercased()
        let isDenial = lowered.contains(domainWriteDeniedProblemType)
            || lowered.contains("cannot write shared domain")
            || lowered.contains("cannot claim unowned domain")
            || lowered.contains("cannot write domain")
            || lowered.contains("no write access to domain")
            || lowered.contains("does not have write access")
        guard isDenial else { return nil }
        return WriteDenial(domain: domain(in: message) ?? memoryDomain, detail: condense(message, to: 300))
    }

    /// The seven stable codes, from SAGE's REST reference.
    ///
    /// Matched against a known set rather than accepted as-is, because the
    /// reference says unknown structured codes fall back to the compatibility
    /// path — so a code we do not recognise must reach the prose matcher below
    /// rather than be reported as a cause we cannot explain.
    ///
    /// Note the spellings. These are the ones in `rest-api.md`; a summary I was
    /// given quoted `deny_domain_claim`, `pending_unapproved` and
    /// `missing_level_2_grant`, none of which appear in the reference. Checked
    /// rather than trusted, because a code that never matches would silently
    /// downgrade every typed denial to the legacy path.
    static let knownReasonCodes: Set<String> = [
        "missing_write_grant",
        "foreign_write_restricted",
        "shared_write_restricted",
        "domain_claim_restricted",
        "principal_pending_review",
        "no_owned_home_domain",
        "manager_scope_denied"
    ]

    /// Pulls a string value out of whatever JSON is embedded in the message.
    ///
    /// Deliberately tolerant. The denial reaches us as the text of a thrown
    /// error, which may be bare JSON, JSON wrapped in a sentence, or the
    /// problem document nested under `store_error` — and the shape differs
    /// between the tool that failed and the transport that carried it. Scanning
    /// for the key is stable across all of those, where a decode against one
    /// assumed shape would silently return nothing for the other two.
    static func jsonString(forKey key: String, in message: String) -> String? {
        guard let keyRange = message.range(of: "\"\(key)\"") else { return nil }
        let rest = message[keyRange.upperBound...]
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        var remainder = rest[rest.index(after: colon)...].drop { $0 == " " }
        guard remainder.first == "\"" else { return nil }
        remainder = remainder.dropFirst()
        var value = ""
        var escaped = false
        for character in remainder {
            if escaped {
                value.append(character)
                escaped = false
                continue
            }
            if character == "\\" { escaped = true; continue }
            if character == "\"" { break }
            value.append(character)
        }
        return value.isEmpty ? nil : value
    }

    /// Pulls the domain out of the node's sentence, so the owner is told which
    /// one to grant. Falls back to the domain we asked for, which is the same
    /// answer in every case the appliance itself produces.
    private static func domain(in message: String) -> String? {
        for marker in ["domain '", "domain \"", "domain "] {
            guard let range = message.range(of: marker) else { continue }
            let rest = message[range.upperBound...]
            let name = rest.prefix { !$0.isWhitespace && $0 != "'" && $0 != "\"" && $0 != "," }
            if !name.isEmpty { return String(name) }
        }
        return nil
    }

    // MARK: - Shaping

    /// A short topic string for contextual recall.
    ///
    /// Derived rather than asked for. Asking the model would cost another turn
    /// — 20+ seconds on this hardware — to produce a phrase used only as a
    /// recall key, where the first few words of what the owner actually said
    /// are already a good one.
    static func topic(from transcript: String) -> String {
        let cleaned = transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        guard !cleaned.isEmpty else { return "voice turn" }
        let words = cleaned.split(separator: " ").prefix(12)
        return words.joined(separator: " ")
    }

    /// SAGE silently drops observations under 30 characters as low-value, so
    /// this always carries both sides of the exchange.
    static func observation(transcript: String, reply: String, usedTools: [String]) -> String {
        let asked = condense(transcript, to: 300)
        let answered = condense(reply, to: 400)
        let via = usedTools.isEmpty ? "no tools" : usedTools.joined(separator: ", ")
        return "Owner asked over Signal: \(asked) — appliance answered using \(via): \(answered)"
    }

    /// Collapses whitespace and truncates at a word boundary.
    static func condense(_ text: String, to limit: Int) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > limit else { return collapsed }
        let clipped = collapsed.prefix(limit)
        guard let lastSpace = clipped.lastIndex(of: " ") else { return String(clipped) + "…" }
        return String(clipped[..<lastSpace]) + "…"
    }
}
