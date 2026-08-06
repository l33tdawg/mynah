import XCTest

/// **A task should look like a task wherever the owner meets it.**
///
/// Two screens draw the same objects. The Memories page marks a task with a
/// stripe down the leading edge; the Home sidebar drew a plain card. The owner,
/// with both open: *"can we make the tasks in the sidebar look a bit better like
/// the task cards here with the grey line at the side"*.
///
/// On Memories the stripe separates tasks from ordinary memories in one mixed
/// list. In the sidebar every card is a task, so it is not carrying that
/// distinction — it is carrying the fact that these are the same things, seen
/// twice. Nothing enforced the agreement, so the two had drifted apart for no
/// reason either screen could have explained.
///
/// A source scan rather than a rendering test, which is the honest limit: this
/// proves both surfaces draw the mark, not that they look identical on screen.
/// The alternative was nothing, and nothing is what let them diverge.
final class ATaskLooksLikeATaskEverywhereTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(path),
            encoding: .utf8
        )
    }

    /// Both surfaces mark a task with a leading stripe, and both use the same
    /// width and the same ink.
    func testBothSurfacesMarkATaskWithTheSameStripe() throws {
        let surfaces = [
            "Sources/MynahMac/Main/MemoriesView.swift",
            "Sources/MynahMac/Main/TaskBoardView.swift"
        ]

        for path in surfaces {
            let text = try source(path)
            XCTAssertTrue(
                text.contains(".overlay(alignment: .leading)"),
                "\(path) draws no leading stripe, so a task looks different here than on the "
                    + "other screen that shows the same objects"
            )
            XCTAssertTrue(
                text.contains("Palette.accent.fill"),
                "\(path) marks a task in something other than the accent ink"
            )
            XCTAssertTrue(
                text.contains(".frame(width: 3)"),
                "\(path) uses a different stripe width; the two screens must agree on the mark"
            )
        }
    }

    /// **The mark is ink, not a state.** `Palette.status` explains why there is
    /// no third colour to reach for: a coloured stripe would be read as a
    /// condition — overdue, failed, selected — and it means nothing of the kind.
    /// The nearness border is the thing that carries state on this card, and it
    /// is a stroke, in a state colour, on a different edge.
    func testTheStripeIsNotDrawnInAStateColour() throws {
        let card = try source("Sources/MynahMac/Main/TaskBoardView.swift")
        guard let overlay = card.range(of: ".overlay(alignment: .leading)") else {
            return XCTFail("no leading stripe to check")
        }
        let stripe = String(card[overlay.lowerBound...].prefix(400))

        for state in ["Palette.state.dueToday", "Palette.state.dueTomorrow", "Palette.state.good"] {
            XCTAssertFalse(
                stripe.contains(state),
                "the stripe is drawn in \(state), so it reads as a condition the task is in "
                    + "rather than as what the card is"
            )
        }
    }

    /// The stripe is clipped to the card, or it runs square past the rounded
    /// corners. `mynahCard` deliberately does not clip, so the caller must.
    func testTheStripeTakesTheCardsCorners() throws {
        let card = try source("Sources/MynahMac/Main/TaskBoardView.swift")
        guard let overlay = card.range(of: ".overlay(alignment: .leading)") else {
            return XCTFail("no leading stripe to check")
        }
        XCTAssertTrue(
            card[overlay.upperBound...].prefix(600).contains(".clipShape(RoundedRectangle.mynah(r.card))"),
            "the stripe is not clipped to the card shape, so it will overhang the rounded corners"
        )
    }
}
