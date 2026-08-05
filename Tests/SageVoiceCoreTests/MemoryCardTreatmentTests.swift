import XCTest
@testable import MynahMac

/// How a task is told apart from a memory on the Memories page.
///
/// ## What was wrong
///
/// A task card was drawn on `Palette.surface.sunken` and a memory on
/// `Palette.surface.raised`. The two were separable down a scrolling list
/// without reading either, which was the intent — and the separation said the
/// wrong thing. The owner, looking at his own screen: *"a bit unclear which is
/// which - the grey cards for tasks look like they're just deactivated or
/// something"*.
///
/// He is right, and it is the ordinary meaning of the treatment: a recessed grey
/// panel is what every other interface on this Mac uses for something switched
/// off. A task is the *most* live thing on the page — the only kind with a date
/// that can pass — so disabled is the one thing it must not read as.
///
/// ## Why this is a source scan
///
/// `ComposerRenderHarness` exists because a picture settles an argument about
/// layout, and it says plainly what it cannot draw: `ImageRenderer` refuses
/// anything AppKit-backed. `MemoryEntry` is a `Button` carrying
/// `.pointingHandCursor()`, which is an `NSViewRepresentable`, so it is in that
/// set. Rendering it would mean rebuilding the card in the test — a copy that
/// drifts from the real one, which is the failure mode half this suite exists to
/// catch.
///
/// So this asserts the one thing that is checkable and load-bearing: the
/// treatment is not the disabled one, and tasks are still marked.
final class MemoryCardTreatmentTests: XCTestCase {

    private func memoriesSource() throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/MynahMac/Main/MemoriesView.swift"),
            encoding: .utf8
        )
    }

    /// The regression, stated as the owner saw it.
    func testATaskCardIsNotDrawnOnTheRecessedSurface() throws {
        let source = try memoriesSource()
        let scan = SwiftSourceScan(source)
        let code = scan.text(in: 0..<scan.characters.count)

        // Narrow to the card's own background on purpose. `surface.sunken` is
        // still correct elsewhere on this page — the search field is a text
        // well, and content sits *in* those. Asserting the token is absent from
        // the whole file would fail on a use that was never the complaint.
        // **Any spelling of the recessed treatment, not the one that was there.**
        //
        // This asserted the absence of the exact literal
        // `memory.kind == .task ? Palette.surface.sunken`, so the same visual
        // could come back written any other way — a reversed ternary, an `if`,
        // a computed property — with the guard green. The audit was right that
        // this guarded a spelling. What must stay true is that nothing on this
        // card chooses `sunken` on the strength of being a task.
        let recessedOnTaskness = code
            .components(separatedBy: "Palette.surface.sunken")
            .dropLast()
            .contains { before in
                // The 200 characters before any use of the recessed token: if a
                // task test is in there, that use is conditioned on taskness.
                String(before.suffix(200)).contains(".task")
            }
        XCTAssertFalse(
            recessedOnTaskness,
            """
            a task card is recessed again. On every other Mac interface that is \
            what "switched off" looks like, and the owner read it exactly that \
            way: "the grey cards for tasks look like they're just deactivated or \
            something".
            """
        )
        XCTAssertTrue(
            code.contains(".background(Palette.surface.raised, in: RoundedRectangle.mynah(r.card))"),
            "this test is reading the wrong file — the card no longer has its raised surface"
        )
    }

    /// And that a task is still distinguishable at a glance, which is what the
    /// recessed surface was there for.
    ///
    /// Without this the whole thing could be "fixed" by making both cards
    /// identical, which resolves the complaint about grey by deleting the
    /// distinction the owner also asked to be clearer.
    func testATaskIsStillMarked() throws {
        let source = try memoriesSource()
        let scan = SwiftSourceScan(source)
        let code = scan.text(in: 0..<scan.characters.count)

        XCTAssertTrue(
            code.contains("memory.kind == .task"),
            "nothing on the card depends on whether it is a task any more"
        )
        XCTAssertTrue(
            code.contains("KindChip(kind: .task)"),
            "the Task chip is gone, so a task and a memory read identically"
        )
    }
}
