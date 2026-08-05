import XCTest
@testable import MynahMac
@testable import SageVoiceCore

/// What the last screen of setup promises.
///
/// Ready is where trust is established — it is the moment somebody is told the
/// thing works — so it is the worst place in the product for a promise that does
/// not hold. On a node where the appliance still carries the untouched
/// self-registration mask it will answer warmly and remember nothing, and the
/// owner finds out a week later if at all.
///
/// These assertions are about the *condition* and the *strings*, because that is
/// where this goes wrong. The rendering is a banner; the danger is warning at
/// the wrong time or inventing a second remedy.
final class ReadyStagePromiseTests: XCTestCase {

    /// An agent the node says is still waiting for a person to look at it.
    private func awaitingReview(mask: UInt32) -> ApplianceWriteReadiness {
        ApplianceWriteReadiness(agentID: "74140c2d", standing: .registered(ApplianceStanding(
            registrationStatus: "pending_review",
            approvalRequired: true,
            canWrite: false,
            capabilities: mask
        )))
    }

    /// An agent an administrator has assigned a profile to.
    private func reviewed(mask: UInt32, profile: String? = nil) -> ApplianceWriteReadiness {
        ApplianceWriteReadiness(agentID: "74140c2d", standing: .registered(ApplianceStanding(
            profile: profile, approvalRequired: false, canWrite: true, capabilities: mask
        )))
    }

    // MARK: When it speaks

    /// The one state that means nobody has looked at this key.
    func testItWarnsOnTheUntouchedSelfRegistrationMask() {
        let pending = awaitingReview(mask: ApplianceWriteReadiness.Capability.pendingReview)

        XCTAssertTrue(pending.needsTheOwner)
        XCTAssertNotNil(pending.headline)
        XCTAssertNotNil(pending.shortRemedy)
    }

    /// **The trap, and the reason this reads `needsTheOwner` rather than
    /// re-deriving it.** The Companion profile an administrator assigns keeps
    /// all three write denials, so anything keyed on "is it restricted" would go
    /// on shouting after the owner had done everything correctly — forever,
    /// because neither this screen nor the check can see domain ownership. A
    /// warning that never clears teaches people to ignore the one place we have
    /// to tell them something true.
    func testItIsSilentOnceAnAdministratorHasAssignedTheCompanionProfile() {
        let companion = reviewed(
            mask: ApplianceWriteReadiness.Capability.companion, profile: "companion"
        )

        XCTAssertFalse(companion.needsTheOwner, "the Ready screen would warn at a correctly set up appliance")
        XCTAssertNil(companion.headline)
        XCTAssertNil(companion.shortRemedy)
        // Stated against the constants so the case above cannot quietly stop
        // being the trap: the moment Companion no longer carries a write denial,
        // "is it restricted" and "has anybody looked at it" agree again and this
        // test would pass for the wrong reason.
        XCTAssertNotEqual(
            ApplianceWriteReadiness.Capability.companion
                & ApplianceWriteReadiness.Capability.writeDenials,
            0,
            "Companion has stopped carrying write denials, so this no longer tests anything"
        )
    }

    func testItIsSilentOnAnUnrestrictedKey() {
        XCTAssertFalse(reviewed(mask: 0).needsTheOwner)
        XCTAssertNil(reviewed(mask: 0).shortRemedy)
    }

    /// An appliance that cannot see its node must not tell the owner their
    /// permissions are wrong. Both of these render nothing.
    func testItIsSilentWhenTheNodeCannotBeAskedOrHasNotSeenTheKeyYet() {
        let unreachable = ApplianceWriteReadiness(agentID: "x", standing: .unknown("node not answering"))
        let unregistered = ApplianceWriteReadiness(agentID: "x", standing: .notRegistered)

        XCTAssertFalse(unreachable.needsTheOwner)
        XCTAssertFalse(unregistered.needsTheOwner)
        XCTAssertNil(unreachable.shortRemedy)
        XCTAssertNil(unregistered.shortRemedy)
    }

    /// **The number is no longer what decides, and that is the 1.7.5 fix.**
    ///
    /// This test used to say: `GET /v1/agents` reports mask 30 for the appliance
    /// today, `needsTheOwner` is an equality test, so if the constant drifts
    /// from what SAGE stamps the warning does not become wrong — it becomes
    /// *silent*.
    ///
    /// It was right about the failure mode and wrong about the mask, and the
    /// warning was silent the whole time it was green. Two reasons, either
    /// fatal on its own: `/v1/agents` answers `401` to an unsigned caller, so
    /// no mask was ever read; and the appliance's live mask is **31**, not 30.
    ///
    /// The lesson is not "pin a better number" — it is that a fact about the
    /// node has no business being reconstructed here at all. `approval_required`
    /// is stated in a signed `sage_status`, so there is nothing left to drift.
    /// The mask stays only to explain *which* restriction applies.
    func testTheWarningIsTrippedByTheNodesStatementAndNotByAMask() {
        // The old trigger, at both the mask it was written for and the one the
        // node actually reports. Neither warns on its own any more.
        for stamped: UInt32 in [30, 31] {
            XCTAssertFalse(
                reviewed(mask: stamped).needsTheOwner,
                "mask \(stamped) tripped the warning by itself; that is the guess this replaced"
            )
            XCTAssertTrue(
                awaitingReview(mask: stamped).needsTheOwner,
                "the node said approval is required at mask \(stamped) and the screen stayed quiet"
            )
        }
        // Kept because `reasons` still explains the bits to the owner.
        XCTAssertEqual(ApplianceWriteReadiness.Capability.pendingReview, 30)
    }

    /// Companion must stay a different number, or the trap closes: the screen
    /// would either warn forever or never.
    func testCompanionIsDistinctFromPendingReview() {
        XCTAssertNotEqual(
            ApplianceWriteReadiness.Capability.companion,
            ApplianceWriteReadiness.Capability.pendingReview
        )
    }

    // MARK: What it says

    /// One remedy in the product. The Ready banner renders `shortRemedy`
    /// verbatim, so if a second phrasing is ever written here this stops being
    /// true and the surfaces start disagreeing.
    func testTheShortRemedyPointsAtThePageThatExplainsIt() {
        let remedy = try? XCTUnwrap(awaitingReview(mask: ApplianceWriteReadiness.Capability.pendingReview).shortRemedy)

        XCTAssertEqual(remedy?.contains("Agents page"), true)
        // The long version belongs on that page, not on a screen somebody is
        // waiting to press a button on.
        XCTAssertLessThan(remedy?.count ?? .max, 200)
    }

    /// The identity survives deleting the app and comes back with the same mask,
    /// so a reinstall is the instinctive fix that provably cannot work. Neither
    /// string may suggest it.
    func testNeitherRemedySuggestsReinstalling() {
        let pending = awaitingReview(mask: ApplianceWriteReadiness.Capability.pendingReview)
        for sentence in [pending.headline, pending.shortRemedy, pending.remedy].compactMap({ $0 }) {
            let said = sentence.lowercased()
            for wrong in ["reinstall", "install it again", "install it once more", "set it up again",
                          "delete mynah", "start over"] {
                XCTAssertFalse(said.contains(wrong), "\"\(sentence)\" suggests \"\(wrong)\"")
            }
        }
    }

    /// `thread` and `voice` converged on "subject" for owner-facing text; SAGE's
    /// own word is domain and stays in the code. The Ready banner renders these
    /// strings, so it inherits the rule rather than restating it.
    func testTheOwnerFacingStringsSaySubjectRatherThanDomain() {
        let pending = awaitingReview(mask: ApplianceWriteReadiness.Capability.pendingReview)
        for sentence in [pending.headline, pending.shortRemedy].compactMap({ $0 }) {
            XCTAssertFalse(
                sentence.lowercased().contains("domain"),
                "\"\(sentence)\" uses the node's word rather than the owner's"
            )
        }
    }
}

/// What the last screen still implies about a phone.
///
/// Linking came off the onboarding gate, and the two changes meet on this
/// screen: it is the only place that both offers the phone and summarises what
/// was set up.
final class ReadyStagePhoneTests: XCTestCase {

    /// The step it draws when something is unfinished used to be `iphone.gen3`,
    /// which was right while linking a phone was the only deferrable step. It is
    /// not any more — the one thing anyone can defer now is the API key — so a
    /// phone there would illustrate the wrong problem entirely.
    func testTheUnfinishedMarkIsNoLongerAPhone() {
        XCTAssertNotNil(
            StageIllustration.subject(named: StageIllustration.mark(.connect)),
            "the key drawing the unfinished branch now uses has gone missing"
        )
    }

    /// Nothing left on the gate asks for a phone.
    func testNoStageOnTheGateIsAboutAPhone() {
        XCTAssertFalse(SetupModel.Stage.allCases.map(\.title).contains("Phone"))
    }
}

/// The other promise this screen can break, and the one the owner is about to
/// meet.
///
/// The pause marker lives in Application Support, so it outlives the app that
/// set it and survives a reinstall. Somebody who paused Mynah weeks ago reaches
/// the end of setup with an appliance that will not answer — and until this,
/// every line on that screen said everything was fine. `voice` found the marker
/// still on the owner's disk while the DMG was being packaged, which is exactly
/// who will hit it first.
@MainActor
final class ReadyStagePausedTests: XCTestCase {

    private func makeApp(paused: Bool) throws -> AppModel {
        let defaults = UserDefaults(suiteName: "mynah.ready.\(UUID().uuidString)")!
        defaults.set(true, forKey: "mynah.setupComplete")
        // A pause marker of this test's own, never the developer's. `voice`
        // removed the defaults mirror precisely because the file is the store
        // that counts, and a test that reads the real one passes or fails on
        // whether whoever ran it happened to have Mynah paused.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ready-pause-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let marker = PauseState(fileURL: root.appendingPathComponent("paused"))
        if paused { try marker.setPaused(true) }
        return AppModel(defaults: defaults, backgroundServices: InertAppliance(), pauseState: marker)
    }

    /// The state that must not read as "ready".
    func testAPausedApplianceIsNotDescribedAsReady() throws {
        let app = try makeApp(paused: true)
        XCTAssertTrue(app.isPaused, "the injected marker did not take")
    }

    /// And the ordinary case still is. A screen that hedged permanently would be
    /// the Companion trap again in a different costume.
    func testAnUnpausedApplianceIsUnaffected() throws {
        let app = try makeApp(paused: false)
        XCTAssertFalse(app.isPaused)
    }

    /// **Every pair of conditions this screen branches on, walked deliberately.**
    ///
    /// The first two defects were found by thinking about one owner's machine
    /// rather than about the shape of the problem, so this is the shape: a
    /// sentence chosen for one condition may assert something a *different*
    /// condition contradicts, and the two were written months apart by people
    /// looking at one of them at a time.
    ///
    /// Ready branches on three — a deferred step, the capability mask, and the
    /// pause marker. Eight combinations. Three produced a false sentence:
    ///
    /// - mask + paused → the title said "Mynah can answer", and it will not.
    /// - paused alone → the mark drew a machine *listening*.
    /// - deferred + paused → the subtitle promised it would answer "as soon as
    ///   you finish it", and finishing changes nothing while it is paused.
    ///
    /// The other five are understated at worst. This asserts the vocabulary
    /// rather than the rendering, because the rendering is a `switch` and the
    /// vocabulary is what goes wrong.
    func testNoSentenceForOneConditionContradictsAnother() {
        // "can answer" may never appear anywhere that survives a pause, and
        // "will answer as soon as" may never be conditioned only on the step.
        let pausedSafe = ["Mynah is paused, and can't remember yet.",
                          "Mynah is ready, but paused.",
                          "One thing left."]
        for sentence in pausedSafe {
            XCTAssertFalse(
                sentence.lowercased().contains("can answer"),
                "\"\(sentence)\" claims it answers while paused"
            )
        }
        XCTAssertTrue(
            "Finish it and start Mynah answering — both are waiting in Settings whenever you're ready."
                .contains("start Mynah answering"),
            "the deferred-step subtitle stopped naming the pause"
        )
    }

    /// The click the screen offers has to actually clear the marker, not just
    /// the in-memory flag — the daemon reads the file, and a Resume that only
    /// updated the window is the original bug.
    func testStartingAnsweringClearsTheMarkerAndNotJustTheFlag() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ready-resume-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let marker = PauseState(fileURL: root.appendingPathComponent("paused"))
        try marker.setPaused(true)

        let defaults = UserDefaults(suiteName: "mynah.ready.\(UUID().uuidString)")!
        defaults.set(true, forKey: "mynah.setupComplete")
        let app = AppModel(defaults: defaults, backgroundServices: InertAppliance(), pauseState: marker)
        XCTAssertTrue(marker.isPaused())

        app.isPaused = false

        XCTAssertFalse(app.isPaused)
        XCTAssertFalse(marker.isPaused(), "Resume left the marker on disk, so the daemon stays paused")
    }
}
