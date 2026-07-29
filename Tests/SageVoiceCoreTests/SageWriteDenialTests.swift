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
}
