import XCTest
@testable import SageVoiceCore

/// Knowing it cannot save, before it tries.
///
/// The fault this replaces was silent for the whole life of an identity: zero
/// memories stored, and every screen saying "nothing stored yet" — the same
/// sentence a working brand-new install shows. These tests exist to keep the
/// two apart.
final class ApplianceWriteReadinessTests: XCTestCase {

    /// An agent an administrator has looked at: no approval outstanding, writes
    /// allowed. The mask still describes *which* restrictions apply.
    private func reviewed(mask: UInt32, profile: String? = nil) -> ApplianceWriteReadiness {
        readiness(ApplianceStanding(
            profile: profile, approvalRequired: false, canWrite: true, capabilities: mask
        ))
    }

    /// An agent the node says is still waiting for a person.
    private func awaitingReview(mask: UInt32) -> ApplianceWriteReadiness {
        readiness(ApplianceStanding(
            registrationStatus: "pending_review",
            approvalRequired: true,
            canWrite: false,
            capabilities: mask
        ))
    }

    private func readiness(_ reported: ApplianceStanding) -> ApplianceWriteReadiness {
        ApplianceWriteReadiness(
            agentID: String(repeating: "a", count: 64),
            standing: .registered(reported)
        )
    }

    // MARK: - The state that actually shipped

    /// 30 is `DefaultSelfRegisteredAgentCapabilities` — what consensus assigns
    /// to any key self-registering after app-v22.
    func testTheUnreviewedStateIsReportedAsUnableToRemember() {
        let state = awaitingReview(mask: 30)
        XCTAssertTrue(state.needsTheOwner)
        XCTAssertFalse(state.canSave)
        // "remember", not "save" — see the note on `headline`. The distinction
        // save was protecting cannot arise in this state, and remember is the
        // word the rest of the product uses to the owner.
        XCTAssertEqual(state.headline, "Approve Mynah in CEREBRUM so it can start remembering.")
    }

    /// Reading is never what this takes away, and saying otherwise would send
    /// the owner looking for the wrong problem.
    func testReadingIsNeverReportedAsBroken() {
        XCTAssertTrue(awaitingReview(mask: 30).canRead)
        XCTAssertTrue(reviewed(mask: 15).canRead)
    }

    /// The confirmed remedy: the Companion profile plus an owned domain.
    ///
    /// This is the test that caught the design being wrong the first time. Mask
    /// 15 still carries all three write denials — under it the one surviving
    /// route is a domain the agent owns, which is precisely what the remedy sets
    /// up. An implementation that warned on "any write denial" therefore kept
    /// warning after the owner had done everything right, and could never stop.
    /// A warning that never clears teaches people to ignore the one channel we
    /// have.
    func testCompanionProfileStopsTheWarningEvenThoughItStillDeniesWrites() {
        let state = reviewed(mask: 15, profile: "companion")
        XCTAssertNotEqual(state.mask, 0, "mask 15 is restricted — this test is meaningless otherwise")
        XCTAssertTrue(state.hasCompanionProfile)
        XCTAssertFalse(state.needsTheOwner, "an assigned profile is not an unreviewed one")
        XCTAssertNil(state.headline)
    }

    /// **The live mask is 31, and the old predicate tested for 15.**
    ///
    /// Measured from a `sage_status` signed as the appliance on the owner's
    /// node: `profile: "companion"` with `capabilities: 31` — the Companion
    /// profile plus the federated-delivery denial. So the appliance held the
    /// profile and `hasCompanionProfile` was false, which is the third dead
    /// guard #51 found in this file. Reading the node's name for the profile
    /// cannot drift with the bits.
    func testTheCompanionProfileIsRecognisedAtTheMaskTheNodeReallyReports() {
        let live = reviewed(mask: 31, profile: "companion")
        XCTAssertTrue(
            live.hasCompanionProfile,
            "mask 31 with profile 'companion' is what the owner's node reports; testing mask == 15 missed it"
        )
        XCTAssertFalse(live.needsTheOwner)
    }

    /// **The signal is the node's own statement, not a mask this code decodes.**
    ///
    /// The old rule was `mask == 30`, and it could not fire in any state: the
    /// mask came from an unsigned `/v1/agents` that answers 401, and the live
    /// mask is 31 anyway. Now a restricted-looking mask says nothing on its own,
    /// and `approval_required` says everything.
    func testOnlyTheNodeSayingSoRaisesTheWarning() {
        for restricted: UInt32 in [30, 31, 15, 14, 12, 8, 4, 2, 0] {
            XCTAssertFalse(
                reviewed(mask: restricted).needsTheOwner,
                "mask \(restricted) was assigned by an administrator; a refusal speaks for itself"
            )
            XCTAssertTrue(
                awaitingReview(mask: restricted).needsTheOwner,
                "the node said approval is required and mask \(restricted) argued it out of it"
            )
        }
    }

    /// Writing refused outright is the other half, and it is stated too.
    func testARefusedWriteRaisesTheWarningWithoutAnApprovalFlag() {
        let refused = readiness(ApplianceStanding(approvalRequired: false, canWrite: false, capabilities: 30))
        XCTAssertTrue(refused.needsTheOwner)
    }

    /// Nineteen of the twenty agents on the owner's node.
    func testAnUnrestrictedAgentSaysNothingAtAll() {
        let state = reviewed(mask: 0)
        XCTAssertFalse(state.needsTheOwner)
        XCTAssertNil(state.headline)
        XCTAssertNil(state.remedy)
        XCTAssertNil(state.logLine)
        XCTAssertTrue(state.reasons.isEmpty)
    }

    /// Bit 16 blocks federated delivery and nothing about saving locally, so on
    /// its own it must not raise a "can't save" alarm.
    func testFederationOnlyRestrictionIsNotAWriteProblem() {
        XCTAssertFalse(reviewed(mask: 16).needsTheOwner)
    }

    // MARK: - What it says

    func testEachWriteDenialIsExplainedWithoutANumber() {
        let reasons = awaitingReview(mask: 30).reasons
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
        let remedy = awaitingReview(mask: 30).remedy ?? ""
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
        XCTAssertTrue(awaitingReview(mask: 30).remedy?.contains("won't remember anything") == true)
    }

    /// The remedy tells somebody to assign a specific subject; if that name is
    /// spelled by hand it can drift from the one the appliance actually writes,
    /// and the failure is silent again.
    func testTheRemedyNamesTheSubjectTheApplianceActuallyWrites() {
        XCTAssertTrue(awaitingReview(mask: 30).remedy?.contains(SageRitual.memoryDomain) == true)
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
        let state = awaitingReview(mask: 30)
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
        let state = awaitingReview(mask: 30)
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

    // MARK: - Reading a signed sage_status

    /// **Read from a captured reply, not one written from memory.**
    ///
    /// `sage_status` signed as the appliance on the owner's node, 11.17.9 /
    /// app-v26, with only the agent id redacted. The 1.7.4 sweep found ~30 tests
    /// across 8 files asserting over SAGE shapes the node had stopped producing,
    /// every one a literal somebody wrote by hand and every one green; of the
    /// files in `Tests/Fixtures`, the ones that have never rotted are the ones
    /// captured from the thing they stand for.
    private func capturedStatus() throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Fixtures/sage_status-11.17.9-appv26-appliance.json"),
            encoding: .utf8
        )
    }

    private var capturedAgentID: String { String(repeating: "a", count: 64) }

    func testStandingIsReadFromTheNodesOwnStatement() throws {
        let standing = ApplianceWriteReadinessCheck.standing(
            inStatus: try capturedStatus(), expecting: capturedAgentID
        )
        guard case .registered(let reported) = standing else {
            return XCTFail("the captured live reply did not read as a registration: \(standing)")
        }
        XCTAssertEqual(reported.capabilities, 31, "the live mask, which the old mask == 30 guard could never match")
        XCTAssertEqual(reported.profile, "companion")
        XCTAssertFalse(reported.approvalRequired)
        XCTAssertTrue(reported.canWrite)
        XCTAssertEqual(reported.homeDomain, "mynah-home")
        XCTAssertEqual(reported.writableDomains, ["mynah-home", "sage-v3.6.0-audit", "user-interaction"])
        XCTAssertTrue(reported.readableDomainsTruncated, "the node said its own list is cut short")
    }

    /// And the whole appliance reads as working, which it is.
    func testTheOwnersLiveApplianceIsNotWarnedAbout() throws {
        let state = ApplianceWriteReadiness(
            agentID: capturedAgentID,
            standing: ApplianceWriteReadinessCheck.standing(
                inStatus: try capturedStatus(), expecting: capturedAgentID
            )
        )
        XCTAssertTrue(state.hasCompanionProfile)
        XCTAssertFalse(state.needsTheOwner)
        XCTAssertNil(state.headline)
        XCTAssertTrue(state.canSave)
    }

    /// **The check a roster could never do.**
    ///
    /// A signed reply is by construction about whoever signed it, so "does the
    /// node's answer name the key I hold" has a real answer. This is the
    /// question that would have caught the bug in `SageAgentIdentity`, where a
    /// comment asserted the appliance signed as an id belonging to a developer's
    /// MCP session on the same Mac — both are registered, both are active, and
    /// both are named after this project, so every question a roster can be
    /// asked says yes to both.
    func testAReplyForADifferentAgentIsNotAcceptedAsOurOwn() throws {
        let standing = ApplianceWriteReadinessCheck.standing(
            inStatus: try capturedStatus(),
            expecting: String(repeating: "b", count: 64)
        )
        guard case .unknown(let why) = standing else {
            return XCTFail("a status signed by another key was read as this appliance's standing")
        }
        XCTAssertTrue(why.contains("aaaaaaaa"), why)
    }

    /// An older node that does not echo the id is not a mismatch.
    func testAStatusWithNoAgentIDIsStillOurs() {
        let standing = ApplianceWriteReadinessCheck.standing(
            inStatus: #"{"approval_required": false, "can_write": true, "capabilities": 15}"#,
            expecting: capturedAgentID
        )
        XCTAssertEqual(standing, .registered(ApplianceStanding(
            approvalRequired: false, canWrite: true, capabilities: 15
        )))
    }

    /// The leading auto-inception banner is still real on 11.17.10 — the node
    /// prepends it on the first tool call of a session, separated by `---`. The
    /// *trailing* `[SAGE] Reminder:` nudge has not existed since 11.16.1.
    func testTheInceptionBannerDoesNotStopItParsing() throws {
        let banner = "Welcome back. Your institutional memory is online.\n\n---\n\n"
        let standing = ApplianceWriteReadinessCheck.standing(
            inStatus: banner + (try capturedStatus()), expecting: capturedAgentID
        )
        guard case .registered = standing else {
            return XCTFail("the banner the node really sends made the status unreadable: \(standing)")
        }
    }

    func testUnreadableAnswerIsUnknownRatherThanUnrestricted() {
        guard case .unknown = ApplianceWriteReadinessCheck.standing(inStatus: "not json", expecting: "a") else {
            return XCTFail("a node answer we cannot parse must never read as 'no restrictions'")
        }
    }

    /// **The route the old check read is not public, and this proves it from the
    /// source rather than from a comment.**
    ///
    /// The comment it replaces said `GET /v1/agents` "needs no signature". It
    /// answers `401` on every 11.17.x node, so the readiness check landed in
    /// `.unknown` every single time and the Ready-screen warning could not fire
    /// in any state. Nothing noticed, because a check that silently answers "I
    /// don't know" looks exactly like one that answers "all fine".
    func testTheReadinessCheckNoLongerReadsTheUnsignedRoster() throws {
        let scan = SwiftSourceScan(try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/SageVoiceCore/Setup/ApplianceWriteReadiness.swift"),
            encoding: .utf8
        ))
        let hits = scan.indices(of: "\"v1/agents\"")
        XCTAssertEqual(
            hits, [],
            "ApplianceWriteReadiness still builds a /v1/agents URL at line "
                + hits.map { String(scan.line(of: $0)) }.joined(separator: ", ")
                + " — that route answers 401 unsigned, so the warning it feeds cannot fire"
        )
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
    /// Read-only: one signed `sage_status`, which reports on the caller and
    /// writes nothing. Skipped unless `SAGE_LIVE_NODE=1`, following the same
    /// convention as the call test that dials a real relay — a test that needs a
    /// running node has no business failing a build on a machine without one.
    ///
    /// **It signs as the appliance, and that is the point rather than a
    /// detail.** The previous version made one unauthenticated GET, which is
    /// exactly how this defect survived: a developer's own MCP session on this
    /// Mac has more standing than Mynah, so a surface verified through it
    /// green-lights screens that are broken for the appliance.
    func testAgainstTheLiveNode() async throws {
        try LiveNode.required("reads the appliance's own standing from the live node")
        let state = await ApplianceWriteReadinessCheck().check()
        let id = try XCTUnwrap(state.agentID, "no appliance key on this Mac")
        XCTAssertEqual(id.count, 64)

        switch state.standing {
        case .registered(let reported):
            print("LIVE: appliance \(id.prefix(16)) profile=\(reported.profile ?? "none") "
                + "mask=\(reported.capabilities.map(String.init) ?? "none") "
                + "approval_required=\(reported.approvalRequired) can_write=\(reported.canWrite)")
            print("LIVE: home=\(reported.homeDomain ?? "none") writable=\(reported.writableDomains)")
            print("LIVE: needsTheOwner=\(state.needsTheOwner) companion=\(state.hasCompanionProfile)")
            if let line = state.logLine { print("LIVE: \(line)") }
        case .notRegistered:
            XCTFail("the node does not know the key this Mac signs as (\(id.prefix(16)))")
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
        let status = reviewed(mask: 0).status(observing: denial)
        XCTAssertEqual(status?.isObserved, true, "a clear mask silenced a refusal we watched happen")
        XCTAssertEqual(status?.remedy, "Submit to the agent's owned non-shared home domain.")
        XCTAssertEqual(status?.detail, denial.detail)
    }

    /// With no denial, the predictive half still speaks.
    func testThePredictionSpeaksWhenNothingHasBeenRefusedYet() {
        let status = awaitingReview(mask: 30).status(observing: nil)
        XCTAssertEqual(status?.isObserved, false)
        XCTAssertNil(status?.detail, "there is no server sentence to quote yet")
        XCTAssertTrue(status?.remedy.contains("companion profile") == true)
    }

    /// The rule the whole feature turns on: when Mynah is working, this state
    /// does not exist. No badge, no green tick, no "all good" row.
    func testAWorkingApplianceProducesNothingToRender() {
        XCTAssertNil(reviewed(mask: 0).status(observing: nil))
        XCTAssertNil(reviewed(mask: 15).status(observing: nil))
    }

    /// An older server sends no per-cause remedy, and that is not rare — it is
    /// every server before v11.14.2. Ours has to stand in.
    func testAnOlderServersDenialFallsBackToOurRemedy() {
        let denial = SageRitual.WriteDenial(domain: "voice-interface", detail: "access denied")
        let status = awaitingReview(mask: 30).status(observing: denial)
        XCTAssertEqual(status?.isObserved, true)
        XCTAssertTrue(status?.remedy.contains("companion profile") == true)
    }

    /// One voice across both paths, so a screen cannot say one thing when it
    /// predicted and another when it observed.
    func testBothPathsUseTheSameHeadline() {
        let observed = awaitingReview(mask: 30).status(
            observing: SageRitual.WriteDenial(domain: "d", detail: "x")
        )
        let predicted = awaitingReview(mask: 30).status(observing: nil)
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
        let state = awaitingReview(mask: ApplianceWriteReadiness.Capability.pendingReview)
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
            standing: .registered(ApplianceStanding(
                registrationStatus: "pending_review",
                approvalRequired: true,
                canWrite: false,
                capabilities: ApplianceWriteReadiness.Capability.pendingReview
            ))
        )
        XCTAssertTrue(try XCTUnwrap(state.remedy).contains("1ab7aa10deadbeef"))
    }

    /// And an unknown id must not produce "the agent whose id starts ." — a
    /// sentence that reads like a truncation bug at the exact moment the owner
    /// is deciding whether to trust what they are being told.
    func testAMissingAgentIDLeavesACompleteSentence() throws {
        let state = ApplianceWriteReadiness(
            agentID: nil,
            standing: .registered(ApplianceStanding(
                registrationStatus: "pending_review",
                approvalRequired: true,
                canWrite: false,
                capabilities: ApplianceWriteReadiness.Capability.pendingReview
            ))
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
        let remedy = awaitingReview(mask: 30).remedy ?? ""
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
        XCTAssertTrue(awaitingReview(mask: 30).remedy?.contains("up to its own clearance") == true)
    }

    /// Stated evenly. The remedy is correct and the owner should apply it —
    /// wording that made the fix sound risky would discourage the right action
    /// in order to look careful, which is its own dishonesty.
    func testTheDisclosureIsNotWordedAsAWarning() {
        let remedy = (awaitingReview(mask: 30).remedy ?? "").lowercased()
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
        let state = awaitingReview(mask: 30)
        XCTAssertFalse(state.shortRemedy?.contains("read across") == true)
        for reason in state.reasons {
            XCTAssertFalse(reason.contains("read across"), "a consequence leaked into a present-tense fact")
        }
    }

    /// And it says nothing at all when there is nothing to apply.
    func testAWorkingApplianceIsToldNoneOfThis() {
        XCTAssertNil(reviewed(mask: 15).remedy)
        XCTAssertNil(reviewed(mask: 0).remedy)
    }
}
