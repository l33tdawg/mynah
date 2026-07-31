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
        XCTAssertEqual(state.headline, "Approve Mynah in CEREBRUM so it can start remembering.")
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

    /// One verb across every owner-facing sentence.
    ///
    /// Added because changing `headline` from "save" to "remember" left
    /// `shortRemedy` behind, and `shortRemedy` is the one the Ready screen
    /// renders — so for a while the screen said "can't remember" in its title
    /// and "can't save" in its banner. A one-word change that leaves references
    /// behind is how a codebase ends up with two vocabularies, which is what
    /// collapsing "subject" versus "domain" was about.
    func testEveryOwnerFacingSentenceUsesTheSameVerb() {
        let state = readiness(mask: 30)
        for sentence in [state.headline, state.remedy, state.shortRemedy].compactMap({ $0 }) {
            XCTAssertFalse(
                sentence.lowercased().contains("save"),
                "\(sentence) still says save; the product's word to owners is remember"
            )
        }
        XCTAssertTrue(state.headline?.contains("remember") == true)
        XCTAssertTrue(state.shortRemedy?.contains("remember") == true)
        XCTAssertTrue(state.remedy?.contains("remember") == true)
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

    // MARK: - Combining the two signals

    /// An observation outranks a prediction of the same thing. It must: the
    /// mask cannot see the `DomainAccess` allowlist at all, so a clear mask
    /// with a real refusal is a state only the denial knows about.
    func testARealRefusalOutranksTheMask() {
        let denial = SageRitual.WriteDenial(
            domain: "voice-interface",
            detail: "access denied: agent cannot write shared domain self",
            reasonCode: "shared_write_restricted",
            remedy: "Submit to the agent's owned non-shared home domain."
        )
        let status = readiness(mask: 0).status(observing: denial)
        XCTAssertEqual(status?.isObserved, true, "a clear mask silenced a refusal we watched happen")
        XCTAssertEqual(status?.remedy, "Submit to the agent's owned non-shared home domain.")
        XCTAssertEqual(status?.detail, denial.detail)
    }

    /// With no denial, the predictive half still speaks.
    func testThePredictionSpeaksWhenNothingHasBeenRefusedYet() {
        let status = readiness(mask: 30).status(observing: nil)
        XCTAssertEqual(status?.isObserved, false)
        XCTAssertNil(status?.detail, "there is no server sentence to quote yet")
        XCTAssertTrue(status?.remedy.contains("companion profile") == true)
    }

    /// The rule the whole feature turns on: when Mynah is working, this state
    /// does not exist. No badge, no green tick, no "all good" row.
    func testAWorkingApplianceProducesNothingToRender() {
        XCTAssertNil(readiness(mask: 0).status(observing: nil))
        XCTAssertNil(readiness(mask: 15).status(observing: nil))
    }

    /// An older server sends no per-cause remedy, and that is not rare — it is
    /// every server before v11.14.2. Ours has to stand in.
    func testAnOlderServersDenialFallsBackToOurRemedy() {
        let denial = SageRitual.WriteDenial(domain: "voice-interface", detail: "access denied")
        let status = readiness(mask: 30).status(observing: denial)
        XCTAssertEqual(status?.isObserved, true)
        XCTAssertTrue(status?.remedy.contains("companion profile") == true)
    }

    /// One voice across both paths, so a screen cannot say one thing when it
    /// predicted and another when it observed.
    func testBothPathsUseTheSameHeadline() {
        let observed = readiness(mask: 30).status(
            observing: SageRitual.WriteDenial(domain: "d", detail: "x")
        )
        let predicted = readiness(mask: 30).status(observing: nil)
        XCTAssertEqual(observed?.headline, predicted?.headline)
        XCTAssertEqual(observed?.headline, "Approve Mynah in CEREBRUM so it can start remembering.")
    }

    // MARK: - An instruction, not a fault report

    /// The owner is not the person who broke this, and nothing here is broken:
    /// a key is waiting for a review that has not happened. A sentence that
    /// reports a defect hands the owner a problem and no next step, and the two
    /// steps it invites — reinstall, or file a SAGE bug — both provably fail.
    ///
    /// So every owner-facing sentence in this state has to name the action.
    /// `testNeitherRemedySuggestsReinstalling` polices the wrong remedies; this
    /// polices the absence of a right one.
    func testTheOwnerIsToldWhatToDoRatherThanWhatIsWrong() throws {
        let state = readiness(mask: ApplianceWriteReadiness.Capability.pendingReview)
        let headline = try XCTUnwrap(state.headline)
        let short = try XCTUnwrap(state.shortRemedy)

        // The action, not the symptom, and in the first sentence of each.
        for sentence in [headline, short] {
            XCTAssertTrue(
                sentence.hasPrefix("Approve Mynah in CEREBRUM"),
                "\"\(sentence)\" opens with something other than the next action"
            )
        }

        // The phrasings that put it back on the owner as a defect they own.
        for sentence in [headline, short, try XCTUnwrap(state.remedy)] {
            let said = sentence.lowercased()
            for complaint in ["can't remember anything yet", "failed", "error", "broken",
                              "something went wrong", "unable to"] {
                XCTAssertFalse(said.contains(complaint), "\"\(sentence)\" reports a fault")
            }
        }
    }

    /// CEREBRUM lists agents by id. "Approve Mynah" in front of a table of hex
    /// is not an instruction, and comparing this id against the row they
    /// approved is the check that would have caught the wrong-key bug.
    func testTheRemedyNamesTheAgentToApprove() throws {
        let state = ApplianceWriteReadiness(
            agentID: "1ab7aa10deadbeefcafef00d",
            standing: .registered(mask: ApplianceWriteReadiness.Capability.pendingReview)
        )
        XCTAssertTrue(try XCTUnwrap(state.remedy).contains("1ab7aa10deadbeef"))
    }

    /// And an unknown id must not produce "the agent whose id starts ." — a
    /// sentence that reads like a truncation bug at the exact moment the owner
    /// is deciding whether to trust what they are being told.
    func testAMissingAgentIDLeavesACompleteSentence() throws {
        let state = ApplianceWriteReadiness(
            agentID: nil,
            standing: .registered(mask: ApplianceWriteReadiness.Capability.pendingReview)
        )
        let remedy = try XCTUnwrap(state.remedy)
        XCTAssertFalse(remedy.contains("id starts"))
        XCTAssertTrue(remedy.hasPrefix("Someone with administrator access"))
    }

    // MARK: - What applying the remedy also does

    /// The companion profile is mask 15 and bit 1 is `ReadAllDomains`, so
    /// following our advice lifts the discovery filters as well as enabling
    /// writes. The Memories page goes from empty to a slice of what nineteen
    /// other agents have stored.
    ///
    /// That is a privacy consequence of an action this product actively tells
    /// somebody to take. Leaving it unsaid is the same failure as every other
    /// one this week: a true sentence that stopped being the whole truth
    /// because something else changed.
    func testTheRemedyNamesTheReadingItAlsoTurnsOn() {
        let remedy = readiness(mask: 30).remedy ?? ""
        XCTAssertTrue(
            remedy.contains("read across subjects it wasn't given"),
            "applying our advice opens reading and we do not say so"
        )
        XCTAssertTrue(
            remedy.contains("Memories page"),
            "does not say where the owner will actually notice the change"
        )
    }

    /// Named because it is real and because it is what makes this calm rather
    /// than alarming: reading lifts only to the agent's own clearance, so
    /// anything classified above stays invisible.
    func testTheDisclosureCarriesTheClearanceBound() {
        XCTAssertTrue(readiness(mask: 30).remedy?.contains("up to its own clearance") == true)
    }

    /// Stated evenly. The remedy is correct and the owner should apply it —
    /// wording that made the fix sound risky would discourage the right action
    /// in order to look careful, which is its own dishonesty.
    func testTheDisclosureIsNotWordedAsAWarning() {
        let remedy = (readiness(mask: 30).remedy ?? "").lowercased()
        for alarm in ["careful", "warning", "caution", "beware", "risk", "danger", "be aware"] {
            XCTAssertFalse(
                remedy.contains(alarm),
                "\"\(alarm)\" makes a correct remedy sound like a hazard"
            )
        }
    }

    /// It belongs to "here is what changes when you do this", not to "here is
    /// how things are" — so it stays off the one-line version, which fires at
    /// boot when the owner is waiting rather than reading, and off `reasons`,
    /// which describe today.
    func testTheDisclosureStaysOnTheRemedyAndNowhereElse() {
        let state = readiness(mask: 30)
        XCTAssertFalse(state.shortRemedy?.contains("read across") == true)
        for reason in state.reasons {
            XCTAssertFalse(reason.contains("read across"), "a consequence leaked into a present-tense fact")
        }
    }

    /// And it says nothing at all when there is nothing to apply.
    func testAWorkingApplianceIsToldNoneOfThis() {
        XCTAssertNil(readiness(mask: 15).remedy)
        XCTAssertNil(readiness(mask: 0).remedy)
    }
}
