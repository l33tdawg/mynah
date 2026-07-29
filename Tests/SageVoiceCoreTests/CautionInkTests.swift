import SwiftUI
import XCTest
@testable import MynahMac

/// What amber is allowed to mean.
///
/// The owner reported his appliance had crashed because he saw amber on the
/// task area. It had not — both processes were up, both LaunchAgents intact.
/// He was reading the colour correctly: everywhere else in this product amber
/// means *Mynah is not doing what you think*, so amber on a stale list read as
/// amber on the appliance.
///
/// The rule that came out of it is about **subject**, not severity. A property
/// of the product gets caution; a property of a view does not.
@MainActor
final class CautionInkTests: XCTestCase {

    /// The tone that view-level facts are supposed to use has to stay distinct
    /// from the one that means something is wrong. If these ever resolve to the
    /// same colour the rule becomes unenforceable by inspection, and the next
    /// person will reach for `.caution` because it looks the same anyway.
    func testTheQuietToneIsNotTheAlarmingOne() {
        XCTAssertNotEqual(
            MynahTone.neutral.ink.description,
            MynahTone.caution.ink.description,
            "a view-level fact and a product fault would be drawn identically"
        )
    }

    /// `.neutral` resolves to secondary ink rather than inventing a fifth
    /// colour. There was never a missing token here — only uses on the wrong
    /// side of the line.
    func testTheQuietToneIsOrdinaryText() {
        XCTAssertEqual(MynahTone.neutral.ink.description, Palette.ink.secondary.description)
    }

    /// The two that were reclassified, pinned by source so they cannot drift
    /// back. Both are statements about a list, not about the appliance.
    ///
    /// Asserted on the file rather than the value because neither is reachable
    /// without a live board: one needs a stale exchange behind it and the other
    /// a pending deletion. A source check is the weaker tool and it is the one
    /// that fits — and it fails loudly, having been written after a source
    /// assertion silently stopped matching earlier today.
    func testTheStaleListNoteIsNotDrawnAsAFault() throws {
        let source = try read("Sources/MynahMac/Main/TaskBoardView.swift")
        let note = try XCTUnwrap(
            source.range(of: "Showing what it last saw"),
            "the stale-list note was renamed; this check is now watching nothing"
        )
        let following = source[note.upperBound...].prefix(900)
        XCTAssertFalse(
            following.contains("Palette.state.caution"),
            "a stale list is being drawn as though the appliance were unwell"
        )
    }

    func testAPendingDeletionIsNotDrawnAsAFault() throws {
        let source = try read("Sources/MynahMac/Main/MemoriesView.swift")
        let note = try XCTUnwrap(
            source.range(of: "has been asked to forget this"),
            "the pending-deletion note was renamed; this check is now watching nothing"
        )
        let following = source[note.upperBound...].prefix(600)
        XCTAssertFalse(
            following.contains("Palette.state.caution"),
            "work going exactly to plan is being drawn as a problem"
        )
    }

    /// The rule has to be written where somebody choosing a colour will meet
    /// it, which is the palette rather than a test file or a commit message.
    func testThePaletteCarriesTheRule() throws {
        let source = try read("Sources/MynahMac/Style/MynahTheme.swift")

        XCTAssertTrue(
            source.contains("A property of a view"),
            "the palette no longer explains when caution is the wrong ink"
        )
    }

    private func read(_ path: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(path),
            encoding: .utf8
        )
    }
}
