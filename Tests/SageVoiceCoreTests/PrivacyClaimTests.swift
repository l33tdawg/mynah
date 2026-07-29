import XCTest
@testable import MynahMac
@testable import SageVoiceCore

/// The sentences that tell the owner where their words go, and what a third
/// party learns.
///
/// **Written because one of them silently stopped being displayed.** A density
/// pass on Settings compressed the update-check row and kept the outbound half —
/// what GitHub is told — while dropping "Nothing is downloaded or installed on
/// its own". Everything remaining was true. The tree was green. The claim was
/// simply no longer on the screen, and it took somebody comparing a before-and-
/// after render to notice.
///
/// `PrivacyClaim` already existed and already had a test, so it is worth being
/// precise about why neither helped: the type held exactly one member, and the
/// lost sentence had never been enrolled in it. **A registry protects only what
/// somebody remembered to register, and the sentence most likely to be dropped
/// is the one nobody thought to register.** So these tests check two different
/// things — that each claim says what it must, and that the screen is *composed
/// from* the claims rather than repeating them, which is what makes a deletion
/// visible from here.
final class PrivacyClaimTests: XCTestCase {

    // MARK: The claims themselves

    /// The one that was lost. Its content matters as much as its existence: an
    /// owner reading about an update check wants to know whether the update
    /// arrives on its own, and "asks GitHub" does not answer that.
    func testTheUpdateCheckSaysNothingInstallsItself() {
        let claim = PrivacyClaim.updateCheckNoAutoInstall

        XCTAssertTrue(claim.lowercased().contains("downloaded or installed"))
        XCTAssertTrue(
            claim.lowercased().contains("on its own"),
            "the claim no longer says the thing that makes it a reassurance"
        )
    }

    /// The outbound half, which survived the pass and must keep both parts:
    /// what the request tells GitHub, and that turning it off stops it entirely.
    func testTheUpdateCheckSaysWhatGitHubLearnsAndHowToStopIt() {
        let claim = PrivacyClaim.updateCheckReach

        XCTAssertTrue(claim.contains("GitHub"))
        XCTAssertTrue(claim.lowercased().contains("this machine exists"))
        XCTAssertTrue(
            claim.lowercased().contains("never contacts github"),
            "the owner was told what leaks without being told how to stop it"
        )
    }

    /// Not a claim about capability. It survived a feature that would have made
    /// "never" untrue, which is the reason it is worded as control.
    func testTheMicrophoneClaimIsAboutControlRatherThanCapability() {
        XCTAssertTrue(PrivacyClaim.microphone.contains("only while"))
        XCTAssertFalse(PrivacyClaim.microphone.contains("never opens"))
    }

    // MARK: Enrolment — the half that was missing

    /// The About caption is built from the claims, so a sentence cannot leave
    /// the screen without leaving this type.
    ///
    /// This is the assertion that would have caught the loss. Reading the
    /// rendered string is not something a test can do; reading the string the
    /// view is handed is, and that is only useful if the view is handed a
    /// composition rather than a literal.
    func testTheAboutCaptionIsComposedFromTheClaimsRatherThanRepeatingThem() {
        let caption = PrivacyClaim.aboutCaption

        XCTAssertTrue(
            caption.contains(PrivacyClaim.updateCheckReach),
            "the caption no longer carries what the update check tells GitHub"
        )
        XCTAssertTrue(
            caption.contains(PrivacyClaim.updateCheckNoAutoInstall),
            "the caption dropped the claim that nothing installs itself — again"
        )
    }

    /// Every claim has to be reachable from something the screen renders.
    ///
    /// Deliberately a list that must be updated by hand when a claim is added:
    /// the failure is loud, it names the new claim, and the fix is to point it
    /// at wherever it is rendered. A test that discovered its own membership
    /// would pass for a claim nobody displays, which is the bug this whole file
    /// exists about.
    func testEveryClaimIsCarriedBySomethingTheScreenShows() {
        let rendered = [
            PrivacyClaim.aboutCaption,
            // The microphone claim is handed to the privacy row directly; it is
            // its own carrier.
            PrivacyClaim.microphone
        ].joined(separator: " ")

        for claim in [
            PrivacyClaim.microphone,
            PrivacyClaim.updateCheckReach,
            PrivacyClaim.updateCheckNoAutoInstall
        ] {
            XCTAssertFalse(claim.isEmpty)
            XCTAssertTrue(
                rendered.contains(claim),
                "a privacy claim exists that nothing on screen carries: \(claim.prefix(60))…"
            )
        }
    }

    // MARK: The vocabulary these share with everything else

    /// Owner-facing, so the settled words apply: subject not domain, remember
    /// not save.
    func testTheClaimsUseTheProductsOwnVocabulary() {
        for claim in [
            PrivacyClaim.microphone,
            PrivacyClaim.updateCheckReach,
            PrivacyClaim.updateCheckNoAutoInstall
        ] {
            XCTAssertFalse(claim.lowercased().contains("domain"))
        }
    }
}
