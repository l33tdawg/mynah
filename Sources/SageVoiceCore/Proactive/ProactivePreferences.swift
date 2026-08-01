import Foundation

/// Whether Mynah is allowed to speak first, and how often it may look.
///
/// **Off unless the owner turns it on, and that is not a default chosen out of
/// caution.** Every other message this appliance sends is an answer to
/// something. This one is not: it arrives on the owner's phone because a timer
/// went off, which is the thing the Privacy screen has always been able to say
/// Mynah does not do. Changing that is the owner's decision to make, once,
/// deliberately — not something an update quietly switches on.
///
/// A file rather than `UserDefaults`, for the reason spelled out on
/// `CallPreferences`: the app and the daemon are separate processes with
/// separate defaults domains, and the daemon is the one that has to obey this.
public struct ProactivePreferences: Sendable, Equatable, Codable {

    /// Whether the appliance may check on its own and say something.
    public var isOn: Bool

    /// Minutes between checks.
    ///
    /// The owner's number — *"every 30 mins or 60 mins (user can define this)"*
    /// — clamped rather than trusted, because this file is editable by hand and
    /// a one-minute interval is a phone that buzzes all day.
    public var everyMinutes: Int

    /// The hour it stops for the night, and the hour it starts again.
    ///
    /// **Both zero by default, which means it never stops.** These shipped at
    /// 22:00–08:00 on the assumption that a message landing overnight wakes
    /// somebody — and on this appliance it does not. Mynah answers in Note to
    /// Self *as the owner's own account*, from a linked device, so what arrives
    /// is one of their own sent messages and Signal does not notify anybody
    /// about their own sent messages. The owner's reading: *"i think its ok to
    /// have it run 24/7 - notes to self does not make a sound."*
    ///
    /// The setting stays because the assumption behind the new default is
    /// configuration-specific: an appliance pointed at a thread that is not
    /// Note to Self would notify, and then somebody will want their nights
    /// back. There is no control for it — it is two numbers in
    /// `proactive-preferences.json` — because inventing a screen for a case
    /// nobody has yet is how settings pages become unreadable.
    ///
    /// Nothing is lost to a quiet hour when one is set: the check does not run,
    /// the ledger is untouched, and whatever accumulated is still new in the
    /// morning.
    public var quietFrom: Int
    public var quietUntil: Int

    /// Fifteen minutes is as often as this will go. Below that the appliance is
    /// polling a node rather than checking in.
    public static let fastest = 15
    public static let slowest = 24 * 60

    public init(
        isOn: Bool = false,
        everyMinutes: Int = 60,
        quietFrom: Int = 0,
        quietUntil: Int = 0
    ) {
        self.isOn = isOn
        self.everyMinutes = everyMinutes
        self.quietFrom = quietFrom
        self.quietUntil = quietUntil
    }

    public var clampedMinutes: Int {
        min(max(everyMinutes, Self.fastest), Self.slowest)
    }

    /// Whether the appliance should stay quiet at this moment.
    ///
    /// Handles the ordinary case (22:00 to 08:00, wrapping midnight) and the
    /// inverted one somebody will eventually write by hand, and treats
    /// `from == until` as "no quiet hours" rather than "silent forever" —
    /// a preference that switches the feature off through the back door is
    /// worse than one that does nothing.
    public func isQuiet(at date: Date, calendar: Calendar = .current) -> Bool {
        guard quietFrom != quietUntil else { return false }
        let hour = calendar.component(.hour, from: date)
        if quietFrom < quietUntil {
            return hour >= quietFrom && hour < quietUntil
        }
        return hour >= quietFrom || hour < quietUntil
    }

    // MARK: Where it lives

    public static func defaultFileURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/SAGE Voice Bridge", isDirectory: true)
            .appendingPathComponent("proactive-preferences.json", isDirectory: false)
    }

    /// Never throws. A file that will not parse should cost the owner a
    /// setting, not their appliance.
    public static func load(
        from url: URL = ProactivePreferences.defaultFileURL()
    ) -> ProactivePreferences {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(ProactivePreferences.self, from: data) else {
            return ProactivePreferences()
        }
        return withoutTheOldNightDefault(stored)
    }

    /// Clears 22:00–08:00 when it was written by the version that shipped it as
    /// the default.
    ///
    /// 1.2.8 stored those two numbers the moment the owner touched the switch,
    /// and there has never been a control for them — so a file carrying exactly
    /// that pair carries a default nobody chose, and after 1.2.9 it would leave
    /// them silent all night with nothing in the app able to change it. A dead
    /// end made out of a preference is worse than the preference.
    ///
    /// Only that exact pair. Anything else is somebody who edited the file, and
    /// an edit is a decision.
    static func withoutTheOldNightDefault(_ stored: ProactivePreferences) -> ProactivePreferences {
        guard stored.quietFrom == 22, stored.quietUntil == 8 else { return stored }
        var updated = stored
        updated.quietFrom = 0
        updated.quietUntil = 0
        return updated
    }

    public func save(to url: URL = ProactivePreferences.defaultFileURL()) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try OwnerOnlyFileSecurity.write(encoder.encode(self), to: url)
    }

    public static func amend(
        at url: URL = ProactivePreferences.defaultFileURL(),
        _ change: (inout ProactivePreferences) -> Void
    ) {
        var preferences = load(from: url)
        change(&preferences)
        try? preferences.save(to: url)
    }
}
