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
