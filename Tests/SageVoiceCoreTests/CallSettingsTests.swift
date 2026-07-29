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

// MARK: - Two barriers, one message

private final class RefusalStubBackend: BrainBackend, @unchecked Sendable {
    let identifier = "stub"
    let modelName: String
    let isLocal: Bool

    init(modelName: String, isLocal: Bool) {
        self.modelName = modelName
        self.isLocal = isLocal
    }

    func isAvailable() async -> Bool { true }
    func complete(_ request: BrainRequest) async throws -> BrainReply {
        throw BrainBackendError.unreachable("not used")
    }
}

/// Calling has **two** preconditions — a brain fast enough to hold a line, and a
/// relay secret on this Mac — and the refusal used to name only the first.
///
/// On the owner's machine `~/.sage/call-relay.secret` does not exist, so the
/// message he got told him to switch to an API model and try again; doing
/// exactly that would have landed him on "this Mac hasn't been set up for calls
/// yet". A refusal that names one of two blockers is not a smaller truth, it is
/// a wrong instruction — it costs a trip.
final class CallRefusalTests: XCTestCase {

    private let localBrain = RefusalStubBackend(modelName: "qwen3.5:4b", isLocal: true)
    private let cloudBrain = RefusalStubBackend(modelName: "claude-haiku-4-5", isLocal: false)

    /// The exact case the owner is in, and the regression this guards.
    func testASlowBrainOnAMacWithNoSecretSaysBothInOneMessage() throws {
        let refusal = try XCTUnwrap(
            CallInvitation.refusal(forBackend: localBrain, isSetUpForCalls: false)
        )
        guard case .backendTooSlow(_, let alsoNeedsSetup) = refusal else {
            return XCTFail("expected backendTooSlow, got \(refusal)")
        }
        XCTAssertTrue(alsoNeedsSetup)

        let sentence = refusal.sentence
        XCTAssertTrue(sentence.contains("qwen3.5:4b"), "must still name the model: \(sentence)")
        XCTAssertTrue(
            sentence.contains("set up for calls"),
            "must not hide the second barrier behind the first: \(sentence)"
        )
        XCTAssertTrue(
            sentence.contains("won't be enough"),
            "must say that switching brains alone does not fix it: \(sentence)"
        )
    }

    /// With the secret in place, the model advice is correct again and the extra
    /// clause would be noise — so it must not appear.
    func testASlowBrainOnAReadyMacAdvisesOnlyTheModel() throws {
        let refusal = try XCTUnwrap(
            CallInvitation.refusal(forBackend: localBrain, isSetUpForCalls: true)
        )
        XCTAssertEqual(refusal, .backendTooSlow(model: "qwen3.5:4b", alsoNeedsSetup: false))
        XCTAssertFalse(refusal.sentence.contains("set up for calls"))
        XCTAssertTrue(refusal.sentence.contains("Switch to an API model"))
    }

    /// The case that was previously invisible: nothing wrong with the brain, and
    /// calling still cannot happen. This used to return `nil` — no refusal at
    /// all — and the owner discovered it only by asking for a call and watching
    /// it fail.
    func testAFastBrainOnAMacWithNoSecretStillRefuses() {
        XCTAssertEqual(
            CallInvitation.refusal(forBackend: cloudBrain, isSetUpForCalls: false),
            .notSetUpForCalls
        )
    }

    func testAFastBrainOnAReadyMacDoesNotRefuse() {
        XCTAssertNil(CallInvitation.refusal(forBackend: cloudBrain, isSetUpForCalls: true))
    }

    /// No refusal reaches the owner carrying a path from his own home directory.
    /// `CallHost.Failure` learned this the hard way — it texted
    /// `/Users/<him>/.sage/call-relay.secret` to his phone.
    func testNoRefusalLeaksAFilesystemPath() {
        let refusals: [CallInvitation.Refusal] = [
            .backendTooSlow(model: "qwen3.5:4b", alsoNeedsSetup: true),
            .backendTooSlow(model: "qwen3.5:4b", alsoNeedsSetup: false),
            .notSetUpForCalls
        ]
        for refusal in refusals {
            XCTAssertFalse(refusal.sentence.contains("/"), "path leaked: \(refusal.sentence)")
            XCTAssertFalse(refusal.sentence.contains(".secret"), "path leaked: \(refusal.sentence)")
        }
    }

    /// `//help` must describe the same barriers the refusal would, because it is
    /// read *before* the attempt. It used to re-author the reason from a Bool
    /// and could only ever name the model one.
    func testHelpDescribesTheRealBarrierRatherThanAssumingTheModel() {
        let help = CallInvitation.help(
            callRefusal: CallInvitation.refusal(forBackend: cloudBrain, isSetUpForCalls: false)
        )
        XCTAssertTrue(help.contains("set up for calls"), help)
        XCTAssertFalse(
            help.contains("Switch to an API model"),
            "the brain is already fast — telling him to change it is the old bug"
        )
    }

    func testHelpOffersCallingWhenBothBarriersAreClear() {
        let help = CallInvitation.help(
            callRefusal: CallInvitation.refusal(forBackend: cloudBrain, isSetUpForCalls: true)
        )
        XCTAssertTrue(help.contains("I set up a voice call"), help)
        XCTAssertFalse(help.contains("Not yet"), help)
    }
}

// MARK: - Tool result budget

/// `sage_status` returns 31,321 bytes on the owner's node — 851 `"name": count`
/// pairs. His log shows those turns taking 32.9 s and 41.7 s while the tool
/// itself returns in 0.37 s: the reading is the cost, not the call.
///
/// The first version of this trimmer **shipped a false number** and these tests
/// exist mostly to stop that returning.
final class VoiceToolBudgetTests: XCTestCase {

    /// The exact shape of the owner's payload: a subject map, an agent map whose
    /// keys are unspeakable hashes, and sibling scalars including a byte count
    /// four orders of magnitude larger than any real total.
    private func statusPayload(subjects: Int) -> String {
        let domains = (0..<subjects).map { "\"subject-\($0)\": \($0 + 1)" }.joined(separator: ", ")
        return """
            {"total_memories": 13383, "committed": 13383, "deprecated": 3830, \
            "db_size_bytes": 244154368, \
            "by_agent": {"\(String(repeating: "a", count: 64))": 4628}, \
            "by_domain": {\(domains)}}
            """
    }

    func testASmallResultIsUntouched() {
        let small = "{\"ok\": true}"
        XCTAssertEqual(VoiceToolBudget.fit(small), small)
    }

    /// **The regression that matters.** Summing every `"name": count` swept up
    /// `db_size_bytes` and announced 244 million memories; the model repeated it
    /// faithfully, and the *un-trimmed* model had got the figure right. Never
    /// compute a total the payload already states.
    func testTheStatedTotalIsUsedAndNeverASumOfTheEntries() {
        let fitted = VoiceToolBudget.fit(statusPayload(subjects: 400))

        XCTAssertTrue(fitted.contains("13383"), "must carry the total the payload stated: \(fitted)")
        XCTAssertFalse(fitted.contains("244154368"), "a byte count is not a memory count")
        XCTAssertFalse(fitted.contains("244"), "no derived total may appear: \(fitted)")
    }

    /// `by_agent` keys are 64-character hashes. A voice appliance cannot say one,
    /// and reading them is pure latency.
    func testOpaqueAgentIdentifiersNeverSurvive() {
        let fitted = VoiceToolBudget.fit(statusPayload(subjects: 400))
        XCTAssertFalse(fitted.contains(String(repeating: "a", count: 64)))
    }

    func testTheResultIsBroughtUnderBudgetAndSaysItWasTrimmed() {
        let fitted = VoiceToolBudget.fit(statusPayload(subjects: 851))
        XCTAssertLessThanOrEqual(fitted.utf8.count, VoiceToolBudget.resultByteBudget)
        XCTAssertTrue(fitted.contains("851"), "must say how many there really were: \(fitted)")
        XCTAssertTrue(fitted.contains("truncated"))
    }

    /// Largest, not alphabetical — "which subjects hold the most" is what a
    /// person asking "what do you remember?" is actually asking.
    func testTheLargestSubjectsAreTheOnesKept() {
        let fitted = VoiceToolBudget.fit(statusPayload(subjects: 400))
        XCTAssertTrue(fitted.contains("subject-399"), "the biggest must survive: \(fitted)")
        XCTAssertFalse(fitted.contains("\"subject-0\""), "the smallest must not")
    }

    /// Measured: the same facts as prose made the model stop using the result
    /// entirely (79–103 s, generic deflection); as JSON it answered correctly in
    /// 9 s. A result that looks like commentary is treated as commentary.
    func testTheTrimmedResultKeepsTheShapeOfAToolResult() {
        let fitted = VoiceToolBudget.fit(statusPayload(subjects: 400))
        XCTAssertTrue(fitted.hasPrefix("{"), "must stay JSON, not become prose: \(fitted)")
        XCTAssertTrue(fitted.hasSuffix("}"))
    }

    /// A payload with no stated total must not acquire one.
    func testATotalIsOmittedRatherThanInventedWhenTheSourceGivesNone() {
        let domains = (0..<400).map { "\"s\($0)\": \($0 + 1)" }.joined(separator: ", ")
        let fitted = VoiceToolBudget.fit("{\"by_domain\": {\(domains)}}")
        XCTAssertFalse(fitted.contains("total_memories"), "no total was stated: \(fitted)")
    }

    // MARK: Clamping what Mynah asks for

    /// The owner: *"don't return k10 bro — return a smaller k."* A schema default
    /// is not a mechanism; the model can pass whatever it likes, so the ceiling
    /// runs after it has chosen.
    func testAnOversizedRequestIsCappedOnTheWayOut() {
        let clamped = VoiceToolBudget.clamp(arguments: ["top_k": .int(10), "query": .string("dmg")])
        XCTAssertEqual(clamped["top_k"]?.intValue, VoiceToolBudget.maxResultCount)
        XCTAssertEqual(clamped["query"]?.stringValue, "dmg", "other arguments must pass through")
    }

    /// Only ever lowers. A model that asked for 2 had a reason, and raising it to
    /// a house number would be inventing a request nobody made.
    func testASmallerRequestIsLeftAlone() {
        XCTAssertEqual(VoiceToolBudget.clamp(arguments: ["top_k": .int(2)])["top_k"]?.intValue, 2)
    }

    func testEveryNameASizeArgumentGoesByIsCovered() {
        for key in ["top_k", "limit", "count", "max_results", "n"] {
            XCTAssertEqual(
                VoiceToolBudget.clamp(arguments: [key: .int(50)])[key]?.intValue,
                VoiceToolBudget.maxResultCount,
                "\(key) is a size argument and must be capped"
            )
        }
    }
}
