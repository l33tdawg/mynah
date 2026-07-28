import XCTest
@testable import MynahMac
@testable import SageVoiceCore

/// The call settings the owner sets in the app and a different process acts on.
///
/// Every assertion about a key string here is load-bearing. Nothing in this
/// target reads `callVoice` or `callTranscript` back: the daemon's
/// `--call-voice` flag and the transcript sender do, in another change and
/// another process. A rename that compiled cleanly would leave the owner
/// adjusting controls that changed nothing, which is the exact failure the
/// appliance's brain-choice record was rebuilt to stop.
final class CallSettingsTests: XCTestCase {

    /// Its own directory per test. These preferences are shared between two
    /// processes, so the store under test is a file rather than a defaults
    /// suite, and tests must not inherit each other's.
    ///
    /// A directory of its own rather than a file in the shared temp directory:
    /// writing goes through OwnerOnlyFileSecurity, which hardens the containing
    /// directory to owner-only. Doing that to /var/folders' shared temp
    /// directory fails, and the failure is swallowed — which looked exactly like
    /// a store that silently does not persist.
    private var preferencesFile: URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mynah-call-prefs-\(name.filter { $0.isLetter || $0.isNumber })",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("call-preferences.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: preferencesFile.deletingLastPathComponent())
        super.tearDown()
    }


    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        suiteName = "mynah.calls.tests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: The voice

    /// An owner who never opens this screen must be shown what they would
    /// actually hear, so the fallback is the daemon's own fallback and not a
    /// second default invented in the app.
    func testTheVoiceFallsBackToWhatTheDaemonWouldUse() {
        let store = CallSettingsStore(fileURL: preferencesFile)
        XCTAssertEqual(store.voice, KokoroHTTPSynthesizer.defaultKokoroVoice)
        XCTAssertEqual(store.voice, "am_michael")
    }

    /// The picked voice has to land where the daemon looks.
    ///
    /// Originally asserted against this process's UserDefaults, which passed
    /// while being wrong: the daemon is a separate process and does not share
    /// this defaults domain, so the value the picker wrote was never the value
    /// the daemon read. Both go through the preferences file now, and this
    /// asserts against the file rather than against the writer's own store —
    /// otherwise it only proves the store agrees with itself.
    func testTheVoiceIsStoredWhereTheDaemonReadsIt() {
        CallSettingsStore(fileURL: preferencesFile).voice = "bf_emma"
        XCTAssertEqual(
            CallPreferences.load(from: preferencesFile).voice,
            "bf_emma",
            "the picked voice did not land where the daemon reads it"
        )
        // A fresh instance is what the next launch gets.
        XCTAssertEqual(CallSettingsStore(fileURL: preferencesFile).voice, "bf_emma")
    }

    // MARK: The transcript

    /// Calls currently leave no record anywhere, so the answer nobody has been
    /// asked for yet is yes.
    func testTranscriptsAreSentUntilTheOwnerSaysOtherwise() {
        XCTAssertTrue(CallSettingsStore(fileURL: preferencesFile).sendsTranscript)
    }

    /// The switch and the thing that acts on it live in different processes, so
    /// they have to agree on what "never answered" means as well as on where it
    /// is stored. If the reader ever defaults the other way, the owner sees a
    /// switch that is on and gets no transcripts.
    ///
    /// This was originally written against UserDefaults on both sides, which
    /// agreed perfectly and would still have failed in practice: the app and the
    /// daemon do not share a defaults domain, so the value the switch wrote was
    /// never the value the daemon read. Both now go through the same file.
    func testTheSwitchAndTheSenderAgreeOnBothKeyAndDefault() {
        XCTAssertEqual(
            CallSettingsStore(fileURL: preferencesFile).sendsTranscript,
            CallPreferences.load(from: preferencesFile).transcript,
            "the settings switch and the transcript sender disagree with nothing stored"
        )

        CallSettingsStore(fileURL: preferencesFile).sendsTranscript = false
        XCTAssertFalse(CallPreferences.load(from: preferencesFile).transcript,
                       "turning the switch off did not reach the sender")

        CallSettingsStore(fileURL: preferencesFile).sendsTranscript = true
        XCTAssertTrue(CallPreferences.load(from: preferencesFile).transcript,
                      "turning the switch back on did not reach the sender")
    }

    /// `bool(forKey:)` would also answer `false` for "never set", which is how a
    /// default-on switch quietly becomes default-off.
    func testTurningTranscriptsOffIsDistinctFromNeverHavingChosen() {
        CallSettingsStore(fileURL: preferencesFile).sendsTranscript = false
        XCTAssertFalse(CallSettingsStore(fileURL: preferencesFile).sendsTranscript)
        XCTAssertFalse(CallPreferences.load(from: preferencesFile).transcript)

        CallSettingsStore(fileURL: preferencesFile).sendsTranscript = true
        XCTAssertTrue(CallSettingsStore(fileURL: preferencesFile).sendsTranscript)
    }

    // MARK: Where the voice list comes from

    /// Derived from the synthesizer's endpoint rather than typed out again, so a
    /// bridge on another port cannot leave the picker listing voices from a
    /// server the calls are not using.
    func testTheVoiceListIsAskedOfTheSameBridgeThatSpeaks() {
        XCTAssertEqual(
            KokoroVoices.endpoint().absoluteString,
            "http://127.0.0.1:8765/voices"
        )
        let moved = URL(string: "http://127.0.0.1:9100/api/speech")!
        XCTAssertEqual(
            KokoroVoices.endpoint(bridge: moved).absoluteString,
            "http://127.0.0.1:9100/voices"
        )
    }

    /// The synthesizer refuses to send the owner's words off-box and so does
    /// this. A "local" bridge that resolves elsewhere is not one to talk to.
    func testANonLoopbackBridgeIsTreatedAsNoBridgeAtAll() async {
        let offBox = URL(string: "http://kokoro.example.com/voices")!
        let result = await KokoroVoices.load(from: offBox)
        XCTAssertEqual(result, .missing)
    }

    /// Nothing listening on the port is the ordinary case — Kokoro is not
    /// running — and it has to come back as a plain absence rather than throwing
    /// a connection error at a settings row.
    func testAnUnreachableBridgeReportsAMissingVoiceRatherThanAnError() async {
        // Port 1 on loopback: privileged, and nothing in this product binds it.
        let dead = URL(string: "http://127.0.0.1:1/voices")!
        let result = await KokoroVoices.load(from: dead)
        XCTAssertEqual(result, .missing)
    }

    // MARK: Naming a voice

    /// Fifty-four rows of `af_alloy` is a list of file names, not a choice.
    func testVoiceNamesAreDecodedIntoWordsAnOwnerCanChooseBetween() {
        XCTAssertEqual(KokoroVoices.displayName("am_michael"), "Michael (American, male)")
        XCTAssertEqual(KokoroVoices.displayName("af_bella"), "Bella (American, female)")
        XCTAssertEqual(KokoroVoices.displayName("bf_emma"), "Emma (British, female)")
        XCTAssertEqual(KokoroVoices.displayName("jm_kumo"), "Kumo (Japanese, male)")
    }

    /// A confidently wrong friendly label is worse than an unfriendly true one,
    /// so anything off the known scheme keeps its raw identifier.
    func testAnUnrecognisedNameIsLeftExactlyAsKokoroSpelledIt() {
        XCTAssertEqual(KokoroVoices.displayName("xq_zzz"), "xq_zzz")
        XCTAssertEqual(KokoroVoices.displayName("ax_alloy"), "ax_alloy")
        XCTAssertEqual(KokoroVoices.displayName("custom"), "custom")
        XCTAssertEqual(KokoroVoices.displayName("aaa_alloy"), "aaa_alloy")
        XCTAssertEqual(KokoroVoices.displayName("am_"), "am_")
    }

    // MARK: The screen

    /// The screen has to read and write the suite it was handed. It mirrors both
    /// values into observable properties, and a mirror that is only written one
    /// way is a control that forgets what the owner chose.
    @MainActor
    func testTheSettingsScreenReadsAndWritesTheSameStore() {
        CallSettingsStore(fileURL: preferencesFile).voice = "af_bella"
        CallSettingsStore(fileURL: preferencesFile).sendsTranscript = false

        let model = SettingsModel(
            defaults: defaults,
            callPreferences: preferencesFile,
            phoneLink: SignalPhoneLink()
        )
        XCTAssertEqual(model.callVoice, "af_bella")
        XCTAssertFalse(model.sendsCallTranscript)

        model.setCallVoice("bm_george")
        model.setSendsCallTranscript(true)
        // Read back through the file, because that is the store the daemon
        // consults. Asserting against this process's defaults would pass while
        // the daemon saw nothing.
        let saved = CallPreferences.load(from: preferencesFile)
        XCTAssertEqual(saved.voice, "bm_george")
        XCTAssertTrue(saved.transcript)
    }
}
