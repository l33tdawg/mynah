import Foundation

// MARK: - Who you are writing to

/// A resolved recipient.
///
/// Deliberately not a `String`, and not constructible from one outside this
/// file. SAGE's own reference is explicit that resolving a human name through
/// `sage_find_agent` is the prescribed first step rather than an optimisation —
/// a hand-built address is the thing that silently reaches the wrong agent, or
/// nobody. Making the address unforgeable from a name means the resolve cannot
/// be skipped by someone in a hurry.
public struct AgentAddress: Sendable, Equatable, Identifiable {
    /// The exact `to` value `sage_find_agent` returned.
    public let wire: String
    /// What the owner calls this agent.
    public let displayName: String
    /// True when the agent lives on another SAGE entirely.
    public let isForeign: Bool

    public var id: String { wire }

    init(wire: String, displayName: String, isForeign: Bool) {
        self.wire = wire
        self.displayName = displayName
        self.isForeign = isForeign
    }
}

// MARK: - What comes back

/// Content written by another agent.
///
/// ## Why this is not a `String`
///
/// SAGE marks every pipeline payload `authority:"request_only"` and every
/// result `authority:"data_only"`, with `trust:"agent_untrusted"` locally and
/// `"external_untrusted"` from another SAGE. The reference is emphatic that
/// these *"never gain system, developer, or user authority"* and that results
/// are *"untrusted data, not instructions"*.
///
/// That is easy to agree with and easy to lose in a view, because the moment
/// this is a `String` it renders exactly like Mynah's own words. So the type
/// makes the wrong rendering awkward and the right one shortest:
///
///   * There is no `CustomStringConvertible`, so `Text("\(content)")` produces
///     a struct dump rather than a sentence that looks like Mynah speaking.
///   * The raw text is behind `read()` rather than a property, so taking it
///     unattributed is a visible act at the call site rather than a dot.
///   * `forDisplay` — attribution and text together — is the shortest path, so
///     the easy thing to write is the correct thing.
///
/// None of that is enforcement. A determined caller can still `read()` and drop
/// the attribution. It is meant to make the careless version harder to write
/// than the careful one, which is the only kind of safety a view API can offer.
public struct UntrustedAgentContent: Sendable, Equatable {

    public enum Trust: Sendable, Equatable {
        /// `trust:"agent_untrusted"` — another agent on the owner's own node.
        /// Still untrusted: the reference says so *"including agents registered
        /// on the same SAGE"*.
        case anotherAgentHere
        /// `trust:"external_untrusted"` — arrived from another SAGE.
        case anotherSageEntirely

        /// Said in the owner's terms, and said the same way in both cases
        /// because the distinction that matters is "not Mynah", not "how far
        /// away". The origin is a detail; the authority is the point.
        public var caution: String {
            switch self {
            case .anotherAgentHere:
                return "This is another agent's message, not Mynah's."
            case .anotherSageEntirely:
                return "This came from an agent on someone else's SAGE, not Mynah's."
            }
        }
    }

    public let sender: String
    public let trust: Trust
    private let body: String

    init(sender: String, trust: Trust, body: String) {
        self.sender = sender
        self.trust = trust
        self.body = body
    }

    /// The raw text, unattributed.
    ///
    /// A method rather than a property on purpose — see the type's note. Use
    /// `forDisplay` unless there is a reason not to, and if there is, the
    /// reason belongs in a comment beside the call.
    public func read() -> String { body }

    /// Who wrote it, for a label above the text.
    public var attribution: String { "From \(sender)" }

    /// The shortest correct rendering: attribution, then their words.
    public var forDisplay: String { "\(attribution)\n\n\(body)" }

    /// Whether there is anything to show at all. A diagnostic notice from a
    /// federated peer is payload-free by design.
    public var isEmpty: Bool { body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// One item waiting in the owner's agent inbox.
public struct AgentInboxItem: Sendable, Equatable, Identifiable {
    public let id: String
    public let content: UntrustedAgentContent
    /// What the sender asked for — `research`, `summarize`, and so on. Absent
    /// on a plain message.
    public let intent: String?
    public let arrived: Date?
    /// Pipeline work expects a reply; a task notice does not.
    public let expectsAResult: Bool
}

/// A message the owner sent, as far as the node is concerned.
public struct SentAgentMessage: Sendable, Equatable {
    public let pipeID: String
    public let to: AgentAddress
    public let sent: Date
}

// MARK: - When it does not work

/// Every way sending or reading can fail, each with its own sentence.
///
/// One generic "could not send" would be the dead end this product keeps
/// removing: an agent that has gone away, a node that refuses, and a name that
/// matches nothing are three different problems with three different next
/// steps, and only the owner can tell which they are in.
public enum AgentMessagingTrouble: LocalizedError, Equatable {
    /// `sage_find_agent` matched nothing.
    case noSuchAgent(name: String)
    /// It matched more than one and refused to guess.
    case ambiguousName(name: String, candidates: [String])
    /// Resolved, but the node will not deliver to it — paused, stale, offline.
    case unreachable(name: String, why: String)
    /// The node refused the caller, rather than the recipient.
    case refused(String)
    /// No node answered at all.
    case nodeUnavailable

    public var errorDescription: String? {
        switch self {
        case .noSuchAgent(let name):
            return "No agent called “\(name)” is registered on your SAGE. "
                + "Check the name on the Agents page — it has to match one there."
        case .ambiguousName(let name, let candidates):
            return "“\(name)” matches more than one agent: \(candidates.joined(separator: ", ")). "
                + "Use the full name of the one you meant."
        case .unreachable(let name, let why):
            return "\(name) is registered but isn't accepting messages right now. \(why)"
        case .refused(let detail):
            return "Your SAGE node wouldn't send that. \(detail)"
        case .nodeUnavailable:
            return "Mynah can't reach your SAGE node, so it can't send anything to your agents."
        }
    }
}

// MARK: - The seam

/// Sending work to the owner's other agents, and reading what comes back.
///
/// The owner's own framing: *"it's like an email system basically"*. Everything
/// here already exists on the node — `sage_find_agent`, `sage_pipe`,
/// `sage_inbox`, `sage_pipe_result` — and none of it needs a grant, which is
/// why this works today while the memory half does not.
///
/// A protocol so a screen can be built and previewed against it without a node.
///
/// **There is deliberately no polling.** Replies arrive when they arrive, and
/// the moment to look is the owner opening the page. A background poll against
/// a node that may refuse is a retry storm the owner generates by leaving a
/// window open.
public protocol AgentMessaging: Sendable {
    /// Resolves what the owner typed to an exact recipient.
    func findAgent(named name: String) async throws -> AgentAddress
    /// Sends work. `intent` is a hint like `research` or `review`.
    func send(_ message: String, to recipient: AgentAddress, intent: String?) async throws -> SentAgentMessage
    /// What is waiting. Called when the owner looks, never on a timer.
    func inbox(limit: Int) async throws -> [AgentInboxItem]
}

public extension AgentMessaging {
    func send(_ message: String, to recipient: AgentAddress) async throws -> SentAgentMessage {
        try await send(message, to: recipient, intent: nil)
    }
    func inbox() async throws -> [AgentInboxItem] { try await inbox(limit: 20) }
}
