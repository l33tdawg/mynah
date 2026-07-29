import XCTest
@testable import SageVoiceCore

/// **That the Swift tokenizer produces the exact tokens Python fed the model.**
///
/// These are not invented expectations. Both sequences were captured from the
/// running `kokoro_onnx` 0.5.0 on this Mac by instrumenting the real call — the
/// literal `int64` array that reached `session.run`, for a sentence whose audio
/// output is also on disk.
///
/// A vocabulary is the kind of thing that fails silently. A wrong id does not
/// crash; it substitutes one phoneme for another and produces speech that is
/// subtly wrong in a way nobody can trace back to a table. Comparing against a
/// captured sequence is the only check that actually means anything here.
final class KokoroTokenizerTests: XCTestCase {

    /// espeak-ng 1.52.0, voice `gmw/en-US`, for
    /// "The quick brown fox jumps over the lazy dog."
    private let foxPhonemes = "ðə kwˈɪk bɹˈaʊn fˈɑːks dʒˈʌmps ˌoʊvɚ ðə lˈeɪzi dˈɑːɡ."

    /// Captured from `kokoro_onnx`, unpadded.
    private let foxIDs: [Int64] = [
        81, 83, 16, 53, 65, 156, 102, 53, 16, 44, 123, 156, 43, 135, 56, 16,
        48, 156, 69, 158, 53, 61, 16, 46, 147, 156, 138, 55, 58, 61, 16, 157,
        57, 135, 64, 85, 16, 81, 83, 16, 54, 156, 47, 102, 68, 51, 16, 46,
        156, 69, 158, 92, 4
    ]

    private let helloPhonemes = "həlˈoʊ."
    private let helloIDs: [Int64] = [50, 83, 54, 156, 57, 135, 4]

    // MARK: The golden vectors

    func testTheFoxSentenceTokenizesExactlyAsPythonDid() {
        XCTAssertEqual(KokoroTokenizer.ids(for: foxPhonemes), foxIDs)
    }

    func testTheFoxSentenceIsPaddedExactlyAsPythonDid() {
        XCTAssertEqual(KokoroTokenizer.tokens(for: foxPhonemes), [0] + foxIDs + [0])
        XCTAssertEqual(KokoroTokenizer.tokens(for: foxPhonemes).count, 55)
    }

    /// The short one, because a short input is the first thing a native port
    /// gets working and the easiest place to see an off-by-one in the padding.
    func testTheShortSentenceTokenizesExactlyAsPythonDid() {
        XCTAssertEqual(KokoroTokenizer.ids(for: helloPhonemes), helloIDs)
        XCTAssertEqual(KokoroTokenizer.tokens(for: helloPhonemes), [0, 50, 83, 54, 156, 57, 135, 4, 0])
    }

    // MARK: The table itself

    /// The stress and length marks are their own tokens and are the ones most
    /// likely to be lost by a well-meaning "normalisation" somewhere upstream —
    /// dropping `ˈ` does not break anything, it just flattens the speech.
    func testTheProsodyMarksAreInTheTable() {
        XCTAssertEqual(KokoroTokenizer.vocabulary["ˈ"], 156, "primary stress")
        XCTAssertEqual(KokoroTokenizer.vocabulary["ˌ"], 157, "secondary stress")
        XCTAssertEqual(KokoroTokenizer.vocabulary["ː"], 158, "length")
    }

    /// A space is a real token, not whitespace to be trimmed. Word boundaries
    /// are what stop the sentence being read as one long word.
    func testASpaceIsATokenRatherThanSomethingToStrip() {
        XCTAssertEqual(KokoroTokenizer.vocabulary[" "], 16)
        XCTAssertEqual(KokoroTokenizer.ids(for: "a a"), [43, 16, 43])
    }

    /// **The scalar-versus-grapheme trap, as a test.**
    ///
    /// Python iterates a `str` scalar by scalar. Swift's `Character` is a
    /// grapheme cluster, so "e" followed by U+0303 is the *single* `Character`
    /// "ẽ" — which matches no vocabulary key, dropping **both** tokens where
    /// Python emits 47 then 17. Nothing crashes; the speech is quietly missing a
    /// nasal, and no test keyed on an isolated tilde would ever notice.
    ///
    /// The first version of this file had exactly that bug, and exactly that
    /// blind test.
    func testACombiningMarkIsTokenizedSeparatelyFromItsBaseVowel() {
        XCTAssertEqual(KokoroTokenizer.vocabulary["\u{0303}"], 17)

        // One Character, two scalars, two tokens.
        let nasal = "e\u{0303}"
        XCTAssertEqual(nasal.count, 1, "precondition: Swift folds this into one Character")
        XCTAssertEqual(nasal.unicodeScalars.count, 2)
        XCTAssertEqual(
            KokoroTokenizer.ids(for: nasal), [47, 17],
            "a combining mark was folded into its base vowel and both tokens were lost"
        )
    }

    /// The table has to be keyed on scalars for the above to be possible at all.
    func testTheVocabularyIsKeyedOnScalarsRatherThanGraphemes() {
        XCTAssertEqual(KokoroTokenizer.vocabulary.count, 114, "the table lost or gained an entry")
    }

    /// Script g, not ASCII g. `ɡ` is U+0261; ASCII `g` (U+0067) is absent from
    /// the table entirely and would be silently dropped — and the two are
    /// indistinguishable in most editors.
    func testTheScriptGIsNotTheASCIIG() {
        XCTAssertEqual(KokoroTokenizer.vocabulary["\u{0261}"], 92)
        XCTAssertNil(KokoroTokenizer.vocabulary["g"], "ASCII g crept into the table")
        XCTAssertEqual(KokoroTokenizer.ids(for: "g"), [], "ASCII g was tokenized")
    }

    /// The length mark is U+02D0 TRIANGULAR COLON, not an ASCII colon — which
    /// *is* in the table, as a different id.
    func testTheLengthMarkIsNotAColon() {
        XCTAssertEqual(KokoroTokenizer.vocabulary["\u{02D0}"], 158)
        XCTAssertEqual(KokoroTokenizer.vocabulary[":"], 2)
    }

    /// Ids the table does not contain are absent on purpose. This guards the
    /// specific temptation to "fix" the gaps by renumbering.
    func testTheGapsInTheTableAreLeftAlone() {
        let assigned = Set(KokoroTokenizer.vocabulary.values)
        for missing: Int64 in [7, 8, 26, 28, 30, 32, 34, 37, 38, 40, 49] {
            XCTAssertFalse(assigned.contains(missing), "id \(missing) was invented")
        }
    }

    /// Every id must be unique — two characters sharing one id is a table that
    /// was mis-transcribed, and it would be nearly impossible to hear which.
    func testNoTwoCharactersShareAnId() {
        let ids = KokoroTokenizer.vocabulary.values
        XCTAssertEqual(Set(ids).count, ids.count, "the vocabulary has a duplicate id")
    }

    /// Nothing may collide with the padding token.
    func testNothingMapsToThePaddingToken() {
        XCTAssertFalse(KokoroTokenizer.vocabulary.values.contains(KokoroTokenizer.padding))
    }

    // MARK: Unknown input

    /// Dropped, not substituted. Mapping an unknown character to a nearby sound
    /// would put a phoneme into the owner's speech that nothing in their text
    /// asked for.
    func testCharactersOutsideTheVocabularyAreDroppedRatherThanSubstituted() {
        XCTAssertEqual(KokoroTokenizer.ids(for: "a\u{1F600}b"), [43, 44])
        XCTAssertEqual(KokoroTokenizer.ids(for: "日本語"), [])
    }

    /// An empty phoneme string still produces a valid, if pointless, sequence
    /// rather than an empty tensor the graph would reject.
    func testAnEmptyStringStillProducesThePadding() {
        XCTAssertEqual(KokoroTokenizer.tokens(for: ""), [0, 0])
    }

    // MARK: Length

    /// **509, not 510.** Each voice is `(510, 1, 256)` indexed by token count, so
    /// rows 0…509 are valid — but upstream truncates the phoneme string at 510
    /// and then indexes with the result, so a 510-token sequence asks for
    /// `voice[510]` and raises `IndexError`. Verified against the running
    /// package. This port takes the bound that actually works.
    func testTheUsableLimitStopsShortOfTheUpstreamOffByOne() {
        XCTAssertEqual(KokoroTokenizer.maximumTokens, 509)
        XCTAssertTrue(KokoroTokenizer.fits(String(repeating: "a", count: 509)))
        XCTAssertFalse(
            KokoroTokenizer.fits(String(repeating: "a", count: 510)),
            "510 tokens would index a style row that does not exist"
        )
    }

    /// The string is truncated before tokenizing, matching upstream's order.
    func testAnOverlongStringIsTruncatedRatherThanRejected() {
        let ids = KokoroTokenizer.ids(for: String(repeating: "a", count: 600))
        XCTAssertEqual(ids.count, 510, "truncation happens on the scalars, at 510")
    }

    /// Scalars that are dropped do not consume the budget, because the
    /// truncation is on the input string and the drop happens after.
    func testDroppedScalarsDoNotCountTowardTheTokenCount() {
        let text = String(repeating: "日", count: 100) + String(repeating: "a", count: 400)
        XCTAssertEqual(KokoroTokenizer.ids(for: text).count, 400)
        XCTAssertTrue(KokoroTokenizer.fits(text))
    }
}
