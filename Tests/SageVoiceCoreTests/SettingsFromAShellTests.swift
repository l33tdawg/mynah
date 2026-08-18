import XCTest
@testable import SageVoiceCore

// `geteuid()`, `chflags()` and `dlsym()` are libc, and nothing re-exports them
// off Darwin.
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// `sage-voiced settings`, which is the whole of the appliance's controls on a
/// machine with no Mac app.
///
/// `SettingsWithoutTheMacTests` covers the two stores underneath. This covers
/// the command an owner actually types: what it refuses, what it prints, and —
/// the property both of those exist for — that **it never reports a state the
/// files on disk do not have.**
final class SettingsFromAShellTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("settings-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var proactiveURL: URL {
        root.appendingPathComponent("proactive-preferences.json", isDirectory: false)
    }

    private var pauseURL: URL { root.appendingPathComponent("paused", isDirectory: false) }

    private func run(_ arguments: [String], now: Date = Date()) -> HeadlessSettings.Outcome {
        HeadlessSettings.run(
            arguments,
            proactiveURL: proactiveURL,
            pauseURL: pauseURL,
            now: now,
            calendar: Self.utc
        )
    }

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func at(hour: Int) -> Date {
        Self.utc.date(from: DateComponents(year: 2026, month: 8, day: 18, hour: hour, minute: 0))!
    }

    // MARK: - Saying what the appliance is set to

    /// A fresh appliance, described. The paths are in the output because a tool
    /// that says "off" without saying which file it read cannot be checked
    /// against the daemon that reads it — and that disagreement is how pause
    /// managed to be a lie the first time.
    func testBareSettingsSaysWhatIsSetAndWhichFilesItRead() {
        let outcome = run([])

        XCTAssertEqual(outcome.status, 0)
        XCTAssertEqual(outcome.problem, [])
        XCTAssertTrue(outcome.output.contains("proactive check: off"), "\(outcome.output)")
        XCTAssertTrue(outcome.output.contains("  every: 60 minutes"), "\(outcome.output)")
        XCTAssertTrue(outcome.output.contains("answering: yes"), "\(outcome.output)")
        XCTAssertTrue(
            outcome.output.contains { $0.contains(proactiveURL.path) },
            "the proactive file is not named: \(outcome.output)"
        )
        XCTAssertTrue(
            outcome.output.contains { $0.contains(pauseURL.path) },
            "the pause flag is not named: \(outcome.output)"
        )
    }

    /// **The confident lie, in its cheapest form.** `ProactivePreferences.load`
    /// answers with the defaults for a file it cannot parse, so a status page
    /// built on it prints "proactive check: off" over an owner's real settings
    /// — wrong in the reassuring direction, and unfalsifiable from the output.
    func testAnUnreadableFileIsNotPrintedAsAFactoryFreshAppliance() throws {
        try Data("{ this was a settings file once".utf8).write(to: proactiveURL)

        let outcome = run([])

        XCTAssertEqual(outcome.status, 1)
        XCTAssertFalse(
            outcome.output.contains { $0.hasPrefix("proactive check:") },
            "a file that could not be read was described anyway: \(outcome.output)"
        )
        XCTAssertTrue(
            outcome.problem.contains { $0.contains(proactiveURL.path) },
            "the refusal does not name the file: \(outcome.problem)"
        )
        // One broken file must not hide the other switch.
        XCTAssertTrue(outcome.output.contains("answering: yes"), "\(outcome.output)")
    }

    /// A stored interval outside the range is a real state — the file is
    /// editable by hand and the floor moved from fifteen to five. Printing only
    /// the stored number names an interval this appliance will never run at;
    /// printing only the clamped one hides what is in the file. Both, and the
    /// command that fixes it.
    func testAStoredIntervalTheApplianceWillNotUseIsPrintedAsBothNumbers() throws {
        try Data(#"{"everyMinutes":1,"isOn":true,"quietFrom":0,"quietUntil":0}"#.utf8)
            .write(to: proactiveURL)

        let outcome = run([])
        let interval = try XCTUnwrap(outcome.output.first { $0.hasPrefix("  every:") })

        XCTAssertTrue(interval.contains("1 minute"), interval)
        XCTAssertTrue(interval.contains("5 minutes"), interval)
        XCTAssertTrue(
            outcome.output.contains { $0.contains("--every 5") },
            "no command that would fix it: \(outcome.output)"
        )
    }

    func testQuietHoursAreSaidToBeInForceWhenTheyAre() throws {
        // Deliberately not 22–08: `ProactivePreferences.withoutTheOldNightDefault`
        // strips exactly that pair, because 1.2.8 wrote it as a default nobody
        // chose. A test using it would be testing the migration.
        try Data(#"{"everyMinutes":60,"isOn":true,"quietFrom":23,"quietUntil":7}"#.utf8)
            .write(to: proactiveURL)

        let night = try XCTUnwrap(
            run([], now: at(hour: 2)).output.first { $0.contains("quiet hours:") }
        )
        XCTAssertTrue(night.contains("23:00"), night)
        XCTAssertTrue(night.contains("07:00"), night)
        XCTAssertTrue(night.contains("quiet right now"), night)

        let day = try XCTUnwrap(
            run([], now: at(hour: 11)).output.first { $0.contains("quiet hours:") }
        )
        XCTAssertFalse(day.contains("quiet right now"), day)
    }

    // MARK: - Turning the proactive check on, with no screen to do it from

    /// The feature, end to end: the owner types the command, and the next
    /// process to read that file — the daemon, through its own forgiving read —
    /// sees it on.
    func testTurningTheCheckOnIsVisibleToTheReadTheDaemonActuallyDoes() {
        let outcome = run(["proactive", "on", "--every", "30"])

        XCTAssertEqual(outcome.status, 0, "\(outcome.problem)")
        XCTAssertTrue(outcome.output.contains("proactive check: on"), "\(outcome.output)")
        XCTAssertTrue(outcome.output.contains("  every: 30 minutes"), "\(outcome.output)")

        let asTheDaemonSeesIt = ProactivePreferences.load(from: proactiveURL)
        XCTAssertTrue(asTheDaemonSeesIt.isOn, "the daemon cannot tell it was turned on")
        XCTAssertEqual(asTheDaemonSeesIt.clampedMinutes, 30)
    }

    /// An owner who has just changed a setting needs to know whether anything
    /// has to be restarted. `runProactiveWatch` calls `ProactivePreferences
    /// .load()` inside its loop, on a sixty-second tick, so the answer is no —
    /// and saying nothing leaves them looking for a launchd job.
    func testTheOwnerIsToldTheDaemonPicksItUpWithoutARestart() {
        let outcome = run(["proactive", "on"])
        XCTAssertTrue(
            outcome.output.contains { $0.lowercased().contains("restart") },
            "nothing says whether the daemon has to be restarted: \(outcome.output)"
        )
    }

    /// A tool that accepts `1` and runs at `5` has told the owner something
    /// untrue about their own appliance. The refusal names the range, names the
    /// file, and nothing is written.
    /// `-5` is here rather than with the unparseable ones on purpose: it *is*
    /// a whole number, so it is the range that refuses it and not the parser,
    /// and the two exit with different codes because a script should be able to
    /// tell "you typed it wrong" from "the appliance refused".
    func testAnIntervalOutsideTheRangeIsRefusedAndNothingIsWritten() {
        for minutes in ["1", "-5", "\(ProactivePreferences.slowest + 1)"] {
            let refused = run(["proactive", "--every", minutes])
            XCTAssertEqual(refused.status, 1, "\(minutes) exited \(refused.status)")
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: proactiveURL.path),
                "\(minutes) was written"
            )
        }

        let outcome = run(["proactive", "--every", "1"])

        XCTAssertEqual(outcome.status, 1)
        let said = outcome.problem.joined(separator: "\n")
        XCTAssertTrue(said.contains("\(ProactivePreferences.fastest)"), said)
        XCTAssertTrue(said.contains("\(ProactivePreferences.slowest)"), said)
        XCTAssertTrue(said.contains(proactiveURL.path), said)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: proactiveURL.path),
            "a refused interval was written anyway"
        )
    }

    /// **The refusal has to survive the trip.** `Refusal.errorDescription`
    /// carries the range and the path; reaching it through
    /// `localizedDescription` goes through a Foundation bridge that is not the
    /// same code off Darwin, and a refusal that arrives as a generic sentence
    /// is this port's own failure class inside the message written to prevent
    /// it.
    func testTheRefusalTextIsTheOneTheStoreWrote() {
        let refusal = ProactivePreferences.Refusal.intervalOutOfRange(minutes: 1, path: "/x/y.json")
        XCTAssertEqual(HeadlessSettings.describe(refusal), refusal.errorDescription)
        XCTAssertTrue(HeadlessSettings.describe(refusal).contains("/x/y.json"))
    }

    /// A dead end would be worse than the bad value: a file carrying a
    /// hand-edited `1` must not make it impossible to switch the feature off.
    func testTurningItOffIsNotBlockedByAnIntervalNobodyChose() throws {
        try Data(#"{"everyMinutes":1,"isOn":true,"quietFrom":0,"quietUntil":0}"#.utf8)
            .write(to: proactiveURL)

        let outcome = run(["proactive", "off"])

        XCTAssertEqual(outcome.status, 0, "\(outcome.problem)")
        XCTAssertFalse(ProactivePreferences.load(from: proactiveURL).isOn)
        XCTAssertEqual(
            ProactivePreferences.load(from: proactiveURL).everyMinutes,
            1,
            "an interval nobody touched was rewritten"
        )
    }

    /// A write that cannot happen must not print as one that did. The directory
    /// is made impossible by putting an ordinary file where it would have to
    /// go — no privileges needed, same behaviour on both platforms.
    func testAWriteThatCannotHappenIsReportedRatherThanCelebrated() throws {
        let blocker = root.appendingPathComponent("blocked", isDirectory: false)
        try Data("not a directory".utf8).write(to: blocker)

        let outcome = HeadlessSettings.run(
            ["proactive", "on"],
            proactiveURL: blocker.appendingPathComponent("proactive-preferences.json"),
            pauseURL: pauseURL
        )

        XCTAssertEqual(outcome.status, 1)
        XCTAssertFalse(
            outcome.output.contains { $0.hasPrefix("proactive check:") },
            "a write that failed printed a state anyway: \(outcome.output)"
        )
        // A raw filesystem error is not a refusal an owner can act on: it names
        // neither the file nor anything to try. `Refusal` writes its own next
        // action; this path has to be given one.
        let said = outcome.problem.joined(separator: "\n")
        XCTAssertTrue(said.contains(blocker.path), "nothing to act on: \(said)")
        XCTAssertTrue(said.lowercased().contains("nothing was changed"), said)
    }

    // MARK: - Pause, from a shell

    func testPauseAndResumeMoveTheFlagTheDaemonReads() {
        let paused = run(["pause"])
        XCTAssertEqual(paused.status, 0, "\(paused.problem)")
        XCTAssertTrue(paused.output.contains { $0.hasPrefix("answering: no") }, "\(paused.output)")
        XCTAssertTrue(PauseState(fileURL: pauseURL).isPaused(), "the daemon still sees it answering")

        let resumed = run(["resume"])
        XCTAssertEqual(resumed.status, 0, "\(resumed.problem)")
        XCTAssertTrue(resumed.output.contains("answering: yes"), "\(resumed.output)")
        XCTAssertFalse(PauseState(fileURL: pauseURL).isPaused(), "the daemon still sees it paused")
    }

    /// A pause the owner cannot undo is the worse half of this feature, so the
    /// way back is printed at the moment they are paused.
    func testAPausedApplianceSaysHowToStartAnsweringAgain() {
        let outcome = run(["pause"])
        XCTAssertTrue(
            outcome.output.contains { $0.contains("sage-voiced settings resume") },
            "no way back is offered: \(outcome.output)"
        )
    }

    /// **`resume` used to be a `try?` one layer down.** The removal can fail —
    /// a state directory the owner cannot write — and a tool that printed
    /// "answering: yes" over a flag that is still there would leave them
    /// waiting on an appliance that stays silent. Permission is taken off the
    /// directory, which is the real case and needs no privileges.
    ///
    /// **This test used to skip under root**, and root is the only user the
    /// Linux container has, so on the one Linux this port is tested on the
    /// failure path of the only pause control an off-Darwin owner has was never
    /// run. `removalsMadeImpossible(in:)` gives the bypass up instead of
    /// skipping; see it for why that is not a trick.
    func testAResumeThatCannotClearTheFlagSaysTheApplianceIsStillPaused() throws {
        let holder = root.appendingPathComponent("read-only", isDirectory: true)
        try FileManager.default.createDirectory(at: holder, withIntermediateDirectories: true)
        let marker = holder.appendingPathComponent("paused", isDirectory: false)
        try Data().write(to: marker)
        let putItBack = try removalsMadeImpossible(in: holder)
        defer { putItBack() }

        let outcome = HeadlessSettings.run(
            ["resume"], proactiveURL: proactiveURL, pauseURL: marker
        )

        XCTAssertEqual(outcome.status, 1)
        XCTAssertFalse(
            outcome.output.contains("answering: yes"),
            "a failed resume printed as success: \(outcome.output)"
        )
        let said = outcome.problem.joined(separator: "\n")
        XCTAssertTrue(said.lowercased().contains("still paused"), said)
        XCTAssertTrue(said.contains(marker.path), said)
        XCTAssertTrue(PauseState(fileURL: marker).isPaused())
    }

    /// Not an error — the Mac app reconciles its saved preference on every
    /// launch by calling exactly this — but the owner is told nothing changed
    /// rather than being left to think they just stopped something.
    func testResumingSomethingThatWasNotPausedSaysNothingChanged() {
        let outcome = run(["resume"])

        XCTAssertEqual(outcome.status, 0, "\(outcome.problem)")
        XCTAssertTrue(outcome.output.contains("answering: yes"), "\(outcome.output)")
        XCTAssertTrue(
            outcome.output.contains { $0.lowercased().contains("not paused") },
            "\(outcome.output)"
        )
    }

    // MARK: - Typos

    /// **An unknown flag is refused, not ignored.** A misspelling that leaves
    /// the interval alone and still prints "proactive check: on" has told the
    /// owner their appliance is set to something they did not set.
    func testAMisspelledFlagIsRefusedRatherThanIgnored() {
        let outcome = run(["proactive", "on", "--evyer", "30"])

        XCTAssertEqual(outcome.status, 2)
        XCTAssertTrue(outcome.problem.joined().contains("--evyer"), "\(outcome.problem)")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: proactiveURL.path),
            "a command that was refused wrote the file anyway"
        )
    }

    /// `--every` is not a global: `sage-voiced settings --every 30` is a
    /// half-typed command, and answering it with the status page would look
    /// like it worked.
    func testEveryWithoutTheVerbIsRefusedRatherThanShowingTheStatusPage() {
        for arguments in [["--every", "30"], ["pause", "--every", "30"]] {
            let outcome = run(arguments)
            XCTAssertEqual(outcome.status, 2, "\(arguments)")
            XCTAssertTrue(outcome.problem.joined().contains("proactive"), "\(outcome.problem)")
            XCTAssertFalse(
                PauseState(fileURL: pauseURL).isPaused(),
                "a refused command paused the appliance"
            )
        }
    }

    func testAnIntervalThatIsNotAWholeNumberIsRefusedRatherThanReadAsZero() {
        for raw in ["thirty", "30m", "5.5", "5 ", "", "٣٠"] {
            let outcome = run(["proactive", "--every", raw])
            XCTAssertEqual(outcome.status, 2, "'\(raw)' was accepted")
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: proactiveURL.path),
                "'\(raw)' was written"
            )
        }
    }

    /// **A refusal must not say something untrue about the command surface.**
    /// `settings pause resume` answered "there is no `sage-voiced settings
    /// resume`" while `resume` was sitting in the same switch statement. An
    /// owner told a command does not exist stops looking for it, which is a
    /// worse outcome than the typo.
    func testATrailingVerbIsRefusedWithoutDenyingThatItExists() {
        let outcome = run(["pause", "resume"])

        XCTAssertEqual(outcome.status, 2)
        let said = outcome.problem.joined(separator: "\n")
        XCTAssertFalse(said.contains("there is no"), said)
        XCTAssertTrue(said.contains("sage-voiced settings pause"), said)
        XCTAssertFalse(
            PauseState(fileURL: pauseURL).isPaused(),
            "a command that was refused paused the appliance anyway"
        )
    }

    func testProactiveWithNothingToChangeIsRefusedRatherThanDoingNothingQuietly() {
        let outcome = run(["proactive"])
        XCTAssertEqual(outcome.status, 2)
        XCTAssertTrue(outcome.problem.joined().contains("on"), "\(outcome.problem)")
    }

    func testOnAndOffTogetherIsRefusedRatherThanResolvedByArgumentOrder() {
        let outcome = run(["proactive", "on", "off"])
        XCTAssertEqual(outcome.status, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: proactiveURL.path))
    }

    /// **Every dead end needs a door.** Nothing this command refuses may stop
    /// at "no": each refusal has to name a command that would have worked.
    func testEveryRefusalNamesSomethingToTypeNext() {
        let typos: [[String]] = [
            ["frobnicate"],
            ["proactive"],
            ["proactive", "maybe"],
            ["proactive", "on", "off"],
            ["proactive", "--every"],
            ["proactive", "--every", "thirty"],
            ["proactive", "on", "--evyer", "30"],
            ["--every", "30"],
            ["pause", "now"],
            ["pause", "resume"],
        ]
        for arguments in typos {
            let outcome = run(arguments)
            XCTAssertNotEqual(outcome.status, 0, "\(arguments) was accepted")
            XCTAssertFalse(outcome.problem.isEmpty, "\(arguments) failed silently")
            XCTAssertTrue(
                outcome.problem.joined(separator: "\n").contains("sage-voiced settings"),
                "\(arguments) is a dead end: \(outcome.problem)"
            )
        }
    }

    /// The invariant the two streams exist for: **a non-zero exit always has a
    /// reason on stderr, and a zero exit never invents one.** A refusal printed
    /// to stdout is a refusal a pipeline swallows.
    func testAnExitCodeAndAReasonAlwaysAgree() {
        let everything: [[String]] = [
            [], ["show"], ["status"],
            ["proactive", "on"], ["proactive", "off"], ["proactive", "--every", "45"],
            ["pause"], ["resume"],
            ["frobnicate"], ["proactive"], ["proactive", "--every", "1"],
            ["proactive", "--every", "thirty"], ["--every", "30"],
        ]
        for arguments in everything {
            let outcome = run(arguments)
            XCTAssertEqual(
                outcome.status != 0,
                !outcome.problem.isEmpty,
                "\(arguments) exited \(outcome.status) saying \(outcome.problem)"
            )
        }
    }

    /// The help is generated from the floor rather than typed out, because the
    /// floor moved once already — fifteen minutes to five — and a help text
    /// carrying the old number is a lie no compiler can see.
    func testTheUsageNamesEveryVerbAndTheRangeItActuallyRuns() {
        let usage = HeadlessSettings.usage
        for verb in ["settings proactive on|off", "--every", "settings pause", "settings resume"] {
            XCTAssertTrue(usage.contains(verb), "usage does not mention \(verb): \(usage)")
        }
        XCTAssertTrue(usage.contains("\(ProactivePreferences.fastest)"), usage)
        XCTAssertTrue(usage.contains("\(ProactivePreferences.slowest)"), usage)
    }

    // MARK: - That the daemon actually offers it

    /// **A door nobody can reach is defect 6 unfixed.**
    ///
    /// Every test above calls `HeadlessSettings` directly, and not one of them
    /// would notice if `case "settings":` were dropped from the dispatch —
    /// which is precisely the shape the defect had in the first place:
    /// `ProactivePreferences.update` and `PauseState.setPaused` were written,
    /// documented as the headless way in, covered by tests, and called by
    /// nothing. `main.swift` is an executable target and cannot be imported, so
    /// the wiring is asserted by scanning it, the precedent `MessageWakeBusTests`
    /// and `AfterTheCallTests` already set.
    func testTheDaemonDispatchesSettingsToTheDoorTheseTestsCover() throws {
        let daemon = try daemonSource()

        let dispatched = try XCTUnwrap(
            daemon.split(separator: "\n").first { $0.contains(#"case "settings":"#) },
            "sage-voiced has no `settings` subcommand, so everything above is unreachable"
        )
        XCTAssertTrue(
            dispatched.contains("runSettings"),
            "`settings` dispatches somewhere else: \(dispatched)"
        )
        XCTAssertTrue(
            daemon.contains("HeadlessSettings.run("),
            "the subcommand does not call the door these tests cover, so what it "
                + "refuses and what it prints are decided where no test can see them"
        )
    }

    /// The two streams and the exit status, at the one layer the tests above
    /// cannot reach. A refusal printed to stdout is a refusal a pipeline
    /// swallows, and `exit(0)` over a refusal is a script that carries on.
    func testTheShimPutsRefusalsOnStderrAndExitsWithTheStatus() throws {
        let body = try shim()

        for line in body.split(separator: "\n") where line.contains("print(") {
            XCTAssertFalse(
                line.contains("problem"),
                "a refusal goes to stdout, where a pipeline swallows it: \(line)"
            )
        }
        XCTAssertTrue(
            body.contains("FileHandle.standardError.write"),
            "nothing reaches stderr: \(body)"
        )
        XCTAssertTrue(
            body.contains("exit(outcome.status)"),
            "the exit status is not the one the outcome asked for: \(body)"
        )
    }

    /// **`usage()` is the whole of the discovery story.** On a machine with no
    /// Mac app, an owner finds out these controls exist by running
    /// `sage-voiced` with no arguments and reading the list — a control that is
    /// not in it is a control that does not exist.
    func testTheDaemonUsageNamesTheSettingsCommand() throws {
        let usage = try XCTUnwrap(
            try daemonSource()
                .components(separatedBy: "func usage() -> Never {")
                .dropFirst().first?
                .components(separatedBy: "\n}").first,
            "there is no usage() in main.swift"
        )
        for named in ["sage-voiced settings", "proactive on|off", "pause | resume"] {
            XCTAssertTrue(usage.contains(named), "usage() does not name `\(named)`: \(usage)")
        }
    }

    // MARK: - Staging a removal that cannot happen

    /// Everything in `holder` made impossible for **this process** to remove,
    /// and the undo.
    ///
    /// Taking write permission off the directory is the real case — a state
    /// directory the owner cannot write — and for the user this suite normally
    /// runs as, the mode is the whole mechanism.
    ///
    /// **Root ignores the mode, and root is the only user the Linux container
    /// has.** Skipping there meant the resume-that-cannot-clear-the-flag path
    /// was unrun on the only Linux this port is tested on: a control believed
    /// covered, whose failure branch had never once executed off Darwin, which
    /// is the exact shape of the defect the rest of this file exists to catch.
    /// So when this is root the *bypass* is given up for the duration rather
    /// than the test — the capability on Linux, per-file immutability on Darwin
    /// — and the same directory mode then does the same work it does for an
    /// owner. The product sees an ordinary refusal from the filesystem either
    /// way; nothing about `PauseState` or `HeadlessSettings` is faked.
    ///
    /// Proved on a decoy before the caller asserts anything, because a
    /// mechanism that silently failed to take would leave the removal
    /// succeeding — and a test that passed anyway would be reporting a control
    /// it never exercised, which is the thing being tested for.
    private func removalsMadeImpossible(in holder: URL) throws -> () -> Void {
        let manager = FileManager.default
        // Not the flag the caller is about to assert on: proving the mechanism
        // must not be the thing that consumes it.
        let decoy = holder.appendingPathComponent("decoy", isDirectory: false)
        try Data().write(to: decoy)

        var undo: [() -> Void] = []
        func putItBack() { for step in undo.reversed() { step() } }

        if geteuid() == 0 {
            guard let restored = Self.releaseTheRootBypass(over: holder) else {
                putItBack()
                throw CannotStageAFailedRemoval(holder: holder.path)
            }
            undo.append(restored)
        }
        try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: holder.path)
        undo.append {
            try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: holder.path)
        }

        let cameAwayAnyway: Bool
        do {
            try manager.removeItem(at: decoy)
            cameAwayAnyway = true
        } catch {
            cameAwayAnyway = false
        }
        guard !cameAwayAnyway else {
            putItBack()
            throw CannotStageAFailedRemoval(holder: holder.path)
        }
        return putItBack
    }

    /// The one part of being root this needs taken away: the right to ignore a
    /// directory's mode. `nil` when the system offers no way to give it up, and
    /// the caller then fails loudly rather than passing on an unstaged test.
    private static func releaseTheRootBypass(over holder: URL) -> (() -> Void)? {
        #if canImport(Darwin)
        // Darwin has no capability model, so the files are made immutable
        // instead: `unlink` refuses an immutable file for uid 0 as well — root
        // has to clear the flag first, which is precisely the step a `resume`
        // does not take.
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: holder, includingPropertiesForKeys: nil
        ) else { return nil }
        for entry in entries {
            _ = entry.withUnsafeFileSystemRepresentation { chflags($0, UInt32(UF_IMMUTABLE)) }
        }
        return {
            for entry in entries {
                _ = entry.withUnsafeFileSystemRepresentation { chflags($0, 0) }
            }
        }
        #elseif canImport(Glibc) || canImport(Musl)
        return LinuxCapabilities.withoutTheRightToIgnoreADirectoryMode()
        #else
        return nil
        #endif
    }

    /// A dead end with a door on it: what could not be staged, and what to do
    /// about it. `LocalizedError` as well, because XCTest reports a thrown
    /// error through `localizedDescription`, which for a bare `Error` off
    /// Darwin is a sentence with none of this in it.
    private struct CannotStageAFailedRemoval: Error, LocalizedError, CustomStringConvertible {
        let holder: String

        var description: String {
            """
            this process can still delete files inside \(holder) with write \
            permission taken off it, so the resume-that-cannot-clear-the-flag \
            this test is about cannot be staged here — and the test will not \
            skip, because that failure path is the only thing standing between \
            an owner and an appliance that says it is answering while the flag \
            is still on disk.
            Run the suite as a non-root user, or on a Linux where \
            CAP_DAC_OVERRIDE can be dropped from this thread.
            """
        }

        var errorDescription: String? { description }
    }

    // MARK: - Reading the daemon

    private func daemonSource() throws -> String {
        try String(
            contentsOf: repositoryRoot().appendingPathComponent("Sources/sage-voiced/main.swift"),
            encoding: .utf8
        )
    }

    /// The body of `runSettings`, bounded at the first brace in column zero so
    /// that an assertion about the shim cannot be satisfied by some other
    /// function further down the file.
    private func shim() throws -> String {
        try XCTUnwrap(
            try daemonSource()
                .components(separatedBy: "func runSettings(")
                .dropFirst().first?
                .components(separatedBy: "\n}").first,
            "there is no runSettings in main.swift"
        )
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

#if canImport(Glibc) || canImport(Musl)
/// `capget`/`capset`, by symbol rather than by header.
///
/// The declarations live in `<sys/capability.h>`, which belongs to libcap and
/// is not something the Glibc module exposes; the two symbols themselves are in
/// libc, and the structures are kernel ABI pinned by the version word. Reached
/// through `dlsym` so that a system without them is a `nil` the caller reports,
/// not a link error that stops this file compiling.
private enum LinuxCapabilities {

    private struct Header {
        /// `_LINUX_CAPABILITY_VERSION_3`, which is the 64-bit-capability layout
        /// and the reason `Words` is asked for in twos.
        var version: UInt32 = 0x2008_0522
        /// Zero means this thread.
        var pid: Int32 = 0
    }

    private struct Words {
        var effective: UInt32 = 0
        var permitted: UInt32 = 0
        var inheritable: UInt32 = 0
    }

    private typealias Call =
        @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Int32

    /// `CAP_DAC_OVERRIDE`, `CAP_DAC_READ_SEARCH` and `CAP_FOWNER` — the three
    /// that let uid 0 walk past a mode that would stop an owner — dropped from
    /// the effective set, and the undo.
    ///
    /// They stay in the *permitted* set, so raising them again always works.
    /// Capabilities are per-thread on Linux, so this touches only the thread
    /// the test is running on: no `SIGSETXID` broadcast, nothing for another
    /// thread to answer, and nothing a wedged one could hold up.
    static func withoutTheRightToIgnoreADirectoryMode() -> (() -> Void)? {
        guard let image = dlopen(nil, RTLD_NOW),
            let read = dlsym(image, "capget").map({ unsafeBitCast($0, to: Call.self) }),
            let write = dlsym(image, "capset").map({ unsafeBitCast($0, to: Call.self) })
        else { return nil }

        var header = Header()
        var held = [Words](repeating: Words(), count: 2)
        guard read(&header, &held) == 0 else { return nil }

        let toRestore = held
        let bypass: UInt32 = (1 << 1) | (1 << 2) | (1 << 3)
        var reduced = held
        reduced[0].effective &= ~bypass
        guard write(&header, &reduced) == 0 else { return nil }

        return {
            var header = Header()
            var restored = toRestore
            _ = write(&header, &restored)
        }
    }
}
#endif
