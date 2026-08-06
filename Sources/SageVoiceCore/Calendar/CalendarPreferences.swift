import Foundation

/// Whether Mynah may put dated tasks in the owner's calendar.
///
/// ## Why this exists
///
/// The mirror writes into a calendar the owner also owns, on a device they also
/// use, and until now there was **no way to stop it** short of revoking a system
/// permission — which is a blunt instrument that leaves whatever was already
/// written behind, orphaned, with nothing able to take it back.
///
/// That is the wrong shape for a feature that touches somebody's real
/// appointments. A thing which can write to your calendar has to have a switch,
/// and the switch has to be somewhere you would look for it.
///
/// ## On by default, and that is a considered choice
///
/// The opposite of `ProactivePreferences`, which is off unless asked for, and
/// for a reason that does not apply here. Proactive messaging *initiates* — it
/// arrives on a phone because a timer went off. This mirrors work the owner
/// already asked for into a place they already keep it, and it is the only thing
/// that makes a dated task reach them when the Mac is shut. An appliance whose
/// reminders silently do not fire is worse than one that puts an event in a
/// calendar somebody can delete.
///
/// It also has to stay on by default because it already is: the feature shipped
/// in 1.6.x and there are events in the owner's calendar right now. Defaulting a
/// new preference to `false` would silently retract a feature and, worse, would
/// read as `plan.remove` for every mirrored task — deleting the owner's events
/// on the next tick because a file gained a field.
///
/// A file rather than `UserDefaults`, for the reason spelled out on
/// `CallPreferences`: the app and the daemon are separate processes with
/// separate defaults domains, and the daemon is the one that has to obey this.
public struct CalendarPreferences: Sendable, Equatable, Codable {

    /// Whether dated tasks are mirrored into the calendar at all.
    ///
    /// Turning this off stops future writes. It deliberately does **not** delete
    /// what is already there — see `EventKitCalendar.forget()`, which is the
    /// separate, explicit act of taking it back. Conflating the two would mean
    /// a switch that quietly destroys data, and somebody flicking it to see what
    /// it does would lose their events.
    public var isOn: Bool

    public init(isOn: Bool = true) {
        self.isOn = isOn
    }

    // MARK: Where it lives

    public static func defaultFileURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/SAGE Voice Bridge", isDirectory: true)
            .appendingPathComponent("calendar-preferences.json", isDirectory: false)
    }

    /// Never throws. A file that will not parse should cost the owner a setting,
    /// not their appliance — and here it must not cost them their events either,
    /// which is why the fallback is the on state rather than the off one.
    public static func load(
        from url: URL = CalendarPreferences.defaultFileURL()
    ) -> CalendarPreferences {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(CalendarPreferences.self, from: data) else {
            return CalendarPreferences()
        }
        return stored
    }

    public func save(to url: URL = CalendarPreferences.defaultFileURL()) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try OwnerOnlyFileSecurity.write(encoder.encode(self), to: url)
    }

    public static func amend(
        at url: URL = CalendarPreferences.defaultFileURL(),
        _ change: (inout CalendarPreferences) -> Void
    ) {
        var preferences = load(from: url)
        change(&preferences)
        try? preferences.save(to: url)
    }
}
