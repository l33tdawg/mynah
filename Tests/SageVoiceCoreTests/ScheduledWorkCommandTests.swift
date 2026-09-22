import XCTest
@testable import SageVoiceCore

/// `//schedule`: the only way work gets onto the clock, and therefore the only
/// place a misreading would live forever.
///
/// The owner's side of this is one message — *"//schedule every day at 8am:
/// check my inbox and tell me what's waiting"* — and everything here is about
/// the two ways it can go wrong at the moment it is sent: a cadence read as
/// something he did not say, and work kept that he cannot then find, change or
/// stop. Both are silent from his phone, which is why the reading is code and
/// why a refusal always names what it could not read.
final class ScheduledWorkCommandTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("mynah-scheduled-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private var file: URL { scratch.appendingPathComponent("scheduled-work.json") }

    private func read(_ transcript: String) -> ScheduledWorkCommand.Reading? {
        ScheduledWorkCommand.read(transcript)
    }

    private func create(
        _ transcript: String,
        now: Date = Date(),
        isPaused: Bool = false
    ) -> String {
        guard let reading = read(transcript) else { return "(not a command)" }
        return ScheduledWorkCommand.perform(reading, at: file, now: now, isPaused: isPaused)
    }

    // MARK: Which messages these are

    /// Anchored, like `//call`: a message that merely mentions the command is a
    /// question, and the model answers it.
    func testOnlyAMessageThatStartsWithTheCommandIsOne() {
        XCTAssertNil(read("how do I use //schedule"))
        XCTAssertNil(read("I'll //schedule something later"))
        XCTAssertNil(read("schedule every day at 8am: check my inbox"))
        XCTAssertNotNil(read("//schedule every day at 8am: check my inbox"))
        XCTAssertNotNil(read("//schedules"))
    }

    // MARK: Reading the owner's own sentence

    func testEveryDayWithAClockTime() {
        XCTAssertEqual(
            read("//schedule every day at 8am: check my inbox and tell me what's waiting"),
            .request(.create(
                instruction: "check my inbox and tell me what's waiting",
                cadence: .daily(hour: 8, minute: 0)
            ))
        )
    }

    /// The time after the words, the daypart in the middle, and the minute
    /// where he put it.
    func testAClockTimeWrittenTheOtherWayRound() {
        XCTAssertEqual(
            read("//schedule every morning at 6:45am: put the bins out"),
            .request(.create(instruction: "put the bins out", cadence: .daily(hour: 6, minute: 45)))
        )
        XCTAssertEqual(
            read("//schedule daily at 20:00: lock up"),
            .request(.create(instruction: "lock up", cadence: .daily(hour: 20, minute: 0)))
        )
    }

    /// Evening, and the last day of the week — the two the parser has to get
    /// right for the same reason the morning ones are tested: nothing downstream
    /// can tell a 9am that should have been 9pm.
    func testEveningAndTheEndOfTheWeek() {
        XCTAssertEqual(
            read("//schedule every day at 9:30pm: text me the day in one line"),
            .request(.create(
                instruction: "text me the day in one line",
                cadence: .daily(hour: 21, minute: 30)
            ))
        )
        XCTAssertEqual(
            read("//schedule every Saturday at 10am: check the backups"),
            .request(.create(
                instruction: "check the backups",
                cadence: .weekly(weekday: 7, hour: 10, minute: 0)
            ))
        )
    }

    /// **The colon inside `8:30` is part of the time.** Splitting there would
    /// leave the work starting mid-hour and the cadence read from "every day at
    /// 8" — which is refused, so the owner would be told his message made no
    /// sense when it plainly did.
    func testAColonInsideTheTimeIsNotTheSeparator() {
        XCTAssertEqual(
            read("//schedule every Monday at 9:30am: send me the week ahead"),
            .request(.create(
                instruction: "send me the week ahead",
                cadence: .weekly(weekday: 2, hour: 9, minute: 30)
            ))
        )
    }

    /// A dash, because that is how somebody types this on a phone keyboard.
    func testADashCanSeparateTheTimeFromTheWork() {
        XCTAssertEqual(
            read("//schedule every day at 8am — check the inbox"),
            .request(.create(instruction: "check the inbox", cadence: .daily(hour: 8, minute: 0)))
        )
    }

    func testIntervals() {
        XCTAssertEqual(
            read("//schedule every 30 minutes: check the inbox"),
            .request(.create(instruction: "check the inbox", cadence: .every(minutes: 30)))
        )
        XCTAssertEqual(
            read("//schedule every hour: check the inbox"),
            .request(.create(instruction: "check the inbox", cadence: .every(minutes: 60)))
        )
        XCTAssertEqual(
            read("//schedule every 2 hours: check the inbox"),
            .request(.create(instruction: "check the inbox", cadence: .every(minutes: 120)))
        )
        XCTAssertEqual(
            read("//schedule hourly: check the inbox"),
            .request(.create(instruction: "check the inbox", cadence: .every(minutes: 60)))
        )
    }

    // MARK: What it refuses, and says

    /// **A bare hour is not read, and this is the refusal that will annoy
    /// somebody once.** "at 8" is eight in the morning to half the world and
    /// eight in the evening to the other half, and the cost of guessing is a
    /// message at the wrong hour for as long as the request stands — with
    /// nothing on the phone that says which of the two of them chose it.
    /// `SpokenDate` refuses the same way at the point of storage.
    func testABareHourIsRefusedRatherThanGuessedAt() {
        let answer = create("//schedule every day at 8: check my inbox")
        XCTAssertTrue(answer.contains("am or pm"), answer)
        XCTAssertEqual(ScheduledWork.load(from: file).tasks.count, 0, "it scheduled something anyway")
    }

    func testADaypartOnItsOwnIsNotATime() {
        let answer = create("//schedule every morning: check my inbox")
        XCTAssertTrue(answer.contains("need a time"), answer)
    }

    func testSomethingWithNoRecurrenceInItIsRefusedWithTheShapesThatWork() {
        let answer = create("//schedule sometime: check my inbox")
        XCTAssertTrue(answer.contains("every day at 8am"), answer)
        XCTAssertTrue(answer.contains("every Monday at 9:30am"), answer)
        XCTAssertTrue(answer.contains("every 30 minutes"), answer)
    }

    func testWorkWithNoSeparatorIsRefused() {
        let answer = create("//schedule every day at 8am check my inbox")
        XCTAssertTrue(answer.contains("colon"), answer)
    }

    func testATimeWithNoWorkAfterItIsRefused() {
        let answer = create("//schedule every day at 8am:")
        XCTAssertTrue(answer.contains("not what to do"), answer)
    }

    /// The fast end of the range, refused with the reason rather than clamped
    /// behind his back: a promise the tick cannot keep is worse than a sentence.
    func testTooOftenIsRefused() {
        let answer = create("//schedule every 2 minutes: check the inbox")
        XCTAssertTrue(answer.contains("5 minutes"), answer)
        XCTAssertEqual(ScheduledWork.load(from: file).tasks.count, 0)
    }

    func testTooLongAnInstructionIsRefused() {
        let answer = create("//schedule every day at 8am: \(String(repeating: "x", count: 700))")
        XCTAssertTrue(answer.contains("600"), answer)
    }

    // MARK: Keeping, listing and stopping them

    func testSettingOneUpKeepsItAndSaysWhichNumberItIs() {
        let answer = create("//schedule every day at 8am: check my inbox")

        XCTAssertTrue(answer.contains("Every day at 08:00"), answer)
        XCTAssertTrue(answer.contains("check my inbox"), answer)
        XCTAssertTrue(answer.contains("number 1"), answer)

        let kept = ScheduledWork.load(from: file)
        XCTAssertEqual(kept.tasks.count, 1)
        XCTAssertEqual(kept.tasks.first?.instruction, "check my inbox")
        XCTAssertEqual(kept.tasks.first?.cadence, .daily(hour: 8, minute: 0))
        XCTAssertNil(kept.tasks.first?.lastRunAt, "a new request must not read as already run")
    }

    func testTheListNumbersThemOldestFirstAndSaysWhatIsHeld() {
        let first = Date(timeIntervalSince1970: 1_800_000_000)
        _ = create("//schedule every day at 8am: check my inbox", now: first)
        _ = create("//schedule every Monday at 9:30am: send me the week ahead", now: first + 60)
        _ = create("//schedule pause 2", now: first + 120)

        let listing = create("//schedules", now: first + 180)
        XCTAssertTrue(listing.contains("1. every day at 08:00 — check my inbox"), listing)
        XCTAssertTrue(listing.contains("2. every Monday at 09:30 — send me the week ahead (held)"), listing)
        XCTAssertFalse(listing.contains("Nothing is scheduled"), listing)
    }

    func testTheEmptyListSaysHowToSetOneUp() {
        let listing = create("//schedules")
        XCTAssertTrue(listing.contains("Nothing is scheduled"), listing)
        XCTAssertTrue(listing.contains("//schedule every day at 8am: check my inbox"), listing)
    }

    func testCancellingStopsItAndSaysWhatIsLeft() {
        _ = create("//schedule every day at 8am: check my inbox")
        _ = create("//schedule every Monday at 9:30am: send me the week ahead")

        let answer = create("//schedule cancel 1")
        XCTAssertTrue(answer.contains("won't run again"), answer)
        XCTAssertTrue(answer.contains("1 left"), answer)
        XCTAssertEqual(ScheduledWork.load(from: file).tasks.map(\.instruction), ["send me the week ahead"])
    }

    func testCancellingSomethingThatIsNotThereNamesTheListCommand() {
        _ = create("//schedule every day at 8am: check my inbox")
        let answer = create("//schedule cancel 4")
        XCTAssertTrue(answer.contains("no 4"), answer)
        XCTAssertTrue(answer.contains("//schedules"), answer)
        XCTAssertEqual(ScheduledWork.load(from: file).tasks.count, 1)
    }

    /// **Holding and stopping are different verbs and the owner asked for both.**
    /// A standing request he wants back after a trip should not have to be typed
    /// again, and a held one must say so in the list rather than looking live.
    func testHoldingAndResuming() {
        _ = create("//schedule every day at 8am: check my inbox")
        let held = create("//schedule pause 1")
        XCTAssertTrue(held.contains("Held"), held)
        XCTAssertEqual(ScheduledWork.load(from: file).tasks.first?.isEnabled, false)

        let resumed = create("//schedule resume 1")
        XCTAssertTrue(resumed.contains("Running again"), resumed)
        XCTAssertEqual(ScheduledWork.load(from: file).tasks.first?.isEnabled, true)
    }

    /// A number he did not give. "cancel it" names a pronoun, and guessing
    /// which one he meant would stop work he did not name.
    func testACommandWithNoNumberAsksWhichOne() {
        let answer = create("//schedule cancel it")
        XCTAssertTrue(answer.contains("Which one?"), answer)
    }

    /// But only a pronoun is read that way. A body that merely starts with one
    /// of the verb words is a request to create something, and it gets the
    /// sentence about the cadence — which is true, and actionable — rather than
    /// a question about which row he meant.
    func testAVerbWordAtTheStartOfARequestIsNotACommandToStopSomething() {
        let answer = create("//schedule hold the fort at 9am: check the inbox")
        XCTAssertFalse(answer.contains("Which one?"), answer)
        XCTAssertTrue(answer.contains("every day at 8am"), answer)
    }

    /// Saying "resume" about something that was never held must not move its
    /// clock: the second time he says it, the work would quietly slip by an
    /// hour — and the third time, by another.
    func testResumingSomethingAlreadyRunningDoesNotMoveItsClock() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        _ = create("//schedule every 30 minutes: check the inbox", now: start)
        let before = ScheduledWork.load(from: file).tasks.first?.lastRunAt

        let answer = create("//schedule resume 1", now: start + 600)
        XCTAssertTrue(answer.contains("already running"), answer)
        XCTAssertEqual(ScheduledWork.load(from: file).tasks.first?.lastRunAt, before)
    }

    func testTheBareCommandExplainsItself() {
        let answer = create("//schedule")
        XCTAssertTrue(answer.contains("Set it up with"), answer)
        XCTAssertTrue(answer.contains("every day at 8am"), answer)
    }

    // MARK: More than it will carry

    /// Ten is the number that keeps the list a paragraph rather than a page of
    /// the model's turn, and the refusal is what stops the eleventh becoming a
    /// longer prompt for everybody.
    func testItWillNotCarryMoreThanItsCeiling() {
        for index in 1...ScheduledWork.maximumTasks {
            _ = create("//schedule every day at 8am: check my inbox \(index)")
        }
        let answer = create("//schedule every day at 9am: one too many")

        XCTAssertTrue(answer.contains("\(ScheduledWork.maximumTasks) pieces"), answer)
        XCTAssertEqual(ScheduledWork.load(from: file).tasks.count, ScheduledWork.maximumTasks)
    }

    // MARK: Paused

    /// Paused means the owner has said *not now*, so nothing is changed — and
    /// the sentence names the switch rather than leaving him to guess. Reading
    /// the list still works: a question costs nothing.
    func testWritesAreRefusedWhilePausedAndReadsAreNot() {
        _ = create("//schedule every day at 8am: check my inbox")

        let refused = create("//schedule every day at 9am: another one", isPaused: true)
        XCTAssertTrue(refused.contains("paused"), refused)
        XCTAssertEqual(ScheduledWork.load(from: file).tasks.count, 1)

        let listed = create("//schedules", isPaused: true)
        XCTAssertTrue(listed.contains("check my inbox"), listed)
    }

    // MARK: What is on disk

    /// **One bad row costs one piece of work, not the whole file.** A schedule
    /// edited by hand into nonsense — an hour of 25 — is dropped on its own;
    /// the rest still run. The alternative is an appliance that silently stops
    /// doing everything because one line has a typo in it.
    func testOneUnreadableRowDoesNotTakeTheOthersWithIt() throws {
        let json = """
        {
          "tasks": [
            {
              "id": "good",
              "instruction": "check my inbox",
              "cadence": {"kind": "daily", "hour": 8, "minute": 0},
              "createdAt": 800000000,
              "isEnabled": true
            },
            {
              "id": "hand-edited",
              "instruction": "impossible",
              "cadence": {"kind": "daily", "hour": 25, "minute": 0},
              "createdAt": 800000000,
              "isEnabled": true
            },
            {
              "id": "also-good",
              "instruction": "send me the week ahead",
              "cadence": {"kind": "weekly", "weekday": 2, "hour": 9, "minute": 30},
              "createdAt": 800000060,
              "isEnabled": true
            }
          ]
        }
        """
        try Data(json.utf8).write(to: file)

        let loaded = ScheduledWork.load(from: file)
        XCTAssertEqual(loaded.tasks.map(\.id), ["good", "also-good"])
    }

    func testWhatIsWrittenCanBeReadBackExactly() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        _ = create("//schedule every Monday at 9:30am: send me the week ahead", now: now)

        let reloaded = ScheduledWork.load(from: file)
        XCTAssertEqual(reloaded.tasks.first?.cadence, .weekly(weekday: 2, hour: 9, minute: 30))
        XCTAssertEqual(reloaded.tasks.first?.createdAt, now)
    }
}
