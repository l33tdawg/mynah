import XCTest
@testable import MynahMac

/// The handoff between a stage and its drawing.
///
/// `StageShell` takes one string for the thing in its mark column, and that
/// string is either an SF Symbol name or a request for one of the five
/// illustrations. Nothing in the type system separates those two, and the
/// failure mode is silent in both directions: a stage that asks for a drawing
/// and gets no match renders `Image(systemName:)` on a name that is not a
/// symbol, which is a blank column, and a symbol name that accidentally parsed
/// as a drawing would replace a glyph with the wrong picture. Neither throws,
/// neither logs, and neither is visible until someone walks the flow by hand.
@MainActor
final class StageIllustrationTests: XCTestCase {

    // MARK: Asking for a drawing

    /// The round trip is the whole contract.
    func testEveryDrawingCanBeAskedForByName() {
        for subject in StageIllustration.Subject.allCases {
            let mark = StageIllustration.mark(subject)
            XCTAssertEqual(
                StageIllustration.subject(named: mark),
                subject,
                "\(subject) asks for \(mark) and gets something else back"
            )
        }
    }

    /// Two stages sharing a name would mean one of them silently showing the
    /// other's drawing.
    func testNoTwoDrawingsShareAName() {
        let marks = StageIllustration.Subject.allCases.map(StageIllustration.mark)
        XCTAssertEqual(Set(marks).count, marks.count, "two stages ask for the mark")
    }

    // MARK: Staying out of the symbols' way

    /// Every symbol the stage layout is still asked for elsewhere in the app —
    /// the microphone screen, the "nothing to connect" detour, the unfinished
    /// ready screen. Any of these resolving to a drawing is a screen showing the
    /// wrong picture.
    func testSymbolNamesAreNotMistakenForDrawings() {
        for name in ["waveform", "checkmark", "laptopcomputer", "iphone.gen3", "mic", ""] {
            XCTAssertNil(
                StageIllustration.subject(named: name),
                "\(name) is an SF Symbol name and was read as a drawing"
            )
        }
    }

    /// SF Symbol names are dot-separated words, so a mark that contained no
    /// character a symbol name cannot hold would be one rename away from a
    /// collision.
    func testAMarkCouldNeverBeASymbolName() {
        for subject in StageIllustration.Subject.allCases {
            XCTAssertTrue(
                StageIllustration.mark(subject).contains(":"),
                "\(subject)'s mark is a plausible SF Symbol name"
            )
        }
    }

    /// A near-miss must fail rather than land on whichever drawing sorts first.
    func testAnUnknownDrawingIsNotGuessed() {
        XCTAssertNil(StageIllustration.subject(named: "stage:"))
        XCTAssertNil(StageIllustration.subject(named: "stage:microphone"))
        XCTAssertNil(StageIllustration.subject(named: "welcome"))
    }

    // MARK: One per stage

    /// The drawings are a story told across the setup flow, so a stage added to
    /// the flow without one leaves a hole in the middle of it — and the hole is
    /// a mark column that renders nothing.
    func testThereIsOneDrawingForEverySetupStage() {
        XCTAssertEqual(
            StageIllustration.Subject.allCases.count,
            SetupModel.Stage.allCases.count,
            "the setup flow and the illustrations have drifted apart"
        )
    }
}
