import Foundation

/// Which calendar the mirror writes into.
///
/// ## Why this exists
///
/// The owner, 22 August 2026: *"we need a ui interface to configure which
/// calendar it writes to so you can choose"*.
///
/// Until now `EventKitCalendar.writableSource()` picked the account by itself —
/// iCloud first, then any other CalDAV account, then the local store — and made
/// a calendar named Mynah inside whichever it landed on. That is a reasonable
/// default and it is *only* a default: an owner whose phone shows a Google
/// account has no way to say so, and no screen anywhere tells them where their
/// events went.
///
/// ## Mynah's own, or one of theirs
///
/// Both are offered because they answer different questions. `own` keeps the
/// property the whole subsystem was built on — a calendar Mynah made, that
/// nothing else writes to, whose deletion is a complete and obvious uninstall.
/// `existing` puts the events where the owner already looks, which is the entire
/// point of mirroring them at all.
///
/// **What `existing` costs, and it is paid for in `EventKitCalendar.forget`:**
/// removing a calendar Mynah did not make would destroy the owner's own
/// appointments. So the undo splits — Mynah's own calendar is deleted whole, and
/// a calendar of theirs has exactly the events named in `CalendarLedger.events`
/// taken out of it and nothing else. Every operation already goes through an
/// event identifier this appliance wrote down itself, so it can only ever take
/// back what it put there.
public enum CalendarTarget: Hashable, Sendable, Codable {
    /// A calendar named `Mynah`, made on first use in whichever account
    /// `EventKitCalendar.writableSource()` picks. The shipped default, and what
    /// every install before 2.4 did without being asked.
    case own
    /// One of the owner's own calendars, by `EKCalendar.calendarIdentifier`.
    ///
    /// The identifier rather than the title, because two accounts are each
    /// entitled to a calendar called "Personal" and a title cannot tell them
    /// apart. It is also the thing that goes stale — the owner may delete the
    /// calendar they chose, and `EventKitCalendar.calendar()` falls back to
    /// `own` and says so rather than letting the mirror quietly stop.
    case existing(identifier: String)

    // MARK: What a screen calls it

    /// The name to show for this choice.
    ///
    /// Mynah's own is named as something that will be *made*, because on most
    /// Macs it does not exist yet and a row naming a calendar the owner cannot
    /// find in Calendar.app reads as a bug.
    public func name(among choices: [CalendarChoice]) -> String {
        switch self {
        case .own:
            return "Mynah's own calendar"
        case .existing(let identifier):
            guard let choice = choices.first(where: { $0.id == identifier }) else {
                // The owner chose it and then deleted it. Named as gone rather
                // than shown as a blank row — and meanwhile
                // `EventKitCalendar.calendar()` is falling back to Mynah's own
                // and saying so in the log, so the mirror has not stopped.
                return "A calendar that is no longer there"
            }
            return "\(choice.title) — \(choice.account)"
        }
    }

    /// What the undo says after it has run.
    ///
    /// **The two branches remove very different things and the sentence has to
    /// say which.** An owner who pointed the mirror at their own calendar and
    /// then pressed the button needs to be told their calendar is still there;
    /// "Done" would leave them opening Calendar.app to find out.
    public func removalSentence(held: Int) -> String {
        let events = "\(held) event\(held == 1 ? "" : "s")"
        switch self {
        case .own:
            return held == 0
                ? "Mynah's calendar is gone."
                : "Removed Mynah's calendar and the \(events) in it."
        case .existing:
            return held == 0
                ? "Mynah had not put anything in your calendar."
                : "Took \(events) back out of your calendar. Your calendar and everything else "
                    + "in it are untouched."
        }
    }
}

/// One calendar the owner could pick, as a screen needs it.
///
/// **A value rather than an `EKCalendar`,** so the settings screen never holds a
/// live EventKit object across a redraw — one signed-out account and the whole
/// list is dangling references.
///
/// It lives here, beside `CalendarTarget` and in a file that imports nothing but
/// Foundation, rather than inside `EventKitCalendar`. That keeps the wording in
/// `CalendarTarget.name(among:)` testable without a calendar, without a
/// permission prompt during `swift test`, and on a platform that has no EventKit
/// at all — which the Linux port will be.
public struct CalendarChoice: Identifiable, Hashable, Sendable {
    /// `EKCalendar.calendarIdentifier`, which is what `CalendarTarget` stores.
    public let id: String
    public let title: String
    /// The account it lives in — "iCloud", "Google", "On My Mac". Shown because
    /// two accounts are each entitled to a calendar called "Personal", and
    /// without this the owner is choosing between two rows with the same name.
    public let account: String

    public init(id: String, title: String, account: String) {
        self.id = id
        self.title = title
        self.account = account
    }
}

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

    /// Which calendar the events go in. See `CalendarTarget`.
    public var target: CalendarTarget

    public init(isOn: Bool = true, target: CalendarTarget = .own) {
        self.isOn = isOn
        self.target = target
    }

    // MARK: Reading a file written before this field existed

    /// **Hand-written because the synthesised one would refuse every file on
    /// disk today.** `Codable` treats a missing key as a failure, and
    /// `CalendarPreferences.load` turns a failure into the default — which is
    /// `isOn: true`, so nothing would break loudly. It would instead silently
    /// discard an owner who had turned the mirror *off*, and start writing to
    /// their calendar again on the next tick. A new field must never be able to
    /// do that.
    private enum CodingKeys: String, CodingKey {
        case isOn
        case target
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.isOn = try container.decodeIfPresent(Bool.self, forKey: .isOn) ?? true
        self.target = try container.decodeIfPresent(CalendarTarget.self, forKey: .target) ?? .own
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
