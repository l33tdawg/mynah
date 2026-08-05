import Foundation

/// The domains this appliance is allowed to search, and the recall that stays
/// inside them.
///
/// **SAGE 11.16.4 stopped answering unscoped recall.** A query with no `domain`
/// now comes back *"Recall query too broad: too many candidates require
/// authorization"* — an authorization guard rather than a fault, and the right
/// call on the node's side: an agent asking to semantically search everything
/// is asking the node to evaluate access on every memory on the machine.
///
/// It lands on us as a regression all the same, because the model omits
/// `domain` most of the time. From the owner's own node, tested by Mynah:
/// *"With a domain scoped, recall works fine, semantic mode not degraded."* So
/// the fix is to supply the scope rather than to teach a 4B to remember an
/// optional argument it has been ignoring since the day it was offered.
///
/// ## Why the domains are discovered and not written down here
///
/// The owner: *"scope it to what it writes to and needs read from"*. That set
/// is knowable exactly — `sage_status` returns the caller's `home_domain` and a
/// `by_domain` breakdown of what it can actually see — and it is **not**
/// knowable by us. `MemoriesView` already carries a warning about this: the
/// appliance's home on the owner's node is `mynah-home`, which is not a name
/// this codebase would have derived from anything, while `sage_status` signed
/// as Mynah returns it without being asked.
///
/// A constant would be a fourth place that has to agree with the node, and the
/// class of bug that produces is the one this project keeps paying for: a
/// silent mismatch where writes are refused and nothing is said.
public struct ReadableDomains: Codable, Equatable, Sendable {

    /// In search order: home first, then where it files what it is told, then
    /// anything else the node says it can read.
    public var domains: [String]

    /// When the node was last *asked*, whether or not it answered.
    ///
    /// Attempted rather than succeeded, and the difference is ninety seconds of
    /// somebody's afternoon. `sage_status` signed as this appliance does not
    /// return on 11.16.4 — it times out — so a record that only remembered
    /// successes would spend a full timeout on every launch, forever, to learn
    /// the same nothing. The fallback below is what makes that affordable to
    /// give up on.
    public var checkedAt: Date?

    /// What to search when the node has not said otherwise.
    ///
    /// Not a guess and not a default in the lazy sense: it is the home domain
    /// this appliance's own vendored node is configured with, and the one the
    /// owner's node independently assigns it. Discovery exists to *add* to this
    /// once the node has been asked, not to establish it.
    ///
    /// **Recall has to work while `sage_status` does not.** With no fallback, a
    /// node that never answers the question leaves recall unscoped, which
    /// 11.16.4 refuses outright — so the owner's memory would be unreachable for
    /// as long as that bug lives.
    ///
    /// **This was two domains and they are now one.** It read
    /// `[SageRitual.memoryDomain, "mynah-home"]`, which was two names for two
    /// places while `memoryDomain` was `voice-interface` — a subject belonging
    /// to another agent. Correcting that constant collapsed the pair into the
    /// same string twice, which is how a list of "the domains we are known to
    /// use" quietly became a list of one domain searched twice. Written out
    /// rather than derived, so the next person to change `memoryDomain` cannot
    /// do the same thing by accident.
    public static let wellKnown = ["mynah-home"]

    /// The search order, falling back when nothing has been discovered.
    public var searchOrder: [String] { domains.isEmpty ? Self.wellKnown : domains }

    /// How long a discovered set is trusted.
    ///
    /// A day, because the answer changes when a person grants this agent
    /// something in CEREBRUM — which is rare, deliberate, and not worth a round
    /// trip at every start-up to detect. The owner's shape exactly: *"maybe not
    /// every single conversation start, but you know what i mean"*.
    public static let freshFor: TimeInterval = 24 * 60 * 60

    public init(domains: [String] = [], checkedAt: Date? = nil) {
        self.domains = domains
        self.checkedAt = checkedAt
    }

    /// Whether the node has been asked recently enough to leave it alone.
    ///
    /// Does not require `domains` to be non-empty. A failed attempt counts, or
    /// the appliance pays a 90-second timeout at every single launch against a
    /// node that has already shown it will not answer.
    public func isFresh(now: Date = Date()) -> Bool {
        guard let checkedAt else { return false }
        return now.timeIntervalSince(checkedAt) < Self.freshFor
    }

    public static func defaultFileURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/SAGE Voice Bridge", isDirectory: true)
            .appendingPathComponent("readable-domains.json", isDirectory: false)
    }

    public static func load(from url: URL = ReadableDomains.defaultFileURL()) -> ReadableDomains {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(ReadableDomains.self, from: data) else {
            return ReadableDomains()
        }
        return stored
    }

    public func save(to url: URL = ReadableDomains.defaultFileURL()) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? OwnerOnlyFileSecurity.write(data, to: url)
    }

    /// Reads a `sage_status` reply into a search order.
    ///
    /// `home_domain` leads because it is where this agent's own work lives, and
    /// the rest of what it owns follows. **The subjects this agent owns are the
    /// answer, and they come from the node rather than from a constant here.**
    ///
    /// ## This read `by_domain`, and app-v26 does not send it
    ///
    /// The previous version took `home_domain`, then a `writesTo` the caller
    /// passed in, then every key of `by_domain`. On the owner's node — SAGE
    /// 11.17.9, app-v26 — `toolStatus` returns `callerBoundedStatus`, which
    /// emits `owned_domains`, `writable_domains` and `readable_domains` and
    /// never `by_domain`. SAGE's own route-security test asserts `by_domain` is
    /// *forbidden* in a caller-scoped response, so it is not coming back.
    ///
    /// The effect was visible in his log and nobody read it:
    ///
    ///     2026-08-03 18:42  recall is scoped to mynah-home, voice-interface,
    ///                       agent-104bda8bb082, … (about seven hundred more)
    ///     2026-08-05 19:52  recall is scoped to mynah-home, voice-interface
    ///
    /// Both are wrong and they are wrong in opposite directions. Seven hundred
    /// subjects is every domain the caller may *read* — most of them other
    /// people's projects — ordered arbitrarily and searched one after another.
    /// Two is whatever survived the key vanishing. Neither was chosen.
    ///
    /// ## Owned, not readable
    ///
    /// The owner's ruling, 5 August, on being shown that recall covered two of
    /// seventeen readable subjects: *"that is correct - that means the rbac is
    /// working as intended"*. Readable is not the right set — it is everything
    /// policy and provenance let this agent see, which on his node is most of
    /// his working life. Owned is: the subjects this appliance is responsible
    /// for, which is where the answer to "what did I tell you" actually lives.
    ///
    /// So `readable_domains` is deliberately not read here, though it is right
    /// there in the reply. A wider net would look like an improvement and would
    /// quietly widen recall past what he confirmed he wants.
    public static func fromStatus(_ reply: String) -> ReadableDomains? {
        guard let status = SageReply.object(in: reply) else { return nil }
        var ordered: [String] = []
        func add(_ domain: String?) {
            guard let domain, !domain.isEmpty, !ordered.contains(domain) else { return }
            ordered.append(domain)
        }
        add(status["home_domain"] as? String)
        // Sorted, so two boots in a row produce the same order and the cached
        // file does not churn for an array the node may reorder.
        for domain in (status["owned_domains"] as? [String] ?? []).sorted() { add(domain) }
        guard !ordered.isEmpty else { return nil }
        return ReadableDomains(domains: ordered, checkedAt: Date())
    }

    /// Where a write belongs: the subject this agent is responsible for.
    ///
    /// **Separate from the search order because it used to be a constant, and
    /// the constant named a domain belonging to somebody else.**
    /// `SageRitual.memoryDomain` was `voice-interface`, chosen when this
    /// appliance owned nothing and an administrator was going to transfer that
    /// subject to it. The transfer never happened. On the owner's node
    /// `voice-interface` is readable and is not in `writable_domains`, and it
    /// belongs to a different agent — so every episodic turn Mynah recorded went
    /// into another agent's subject.
    ///
    /// The owner, 5 August: *"we should make it default to its own home domain
    /// bro - voice-interface is YOUR DOMAIN - we will transfer it back to you"*.
    ///
    /// Asked rather than assumed, for the reason the whole of this file exists:
    /// a hardcoded domain is a claim about a node's configuration made months
    /// earlier, and it fails silently when it stops being true.
    public static func homeDomain(inStatus reply: String) -> String? {
        guard let status = SageReply.object(in: reply),
              let home = status["home_domain"] as? String,
              !home.isEmpty else { return nil }
        return home
    }
}

/// Supplies the `domain` the model leaves out.
///
/// A decorator rather than a change inside `ToolLoop`, because this is a
/// property of *this node version* and not of tool-calling: when SAGE ships
/// durable unscoped recall the wrapper comes off and nothing else moves.
///
/// Only `sage_recall`, and only when `domain` is absent. A model that names a
/// domain has said something specific and is obeyed — including when it names
/// one that returns nothing, which is a true answer to a precise question.
public struct ScopedRecall: ToolProviding {

    public static let recall = "sage_recall"

    private let wrapped: ToolProviding
    private let domainsFile: URL

    public init(wrapping wrapped: ToolProviding, domainsFile: URL = ReadableDomains.defaultFileURL()) {
        self.wrapped = wrapped
        self.domainsFile = domainsFile
    }

    public func listTools() async throws -> [MCPTool] {
        try await wrapped.listTools()
    }

    public func call(name: String, arguments: [String: JSONValue]) async throws -> String {
        guard name == Self.recall, arguments["domain"] == nil else {
            return try await wrapped.call(name: name, arguments: arguments)
        }
        // Read per call rather than held: the boot ritual writes this file, and
        // this wrapper is built before the ritual has run. Loading it here is
        // what makes the first turn after a discovery use the new set instead
        // of an empty snapshot taken at launch.
        // Falls back to the appliance's own two domains when discovery has not
        // run or could not. Passing it through unscoped instead would be the
        // more cautious-looking choice and the wrong one: 11.16.4 refuses the
        // unscoped form, so "cautious" would mean the owner's memory is
        // unreachable whenever `sage_status` is unwell — which, today, is
        // always.
        let known = ReadableDomains.load(from: domainsFile).searchOrder

        var lastReply: String?
        var lastError: Error?
        for domain in known {
            var scoped = arguments
            scoped["domain"] = .string(domain)
            do {
                let reply = try await wrapped.call(name: name, arguments: scoped)
                // `total_count` is the node's own figure, so this is reading a
                // field rather than interpreting prose — see `SageReply` for
                // why that distinction has already cost this project once.
                if Self.foundSomething(in: reply) { return reply }
                lastReply = reply
            } catch {
                lastError = error
            }
        }
        // Every domain answered and none held anything: return the last real
        // answer, which says "nothing found" in the node's own words.
        if let lastReply { return lastReply }
        throw lastError ?? BrainBackendError.unreachable("recall returned nothing on every readable domain")
    }

    static func foundSomething(in reply: String) -> Bool {
        guard let object = SageReply.object(in: reply) else {
            // Unparseable is not empty. Handing it back is how the model gets
            // to see whatever the node actually said.
            return true
        }
        if let total = object["total_count"] as? Int { return total > 0 }
        if let memories = object["memories"] as? [Any] { return !memories.isEmpty }
        return true
    }
}
