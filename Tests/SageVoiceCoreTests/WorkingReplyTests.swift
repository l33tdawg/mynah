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

    // MARK: Instant

    /// The reported failure: "Having a look." arrived most of a minute after the
    /// question, because `line(forTools:)` waits on a tool decision and deciding
    /// costs a whole model call. Late enough to be worse than nothing — by then
    /// the owner has already concluded it is broken.
    func testTheBacklogQuestionFromTheThreadGetsAnInstantLine() {
        let line = WorkingReply.instantLine(
            forRequest: "any other items on our task list / backlog ?",
            chooser: { _ in 0 }
        )
        XCTAssertEqual(line, "Let me check your backlog.")
    }

    /// What separates this from the acknowledgement the owner already rejected
    /// ("they sound very fake and don't make sense"): it is derived from their
    /// own sentence, not predicted from the model. If they said backlog, saying
    /// backlog back is true before anything has run.
    func testTheLineComesFromTheOwnersOwnWords() {
        XCTAssertEqual(
            WorkingReply.instantOptions(forRequest: "what did we talk about in Tokyo last week")?.first,
            "Let me go back through that."
        )
        XCTAssertEqual(
            WorkingReply.instantOptions(forRequest: "whats the latest news on eurorack")?.first,
            "Looking into that now."
        )
    }

    /// The first turn in the reported thread — "add a note to your sage task
    /// list that we need to check on the a100 benchmarks before Friday" — got no
    /// acknowledgement and read correctly. A write answers before an
    /// acknowledgement would land, and this thread is Note to Self, where two
    /// bubbles where one would do is noise.
    func testFastWritesStillSayNothing() {
        XCTAssertNil(
            WorkingReply.instantLine(
                forRequest: "add a note to your sage task list that we need to check on the a100 benchmarks before Friday"
            )
        )
        XCTAssertNil(WorkingReply.instantLine(forRequest: "remind me to pay the signal number"))
    }

    func testSmallTalkStillSaysNothing() {
        for chatter in ["thanks bro thats all", "never mind", "good night", "hey"] {
            XCTAssertNil(
                WorkingReply.instantLine(forRequest: chatter),
                "\"\(chatter)\" got an acknowledgement it did not need"
            )
        }
    }

    /// Nothing said instantly may name a tool or a source, because at this point
    /// nothing has chosen one. "Let me check your backlog" is safe — they said
    /// backlog. "Searching online" would not be.
    func testNoInstantLinePromisesSomethingUnknowable() {
        let requests = [
            "any other items on our task list / backlog ?",
            "what did we talk about in Tokyo",
            "make me a list of the shops",
            "whats the latest news",
            "what time is the festival?"
        ]
        for request in requests {
            for line in WorkingReply.instantOptions(forRequest: request) ?? [] {
                for promise in ["online", "searching", "web", "memory", "sage"] {
                    XCTAssertFalse(
                        line.localizedCaseInsensitiveContains(promise),
                        "\"\(line)\" promises \(promise) before anything has decided to do it"
                    )
                }
            }
        }
    }

    func testTheInstantLineVariesToo() {
        let options = WorkingReply.instantOptions(forRequest: "any other items on our backlog?") ?? []
        XCTAssertGreaterThan(options.count, 1)
        for index in 0..<options.count {
            XCTAssertNotEqual(
                WorkingReply.instantLine(
                    forRequest: "any other items on our backlog?",
                    previous: options[0],
                    chooser: { _ in index }
                ),
                options[0]
            )
        }
    }

    /// The reported gap: "the ramen shops near klcc" matched no keyword, so the
    /// owner waited about 30 seconds for the tool-decision line — exactly the
    /// failure the instant line exists to remove. An allowlist is the wrong
    /// shape for "say something unless it would be wrong": the wrong cases are
    /// few and nameable, the right ones are unbounded.
    func testAnOrdinaryRequestWithNoKeywordsStillGetsAnInstantLine() {
        for request in [
            "the ramen shops near klcc",
            "hugo boss stores in bukit bintang",
            "a good place for coffee tomorrow morning"
        ] {
            XCTAssertNotNil(
                WorkingReply.instantLine(forRequest: request),
                "\"\(request)\" waits on a model call before anything is said"
            )
        }
    }

    /// The generic fallback is only safe while it claims nothing. The moment it
    /// names a tool or a source it becomes a guess about behaviour that has not
    /// been decided.
    func testTheFallbackClaimsNothing() {
        for line in WorkingReply.instantOptions(forRequest: "the ramen shops near klcc") ?? [] {
            for promise in ["online", "search", "web", "memory", "sage", "note", "backlog"] {
                XCTAssertFalse(
                    line.localizedCaseInsensitiveContains(promise),
                    "the catch-all line \"\(line)\" promises \(promise)"
                )
            }
        }
    }

    // MARK: Not saying it twice

    /// Both pairs observed in the thread. Individually true, together a stutter.
    func testTheStutterFromTheThreadIsCaught() {
        XCTAssertTrue(WorkingReply.saysTheSameThing(
            "Looking online for the rest of it.",
            as: "Looking that up online — give me a few seconds."
        ))
        XCTAssertTrue(WorkingReply.saysTheSameThing(
            "Looking online for the rest of it.",
            as: "On it — having a look online."
        ))
    }

    /// Real news must still get through. Suppressing "found a few options in
    /// Tokyo" because the opener also said "look" would delete the only update
    /// worth sending.
    func testActualNewsIsNotSuppressed() {
        XCTAssertFalse(WorkingReply.saysTheSameThing(
            "Found a few options in Tokyo — let me compile that.",
            as: "Looking that up online — give me a few seconds."
        ))
        XCTAssertFalse(WorkingReply.saysTheSameThing(
            "Memory didn't have all of it — checking online now.",
            as: "Let me go back through that."
        ))
        XCTAssertFalse(WorkingReply.saysTheSameThing("Almost there.", as: "One moment."))
        XCTAssertFalse(WorkingReply.saysTheSameThing("anything", as: nil))
    }
}

// MARK: - Being cut off

/// What the appliance says when the caller talks over it.
///
/// *"if user starts speaking half way, we have the agent say something when
/// they end that acknowledges the new ask before actually doing it."*
///
/// On a call this is the moment that decides whether the thing feels like it is
/// listening. Cutting in stops the audio instantly — the endpoint drops what is
/// queued locally — so from the caller's side the appliance goes abruptly
/// silent, and the next words they hear are the only evidence of whether it
/// heard them or merely stopped.
final class InterruptedOpeningTests: XCTestCase {

    /// Deterministic: always the first option, so a wording change fails the
    /// test rather than the random pick doing it one run in three.
    private let first: (Int) -> Int = { _ in 0 }

    func testItLeadsWithTheTurnRatherThanTheTask() {
        let opening = WorkingReply.interruptedOpening(
            forRequest: "actually look up the flight times instead",
            chooser: first
        )

        XCTAssertTrue(opening?.line.hasPrefix("Right —") ?? false, opening?.line ?? "nil")
    }

    func testASpecificRequestKeepsItsOwnOpener() {
        // Both halves in one sentence: heard you, and here is what I am doing.
        let opening = WorkingReply.interruptedOpening(
            forRequest: "search online for the ferry timetable",
            chooser: first
        )

        let line = opening?.line ?? ""
        XCTAssertEqual(opening?.isSpecific, true)
        XCTAssertTrue(line.hasPrefix("Right — "), line)
        // Joined into one sentence rather than bolted together: the opener's
        // own capital would read as two sentences with a dash between them.
        let second = line.dropFirst("Right — ".count).first
        XCTAssertEqual(second?.isLowercase, true, line)
    }

    func testAVagueRequestSaysOnlyTheTruePart() {
        // Nothing specific to name. Inventing a subject here would be the
        // appliance guessing out loud on the one turn where the caller has just
        // demonstrated it was heading the wrong way.
        let opening = WorkingReply.interruptedOpening(forRequest: "no wait", chooser: first)

        XCTAssertEqual(opening?.line, "Right — let me get that instead.")
        XCTAssertEqual(opening?.isSpecific, false)
    }

    func testItNeverSoundsLikeAnUninterruptedTurn() {
        // The bug this exists to remove: being interrupted and being asked
        // produced the same sentence, which answers a question the caller did
        // not have and not the one they did.
        let plain = WorkingReply.opening(forRequest: "no wait", chooser: first)?.line
        let cutIn = WorkingReply.interruptedOpening(forRequest: "no wait", chooser: first)?.line

        XCTAssertNotEqual(plain, cutIn)
    }

    func testAlwaysSomethingToSay() {
        // `opening` may return nil — a fast write answers before an
        // acknowledgement would land. An interruption always gets a reply,
        // because silence after cutting in is indistinguishable from a dropped
        // call.
        for request in ["add a note about the roof", "", "hmm", "no no no"] {
            XCTAssertNotNil(
                WorkingReply.interruptedOpening(forRequest: request, chooser: first),
                "nothing said after \"\(request)\""
            )
        }
    }
}
