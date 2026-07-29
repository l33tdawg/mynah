import XCTest
@testable import SageVoiceCore

/// Knowing it cannot save, before it tries.
///
/// The fault this replaces was silent for the whole life of an identity: zero
/// memories stored, and every screen saying "nothing stored yet" — the same
/// sentence a working brand-new install shows. These tests exist to keep the
/// two apart.
final class ApplianceWriteReadinessTests: XCTestCase {

    private func readiness(mask: UInt32) -> ApplianceWriteReadiness {
        ApplianceWriteReadiness(agentID: String(repeating: "a", count: 64), standing: .registered(mask: mask))
    }

    // MARK: - The mask that actually shipped

    /// 30 is `DefaultSelfRegisteredAgentCapabilities` — what consensus assigns
    /// to any key self-registering after app-v22, and what the appliance on the
    /// author's node carries.
    func testTheRealMaskIsReportedAsUnableToRemember() {
        let state = readiness(mask: 30)
        XCTAssertTrue(state.needsTheOwner)
        XCTAssertFalse(state.canSave)
        // "remember", not "save" — see the note on `headline`. The distinction
        // save was protecting cannot arise in this state, and remember is the
        // word the rest of the product uses to the owner.
        XCTAssertEqual(state.headline, "Mynah can't remember anything yet.")
    }

    /// Reading is never what the mask takes away, and saying otherwise would
    /// send the owner looking for the wrong problem.
    func testReadingIsNeverReportedAsBroken() {
        XCTAssertTrue(readiness(mask: 30).canRead)
        XCTAssertTrue(readiness(mask: 15).canRead)
    }

    /// The confirmed remedy: the Companion profile plus an owned domain.
    ///
    /// This is the test that caught the design being wrong. Mask 15 still
    /// carries all three write denials — under it the one surviving route is a
    /// domain the agent owns, which is precisely what the remedy sets up. An
    /// implementation that warned on "any write denial" therefore kept warning
    /// after the owner had done everything right, and could never stop, because
    /// domain ownership is not visible without a signature. A warning that
    /// never clears teaches people to ignore the one channel we have.
    func testCompanionProfileStopsTheWarningEvenThoughItStillDeniesWrites() {
        let state = readiness(mask: 15)
        XCTAssertNotEqual(
            state.standing, .registered(mask: 0),
            "mask 15 is restricted — this test is meaningless if that stops being true"
        )
        XCTAssertTrue(state.hasCompanionProfile)
        XCTAssertFalse(state.needsTheOwner, "an assigned profile is not an unreviewed one")
        XCTAssertNil(state.headline)
    }

    /// The signal is "has anybody looked at this agent", not "is it
    /// restricted". Only the untouched self-registration default means nobody
    /// has.
    func testOnlyTheUnreviewedDefaultRaisesTheWarning() {
        XCTAssertTrue(readiness(mask: 30).needsTheOwner)
        for assigned: UInt32 in [15, 14, 12, 8, 4, 2, 31] where assigned != 30 {
            XCTAssertFalse(
                readiness(mask: assigned).needsTheOwner,
                "mask \(assigned) was assigned by an administrator; a refusal speaks for itself"
            )
        }
    }

    /// Nineteen of the twenty agents on the owner's node.
    func testAnUnrestrictedAgentSaysNothingAtAll() {
        let state = readiness(mask: 0)
        XCTAssertFalse(state.needsTheOwner)
        XCTAssertNil(state.headline)
        XCTAssertNil(state.remedy)
        XCTAssertNil(state.logLine)
        XCTAssertTrue(state.reasons.isEmpty)
    }

    /// Bit 16 blocks federated delivery and nothing about saving locally, so on
    /// its own it must not raise a "can't save" alarm.
    func testFederationOnlyRestrictionIsNotAWriteProblem() {
        XCTAssertFalse(readiness(mask: 16).needsTheOwner)
    }

    // MARK: - What it says

    func testEachWriteDenialIsExplainedWithoutANumber() {
        let reasons = readiness(mask: 30).reasons
        XCTAssertEqual(reasons.count, 3)
        for reason in reasons {
            for leak in ["mask", "bit", "capabilit", "app-v22", "RBAC", "30"] {
                XCTAssertFalse(
                    reason.lowercased().contains(leak.lowercased()),
                    "\(reason) leaks an implementation detail the owner cannot act on"
                )
            }
        }
    }

    /// The single most important sentence in this feature. A level-2 grant is
    /// the obvious-looking remedy, is what SAGE's own MCP documentation
    /// suggests, and does not work — deny-foreign-write is checked before the
    /// grant is consulted. The SAGE team confirmed it: "a level-2 grant is not
    /// a substitute."
    func testTheRemedyNeverAdvisesALevelTwoGrant() {
        let remedy = readiness(mask: 30).remedy ?? ""
        XCTAssertFalse(remedy.lowercased().contains("level 2"))
        XCTAssertFalse(remedy.lowercased().contains("level-2"))
        XCTAssertTrue(remedy.contains("companion profile"))
        XCTAssertTrue(remedy.contains("CEREBRUM"))
        // "grant" may appear, but only to rule it out. An owner who reaches for
        // the access matrix has taken the one obvious action that cannot work.
        XCTAssertTrue(remedy.contains("An access grant won't do it"))
    }

    /// It must say the consequence the owner actually cares about, which is not
    /// "permissions are wrong" but "it will forget everything you say".
    func testTheRemedySaysWhatHappensUntilItIsFixed() {
        XCTAssertTrue(readiness(mask: 30).remedy?.contains("won't remember anything") == true)
    }

    /// The remedy tells somebody to assign a specific subject; if that name is
    /// spelled by hand it can drift from the one the appliance actually writes,
    /// and the failure is silent again.
    func testTheRemedyNamesTheSubjectTheApplianceActuallyWrites() {
        XCTAssertTrue(readiness(mask: 30).remedy?.contains(SageRitual.memoryDomain) == true)
    }

    /// Owner-facing strings say "subject". SAGE's word is "domain" and the code
    /// keeps it, but no owner-facing string in this app says it.
    func testOwnerFacingStringsNeverSayDomain() {
        let state = readiness(mask: 30)
        let owner = ([state.headline, state.remedy, state.shortRemedy].compactMap { $0 } + state.reasons)
        for sentence in owner {
            XCTAssertFalse(
                sentence.lowercased().contains("domain"),
                "\(sentence) says domain; every owner-facing string in this app says subject"
            )
        }
    }

    // MARK: - Not knowing is not the same as being blocked

    /// An appliance that cannot reach its node must not tell the owner their
    /// permissions are wrong. This is the failure mode that would turn a
    /// restarted node into a false accusation.
    func testAnUnreachableNodeAccusesNobody() {
        let state = ApplianceWriteReadiness(agentID: "abc", standing: .unknown("connection refused"))
        XCTAssertFalse(state.needsTheOwner)
        XCTAssertNil(state.headline)
        XCTAssertNil(state.logLine)
    }

    /// Normal for the moments before a first registration lands.
    func testAnUnregisteredAgentIsNotAnAlarm() {
        let state = ApplianceWriteReadiness(agentID: "abc", standing: .notRegistered)
        XCTAssertFalse(state.needsTheOwner)
        XCTAssertNil(state.headline)
    }

    // MARK: - Reading the roster

    func testTheMaskIsReadFromTheAgentsRoster() {
        let id = "74140c2d6b710a1812f609031a541995d7da551096c4d0fc4d74b9d9013912db"
        let json = Data("""
        {"agents":[{"agent_id":"\(id)","name":"Mynah - Sage Voice Bridge","capabilities":30}]}
        """.utf8)
        XCTAssertEqual(ApplianceWriteReadinessCheck.standing(inRoster: json, for: id), .registered(mask: 30))
    }

    /// An absent `capabilities` field means unrestricted — the documented
    /// meaning, not a convenient reading. Nineteen rows on the owner's node
    /// omit it entirely.
    func testAnAbsentCapabilitiesFieldMeansUnrestricted() {
        let id = String(repeating: "b", count: 64)
        let json = Data("{\"agents\":[{\"agent_id\":\"\(id)\",\"name\":\"x\"}]}".utf8)
        XCTAssertEqual(ApplianceWriteReadinessCheck.standing(inRoster: json, for: id), .registered(mask: 0))
    }

    func testAnAgentMissingFromTheRosterIsNotRegistered() {
        let json = Data("{\"agents\":[{\"agent_id\":\"ffff\",\"name\":\"someone else\"}]}".utf8)
        XCTAssertEqual(
            ApplianceWriteReadinessCheck.standing(inRoster: json, for: String(repeating: "c", count: 64)),
            .notRegistered
        )
    }

    func testUnreadableAnswerIsUnknownRatherThanUnrestricted() {
        guard case .unknown = ApplianceWriteReadinessCheck.standing(inRoster: Data("not json".utf8), for: "a") else {
            return XCTFail("a node answer we cannot parse must never read as 'no restrictions'")
        }
    }

    // MARK: - Identity

    /// The derivation the Agents screen had concluded was impossible. Both
    /// vectors are real files on the author's machine, checked against the live
    /// roster: the 32-byte appliance seed is the registered appliance, and the
    /// 64-byte operator key is the node's sole global admin.
    func testAgentIDIsDerivedFromTheKeySeed() {
        // A known-answer test would need the owner's private keys, which do not
        // belong in a repository. What is asserted here is the shape contract
        // both real files satisfy.
        let seed = Data(repeating: 7, count: 32)
        guard let derived = SageAgentIdentity.agentID(ofKeyBytes: seed) else {
            return XCTFail("a 32-byte seed is the appliance's own key format")
        }
        XCTAssertEqual(derived.count, 64, "an agent id is a hex-encoded 32-byte public key")
        XCTAssertEqual(derived, derived.lowercased())

        // The 64-byte form is seed + public key; deriving from the first 32
        // bytes must give the same answer as the 32-byte form.
        let full = seed + Data(repeating: 9, count: 32)
        XCTAssertEqual(SageAgentIdentity.agentID(ofKeyBytes: full), derived)
    }

    /// A truncated or half-written key must yield nothing rather than a
    /// plausible id — an id that does not match the signing key would attribute
    /// another agent's standing to this one.
    func testAMalformedKeyYieldsNoIdentity() {
        XCTAssertNil(SageAgentIdentity.agentID(ofKeyBytes: Data(repeating: 1, count: 16)))
        XCTAssertNil(SageAgentIdentity.agentID(ofKeyBytes: Data()))
        XCTAssertNil(SageAgentIdentity.agentID(ofKeyBytes: Data(repeating: 1, count: 100)))
    }

    // MARK: - Against a real node

    /// The whole path, against whatever SAGE is running on this machine.
    ///
    /// Read-only: one unauthenticated GET, nothing signed and nothing written.
    /// Skipped unless `SAGE_LIVE_NODE=1`, following the same convention as the
    /// call test that dials a real relay — a test that needs a running node has
    /// no business failing a build on a machine without one.
    ///
    /// It asserts the shape rather than a particular mask, because the mask is
    /// exactly what the owner is going to change. What it proves is the part
    /// that unit tests cannot: that the appliance's key derives to an id that
    /// is really on the roster, which is the step the Agents screen had
    /// concluded was impossible.
    func testAgainstTheLiveNode() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SAGE_LIVE_NODE"] == "1",
            "set SAGE_LIVE_NODE=1 to run against the SAGE on this machine"
        )
        let state = await ApplianceWriteReadinessCheck().check()
        let id = try XCTUnwrap(state.agentID, "no appliance key on this Mac")
        XCTAssertEqual(id.count, 64)

        switch state.standing {
        case .registered(let mask):
            print("LIVE: appliance \(id.prefix(16)) is registered with capability mask \(mask)")
            print("LIVE: needsTheOwner=\(state.needsTheOwner) companion=\(state.hasCompanionProfile)")
            if let line = state.logLine { print("LIVE: \(line)") }
        case .notRegistered:
            XCTFail("the appliance key derived to \(id.prefix(16)), which is not on the roster")
        case .unknown(let why):
            throw XCTSkip("no reachable SAGE node: \(why)")
        }
    }
}
