import XCTest
@testable import KokoroEngine
@testable import SageVoiceCore

/// **That the Swift front end says the same thing Python's did.**
///
/// This is the load-bearing test of the whole native voice. Every other stage of
/// the port — tokenizer, voices, trim, upsampler, the graph itself — was verified
/// against captured output, and this one closes the last gap: the text that goes
/// in has to become the same phonemes, because the phonemes are the only thing
/// the model ever sees.
///
/// The fixture is not hand-written. `Tests/Fixtures/espeak-phonemes.json` was
/// produced by calling the exact Python this replaces —
/// `kokoro_onnx.Tokenizer.phonemize`, which is
/// `phonemizer.phonemize(text, 'en-us', preserve_punctuation=True,
/// with_stress=True)` — over 78 cases, and it records the token ids as well as
/// the phoneme string.
///
/// Both are asserted, and the distinction matters. **The tokens are the
/// contract**: Kokoro's vocabulary filter drops anything it does not know, so two
/// different phoneme strings can tokenize identically and the model cannot tell
/// them apart. The phoneme string is asserted anyway, separately, because a
/// divergence that the filter happens to erase today is a divergence that stops
/// being erased the moment the vocabulary changes.
final class EspeakPhonemizerTests: XCTestCase {

    // MARK: Fixtures

    struct Case: Decodable {
        let text: String
        let phonemes: String?
        let tokens: [Int64]?
        let error: String?
    }

    private struct Fixture: Decodable {
        let espeak_version: String
        let contract: String
        let cases: [Case]
    }

    private static let fixture: Fixture? = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // KokoroEngineTests
            .deletingLastPathComponent()   // Tests
            .appendingPathComponent("Fixtures/espeak-phonemes.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Fixture.self, from: data)
    }()

    private func cases() throws -> [Case] {
        guard let fixture = Self.fixture else {
            throw XCTSkip("Tests/Fixtures/espeak-phonemes.json is missing or unreadable")
        }
        return fixture.cases
    }

    /// Skips rather than fails where espeak has not been provisioned, matching
    /// `KokoroSessionTests`. A fresh clone has no `vendor/`, and a test that
    /// cannot run is not a test that failed.
    private func phonemizer() throws -> EspeakPhonemizer {
        do {
            return try EspeakPhonemizer()
        } catch EspeakPhonemizer.Failure.binaryNotFound {
            throw XCTSkip("espeak-ng is not staged — run scripts/provision-espeak-ng.sh")
        }
    }

    // MARK: The one difference we cannot remove

    /// **The single case where this port cannot match Python, and why.**
    ///
    /// Python reaches espeak through `espeak_TextToPhonemes`, a library entry
    /// point. We reach the same espeak through its command line, which runs the
    /// full synthesis path. Those two disagree about one thing: a lone word gets
    /// sentence-stress promotion from the CLI and does not from the library.
    ///
    ///     library "One"      -> w_ˌʌ_n     (secondary)
    ///     library "One two"  -> w_ˈʌ_n     (primary)
    ///     CLI     "One"      -> wˈʌn       (primary, always)
    ///
    /// It shows up here because `preserve` splits `"One, two, three, …"` into
    /// one-word chunks, so `One` is phonemized alone. It is specific to the word
    /// *one*, whose dictionary entry carries secondary stress for the unstressed
    /// reading in "one of the".
    ///
    /// **Closing it would mean calling the library, and the library is GPLv3.**
    /// That is the whole reason espeak is a subprocess here, so this difference
    /// is a permanent consequence of the licence boundary rather than something
    /// left unfinished. The audible effect is the emphasis on one word in a
    /// counted list, and the CLI's primary stress is arguably the better reading
    /// of it.
    ///
    /// Listed explicitly, not tolerated generally: any *other* divergence still
    /// fails, and `testTheKnownDivergenceStillDiverges` fails if this one ever
    /// goes away, so the exception cannot outlive its cause.
    static let knownDivergences: [String: (python: String, swift: String)] = [
        "One, two, three, four, five.": (
            python: "wˌʌn, tˈuː, θɹˈiː, fˈɔːɹ, fˈaɪv.",
            swift: "wˈʌn, tˈuː, θɹˈiː, fˈɔːɹ, fˈaɪv."
        )
    ]

    /// If upstream, a rebuild, or a flag change ever makes this agree, the
    /// exception above is stale and must be deleted rather than left to excuse a
    /// future real difference.
    func testTheKnownDivergenceStillDiverges() throws {
        let subject = try phonemizer()
        for (text, expected) in Self.knownDivergences {
            let produced = vocabularyFiltered(try subject.phonemes(for: text))
            XCTAssertEqual(
                produced, expected.swift,
                "the known divergence for \(text.debugDescription) changed shape"
            )
            XCTAssertNotEqual(
                produced, expected.python,
                "\(text.debugDescription) now matches Python — delete this exception"
            )
        }
    }

    // MARK: The whole corpus

    /// **The one that matters.** Every case, compared on tokens.
    func testEveryCapturedCaseTokenizesIdentically() throws {
        let subject = try phonemizer()
        var mismatches: [String] = []

        for testCase in try cases() {
            guard let expectedTokens = testCase.tokens else { continue }
            if Self.knownDivergences[testCase.text] != nil { continue }
            let produced = try subject.phonemes(for: testCase.text)
            let tokens = KokoroTokenizer.ids(for: produced)
            if tokens != expectedTokens {
                mismatches.append(
                    """
                    \(testCase.text.debugDescription)
                        python: \((testCase.phonemes ?? "").debugDescription)
                        swift:  \(produced.debugDescription)
                    """
                )
            }
        }

        XCTAssertTrue(
            mismatches.isEmpty,
            "\(mismatches.count) case(s) tokenized differently:\n" + mismatches.joined(separator: "\n")
        )
    }

    /// Kokoro's vocabulary filter, applied exactly where Python applies it.
    ///
    /// `Tokenizer.phonemize` ends with `''.join(p for p in phonemes if p in
    /// vocab)`, so the captured `phonemes` field is **already filtered**.
    /// `EspeakPhonemizer` deliberately returns the unfiltered string — that is
    /// what lets a newly-appearing phoneme be noticed rather than silently
    /// dropped — which means the comparison has to filter, not the subject.
    /// Comparing raw against filtered flagged `[the note]` and `¿Que?` as
    /// divergences when both tokenize identically; the mismatch was in this
    /// test, not in the port.
    private func vocabularyFiltered(_ phonemes: String) -> String {
        String(String.UnicodeScalarView(
            phonemes.unicodeScalars.filter { KokoroTokenizer.vocabulary[$0] != nil }
        ))
    }

    /// The phoneme strings themselves, asserted separately so a difference the
    /// vocabulary filter currently hides still shows up here.
    func testEveryCapturedCaseProducesTheSamePhonemeString() throws {
        let subject = try phonemizer()
        var mismatches: [String] = []

        for testCase in try cases() {
            guard let expected = testCase.phonemes else { continue }
            if Self.knownDivergences[testCase.text] != nil { continue }
            let produced = vocabularyFiltered(try subject.phonemes(for: testCase.text))
            if produced != expected {
                mismatches.append(
                    "\(testCase.text.debugDescription)\n"
                    + "    python: \(expected.debugDescription)\n"
                    + "    swift:  \(produced.debugDescription)"
                )
            }
        }

        XCTAssertTrue(
            mismatches.isEmpty,
            "\(mismatches.count) case(s) differ:\n" + mismatches.joined(separator: "\n")
        )
    }

    // MARK: The cases the golden vectors were produced from

    /// These two strings are what `KokoroSessionTests` feeds the graph, so if
    /// text-to-phoneme drifts, the audio comparison silently stops testing the
    /// sentence it names.
    func testTheGoldenVectorSentencesStillProduceTheirGoldenPhonemes() throws {
        let subject = try phonemizer()

        XCTAssertEqual(
            try subject.phonemes(for: "the quick brown fox jumps over the lazy dog."),
            "ðə kwˈɪk bɹˈaʊn fˈɑːks dʒˈʌmps ˌoʊvɚ ðə lˈeɪzi dˈɑːɡ."
        )
        XCTAssertEqual(try subject.phonemes(for: "hello"), "həlˈoʊ")
    }

    /// The example that proves G2P cannot be a lookup table: the currency and
    /// the decimal both become words, and neither is in the input.
    func testCurrencyIsSpokenRatherThanSpelled() throws {
        XCTAssertEqual(
            try phonemizer().phonemes(for: "Cost: $5.50"),
            "kˈɔst: dˈɑːlɚ fˈaɪv.fˈɪfti"
        )
    }

    // MARK: Punctuation, which espeak alone discards

    func testPunctuationSurvivesTheRoundTrip() throws {
        let subject = try phonemizer()

        // A comma mid-sentence and a full stop at the end — the two positions
        // the restore algorithm treats differently.
        XCTAssertEqual(
            try subject.phonemes(for: "hello world, the quick brown fox."),
            "həlˈoʊ wˈɜːld, ðə kwˈɪk bɹˈaʊn fˈɑːks."
        )
    }

    func testTextThatIsOnlyPunctuationSurvives() throws {
        let subject = try phonemizer()
        XCTAssertEqual(try subject.phonemes(for: "."), ".")
        XCTAssertEqual(try subject.phonemes(for: "?!"), "?!")
    }

    /// A leading mark attaches to the front of the first chunk rather than
    /// becoming its own segment.
    func testALeadingMarkIsKeptAtTheFront() throws {
        let produced = try phonemizer().phonemes(for: ", leading comma")
        XCTAssertTrue(produced.hasPrefix(","), "the leading comma moved or vanished: \(produced)")
    }

    // MARK: Structure

    /// **The pattern must compile, asserted directly.**
    ///
    /// It did not, for one unescaped `[`, and because it is built with `try?`
    /// the only symptom was that punctuation stopped being recognised at all —
    /// no error, no log, just a voice that no longer paused. Every punctuation
    /// assertion in this file was failing for that single reason. This test
    /// names the cause instead of leaving it to be inferred from fifty-five
    /// downstream failures.
    func testThePunctuationPatternCompiles() {
        XCTAssertNotNil(
            EspeakPhonemizer.markExpression,
            "the punctuation pattern does not compile, so no mark will be recognised"
        )
    }

    /// `preserve` carries each mark's surrounding whitespace with it, because
    /// that space is a word separator on the way back.
    func testAMarkCarriesTheSpaceThatFollowedIt() {
        let (chunks, marks) = EspeakPhonemizer.preserve("hello, my world!")
        XCTAssertEqual(chunks, ["hello", "my world"])
        XCTAssertEqual(marks.map(\.text), [", ", "!"])
        XCTAssertEqual(marks.map(\.position), [.middle, .end])
    }

    func testTextWithNoMarksIsOneChunk() {
        let (chunks, marks) = EspeakPhonemizer.preserve("no punctuation here")
        XCTAssertEqual(chunks, ["no punctuation here"])
        XCTAssertTrue(marks.isEmpty)
    }

    func testTextThatIsAllMarksHasNoChunks() {
        let (chunks, marks) = EspeakPhonemizer.preserve("...")
        XCTAssertTrue(chunks.isEmpty)
        XCTAssertEqual(marks, [EspeakPhonemizer.Mark(text: "...", position: .alone)])
    }

    /// Every mark in the default set has to be recognised. One missing is one
    /// pause the owner never hears.
    func testEveryDefaultMarkIsRecognised() {
        for mark in EspeakPhonemizer.marks {
            let (chunks, marks) = EspeakPhonemizer.preserve("before\(mark)after")
            XCTAssertEqual(marks.map(\.text), [String(mark)], "\(mark) was not treated as punctuation")
            XCTAssertEqual(chunks, ["before", "after"])
        }
    }

    // MARK: Refusing

    func testAMissingBinaryIsNamedRatherThanCrashing() {
        XCTAssertThrowsError(
            try EspeakPhonemizer(
                binary: URL(fileURLWithPath: "/nowhere/espeak-ng"),
                dataPath: URL(fileURLWithPath: "/nowhere/data")
            )
        ) { error in
            XCTAssertEqual(
                error as? EspeakPhonemizer.Failure,
                .binaryNotFound("/nowhere/espeak-ng")
            )
        }
    }

    /// A present binary with absent data is the failure mode a bad bundle
    /// produces, and espeak's own message for it is unhelpful.
    func testMissingDataIsNamedSeparately() throws {
        let subject = try phonemizer()
        _ = subject
        XCTAssertThrowsError(
            try EspeakPhonemizer(
                binary: URL(fileURLWithPath: "/bin/sh"),
                dataPath: URL(fileURLWithPath: "/nowhere/espeak-ng-data")
            )
        ) { error in
            XCTAssertEqual(
                error as? EspeakPhonemizer.Failure,
                .dataNotFound("/nowhere/espeak-ng-data")
            )
        }
    }

    // MARK: Provenance

    /// The fixture records which espeak produced it. A different version on the
    /// machine is a reason to re-capture, not to edit the expectations.
    func testTheFixtureRecordsTheEspeakItCameFrom() throws {
        guard let fixture = Self.fixture else { throw XCTSkip("fixture missing") }
        XCTAssertEqual(fixture.espeak_version, "1.52.0")
        XCTAssertFalse(fixture.cases.isEmpty)
        XCTAssertTrue(
            fixture.cases.allSatisfy { $0.error == nil },
            "the capture recorded a case Python itself could not phonemize"
        )
    }
}
