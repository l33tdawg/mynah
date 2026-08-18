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

/// A pleasantry must never take away the answer somebody is waiting for.
///
/// ## The report
///
/// A tester on 1.6.3, on a call, with a transcript showing nine `You: Thank
/// you.` in a row: *"When he doesn't get to the answer, it's because his
/// thinking cycle is interrupted by him thinking I said 'Thank You'. So it stops
/// thinking and says 'You're welcome. What would you like to do next'."* And
/// then, flatly: *"I never even thanked it once."*
///
/// Whisper invents that phrase over silence — the machinery for it was already
/// here — but the filter was gated on an amplitude threshold set to 60 when real
/// speech measures in the thousands, so it had never once fired.
///
/// ## Why this rule does not use the threshold
///
/// Two separate questions were being answered by one number. *Should this be
/// answered?* genuinely depends on whether anybody spoke, and that is a
/// measurement. *Should this cancel work already running?* does not depend on it
/// at all: a real "thank you" over the top of an answer is a pleasantry from
/// someone who still wants the answer, and an invented one is nothing. Cancelling
/// is the single response that cannot be correct either way.
final class CourtesyNeverCancelsTests: XCTestCase {

    func testTheStockCourtesiesAreRecognised() {
        for phrase in ["Thank you.", "thanks", "THANK YOU VERY MUCH", "Okay", "mm", "Bye."] {
            XCTAssertTrue(HeardSpeech.isCourtesy(phrase), phrase)
        }
    }

    /// "MM" is in the list because the same tester heard it constantly — *"He
    /// also often repeats the word MM"* — and it is filler either way.
    func testTheFillerNoiseTheTesterKeptHearingCounts() {
        XCTAssertTrue(HeardSpeech.isCourtesy("MM"))
        XCTAssertTrue(HeardSpeech.isCourtesy("mhm"))
    }

    /// A real request must never be mistaken for a courtesy — that failure mode
    /// is the appliance ignoring its owner, which is the worse one.
    func testARealRequestIsNotACourtesy() {
        for phrase in [
            "what's on my list today",
            "thank you, now book the hotel",
            "say hello to the desktop agent",
            "okay so what did Najwa say"
        ] {
            XCTAssertFalse(HeardSpeech.isCourtesy(phrase), phrase)
        }
    }

    /// Nothing at all counts, so an empty transcript cannot cancel a turn either.
    func testSilenceCountsAsACourtesyForThisPurpose() {
        XCTAssertTrue(HeardSpeech.isCourtesy(""))
        XCTAssertTrue(HeardSpeech.isCourtesy("   "))
    }

    // MARK: The threshold that never fired

    /// **The measurement that closes this out.** Six segments from a real call,
    /// every one of them accepted as speech, logged for exactly this purpose.
    /// The lowest confident utterance was 1879; the ceiling was 60.
    func testTheCeilingSitsBelowRealSpeechAndAboveTheArtefact() {
        let measuredSpeech: [Double] = [3944, 2884, 3805, 3020, 1879]
        let suspectedArtefact: Double = 139

        for level in measuredSpeech {
            XCTAssertGreaterThan(
                level, CallAudioEnergy.silenceCeiling,
                "a real utterance at \(level) would now be discarded as silence"
            )
        }
        XCTAssertLessThan(
            suspectedArtefact, CallAudioEnergy.silenceCeiling,
            "the 401ms blip at 139 still reads as speech, so the courtesy filter stays shut"
        )
    }

    /// The old value could not fire against any audio ever recorded here, which
    /// is why a filter that was written, tested and shipped did nothing for
    /// months.
    func testTheOldCeilingWouldHaveCalledTheQuietestArtefactSpeech() {
        // The measurement, named rather than inlined. `XCTAssertGreaterThan(139,
        // 60)` was two literals compared with each other: true by arithmetic,
        // unfalsifiable by any source edit, and it read as though it were
        // checking something.
        let quietestArtefactMeasured = 139.0
        let oldCeiling = 60.0

        // What the old ceiling did to that measurement: nothing. A blip at 139
        // scored as speech, so the hallucination filter that depends on knowing
        // the room was quiet never fired — written, tested and shipped, doing
        // nothing for months.
        XCTAssertGreaterThan(quietestArtefactMeasured, oldCeiling)
        // And what the new one does, which is the assertion that can actually
        // fail: lower `silenceCeiling` back under the artefact and this goes red.
        XCTAssertGreaterThan(
            CallAudioEnergy.silenceCeiling, quietestArtefactMeasured,
            """
            the ceiling is back below the quietest artefact ever measured here \
            (\(quietestArtefactMeasured)), so a blip of room noise scores as \
            speech again and the courtesy filter goes back to doing nothing
            """
        )
    }
}
#endif  // os(macOS)
