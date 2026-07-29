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
