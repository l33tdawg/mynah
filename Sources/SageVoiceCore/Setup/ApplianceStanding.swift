import Foundation

/// What the node says about *this caller*, in the node's own words.
///
/// ## Why a statement and not a mask
///
/// The thing this replaces read an unsigned `GET /v1/agents`, found the
/// appliance's row, and inferred its standing from a capability bitmask. Every
/// part of that was wrong by 1.7.4, and each part independently:
///
///   * **The route is not public.** `/v1/agents` sits inside the group that
///     applies `Ed25519AuthMiddleware` and is wrapped in
///     `appV23PipelineAgentBoundary`, which 403s any non-active caller. Only
///     `/health` and `/ready` answer unsigned. Measured on the owner's node,
///     5 August 2026: `/v1/agents` → `401 Missing authentication headers`,
///     `/health` → `200`. So the read never succeeded and the standing was
///     always `.unknown`.
///   * **The mask it compared against is not the mask.** The old
///     `needsTheOwner` was `mask == 30`. The appliance's live mask is **31**.
///     Two independent reasons for the same dead guard.
///   * **A roster row proves nothing anyway.** It answers "does a row exist
///     under this name and is it active", and a *developer's* key on the same
///     machine passes both — which is how `SageAgentIdentity`'s comment came to
///     name the wrong agent with total confidence. See that file.
///
/// `sage_status` answers instead of implying. It is signed, so the reply is
/// necessarily about whoever signed it — the one question a roster cannot be
/// made to answer, because the answer *is* the signature. And it states
/// `approval_required`, `can_write`, `registration_status` and
/// `writable_domains` outright, so nothing here has to reconstruct a policy
/// decision from bits and then keep that reconstruction in step with SAGE.
///
/// The bits are still carried, in `capabilities`, because the owner-facing
/// `reasons` list explains *which* restriction applies and the node is the only
/// source for that. What changed is that no decision is taken by comparing them.
///
/// ## The shape is captured, not imagined
///
/// `Tests/Fixtures/sage_status-11.17.9-appv26-appliance.json` is a real reply,
/// signed as the appliance on the owner's node, with only the agent id redacted.
/// That matters more than it sounds: the 1.7.4 sweep found about thirty tests
/// across eight files asserting over SAGE shapes the node had stopped
/// producing — every one a literal somebody wrote by hand, every one green. Of
/// the files in `Tests/Fixtures`, the ones that have never rotted are the ones
/// captured from the thing they stand for.
public struct ApplianceStanding: Sendable, Equatable, Codable {

    /// Who the node thinks is asking. **This is the appliance's real id**,
    /// because it is derived from the signature rather than matched by name.
    public var agentID: String?

    /// The named profile an administrator assigned, e.g. `companion`.
    ///
    /// Read as a name rather than inferred from the mask, and that is a fix in
    /// itself: the old `hasCompanionProfile` tested `mask == 15`, while the
    /// owner's node reports `profile: "companion"` alongside `capabilities: 31`.
    /// So the appliance held the Companion profile and the predicate for it was
    /// false — a third dead guard in the same file.
    public var profile: String?
    public var role: String?

    /// `active`, `pending_review`, … — the node's vocabulary, kept verbatim.
    public var registrationStatus: String?
    public var enrollmentStatus: String?

    /// **The node saying a person has to act.** This is what `needsTheOwner` was
    /// always trying to detect, and here it is stated rather than inferred.
    public var approvalRequired: Bool

    public var canRead: Bool
    public var canWrite: Bool

    /// The app-v22 capability bits, for explaining *which* restriction applies.
    /// Never for deciding whether one does.
    public var capabilities: UInt32?
    public var clearance: Int?

    /// Where this agent's own work belongs.
    public var homeDomain: String?

    /// The subjects it is responsible for.
    public var ownedDomains: [String]

    /// **The set that actually decides whether a write lands.** A mask can be
    /// clear and a write still refused because the agent owns nothing; this is
    /// the answer to that, and it was not available from a roster row at all.
    public var writableDomains: [String]

    /// Everything policy and provenance let it see. Wider than what recall is
    /// scoped to, deliberately — see `ReadableDomains` for the owner's ruling
    /// that recall stays on what Mynah *owns*.
    public var readableDomains: [String]

    /// The node telling us its own list is cut short, which a count of the array
    /// cannot tell us. Rendering a truncated list as complete is the
    /// substitution this product keeps having to remove.
    public var readableDomainsTruncated: Bool

    public var totalMemories: Int?

    /// `total_exact: false` means the count is bounded by what the caller may
    /// see, not that it is approximate arithmetic. Shown as "at least" rather
    /// than as a total.
    public var totalExact: Bool

    public init(
        agentID: String? = nil,
        profile: String? = nil,
        role: String? = nil,
        registrationStatus: String? = nil,
        enrollmentStatus: String? = nil,
        approvalRequired: Bool = false,
        canRead: Bool = true,
        canWrite: Bool = true,
        capabilities: UInt32? = nil,
        clearance: Int? = nil,
        homeDomain: String? = nil,
        ownedDomains: [String] = [],
        writableDomains: [String] = [],
        readableDomains: [String] = [],
        readableDomainsTruncated: Bool = false,
        totalMemories: Int? = nil,
        totalExact: Bool = false
    ) {
        self.agentID = agentID
        self.profile = profile
        self.role = role
        self.registrationStatus = registrationStatus
        self.enrollmentStatus = enrollmentStatus
        self.approvalRequired = approvalRequired
        self.canRead = canRead
        self.canWrite = canWrite
        self.capabilities = capabilities
        self.clearance = clearance
        self.homeDomain = homeDomain
        self.ownedDomains = ownedDomains
        self.writableDomains = writableDomains
        self.readableDomains = readableDomains
        self.readableDomainsTruncated = readableDomainsTruncated
        self.totalMemories = totalMemories
        self.totalExact = totalExact
    }

    /// Reads a `sage_status` reply.
    ///
    /// Through `SageReply.object(in:)` rather than `JSONSerialization`, because
    /// the node prepends an auto-inception banner separated by `\n\n---\n\n` on
    /// the first tool call of a session. That prefix is still real on 11.17.10;
    /// the *trailing* `[SAGE] Reminder:` nudge is not, and has not been since
    /// 11.16.1 — see `SageReply`.
    ///
    /// Returns nil when nothing parses. A caller must not read that as
    /// "restricted": an appliance that cannot see its node has to say so, not
    /// tell the owner their permissions are wrong.
    ///
    /// ## Defaults, and which way each one fails
    ///
    /// `approval_required` defaults to **false** and `can_write` to **true**, so
    /// a node that omits them produces no warning. That is deliberate and it is
    /// the opposite of fail-closed. A warning that cannot clear is worse than no
    /// warning — it teaches the owner to ignore the one screen that has to tell
    /// them something true — and this warning is unclearable by construction,
    /// because the owner cannot make an older node emit a newer field. Being
    /// wrong the other way costs a warning nobody sees; a `WriteDenial` from a
    /// real refusal still speaks, with the server's own reason.
    public static func fromStatus(_ reply: String) -> ApplianceStanding? {
        guard let status = SageReply.object(in: reply) else { return nil }

        func strings(_ key: String) -> [String] {
            (status[key] as? [String])?.filter { !$0.isEmpty } ?? []
        }

        return ApplianceStanding(
            agentID: status["agent_id"] as? String,
            profile: status["profile"] as? String,
            role: status["role"] as? String,
            registrationStatus: status["registration_status"] as? String,
            enrollmentStatus: status["enrollment_status"] as? String,
            approvalRequired: status["approval_required"] as? Bool ?? false,
            canRead: status["can_read"] as? Bool ?? true,
            canWrite: status["can_write"] as? Bool ?? true,
            capabilities: (status["capabilities"] as? NSNumber)?.uint32Value,
            clearance: (status["clearance"] as? NSNumber)?.intValue,
            homeDomain: status["home_domain"] as? String,
            ownedDomains: strings("owned_domains"),
            writableDomains: strings("writable_domains"),
            readableDomains: strings("readable_domains"),
            readableDomainsTruncated: status["readable_domains_truncated"] as? Bool ?? false,
            totalMemories: (status["total_memories"] as? NSNumber)?.intValue,
            totalExact: status["total_exact"] as? Bool ?? false
        )
    }

    /// Whether the node has said, in as many words, that a person has to act.
    ///
    /// Two statements, either of which alone means the appliance cannot save:
    /// approval is outstanding, or writing is refused outright.
    ///
    /// **`writableDomains.isEmpty` is deliberately not one of them**, though it
    /// is the condition that most directly predicts a failed write. An older
    /// node that does not emit the field would look identical to one that emits
    /// an empty list, and the resulting warning would be unclearable — the exact
    /// failure `ApplianceWriteReadiness` documents at length about warning on
    /// "any write denial". The list is shown to the owner as information; it is
    /// not used to raise an alarm.
    public var needsReview: Bool { approvalRequired || !canWrite }
}
