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

/// **That a list the model wrote arrives as a list.**
///
/// A reply came back as four `- ` lines wrapped in two sentences and every line
/// of it went into one `Text`, so the hyphens stayed hyphens and the items ran
/// at the same rhythm as the prose around them: *"can we adjust the response
/// text spacing so its easier to read and list items appear with bullets etc?"*
final class AnswerLayoutTests: XCTestCase {

    func testAHyphenListBecomesBullets() {
        let blocks = AnswerBlock.parse("""
            Four open tasks, bro:
            - Book hotel for Wednesday the 19th
            - Apply for the TDAC before travelling
            All still planned, none started.
            """)

        XCTAssertEqual(blocks, [
            .paragraph("Four open tasks, bro:"),
            .bullet("Book hotel for Wednesday the 19th"),
            .bullet("Apply for the TDAC before travelling"),
            .paragraph("All still planned, none started.")
        ])
    }

    /// Every marker a model actually reaches for, including the dashes it uses
    /// when it is being typographic.
    func testTheOtherMarkersCountToo() {
        for marker in ["-", "*", "•", "–", "—"] {
            XCTAssertEqual(
                AnswerBlock.parse("\(marker) send the car in"),
                [.bullet("send the car in")],
                "\(marker) was left as prose"
            )
        }
    }

    /// The model's own numbering is kept. Renumbering somebody else's list is
    /// how a reply that says "go back to step 3" stops matching what is above it.
    func testANumberedListKeepsItsNumbers() {
        XCTAssertEqual(
            AnswerBlock.parse("1. first\n2) second"),
            [.numbered(marker: "1.", text: "first"), .numbered(marker: "2)", text: "second")]
        )
    }

    /// **The false positives.** A year, a price and a decimal all start with
    /// digits, and none of them is a list.
    func testProseThatStartsWithADigitIsNotAList() {
        for line in ["1998 was the year", "20% off until Friday", "3.4 GB downloaded", "1.2.3"] {
            XCTAssertEqual(
                AnswerBlock.parse(line), [.paragraph(line)],
                "\"\(line)\" was turned into a list item"
            )
        }
    }

    /// A hyphen inside a sentence is punctuation, not a bullet — the marker has
    /// to be at the start of the line and followed by a space.
    func testAHyphenMidSentenceIsLeftAlone() {
        let line = "Book it — the 19th works, low-cost if possible"
        XCTAssertEqual(AnswerBlock.parse(line), [.paragraph(line)])
    }

    /// Blank lines carry no content and become spacing rather than empty rows.
    func testBlankLinesDoNotBecomeEmptyBlocks() {
        XCTAssertEqual(
            AnswerBlock.parse("first\n\n\nsecond"),
            [.paragraph("first"), .paragraph("second")]
        )
    }

    /// Nothing in, nothing out — a reply that is only whitespace must not draw
    /// a bubble full of empty rows.
    func testAnEmptyAnswerHasNoBlocks() {
        XCTAssertTrue(AnswerBlock.parse("").isEmpty)
        XCTAssertTrue(AnswerBlock.parse("   \n  \n").isEmpty)
    }

    /// The distinction the spacing is built on.
    func testOnlyListItemsCountAsListItems() {
        XCTAssertTrue(AnswerBlock.bullet("x").isListItem)
        XCTAssertTrue(AnswerBlock.numbered(marker: "1.", text: "x").isListItem)
        XCTAssertFalse(AnswerBlock.paragraph("x").isListItem)
    }
}
#endif  // os(macOS)
