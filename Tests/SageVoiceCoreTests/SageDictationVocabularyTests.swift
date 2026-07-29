import XCTest
@testable import SageVoiceCore

/// Teaching the recogniser the owner's own words.
///
/// The measured baseline, from real transcripts on this stack:
///
///     VANTARAQ  → "Vantirac"
///     QuietType → "Quiet Type"
///     CometBFT  → "Comet BFT"
///
/// Structure and ordinary proper nouns were already perfect; coinages were not,
/// and coinages are most of what an owner says to an agent manager. These tests
/// are the measurement — if the profile does not repair those three, the
/// feature is not working, and that should fail here rather than be discovered
/// in a voice note.
final class SageDictationVocabularyTests: XCTestCase {

    /// What the owner's node actually holds — his own words, written correctly.
    private let remembered = [
        "The VANTARAQ blue dashboard needs its access reviewed before Friday.",
        "QuietType owns the Fn key, so Mynah must not bind it.",
        "VANTARAQ pricing page still needs rewriting.",
        "SAGE runs on CometBFT and the chain is at app-v22.",
        "Ask the CEREBRUM admin to assign voice-interface to Mynah.",
        "VANTARAQ and QuietType are both his, CometBFT is not."
    ]

    private func profile(from texts: [String]) -> DictationProfile {
        ProfileMemoryCompiler.enrich(
            DictationProfile(),
            with: SageDictationVocabulary.memories(fromRemembered: texts)
        )
    }

    // MARK: - The measurement

    /// The whole feature, end to end, against the three known failures.
    func testTheThreeMeasuredMishearingsAreRepaired() {
        let engine = CorrectionEngine(profile: profile(from: remembered))

        XCTAssertEqual(
            engine.apply(to: "the Quiet Type shortcut"),
            "the QuietType shortcut",
            "QuietType is still being split in two"
        )
        XCTAssertEqual(
            engine.apply(to: "SAGE runs on Comet BFT"),
            "SAGE runs on CometBFT",
            "CometBFT is still being split in two"
        )
    }

    /// The third one is a *phonetic* mishearing rather than a split, and the
    /// distinction matters more than the count.
    ///
    /// "Quiet Type" and "Comet BFT" are the recogniser writing a coinage as the
    /// words it is made of — deterministically derivable from the spelling, and
    /// therefore repairable from vocabulary alone. "Vantirac" is not derivable
    /// from "VANTARAQ" by any rule that would not also rewrite real words.
    ///
    /// So it needs evidence rather than inference: a correction memory, which
    /// is what `DictationMemoryType.correction` is for and what the owner
    /// generates simply by fixing it once in the composer before sending.
    /// Recording that here rather than pretending the vocabulary path covers it.
    func testAPhoneticMishearingNeedsACorrectionRatherThanInference() {
        let vocabularyOnly = CorrectionEngine(profile: profile(from: remembered))
        XCTAssertEqual(
            vocabularyOnly.apply(to: "the Vantirac dashboard"),
            "the Vantirac dashboard",
            "a phonetic variant was guessed at from spelling alone — that rule would rewrite real words too"
        )

        let taught = ProfileMemoryCompiler.enrich(
            profile(from: remembered),
            with: [
                DictationMemory(
                    type: .correction,
                    payload: ["heard": "Vantirac", "corrected": "VANTARAQ"],
                    source: "owner",
                    confidence: 1
                )
            ]
        )
        XCTAssertEqual(
            CorrectionEngine(profile: taught).apply(to: "the Vantirac dashboard"),
            "the VANTARAQ dashboard"
        )
    }

    // MARK: - What counts as a coinage

    func testItFindsTheShapesARecogniserGetsWrong() {
        XCTAssertTrue(SageDictationVocabulary.isCoinage("QuietType"))
        XCTAssertTrue(SageDictationVocabulary.isCoinage("CometBFT"))
        XCTAssertTrue(SageDictationVocabulary.isCoinage("VANTARAQ"))
        XCTAssertTrue(SageDictationVocabulary.isCoinage("CEREBRUM"))
        XCTAssertTrue(SageDictationVocabulary.isCoinage("voice-interface"))
        XCTAssertTrue(SageDictationVocabulary.isCoinage("sage.dev"))
    }

    /// The important half. A vocabulary that swallowed ordinary English would
    /// be a rewriting engine pointed at the owner's speech — which is the scar
    /// `CorrectionEngine` already carries, refusing to learn "but" and "bro"
    /// because a one-token rewrite in either direction corrupts real sentences.
    func testItLeavesOrdinaryLanguageAlone() {
        for ordinary in [
            "the", "dashboard", "Friday", "Mynah", "Dhillon",   // plain words and names
            "AI", "US", "OK",                                    // short acronyms nothing mishears
            "2026", "11.14.2", "3",                              // numbers and versions
            "e.g", "i.e"                                         // abbreviations
        ] {
            XCTAssertFalse(
                SageDictationVocabulary.isCoinage(ordinary),
                "\(ordinary) would be taught to the recogniser as jargon"
            )
        }
    }

    /// A capitalised word starting a sentence is not a coinage, or every
    /// sentence would contribute one.
    func testASentenceInitialCapitalIsNotACoinage() {
        XCTAssertFalse(SageDictationVocabulary.isCoinage("Friday"))
        XCTAssertTrue(SageDictationVocabulary.coinages(in: "Friday is fine.").isEmpty)
    }

    // MARK: - Ranking and the budget

    /// Ranked by how many separate memories mention a term, because a term
    /// written down repeatedly is one said repeatedly, and a wrong entry for it
    /// is wrong constantly.
    func testTheMostMentionedTermRanksFirst() {
        let ranked = SageDictationVocabulary.ranked(fromRemembered: remembered)
        XCTAssertEqual(ranked.first?.term, "VANTARAQ", "mentioned in three memories, ranked \(ranked.map(\.term))")
        XCTAssertEqual(ranked.first?.confidence, 1)
    }

    /// Repetition inside one memory is one piece of evidence, not six.
    func testRepeatingATermInOneMemoryDoesNotStuffTheRanking() {
        let stuffed = ["FOOBAR FOOBAR FOOBAR FOOBAR FOOBAR", "BAZQUX is real.", "BAZQUX again."]
        let ranked = SageDictationVocabulary.ranked(fromRemembered: stuffed)
        XCTAssertEqual(ranked.first?.term, "BAZQUX")
    }

    /// The budget is a real constraint — the node holds five figures of
    /// memories and every term costs a pass over every transcript.
    func testTheBudgetIsHonoured() {
        let many = (0..<500).map { "TERM\($0)X is a thing." }
        XCTAssertEqual(SageDictationVocabulary.memories(fromRemembered: many, limit: 10).count, 10)
    }

    // MARK: - The empty case, which is today

    /// Mynah cannot read its own memories yet — mask 30. So on the owner's
    /// machine right now the source is empty, and that has to be *exactly*
    /// today's behaviour rather than an error or a degraded one.
    func testNoMemoriesMeansNoProfileAndNoChange() {
        XCTAssertTrue(SageDictationVocabulary.memories(fromRemembered: []).isEmpty)

        let empty = profile(from: [])
        XCTAssertTrue(empty.vocabulary.isEmpty)
        XCTAssertTrue(empty.confusions.isEmpty)

        let untouched = "SAGE runs on Comet BFT and Quiet Type owns the Fn key"
        XCTAssertEqual(
            CorrectionEngine(profile: empty).apply(to: untouched),
            untouched,
            "an empty profile changed the transcript"
        )
    }

    /// Memories that contain no coinages are the same as none.
    func testProseWithNoJargonProducesNothing() {
        XCTAssertTrue(
            SageDictationVocabulary.memories(
                fromRemembered: ["He wants to go to the shops on Friday and buy some bread."]
            ).isEmpty
        )
    }
}

// MARK: - The source, and the state the owner is actually in

/// Reading memories, on a node that refuses to let Mynah read memories.
///
/// He is going to run this build with capability mask 30, where `sage_recall`
/// answers with a refusal rather than an empty list — for days, until the SAGE
/// fix lands. These tests are about that being boring.
final class SageMemoryVocabularySourceTests: XCTestCase {

    /// A refusal, an unreachable node, an unregistered agent and a node that is
    /// not running are four different errors and one answer: there is nothing
    /// to learn from right now.
    func testAReadFailureIsIndistinguishableFromAnEmptyCorpus() async {
        let refused = SageMemoryVocabularySource(tools: FailingTools())
        let contents = await refused()
        XCTAssertTrue(contents.isEmpty, "a refusal leaked out as something other than 'nothing'")
    }

    /// And the whole way through: refusal to profile to transcript, unchanged.
    func testARefusedReadLeavesTranscriptsExactlyAsTheyWere() async {
        let store = DictationProfileStore()
        await store.use(source: SageMemoryVocabularySource(tools: FailingTools()).callAsFunction)
        _ = await store.profile()

        let spoken = "SAGE runs on Comet BFT and Quiet Type owns the Fn key"
        let out = await store.repair(spoken)
        XCTAssertEqual(out, spoken, "a node that refuses reads changed the owner's words")
    }

    /// Memory text is mined out of whatever shape recall replies with, because
    /// the reply is rendered for a language model rather than being a stable
    /// API. Guessing wrong costs an empty vocabulary, which is a state this
    /// already degrades to — so lenient beats strict.
    func testMemoryTextIsFoundInTheShapesRecallUses() {
        let wrapped = #"{"memories":[{"content":"VANTARAQ is his"},{"content":"CometBFT too"}]}"#
        XCTAssertEqual(SageMemoryVocabularySource.texts(in: wrapped).count, 2)

        let bare = #"[{"text":"QuietType owns Fn"}]"#
        XCTAssertEqual(SageMemoryVocabularySource.texts(in: bare), ["QuietType owns Fn"])

        // Not JSON at all — the whole reply is the sample, which is fine
        // because mining coinages out of prose is what the vocabulary does.
        XCTAssertEqual(SageMemoryVocabularySource.texts(in: "VANTARAQ and CometBFT"), ["VANTARAQ and CometBFT"])
        XCTAssertTrue(SageMemoryVocabularySource.texts(in: "").isEmpty)
    }

    // MARK: Never on the path of a voice note

    /// The guarantee that matters more than the repair: the owner is holding a
    /// button and waiting on these words. A profile that is not ready yet must
    /// not make him wait for a memory query — the transcript goes through
    /// unrepaired and the profile is there next time.
    func testRepairNeverWaitsForAProfileToBeBuilt() async {
        let store = DictationProfileStore()
        await store.use(source: {
            try? await Task.sleep(for: .seconds(30))
            return ["VANTARAQ and QuietType"]
        })

        let started = Date()
        let out = await store.repair("Quiet Type is his")
        XCTAssertLessThan(
            Date().timeIntervalSince(started), 1,
            "a voice note waited on a memory query"
        )
        XCTAssertEqual(out, "Quiet Type is his", "it waited and repaired instead of passing through")
    }

    /// Once built, it is used — and built only once.
    func testTheProfileIsBuiltOnceAndThenUsed() async {
        let counter = BuildCounter()
        let store = DictationProfileStore()
        await store.use(source: {
            await counter.bump()
            return ["QuietType owns the Fn key."]
        })

        _ = await store.profile()
        _ = await store.profile()
        let repaired = await store.repair("Quiet Type is his")

        XCTAssertEqual(repaired, "QuietType is his")
        let builds = await counter.value
        XCTAssertEqual(builds, 1, "the corpus was re-read; that belongs off the critical path, once")
    }

    /// Gaining read access is the invalidation trigger that will actually fire
    /// on his machine, after the profile has been empty for days.
    func testInvalidatingPicksUpMemoriesThatAppearLater() async {
        let corpus = GrowingCorpus()
        let store = DictationProfileStore()
        await store.use(source: { await corpus.texts })

        _ = await store.profile()
        // Hoisted out of the assertion: an XCTAssert autoclosure cannot await.
        let beforeAccess = await store.repair("Quiet Type")
        XCTAssertEqual(beforeAccess, "Quiet Type", "should be empty at first")

        await corpus.grant(["QuietType owns the Fn key."])
        await store.invalidate()
        _ = await store.profile()

        let afterAccess = await store.repair("Quiet Type")
        XCTAssertEqual(afterAccess, "QuietType")
    }
}

/// Every call fails, the way a node under mask 30 does.
private struct FailingTools: ToolProviding {
    struct Denied: Error {}
    func listTools() async throws -> [MCPTool] { [] }
    func call(name: String, arguments: [String: JSONValue]) async throws -> String { throw Denied() }
}

private actor BuildCounter {
    private(set) var value = 0
    func bump() { value += 1 }
}

/// Stands in for a node that starts refusing reads and later allows them.
private actor GrowingCorpus {
    private(set) var texts: [String] = []
    func grant(_ new: [String]) { texts = new }
}

