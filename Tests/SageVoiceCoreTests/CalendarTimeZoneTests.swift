import XCTest
@testable import SageVoiceCore

/// Which timezone a mirrored event is written in.
///
/// **An event with no zone is not "local", it is undefined.** EventKit calls it
/// floating, and a floating event syncing through iCloud is re-read by whichever
/// device opens it — so "1pm", written on a Mac in Kuala Lumpur, can be shown as
/// 1pm four timezones away. That is a different instant and a missed
/// appointment, and it looks exactly like the calendar being "set to GMT".
///
/// `apply(_:to:)` set the title, the day, the start, the end, the alarms, the
/// link and the notes, and never once said where in the world any of it was.
final class CalendarTimeZoneTests: XCTestCase {

    private let dubai = TimeZone(identifier: "Asia/Dubai")!
    private let malaysia = TimeZone(identifier: "Asia/Kuala_Lumpur")!

    private func entry(allDay: Bool) -> CalendarEntry {
        CalendarEntry(
            taskID: "t1",
            title: allDay ? "Check in at Butterfly Hotel Betong" : "Dentist appointment",
            starts: Date(timeIntervalSince1970: 1_785_906_000),
            isAllDay: allDay
        )
    }

    /// A timed event says where it was written, so 1pm here stays 1pm here.
    func testATimedEventCarriesTheZoneItWasWrittenIn() {
        let zone = EventKitCalendar.timeZone(for: entry(allDay: false), current: malaysia)

        XCTAssertEqual(zone?.identifier, "Asia/Kuala_Lumpur")
    }

    /// And it is the Mac's zone, not a fixed one — the owner flies, and an
    /// appointment made in Dubai was made at Dubai's one o'clock.
    func testTheZoneFollowsTheMacRatherThanBeingPinned() {
        let zone = EventKitCalendar.timeZone(for: entry(allDay: false), current: dubai)

        XCTAssertEqual(zone?.identifier, "Asia/Dubai")
    }

    /// **All-day events must keep floating.** A day is not an instant. Pin
    /// "Sunday 9 August" to a zone and it becomes midnight-to-midnight in that
    /// zone, which one timezone east is a hotel check-in that starts on the
    /// Saturday.
    func testAnAllDayEventStaysFloating() {
        XCTAssertNil(EventKitCalendar.timeZone(for: entry(allDay: true), current: malaysia))
        XCTAssertNil(EventKitCalendar.timeZone(for: entry(allDay: true), current: dubai))
    }
}
