// **Mac-only, because it tests `MynahMac`.**
//
// `MynahMac` is the AppKit/SwiftUI half of this package, and Package.swift does
// not declare that target off Darwin — so the import below resolves on a Mac
// and nowhere else. The guard wraps the whole file rather than just the import,
// because every test in here drives a Mac type: a file that compiled down to an
// empty test class would let Linux report a green suite that ran nothing, which
// is the exact failure this branch exists to stop. See `coreTestDependencies`
// in Package.swift.
#if os(macOS)
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
    ///
    /// **This used to assert the two counts were equal, and they no longer are.**
    /// Linking a phone came off the onboarding gate — it is an optional add-on
    /// and it was the fourth of five screens — so the flow has four stages while
    /// the drawings still number five. The fifth is not orphaned: `phone` is
    /// what `SignalLinkStage` draws, and that screen still exists for anyone who
    /// chooses it from Ready or from Settings. Equality was a proxy for "every
    /// stage has a mark", and the proxy stopped being true before the thing it
    /// stood for did.
    func testEveryStageStillHasADrawingToStandIn() {
        XCTAssertGreaterThanOrEqual(
            StageIllustration.Subject.allCases.count,
            SetupModel.Stage.allCases.count,
            "there are fewer drawings than stages, so a stage renders an empty mark column"
        )
    }

    /// The one that outlived the gate. If this ever goes, `SignalLinkStage`
    /// renders `Image(systemName: "stage:phone")` — a blank column — and nobody
    /// notices until they open the sheet.
    func testThePhoneDrawingSurvivesComingOffTheGate() {
        XCTAssertNotNil(StageIllustration.subject(named: StageIllustration.mark(.phone)))
    }

    /// Every drawing is still reachable from something. A subject nobody asks
    /// for is dead weight that the next person has to work out the status of.
    func testNoDrawingIsOrphaned() {
        // `connect` is the `key` stage's mark — the names differ, which is
        // exactly why this cannot be derived from `Stage` and is written out.
        let claimed: Set<StageIllustration.Subject> = [.welcome, .brain, .connect, .ready, .phone]
        XCTAssertEqual(
            claimed,
            Set(StageIllustration.Subject.allCases),
            "a drawing exists that no screen asks for, or one is asked for and missing"
        )
    }
}
#endif  // os(macOS)
