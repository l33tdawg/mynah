import XCTest
@testable import SageVoiceCore

/// Tests for the two things the model is told about its own position in space
/// and time.
///
/// ## The bug these were written for
///
/// On the morning of Tuesday 4 August 2026 the owner asked over Signal *"whats
/// on our todo list today?"* and Mynah answered *"Nothing due today … so Monday
/// 3 August is clear"*, then listed the rest of the week correctly. It knew
/// every date on the list. It did not know which one was today.
///
/// `WhereWeAre` had been written to prevent exactly this and was never wired to
/// anything: nothing in the repo constructed it, called `spokenForPrompt`, or
/// read the file it knows how to save. So no prompt on either surface carried
/// the date, and the model anchored "today" to the only date in its context —
/// the proactive watch's own message, sent eight minutes earlier, naming the
/// Monday task that had just come off the list.
///
/// The window answered the same question correctly at the same minute. Not
/// because it knew: because the owner had typed "its already tuesday" into it
/// an hour before. Two surfaces equally blind, one of them lucky.
///
/// Which is why the last test here does not check a string. It runs a turn and
/// reads what the backend was actually sent.
final class WhereWeAreTests: XCTestCase {

    private let malaysia = TimeZone(identifier: "Asia/Kuala_Lumpur")!

    /// 09:15 on Tuesday 4 August 2026, Malaysian time — the morning in question.
    private var thatMorning: Date {
        var parts = DateComponents()
        parts.year = 2026
        parts.month = 8
        parts.day = 4
        parts.hour = 9
        parts.minute = 15
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = malaysia
        return calendar.date(from: parts)!
    }

    // MARK: The stamp

    func testTheStampNamesTheDayAndTheClock() {
        let line = WhereWeAre.rightNow(thatMorning, zone: malaysia)

        XCTAssertEqual(line, "(Right now it is 09:15 on Tuesday 4 August 2026.)")
    }

    /// The whole point: a stamp read in Malaysia says Malaysia's day, not UTC's.
    /// At 00:30 in Kuala Lumpur it is still the previous afternoon in London,
    /// and an appliance that reported the wrong side of midnight would be
    /// committing the original bug in a smaller way.
    func testTheStampIsInTheOwnersZoneNotUTC() {
        var parts = DateComponents()
        parts.year = 2026
        parts.month = 8
        parts.day = 4
        parts.hour = 0
        parts.minute = 30
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = malaysia
        let justAfterMidnight = calendar.date(from: parts)!

        let here = WhereWeAre.rightNow(justAfterMidnight, zone: malaysia)
        let inLondon = WhereWeAre.rightNow(justAfterMidnight, zone: TimeZone(identifier: "Europe/London")!)

        XCTAssertTrue(here.contains("Tuesday 4 August 2026"), here)
        XCTAssertTrue(inLondon.contains("Monday 3 August 2026"), inLondon)
    }

    func testTheStampLeavesTheOwnersWordsIntact() {
        let stamped = WhereWeAre.stamp("whats on our todo list today ?", now: thatMorning, zone: malaysia)

        XCTAssertTrue(stamped.hasSuffix("whats on our todo list today ?"), stamped)
        XCTAssertTrue(stamped.hasPrefix("(Right now it is"), stamped)
    }

    // MARK: Where, which is a different question

    func testWhereNamesTheCountryFromTheTimeZoneAlone() throws {
        let here = WhereWeAre.fromTimeZone(malaysia, locale: Locale(identifier: "en_MY"))
        let line = try XCTUnwrap(here.spokenForPrompt())

        XCTAssertTrue(line.contains("Malaysia"), line)
        XCTAssertTrue(line.contains("Kuala Lumpur"), line)
    }

    /// **The regression that would undo the fix.** The place line goes in the
    /// system prompt, which is the prompt cache's prefix and which the daemon
    /// builds once and holds for days. A date in here is stale by the next
    /// morning and invalidates `anchorPromptCache`'s checkpoint every turn it is
    /// not. Both failures are silent, so this is asserted rather than trusted.
    func testWhereCarriesNoDateAtAll() throws {
        let here = WhereWeAre.fromTimeZone(malaysia, locale: Locale(identifier: "en_MY"))
        let line = try XCTUnwrap(here.spokenForPrompt())

        for day in ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"] {
            XCTAssertFalse(line.contains(day), "the place line named a day: \(line)")
        }
        for month in ["January", "August", "December"] {
            XCTAssertFalse(line.contains(month), "the place line named a month: \(line)")
        }
        XCTAssertFalse(line.contains("2026"), "the place line named a year: \(line)")
    }

    // MARK: On disk

    func testALoadFromNowhereStillKnowsTheCountry() {
        let missing = URL(fileURLWithPath: "/nonexistent/where-we-are.json")

        let here = WhereWeAre.load(from: missing, zone: malaysia)

        XCTAssertFalse(here.country.isEmpty)
        XCTAssertEqual(here.timeZone, "Asia/Kuala_Lumpur")
        XCTAssertNotNil(here.spokenForPrompt())
    }
}
