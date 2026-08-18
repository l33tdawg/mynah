// **Mac-only, because the live voice call is a Mac feature.**
//
// `Sources/SageVoiceCore/Call` is excluded from the target off Darwin — see
// `coreExclusions` in Package.swift — so none of the types below exist there.
// The exclusion and this guard are two halves of one decision, and the tests
// have to carry their half explicitly: a test file that cannot compile does not
// fail loudly, it takes the whole target down with it and every other test in
// the suite stops running too. That is what happened here.
#if os(macOS)
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
        for phrase in ["Thanks for watching!", "[BLANK_AUDIO]",
                       "Subtitles by the Amara.org community"] {
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

    /// Saying thanks must reach it.
    ///
    /// This filter used to swallow "thank you" as an artefact, and the call went
    /// silent when the owner thanked it. Whisper does invent that phrase over
    /// silence — but it is also among the most ordinary things anyone says to an
    /// assistant, and no length check separates the two.
    ///
    /// The costs are not symmetric, which is what decides it. Filtering real
    /// speech means ignoring the owner, who cannot tell why. Not filtering a
    /// hallucination means answering a quiet room, which is merely odd.
    func testSayingThanksIsHeard() {
        for thanks in ["Thanks.", "Thank you.", "thanks bro", "Thanks, that's great.",
                       "Cheers.", "yes", "no", "you"] {
            XCTAssertFalse(
                HeardSpeech.isNothing(thanks, milliseconds: 700),
                "\(thanks) was discarded; the owner would be ignored with no way to know why"
            )
        }
    }
}
#endif  // os(macOS)
