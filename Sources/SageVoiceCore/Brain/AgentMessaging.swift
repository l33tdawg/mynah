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

    /// The sender of a message the node handed us, as a recipient to answer.
    ///
    /// **This is the one address that does not need `sage_find_agent`, and the
    /// reason is worth stating rather than assuming.** The type exists to stop
    /// an address being conjured from a name somebody typed. `sender_agent` is
    /// the opposite of that: SAGE puts it on every inbox item as the exact,
    /// authenticated identity that signed the message — its own words are that
    /// it is *"the authoritative exact local identity"* while display,
    /// registered-name and provider labels are *"optional presentation
    /// metadata"* and *"no label establishes authorization"*. Resolving a name
    /// to reach that agent would be strictly worse: it asks a mutable label to
    /// reproduce an id the node already told us exactly.
    ///
    /// **Only available since SAGE 11.18.12.** Before it, `sender_agent` was
    /// emitted for *foreign* items and omitted for local ones, so on an older
    /// node the local case has no exact identity to carry and this returns nil.
    /// Nil means "ask the node" — never "invent one from the label".
    ///
    /// Named for where the id came from rather than what it is for, because a
    /// bare `init` here would read exactly like the forgery the type refuses.
    static func asAttributedByTheNode(
        senderAgent: String,
        displayName: String,
        isForeign: Bool
    ) -> AgentAddress? {
        let exact = senderAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !exact.isEmpty else { return nil }
        return AgentAddress(
            wire: exact,
            displayName: displayName.isEmpty ? exact : displayName,
            isForeign: isForeign
        )
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

    /// Who to answer, exactly — not the label they are announced under.
    ///
    /// **`content.sender` is a name and this is an identity, and the difference
    /// has already cost the owner once.** The label is chosen by the node for
    /// display and can change; two agents from one provider used to announce
    /// identically, and a reply addressed by name is how his messages once
    /// reached strangers. Anything *sending* must use this; anything *speaking*
    /// should use the label, because reading a 64-character hex string to
    /// somebody is not an answer.
    ///
    /// Nil on a node before SAGE 11.18.12, which omitted `sender_agent` on
    /// local items — and nil is a real answer meaning "ask the node", never a
    /// licence to rebuild it from the label.
    public let replyTo: AgentAddress?

    public init(
        id: String,
        content: UntrustedAgentContent,
        intent: String?,
        arrived: Date?,
        expectsAResult: Bool,
        replyTo: AgentAddress? = nil
    ) {
        self.id = id
        self.content = content
        self.intent = intent
        self.arrived = arrived
        self.expectsAResult = expectsAResult
        self.replyTo = replyTo
    }
}

/// A message the owner sent, as far as the node is concerned.
public struct SentAgentMessage: Sendable, Equatable {
    public let messageID: String
    public let to: AgentAddress
    public let sent: Date
}

// MARK: - Work this appliance can see and cannot have

/// What `sage_inbox` says about messages held under *another* session's claim.
///
/// ## Why this exists at all
///
/// The appliance can be woken by the node — `MessageWakeBus` says canonical
/// inbox work was durably inserted — look, and find nothing. Today that is
/// unexplainable from the log: the wake line goes in, the check reports nothing
/// changed, and there is no third line saying which of the two ordinary causes
/// it was. One of them is that the work is real and already claimed by another
/// runtime sharing this agent identity, where it will stay until that session
/// finishes or the message expires.
///
/// ## Why three cases rather than an `Int?`
///
/// **The node's own contract sentence is that "an unavailable probe is explicit
/// and never presented as zero"**, and the mechanism behind it is visible in
/// the vendored binary: the field is a *pointer* to a struct —
/// `*struct { Count int "json:\"claimed_elsewhere_count\"" }` — so when the
/// probe cannot run the key is omitted entirely rather than sent as `0`.
///
/// Modelled as an `Int` with a `?? 0` anywhere on this path, "I could not find
/// out" silently becomes "nothing is held elsewhere". That is this project's
/// worst defect class — a feature reporting a success it did not achieve —
/// landing in the one log line whose entire job is telling those two apart. So
/// they are three cases, for the same reason `AgentMessagingTrouble` is an enum
/// rather than one string: three different facts with three different next
/// steps, and a type is what stops a future reader flattening two of them.
public enum ClaimedElsewhere: Sendable, Equatable {
    /// The probe ran and this is its answer. Exact and payload-free — the node
    /// hands over a number and never the messages themselves.
    case counted(Int, state: String)
    /// The probe could not answer. **Not a count of zero**, and the whole
    /// reason this type is not an `Int?`.
    case unavailable(state: String)
    /// The reply carried no probe at all.
    ///
    /// Which SAGE release introduced these keys is deliberately not asserted
    /// anywhere here or in the log sentence: it could not be determined, and
    /// this file already carries a long correction about a comment that stated
    /// a durability window it had not measured. `claimed_elsewhere_*` **is**
    /// present in the vendored node, so this case is a real older-node answer
    /// rather than the ordinary one.
    case notReported

    /// One line for `bridge.log`, said the same way every time.
    ///
    /// ## Why the sentence is built here and not where it is logged
    ///
    /// `runProactiveWatch` lives in the `sage-voiced` executable, which no test
    /// can import — the same reason `VoiceBridgeDaemon.relayed` is a static on a
    /// library type. A sentence that can only be produced inside the daemon is a
    /// sentence nothing can pin, and the distinction this one exists to make is
    /// exactly the kind that rots quietly.
    ///
    /// ## Why it takes the Optional
    ///
    /// `nil` is a fourth fact: the inbox was not read on this check *at all*.
    /// Collapsing it into `.notReported` would have a node with a working probe
    /// described as a node without one, every time it was unreachable — the
    /// same "could not ask" reported as "there is nothing to ask about" that
    /// this whole type is built to refuse.
    ///
    /// **None of the five asserts what the check found.** A claim held elsewhere
    /// is perfectly compatible with there also being new work in this reply, so
    /// the line reports the field and stops.
    public static func forTheLog(_ reading: ClaimedElsewhere?) -> String {
        // Verbatim, never enumerated. `state` has been observed with exactly one
        // value ("present"), and inventing a vocabulary for a field on that
        // evidence is what `AgentMessagingTrouble.terminalFailure` warns against
        // one file over. The appliance never branches on it; it only prints it.
        func clause(_ state: String) -> String {
            state.isEmpty ? "" : " (state: \(state))"
        }
        switch reading {
        case .counted(let held, let state) where held > 0:
            return "the node reports \(held) unfinished message(s) held by another claimant "
                + "session\(clause(state)); this appliance cannot take those over — they clear "
                + "when that session finishes or the message expires."
        case .counted(_, let state):
            // Zero, and anything below it. A negative is not a shape the node
            // can produce, and if one ever arrived the honest reading is still
            // "nothing is being held", which is this sentence.
            return "the node reports no message held by another claimant session\(clause(state)); "
                + "a wake that found nothing is not explained by a stranded claim."
        case .unavailable(let state):
            return "the node could not probe for messages held by another "
                + "session\(clause(state)). This is not a count of zero."
        case .notReported:
            return "this node does not report claimed-elsewhere counts, so a wake that finds "
                + "nothing cannot be explained from here."
        case nil:
            return "the inbox could not be read on this check, so nothing can be said about "
                + "messages held elsewhere."
        }
    }
}

/// One reading of the inbox: what is waiting, and what the node said about work
/// it is holding for somebody else.
///
/// A pair rather than two calls, because they arrive in one reply and asking
/// twice would claim the inbox twice.
public struct AgentInboxReading: Sendable, Equatable {
    public let items: [AgentInboxItem]
    public let claimedElsewhere: ClaimedElsewhere

    public init(items: [AgentInboxItem], claimedElsewhere: ClaimedElsewhere) {
        self.items = items
        self.claimedElsewhere = claimedElsewhere
    }
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
    /// The node answered, and the answer was not an inbox.
    ///
    /// **A distinct case because "nothing is waiting" and "I could not look" are
    /// opposite facts**, and the read used to hand both of them back as an empty
    /// list. See `SageAgentMessaging.inboxReading`.
    case unreadableInbox(String)

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
            return Self.ownerSentence(forRefusal: detail)
        case .nodeUnavailable:
            return "Mynah can't reach your SAGE node, so it can't send anything to your agents."
        case .unreadableInbox:
            return "Your SAGE node answered, but Mynah couldn't read the reply, so it can't say "
                + "what's waiting for you."
        }
    }

    /// The node's refusal, in the owner's terms.
    ///
    /// **This used to append the node's own words verbatim**, which put
    /// `MCP tool 'sage_inbox' failed: Error: pipeline inbox: Active agent
    /// required: agent pipeline work is available only to an active ordinary
    /// agent on this SAGE.` on a page a non-technical owner reads. Every word of
    /// that is accurate and none of it tells them what to do.
    ///
    /// The one refusal that actually happens on a fresh install is the restricted
    /// appliance, and it has the same cause and the same fix as the warning on the
    /// Agents page — so it says the same thing, rather than describing one problem
    /// in two vocabularies. Anything unrecognised gets a plain sentence; the raw
    /// text is still available through `technicalDetail` for the administrator
    /// disclosure, which is where a node's internal vocabulary belongs.
    static func ownerSentence(forRefusal detail: String) -> String {
        let lowered = detail.lowercased()
        if lowered.contains("active ordinary agent") || lowered.contains("active agent required") {
            return "Mynah can't exchange messages with your other agents until it has its own "
                + "memory. Somebody with administrator access to SAGE has to set that up."
        }
        return "Your SAGE node turned that down. Nothing was sent."
    }

    /// The node's own words, for the administrator disclosure rather than the
    /// owner. `nil` where there is nothing a node said.
    public var technicalDetail: String? {
        switch self {
        case .refused(let detail):
            return detail
        case .unreachable(_, let why):
            return why
        case .unreadableInbox(let reply):
            return reply
        case .noSuchAgent, .ambiguousName, .nodeUnavailable:
            return nil
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
    ///
    /// **`retrying` is the requirement, and the plain send is the convenience.**
    /// It would read better the other way round, with a defaulted parameter on
    /// an extension — but a default that quietly mints a fresh key turns a
    /// conformer's omission into a duplicate message the owner cannot unsend.
    /// Making the key-carrying form the thing a type must implement means the
    /// compiler asks the question instead.
    ///
    /// Pass a key only when re-attempting a send that was already recorded
    /// somewhere durable — `CallActionQueue` mints one at enqueue and presents
    /// the same one on every drain, so a drain interrupted after the node
    /// accepted the message returns the original `message_id` instead of
    /// sending twice. Pass nil for an ordinary send, which is one logical send
    /// and wants its own fresh key.
    func send(
        _ message: String,
        to recipient: AgentAddress,
        intent: String?,
        retrying key: String?
    ) async throws -> SentAgentMessage
    /// What is waiting, **and what the node is holding for somebody else**.
    /// Called when the owner looks, never on a timer.
    ///
    /// **The reading is the requirement and the plain list is the convenience,
    /// for the same reason `retrying` is the requirement above.** It would read
    /// better the other way round — add `inboxReading` to the extension with a
    /// default of `.notReported` and leave every conformer alone. That default
    /// would be a lie with a specific shape: a conformer that simply had not
    /// been updated would report *"this node does not have a claimed-elsewhere
    /// probe"* about a node that does, and the sentence built from it would
    /// close off the one explanation a puzzled reader came looking for.
    ///
    /// Making the reading the thing a type must implement means the compiler
    /// asks the question instead. Everything that only wants the items keeps
    /// calling `inbox(limit:)` below, unchanged.
    func inboxReading(limit: Int) async throws -> AgentInboxReading
}

public extension AgentMessaging {
    func send(_ message: String, to recipient: AgentAddress) async throws -> SentAgentMessage {
        try await send(message, to: recipient, intent: nil, retrying: nil)
    }
    func send(
        _ message: String,
        to recipient: AgentAddress,
        intent: String?
    ) async throws -> SentAgentMessage {
        try await send(message, to: recipient, intent: intent, retrying: nil)
    }
    /// Just the items, for the callers that have no use for the probe.
    func inbox(limit: Int) async throws -> [AgentInboxItem] {
        try await inboxReading(limit: limit).items
    }
    func inbox() async throws -> [AgentInboxItem] { try await inbox(limit: 20) }
}
