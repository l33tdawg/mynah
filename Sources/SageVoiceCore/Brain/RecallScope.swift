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

    /// When the node was last asked. Nil for a record written before this
    /// existed, which counts as stale.
    public var checkedAt: Date?

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

    public func isFresh(now: Date = Date()) -> Bool {
        guard let checkedAt, !domains.isEmpty else { return false }
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
    /// `home_domain` leads because it is where this agent's own work lives.
    /// `writesTo` follows and is included **whether or not the node listed it**:
    /// `by_domain` reports what the caller can currently see, and a domain with
    /// nothing in it yet is still the domain the next `sage_remember` lands in.
    /// Everything else the node named comes after, so a granted shared domain is
    /// searched but never ahead of the appliance's own.
    public static func fromStatus(_ reply: String, writesTo: String) -> ReadableDomains? {
        guard let status = SageReply.object(in: reply) else { return nil }
        var ordered: [String] = []
        func add(_ domain: String?) {
            guard let domain, !domain.isEmpty, !ordered.contains(domain) else { return }
            ordered.append(domain)
        }
        add(status["home_domain"] as? String)
        add(writesTo)
        if let counts = status["by_domain"] as? [String: Any] {
            // Sorted, so two boots in a row produce the same order and the
            // cached file does not churn for a dictionary's iteration order.
            for domain in counts.keys.sorted() { add(domain) }
        }
        guard !ordered.isEmpty else { return nil }
        return ReadableDomains(domains: ordered, checkedAt: Date())
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
        let known = ReadableDomains.load(from: domainsFile).domains
        guard !known.isEmpty else {
            // Nothing discovered yet — send it as the model wrote it. On a node
            // that still answers unscoped recall this is correct, and on one
            // that does not, the refusal is the node's own sentence rather than
            // a guess of ours dressed up as an answer.
            return try await wrapped.call(name: name, arguments: arguments)
        }

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
