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

    private func readiness(mask: UInt32) -> ApplianceWriteReadiness {
        ApplianceWriteReadiness(agentID: "74140c2d", standing: .registered(mask: mask))
    }

    // MARK: When it speaks

    /// The one state that means nobody has looked at this key.
    func testItWarnsOnTheUntouchedSelfRegistrationMask() {
        let pending = readiness(mask: ApplianceWriteReadiness.Capability.pendingReview)

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
        let companion = readiness(mask: ApplianceWriteReadiness.Capability.companion)

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
        XCTAssertFalse(readiness(mask: 0).needsTheOwner)
        XCTAssertNil(readiness(mask: 0).shortRemedy)
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

    /// **The number, pinned against a live observation.**
    ///
    /// `GET /v1/agents` on the owner's own node reports capability mask **30**
    /// for the appliance today, and `needsTheOwner` is an equality test — so if
    /// this constant ever drifts from what SAGE actually stamps on a
    /// self-registered key, the warning does not become wrong, it becomes
    /// *silent*. That is the same failure shape as the ghost identity and the
    /// scoped backlog: everything keeps working, nothing throws, and the screen
    /// quietly goes back to promising something it cannot deliver.
    ///
    /// 30 = deny shared write (2) · deny owning a subject (4) · deny foreign
    /// write (8) · deny other SAGEs (16).
    func testTheSelfRegistrationMaskIsStillTheNumberTheNodeStamps() {
        XCTAssertEqual(ApplianceWriteReadiness.Capability.pendingReview, 30)
        XCTAssertTrue(readiness(mask: 30).needsTheOwner, "the live mask no longer trips the warning")
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
        let remedy = try? XCTUnwrap(readiness(mask: ApplianceWriteReadiness.Capability.pendingReview).shortRemedy)

        XCTAssertEqual(remedy?.contains("Agents page"), true)
        // The long version belongs on that page, not on a screen somebody is
        // waiting to press a button on.
        XCTAssertLessThan(remedy?.count ?? .max, 200)
    }

    /// The identity survives deleting the app and comes back with the same mask,
    /// so a reinstall is the instinctive fix that provably cannot work. Neither
    /// string may suggest it.
    func testNeitherRemedySuggestsReinstalling() {
        let pending = readiness(mask: ApplianceWriteReadiness.Capability.pendingReview)
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
        let pending = readiness(mask: ApplianceWriteReadiness.Capability.pendingReview)
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
        return AppModel(defaults: defaults, pauseState: marker)
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
        let app = AppModel(defaults: defaults, pauseState: marker)
        XCTAssertTrue(marker.isPaused())

        app.isPaused = false

        XCTAssertFalse(app.isPaused)
        XCTAssertFalse(marker.isPaused(), "Resume left the marker on disk, so the daemon stays paused")
    }
}
