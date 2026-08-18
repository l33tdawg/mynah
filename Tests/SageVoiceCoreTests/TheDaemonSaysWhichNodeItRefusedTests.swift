import XCTest
@testable import SageVoiceCore

/// **A refusal that names nothing sends the owner to reinstall what they have.**
///
/// `SageNodeChoice.decide` returns a reason: `.unprovenExecutable` names the
/// binary it found and quotes what that binary said when it was asked to
/// identify itself; `.noNodeInstalled` carries every place that was looked.
/// `resolve` is `try? decide(...).get()`, so the daemon — which called
/// `resolve` — threw all of it away and printed one fixed sentence for two
/// opposite situations:
///
///     No SAGE node found, and Mynah does not install one on this platform.
///     Install SAGE yourself, then name its executable: …
///
/// On Linux that sentence is *wrong* in the case it matters most. SageMath
/// installs an executable called `sage`, and on a box where it sits in front of
/// the owner's real node on `PATH`, the machine has SAGE and Mynah told its
/// owner to go and install SAGE. There is no way out of that from the message:
/// it does not say what was found, what was wrong with it, or that `--sage`
/// exists.
///
/// ## Why these run the real binary
///
/// The thing under test is `Sources/sage-voiced/main.swift`, an executable
/// target — nothing can import it. `SageNodeChoiceLinuxTests` already proves
/// `decide` produces the right reason; that passed the whole time the daemon
/// was discarding it. So the only test that can fail for the actual defect is
/// one that runs `sage-voiced` and reads what a Linux owner would read on their
/// terminal.
///
/// **Off-Darwin only**, and not for portability: on a Mac `resolvedSagePath`
/// never refuses — there is a vendored node — and spawning `sage-voiced` on
/// this machine would have it reach for the owner's live SAGE.
#if !canImport(Darwin)

final class TheDaemonSaysWhichNodeItRefusedTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("daemon-refusal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    // MARK: - Running the daemon for real

    private struct Run {
        let status: Int32
        let standardOutput: String
        let standardError: String
    }

    /// `sage-voiced`, built beside the test bundle by the same `swift test`.
    ///
    /// A missing binary is a failure and never a skip: a skipped test is a
    /// green tick for a check that did not happen, which is the class of defect
    /// this whole file exists about.
    private func daemonExecutable() throws -> URL {
        let beside = Bundle.main.bundleURL
        let candidates = [
            beside.appendingPathComponent("sage-voiced"),
            beside.deletingLastPathComponent().appendingPathComponent("sage-voiced")
        ]
        guard let found = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) else {
            throw Failure.noDaemon(candidates.map(\.path))
        }
        return found
    }

    private enum Failure: Error, CustomStringConvertible {
        case noDaemon([String])
        case hung(seconds: Int, saidSoFar: String)
        case neverFinished(seconds: Int, saidSoFar: String)

        var description: String {
            switch self {
            case .noDaemon(let looked):
                return "sage-voiced was not built beside the tests, so what a Linux owner reads "
                    + "cannot be checked. Build it with `swift build --product sage-voiced "
                    + "--scratch-path <the same scratch path these tests were built with>`. "
                    + "Looked at: " + looked.joined(separator: ", ")
            case .hung(let seconds, let said):
                return "the daemon did not exit within \(seconds)s. A node it cannot use has to "
                    + "be refused, not waited on. It had said: \(said.isEmpty ? "nothing" : said)"
            case .neverFinished(let seconds, let said):
                return "the shell running the daemon never recorded an exit status within "
                    + "\(seconds)s; the run cannot be judged. It had said: "
                    + (said.isEmpty ? "nothing" : said)
            }
        }
    }

    /// One subcommand, with `PATH` and `HOME` described by the test rather than
    /// inherited, so the answer is about the fixture and not about this machine.
    ///
    /// **Nothing here waits on `Foundation.Process`, and that is measured.**
    ///
    /// Two obvious spellings both hang forever on Linux, and both hang *after*
    /// the daemon has already done its job — the worst shape a harness can
    /// have, because the thing under test passed and the run never ends:
    ///
    ///   * `Pipe` + `readDataToEndOfFile`. The parent holds its own copy of the
    ///     write end for as long as the `Process` holds the pipe, so the read
    ///     waits for an EOF that cannot arrive.
    ///   * `waitUntilExit()`. Verified against a run whose child had exited,
    ///     written both its streams and left no zombie: the call never
    ///     returned. `terminate()` afterwards cannot help — there is nothing
    ///     left to signal.
    ///
    /// So the shell owns the lifetime. It redirects both streams to files
    /// (no buffer to deadlock against, and `check` is chatty), enforces the
    /// deadline with `timeout`, and writes the exit status to a third file when
    /// it is over. This polls for that file. `run()` itself is fine; only
    /// waiting is not.
    private func runDaemon(
        _ arguments: [String],
        path: String,
        home: URL,
        seconds: Int = 45
    ) throws -> Run {
        let box = root.appendingPathComponent("run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: box, withIntermediateDirectories: true)
        let outURL = box.appendingPathComponent("stdout")
        let errURL = box.appendingPathComponent("stderr")
        let statusURL = box.appendingPathComponent("status")

        let daemon = try daemonExecutable()
        // The shell keeps a real `PATH` — it needs `timeout` — and `env` hands
        // the daemon the one the test is describing. Setting `PATH` on the
        // `Process` instead starves the shell of its own tools, which showed up
        // as every assertion failing on `timeout: not found`.
        let quoted = (["env", "PATH=\(path)", "HOME=\(home.path)", daemon.path] + arguments)
            .map { "'\($0)'" }
            .joined(separator: " ")
        let script = "command -v timeout > /dev/null || { "
            + "echo 'this machine has no timeout(1); the harness needs it to bound the daemon' "
            + "> '\(errURL.path)'; echo 127 > '\(statusURL.path)'; exit 0; }; "
            + "timeout \(seconds) \(quoted) > '\(outURL.path)' 2> '\(errURL.path)'; "
            + "echo $? > '\(statusURL.path)'"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.environment = ["PATH": "/usr/local/bin:/usr/bin:/bin", "HOME": home.path]
        process.standardInput = FileHandle.nullDevice
        try process.run()

        let deadline = Date().addingTimeInterval(TimeInterval(seconds) + 30)
        var status: Int32?
        while status == nil, Date() < deadline {
            if let text = try? String(contentsOf: statusURL, encoding: .utf8) {
                status = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if status == nil { Thread.sleep(forTimeInterval: 0.1) }
        }

        let out = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
        let err = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""

        guard let status else {
            throw Failure.neverFinished(seconds: seconds, saidSoFar: err + out)
        }
        // 124 is `timeout`'s. A daemon that hangs where it should refuse is the
        // same defect in a different coat, and swallowing it here would turn
        // "it never answered" into a passing assertion about absent text.
        guard status != 124 else {
            throw Failure.hung(seconds: seconds, saidSoFar: err + out)
        }
        return Run(status: status, standardOutput: out, standardError: err)
    }

    // MARK: - Fixtures

    @discardableResult
    private func makeExecutable(named name: String, script: String, in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        FileManager.default.createFile(
            atPath: url.path,
            contents: Data(script.utf8),
            attributes: [.posixPermissions: 0o755]
        )
        return url
    }

    /// Every fixture writes down what it was asked, next to itself.
    ///
    /// That file is what makes "was this binary used as the owner's memory?" a
    /// fact rather than an inference: the node is started with `mcp`, and the
    /// identity probe asks `version`. Reading the daemon's own words cannot
    /// answer it — a refusal and a node that failed to connect both leave the
    /// same silence on stdout.
    private static let invocationLog = "invocations"

    private func invocations(in directory: URL) -> String {
        (try? String(
            contentsOf: directory.appendingPathComponent(Self.invocationLog),
            encoding: .utf8
        )) ?? ""
    }

    /// An absolute path and a builtin, nothing else. The daemon runs these with
    /// the `PATH` the test described — a fixture bin holding one file — so
    /// `dirname` is not on it, and a fixture that shells out prints its own
    /// error where SAGE's version line should be.
    private func recordTheArguments(in directory: URL) -> String {
        "echo \"$@\" >> '\(directory.appendingPathComponent(Self.invocationLog).path)'"
    }

    /// SageMath: really installs a `sage`, really is not a memory node.
    private func makeSageMath(in directory: URL) throws -> URL {
        try makeExecutable(
            named: "sage",
            script: """
            #!/bin/sh
            \(recordTheArguments(in: directory))
            if [ "$1" = "--version" ]; then
              echo "SageMath version 10.3, Release Date: 2024-03-19"
              exit 0
            fi
            echo "Error: no such file or directory: $1" >&2
            exit 1
            """,
            in: directory
        )
    }

    /// Something that proves itself the way SAGE does. It answers `version` and
    /// then leaves immediately on `mcp` — the point of the fixture is which
    /// binary the daemon reached for, and a node that never answers would only
    /// be testing `MCPClient`'s patience.
    private func makeRealSage(in directory: URL) throws -> URL {
        try makeExecutable(
            named: "sage",
            script: """
            #!/bin/sh
            \(recordTheArguments(in: directory))
            if [ "$1" = "version" ]; then
              echo "sage-gui 11.18.14 (commit 5053ca0c, built 2026-08-16T04:48:49Z)"
              exit 0
            fi
            exit 0
            """,
            in: directory
        )
    }

    /// An empty directory to hand `PATH`, so "nothing installed" means it.
    private func emptyBin() throws -> URL {
        let empty = root.appendingPathComponent("empty-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        return empty
    }

    /// This machine must really have no SAGE for the "nothing found" case to be
    /// describable. The check is the resolver's own search, so it cannot drift
    /// from what the daemon will do, and it names what it found rather than
    /// failing as a mystery.
    ///
    /// Both homes, because `HOME` does not decide this: Foundation's
    /// `homeDirectoryForCurrentUser` reads the passwd entry off Darwin, so the
    /// daemon searches the account's real home whatever the test exports.
    private func assertMachineHasNoNodeOfItsOwn(path: String, home: URL) {
        let stray = [home, FileManager.default.homeDirectoryForCurrentUser].flatMap {
            SageNodeLocator.installedExecutableCandidates(
                environment: ["PATH": path],
                homeDirectory: $0
            )
        }
        XCTAssertTrue(
            stray.isEmpty,
            "this machine has a SAGE at \(stray.map(\.path)), so a run with no node cannot be "
                + "described here; move it or run these in the swift:6.0-jammy container"
        )
    }

    // MARK: - The defect

    /// **SageMath on `PATH` is the case the fixed sentence got backwards.**
    ///
    /// The owner has software installed. The daemon must say which binary it
    /// found, what that binary said when asked, and that `--sage` is how to
    /// point at the right one — and must *not* tell them to install SAGE.
    func testAnUnprovenBinaryIsNamedAndQuotedRatherThanCallingItAMissingInstall() throws {
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let impostor = try makeSageMath(in: bin)

        let run = try runDaemon(["check"], path: bin.path, home: root)
        let said = run.standardError

        XCTAssertNotEqual(run.status, 0, "the daemon reported success with no memory node")
        XCTAssertTrue(
            said.contains(impostor.path),
            "the refusal does not say which binary it found: \(said)"
        )
        XCTAssertTrue(
            said.contains("did not identify itself as SAGE"),
            "the refusal does not say what was wrong with it: \(said)"
        )
        // SAGE is asked `version`; SageMath has no such subcommand and treats
        // it as a filename, so what the owner needs to see is the sentence
        // *their* `sage` printed. Without it the message is "something at
        // /x/sage is not SAGE", which is not enough to recognise it.
        XCTAssertTrue(
            said.contains("exited 1") && said.contains("no such file or directory: version"),
            "the refusal does not quote what the binary said, so the owner cannot tell it is "
                + "SageMath rather than a broken SAGE: \(said)"
        )
        XCTAssertTrue(
            said.contains("--sage"),
            "the refusal does not name the next action: \(said)"
        )
        XCTAssertFalse(
            said.contains("Install SAGE yourself"),
            "the owner has SAGE-shaped software installed and was told to go and install it — "
                + "this is the defect: \(said)"
        )

        // Refusing has to mean refusing. The alternative outcome — running
        // SageMath as the owner's memory — is worse than either message.
        let asked = invocations(in: bin)
        XCTAssertTrue(asked.contains("version"), "the binary was never asked who it was: \(asked)")
        XCTAssertFalse(
            asked.contains("mcp"),
            "SageMath was started as the owner's memory node anyway: \(asked)"
        )
    }

    /// And the diagnosis reaches the owner from every subcommand that needs a
    /// node, not only the one that happened to be tested.
    func testTheDiagnosisReachesTheOwnerFromCalendarToo() throws {
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let impostor = try makeSageMath(in: bin)

        let run = try runDaemon(["calendar", "--plan"], path: bin.path, home: root)

        XCTAssertNotEqual(run.status, 0)
        XCTAssertTrue(
            run.standardError.contains(impostor.path),
            "`calendar` still prints the fixed sentence: \(run.standardError)"
        )
    }

    /// The genuinely-nothing case keeps its message — and now says where it
    /// looked, because "not found" without that is indistinguishable from a
    /// node installed somewhere Mynah does not search.
    func testNothingInstalledAnywhereStillSaysInstallSageAndNamesWhereItLooked() throws {
        let empty = try emptyBin()
        assertMachineHasNoNodeOfItsOwn(path: empty.path, home: root)

        let run = try runDaemon(["check"], path: empty.path, home: root)
        let said = run.standardError

        XCTAssertNotEqual(run.status, 0, "the daemon reported success with no memory node")
        XCTAssertTrue(
            said.contains("No SAGE node found"),
            "the machine has no SAGE and was not told so: \(said)"
        )
        XCTAssertTrue(
            said.contains("Install SAGE yourself"),
            "the one case where installing SAGE *is* the answer no longer says so: \(said)"
        )
        XCTAssertTrue(said.contains("--sage"), "no next action: \(said)")
        XCTAssertTrue(
            said.contains("Looked in:") && said.contains("PATH ("),
            "the owner cannot tell whether their install is simply somewhere else: \(said)"
        )
    }

    /// The refusal must not be traded for a false start: a node that proves
    /// itself is used, and nothing is said about installing anything.
    ///
    /// The first assertion is what stops this passing for the wrong reason. An
    /// absence of refusal text is also what a daemon that fell over earlier
    /// produces, so the proof is the fixture's own record: it was asked
    /// `version`, and then it was started as the node with `mcp`.
    func testARealSageOnPathIsUsedRatherThanRefused() throws {
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try makeRealSage(in: bin)

        let run = try runDaemon(["check"], path: bin.path, home: root, seconds: 30)
        let asked = invocations(in: bin)

        XCTAssertTrue(
            asked.contains("version"),
            "the daemon never asked the binary who it was: \(asked)\(run.standardError)"
        )
        XCTAssertTrue(
            asked.contains("mcp"),
            "the daemon found a SAGE that identified itself and never started it as the node: "
                + "\(asked)\(run.standardError)"
        )
        XCTAssertFalse(
            run.standardError.contains("No SAGE node found"),
            "a SAGE that identified itself was reported as no SAGE at all: \(run.standardError)"
        )
        XCTAssertFalse(
            run.standardError.contains("did not identify itself as SAGE"),
            "a SAGE that identified itself was refused: \(run.standardError)"
        )
    }

    /// Nothing about a refusal may go to stdout: `check` prints its result
    /// there, and a failure mixed into it reads as a result.
    func testTheRefusalGoesToStandardErrorAndLeavesStandardOutputEmpty() throws {
        let empty = try emptyBin()
        assertMachineHasNoNodeOfItsOwn(path: empty.path, home: root)

        let run = try runDaemon(["check"], path: empty.path, home: root)

        XCTAssertTrue(
            run.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "a refusal was printed on the result channel: \(run.standardOutput)"
        )
    }
}

#endif

/// The half of this that a Mac can check, and the reason it is worth checking
/// there: everything above compiles out on Darwin, so a Mac-only run would
/// happily green-light putting `resolve` back.
final class TheDaemonKeepsTheNodeDiagnosisTests: XCTestCase {

    private func daemonSource() throws -> String {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: repository.appendingPathComponent("Sources/sage-voiced/main.swift"),
            encoding: .utf8
        )
    }

    private struct Unreadable: Error, CustomStringConvertible {
        let description: String
    }

    private func resolvedSagePathBody() throws -> String {
        let source = try daemonSource()
        guard let start = source.range(of: "func resolvedSagePath("),
              let end = source.range(of: "\n}\n", range: start.upperBound..<source.endIndex) else {
            throw Unreadable(
                description: "resolvedSagePath is no longer a top-level function in "
                    + "Sources/sage-voiced/main.swift; move these two checks to wherever the node "
                    + "is now chosen rather than deleting them"
            )
        }
        return String(source[start.upperBound..<end.lowerBound])
    }

    /// `resolve` is `try? decide(...).get()`. Using it here is exactly how the
    /// reason was lost, and it looks completely correct at the call site.
    func testTheOffDarwinArmAsksForTheReasonAndNotJustThePath() throws {
        let body = try resolvedSagePathBody()
        guard let elseArm = body.range(of: "#else"),
              let endif = body.range(of: "#endif", range: elseArm.upperBound..<body.endIndex) else {
            return XCTFail("resolvedSagePath no longer has a platform split; check it by hand")
        }
        let offDarwin = String(body[elseArm.upperBound..<endif.lowerBound])

        XCTAssertTrue(
            offDarwin.contains("SageNodeChoice.decide"),
            "the off-Darwin arm no longer asks why, so a refused node reads as a missing install"
        )
        XCTAssertFalse(
            offDarwin.contains("SageNodeChoice.resolve"),
            "`resolve` discards the reason — that is the defect, and it reappears silently "
                + "because it compiles and reads correctly"
        )
    }

    /// The Mac arm is not this change's to alter, and it is the one that ships.
    func testTheMacArmStillFallsBackToTheConventionalPath() throws {
        let body = try resolvedSagePathBody()
        guard let macArm = body.range(of: "#if os(macOS)"),
              let elseArm = body.range(of: "#else", range: macArm.upperBound..<body.endIndex) else {
            return XCTFail("resolvedSagePath no longer has a platform split; check it by hand")
        }
        let mac = String(body[macArm.upperBound..<elseArm.lowerBound])

        XCTAssertTrue(
            mac.contains("/Applications/SAGE.app/Contents/MacOS/sage-gui"),
            "the Mac lost its fallback to the conventional path"
        )
        XCTAssertFalse(
            mac.contains("exit(fail("),
            "the Mac now refuses to start where it used to fall back — a shipped regression"
        )
    }
}
