import XCTest
@testable import SageVoiceCore

final class HeardSpeechTests: XCTestCase {

    /// The one that actually happened.
    ///
    /// Nobody spoke. Whisper returned ありがとうございました, the model replied
    /// どういたしまして, and an English voice spent ten seconds on it.
    func testWhispersJapaneseHallucinationIsNotSpeech() {
        XCTAssertTrue(HeardSpeech.isNothing("ありがとうございました", milliseconds: 600))
        XCTAssertTrue(HeardSpeech.isNothing("ご視聴ありがとうございました", milliseconds: 900))
    }

    func testTheOtherStockPhrasesAreNotSpeech() {
        for phrase in ["Thank you.", "Thanks for watching!", "you", "Bye.",
                       "[BLANK_AUDIO]", "(silence)", "Subtitles by the Amara.org community"] {
            XCTAssertTrue(
                HeardSpeech.isNothing(phrase, milliseconds: 700),
                "\(phrase) should be treated as silence"
            )
        }
    }

    func testPunctuationOnlyIsNotSpeech() {
        for noise in ["", "   ", ".", "。", "...", "♪", "♪♪♪"] {
            XCTAssertTrue(HeardSpeech.isNothing(noise, milliseconds: 500), "\(noise)")
        }
    }

    /// The filter must not eat real speech, which is the whole risk of having it.
    func testRealSpeechSurvives() {
        for said in [
            "Can you check your SAGE backlog?",
            "What about the Eurorack shopping list?",
            "Hey bro, are you there?",
            "yes",
            "no",
            "It's not one module, it's a EuroRack module."
        ] {
            XCTAssertFalse(
                HeardSpeech.isNothing(said, milliseconds: 1800),
                "\(said) was discarded as noise"
            )
        }
    }

    /// A caller who genuinely says "thank you" must be heard.
    ///
    /// The length guard is what makes filtering a common courtesy safe: over
    /// four seconds of audio it is taken at face value, and only the
    /// suspiciously brief version is treated as the artefact.
    func testAGenuineThankYouOverEnoughAudioIsSpeech() {
        XCTAssertTrue(HeardSpeech.isNothing("Thank you.", milliseconds: 600))
        XCTAssertFalse(HeardSpeech.isNothing("Thank you.", milliseconds: 5000))
    }
}
