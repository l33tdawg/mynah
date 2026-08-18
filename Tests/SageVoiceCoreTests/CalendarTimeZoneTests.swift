// **Mac-only, because it tests EventKit.**
//
// The calendar mirror is Apple's EventKit, which has no counterpart off Darwin;
// `Sources/SageVoiceCore/Calendar/EventKitCalendar.swift` is itself compiled
// only where `EventKit` can be imported. Guarding the whole file rather than
// just the import, so Linux cannot report a green suite containing an empty
// test class.
#if canImport(EventKit)
import XCTest
import EventKit
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

    // MARK: - And the event is actually written with it

    /// **The three tests above pass with the assignment deleted.**
    ///
    /// They ask `timeZone(for:current:)` what the zone *should* be. Nothing asked
    /// whether `apply(_:to:)` ever put it on the event — and `apply` is the
    /// method the opening paragraph of this file is about, the one that set the
    /// title, the day, the start, the end, the alarms, the link and the notes and
    /// never once said where in the world any of it was. Delete
    /// `event.timeZone = Self.timeZone(for: entry)` and this file was green while
    /// every mirrored appointment floated again.
    ///
    /// So `apply` is `static` and internal now, which is the smallest change that
    /// lets a test hand it an event and read the event back. No store, no
    /// permission prompt, nothing saved: an `EKEvent` that is never written to a
    /// calendar is a value object, and this is the one place in the mirror where
    /// a value is all that matters.
    ///
    /// **The zone handed in is deliberately not this Mac's**, and the first
    /// version of this test was decoration for want of that. Measured here on 4
    /// August 2026: a brand new `EKEvent(eventStore:)` already answers
    /// `Asia/Kuala_Lumpur`, this Mac's zone, before anything has been assigned to
    /// it. So `XCTAssertEqual(event.timeZone, .current)` passed with the
    /// assignment deleted from `apply` — the mutation ran, and all five tests in
    /// this file stayed green. Asking for Dubai on a Mac in Malaysia is what
    /// makes the assignment the only thing that could have put it there.
    func testATimedEventIsWrittenCarryingItsZone() {
        let event = EKEvent(eventStore: EKEventStore())
        let elsewhere = try? XCTUnwrap([dubai, malaysia].first { $0 != TimeZone.current })
        let asked = elsewhere ?? dubai

        EventKitCalendar.apply(entry(allDay: false), to: event, current: asked)

        XCTAssertNotEqual(asked, TimeZone.current, "the zone asked for is this Mac's, so this proves nothing")
        // Asserted alongside the zone so that an `apply` which did nothing at all
        // could not pass this by leaving every field untouched.
        XCTAssertEqual(event.title, "Dentist appointment")
        XCTAssertEqual(event.timeZone, asked)
    }

    /// And the all-day case keeps floating through the same method, because a
    /// zone assigned unconditionally is the other half of the bug: it turns
    /// "Sunday 9 August" into midnight-to-midnight somewhere, and one timezone
    /// east that is a hotel check-in on the Saturday.
    ///
    /// **What this one can and cannot see, stated plainly.** EventKit clears
    /// `timeZone` by itself the moment `isAllDay` becomes true, so this cannot
    /// tell a correct `apply` from one with the assignment removed. What it does
    /// tell — measured, not assumed — is the failure that would actually be
    /// written: a zone assigned *after* `isAllDay` sticks, so an unconditional
    /// `event.timeZone = current` shows up here as a non-nil zone. That is the
    /// mistake somebody makes while fixing the timed case, and it is the one
    /// worth a test.
    func testAnAllDayEventIsWrittenWithNoZoneAtAll() {
        let event = EKEvent(eventStore: EKEventStore())

        EventKitCalendar.apply(entry(allDay: true), to: event, current: dubai)

        XCTAssertEqual(event.title, "Check in at Butterfly Hotel Betong")
        XCTAssertTrue(event.isAllDay)
        XCTAssertNil(event.timeZone)
    }
}
#endif  // canImport(EventKit)
