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
///
/// **The only writer used to be a Mac settings screen**, which made this the
/// one feature a Linux owner could install the product for and then never turn
/// on. `update(at:_:)` is the headless way in; `amend(at:_:)` stays for the
/// screen. They are not interchangeable — see both.
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

    /// Five minutes is as often as this will go.
    ///
    /// **This was fifteen, and the sentence defending it was "below that the
    /// appliance is polling a node rather than checking in."** That reads well
    /// and was never measured. What settled it was the appliance accidentally
    /// doing five for an evening and the owner preferring it — his words, on
    /// seeing it in his own log: *"every 5 mins is even better bro"*.
    ///
    /// The accident is worth recording, because it is the only evidence either
    /// number ever had. SAGE hands out a five-minute wake lease; when it
    /// expires the stream reconnects, and 11.18.14 re-announces any still-
    /// pending work on reconnect. With a row stranded under another claimant,
    /// that drove a check every five minutes for hours. Nothing suffered: a
    /// check is three local reads, the ledger stops anything being said twice,
    /// and no duplicate reached his phone. The old floor was protecting against
    /// a cost that did not exist.
    ///
    /// It is still a floor rather than a default — `everyMinutes` defaults to
    /// 60 and is the owner's to choose. This only decides how low he may go.
    public static let fastest = 5
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
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        layout: ApplianceSupportDirectory.Layout = ApplianceSupportDirectory.current,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        ApplianceSupportDirectory.url(
            for: "proactive-preferences.json",
            layout: layout,
            homeDirectory: homeDirectory,
            environment: environment
        )
    }

    /// Never throws. A file that will not parse should cost the owner a
    /// setting, not their appliance.
    ///
    /// This is the daemon's read and it stays exactly as forgiving as it was.
    /// Anything that is about to *write* must use `loadOrRefuse(from:)` instead,
    /// for the reason spelled out there.
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

    /// **The settings screen's writer, and nothing else's.**
    ///
    /// It cannot report a failed write and it cannot report a file it could not
    /// read, which is survivable behind a switch the owner is looking at — the
    /// switch springs back on the next redraw — and is not survivable in a tool
    /// that prints a line and exits. A headless caller wants `update(at:_:)`.
    public static func amend(
        at url: URL = ProactivePreferences.defaultFileURL(),
        _ change: (inout ProactivePreferences) -> Void
    ) {
        var preferences = load(from: url)
        change(&preferences)
        try? preferences.save(to: url)
    }

    // MARK: Changing it without a settings screen

    /// Why a write refuses, in the words the caller should print.
    public enum Refusal: Error, LocalizedError, Equatable {
        /// There is a file, and it is not this.
        case unreadable(path: String)
        /// A caller asked for an interval outside the range that will be run.
        case intervalOutOfRange(minutes: Int, path: String)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let path):
                return """
                \(path) exists but is not readable proactive settings, so changing one \
                setting would silently discard the rest.
                Move that file aside and try again; a fresh one will be written with the \
                defaults, and the check stays off until it is turned on.
                """
            case .intervalOutOfRange(let minutes, let path):
                return """
                \(minutes) minutes is outside the range this appliance checks at \
                (\(ProactivePreferences.fastest) to \(ProactivePreferences.slowest) minutes).
                Choose a number in that range. Nothing was written to \(path).
                """
            }
        }
    }

    /// The read a caller does **before writing**.
    ///
    /// `load(from:)` answers with the defaults when the file will not parse,
    /// which is right for the daemon and destructive for a writer: amending
    /// defaults and saving them replaces whatever the owner had — their
    /// interval, their quiet hours — with values nobody chose, and reports
    /// success. So this one separates *no file* (defaults, an ordinary state)
    /// from *a file I cannot read* (a refusal that names the path).
    public static func loadOrRefuse(
        from url: URL = ProactivePreferences.defaultFileURL()
    ) throws -> ProactivePreferences {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            guard FileManager.default.fileExists(atPath: url.path) else {
                return ProactivePreferences()
            }
            throw Refusal.unreadable(path: url.path)
        }
        guard let stored = try? JSONDecoder().decode(ProactivePreferences.self, from: data) else {
            throw Refusal.unreadable(path: url.path)
        }
        return withoutTheOldNightDefault(stored)
    }

    /// The write for a caller that has to say what happened.
    ///
    /// Everything `amend` swallows, this reports: an unreadable file, a refused
    /// interval, a directory it cannot write. And it returns what is now on
    /// disk, so the caller prints the state of the appliance rather than the
    /// state it hoped for.
    ///
    /// **An out-of-range interval is refused rather than clamped**, because a
    /// tool that accepts `1` and quietly runs at `5` has told the owner
    /// something untrue about their own appliance. Only an interval *this write
    /// introduces* is refused, though: a file already carrying a hand-edited `1`
    /// must not make it impossible to turn the feature off, which would be a
    /// dead end with the setting stuck on.
    ///
    /// - Returns: the preferences as written.
    @discardableResult
    public static func update(
        at url: URL = ProactivePreferences.defaultFileURL(),
        _ change: (inout ProactivePreferences) -> Void
    ) throws -> ProactivePreferences {
        let before = try loadOrRefuse(from: url)
        var after = before
        change(&after)
        if after.everyMinutes != before.everyMinutes, after.everyMinutes != after.clampedMinutes {
            throw Refusal.intervalOutOfRange(minutes: after.everyMinutes, path: url.path)
        }
        try after.save(to: url)
        return after
    }
}
