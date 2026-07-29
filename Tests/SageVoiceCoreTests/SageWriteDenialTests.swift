import XCTest
@testable import SageVoiceCore

/// Telling a refusal from a bad moment.
///
/// This matters more than its size suggests. The appliance stored **zero**
/// memories on the author's node for the whole life of an identity, and the
/// reason was that a permanent refusal and a dropped connection produced the
/// same log line and the same response — try again next turn, forever.
///
/// Every string below is quoted from SAGE rather than invented: the consensus
/// messages come from `processMemorySubmit` (`internal/abci/app.go`) and the
/// problem type from `api/rest/memory_handler.go` and `internal/mcp/server.go`.
/// If SAGE rewords one of these, this test is the thing that notices — the
/// production path has no typed channel to read instead, because
/// `ToolProviding.call` hands back prose.
final class SageWriteDenialTests: XCTestCase {

    // MARK: - The refusals that must latch

    func testProblemTypeIsRecognised() {
        let message = """
        tool failed: {"type":"https://sage.dev/errors/domain-write-denied",\
        "title":"Domain write denied","status":403}
        """
        XCTAssertNotNil(SageRitual.permanentDenial(in: message))
    }

    /// Mask bit 2, `AgentCapabilityDenySharedDomainWrite`. This is the one that
    /// silently swallowed `sage_inception`'s own identity memory, which it
    /// writes to `self` — the reason a fresh appliance shows zero memories
    /// while the identity it replaced shows exactly one.
    func testSharedDomainRefusalLatches() {
        let denial = SageRitual.permanentDenial(
            in: "access denied: agent 74140c2d6b710a18 cannot write shared domain self"
        )
        XCTAssertEqual(denial?.domain, "self")
    }

    /// Mask bit 4, `AgentCapabilityDenyDomainClaim`. Every invented per-subject
    /// domain lands here, which is why the appliance writes exactly one domain.
    func testUnownedDomainRefusalNamesTheDomainItWanted() {
        let denial = SageRitual.permanentDenial(
            in: "access denied: agent 74140c2d6b710a18 cannot claim unowned domain voice-appliance"
        )
        XCTAssertEqual(denial?.domain, "voice-appliance")
    }

    /// Mask bit 8, `AgentCapabilityDenyForeignDomainWrite` — refused *even when
    /// a level-2 grant exists*, which is why "ask the owner to grant level 2"
    /// is not on its own a fix.
    func testForeignDomainRefusalLatches() {
        let denial = SageRitual.permanentDenial(
            in: "access denied: agent 74140c2d6b710a18 cannot write domain research it does not own"
        )
        XCTAssertEqual(denial?.domain, "research")
    }

    func testMissingGrantRefusalLatches() {
        let denial = SageRitual.permanentDenial(
            in: "access denied: agent 74140c2d6b710a18 has no write access to domain voice-appliance"
        )
        XCTAssertEqual(denial?.domain, "voice-appliance")
    }

    /// The REST wording, which quotes the domain rather than leaving it bare.
    func testQuotedDomainIsUnwrapped() {
        let denial = SageRitual.permanentDenial(
            in: "agent does not have write access to domain 'voice-appliance'"
        )
        XCTAssertEqual(denial?.domain, "voice-appliance")
    }

    // MARK: - The failures that must NOT latch

    /// The safe direction to be wrong in. A denial this misses is retried and
    /// is merely noisy; a transport failure mistaken for a denial would stop
    /// the appliance storing anything for the rest of the session over a
    /// dropped socket.
    func testTransientFailuresDoNotLatch() {
        for message in [
            "connection refused",
            "The request timed out.",
            "Broadcast error: mempool is full: number of txs 5000 (max: 5000)",
            "malformed response: unexpected end of JSON input",
            "tool failed: vault_locked"
        ] {
            XCTAssertNil(
                SageRitual.permanentDenial(in: message),
                "\(message) is recoverable and must be retried, not latched"
            )
        }
    }

    // MARK: - The domain the appliance writes

    /// `sage-*` is a reserved ownerless shared prefix, so a domain named after
    /// this product would be unwritable by construction. SAGE's own RBAC
    /// reference calls out `sage-voice-bridge` by name as an example of the
    /// mistake.
    func testMemoryDomainIsNotUnderTheReservedSharedPrefix() {
        XCTAssertFalse(SageRitual.memoryDomain.hasPrefix("sage-"))
    }

    /// The shared domains are closed to any agent carrying a non-zero mask, and
    /// `general` is what `sage_remember` uses when no domain is passed — so
    /// picking one of these would be picking a domain that cannot be written.
    func testMemoryDomainIsNotAReservedSharedName() {
        for reserved in ["general", "self", "meta"] {
            XCTAssertNotEqual(SageRitual.memoryDomain, reserved)
        }
    }

    /// The model is told where to store things, and it is told the same name the
    /// appliance itself uses. These drifting apart would split the owner's
    /// memories across two domains, one of which is unwritable.
    func testTheModelIsToldTheSameDomainTheApplianceWrites() {
        XCTAssertTrue(
            BrainPrompts.voiceAgentManager.contains(SageRitual.memoryDomain),
            "the system prompt must name the one domain this agent can write"
        )
    }

    /// The bio is what a person reads in CEREBRUM when deciding what to grant.
    /// It replaced "Auto-registered  agent for project ''" — two empty
    /// substitutions and a double space — which told the operator nothing.
    func testBootBioNamesTheDomainTheOwnerHasToGrant() {
        XCTAssertTrue(SageRitual.bootBio.contains(SageRitual.memoryDomain))
        XCTAssertFalse(SageRitual.bootBio.contains("Auto-registered"))
    }

    // MARK: - The typed channel (SAGE v11.14.2+)

    /// SAGE shipped stable reason codes after we reported that one remedy
    /// string could not be right for every cause. Reading the code beats
    /// inferring the cause — and inferring it from the mask is now explicitly
    /// wrong: "a non-zero capability mask does not by itself invalidate a
    /// grant: only the matching effective restriction produces its reason
    /// code."
    func testATypedDenialIsReadFromTheReasonCode() {
        let message = """
        tool failed: {"store_error":{"type":"https://sage.dev/errors/domain-write-denied",        "reason_code":"domain_claim_restricted","retryable":false,        "remedy":"Submit to a domain this agent already owns, or ask a local administrator         to assign or reassign a non-shared domain; this profile cannot claim an unowned domain."}}
        """
        let denial = SageRitual.permanentDenial(in: message)
        XCTAssertEqual(denial?.reasonCode, "domain_claim_restricted")
        XCTAssertTrue(denial?.remedy?.contains("cannot claim an unowned domain") == true)
    }

    /// Each of the seven, so a reworded server sentence cannot quietly drop one
    /// back onto the legacy prose path.
    func testEveryStableReasonCodeIsRecognised() {
        for code in SageRitual.knownReasonCodes {
            let denial = SageRitual.permanentDenial(in: "{\"reason_code\":\"\(code)\"}")
            XCTAssertEqual(denial?.reasonCode, code, "\(code) fell through to the legacy matcher")
        }
    }

    /// A code we do not know must reach the compatibility path rather than be
    /// reported as a cause we cannot explain.
    func testAnUnknownReasonCodeFallsBackRatherThanGuessing() {
        XCTAssertNil(SageRitual.permanentDenial(in: "{\"reason_code\":\"something_new\"}"))
        // ...but still latches if the prose says it is a denial.
        let both = SageRitual.permanentDenial(
            in: "{\"reason_code\":\"something_new\"} access denied: agent x cannot write shared domain self"
        )
        XCTAssertNotNil(both)
        XCTAssertNil(both?.reasonCode, "an unrecognised code must not be reported as if understood")
    }

    /// A v11.14.2 node deliberately withholds the domain — the typed denial
    /// "does not disclose the agent ID, requested domain, owner ID, raw
    /// capability mask, or raw consensus log" — so the only party that knows
    /// which subject was refused is us.
    func testATypedDenialFallsBackToTheDomainWeAskedFor() {
        let denial = SageRitual.permanentDenial(in: "{\"reason_code\":\"no_owned_home_domain\"}")
        XCTAssertEqual(denial?.domain, SageRitual.memoryDomain)
    }

    func testAMessageWithNoJSONStillParsesNothing() {
        XCTAssertNil(SageRitual.jsonString(forKey: "reason_code", in: "connection refused"))
        XCTAssertNil(SageRitual.jsonString(forKey: "remedy", in: "{\"remedy\":}"))
    }
}
