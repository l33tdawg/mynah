import XCTest
@testable import SageVoiceCore

private final class RecordingCalendar: CalendarWriting, @unchecked Sendable {
    var added: [CalendarEntry] = []
    var updated: [String] = []
    var removed: [String] = []
    var prepareCalls = 0

    func prepare() async -> Bool {
        prepareCalls += 1
        return true
    }

    func add(_ entry: CalendarEntry) async throws -> String {
        added.append(entry)
        return "event-\(entry.taskID)"
    }

    func update(_ entry: CalendarEntry, eventID: String) async throws -> String {
        updated.append(eventID)
        return eventID
    }

    func remove(eventID: String) async throws {
        removed.append(eventID)
    }
}

/// **A thing that writes to the owner's calendar has to have a switch.**
///
/// Until 1.7.8 the only way to stop the mirror was revoking a system permission,
/// which leaves everything already written behind with nothing able to take it
/// back. The switch is half the answer; `EventKitCalendar.forget()` is the other
/// half, and they are deliberately separate acts.
final class CalendarSwitchTests: XCTestCase {

    private func task(_ id: String, _ title: String) -> WatchedTask {
        WatchedTask(id: id, title: title, status: "planned")
    }

    private var dated: [WatchedTask] {
        [task("t1", "Dentist appointment on Friday 21 August 2026, 11am")]
    }

    /// **The failure this test exists to prevent, and it is the expensive one.**
    ///
    /// The tempting implementation of an off switch is to let it fall through to
    /// a plan computed against no tasks, because that reads as "mirror nothing".
    /// It would empty the owner's calendar: every mirrored task becomes a
    /// `plan.remove`. Somebody flicking the switch to see what it does would
    /// lose their appointments, and the ledger would go with them so nothing
    /// could put them back.
    func testTurningItOffRemovesNothing() async {
        let calendar = RecordingCalendar()
        let ledger = CalendarLedger(
            events: ["t1": "event-1", "gone": "event-2"],
            written: ["t1": "stale-fingerprint"]
        )

        let outcome = await CalendarSync(calendar: calendar).run(
            tasks: dated,
            ledger: ledger,
            preferences: CalendarPreferences(isOn: false)
        )

        XCTAssertTrue(calendar.removed.isEmpty, "switching the mirror off deleted the owner's events")
        XCTAssertTrue(calendar.added.isEmpty)
        XCTAssertTrue(calendar.updated.isEmpty)
        XCTAssertEqual(outcome.ledger, ledger, "the ledger was rewritten by a switch that writes nothing")
    }

    /// Off must not even ask for permission. A prompt raised by a feature the
    /// owner has just switched off is its own small betrayal.
    func testTurningItOffDoesNotAskForCalendarAccess() async {
        let calendar = RecordingCalendar()

        _ = await CalendarSync(calendar: calendar).run(
            tasks: dated,
            ledger: CalendarLedger(),
            preferences: CalendarPreferences(isOn: false)
        )

        XCTAssertEqual(calendar.prepareCalls, 0, "a switched-off mirror asked for calendar access")
    }

    /// **The events are still there, so the ladder must still stay quiet about
    /// them.** Turning off future writes does not stop macOS alerting on what it
    /// already holds, and a reminder ladder that started nudging about tasks the
    /// calendar is still shouting about would double every alert.
    func testWhatIsAlreadyMirroredStillSuppressesTheLadder() async {
        let outcome = await CalendarSync(calendar: RecordingCalendar()).run(
            tasks: dated,
            ledger: CalendarLedger(events: ["t1": "event-1"], written: ["t1": "f"]),
            preferences: CalendarPreferences(isOn: false)
        )

        XCTAssertEqual(outcome.mirrored, ["t1"])
    }

    /// On is the default and has to be: the feature shipped in 1.6.x and there
    /// are events in the owner's calendar now. A new preference defaulting to
    /// `false` would silently retract a working feature — and worse, read as a
    /// removal for every mirrored task on the next tick.
    func testTheDefaultIsOn() {
        XCTAssertTrue(CalendarPreferences().isOn)
    }

    /// A file that will not parse costs a setting, never the owner's events.
    func testAnUnreadableFileFallsBackToOn() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cal-prefs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("calendar-preferences.json")
        try Data("not json".utf8).write(to: file)

        XCTAssertTrue(
            CalendarPreferences.load(from: file).isOn,
            "a corrupt preferences file switched the mirror off, which on the next tick would "
                + "look like the owner had asked for it"
        )
    }

    /// And with it on, the mirror does what it always did.
    func testOnStillMirrors() async {
        let calendar = RecordingCalendar()

        let outcome = await CalendarSync(calendar: calendar).run(
            tasks: dated,
            ledger: CalendarLedger(),
            preferences: CalendarPreferences(isOn: true)
        )

        XCTAssertEqual(calendar.added.count, 1)
        XCTAssertEqual(outcome.ledger.events["t1"], "event-t1")
    }
}
