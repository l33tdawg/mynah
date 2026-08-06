import Foundation

// MARK: - How often it happens

/// How often a mirrored task comes round again.
///
/// **The owner's, 6 August 2026, looking at a calendar entry that said it
/// repeated and did not:** *"the repeats is not set"*. He had asked for a
/// standing Thursday call, Mynah confirmed *"the weekly recurrence is recorded
/// as a permanent fact"*, and the event landed as a one-off on 6 August with
/// `Repeat: Never` and the words "recurring weekly" sitting in its title.
///
/// Both halves of that were true and neither helped. SAGE really did record it
/// — the fact is permanent, and next week Mynah would have rolled the task
/// forward by hand. What the *calendar* got was a single event, so the alarm
/// that actually reaches his phone and watch fires once and never again, which
/// is the entire reason dated tasks are mirrored at all.
///
/// `EKRecurrenceRule` appeared nowhere in this codebase before this. The mirror
/// could only ever produce one-offs, and `tidied` treated "every, recurring
/// weekly" as *wreckage to sweep up* — the phrase was already recognised, and
/// recognised as noise.
public enum CalendarRepeat: String, Equatable, Sendable, Codable {
    case daily
    case weekly
    case fortnightly
    case monthly
    case yearly

    /// How many of `unit` between occurrences, for EventKit.
    public var interval: Int { self == .fortnightly ? 2 : 1 }

    /// What the owner said, and the text with the saying taken out.
    ///
    /// **Read from the ORIGINAL title, before the date is removed.** "every
    /// Thursday" is both a recurrence and the thing `SpokenDate` uses to place
    /// the first occurrence, so stripping it early would leave an event with a
    /// repeat and no date. `CalendarEntry.from` detects here and strips later,
    /// against the text the date has already been taken out of.
    ///
    /// Ordered longest-first: "every other week" must not be read as "every
    /// week" with a stray "other", and "every two weeks" must beat "weeks".
    public static func read(from text: String) -> (CalendarRepeat?, String) {
        let patterns: [(String, CalendarRepeat)] = [
            (#"(?i)\b(every\s+other\s+week|every\s+two\s+weeks|fortnightly|biweekly)\b"#, .fortnightly),
            (#"(?i)\b(every\s+year|yearly|annually|annual)\b"#, .yearly),
            (#"(?i)\b(every\s+month|monthly)\b"#, .monthly),
            (#"(?i)\b(every\s+day|daily)\b"#, .daily),
            // The weekday form is the one he actually used, and it is why this
            // cannot key on the word "every" alone: "every Thursday at 6pm" is a
            // weekly repeat, and the weekday is the date rather than part of the
            // rule — EventKit takes the day from the start date.
            (#"(?i)\b(every\s+(monday|tuesday|wednesday|thursday|friday|saturday|sunday))\b"#, .weekly),
            (#"(?i)\b(every\s+week|weekly|each\s+week)\b"#, .weekly)
        ]
        for (pattern, repeats) in patterns where text.range(of: pattern, options: .regularExpression) != nil {
            return (repeats, text.replacingOccurrences(
                of: pattern, with: " ", options: .regularExpression
            ))
        }
        return (nil, text)
    }

    /// The leftovers a recurrence phrase leaves in a title, in the house style
    /// of `tidied`.
    ///
    /// "Call with MT & Biniam — recurring weekly. Do not remove after" is a real
    /// title from the owner's list, and taking "weekly" out of it leaves both a
    /// dangling "recurring" and an instruction addressed to Mynah rather than to
    /// him. Neither belongs on a lock screen.
    static func tidiedAfterRemoval(_ text: String) -> String {
        var cleaned = text
        let repairs: [(String, String)] = [
            (#"(?i)\s*[—–-]?\s*\brecurring\b\s*[.,]?"#, " "),
            (#"(?i)\s*\bdo not remove( after)?\b\s*[.,]?"#, " "),
            (#"(?i)\s*\brepeats?\b\s*[.,]?\s*$"#, " ")
        ]
        for (pattern, replacement) in repairs {
            cleaned = cleaned.replacingOccurrences(
                of: pattern, with: replacement, options: .regularExpression
            )
        }
        return cleaned
    }
}

// MARK: - What belongs in the calendar

/// One dated task, as an event ought to look.
///
/// A value, not an `EKEvent`: everything that decides *what* the calendar should
/// hold is worked out here, where it can be tested without a calendar, without a
/// permission prompt and without the owner's real appointments in scope.
public struct CalendarEntry: Equatable, Sendable {
    /// The SAGE task this mirrors. The key for everything — without it a task
    /// that changes cannot be found again, and every sync would add a duplicate.
    public let taskID: String
    /// What the event is called: the task's own words with the written date
    /// taken out, because the date is the event's own field and repeating it in
    /// the title is how a calendar ends up reading "Dentist — Tuesday 4 August
    /// 2026, 1pm" on Tuesday 4 August at 1pm.
    public let title: String
    public let starts: Date
    /// True when the task named a day and no clock time. `SpokenDate` refused to
    /// invent an hour at the point of storage and this refuses to invent one
    /// here — an all-day event is the honest shape for "sometime on Tuesday".
    public let isAllDay: Bool
    /// The meeting link, taken out of the title and given the field it belongs
    /// in. A 300-character Teams URL in a calendar title is unreadable on a
    /// phone and hides the one thing the title is for.
    public let link: URL?
    /// Everything else the task said. It goes in the event's notes rather than
    /// being thrown away — the booking number and the room type matter when you
    /// arrive at the hotel, they just do not belong in the title.
    public let detail: String?
    /// How often it comes round, or `nil` for a one-off.
    ///
    /// `nil` is meaningful rather than merely absent: a task that *stops*
    /// recurring has to clear the rule off the event, so `EventKitCalendar`
    /// assigns this in both directions rather than only when it is set.
    public let repeats: CalendarRepeat?

    public init(
        taskID: String,
        title: String,
        starts: Date,
        isAllDay: Bool,
        link: URL? = nil,
        detail: String? = nil,
        repeats: CalendarRepeat? = nil
    ) {
        self.taskID = taskID
        self.title = title
        self.starts = starts
        self.isAllDay = isAllDay
        self.link = link
        self.detail = detail
        self.repeats = repeats
    }

    /// How long a timed event runs for.
    ///
    /// **A display convention, not a claim.** The owner never said how long the
    /// dentist takes, and a calendar cannot draw a zero-length event. Half an
    /// hour is short enough that it does not block out an afternoon that is
    /// actually free, and the alarm — which is the point — fires at the start
    /// either way.
    public static let timedDuration: TimeInterval = 30 * 60

    public var ends: Date { starts.addingTimeInterval(Self.timedDuration) }

    /// What was written, condensed to one string.
    ///
    /// Compared instead of the fields themselves so that "has this changed"
    /// is one cheap equality rather than a growing list of things somebody has
    /// to remember to compare. Stored in the ledger; a task whose fingerprint
    /// matches is left completely alone, which is what stops every tick from
    /// rewriting every event and making the owner's phone buzz.
    /// `repeats` is in here, and it has to be: without it a task that gains or
    /// loses its recurrence keeps the fingerprint it had, the plan calls it
    /// unchanged, and the event is left alone for ever. The owner would say
    /// "make that weekly", be told it was done, and see `Repeat: Never` — the
    /// same failure this field exists to end, one layer down.
    public var fingerprint: String {
        "\(title)|\(starts.timeIntervalSince1970)|\(isAllDay)|\(link?.absoluteString ?? "")"
            + "|\(detail ?? "")|\(repeats?.rawValue ?? "")"
    }

    /// The longest an event title gets before the rest becomes notes.
    ///
    /// Sized against the phone, which is where a calendar alert is actually
    /// read: a lock-screen notification shows about this much and then stops,
    /// so anything past it is not shortened, it is invisible.
    public static let longestTitle = 64

    /// The entry a task deserves, or `nil` when it has no date in it.
    ///
    /// Only dated tasks are mirrored. "Look into the visa thing" is a real task
    /// and belongs on the board; putting it in a calendar would mean choosing a
    /// day for it, which is exactly the invention this subsystem refuses.
    public static func from(_ task: WatchedTask, calendar: Calendar = .current) -> CalendarEntry? {
        // **The link comes out first, and the order is not cosmetic.** A Teams
        // URL contains `19%3ameeting_…`, and reading a date out of a sentence
        // that still has one in it finds "3am" inside the address — which both
        // corrupts the link and can date the event from a query string. Written
        // out before anything looks for a date, the URL cannot be misread as
        // one.
        let (link, withoutLink) = splitLink(from: task.title)
        // **Detected before the date is read, applied after.** "every Thursday"
        // is both the recurrence and the thing that places the first occurrence,
        // so taking it out now would leave a repeating event with no date to
        // repeat from — and `from` would return nil, dropping the task out of
        // the calendar altogether.
        let (repeats, _) = CalendarRepeat.read(from: withoutLink)
        guard let written = SpokenDate.writtenDateMatch(in: withoutLink, calendar: calendar) else {
            return nil
        }
        // Now the date is gone, the phrase can go too — against the remainder,
        // so what is stripped is the recurrence and never the date.
        let (_, withoutRepeat) = CalendarRepeat.read(
            from: SpokenDate.withoutWrittenDate(in: withoutLink, calendar: calendar)
        )
        let (title, detail) = split(
            tidied(CalendarRepeat.tidiedAfterRemoval(withoutRepeat))
        )
        return CalendarEntry(
            taskID: task.id,
            // A title made only of a date leaves nothing to call the event, so
            // the task's own words stand rather than an empty string.
            title: title.isEmpty ? task.title : title,
            starts: written.at,
            isAllDay: written.granularity != .minute,
            link: link,
            detail: detail,
            repeats: repeats
        )
    }

    // MARK: Making a title out of a sentence

    /// The first link in the text, and the text without it.
    static func splitLink(from text: String) -> (URL?, String) {
        guard let found = text.range(of: #"https?://\S+"#, options: .regularExpression) else {
            return (nil, text)
        }
        // Trailing punctuation belongs to the sentence, not to the address.
        let raw = String(text[found]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:)"))
        return (URL(string: raw), text.replacingCharacters(in: found, with: " "))
    }

    /// The wreckage a removed date leaves behind, cleared up.
    ///
    /// **Measured against the owner's real list, not imagined.** Taking the date
    /// out of his fifteen dated tasks produced, among others:
    ///
    ///     Call with Daniel & Tenzai —, on Google Meet.
    ///     Call with Credence at on Microsoft Teams
    ///     Call with David / Remah and TII,, Malaysian time
    ///     Call with MT & Biniam — every, recurring weekly.
    ///
    /// Each one is a preposition or a dash that used to lead into the date and
    /// now leads into nothing. It never mattered before because the ladder said
    /// these mid-sentence; a calendar puts them on a lock screen in bold.
    static func tidied(_ text: String) -> String {
        var cleaned = text
        let repairs: [(String, String)] = [
            // "at on Microsoft Teams" — two prepositions, the first belonged to
            // the date.
            (#"\b(at|on|by|from|to|for)\s+(at|on|by|from|to|for)\b"#, "$2"),
            // "must be done by, latest" and "every, recurring" — a connective
            // left hanging in front of a comma.
            (#"\s+\b(at|on|by|from|to|for|every|until|before|after)\s*(?=[,;])"#, ""),
            // ",," and "— ," and " ,"
            (#"\s*[—–-]\s*,"#, " —"),
            (#"\s*,\s*,+"#, ","),
            (#"\s+([,;.])"#, "$1"),
            (#"\s{2,}"#, " ")
        ]
        for (pattern, replacement) in repairs {
            cleaned = cleaned.replacingOccurrences(
                of: pattern, with: replacement, options: .regularExpression
            )
        }
        // And the same thing at the very end, where there is no comma to anchor
        // on: "Call with Najwa at" or "… — link:".
        cleaned = cleaned.replacingOccurrences(
            of: #"(?i)\s+\b(at|on|by|from|to|for|every|link|links)\b\s*[:.]?\s*$"#,
            with: "",
            options: .regularExpression
        )
        return cleaned.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n—–-,;:."))
    }

    /// A short title and the rest.
    ///
    /// Split at a sentence where there is one, because the first sentence of one
    /// of these is reliably the thing itself and everything after it is the
    /// booking number, the room type or where to find the link.
    static func split(_ text: String) -> (String, String?) {
        guard text.count > longestTitle else { return (text, nil) }

        if let stop = text.range(of: #"[.!?]\s+"#, options: .regularExpression),
           text.distance(from: text.startIndex, to: stop.lowerBound) <= longestTitle {
            let head = String(text[..<stop.lowerBound])
            let tail = String(text[stop.upperBound...]).trimmingCharacters(in: .whitespaces)
            return (head, tail.isEmpty ? nil : tail)
        }

        // No sentence to cut at, so cut at a word.
        let limit = text.index(text.startIndex, offsetBy: longestTitle)
        let head = text[..<limit].lastIndex(of: " ").map { text[..<$0] } ?? text[..<limit]
        let tail = String(text[head.endIndex...]).trimmingCharacters(in: .whitespaces)
        return (
            String(head).trimmingCharacters(in: CharacterSet(charactersIn: " ,;:—–-")) + "…",
            tail.isEmpty ? nil : tail
        )
    }
}

// MARK: - What the calendar already holds

/// The mapping between SAGE tasks and the events written for them.
///
/// **Without this, removal does not work and duplicates accumulate.** An event
/// this appliance wrote is indistinguishable from one the owner wrote, once it
/// is in the calendar — so the only safe way to change or delete one is to have
/// written down which is which.
public struct CalendarLedger: Codable, Equatable, Sendable {
    /// Task id to the event identifier the calendar gave back.
    public var events: [String: String]
    /// Task id to `CalendarEntry.fingerprint` as last written.
    public var written: [String: String]

    public init(events: [String: String] = [:], written: [String: String] = [:]) {
        self.events = events
        self.written = written
    }

    public static func defaultFileURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/SAGE Voice Bridge", isDirectory: true)
            .appendingPathComponent("calendar-ledger.json", isDirectory: false)
    }

    public static func load(from url: URL = CalendarLedger.defaultFileURL()) -> CalendarLedger {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(CalendarLedger.self, from: data) else {
            return CalendarLedger()
        }
        return stored
    }

    public func save(to url: URL = CalendarLedger.defaultFileURL()) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try OwnerOnlyFileSecurity.write(encoder.encode(self), to: url)
    }
}

// MARK: - Working out the difference

/// What one sync should do to the calendar.
///
/// Pure, total and separately testable, for the reason `ProactiveWatch` and
/// `ReminderLadder` are: this writes to something the owner also writes to, and
/// a rule that can only be observed by granting calendar access and waiting for
/// a tick is a rule nobody will ever check.
public enum CalendarMirror {

    public struct Plan: Equatable, Sendable {
        /// Tasks with no event yet.
        public var add: [CalendarEntry]
        /// Tasks whose event exists and no longer says the right thing. The
        /// identifier travels with it, because an update is a find-then-change.
        public var update: [(entry: CalendarEntry, eventID: String)]
        /// Event identifiers whose task is gone from the open list — finished,
        /// dropped, or no longer dated.
        public var remove: [(taskID: String, eventID: String)]

        public var isEmpty: Bool { add.isEmpty && update.isEmpty && remove.isEmpty }

        public static func == (left: Plan, right: Plan) -> Bool {
            left.add == right.add
                && left.update.map(\.eventID) == right.update.map(\.eventID)
                && left.update.map(\.entry) == right.update.map(\.entry)
                && left.remove.map(\.taskID) == right.remove.map(\.taskID)
                && left.remove.map(\.eventID) == right.remove.map(\.eventID)
        }

        public init(
            add: [CalendarEntry] = [],
            update: [(entry: CalendarEntry, eventID: String)] = [],
            remove: [(taskID: String, eventID: String)] = []
        ) {
            self.add = add
            self.update = update
            self.remove = remove
        }
    }

    /// The difference between what the task list says and what was last written.
    ///
    /// - Parameter tasks: the open tasks as the node reports them. **Never pass
    ///   an empty list for "I could not ask"** — that is the `?? []` bug from
    ///   `ProactiveWatch`, and here it would not merely go quiet, it would empty
    ///   the owner's calendar. The caller holds the optional.
    public static func plan(
        tasks: [WatchedTask],
        against ledger: CalendarLedger,
        calendar: Calendar = .current
    ) -> Plan {
        let entries = tasks.compactMap { CalendarEntry.from($0, calendar: calendar) }
        // Sorted so a plan is the same plan twice, which is what makes it worth
        // asserting on. Dictionary iteration is not ordered.
        let wanted = entries.sorted { $0.taskID < $1.taskID }
        let present = Set(wanted.map(\.taskID))

        var plan = Plan()
        for entry in wanted {
            guard let eventID = ledger.events[entry.taskID] else {
                plan.add.append(entry)
                continue
            }
            // Unchanged means untouched. Rewriting an identical event is not
            // free: it is a modification the owner's other devices sync, and on
            // a fifteen-minute tick it would be four an hour, for ever.
            guard ledger.written[entry.taskID] != entry.fingerprint else { continue }
            plan.update.append((entry, eventID))
        }
        for (taskID, eventID) in ledger.events.sorted(by: { $0.key < $1.key })
        where !present.contains(taskID) {
            plan.remove.append((taskID, eventID))
        }
        return plan
    }

    /// The ledger as it should read once a plan has been carried out.
    ///
    /// **Only what actually happened.** Both arguments carry successes, never
    /// intentions: an add that threw is left out of `written` and therefore out
    /// of the ledger, so the next tick tries it again rather than believing an
    /// event exists that does not. A remove that threw is left out of `removed`
    /// and keeps its row, because forgetting the identifier would orphan the
    /// event for ever — nothing would ever be able to delete it again.
    ///
    /// - Parameter written: task id to the event identifier it ended up with.
    /// - Parameter removed: task ids whose event is genuinely gone.
    public static func settled(
        _ ledger: CalendarLedger,
        after plan: Plan,
        written: [String: String],
        removed: Set<String>
    ) -> CalendarLedger {
        var settled = ledger
        for (taskID, _) in plan.remove where removed.contains(taskID) {
            settled.events.removeValue(forKey: taskID)
            settled.written.removeValue(forKey: taskID)
        }
        for entry in plan.add + plan.update.map(\.entry) {
            guard let eventID = written[entry.taskID] else { continue }
            settled.events[entry.taskID] = eventID
            settled.written[entry.taskID] = entry.fingerprint
        }
        return settled
    }
}
