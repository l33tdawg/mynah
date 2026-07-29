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

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mynah-log-\(UUID().uuidString)", isDirectory: true)
        file = directory.appendingPathComponent("mynah.log")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Runs a real `grep` against the file and returns what it found. A hit
    /// proves the line is on disk and legible to something that is not this
    /// test.
    private func grepFromAnotherProcess(_ needle: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
        process.arguments = [needle, file.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
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

    // MARK: Where it goes

    /// Beside `bridge.log`, `signal.log` and `appliance.log`, in the folder
    /// somebody already knows to open.
    func testItLivesWithTheOtherLogsTheOwnerAlreadyHas() {
        let url = MynahLog.defaultFileURL(homeDirectory: URL(fileURLWithPath: "/Users/someone"))
        XCTAssertEqual(url.path, "/Users/someone/Library/Logs/Mynah/mynah.log")
    }
}
