import Foundation

/// The two switches an owner with no settings screen still has to reach.
///
/// **`ProactivePreferences.update` and `PauseState.setPaused` had no caller.**
/// Both were written to be the headless way in — their own documentation says
/// so — and `grep` found them only in the tests and in `MynahMac`, which is not
/// built off Darwin. So on Linux the proactive check could be printed by
/// `sage-voiced check` and never switched on, and an appliance answering the
/// owner's phone in the middle of a meeting could not be stopped except by
/// hand-editing JSON in a directory the owner has to be told the name of.
///
/// This is the door. It lives here rather than in `main.swift` because nothing
/// can import an executable target: every line of judgement below — what the
/// words mean, what gets refused, what gets printed — is untestable the moment
/// it moves into the CLI. `runSettings` there is a shell that prints these two
/// arrays and exits with this status.
///
/// **Everything printed is read back off disk, never assumed.** A tool that
/// says "paused" because the call it made did not throw is the same failure
/// pause shipped with the first time, one layer up.
public enum HeadlessSettings {

    /// What the caller prints, and what it exits with.
    ///
    /// Two streams rather than one, because a refusal that goes to stdout is a
    /// refusal a shell pipeline swallows. The invariant is pinned by a test:
    /// **`status != 0` if and only if `problem` is non-empty** — there is no
    /// way to fail quietly through this type.
    public struct Outcome: Equatable, Sendable {
        public var output: [String]
        public var problem: [String]
        public var status: Int32

        public init(output: [String] = [], problem: [String] = [], status: Int32 = 0) {
            self.output = output
            self.problem = problem
            self.status = status
        }
    }

    /// The range is interpolated, not typed out. The floor moved once already
    /// — fifteen minutes to five — and a help text carrying the old number is a
    /// lie the compiler cannot see.
    public static var usage: String {
        """
        usage:
          sage-voiced settings                        what this appliance is set to
          sage-voiced settings proactive on|off       let Mynah check on its own, or stop it
          sage-voiced settings proactive --every N    minutes between checks \
        (\(ProactivePreferences.fastest)–\(ProactivePreferences.slowest))
          sage-voiced settings pause                  stop answering
          sage-voiced settings resume                 answer again
        """
    }

    // MARK: - What was asked for

    public enum Command: Equatable, Sendable {
        case show
        /// At least one of the two is non-nil; `parse` refuses the empty case.
        case proactive(on: Bool?, everyMinutes: Int?)
        case pause(Bool)
    }

    /// A typo, named — with the command that would have worked.
    ///
    /// Every case ends by naming the next action. An owner who has just been
    /// refused is exactly the owner with the least idea what to type next, and
    /// a refusal that stops at "no" is a dead end made out of a help message.
    public enum Misuse: Error, Equatable, Sendable {
        case unknownVerb(String)
        case nothingAfter(verb: String, extra: String)
        case unknownFlag(String)
        case everyWithoutProactive
        case everyNeedsAWholeNumber(String?)
        case proactiveNeedsAChange
        case notOnOrOff(String)
        case onAndOffTogether

        public var message: String {
            switch self {
            case .unknownVerb(let word):
                return """
                there is no `sage-voiced settings \(word)`.

                \(HeadlessSettings.usage)
                """
            case .nothingAfter(let verb, let extra):
                return """
                `sage-voiced settings \(verb)` takes nothing after it, so it is \
                not clear what `\(extra)` was meant to do and nothing has been \
                changed.
                Run `sage-voiced settings \(verb)` on its own.
                """
            case .unknownFlag(let name):
                return """
                `--\(name)` is not a flag this command takes, and it was not \
                ignored: nothing has been changed.

                \(HeadlessSettings.usage)
                """
            case .everyWithoutProactive:
                return """
                `--every` sets how often the proactive check runs, so it needs \
                the verb: `sage-voiced settings proactive --every <minutes>`. \
                Nothing has been changed.
                """
            case .everyNeedsAWholeNumber(let given):
                let head = given.map { "`\($0)` is not a number of minutes." }
                    ?? "`--every` was given nothing to set."
                return """
                \(head)
                Use a whole number of minutes between \(ProactivePreferences.fastest) \
                and \(ProactivePreferences.slowest): \
                `sage-voiced settings proactive --every 30`. Nothing has been changed.
                """
            case .proactiveNeedsAChange:
                return """
                `sage-voiced settings proactive` on its own does not say what to \
                change. Say `on`, `off`, or `--every <minutes>`.
                To see what it is set to now: `sage-voiced settings`.
                """
            case .notOnOrOff(let word):
                return """
                `\(word)` is not something `proactive` takes. Say `on`, `off`, or \
                `--every <minutes>`.
                To see what it is set to now: `sage-voiced settings`.
                """
            case .onAndOffTogether:
                return """
                `on` and `off` in the same command, so it is not clear which one \
                was meant and nothing has been changed.
                Run `sage-voiced settings proactive on` or \
                `sage-voiced settings proactive off`.
                """
            }
        }
    }

    /// Splits `--flag value`, `--switch` and bare words, by the same rule
    /// `main.swift`'s `parseFlags` uses: **a flag is never another flag's
    /// value.** Spelling it again here rather than importing it is deliberate —
    /// that function is in the executable target, where no test can reach it,
    /// and this is the copy that is covered.
    static func split(
        _ arguments: [String]
    ) -> (words: [String], flags: [String: String], switches: [String]) {
        var words: [String] = []
        var flags: [String: String] = [:]
        var switches: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("--") else {
                words.append(argument)
                index += 1
                continue
            }
            let name = String(argument.dropFirst(2))
            if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                flags[name] = arguments[index + 1]
                index += 2
            } else {
                switches.append(name)
                index += 1
            }
        }
        return (words, flags, switches)
    }

    public static func parse(_ arguments: [String]) -> Result<Command, Misuse> {
        let (words, flags, switches) = split(arguments)

        // **An unknown flag is refused, not ignored.** `--evyer 30` that leaves
        // the interval alone and prints a cheerful "proactive check: on" has
        // told the owner their appliance is set to something they did not set,
        // which is the one failure class this port is not allowed to add.
        let known: Set<String> = ["every"]
        let seen = Set(flags.keys).union(switches)
        if let stray = seen.subtracting(known).sorted().first {
            return .failure(.unknownFlag(stray))
        }

        let wantsEvery = seen.contains("every")
        guard let verb = words.first else {
            return wantsEvery ? .failure(.everyWithoutProactive) : .success(.show)
        }

        switch verb {
        case "show", "status":
            return wantsEvery ? .failure(.everyWithoutProactive) : .success(.show)

        case "pause", "resume":
            if wantsEvery { return .failure(.everyWithoutProactive) }
            if let extra = words.dropFirst().first {
                return .failure(.nothingAfter(verb: verb, extra: extra))
            }
            return .success(.pause(verb == "pause"))

        case "proactive":
            var on: Bool?
            for word in words.dropFirst() {
                switch word {
                case "on", "yes":
                    if on == false { return .failure(.onAndOffTogether) }
                    on = true
                case "off", "no":
                    if on == true { return .failure(.onAndOffTogether) }
                    on = false
                default:
                    return .failure(.notOnOrOff(word))
                }
            }

            var minutes: Int?
            if wantsEvery {
                guard let raw = flags["every"] else {
                    return .failure(.everyNeedsAWholeNumber(nil))
                }
                // `Int(_:)` and nothing cleverer. It takes ASCII digits with
                // an optional sign and refuses everything else — "30m", "5.5",
                // "5 ", "٣٠" — where a `filter`-then-parse or a
                // `NumberFormatter` would quietly turn some of those into a
                // number the owner did not type. Out of range is not this
                // refusal's business: `-5` parses here and is refused by the
                // store, which names the range.
                guard let parsed = Int(raw) else {
                    return .failure(.everyNeedsAWholeNumber(raw))
                }
                minutes = parsed
            }

            guard on != nil || minutes != nil else { return .failure(.proactiveNeedsAChange) }
            return .success(.proactive(on: on, everyMinutes: minutes))

        default:
            return .failure(.unknownVerb(verb))
        }
    }

    // MARK: - Doing it

    /// - Parameters:
    ///   - now: injected so the "quiet right now" line is not a test that fails
    ///     between 22:00 and 08:00 on the machine running it.
    public static func run(
        _ arguments: [String],
        proactiveURL: URL = ProactivePreferences.defaultFileURL(),
        pauseURL: URL = PauseState.defaultFileURL(),
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Outcome {
        switch parse(arguments) {
        case .failure(let misuse):
            // 2 rather than 1, matching `usage()`: "you typed it wrong" and
            // "the appliance refused" are different answers and a script
            // should be able to tell them apart.
            return Outcome(problem: [misuse.message], status: 2)

        case .success(.show):
            return show(proactiveURL: proactiveURL, pauseURL: pauseURL, now: now, calendar: calendar)

        case .success(.proactive(let on, let minutes)):
            return setProactive(
                on: on, everyMinutes: minutes, at: proactiveURL, now: now, calendar: calendar
            )

        case .success(.pause(let paused)):
            return setPaused(paused, at: pauseURL)
        }
    }

    private static func show(
        proactiveURL: URL, pauseURL: URL, now: Date, calendar: Calendar
    ) -> Outcome {
        var outcome = Outcome()
        do {
            let preferences = try ProactivePreferences.loadOrRefuse(from: proactiveURL)
            outcome.output += proactiveLines(
                preferences,
                at: proactiveURL,
                now: now,
                calendar: calendar,
                written: FileManager.default.fileExists(atPath: proactiveURL.path)
            )
        } catch {
            // **Not "proactive check: off".** `load` answers with the defaults
            // for a file it cannot parse, and printing those would describe a
            // factory-fresh appliance over an owner's real settings — the
            // reading being wrong in the reassuring direction.
            outcome.problem.append(describe(error))
            outcome.status = 1
        }
        // Printed even when the line above failed: one broken file must not
        // hide the state of the other.
        outcome.output += pauseLines(at: pauseURL)
        return outcome
    }

    private static func setProactive(
        on: Bool?, everyMinutes: Int?, at url: URL, now: Date, calendar: Calendar
    ) -> Outcome {
        do {
            let written = try ProactivePreferences.update(at: url) {
                if let on { $0.isOn = on }
                if let everyMinutes { $0.everyMinutes = everyMinutes }
            }
            var lines = proactiveLines(
                written, at: url, now: now, calendar: calendar, written: true
            )
            // True as of `ProactiveSchedule.tick`, which is 60 seconds, and
            // `runProactiveWatch`, which calls `ProactivePreferences.load()`
            // inside the loop rather than above it. An owner told to restart a
            // launchd job they did not know they had is a dead end.
            lines.append("The daemon re-reads that file every minute; there is nothing to restart.")
            return Outcome(output: lines)
        } catch {
            var problem = [describe(error)]
            // **A `Refusal` already ends with what to do; a filesystem error
            // does not.** `prepareDirectory` failing arrives here as
            // "The file couldn't be opened" with no path an owner can act on,
            // and a refusal that stops there is a dead end made out of an
            // error message.
            if !(error is ProactivePreferences.Refusal) {
                problem.append(
                    "Nothing was changed. The file is \(url.path) — check that "
                        + "\(url.deletingLastPathComponent().path) is a directory you can write, "
                        + "then run this again."
                )
            }
            return Outcome(problem: problem, status: 1)
        }
    }

    private static func setPaused(_ paused: Bool, at url: URL) -> Outcome {
        let pause = PauseState(fileURL: url)
        let wasPaused = pause.isPaused()
        do {
            try pause.setPaused(paused)
        } catch {
            return Outcome(
                problem: [
                    paused
                        ? "could not pause: \(describe(error))"
                        : "could not resume, so this appliance is still paused: \(describe(error))",
                    "The flag is \(url.path) — check that "
                        + "\(url.deletingLastPathComponent().path) is a directory you can write, "
                        + "then run this again.",
                ],
                status: 1
            )
        }

        // **Read back rather than reported.** Everything below describes the
        // flag as it is now, so a write that returned without doing anything
        // cannot print as success.
        let isPaused = pause.isPaused()
        guard isPaused == paused else {
            return Outcome(
                problem: [
                    "asked to \(paused ? "pause" : "resume") and the flag at \(url.path) "
                        + "\(isPaused ? "is still there" : "did not appear"), so this appliance "
                        + "is \(isPaused ? "still paused" : "still answering").",
                    "Something else is writing that file. Check it by hand, then run this again.",
                ],
                status: 1
            )
        }

        var lines = pauseLines(at: url)
        if paused {
            // Also true, and also checked: `VoiceBridgeDaemon` calls
            // `pause.isPaused()` per message rather than caching it at start.
            lines.append("The daemon checks that flag on every message, so this is in force now.")
        } else if !wasPaused {
            lines.append("It was not paused, so nothing changed.")
        }
        return Outcome(output: lines)
    }

    // MARK: - Saying what it is

    static func proactiveLines(
        _ preferences: ProactivePreferences,
        at url: URL,
        now: Date,
        calendar: Calendar,
        written: Bool
    ) -> [String] {
        var lines = ["proactive check: \(preferences.isOn ? "on" : "off")"]

        // **Both numbers when they disagree.** The file is editable by hand and
        // the floor has moved, so a stored `1` is a real state — and printing
        // only the stored one names an interval this appliance will never run
        // at, while printing only the clamped one hides what is in the file.
        if preferences.everyMinutes == preferences.clampedMinutes {
            lines.append("  every: \(minutes(preferences.clampedMinutes))")
        } else {
            lines.append(
                "  every: \(minutes(preferences.everyMinutes)) in the file, but this appliance "
                    + "checks every \(minutes(preferences.clampedMinutes)) — "
                    + "\(ProactivePreferences.fastest) to \(ProactivePreferences.slowest) "
                    + "is the range it runs at."
            )
            lines.append(
                "  set one it will use: sage-voiced settings proactive --every "
                    + "\(preferences.clampedMinutes)"
            )
        }

        if preferences.quietFrom == preferences.quietUntil {
            lines.append("  quiet hours: none")
        } else {
            let quiet = preferences.isQuiet(at: now, calendar: calendar)
            lines.append(
                "  quiet hours: \(hour(preferences.quietFrom))–\(hour(preferences.quietUntil))"
                    + (quiet ? " (quiet right now)" : "")
            )
        }

        lines.append("  file: \(url.path)" + (written ? "" : " (not written yet — these are the defaults)"))
        return lines
    }

    static func pauseLines(at url: URL) -> [String] {
        let pause = PauseState(fileURL: url)
        guard pause.isPaused() else {
            return ["answering: yes", "  file: \(url.path)"]
        }
        var head = "answering: no — paused"
        if let since = pause.pausedAt() { head += " since \(stamp(since))" }
        return [head, "  answer again with: sage-voiced settings resume", "  file: \(url.path)"]
    }

    static func minutes(_ count: Int) -> String {
        count == 1 ? "1 minute" : "\(count) minutes"
    }

    static func hour(_ value: Int) -> String {
        String(format: "%02d:00", value)
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    /// **Not `error.localizedDescription`.**
    ///
    /// `ProactivePreferences.Refusal` puts the range, the path and the next
    /// action in `errorDescription`, and reaching that through
    /// `localizedDescription` depends on a Foundation bridge that is not the
    /// same code off Darwin. A refusal that arrives as a generic sentence is
    /// this port's own worst failure class, in the very message written to
    /// prevent it, so the conformance is asked for by name.
    static func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let described = localized.errorDescription {
            return described
        }
        return "\(error)"
    }
}
