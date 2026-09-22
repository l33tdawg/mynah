import Foundation

/// `//schedule`: the owner putting work on a clock.
///
/// ## Why a command and not a tool
///
/// The obvious design is a tool the model calls when the owner asks for this in
/// conversation, and it is the design this appliance uses for everything else it
/// can do — `sage_task`, `send_file`, `after_the_call`. It is refused here for
/// two reasons, and the second is the one that decides it.
///
/// **The catalogue is full, by measurement.** `PromptLatencyBudgetTests
/// .voiceCatalogueBudget` is 21 and `BrainPrompts.voiceToolAllowlist.count` is
/// 21: routing on the shipped 4B was measured at composed 21 → 10/12, and the
/// ratchet exists so that adding to it costs a re-run of
/// `scripts/measure-tool-routing.py` rather than an argument. A tool here would
/// have to be paid for out of a budget nobody has measured room in — and the
/// thing being bought is a message on the owner's phone, which is the last place
/// to spend accuracy nobody has counted.
///
/// **And a command cannot be reached by accident.** `CallInvitation` made this
/// ruling first, for the microphone: *"an explicit `//call` cannot be reached by
/// accident or by a model misreading a sentence."* Standing work is the same
/// class of thing and a heavier version of it — it makes the appliance speak
/// first, repeatedly, for as long as it stands, on a clock the owner set. A
/// model that misreads *"I check my inbox every morning, it's a nightmare"* and
/// books one is a stranger messaging him at eight o'clock for the rest of the
/// year. So the sentence that creates one is his, typed on purpose, and the
/// reading of it is done by code that is total and testable rather than by a
/// language model on the one input where a wrong guess never stops.
///
/// ## What that costs, said plainly
///
/// Mynah cannot set one of these up from a request. It can *answer* about them —
/// the list rides every turn, see `ScheduledWork.note` — and it points at
/// `//schedule`, which is the same shape as `//call` refuses and for the same
/// reason. If that turns out to be the wrong trade, the tool is a small piece of
/// work and the measurement is the price.
///
/// ## The reading
///
/// Deterministic, from the owner's own words, in the spirit of `SpokenDate`:
/// a recurrence phrase, a separator, and the work itself kept verbatim. A bare
/// hour is refused rather than guessed — "at 8" is the eighth hour to half the
/// world and the twentieth to the other half — which is the one refusal here
/// that will annoy somebody once and then never again.
public enum ScheduledWorkCommand {

    /// What the owner types. Anchored, so a message that merely mentions it —
    /// "how do I use //schedule" — is a question, not a command.
    public static let command = "//schedule"

    /// The list, on its own word, because "//schedule" with nothing after it is
    /// the moment somebody is wondering what they already have.
    public static let listCommand = "//schedules"

    /// The longest instruction that will be kept.
    ///
    /// A bound rather than a policy: the instruction is a prompt that runs
    /// unattended and is read back into the model's turn forever, so an
    /// accidental page-paste should be refused at the door with a sentence
    /// rather than discovered as a slow appliance.
    public static let maximumInstructionCharacters = 600

    public static func isRequest(_ transcript: String) -> Bool {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed == command || trimmed.hasPrefix(command + " ")
            || trimmed == listCommand || trimmed.hasPrefix(listCommand + " ")
    }

    // MARK: What a message is

    public enum Request: Equatable, Sendable {
        case create(instruction: String, cadence: ScheduleCadence)
        case list
        case cancel(Int)
        case pause(Int)
        case resume(Int)
        /// `//schedule` with nothing after it.
        case usage
    }

    /// A request, or the sentence the owner gets instead. Both are answers; the
    /// caller sends whichever it is.
    public enum Reading: Equatable, Sendable {
        case request(Request)
        case refused(String)
    }

    /// `nil` when this is not a schedule command at all.
    public static func read(_ transcript: String) -> Reading? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        guard isRequest(trimmed) else { return nil }

        if lowered == listCommand || lowered.hasPrefix(listCommand + " ") {
            return .request(.list)
        }

        let body = String(trimmed.dropFirst(command.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return .request(.usage) }

        if ["list", "all", "show"].contains(body.lowercased()) {
            return .request(.list)
        }

        if let (verb, number) = verbAndNumber(in: body) {
            guard let number else { return .refused(whichOne) }
            switch verb {
            case .cancel: return .request(.cancel(number))
            case .pause: return .request(.pause(number))
            case .resume: return .request(.resume(number))
            }
        }

        guard let halves = split(whenAndWhat: body) else { return .refused(needASeparator) }
        guard !halves.what.isEmpty else { return .refused(needTheWork) }
        guard halves.what.count <= maximumInstructionCharacters else { return .refused(tooLong) }

        switch cadence(in: halves.when) {
        case .read(let cadence):
            return .request(.create(instruction: halves.what, cadence: cadence))
        case .refused(let sentence):
            return .refused(sentence)
        }
    }

    // MARK: Doing it

    /// Carries the request out and returns exactly what to send back.
    ///
    /// Writes are refused while the appliance is paused, and that is a real
    /// decision rather than a side effect of where the check sits in the daemon:
    /// paused means the owner has said *not now*, and quietly accepting work he
    /// will then not see run is the failure this whole feature exists to end.
    /// Reading the list is allowed either way — a question costs nothing.
    public static func perform(
        _ reading: Reading,
        at url: URL = ScheduledWork.defaultFileURL(),
        now: Date = Date(),
        isPaused: Bool = false
    ) -> String {
        switch reading {
        case .refused(let sentence):
            return sentence
        case .request(.usage):
            return usage
        case .request(.list):
            return listing(ScheduledWork.load(from: url))
        case .request(.create(let instruction, let cadence)):
            guard !isPaused else { return paused }
            var work = ScheduledWork.load(from: url)
            guard work.tasks.count < ScheduledWork.maximumTasks else {
                return "I'm already holding \(ScheduledWork.maximumTasks) pieces of scheduled work, "
                    + "which is as many as I keep. Stop one first — //schedules lists them."
            }
            let task = work.add(instruction: instruction, cadence: cadence, now: now)
            do {
                try work.save(to: url)
            } catch {
                return "I couldn't write that down, so nothing was scheduled: "
                    + "\(error.localizedDescription)"
            }
            let number = work.numbered().first { $0.task.id == task.id }?.number ?? work.tasks.count
            return created(task, number: number)
        case .request(.cancel(let number)):
            return change(at: url, number: number, isPaused: isPaused) { work, task in
                _ = work.remove(number: number)
                return "Stopped — “\(task.summary)” won't run again. "
                    + "\(work.tasks.count == 1 ? "1 left" : "\(work.tasks.count) left")."
            }
        case .request(.pause(let number)):
            return change(at: url, number: number, isPaused: isPaused) { work, task in
                _ = work.pause(number: number)
                return "Held — “\(task.summary)” won't run until you say "
                    + "\(command) resume \(number)."
            }
        case .request(.resume(let number)):
            return change(at: url, number: number, isPaused: isPaused) { work, task in
                guard !task.isEnabled else {
                    return "That one is already running — “\(task.summary)”."
                }
                _ = work.resume(number: number, now: now)
                return "Running again — “\(task.summary)”."
            }
        }
    }

    /// The three verbs that change one row, which differ only in what they do to
    /// it. Split out so the paused check, the missing-number sentence and the
    /// write-failure sentence exist once rather than three times.
    private static func change(
        at url: URL,
        number: Int,
        isPaused: Bool,
        _ edit: (inout ScheduledWork, ScheduledTask) -> String
    ) -> String {
        guard !isPaused else { return paused }
        var work = ScheduledWork.load(from: url)
        guard let task = work.task(number: number) else {
            return "There's no \(number) in the list. \(listCommand) shows them, numbered."
        }
        let sentence = edit(&work, task)
        do {
            try work.save(to: url)
        } catch {
            return "I couldn't write that down, so nothing changed: \(error.localizedDescription)"
        }
        return sentence
    }

    // MARK: What it says

    static func created(_ task: ScheduledTask, number: Int) -> String {
        """
        Scheduled. \(task.cadence.spoken.capitalisedFirst) I'll do this — \
        \(ScheduledWork.flattened(task.instruction))

        It's number \(number). \(listCommand) shows them all, \(command) cancel \(number) \
        stops this one.
        """
    }

    static func listing(_ work: ScheduledWork) -> String {
        let numbered = work.numbered()
        guard !numbered.isEmpty else {
            return """
                Nothing is scheduled. Set something up with:

                \(command) every day at 8am: check my inbox and tell me what's waiting

                I'll run it on that clock and message you here, whether or not you're talking \
                to me.
                """
        }
        let lines = numbered.map { entry in
            "\(entry.number). \(entry.task.summary)\(entry.task.isEnabled ? "" : " (held)")"
        }
        return """
            Scheduled work:

            \(lines.joined(separator: "\n"))

            \(command) cancel <number> stops one, \(command) pause <number> holds it for a \
            while, \(command) resume <number> starts it again.
            """
    }

    /// What `//help` says about this, in its own voice.
    ///
    /// **The only place a command like this can announce itself**, in
    /// `CallInvitation`'s words — the owner is in a Signal thread, not reading a
    /// README, and this is the moment somebody wonders whether there is one.
    public static var helpLines: String {
        """
        \(command) <when>: <what to do> — standing work I run on a clock and message you \
        about, whether or not you're talking to me. For example: \(command) every day at 8am: \
        check my inbox and tell me what's waiting. \(listCommand) lists what you have set up, \
        and \(command) cancel <number> stops one.
        """
    }

    static let usage = """
        Scheduled work runs on a clock and messages you here. Set it up with:

        \(command) every day at 8am: check my inbox and tell me what's waiting

        What I can read: every day at <time>, every <weekday> at <time>, or every <number> \
        of minutes. \(listCommand) lists what you already have.
        """

    static let needASeparator = """
        I couldn't tell where the time ends and the work begins. Put a colon between them — \
        \(command) every day at 8am: check my inbox and tell me what's waiting
        """

    static let needTheWork = """
        I read a time but not what to do. Say what to do after the colon — \
        \(command) every day at 8am: check my inbox and tell me what's waiting
        """

    static let needAWhen = """
        I couldn't read when to do that. What I can read is "every day at 8am", \
        "every Monday at 9:30am" or "every 30 minutes" — for example \
        \(command) every day at 8am: check my inbox and tell me what's waiting
        """

    static let needATime = """
        I need a time with that — "every day at 8am", or "every Monday at 9:30am". A bare \
        hour like "at 8" I won't guess at, so say am or pm.
        """

    static let tooLong = "That's longer than I'll keep for one piece of scheduled work — "
        + "keep it under \(maximumInstructionCharacters) characters and say the rest as it comes up."

    static let whichOne = "Which one? \(listCommand) shows them numbered — then say "
        + "\(command) cancel 2, for example."

    static let paused = "I'm paused, so I won't change your scheduled work. Turn me back on "
        + "in Mynah and send that again."

    // MARK: Reading the owner's words

    private enum Verb {
        case cancel, pause, resume
    }

    /// Words that stand in for a number without being one. "cancel it" is the
    /// owner talking about the line he has just read, and there is no number in
    /// it to act on — guessing "the first one" would stop work he did not name.
    private static let pronouns: Set<String> = ["it", "that", "this", "them", "those"]

    /// The verbs that act on a row, and the number after them if there is one.
    ///
    /// **A body that merely starts with one of these words is a request to
    /// create.** "//schedule hold the fort at 9am: …" is not a pause, and the
    /// else-branch falls through to the reading that will tell him what it could
    /// not understand about the cadence — which is a better answer than "which
    /// one?".
    private static func verbAndNumber(in body: String) -> (Verb, Int?)? {
        let table: [(Verb, [String])] = [
            (.cancel, ["cancel", "stop", "remove", "delete", "drop"]),
            (.pause, ["pause", "hold"]),
            (.resume, ["resume", "start", "unpause"])
        ]
        let lowered = body.lowercased()
        for (verb, words) in table {
            for word in words where lowered == word || lowered.hasPrefix(word + " ") {
                let tail = String(lowered.dropFirst(word.count))
                    .replacingOccurrences(of: "#", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if let number = Int(tail) { return (verb, number) }
                guard tail.isEmpty || pronouns.contains(tail) else { continue }
                return (verb, nil)
            }
        }
        return nil
    }

    /// The recurrence phrase, and the work, split on the first separator.
    ///
    /// A colon, unless it is a clock reading — `8:30` is part of the time, and
    /// splitting there would leave the owner's work starting mid-hour. A dash
    /// counts when it stands alone, because "every day at 8 — check the inbox"
    /// is how somebody types this on a phone keyboard.
    static func split(whenAndWhat body: String) -> (when: String, what: String)? {
        let characters = Array(body)
        for index in characters.indices {
            let character = characters[index]
            let before = index > 0 ? characters[index - 1] : nil
            let after = index + 1 < characters.count ? characters[index + 1] : nil

            let isSeparator: Bool
            switch character {
            case ":":
                isSeparator = !(before?.isNumber ?? false && after?.isNumber ?? false)
            case "—", "–", "-":
                isSeparator = (before?.isWhitespace ?? true) && (after?.isWhitespace ?? true)
            default:
                isSeparator = false
            }
            guard isSeparator else { continue }

            let when = String(characters[..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
            let what = String(characters[(index + 1)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return (when, what)
        }
        return nil
    }

    /// A "when" that was read, or the sentence explaining what could not be.
    ///
    /// An enum rather than `Result`, whose failure type would have to be an
    /// `Error`: what comes back on failure is not something to throw and catch,
    /// it is exactly the words the owner is owed.
    enum WhenReading: Equatable {
        case read(ScheduleCadence)
        case refused(String)
    }

    /// The owner's "when", read exactly, or the sentence explaining what could
    /// not be read.
    static func cadence(in phrase: String) -> WhenReading {
        let text = phrase.lowercased()

        if let minutes = intervalMinutes(in: text) {
            guard (ScheduleCadence.fastestEveryMinutes...ScheduleCadence.slowestEveryMinutes)
                .contains(minutes)
            else {
                return .refused(
                    "Every \(ScheduleCadence.spokenInterval(minutes)) is outside what I'll do — "
                        + "the fastest is every \(ScheduleCadence.fastestEveryMinutes) minutes, "
                        + "and past a day I'd rather have a time of day."
                )
            }
            return .read(.every(minutes: minutes))
        }

        if let weekday = weekday(in: text), text.contains("every") {
            guard let clock = SpokenDate.time(in: text) else { return .refused(needATime) }
            return .read(.weekly(weekday: weekday, hour: clock.hour, minute: clock.minute))
        }

        if text.contains("every day") || text.contains("daily") || daypart(in: text) != nil {
            guard let clock = SpokenDate.time(in: text) else { return .refused(needATime) }
            return .read(.daily(hour: clock.hour, minute: clock.minute))
        }

        return .refused(needAWhen)
    }

    /// "every 30 minutes", "every 2 hours", "every half hour", "hourly".
    static func intervalMinutes(in text: String) -> Int? {
        if text.contains("hourly") { return 60 }
        if matches(text, #"\bevery\s+half\s+(an\s+)?hour\b"#) { return 30 }
        if matches(text, #"\bevery\s+(an\s+)?hour\b"#) { return 60 }
        if matches(text, #"\bevery\s+minute\b"#) { return 1 }
        if let minutes = firstNumber(in: text, pattern: #"\bevery\s+(\d+)\s*(minutes?|mins?)\b"#),
           minutes > 0 {
            return minutes
        }
        if let hours = firstNumber(in: text, pattern: #"\bevery\s+(\d+)\s*(hours?|hrs?)\b"#),
           hours > 0 {
            return hours * 60
        }
        return nil
    }

    /// The dayparts that are filler in "every morning at 8am" and a refusal in
    /// "every morning".
    ///
    /// Recognised only so that the *refusal* is the useful one. A part of a day
    /// is not a time — `SpokenDate` refuses to turn one into a clock reading for
    /// the same reason — so this changes which sentence comes back, never
    /// whether a time was read.
    static func daypart(in text: String) -> String? {
        ["morning", "afternoon", "evening", "night", "midday"].first {
            matches(text, "\\b\($0)\\b")
        }
    }

    static func weekday(in text: String) -> Int? {
        let names = [
            "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4,
            "thursday": 5, "friday": 6, "saturday": 7
        ]
        return names
            .filter { matches(text, "\\b\($0.key)\\b") }
            // Sorted so a phrase naming two weekdays reads the same way twice.
            .sorted { $0.key < $1.key }
            .first?.value
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func firstNumber(in text: String, pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return Int(text[range])
    }
}

extension String {
    /// "every day at 08:00" → "Every day at 08:00", for the one place this
    /// appliance starts a sentence with a cadence.
    var capitalisedFirst: String {
        guard let first else { return self }
        return first.uppercased() + String(dropFirst())
    }
}
