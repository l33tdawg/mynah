import XCTest
@testable import SageVoiceCore

/// **That a list sent to a phone is readable on one.**
///
/// The window got real bullets and hanging indents from `AnswerLayout`. Signal
/// cannot: it is handed a string and draws it at one line height, so the same
/// reply arrived as a wall — *"list replies are still all bunched together"*.
/// The spacing has to be in the characters or it is nowhere.
final class SignalReplyTextTests: XCTestCase {

    func testAListGetsAirAroundAndInsideIt() {
        let out = SignalReplyText.spacingOutLists(in: """
            The todo list now has four items:
            - Apply for UOB Visa Infinite
            - Send car for servicing on Tuesday
            None have been started.
            """)

        XCTAssertEqual(out, """
            The todo list now has four items:

            - Apply for UOB Visa Infinite

            - Send car for servicing on Tuesday

            None have been started.
            """)
    }

    /// Prose is left exactly alone. Double-spacing an ordinary answer would make
    /// every reply worse to fix the one shape that needed it.
    func testProseWithNoListIsUntouched() {
        let prose = "Yeah bro, I'm right here. What's up?\nAsk me anything."
        XCTAssertEqual(SignalReplyText.spacingOutLists(in: prose), prose)
    }

    /// A model that already spaced its own list must not come out full of holes.
    func testAnAlreadySpacedListIsNotDoubleSpaced() {
        let out = SignalReplyText.spacingOutLists(in: "Items:\n\n- one\n\n- two")
        XCTAssertFalse(out.contains("\n\n\n"), "two blank lines in a row: \(out)")
    }

    func testNumberedListsCountToo() {
        XCTAssertTrue(SignalReplyText.isListItem("1. first"))
        XCTAssertTrue(SignalReplyText.isListItem("2) second"))
        XCTAssertTrue(SignalReplyText.isListItem("- bullet"))
    }

    /// The false positives, same set the window's parser refuses.
    func testProseStartingWithDigitsIsNotAList() {
        for line in ["1998 was the year", "20% off", "3.4 GB downloaded"] {
            XCTAssertFalse(SignalReplyText.isListItem(line), "\"\(line)\" read as a list item")
        }
    }

    func testNoTrailingBlankLineIsLeftBehind() {
        let out = SignalReplyText.spacingOutLists(in: "Items:\n- one\n")
        XCTAssertFalse(out.hasSuffix("\n"), "a trailing blank line rides along: \(out.debugDescription)")
    }
}

// MARK: - The bold marker

/// What makes `MYNAH >>` stand out from the owner's own words in a thread they
/// also use with people.
///
/// Pinned because it cannot be seen from here: the range is handed to
/// `signal-cli` and drawn on a phone, and an off-by-one — or a count of
/// characters where Signal wants UTF-16 code units — bolds the wrong text
/// silently rather than failing.
final class SignalReplyStyleTests: XCTestCase {

    func testBoldsExactlyTheMarkerAndNotTheAnswer() {
        XCTAssertEqual(
            SignalReplyText.styles(forPrefix: VoiceBridgeDaemon.Configuration.defaultReplyPrefix),
            ["0:8:BOLD"],
            "MYNAH >> is eight code units; the trailing space is not part of the marker"
        )
    }

    func testAMarkerWithAnEmojiIsCountedTheWaySignalCountsIt() {
        // 🐦 is one character and two UTF-16 code units. Counting characters
        // here would leave the last unit of the bird outside the bold range.
        XCTAssertEqual(SignalReplyText.styles(forPrefix: "🐦 "), ["0:2:BOLD"])
    }

    func testNoMarkerMeansNoFormattingAtAll() {
        XCTAssertEqual(SignalReplyText.styles(forPrefix: ""), [])
        XCTAssertEqual(
            SignalReplyText.styles(forPrefix: "   "), [],
            "a marker of spaces would bold a range of nothing, which signal-cli rejects"
        )
    }
}
