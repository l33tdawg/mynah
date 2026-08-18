import XCTest
@testable import SageVoiceCore

/// Whether a diagnostic can be read back.
///
/// **The obvious test here is the useless one.** Asserting that the logger was
/// called reproduces the exact bug it exists to fix: `os_log` *succeeds*, every
/// time, and forgets — so "we logged it" was already true all day while nothing
/// could be retrieved. The only assertion that means anything is to write a
/// line and then go and get it, and to get it the way a person would: from the
/// file, in another process, after the fact.
///
/// Hence `/usr/bin/grep` rather than `String(contentsOf:)`. Reading the file
/// in-process would pass even if the bytes had never left this program's own
/// buffers, and "a separate process can see it" is the property that was
/// missing.
final class MynahLogTests: XCTestCase {

    private var directory: URL!
    private var file: URL!
    /// Where each `grep` run leaves its output and its exit status. Kept
    /// outside `directory` on purpose: that folder's own mode is under test,
    /// and a harness must not be the reason an assertion about it passes.
    private var scratch: URL!

    override func setUpWithError() throws {
        let unique = UUID().uuidString
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mynah-log-\(unique)", isDirectory: true)
        file = directory.appendingPathComponent("mynah.log")
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mynah-log-grep-\(unique)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: scratch)
    }

    /// How long one `grep` over one small file may take before the run is
    /// declared unjudgeable. Long enough that a loaded machine never sees it,
    /// short enough that a wedge is *reported* instead of parking the suite.
    private static let grepSeconds = 30

    private enum GrepFailure: Error, CustomStringConvertible {
        case neverFinished(needle: String, seconds: Int)
        case couldNotRun(needle: String, path: String, status: Int32, said: String)

        var description: String {
            switch self {
            case .neverFinished(let needle, let seconds):
                return "the grep for \"\(needle)\" never recorded an exit status within "
                    + "\(seconds)s, so whether the line reached disk is unknown. The child was "
                    + "killed rather than waited on, so the suite carries on. Re-run this test "
                    + "on its own; if it repeats, the harness is what to look at, not MynahLog."
            case .couldNotRun(let needle, let path, let status, let said):
                return "grep exited \(status) looking for \"\(needle)\" in \(path), so nothing "
                    + "was read back and no assertion about the text would mean anything. It "
                    + "said: " + (said.isEmpty ? "nothing" : said) + ". Exit 2 usually means the "
                    + "file is not there — the line never reached disk at all; 127 means this "
                    + "machine has no grep(1) on /usr/local/bin:/usr/bin:/bin."
            }
        }
    }

    /// Runs a real `grep` against the file and returns what it found. A hit
    /// proves the line is on disk and legible to something that is not this
    /// test.
    ///
    /// **Nothing here waits on `Foundation.Process`, and that is deliberate.**
    /// Both obvious spellings hang forever on Linux, and both hang *after* the
    /// line under test has already reached disk — the worst shape a harness can
    /// have, because the thing being tested passed and the run never ends.
    /// `TheDaemonSaysWhichNodeItRefusedTests` measured both in this repo:
    ///
    ///   * `Pipe` + `readDataToEndOfFile()`. The parent holds its own copy of
    ///     the write end for as long as the `Process` holds the pipe, so the
    ///     read waits for an EOF that cannot arrive.
    ///   * `waitUntilExit()`. Verified against a child that had exited, written
    ///     both its streams and left no zombie: the call never returned.
    ///     `terminate()` afterwards cannot help — there is nothing left to
    ///     signal.
    ///
    /// So the shell owns the lifetime. It redirects `grep` to files — no buffer
    /// to deadlock against — and records the exit status when it is over. This
    /// polls for that status under a deadline and *names* a miss rather than
    /// waiting on it. `run()` itself is fine; only waiting is not.
    private func grepFromAnotherProcess(_ needle: String) throws -> String {
        let box = scratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: box, withIntermediateDirectories: true)
        let outURL = box.appendingPathComponent("stdout")
        let errURL = box.appendingPathComponent("stderr")
        let statusURL = box.appendingPathComponent("status")
        let partialURL = box.appendingPathComponent("status.partial")

        // The status is written elsewhere and `mv`d into place, so a status
        // file that exists is a whole one and the poll below cannot read half
        // of a number and call it an exit code.
        let script = "grep -- \(Self.quoted(needle)) \(Self.quoted(file.path)) "
            + "> \(Self.quoted(outURL.path)) 2> \(Self.quoted(errURL.path)); "
            + "echo $? > \(Self.quoted(partialURL.path)); "
            + "mv \(Self.quoted(partialURL.path)) \(Self.quoted(statusURL.path))"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        // `grep` by name off a described `PATH` rather than a hardcoded
        // /usr/bin/grep, which is the kind of thing that differs between a Mac
        // and a distro image.
        process.environment = ["PATH": "/usr/local/bin:/usr/bin:/bin"]
        // Not a `Pipe` on any of the three: everything the child says is
        // already going to a file it owns.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        let deadline = Date().addingTimeInterval(TimeInterval(Self.grepSeconds))
        var status: Int32?
        while status == nil, Date() < deadline {
            if let text = try? String(contentsOf: statusURL, encoding: .utf8) {
                status = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if status == nil { Thread.sleep(forTimeInterval: 0.02) }
        }

        guard let status else {
            process.terminate()
            throw GrepFailure.neverFinished(needle: needle, seconds: Self.grepSeconds)
        }
        // 0 is a hit and 1 is an honest miss, which the caller's own assertion
        // should speak for. Anything else means the read never happened, and no
        // assertion about absent text is entitled to describe that.
        guard status == 0 || status == 1 else {
            let said = ((try? String(contentsOf: errURL, encoding: .utf8)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw GrepFailure.couldNotRun(
                needle: needle,
                path: file.path,
                status: status,
                said: said
            )
        }
        return (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
    }

    /// Single-quoted for `/bin/sh`, embedded quotes and all.
    private static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    // MARK: The property that was missing

    func testALineCanBeReadBackByAnotherProcess() throws {
        MynahLog(category: "probe", fileURL: file).error("the memory node refused the write")

        let found = try grepFromAnotherProcess("refused the write")
        XCTAssertTrue(
            found.contains("the memory node refused the write"),
            "the line did not survive to disk: \(found)"
        )
    }

    /// Every line carries when and where, because a diagnosis starts by lining
    /// this up against a file's modification time.
    func testEveryLineCarriesItsTimeCategoryAndLevel() throws {
        MynahLog(category: "board", fileURL: file).error("could not read the task list")

        let line = try grepFromAnotherProcess("task list")
        XCTAssertTrue(line.contains("[board]"))
        XCTAssertTrue(line.contains("ERROR"))
        // yyyy-MM-dd, matching appliance.log so the two read together.
        XCTAssertTrue(line.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}"#, options: .regularExpression) != nil)
    }

    func testNoticeAndInfoAlsoReachTheFile() throws {
        let log = MynahLog(category: "probe", fileURL: file)
        log.info("started the scan")
        log.notice("the scan found nothing")

        XCTAssertTrue(try grepFromAnotherProcess("started the scan").contains("INFO"))
        XCTAssertTrue(try grepFromAnotherProcess("found nothing").contains("NOTE"))
    }

    /// `debug` is deliberately the exception: chatter that is worth having while
    /// watching and would bury the file for somebody reading it back later.
    func testDebugStaysOutOfTheFile() throws {
        MynahLog(category: "probe", fileURL: file).debug("polled, nothing changed")

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: Not becoming a second problem

    /// A log that cannot be written must not throw, crash, or take the caller
    /// down with it. There is nowhere left to report the failure to.
    func testAnUnwritableDestinationIsSilentRatherThanFatal() {
        let impossible = URL(fileURLWithPath: "/System/definitely-not-writable/mynah.log")
        MynahLog(category: "probe", fileURL: impossible).error("this cannot be written")
    }

    /// Appends rather than replaces — the second line must not cost the first.
    func testLinesAccumulate() throws {
        let log = MynahLog(category: "probe", fileURL: file)
        log.error("first")
        log.error("second")

        XCTAssertTrue(try grepFromAnotherProcess("first").contains("first"))
        XCTAssertTrue(try grepFromAnotherProcess("second").contains("second"))
    }

    /// Rolls once past its cap, and the current file survives the roll — a log
    /// that grows without limit becomes a log people delete.
    func testItRollsOnceRatherThanGrowingForever() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: MynahLog.maximumBytes + 1).write(to: file)

        MynahLog(category: "probe", fileURL: file).error("after the roll")

        XCTAssertTrue(
            try grepFromAnotherProcess("after the roll").contains("after the roll"),
            "the line was lost in the roll"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: file.appendingPathExtension("1").path),
            "the previous generation was dropped rather than kept"
        )
    }

    // MARK: Owner-only

    /// The same treatment the owner's transcripts and keys get. Not because
    /// today's lines are sensitive — because this is the seam a dozen files log
    /// through, and the line that does carry something will be written by
    /// somebody who never looked at the mode.
    func testTheFileIsOwnerOnly() throws {
        MynahLog(category: "probe", fileURL: file).error("something worth keeping")

        let manager = FileManager.default
        let filePerms = try manager.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        let dirPerms = try manager.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(filePerms, 0o600)
        XCTAssertEqual(dirPerms, 0o700)
    }

    /// **The way this fix usually fails.** A rotate recreates the file at the
    /// default mode, nobody looks again, and the protection quietly applies
    /// only to a file that no longer exists.
    func testTheModeSurvivesARoll() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: MynahLog.maximumBytes + 1).write(to: file)

        MynahLog(category: "probe", fileURL: file).error("after the roll")

        let manager = FileManager.default
        let current = try manager.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(current, 0o600, "the rolled-to file came back world-readable")
        let kept = try manager.attributesOfItem(
            atPath: file.appendingPathExtension("1").path
        )[.posixPermissions] as? NSNumber
        XCTAssertEqual(kept, 0o600, "the kept generation lost its mode in the move")
    }

    /// A file left world-readable by an older build is repaired rather than
    /// inherited — protection at creation time alone would never reach it.
    func testAWorldReadableFileFromAnEarlierBuildIsRepaired() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("old line\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)

        MynahLog(category: "probe", fileURL: file).error("a new line")

        let perms = try FileManager.default
            .attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms, 0o600)
    }

    // MARK: Not writing into the owner's real log

    /// **The rule that stops a test fabricating evidence.**
    ///
    /// `mynah.log` showed forty reconcile lines in an hour and it looked exactly
    /// like the chronic-restart bug the team was hunting. It was this suite:
    /// `SignalBackgroundServiceManager` is injectable everywhere except its
    /// logger, which was a `static let` on the default path. The noise landed in
    /// the file Settings tells the owner to attach to a support message, and in
    /// the file anybody diagnosing reads first.
    func testATestNeverWritesToTheOwnersRealLog() {
        XCTAssertFalse(
            MynahLog.mayWriteToFile(MynahLog.defaultFileURL(), isTesting: true),
            "a test would append to the owner's diagnostic log"
        )
    }

    /// The narrowness matters as much as the rule: every test that asserts on
    /// file contents passes its own URL, and must keep working.
    func testATestWritingToItsOwnFileIsUnaffected() {
        XCTAssertTrue(MynahLog.mayWriteToFile(file, isTesting: true))
    }

    /// And the product itself must be unaffected — this is a test-only muzzle,
    /// not a reason the owner's log is empty when he needs it.
    func testTheRunningProductStillWritesToTheDefaultPath() {
        XCTAssertTrue(MynahLog.mayWriteToFile(MynahLog.defaultFileURL(), isTesting: false))
    }

    /// End to end, since the point is bytes on disk rather than a predicate:
    /// logging to the default path from inside a test must not grow the file.
    func testTheRealLogDoesNotGrowWhileTheSuiteRuns() throws {
        let real = MynahLog.defaultFileURL()
        let manager = FileManager.default
        let before = (try? manager.attributesOfItem(atPath: real.path)[.size] as? Int) ?? 0

        MynahLog(category: "probe").error("this line must not reach his disk")

        let after = (try? manager.attributesOfItem(atPath: real.path)[.size] as? Int) ?? 0
        XCTAssertEqual(before ?? 0, after ?? 0, "the suite appended to the owner's real log")
    }

    // MARK: Where it goes

    /// Beside `bridge.log`, `signal.log` and `appliance.log`, in the folder
    /// somebody already knows to open — and off Darwin, in the folder somebody
    /// on *that* machine already knows to open instead.
    ///
    /// **This assertion had no platform guard, and read as a product bug.** It
    /// pinned `~/Library/Logs/Mynah` everywhere, so the first Linux run failed
    /// here while `defaultFileURL` was doing exactly the right thing: on a
    /// Linux box `~/Library` is a folder Mynah would be inventing, with a name
    /// that means nothing to the person looking for the log, while
    /// `~/.local/state` is the XDG place for state a program keeps across
    /// runs. The test was wrong, not the code — so it pins both spellings now
    /// rather than one, because a log nobody can find is the failure either
    /// way.
    ///
    /// The condition is spelled `canImport(Darwin)` to match the one inside
    /// `MynahLog.defaultFileURL` exactly. `os(macOS)` would read identically
    /// on both machines we build for today and would quietly stop agreeing
    /// with the product on any other Darwin platform — a test drifting from
    /// the branch it checks is the thing this guard exists to prevent, not to
    /// introduce.
    func testItLivesWithTheOtherLogsTheOwnerAlreadyHas() {
        let url = MynahLog.defaultFileURL(homeDirectory: URL(fileURLWithPath: "/Users/someone"))

        #if canImport(Darwin)
        XCTAssertEqual(url.path, "/Users/someone/Library/Logs/Mynah/mynah.log")
        #else
        XCTAssertEqual(url.path, "/Users/someone/.local/state/mynah/mynah.log")
        #endif
    }
}
