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

    /// **The picker reads the same file the voice does.**
    ///
    /// It used to `GET /voices` on the Python bridge, which meant the list was
    /// empty whenever that service was not running — and that service no longer
    /// exists. Reading `voices-v1.0.bin` directly makes the picker and the
    /// synthesizer incapable of disagreeing about which voices there are, since
    /// the style rows come out of the same file.
    func testTheVoiceListComesFromTheFileTheSynthesizerReads() async throws {
        let installed = KokoroAssets.location(of: KokoroAssets.voices)
        let lab = URL(fileURLWithPath: "/Users/l33tdawg/sage-voice-lab/kokoro/voices-v1.0.bin")
        guard let location = [installed, lab].first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) else {
            throw XCTSkip("voices-v1.0.bin is not on this machine")
        }

        guard case let .installed(names) = await CallVoiceLibrary.load(from: location) else {
            return XCTFail("the voices file did not yield a catalogue")
        }
        // 54 voices ship in this file, and the default has to be among them or
        // the picker opens with nothing selected.
        XCTAssertEqual(names.count, 54)
        XCTAssertTrue(names.contains(SageVoiceCore.KokoroVoices.defaultVoiceName))
        XCTAssertEqual(names, names.sorted())
    }

    /// The ordinary first-run case: the 28 MB voices file is downloaded when
    /// Signal is linked, so before that it genuinely is not there. It has to come
    /// back as a plain absence rather than an error at a settings row.
    func testAnAbsentVoicesFileReportsAMissingVoiceRatherThanAnError() async {
        let nowhere = URL(fileURLWithPath: "/nowhere/voices-v1.0.bin")
        let result = await CallVoiceLibrary.load(from: nowhere)
        XCTAssertEqual(result, .missing)
    }

    /// A file that exists but is not a voices archive is the same absence, not a
    /// crash and not a format error shown to the owner.
    func testATruncatedVoicesFileReportsAMissingVoice() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voices-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let junk = directory.appendingPathComponent("voices-v1.0.bin")
        try Data("not a zip archive".utf8).write(to: junk)

        let result = await CallVoiceLibrary.load(from: junk)
        XCTAssertEqual(result, .missing)
    }

    // MARK: Naming a voice

    /// Fifty-four rows of `af_alloy` is a list of file names, not a choice.
    func testVoiceNamesAreDecodedIntoWordsAnOwnerCanChooseBetween() {
        XCTAssertEqual(CallVoiceLibrary.displayName("am_michael"), "Michael (American, male)")
        XCTAssertEqual(CallVoiceLibrary.displayName("af_bella"), "Bella (American, female)")
        XCTAssertEqual(CallVoiceLibrary.displayName("bf_emma"), "Emma (British, female)")
        XCTAssertEqual(CallVoiceLibrary.displayName("jm_kumo"), "Kumo (Japanese, male)")
    }

    /// A confidently wrong friendly label is worse than an unfriendly true one,
    /// so anything off the known scheme keeps its raw identifier.
    func testAnUnrecognisedNameIsLeftExactlyAsKokoroSpelledIt() {
        XCTAssertEqual(CallVoiceLibrary.displayName("xq_zzz"), "xq_zzz")
        XCTAssertEqual(CallVoiceLibrary.displayName("ax_alloy"), "ax_alloy")
        XCTAssertEqual(CallVoiceLibrary.displayName("custom"), "custom")
        XCTAssertEqual(CallVoiceLibrary.displayName("aaa_alloy"), "aaa_alloy")
        XCTAssertEqual(CallVoiceLibrary.displayName("am_"), "am_")
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

/// **Calling has one precondition now, and it took a measurement to get there.**
///
/// There were two: a brain fast enough to hold a line, and a relay secret on
/// this Mac. The model barrier is gone — `qwen3.5:4b`, running on the owner's
/// Mac, answered three questions in 5, 6 and 9 seconds on 29 July 2026, two of
/// them with a SAGE tool call inside. The 40–60 second floor the refusal was
/// built on was never the model; it was tool results arriving 31KB at a time.
///
/// What remains is the barrier the owner was never told about. On his machine
/// `~/.sage/call-relay.secret` does not exist, and the old refusal sent him to
/// switch models — advice that would have landed him on "this Mac hasn't been
/// set up for calls yet" after a trip he did not need to make.
final class CallRefusalTests: XCTestCase {

    private let localBrain = RefusalStubBackend(modelName: "qwen3.5:4b", isLocal: true)
    private let cloudBrain = RefusalStubBackend(modelName: "claude-haiku-4-5", isLocal: false)

    /// **The change, stated as the thing that used to be false.**
    ///
    /// A brain running on this Mac is no longer a reason to refuse a call. If
    /// this ever fails, somebody has reinstated a speed proxy — and the fix for
    /// a slow call is to measure time to first token, not to guess from where
    /// the model runs. A slow cloud model sailed past the old check too.
    ///
    /// **That instruction still stands, and the barrier is back anyway.** On
    /// 4 August 2026 a tester spent a call on `qwen3.5:4b` and reported it
    /// unusable: *"quite slow to think"*, seven filler lines in one wait, a
    /// laptop made *"very laggy"*, and answers lost outright when the model was
    /// interrupted mid-thought. The owner's ruling: *"calling on qwen seems
    /// unusable we should disable //call for local - only api - voice notes
    /// local handles fine but realtime calls is too much"*.
    ///
    /// So the tier stands in for time-to-first-token again, knowingly, with the
    /// measurement still owed. What is different from the old `backendTooSlow`
    /// is where the decision lives: `BrainCapabilities.holdsARealtimeCall`, one
    /// declared property, rather than an `isLocal` check re-derived at each call
    /// site.
    func testACloudBrainOnAReadyMacIsNotRefused() {
        XCTAssertNil(
            CallInvitation.refusal(isSetUpForCalls: true, brain: .hosted),
            "a hosted brain on a Mac that is set up for calls must not be refused"
        )
    }

    /// And the half the tester's report bought: a brain on this Mac is turned
    /// away, with a sentence that names the next action rather than leaving him
    /// to guess.
    func testABrainOnThisMacIsRefusedWithSomethingToDo() {
        let refusal = CallInvitation.refusal(isSetUpForCalls: true, brain: .onDevice)

        XCTAssertEqual(refusal, .brainCannotHoldALine)
        let sentence = refusal?.sentence ?? ""
        XCTAssertTrue(sentence.contains("Settings"), sentence)
        XCTAssertTrue(
            sentence.lowercased().contains("voice note"),
            "it must say voice notes still work, or he learns that by trying: \(sentence)"
        )
    }

    /// The tier decides, and both tiers reach a different answer from the same
    /// Mac — which is what makes this a capability rather than a coincidence.
    func testTheTierIsWhatDecides() {
        XCTAssertNil(CallInvitation.refusal(isSetUpForCalls: true, brain: .hosted))
        XCTAssertEqual(
            CallInvitation.refusal(isSetUpForCalls: true, brain: .onDevice),
            .brainCannotHoldALine
        )
        // Named so the stubs are not flagged as dead: they are the two tiers
        // this distinction is about.
        XCTAssertTrue(localBrain.isLocal && !cloudBrain.isLocal)
    }

    /// **A Mac with no relay loses on that first, whatever brain it has.** The
    /// order matters: telling somebody to switch provider when the real barrier
    /// is a missing secret sends them to fix the wrong thing.
    func testTheMissingSecretIsReportedBeforeTheBrain() {
        XCTAssertEqual(
            CallInvitation.refusal(isSetUpForCalls: false, brain: .onDevice),
            .notSetUpForCalls
        )
        XCTAssertEqual(
            CallInvitation.refusal(isSetUpForCalls: false, brain: .hosted),
            .notSetUpForCalls
        )
    }

    /// No refusal reaches the owner carrying a path from his own home directory.
    /// `CallHost.Failure` learned this the hard way — it texted
    /// `/Users/<him>/.sage/call-relay.secret` to his phone.
    ///
    /// **Looks for a path, not for a slash.** It banned the `/` character
    /// outright, which is not the same rule and is not one the product can keep:
    /// the refusal that tells him to switch provider necessarily names the
    /// command, and `//call` has two. Banning the character would have forced
    /// the sentence to talk around its own subject to satisfy a test.
    ///
    /// So this names what actually leaked: an absolute path, a home directory, a
    /// dotfile, the secret itself.
    func testNoRefusalLeaksAFilesystemPath() {
        for refusal: CallInvitation.Refusal in [
            .notSetUpForCalls, .brainCannotHoldALine, .couldNotStart("timed out")
        ] {
            let sentence = refusal.sentence
            for leak in ["/Users/", "~/", ".sage/", ".secret", "Application Support", "/private/"] {
                XCTAssertFalse(sentence.contains(leak), "leaked \(leak): \(sentence)")
            }
            // An absolute path anywhere in the sentence, which is the general
            // shape rather than the spellings above.
            //
            // One leading slash, not two: `//call` and `//help` are this
            // product's own commands and a refusal that recommends one has to be
            // able to name it. `/Users/him` is a path; `//call` is a verb.
            XCTAssertFalse(
                sentence.split(separator: " ").contains {
                    $0.hasPrefix("/") && !$0.hasPrefix("//") && $0.count > 1
                },
                "an absolute path leaked: \(sentence)"
            )
        }
    }

    /// `//help` is read *before* the attempt, so it must describe the same
    /// barrier the refusal would. It used to re-author the reason from a Bool
    /// and could only ever name the model one.
    func testHelpDescribesTheRealBarrier() {
        let help = CallInvitation.help(callRefusal: CallInvitation.refusal(isSetUpForCalls: false, brain: .hosted))
        XCTAssertTrue(help.contains("set up for calls"), help)
        XCTAssertFalse(
            help.contains("API model"),
            "help is still telling him to change his brain, which fixes nothing"
        )
    }

    func testHelpOffersCallingWhenTheMacIsReady() {
        let help = CallInvitation.help(callRefusal: CallInvitation.refusal(isSetUpForCalls: true, brain: .hosted))
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

// MARK: - How much room a result gets

/// The budget stopped being one number, and this is why.
///
/// The owner asked what his agents had sent. Codex had written two long
/// messages; the second was cut at 2 KB and Mynah reported *"the second message
/// got truncated by the system, so I may have missed its tail end."* Honest, and
/// useless — the message was the errand.
final class ToolResultBudgetTests: XCTestCase {

    private func payload(_ bytes: Int) -> String {
        "{\"items\": \"" + String(repeating: "a", count: bytes) + "\"}"
    }

    // MARK: What the bytes are

    func testAnAgentsMessageGetsMoreRoomThanADirectory() {
        XCTAssertGreaterThan(
            VoiceToolBudget.budget(forTool: "sage_inbox", brain: .onDevice),
            VoiceToolBudget.budget(forTool: "sage_status", brain: .onDevice),
            "a truncated directory loses names nobody can hear read aloud; a truncated "
                + "message loses the thing that was asked for"
        )
    }

    func testTheOwnersOwnContentIsWhatEarnsTheRoom() {
        for tool in ["sage_inbox", "sage_recall", "read_note", "web_search"] {
            XCTAssertGreaterThan(
                VoiceToolBudget.budget(forTool: tool, brain: .onDevice),
                VoiceToolBudget.resultByteBudget,
                "\(tool) returns content, not a listing"
            )
        }
        for tool in ["sage_status", "sage_backlog", "sage_timeline", "list_notes"] {
            XCTAssertEqual(
                VoiceToolBudget.budget(forTool: tool, brain: .onDevice),
                VoiceToolBudget.resultByteBudget,
                "\(tool) is a directory and the measured 2 KB still applies to it"
            )
        }
    }

    // MARK: Which brain is reading

    func testAHostedBrainIsNotHeldToALocalModelsLatencyBudget() {
        // 2 KB is prefill arithmetic for qwen3.5:4b on this Mac — 0.36 ms a
        // byte. Against a hosted model the prefill happens on somebody else's
        // hardware and the honest cost is a few tokens.
        XCTAssertGreaterThan(
            VoiceToolBudget.budget(forTool: "sage_status", brain: .hosted),
            VoiceToolBudget.budget(forTool: "sage_status", brain: .onDevice)
        )
        XCTAssertGreaterThan(
            VoiceToolBudget.budget(forTool: "sage_inbox", brain: .hosted),
            VoiceToolBudget.budget(forTool: "sage_inbox", brain: .onDevice)
        )
    }

    func testTheReportedCaseNowSurvives() {
        // Two long agent messages, which is what arrived: about 8 KB of inbox.
        let inbox = payload(8_000)

        let onCloud = VoiceToolBudget.fit(inbox, tool: "sage_inbox", brain: .hosted)
        XCTAssertEqual(onCloud, inbox, "nothing should have been cut")
        XCTAssertFalse(onCloud.contains("left"), "and nothing should claim it was")

        let onDirectory = VoiceToolBudget.fit(inbox, tool: "sage_status", brain: .onDevice)
        XCTAssertLessThan(onDirectory.utf8.count, inbox.utf8.count)
    }

    // MARK: What has not changed

    func testATrimStillSaysItTrimmed() {
        // The one thing that must survive every adjustment to these numbers: a
        // model handed a severed answer has to know it was severed, or it
        // answers confidently from half a result.
        let huge = payload(200_000)
        let fitted = VoiceToolBudget.fit(huge, tool: "sage_inbox", brain: .hosted)

        XCTAssertLessThan(fitted.utf8.count, huge.utf8.count)
        XCTAssertTrue(fitted.contains("left"), fitted.suffix(200).description)
    }

    func testTheDefaultIsStillTheCautiousOne() {
        // `fit(_:)` with no tool and no brain named is the local directory
        // budget, so a caller that has not been taught the difference cannot
        // accidentally hand a 4B model 31 KB.
        XCTAssertEqual(
            VoiceToolBudget.fit(payload(10_000)).utf8.count,
            VoiceToolBudget.fit(payload(10_000), tool: "", brain: .onDevice).utf8.count
        )
    }
}
