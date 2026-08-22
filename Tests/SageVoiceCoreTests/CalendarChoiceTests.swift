import XCTest
@testable import SageVoiceCore

/// **Choosing which calendar the mirror writes into.**
///
/// The owner, 22 August 2026: *"we need a ui interface to configure which
/// calendar it writes to so you can choose"*. Before this the account was picked
/// by `EventKitCalendar.writableSource()` — iCloud, then any other CalDAV
/// account, then this Mac — with no way to say otherwise and no screen anywhere
/// saying which had won.
///
/// Nothing here touches EventKit. The parts worth pinning are the ones that
/// decide what is *stored* and what the owner is *told*, and both of those are
/// plain values by construction — see `CalendarChoice`, which is deliberately in
/// the Foundation-only file for exactly this reason.
final class CalendarChoiceTests: XCTestCase {

    private var directory: URL!
    private var file: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("calendar-choice-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("calendar-preferences.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: The file that already exists on every Mac

    /// **The expensive failure, and the only reason `init(from:)` is written by
    /// hand.**
    ///
    /// Every `calendar-preferences.json` on disk today holds `isOn` and nothing
    /// else. `Codable`'s synthesised decoder treats a missing key as an error,
    /// and `CalendarPreferences.load` deliberately turns any error into the
    /// default — which is `isOn: true`. So adding a field with the synthesised
    /// decoder would not fail loudly: it would silently discard an owner who had
    /// turned the mirror **off** and start writing to their calendar again on
    /// the next tick, because a file gained a key.
    ///
    /// That is the same class of fault `CalendarPreferences` was created to
    /// prevent one field along, where defaulting a new preference to `false`
    /// would have read as `plan.remove` for every mirrored task.
    func testAFileWrittenBeforeThereWasAChoiceKeepsTheOwnersSwitch() throws {
        try Data(#"{"isOn":false}"#.utf8).write(to: file)

        let loaded = CalendarPreferences.load(from: file)

        XCTAssertFalse(
            loaded.isOn,
            "an old preferences file must keep the owner's off switch; decoding it as the "
                + "default would turn the mirror back on because a field was added"
        )
        XCTAssertEqual(loaded.target, .own, "the target a file does not mention is Mynah's own")
    }

    /// The other half of the same guard: a file with no fields at all is still
    /// the shipped default rather than a crash or an off switch.
    func testAnEmptyFileIsTheShippedDefault() throws {
        try Data("{}".utf8).write(to: file)

        let loaded = CalendarPreferences.load(from: file)

        XCTAssertTrue(loaded.isOn)
        XCTAssertEqual(loaded.target, .own)
    }

    /// A chosen calendar survives being written and read back, identifier and
    /// all. Without this the picker would appear to work and forget by the next
    /// launch.
    func testAChosenCalendarSurvivesTheRoundTrip() throws {
        try CalendarPreferences(isOn: true, target: .existing(identifier: "cal-42")).save(to: file)

        XCTAssertEqual(
            CalendarPreferences.load(from: file).target,
            .existing(identifier: "cal-42")
        )
    }

    /// Turning the mirror off must not disturb which calendar was chosen. The
    /// owner switching it off for a fortnight and back on should not have to
    /// find their calendar again.
    func testTheSwitchAndTheChoiceAreIndependent() throws {
        try CalendarPreferences(isOn: true, target: .existing(identifier: "cal-7")).save(to: file)

        CalendarPreferences.amend(at: file) { $0.isOn = false }

        let loaded = CalendarPreferences.load(from: file)
        XCTAssertFalse(loaded.isOn)
        XCTAssertEqual(loaded.target, .existing(identifier: "cal-7"))
    }

    // MARK: What the owner is told

    private let choices = [
        CalendarChoice(id: "cal-1", title: "Personal", account: "iCloud"),
        CalendarChoice(id: "cal-2", title: "Personal", account: "Google")
    ]

    /// **The account is part of the name, not decoration.** Two accounts are
    /// each entitled to a calendar called "Personal", and a picker showing two
    /// identical rows is one the owner cannot choose from.
    func testACalendarIsNamedWithTheAccountItLivesIn() {
        XCTAssertEqual(
            CalendarTarget.existing(identifier: "cal-2").name(among: choices),
            "Personal — Google"
        )
        XCTAssertNotEqual(
            CalendarTarget.existing(identifier: "cal-1").name(among: choices),
            CalendarTarget.existing(identifier: "cal-2").name(among: choices),
            "two calendars with the same title must not produce the same row"
        )
    }

    /// A calendar the owner chose and then deleted is named as gone rather than
    /// rendered as an empty row. `EventKitCalendar.calendar()` is meanwhile
    /// falling back to Mynah's own and logging it, so the mirror has not
    /// stopped — but a blank row would say nothing at all about that.
    func testACalendarThatHasBeenDeletedIsNamedRatherThanBlank() {
        let name = CalendarTarget.existing(identifier: "gone").name(among: choices)

        XCTAssertFalse(name.isEmpty)
        XCTAssertTrue(
            name.lowercased().contains("no longer there"),
            "a vanished calendar has to say so; got “\(name)”"
        )
    }

    // MARK: The sentence on the button that destroys things

    /// **The wording that keeps the undo honest.**
    ///
    /// Aimed at one of the owner's own calendars the button does not delete a
    /// calendar at all — it takes back exactly the events in
    /// `CalendarLedger.events`. Telling them it removed a calendar would be
    /// false about the one control in this app that destroys data, and would
    /// send them to Calendar.app expecting to find something missing.
    func testTakingEventsBackNeverClaimsToHaveRemovedACalendar() {
        let sentence = CalendarTarget.existing(identifier: "cal-1").removalSentence(held: 3)

        XCTAssertTrue(sentence.contains("3 events"))
        XCTAssertTrue(
            sentence.lowercased().contains("untouched"),
            "it has to say the owner's calendar is still there; got “\(sentence)”"
        )
        XCTAssertFalse(
            sentence.lowercased().contains("removed mynah's calendar"),
            "this branch removes events, not a calendar; got “\(sentence)”"
        )
        XCTAssertFalse(
            sentence.lowercased().contains("calendar is gone"),
            "this branch removes events, not a calendar; got “\(sentence)”"
        )
    }

    /// Mynah's own calendar is deleted whole, and the sentence says so — that
    /// branch is the complete uninstall and must keep reading like one.
    func testRemovingMynahsOwnCalendarSaysTheCalendarIsGone() {
        XCTAssertEqual(
            CalendarTarget.own.removalSentence(held: 0),
            "Mynah's calendar is gone."
        )
        XCTAssertTrue(
            CalendarTarget.own.removalSentence(held: 1).contains("1 event"),
            "singular, because “1 events” is how an appliance sounds like a form letter"
        )
        XCTAssertTrue(CalendarTarget.own.removalSentence(held: 4).contains("4 events"))
    }

    /// Nothing mirrored is an ordinary state, not a failure, and the sentence
    /// for it must not read as one — the owner may simply have no dated tasks.
    func testNothingToTakeBackIsSaidPlainly() {
        let sentence = CalendarTarget.existing(identifier: "cal-1").removalSentence(held: 0)

        XCTAssertFalse(sentence.lowercased().contains("error"))
        XCTAssertFalse(sentence.lowercased().contains("could not"))
        XCTAssertTrue(sentence.lowercased().contains("had not put anything"))
    }
}
