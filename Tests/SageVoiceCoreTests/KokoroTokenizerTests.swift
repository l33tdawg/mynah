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

    /// The combining tilde is a single Unicode scalar that Swift would happily
    /// fold into the preceding character if this were keyed on anything but
    /// `Character` — worth asserting because the failure would be invisible.
    func testTheCombiningTildeIsItsOwnEntry() {
        XCTAssertEqual(KokoroTokenizer.vocabulary["\u{0303}"], 17)
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

    /// The positional embedding is 510 long and the style array has 510 rows.
    /// A sequence past that has nowhere to index, so the caller must split
    /// first — this is the predicate it splits on.
    func testTheLengthLimitIsMeasuredOnTheUnpaddedCount() {
        let long = String(repeating: "a", count: 510)
        XCTAssertTrue(KokoroTokenizer.fits(long))
        XCTAssertEqual(KokoroTokenizer.ids(for: long).count, 510)
        // Padding takes it to 512, which is expected and is not what `fits`
        // measures.
        XCTAssertEqual(KokoroTokenizer.tokens(for: long).count, 512)

        XCTAssertFalse(KokoroTokenizer.fits(String(repeating: "a", count: 511)))
    }

    /// Characters that are dropped do not count toward the limit, because they
    /// do not reach the model.
    func testDroppedCharactersDoNotCountTowardTheLimit() {
        let text = String(repeating: "a", count: 510) + String(repeating: "日", count: 100)
        XCTAssertTrue(KokoroTokenizer.fits(text))
    }
}
