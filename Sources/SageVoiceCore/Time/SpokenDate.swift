import Foundation

/// A date the owner named, and how precisely they named it.
public struct OwnerDate: Equatable, Sendable {

    /// How exact the owner was. A day is a day: nothing here invents nine in
    /// the morning because a `Date` needs a time component.
    public enum Granularity: String, Codable, Equatable, Sendable {
        case day
        case minute
    }

    public let at: Date
    public let granularity: Granularity
    /// The owner's exact words, kept so the read-back can quote them rather
    /// than paraphrase — "you said next Wednesday, so the 5th".
    public let phrase: String

    public init(at: Date, granularity: Granularity, phrase: String) {
        self.at = at
        self.granularity = granularity
        self.phrase = phrase
    }
}

/// Turns the way people say dates into exact ones.
///
/// **Resolved from the owner's own words and never from anything the model
/// wrote.** That is the whole design and it is not a style preference: a model
/// asked to store "chiro next Wednesday" will cheerfully normalise it to a
/// specific date, be wrong, and be wrong *confidently* — and at the point of
/// storage there is no way to tell a date the owner gave from one the model
/// produced. Reading only the raw transcript makes an invented date
/// structurally impossible rather than merely unlikely.
///
/// The owner, on why this is a lookup table and not a language problem:
/// *"next wednesday means the coming wednesday - its basic logic; in 2 weeks
/// from now; next month; next week - tomorrow, day after - those are normal
/// human turn of phrases bro; its deterministic"*. He is right, and the
/// consequence is that this file is pure, total, and has no I/O and no model in
/// it. Given the same words and the same instant it returns the same answer
/// forever, which is what makes it testable at all.
///
/// ## What it deliberately will not read
///
/// - **Bare numeric dates** — "5/8" is the fifth of August to him and the
///   eighth of May to half the internet. There is no correct guess.
/// - **A bare hour** — "at 11" has two answers eleven hours apart. A time needs
///   am/pm, a colon, or a word like noon.
/// - **"morning", "evening", "later"** — those are parts of a day, not times,
///   and turning one into a clock reading would be this file inventing
///   precision the owner did not offer.
///
/// Each of those returns `.none` rather than a guess. A task with no date is a
/// task the owner can date; a task with the wrong date is one they will miss.
public enum SpokenDate {

    public enum Resolution: Equatable, Sendable {
        /// Nothing date-shaped, or something deliberately not read. See above.
        case none
        case one(OwnerDate)
        /// Two different days named in one sentence. Not resolved to the first
        /// one: "move the chiro from Wednesday to Friday" has two anchors and
        /// picking either silently is how the wrong appointment gets a
        /// reminder. The caller asks.
        case ambiguous(phrases: [String])
    }

    /// Every day-anchor found, in the order they appear, with the exact words.
    public static func resolve(
        in text: String,
        now: Date,
        calendar: Calendar = .current
    ) -> Resolution {
        let found = anchors(in: text.lowercased(), now: now, calendar: calendar)
        let distinct = found.reduce(into: [Anchor]()) { kept, anchor in
            if !kept.contains(where: { calendar.isDate($0.day, inSameDayAs: anchor.day) }) {
                kept.append(anchor)
            }
        }
        guard let first = distinct.first else { return .none }
        guard distinct.count == 1 else {
            return .ambiguous(phrases: distinct.map(\.phrase))
        }

        // A time only ever refines a day that was already named. "at 11am" on
        // its own is not a date, and treating it as today's 11am would silently
        // schedule things for a day the owner never mentioned.
        if let clock = time(in: text.lowercased()),
           let exact = calendar.date(
               bySettingHour: clock.hour,
               minute: clock.minute,
               second: 0,
               of: first.day
           ) {
            return .one(OwnerDate(at: exact, granularity: .minute, phrase: first.phrase))
        }
        return .one(OwnerDate(at: first.day, granularity: .day, phrase: first.phrase))
    }

    /// The date already written into a task's own words, if there is one.
    ///
    /// **Different job from `resolve`, and the difference is who wrote it.**
    /// `resolve` reads what the *owner* said, and refuses numeric forms because
    /// "5/8" has two readings. This reads a task title that has already been
    /// written down with the month spelled out — "Chiropractor appointment at
    /// One Spine TTDI Wednesday 5 August 2026, 11am" — which has exactly one
    /// reading and is the shape Mynah itself records.
    ///
    /// It exists so the list can be ordered by when things happen. The owner:
    /// *"i'm talking about the order in which they should be 'executed' …
    /// don't remind me about thursday on monday instead of telling me about
    /// things on tuesday / wednesday"*.
    ///
    /// Still no numeric dates. A task saying "5/8" gets no date and sorts with
    /// the undated, which is a task the owner can fix rather than a reminder
    /// three months early.
    public static func writtenDate(in text: String, calendar: Calendar = .current) -> Date? {
        writtenDateMatch(in: text, calendar: calendar)?.at
    }

    /// A date found in a title, with the two extra facts a reminder needs.
    ///
    /// Ordering only ever wanted the instant. A reminder wants two more things:
    /// whether a *time* was written — because "in about two hours" is a promise
    /// nothing can keep about a task whose title says only "Tuesday" — and where
    /// the date sat in the sentence, so the reminder can say when it is without
    /// reading the date out twice.
    public struct WrittenDate: Equatable, Sendable {
        public let at: Date
        /// A clock time was written, not just a day. `.day` means the owner
        /// named a date and no hour, and no rung may invent one.
        public let granularity: OwnerDate.Granularity
        /// The matched text, exactly as it appears in the original.
        public let text: String
    }

    static func writtenDateMatch(in text: String, calendar: Calendar = .current) -> WrittenDate? {
        let months = [
            "january": 1, "february": 2, "march": 3, "april": 4, "may": 5, "june": 6,
            "july": 7, "august": 8, "september": 9, "october": 10, "november": 11, "december": 12,
            "jan": 1, "feb": 2, "mar": 3, "apr": 4, "jun": 6, "jul": 7,
            "aug": 8, "sep": 9, "sept": 9, "oct": 10, "nov": 11, "dec": 12
        ]
        let lower = text.lowercased()
        // **Longest first, and this was a live bug rather than tidiness.**
        //
        // `months.keys` has no order — Dictionary hashing decides it, and it can
        // differ between runs. When "aug" happened to precede "august" the
        // alternation matched the short form, because regex alternation takes
        // the first branch that fits rather than the longest. "5 August 2026"
        // then matched only "5 aug", the year group never saw 2026, and the year
        // silently fell back to *the current one*.
        //
        // Invisible all year: the fallback is right whenever the task is in this
        // year, which every task on the board is. It would have started dating
        // things twelve months early on New Year's Day.
        let names = months.keys.sorted { ($0.count, $0) > ($1.count, $1) }.joined(separator: "|")
        // "5 August 2026" and "August 5 2026", each with an optional ordinal
        // suffix and an optional year.
        let patterns = [
            #"(\d{1,2})(?:st|nd|rd|th)?\s+(\#(names))\.?(?:\s+(\d{4}))?"#,
            #"(?:\#(names))\.?\s+(\d{1,2})(?:st|nd|rd|th)?(?:,?\s+(\d{4}))?"#
        ]

        for (index, pattern) in patterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower))
            else { continue }

            func group(_ at: Int) -> String? {
                guard let range = Range(match.range(at: at), in: lower) else { return nil }
                return String(lower[range])
            }

            let day: Int?
            let month: Int?
            let year: Int?
            if index == 0 {
                day = group(1).flatMap(Int.init)
                month = group(2).flatMap { months[$0.replacingOccurrences(of: ".", with: "")] }
                year = group(3).flatMap(Int.init)
            } else {
                // The month name is the literal alternation, so recover it from
                // the matched text rather than a capture group.
                let whole = Range(match.range, in: lower).map { String(lower[$0]) } ?? ""
                month = months.first { whole.hasPrefix($0.key) }?.value
                day = group(1).flatMap(Int.init)
                year = group(2).flatMap(Int.init)
            }

            guard let day, let month, (1...31).contains(day) else { continue }
            var components = DateComponents()
            components.day = day
            components.month = month
            components.year = year ?? calendar.component(.year, from: Date())
            let clock = time(in: lower)
            if let clock {
                components.hour = clock.hour
                components.minute = clock.minute
            }
            guard let date = calendar.date(from: components) else { continue }

            // Recovered from the *original* by searching for what matched,
            // rather than by reusing an index into the lowercased copy. Case
            // folding is not always length-preserving, and an offset that is
            // right for ASCII and wrong for anything else is the kind of bug
            // that only ever appears in somebody else's language.
            let matched = Range(match.range, in: lower).map { String(lower[$0]) } ?? ""
            let asWritten = text.range(of: matched, options: .caseInsensitive)
                .map { String(text[$0]) } ?? matched

            return WrittenDate(
                at: date,
                granularity: clock == nil ? .day : .minute,
                text: asWritten
            )
        }
        return nil
    }

    /// The title with its date taken out, for a reminder that is about to say
    /// when it is in its own words.
    ///
    /// *"Chiropractor appointment at One Spine TTDI Wednesday 5 August 2026,
    /// 11am"* becomes *"Chiropractor appointment at One Spine TTDI"*, so the
    /// nudge reads "in about two hours" instead of naming a date the owner is
    /// being reminded of anyway.
    ///
    /// The weekday goes too when it sits directly against the date, because
    /// "Chiropractor appointment at One Spine TTDI Wednesday" is a sentence that
    /// still claims to know when. Falls back to the whole title whenever the
    /// surgery would leave something odd — a reminder that reads a little long
    /// is fine, one that reads mangled is not.
    public static func withoutWrittenDate(in text: String, calendar: Calendar = .current) -> String {
        guard let found = writtenDateMatch(in: text, calendar: calendar),
              let span = text.range(of: found.text) else { return text }

        var kept = text
        kept.removeSubrange(span)

        // The time, when it was written separately — "…, 11am" trailing the
        // date rather than inside the matched span.
        for pattern in [#"\b\d{1,2}:\d{2}\s*(am|pm)?"#, #"\b\d{1,2}\s*(am|pm)"#, #"\b(noon|midday|midnight)\b"#] {
            if let range = kept.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                kept.removeSubrange(range)
            }
        }

        let weekdays = "monday|tuesday|wednesday|thursday|friday|saturday|sunday"
        for pattern in [#"\b(on|at)?\s*(\#(weekdays))\b,?"#, #"\s*[,–—-]\s*$"#, #"^\s*[,–—-]\s*"#] {
            while let range = kept.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                kept.removeSubrange(range)
            }
        }

        // **The preposition outlives its object.** Shipped once and read badly:
        // "Call Amy — Monday 3 August 2026 at 10:00" lost the date, then the
        // time, then the weekday — each correctly — and left "Call Amy — at",
        // which the reminder rendered as "Call Amy — at — in about 2 hours".
        //
        // Each removal above is right on its own; the word joining them to what
        // was removed is what nothing owned. Run to a fixed point, because
        // stripping one can expose another ("… on at").
        var settled = false
        while !settled {
            settled = true
            for pattern in [#"\s+(at|on|for|by)\s*$"#, #"\s*[,–—-]\s*$"#, #"\s{2,}"#] {
                if let range = kept.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                    kept.replaceSubrange(range, with: pattern == #"\s{2,}"# ? " " : "")
                    settled = false
                }
            }
        }

        let tidied = kept
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+([,.])"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ",–—- "))

        // Nothing meaningful survived, so the owner's own sentence is better
        // than the stub this produced.
        return tidied.count >= 3 ? tidied : text
    }

    // MARK: Days

    private struct Anchor {
        let day: Date
        let phrase: String
        let position: Int
    }

    private static let weekdays = [
        "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4,
        "thursday": 5, "friday": 6, "saturday": 7
    ]

    /// "friday next week", "next week on friday", "friday of next week".
    ///
    /// One anchor for one phrase. Resolved as the named weekday inside the week
    /// that follows this one, which is what somebody saying it means: on a
    /// Monday, "friday next week" is eleven days away, not four. Taking the
    /// coming Friday would put a deadline a week early — the failure that is
    /// hardest to notice, because the task looks correctly dated.
    ///
    /// Weeks are counted from the calendar's own `firstWeekday`, so this follows
    /// the owner's locale rather than an assumption about when a week starts.
    private static func weekdayOfNextWeek(
        in text: String,
        today: Date,
        calendar: Calendar
    ) -> Anchor? {
        let lower = text.lowercased()
        let names = weekdays.keys.sorted { $0.count > $1.count }.joined(separator: "|")
        let patterns = [
            #"\b(\#(names))\s+(of\s+)?next\s+week\b"#,
            #"\bnext\s+week\s*,?\s+(on\s+)?(\#(names))\b"#
        ]

        for pattern in patterns {
            guard let range = lower.range(of: pattern, options: .regularExpression) else { continue }
            let phrase = String(lower[range])
            guard let name = weekdays.keys.first(where: { phrase.contains($0) }),
                  let target = weekdays[name] else { continue }

            // Start of the week after this one, then the named day within it.
            guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: today)?.start,
                  let nextWeek = calendar.date(byAdding: .weekOfYear, value: 1, to: thisWeek),
                  let day = calendar.nextDate(
                      after: calendar.date(byAdding: .second, value: -1, to: nextWeek) ?? nextWeek,
                      matching: DateComponents(weekday: target),
                      matchingPolicy: .nextTime,
                      direction: .forward
                  )
            else { continue }

            return Anchor(
                day: calendar.startOfDay(for: day),
                phrase: phrase,
                position: lower.distance(from: lower.startIndex, to: range.lowerBound)
            )
        }
        return nil
    }

    private static let numberWords = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12
    ]

    private static func anchors(in text: String, now: Date, calendar: Calendar) -> [Anchor] {
        let today = calendar.startOfDay(for: now)
        var found: [Anchor] = []

        func add(_ phrase: String, _ day: Date?, at position: Int) {
            guard let day else { return }
            found.append(Anchor(day: day, phrase: phrase, position: position))
        }

        // **"friday next week" is one day, not two.**
        //
        // The owner asked to add something "by friday next week" and got
        // nothing: "friday" resolves to the coming Friday, "next week" to seven
        // days out, and two distinct days in one sentence is `.ambiguous` by
        // design — the rule that stops "move it from Wednesday to Friday" being
        // silently guessed at. Correct rule, wrong input: this is a single
        // English phrase naming a single day, and refusing it left a task with
        // no date at all.
        //
        // Handled here and returned immediately, so neither half is also matched
        // separately below.
        if let combined = weekdayOfNextWeek(in: text, today: today, calendar: calendar) {
            return [combined]
        }

        // Longest first, always. "day after tomorrow" contains "tomorrow", and
        // a shorter match winning would put the appointment a day early.
        let fixed: [(String, Int)] = [
            ("day after tomorrow", 2),
            ("the day after", 2),
            ("day after", 2),
            ("tomorrow", 1),
            ("tonight", 0),
            ("today", 0),
            ("next week", 7),
            ("next fortnight", 14),
            ("fortnight", 14)
        ]
        var claimed: [Range<String.Index>] = []
        for (phrase, days) in fixed {
            guard let range = text.range(of: phrase) else { continue }
            // Skip anything already inside a longer phrase that matched.
            guard !claimed.contains(where: { $0.overlaps(range) }) else { continue }
            claimed.append(range)
            add(phrase, calendar.date(byAdding: .day, value: days, to: today),
                at: text.distance(from: text.startIndex, to: range.lowerBound))
        }

        if let range = text.range(of: "next month") {
            add("next month", calendar.date(byAdding: .month, value: 1, to: today),
                at: text.distance(from: text.startIndex, to: range.lowerBound))
        }
        if let range = text.range(of: "next year") {
            add("next year", calendar.date(byAdding: .year, value: 1, to: today),
                at: text.distance(from: text.startIndex, to: range.lowerBound))
        }

        found.append(contentsOf: counted(in: text, from: today, calendar: calendar))
        found.append(contentsOf: named(in: text, from: today, calendar: calendar, claimed: claimed))

        return found.sorted { $0.position < $1.position }
    }

    /// "in 2 weeks", "in three days", "in a month", "2 weeks from now".
    private static func counted(in text: String, from today: Date, calendar: Calendar) -> [Anchor] {
        let pattern = #"(?:in\s+)?(\d+|[a-z]+)\s+(day|days|week|weeks|month|months|year|years)(?:\s+from\s+now)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let whole = NSRange(text.startIndex..., in: text)
        var found: [Anchor] = []
        for match in regex.matches(in: text, range: whole) {
            guard let countRange = Range(match.range(at: 1), in: text),
                  let unitRange = Range(match.range(at: 2), in: text),
                  let phraseRange = Range(match.range, in: text) else { continue }
            let raw = String(text[countRange])
            guard let count = Int(raw) ?? numberWords[raw] else { continue }
            let unit: Calendar.Component
            switch text[unitRange].first {
            case "d": unit = .day
            case "w": unit = .weekOfYear
            case "m": unit = .month
            default: unit = .year
            }
            guard let day = calendar.date(byAdding: unit, value: count, to: today) else { continue }
            found.append(Anchor(
                day: day,
                phrase: String(text[phraseRange]),
                position: text.distance(from: text.startIndex, to: phraseRange.lowerBound)
            ))
        }
        return found
    }

    /// **"next Wednesday" is the coming Wednesday.** The owner ruled on it, and
    /// it is the reading most people mean — the pedantic alternative ("the
    /// Wednesday after this one") is a week's error on an appointment.
    ///
    /// "this Wednesday", "on Wednesday" and a bare "Wednesday" all mean the same
    /// thing here for the same reason. Said *on* a Wednesday it means the next
    /// one, seven days out, never today: an appointment named by its weekday is
    /// one being planned, and resolving it to a day already half over is the
    /// only reading guaranteed to be useless.
    private static func named(
        in text: String,
        from today: Date,
        calendar: Calendar,
        claimed: [Range<String.Index>]
    ) -> [Anchor] {
        var found: [Anchor] = []
        for (name, weekday) in weekdays {
            guard let range = text.range(of: name) else { continue }
            guard !claimed.contains(where: { $0.overlaps(range) }) else { continue }
            var components = DateComponents()
            components.weekday = weekday
            guard let day = calendar.nextDate(
                after: today,
                matching: components,
                matchingPolicy: .nextTime,
                direction: .forward
            ) else { continue }
            // The words around it, so the read-back quotes the owner.
            let start = text.index(range.lowerBound, offsetBy: -5, limitedBy: text.startIndex)
                ?? text.startIndex
            let phrase = String(text[start..<range.upperBound])
                .trimmingCharacters(in: .whitespaces)
            found.append(Anchor(
                day: calendar.startOfDay(for: day),
                phrase: phrase.hasSuffix(name) ? phrase : name,
                position: text.distance(from: text.startIndex, to: range.lowerBound)
            ))
        }
        return found
    }

    // MARK: Times

    struct Clock: Equatable { let hour: Int; let minute: Int }

    /// "11am", "11.30am", "11:30", "3 pm", "noon", "midnight".
    ///
    /// A bare hour is refused on purpose — see the type's doc comment. "at 11"
    /// has two answers eleven hours apart and neither is safe to assume.
    static func time(in text: String) -> Clock? {
        if text.contains("midnight") { return Clock(hour: 0, minute: 0) }
        if text.contains("noon") || text.contains("midday") { return Clock(hour: 12, minute: 0) }

        let pattern = #"(\d{1,2})(?:[:.](\d{2}))?\s*(am|pm)|(\d{1,2}):(\d{2})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }

        func number(_ index: Int) -> Int? {
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            return Int(text[range])
        }

        if let hour = number(1), let meridiem = Range(match.range(at: 3), in: text) {
            guard (1...12).contains(hour) else { return nil }
            let minute = number(2) ?? 0
            guard (0...59).contains(minute) else { return nil }
            let isAfternoon = text[meridiem] == "pm"
            let adjusted = hour == 12 ? (isAfternoon ? 12 : 0) : (isAfternoon ? hour + 12 : hour)
            return Clock(hour: adjusted, minute: minute)
        }
        // 24-hour, which is unambiguous and therefore allowed.
        if let hour = number(4), let minute = number(5),
           (0...23).contains(hour), (0...59).contains(minute) {
            return Clock(hour: hour, minute: minute)
        }
        return nil
    }
}
