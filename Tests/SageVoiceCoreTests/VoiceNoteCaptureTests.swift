// **Mac-only, because it tests `MynahMac`.**
//
// `MynahMac` is the AppKit/SwiftUI half of this package, and Package.swift does
// not declare that target off Darwin — so the import below resolves on a Mac
// and nowhere else. The guard wraps the whole file rather than just the import,
// because every test in here drives a Mac type: a file that compiled down to an
// empty test class would let Linux report a green suite that ran nothing, which
// is the exact failure this branch exists to stop. See `coreTestDependencies`
// in Package.swift.
#if os(macOS)
import AVFoundation
import XCTest
@testable import MynahMac
@testable import SageVoiceCore

/// Speaking into the window.
///
/// The recognition stack, the composer control, the level meter and the cancel
/// path all already existed — what had never existed anywhere in this app was
/// capture. So these tests are about the seams that decide whether the control
/// appears at all and what happens at its edges, not about audio quality, which
/// no test on a build machine can speak to.
@MainActor
final class VoiceNoteCaptureTests: XCTestCase {

    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    // MARK: - Whether the control exists at all

    /// A Mac with no recogniser must not get the control.
    ///
    /// `canHoldToTalk` is `voice != nil`, so this is the whole mechanism: a
    /// control that cannot lead anywhere does not ship. The alternative — a
    /// button that appears and then fails when pressed — is the shape of every
    /// other bug in this codebase this month.
    func testNoRecogniserMeansNoControl() {
        let discovery = LocalASRDiscovery(
            rootDirectory: root,
            homeDirectory: root
        )
        XCTAssertNil(
            MicrophoneVoiceCapture.ifAvailable(discovery: discovery),
            "hold-to-talk would appear on a Mac that cannot turn speech into words"
        )
    }

    /// And the model agrees, which is the half the owner actually sees.
    func testAModelWithNoVoiceHidesHoldToTalk() {
        XCTAssertFalse(ConversationModel(voice: nil).canHoldToTalk)
    }

    // MARK: - The edges of a recording

    /// Silence must not reach the recogniser.
    ///
    /// Whisper confabulates on it — a silent moment on a call came back as
    /// Japanese and the appliance answered it — so a tap that produced nothing
    /// is reported as nothing rather than transcribed. This also covers the
    /// ordinary misfire: a click that was not a hold.
    func testFinishingWithNoAudioReportsNothingHeardRatherThanTranscribing() async {
        var asked = false
        let capture = MicrophoneVoiceCapture(prepareTranscriber: {
            asked = true
            return NeverCalledTranscriber()
        })
        do {
            _ = try await capture.finish()
            XCTFail("silence was accepted")
        } catch let trouble as MicrophoneVoiceCapture.Trouble {
            XCTAssertEqual(trouble, .heardNothing)
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertFalse(asked, "the recogniser was loaded to transcribe nothing")
    }

    /// Cancel is called from a view and must be safe whenever it is reached —
    /// including when nothing is running, which is what happens if the owner
    /// releases outside the button or the window closes mid-press.
    func testCancellingWhenNothingIsRunningIsHarmless() {
        let capture = MicrophoneVoiceCapture(prepareTranscriber: { NeverCalledTranscriber() })
        capture.cancel()
        capture.cancel()
        XCTAssertEqual(capture.level, 0)
    }

    /// The threshold is a duration, not a sample count, so it survives someone
    /// changing the rate the recogniser wants.
    func testTheShortestUsefulRecordingIsExpressedInTime() {
        XCTAssertGreaterThan(MicrophoneVoiceCapture.shortestUsefulSeconds, 0)
        XCTAssertLessThan(
            MicrophoneVoiceCapture.shortestUsefulSeconds, 1,
            "a threshold this long would reject ordinary short answers like \"yes\""
        )
    }

    /// Whisper is trained at 16 kHz and the call endpoint already decodes to
    /// it. A capture that recorded at the hardware's rate would either be
    /// resampled by somebody else or transcribed badly.
    func testCaptureTargetsTheRateTheRecogniserWants() {
        XCTAssertEqual(MicrophoneVoiceCapture.sampleRate, 16_000)
    }

    // MARK: - What the owner is told when it cannot work

    /// Every failure has to name something the owner can do. A refusal that
    /// says only "recording failed" is the dead end this product keeps removing.
    func testEveryFailureSaysWhatToDoAboutIt() {
        let refused = MicrophoneVoiceCapture.Trouble.microphoneRefused.errorDescription ?? ""
        XCTAssertTrue(refused.contains("System Settings"), "no route out of a refusal")
        XCTAssertTrue(refused.contains("only asks once"), "does not say why re-pressing cannot work")

        let missing = MicrophoneVoiceCapture.Trouble.noRecogniser("x").errorDescription ?? ""
        XCTAssertFalse(missing.isEmpty)

        let nothing = MicrophoneVoiceCapture.Trouble.heardNothing.errorDescription ?? ""
        XCTAssertTrue(nothing.lowercased().contains("longer"), "does not say what to try instead")
    }


    /// A refusal is the one failure with somewhere to send the owner, and it is
    /// the one that most needs it: macOS never shows the prompt twice, so a
    /// sentence describing where the switch lives is their entire route.
    func testOnlyTheRefusalOffersAWayIntoSystemSettings() {
        XCTAssertTrue(MicrophoneVoiceCapture.Trouble.microphoneRefused.opensPrivacySettings)
        XCTAssertFalse(MicrophoneVoiceCapture.Trouble.heardNothing.opensPrivacySettings)
        XCTAssertFalse(MicrophoneVoiceCapture.Trouble.noRecogniser("x").opensPrivacySettings)
    }

    // MARK: - The claim this feature falsified

    /// Settings said *"Mynah never listens through this Mac's microphone"*, and
    /// hold-to-talk made that false. The previous author left an explicit
    /// instruction to change it in the same commit as the feature, and on a
    /// product whose whole argument is where your words go, shipping the
    /// feature without the sentence would have been the most expensive thing
    /// this app could do.
    ///
    /// Asserts on the **value**, not on the file.
    ///
    /// The first two versions of this test read `SettingsView.swift` off disk
    /// and grepped it, and both were wrong in the same way: a source grep
    /// cannot tell a claim from a comment *about* a claim, so it failed on the
    /// note recording what the sentence used to say. The ways to make that pass
    /// were deleting the note or paraphrasing it until the grep missed — both
    /// of which make the codebase quieter about its own history in order to
    /// satisfy a test.
    ///
    /// Lifting the sentence to `PrivacyClaim.microphone` fixed the test and was
    /// worth doing anyway: a privacy claim should not be an anonymous literal
    /// inside a view body.
    func testTheMicrophoneClaimPromisesControlRatherThanNever() {
        let claim = PrivacyClaim.microphone

        // The old sentence, which hold-to-talk falsified.
        XCTAssertFalse(
            claim.contains("never listens through this Mac's microphone"),
            "Settings promises something the composer's record button breaks"
        )
        // "Never" as a claim about capability cannot survive a record button.
        // What survives is a claim about control.
        XCTAssertTrue(claim.contains("only while you hold"))
        XCTAssertTrue(claim.contains("never on its own"))
        XCTAssertTrue(claim.contains("no wake word"))
    }

    /// Recognition staying on the Mac is the load-bearing half for an owner who
    /// has chosen a cloud brain: the audio never leaves, whatever answers it.
    func testTheClaimSaysSpeechIsTurnedIntoWordsOnThisMac() {
        XCTAssertTrue(PrivacyClaim.microphone.contains("on this Mac"))
    }
}

/// Fails the test if it is ever asked to transcribe. Used to prove the
/// recogniser is not reached on the paths that must short-circuit before it.
private struct NeverCalledTranscriber: AudioFileTranscribing {
    func transcribe(audioFile: URL, options: AudioTranscriptionOptions) async throws -> String {
        XCTFail("the recogniser was asked to transcribe when it should not have been")
        return ""
    }
}
#endif  // os(macOS)
