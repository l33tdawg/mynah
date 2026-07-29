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
    ///
    /// **What "reaches a screen" has to mean, now that two things are in
    /// flight.** The Privacy destination moves these rows out of Settings, and a
    /// tooltip system may soon put explanations behind a hover. A claim that
    /// reaches only a tooltip has not reached a screen: it is invisible on a
    /// trackpad without hovering, invisible on a screenshot, invisible to
    /// somebody reading rather than pointing, and gone entirely if the tooltips
    /// are ever switched off. So the rule this asserts is *carried by a view
    /// that renders unconditionally* — and a claim moved into a tooltip has to
    /// be deleted from this list and re-sited, which will fail loudly rather
    /// than quietly.
    func testEveryClaimIsCarriedBySomethingTheScreenShowsWithoutBeingAskedTo() {
        // Each entry is a string the owner sees without hovering, clicking a
        // disclosure, or turning anything on.
        let rendered = [
            // Settings → About, as a group caption.
            PrivacyClaim.aboutCaption,
            // Settings → Privacy row, handed to the row directly.
            PrivacyClaim.microphone,
            // The Privacy destination, which composes the rest.
            PrivacyClaim.openingStatement,
            PrivacyClaim.recordings,
            PrivacyClaim.memories,
            PrivacyClaim.webSearch,
            PrivacyClaim.calling,
            PrivacyClaim.callTranscript,
            PrivacyClaim.thinkingOnThePhone(model: "claude-sonnet-4-5", staysOnDevice: false),
            PrivacyClaim.thinkingOnThePhone(model: "qwen3.5:4b", staysOnDevice: true),
            PrivacyClaim.thinkingOnThePhone(model: nil, staysOnDevice: false),
            PrivacyClaim.thinkingInThisWindow(destination: "Anthropic", staysOnDevice: false),
            PrivacyClaim.thinkingInThisWindow(destination: nil, staysOnDevice: false)
        ].joined(separator: " ")

        for claim in [
            PrivacyClaim.microphone,
            PrivacyClaim.updateCheckReach,
            PrivacyClaim.updateCheckNoAutoInstall,
            PrivacyClaim.openingStatement,
            PrivacyClaim.recordings,
            PrivacyClaim.memories,
            PrivacyClaim.webSearch,
            PrivacyClaim.calling,
            PrivacyClaim.callTranscript
        ] {
            XCTAssertFalse(claim.isEmpty)
            XCTAssertTrue(
                rendered.contains(claim),
                "a privacy claim exists that nothing on screen carries: \(claim.prefix(60))…"
            )
        }
    }

    // MARK: The destination's own claims

    /// The state before setup has recorded a brain is not "nothing leaves" — it
    /// is "nobody has said yet", and the row must not read as reassurance.
    func testAnUnrecordedBrainIsAnAbsenceRatherThanAPromise() {
        for unknown in [
            PrivacyClaim.thinkingInThisWindow(destination: nil, staysOnDevice: false),
            PrivacyClaim.thinkingOnThePhone(model: nil, staysOnDevice: false)
        ] {
            XCTAssertTrue(unknown.lowercased().contains("hasn't"))
            XCTAssertFalse(unknown.lowercased().contains("never"))
            XCTAssertFalse(unknown.lowercased().contains("stays"))
        }
    }

    /// The cloud row names the company. A privacy page that says "a provider"
    /// where it could say "Anthropic" is softening the one fact it exists for.
    func testTheThinkingClaimNamesWhereTheWordsGo() {
        XCTAssertTrue(
            PrivacyClaim.thinkingInThisWindow(destination: "Anthropic", staysOnDevice: false)
                .contains("Anthropic")
        )
        XCTAssertTrue(
            PrivacyClaim.thinkingOnThePhone(model: "claude-sonnet-4-5", staysOnDevice: false)
                .contains("claude-sonnet-4-5")
        )
    }

    /// **The defect this pair of claims exists to prevent.**
    ///
    /// The page first read the window's recorded brain choice for both
    /// surfaces. Worth recording precisely, because the first version of this
    /// comment overstated it: I asserted the two stores *were* disagreeing on
    /// this machine, having checked only one of them. They are not — both say
    /// `ollama` / `qwen3.5:4b`.
    ///
    /// The claims must still never share a source, because nothing makes them
    /// agree: the daemon builds its backend from its launch flags and never
    /// reads `BrainSelectionStore`, and since the reconcile stopped tearing down
    /// an appliance it cannot read the configuration for, a model changed in the
    /// window can outrun the running appliance until the next successful
    /// reconcile. One row sourced from one store would then state the wrong
    /// destination as fact for whoever is holding the phone.
    func testThePhoneAndTheWindowAreAllowedToDisagree() {
        let phone = PrivacyClaim.thinkingOnThePhone(model: "qwen3.5:4b", staysOnDevice: true)
        let window = PrivacyClaim.thinkingInThisWindow(
            destination: "Anthropic",
            staysOnDevice: false
        )

        XCTAssertTrue(phone.contains("runs on this Mac"))
        XCTAssertTrue(window.contains("Anthropic"))
        XCTAssertNotEqual(phone, window)
        // Neither may speak for the other: the phone claim must not mention the
        // window's destination, and vice versa.
        XCTAssertFalse(phone.contains("Anthropic"))
        XCTAssertFalse(window.contains("qwen3.5:4b"))
    }

    /// Calling claims only what this repository can show: recognition and
    /// synthesis here, and a relay that carries the two ends' details rather
    /// than the call. It must not claim anything about a media path that is
    /// configured outside this app — the ICE servers are served with the page.
    func testTheCallingClaimStopsWhereTheEvidenceStops() {
        let claim = PrivacyClaim.calling

        XCTAssertTrue(claim.contains("on this Mac"))
        XCTAssertTrue(claim.lowercased().contains("not in the call"))
        XCTAssertFalse(
            claim.lowercased().contains("never leaves"),
            "the claim promised something about the media path this app cannot see"
        )
        XCTAssertFalse(claim.lowercased().contains("end-to-end"))
    }

    /// The transcript is a second copy of a conversation in a place the owner
    /// may not be thinking about, so the claim has to say it is conditional and
    /// name the condition.
    func testTheTranscriptClaimSaysItIsSwitchable() {
        XCTAssertTrue(PrivacyClaim.callTranscript.lowercased().contains("if you have"))
        XCTAssertTrue(PrivacyClaim.callTranscript.lowercased().contains("signal"))
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
