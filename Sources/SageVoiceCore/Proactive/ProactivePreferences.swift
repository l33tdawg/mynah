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
    /// A phone on a bedside table is the reason this exists. Nothing is lost to
    /// a quiet hour: the check simply does not run, and whatever accumulated is
    /// still there in the morning.
    public var quietFrom: Int
    public var quietUntil: Int

    /// Fifteen minutes is as often as this will go. Below that the appliance is
    /// polling a node rather than checking in.
    public static let fastest = 15
    public static let slowest = 24 * 60

    public init(
        isOn: Bool = false,
        everyMinutes: Int = 60,
        quietFrom: Int = 22,
        quietUntil: Int = 8
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
        return stored
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
