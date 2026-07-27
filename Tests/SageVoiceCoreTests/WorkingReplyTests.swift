import XCTest
@testable import SageVoiceCore

/// What the appliance says while the owner waits.
///
/// The governing constraint is in `WorkingReply`'s own doc comment and it is a
/// verdict, not a preference: an earlier version sent a fixed acknowledgement the
/// instant a message arrived, and the owner's response was "they sound very fake
/// and don't make sense". It was guessing — speaking before the model had chosen
/// anything. So every line here has to be *earned* by something that actually
/// happened, and these tests mostly exist to stop a future edit from making the
/// lines friendlier by making them less true.
final class WorkingReplyTests: XCTestCase {

    // MARK: Variety

    func testTheSameToolDoesNotProduceTheSameLineTwiceRunning() {
        let options = WorkingReply.lines(forTools: ["sage_recall"]) ?? []
        XCTAssertGreaterThan(options.count, 1, "one option is not variety")

        // Every option, asked for while it is the previous one, must move.
        for previous in options {
            for index in 0..<options.count {
                let line = WorkingReply.line(
                    forTools: ["sage_recall"],
                    previous: previous,
                    chooser: { _ in index }
                )
                XCTAssertNotNil(line)
                XCTAssertNotEqual(
                    line,
                    previous,
                    "repeated \"\(previous)\" back to back, which reads worse than never varying at all"
                )
            }
        }
    }

    /// The degenerate case: a tool with exactly one line. Saying it again beats
    /// going silent, because silence is the failure this feature exists for.
    func testASingleOptionIsStillSaidRatherThanSwallowed() {
        let single = WorkingReply.line(
            forTools: ["sage_gov_vote"],
            previous: WorkingReply.lines(forTools: ["sage_gov_vote"])?.last,
            chooser: { _ in 0 }
        )
        XCTAssertNotNil(single)
    }

    /// Fast tools stay quiet. A `sage_remember` finishes in milliseconds, so an
    /// announcement puts two messages in the thread where one would do — noise,
    /// in a Note to Self the owner also uses for real notes.
    func testFastToolsSayNothing() {
        XCTAssertNil(WorkingReply.line(forTools: ["sage_remember"]))
        XCTAssertNil(WorkingReply.line(forTools: []))
    }

    /// Every alternative has to be true of the tool it belongs to. A line about
    /// searching, offered for a memory lookup, is the original sin restated.
    func testNoLineClaimsToSearchTheWebUnlessItIs() {
        for tool in ["sage_recall", "sage_backlog", "sage_status", "write_note"] {
            for line in WorkingReply.lines(forTools: [tool]) ?? [] {
                XCTAssertFalse(
                    line.localizedCaseInsensitiveContains("online"),
                    "\"\(line)\" promises the internet for \(tool)"
                )
            }
        }
        let search = WorkingReply.lines(forTools: ["web_search"]) ?? []
        XCTAssertTrue(search.allSatisfy { line in
            ["online", "search", "look"].contains { line.localizedCaseInsensitiveContains($0) }
        })
    }

    // MARK: Progress

    func testNothingIsSaidBeforeAnythingHasFinished() {
        XCTAssertNil(
            WorkingReply.progressLine(completed: [], pending: "sage_recall"),
            "this repeats the first line with no new information — the definition of filler"
        )
    }

    /// The owner's own example: *"looking up those suppliers; found a few options
    /// in <city>, let me compile; almost there"*.
    func testTheOwnersThreeBeatShapeComesOut() {
        let results = """
        1. Clockface Modular — https://clockfacemodular.com/
        2. Five G Tokyo — https://five-g.com/
        3. Nishi-Shinjuku store — https://example.jp/
        """
        let request = "find me eurorack shops in Tokyo and make a list"

        let compiling = ToolLoopProgress(
            completed: ["web_search"],
            pending: "write_note",
            index: 0,
            lastResult: results,
            request: request
        ).line
        XCTAssertEqual(compiling, "Found a few options in Tokyo — let me compile that.")

        let almost = ToolLoopProgress(
            completed: ["web_search", "sage_recall", "read_note"],
            pending: nil,
            index: 2,
            lastResult: results,
            request: request
        ).line
        XCTAssertEqual(almost, "Almost there.")
    }

    /// The rule that keeps "in Tokyo" honest. A place the owner never said is a
    /// stranger's word in the appliance's mouth; a place the results never
    /// mention is a claim about what was found.
    func testAPlaceIsNamedOnlyWhenBothSidesSaidIt() {
        let results = "1. Clockface Modular, Tokyo — https://example.com/"

        XCTAssertEqual(
            WorkingReply.sharedSubject(request: "eurorack shops in Tokyo", result: results),
            "Tokyo"
        )
        XCTAssertNil(
            WorkingReply.sharedSubject(request: "eurorack shops in Bangkok", result: results),
            "named a city the results never mentioned"
        )
        XCTAssertNil(
            WorkingReply.sharedSubject(request: "find me some shops", result: results),
            "named a city the owner never asked about"
        )
    }

    /// ASR capitalises the first word of every transcript, so treating that as a
    /// proper noun would put "Looking" or "Find" into the sentence as a place.
    func testTheFirstWordOfATranscriptIsNotAProperNoun() {
        XCTAssertNil(
            WorkingReply.sharedSubject(
                request: "Tokyo shops please",
                result: "results about Tokyo shops"
            ),
            "the leading token was trusted, which makes any first word a place"
        )
    }

    func testJapaneseSubjectsSurviveHavingNoCase() {
        XCTAssertEqual(
            WorkingReply.sharedSubject(request: "eurorack shops in 大阪", result: "1. 大阪 store"),
            "大阪"
        )
    }

    /// Counts are shape heuristics over text, so they are spoken vaguely. "7
    /// options" claims a precision that counting numbered lines does not have.
    func testCountsAreSpokenVaguelyBecauseTheyAreEstimates() {
        let many = (1...9).map { "\($0). thing — https://e.com/\($0)" }.joined(separator: "\n")
        XCTAssertEqual(WorkingReply.resultCount(in: many), 9)

        let line = WorkingReply.progressLine(
            completed: ["web_search"],
            pending: "write_note",
            findings: .init(count: 9, subject: nil)
        )
        XCTAssertEqual(line, "Found quite a few options — let me compile that.")
        XCTAssertFalse(line?.contains("9") == true, "an estimate was reported as an exact count")
    }

    func testProseWithNoResultsCountsAsNothingFound() {
        XCTAssertNil(WorkingReply.resultCount(in: "I could not find anything about that."))
        XCTAssertNil(
            WorkingReply.progressLine(
                completed: ["web_search"],
                pending: "write_note",
                findings: .init(count: 0)
            ).flatMap { $0.contains("Found") ? $0 : nil },
            "claimed a find on an empty result"
        )
    }

    /// What is about to happen is the only part the owner can still redirect, so
    /// it outranks a summary of what already did.
    func testTheNextStepIsPreferredOverTheLastOne() {
        XCTAssertEqual(
            WorkingReply.progressLine(completed: ["sage_recall"], pending: "web_search"),
            "Memory didn't have all of it — checking online now."
        )
    }

    // MARK: Cadence

    /// A 300 s budget cannot be covered by one message, and it must not be
    /// covered by twelve. Three is roughly what a person says while working.
    func testTheCadenceCoversALongTurnWithoutFillingIt() {
        XCTAssertEqual(WorkingReply.maximumProgressMessages, 3)
        XCTAssertGreaterThanOrEqual(
            WorkingReply.progressAfterSeconds * Double(WorkingReply.maximumProgressMessages),
            120,
            "three updates at this spacing do not cover enough of a long turn to be worth sending"
        )
        XCTAssertLessThan(
            WorkingReply.progressAfterSeconds * Double(WorkingReply.maximumProgressMessages),
            ToolLoop.defaultDeadlineSeconds,
            "the updates outlast the turn they describe"
        )
    }

    /// Later updates must not restate the earlier ones. Saying "still looking"
    /// three times is the same as saying nothing three times, except louder.
    func testEachUpdateInATurnSaysSomethingDifferent() {
        let lines = (0..<WorkingReply.maximumProgressMessages).compactMap {
            WorkingReply.progressLine(completed: ["sage_recall"], pending: nil, index: $0)
        }
        XCTAssertEqual(lines.count, WorkingReply.maximumProgressMessages)
        XCTAssertEqual(Set(lines).count, lines.count, "an update repeated an earlier one verbatim")
    }
}
