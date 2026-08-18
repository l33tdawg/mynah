#if os(Linux)
import CoreFoundation
#endif
import Foundation
import XCTest

// MARK: - The watchdog

/// **A wait on the main run loop off Darwin never ends by itself.**
///
/// This is why the Linux suite has never once finished. It is not a slow test,
/// not a leaked task, and not anything in `Sources/` — a two-test hello-world
/// package with no project code in it at all wedges the same way, on
/// `swift:6.0-jammy`, `swift:6.1-jammy` and `swift:6.2-noble` alike, in roughly
/// one run in five.
///
/// The mechanism, from the bottom up:
///
///   1. `RunLoop.run(mode:before:)` off Darwin does not honour `before:`. Six
///      lines of Foundation are enough to show it: ask the main run loop to
///      return after 0.1 s and it parks in `ppoll` and never comes back — with
///      no sources registered, with a far-future timer registered, and with a
///      10 ms repeating timer *firing the whole time*. Only `CFRunLoopStop`
///      brings it back; `CFRunLoopWakeUp` and `RunLoop.perform` do not.
///   2. XCTest off Darwin runs *every* `setUp`/test/`tearDown` through
///      `awaitUsingExpectation`, which blocks the main thread in
///      `XCTWaiter.wait`. That wait is written as a poll —
///      `runLoop.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))`
///      in a `while !isFinished` loop — so its correctness rests entirely on
///      the limit date that (1) says does not work.
///   3. The one thing that does end the wait is the fulfilment itself:
///      `XCTestExpectation.fulfill()` reaches `CFRunLoopStop`. When the child
///      task finishes *after* the main thread is already parked, that lands and
///      the test passes. When it finishes in the window *before* the main
///      thread enters the run loop, the stop is spent on a run loop that is not
///      running yet, the poll that was supposed to catch it never returns, and
///      the process parks forever: main thread in `ppoll`, one libdispatch
///      thread in `epoll_wait`, no cooperative threads, no CPU. That is exactly
///      the process every previous attempt to run this suite has left behind.
///
/// So the wedge point moves between runs because it is a race, and it is early
/// as often as it is late because every test enters that window four times.
///
/// The fix is to make (2) into the poll it was written as. A thread does
/// nothing but stop the main run loop every 20 ms, so a lost fulfilment costs
/// 20 ms instead of the suite. Nothing else changes: `XCTWaiter` re-checks its
/// expectations and waits again, which is what it does on Darwin after every
/// tick anyway.
///
/// Darwin is untouched — `RunLoop.run(mode:before:)` honours its limit date
/// there, the shipped Mac suite has never wedged, and 2.3.1 is out. The
/// watchdog therefore does not exist off the platforms that need it.
enum MainRunLoopWatchdog {

    /// Short enough that a lost fulfilment is not noticeable next to the
    /// ~0.003 s a typical test in this suite takes, long enough that 1751 tests
    /// do not pay for it. The number is not load-bearing; anything that fires
    /// works, because all it has to do is give `XCTWaiter` its next look.
    static let interval: TimeInterval = 0.02

    private static let gate = NSLock()
    nonisolated(unsafe) private static var watchdog: Thread?

    /// Whether this process has a watchdog running. Off Darwin this must be
    /// true before any test runs; on Darwin it must never be true.
    static var isRunning: Bool {
        gate.lock()
        defer { gate.unlock() }
        return watchdog != nil
    }

    /// Idempotent, and safe to call from any suite — the first caller wins and
    /// the thread then lives as long as the process does.
    static func start() {
        #if os(Linux)
        gate.lock()
        defer { gate.unlock() }
        guard watchdog == nil else { return }

        let thread = Thread {
            while true {
                Thread.sleep(forTimeInterval: MainRunLoopWatchdog.interval)
                CFRunLoopStop(CFRunLoopGetMain())
            }
        }
        thread.name = "mynah.main-run-loop-watchdog"
        watchdog = thread
        thread.start()
        #endif
    }
}

// MARK: - Tests

/// The suite has to finish before anything it says about Linux means anything.
///
/// This class is named to sort first, because `XCTest` runs suites in the order
/// the generated discovery list gives them — alphabetically by class name — and
/// a watchdog started after the wedge is a watchdog that arrived too late.
/// `testNoOtherSuiteRunsBeforeTheWatchdogIsStarted` is what keeps that true.
final class AHungSuiteIsNotAPassingOneTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        MainRunLoopWatchdog.start()
    }

    // MARK: The two waits the suite is built on

    /// **The defect itself.** Ask the main run loop to come back in 50 ms and
    /// it has to come back. Off Darwin, without the watchdog, this call never
    /// returns at all — which is not a failing test, it is a suite that stops.
    func testAWaitOnTheMainRunLoopEndsWhenItsLimitDatePasses() {
        let started = Date()
        _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        let waited = Date().timeIntervalSince(started)

        XCTAssertLessThan(
            waited,
            5,
            "the main run loop ignored a 0.05s limit date and waited \(waited)s — "
                + "every XCTest setUp and tearDown in this suite is one of these waits"
        )
    }

    /// The same defect wearing different clothes, and worse: off Darwin
    /// `Process.waitUntilExit()` on the main thread is the same
    /// `run(mode:before:)` poll, and without the watchdog it does not come back
    /// **at all** — five runs out of five, waiting on `/bin/echo hi`, a child
    /// that had already exited. Not a race; a hang.
    ///
    /// **What a green tick here does not cover.** It passes because *this
    /// process* has a watchdog. `sage-voiced` has none: `MainRunLoopWatchdog` is
    /// declared in this file, in the test target, and nothing under `Sources/`
    /// stops the main run loop. So this says the harness survives its own waits
    /// and says nothing whatever about the appliance — and reading it as
    /// coverage is exactly how `EspeakPhonemizer`, `UpdateInstall` and
    /// `LocalBrainInstaller` kept unprotected `waitUntilExit()` calls through
    /// this entire investigation.
    ///
    /// `testNoProductCodeTheLinuxBuildCompilesCallsWaitUntilExit` below is the
    /// one that looks at the product.
    func testWaitingForAChildProcessOnTheMainThreadEnds() throws {
        let echo = ["/bin/echo", "/usr/bin/echo"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
        let path = try XCTUnwrap(echo, "no echo on this machine to wait for")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["mynah"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        let started = Date()
        try process.run()
        process.waitUntilExit()
        let waited = Date().timeIntervalSince(started)

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertLessThan(
            waited,
            20,
            "waiting for a child that had already exited took \(waited)s"
        )
    }

    // MARK: The product has no watchdog, so it must not need one

    /// **The watchdog ships in the test target and nowhere else.**
    ///
    /// That asymmetry is the whole point of this test. `swift test` grows a
    /// thread that stops the main run loop every 20 ms; `sage-voiced` does not,
    /// and neither does anything it links — `grep -rn CFRunLoopStop Sources/`
    /// finds nothing. So every argument in this file for why a main-thread
    /// `waitUntilExit()` never returns off Darwin applies to the shipped daemon
    /// *unrescued*.
    ///
    /// Reading before waiting, which all three call sites do, is a fix for a
    /// full pipe buffer and not for this one: the watchdog test above hung on
    /// `/bin/echo`, a child that had already exited and whose output nobody was
    /// holding.
    ///
    /// **Why the guard is on the call and not on the thread.** Off Darwin
    /// `Process.waitUntilExit()` branches on `RunLoop.current == RunLoop.main`.
    /// On any other thread it polls a run loop with no sources registered and
    /// comes straight back; on the main thread it is the `run(mode:before:)`
    /// wait that ignores its limit date, which is the defect this whole file is
    /// about. All three call sites are plain synchronous functions with no
    /// isolation of their own, so each runs on whichever thread its caller is
    /// on, and not one of them can tell which that is. The daemon hands its main
    /// thread to the main queue (`runAndExit` → `dispatchMain()`), and the main
    /// queue is the main actor's executor, so a `@MainActor` caller lands
    /// squarely on it.
    ///
    /// **The honest limit of this test.** No main-thread path to those three is
    /// proven; this guards an exposure, not a reproduced hang. It is written as
    /// a hard guard anyway because the cost of being wrong is an appliance that
    /// stops with nothing said to the owner, and because the codebase already
    /// settled the question elsewhere: `Brain/MCPClient.swift` polls `isRunning`
    /// against a deadline "so we cannot hang here".
    ///
    /// Darwin-only sources are out of scope — Darwin does not have the defect.
    /// Everything else under `Sources/` is in, and a Mac runs this too: the
    /// Linux binary is built from this tree, so the Mac suite is where a newly
    /// written `waitUntilExit()` gets caught the day somebody writes it.
    func testNoProductCodeTheLinuxBuildCompilesCallsWaitUntilExit() throws {
        // The scan before what the scan found: a reader has to be able to tell a
        // clean result from a broken scanner, and this file has already been
        // burned once by a check that proved nothing while looking green.
        var state = Self.ScanState()
        XCTAssertTrue(
            Self.codeOnly("        process.waitUntilExit()", state: &state)
                .contains("waitUntilExit()"),
            "the scan cannot see a plain call, so it is checking nothing — fix it before trusting it"
        )
        state = Self.ScanState()
        XCTAssertFalse(
            Self.codeOnly("            // Poll rather than waitUntilExit() so we cannot hang here.", state: &state)
                .contains("waitUntilExit()"),
            "the scan counts commented-out mentions, so it would report MCPClient's own note "
                + "as a defect — fix it before trusting it"
        )

        let files = try Self.sourceFilesTheOffDarwinBuildCompiles()
        XCTAssertTrue(
            files.contains("Sources/SageVoiceCore/Setup/UpdateInstall.swift"),
            "the scan did not reach SageVoiceCore — it found \(files.count) file(s) under "
                + "\(Self.repositoryRoot.appendingPathComponent("Sources").path), so it is "
                + "checking nothing. Fix the scan before trusting it."
        )
        XCTAssertFalse(
            files.contains { path in
                Self.darwinOnlySourceDirectories.contains { path.hasPrefix($0) }
            },
            "the scan is reading Darwin-only sources, which do not have this defect and "
                + "would make it report a Mac file the Linux build never compiles"
        )

        let waits = try Self.callsToWaitUntilExit(in: files)
        XCTAssertTrue(
            waits.isEmpty,
            """
            Process.waitUntilExit() is called where the off-Darwin build compiles it:
            \(waits.map { "  " + $0 }.joined(separator: "\n"))
            Off Darwin that is the main-run-loop wait this suite had to grow
            MainRunLoopWatchdog to survive, and sage-voiced ships no watchdog.
            Reached on the main thread it does not come back at all - five runs out
            of five here, on a child that had already exited - and the appliance
            stops with nothing said to the owner, which is the worst thing it can do.
            The fix is the one Sources/SageVoiceCore/Brain/MCPClient.swift already
            uses: poll process.isRunning against a deadline and escalate to SIGKILL,
            instead of calling waitUntilExit(). Guaranteeing the wait happens off the
            main thread also closes it, but only where the call site can prove which
            thread it is on, and these cannot - they are synchronous and uninsulated.
            Putting a watchdog in Sources/ is the third option, and it needs its own
            test that the daemon actually starts it: declared and never started is
            precisely the silent success this file exists to catch.
            """
        )
    }

    // MARK: The watchdog is where it has to be

    /// The watchdog is a fix for a defect in one platform's Foundation, so it
    /// runs on that platform and nowhere else. A Mac that grew a thread
    /// stopping its main run loop twice a second would be a regression in a
    /// shipped release.
    func testTheWatchdogRunsOffDarwinAndNowhereElse() {
        #if os(Linux)
        XCTAssertTrue(
            MainRunLoopWatchdog.isRunning,
            "the watchdog never started, so this suite is one lost fulfilment "
                + "away from parking forever with nothing reported"
        )
        #else
        XCTAssertFalse(
            MainRunLoopWatchdog.isRunning,
            "Darwin's run loop honours its limit date and 2.3.1 shipped without "
                + "this thread — it must not appear on a Mac"
        )
        #endif
    }

    /// **A watchdog that starts second is not a watchdog.**
    ///
    /// `class func setUp()` runs once, when this suite starts, and the suites
    /// run in name order. So any test class whose name sorts before this one
    /// runs its whole self unprotected — which is precisely how the suite used
    /// to die inside its first two tests.
    ///
    /// This reads the directory rather than trusting the name, because the next
    /// person to add a class has no reason to know any of this.
    func testNoOtherSuiteRunsBeforeTheWatchdogIsStarted() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let names = try Self.discoverableTestClassNames(in: directory)

        XCTAssertTrue(
            names.contains(Self.ownName),
            "the scan did not find this class in \(directory.path), so it is "
                + "checking nothing — fix the scan before trusting it"
        )

        let earlier = names.filter { $0 < Self.ownName }.sorted()
        XCTAssertTrue(
            earlier.isEmpty,
            "\(earlier.joined(separator: ", ")) sort(s) before \(Self.ownName), so "
                + "off Darwin they run before the main-run-loop watchdog exists and "
                + "can park the whole suite. Either rename this class to sort first "
                + "again, or call MainRunLoopWatchdog.start() from an "
                + "`override class func setUp()` on the earliest one."
        )
    }

    // MARK: The scan

    private static let ownName = "AHungSuiteIsNotAPassingOneTests"

    /// The names XCTest will actually build suites from: a `private` or
    /// `fileprivate` helper class is never discovered, so one sorting early is
    /// not a problem and must not be reported as one.
    static func discoverableTestClassNames(in directory: URL) throws -> [String] {
        let files = try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }

        var names: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
                if let name = declaredTestCaseClass(in: String(line)) {
                    names.append(name)
                }
            }
        }
        return names
    }

    /// The repository this test file was compiled from, so the scans read the
    /// tree under review rather than whatever happens to be the daemon's
    /// working directory when the suite runs.
    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)          // .../Tests/SageVoiceCoreTests/<this file>
            .deletingLastPathComponent()         // .../Tests/SageVoiceCoreTests
            .deletingLastPathComponent()         // .../Tests
            .deletingLastPathComponent()         // the repository root
    }

    /// Source the off-Darwin build never sees, and which therefore cannot carry
    /// this defect. `MynahMac` and `Mynah` are AppKit and are not so much as
    /// *declared* in the manifest off Darwin; `SageVoiceCore/Call` is dropped
    /// there by `coreExclusions`, because the live voice call is not ported.
    static let darwinOnlySourceDirectories = [
        "Sources/MynahMac/",
        "Sources/Mynah/",
        "Sources/SageVoiceCore/Call/"
    ]

    enum ScanFailure: Error, CustomStringConvertible {
        case unreadable(String)

        var description: String {
            switch self {
            case .unreadable(let path):
                return "could not read \(path), so the scan checked nothing"
            }
        }
    }

    /// Repository-relative paths of every Swift file a Linux build compiles.
    static func sourceFilesTheOffDarwinBuildCompiles() throws -> [String] {
        let sources = repositoryRoot.appendingPathComponent("Sources")
        guard let walk = FileManager.default.enumerator(atPath: sources.path) else {
            throw ScanFailure.unreadable(sources.path)
        }

        var found: [String] = []
        for case let entry as String in walk {
            guard entry.hasSuffix(".swift") else { continue }
            let relative = "Sources/" + entry
            guard !darwinOnlySourceDirectories.contains(where: { relative.hasPrefix($0) }) else {
                continue
            }
            found.append(relative)
        }
        return found.sorted()
    }

    /// Real calls only, as `path:line`. A mention in a comment is not a call —
    /// `MCPClient` explains in prose why it does *not* use `waitUntilExit()`,
    /// and a scan that reported that line would be worse than no scan.
    ///
    /// **A call inside `#if canImport(Darwin)` is not a call either**, and this
    /// has to be understood rather than exempted by path. The portable wait in
    /// `ProcessExitWait.swift` forwards to `waitUntilExit()` on Darwin so the
    /// shipped Mac behaviour is untouched, and guards it off everywhere else —
    /// which is exactly the shape this test wants to see, and the shape a
    /// name-only scan reads as the defect it was written to catch. Without
    /// this, the one correct way to write the fix is the one thing the guard
    /// forbids, and the next person deletes the guard instead of the defect.
    ///
    /// Only `canImport(Darwin)` and `os(macOS)` count as Darwin-only. Anything
    /// else — a bare `#if DEBUG`, an `#else`, a condition this does not
    /// recognise — is treated as compiled off Darwin, so an unfamiliar guard
    /// fails loudly rather than silently hiding a real call.
    static func callsToWaitUntilExit(in files: [String]) throws -> [String] {
        var found: [String] = []
        for relative in files {
            let url = repositoryRoot.appendingPathComponent(relative)
            let source = try String(contentsOf: url, encoding: .utf8)
            var state = ScanState()
            var darwinOnly: [Bool] = []
            let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
            for (offset, line) in lines.enumerated() {
                let code = codeOnly(String(line), state: &state)
                let trimmed = code.trimmingCharacters(in: .whitespaces)

                if trimmed.hasPrefix("#if") {
                    darwinOnly.append(Self.isDarwinOnly(trimmed))
                } else if trimmed.hasPrefix("#elseif") {
                    if !darwinOnly.isEmpty { darwinOnly[darwinOnly.count - 1] = Self.isDarwinOnly(trimmed) }
                } else if trimmed.hasPrefix("#else") {
                    if !darwinOnly.isEmpty { darwinOnly[darwinOnly.count - 1] = false }
                } else if trimmed.hasPrefix("#endif") {
                    if !darwinOnly.isEmpty { darwinOnly.removeLast() }
                } else if code.contains("waitUntilExit()"), !darwinOnly.contains(true) {
                    found.append("\(relative):\(offset + 1)")
                }
            }
        }
        return found
    }

    /// Whether this `#if`/`#elseif` condition means "Darwin only".
    ///
    /// Deliberately narrow: an `||` can widen a Darwin-only branch to include
    /// Linux, so a condition carrying one is not trusted.
    static func isDarwinOnly(_ condition: String) -> Bool {
        guard !condition.contains("||") else { return false }
        return condition.contains("canImport(Darwin)") || condition.contains("os(macOS)")
    }

    /// Carried between lines, because a block comment and a multi-line string
    /// literal both outlive the line that opened them.
    struct ScanState {
        var inBlockComment = false
        var inMultilineString = false
    }

    /// One line with its comments and string literals removed, so what is left
    /// is code. Not a Swift parser — it is deliberately the smallest thing that
    /// cannot mistake documentation for a call, which is the only error that
    /// would matter here.
    static func codeOnly(_ line: String, state: inout ScanState) -> String {
        let characters = Array(line)
        var code = ""
        var inStringLiteral = false
        var index = 0

        func peek(_ ahead: Int) -> Character? {
            let position = index + ahead
            return position < characters.count ? characters[position] : nil
        }

        while index < characters.count {
            let character = characters[index]

            if state.inBlockComment {
                if character == "*", peek(1) == "/" {
                    state.inBlockComment = false
                    index += 2
                } else {
                    index += 1
                }
                continue
            }

            if state.inMultilineString {
                if character == "\"", peek(1) == "\"", peek(2) == "\"" {
                    state.inMultilineString = false
                    index += 3
                } else {
                    index += 1
                }
                continue
            }

            if inStringLiteral {
                if character == "\\" {
                    index += 2
                } else {
                    if character == "\"" { inStringLiteral = false }
                    index += 1
                }
                continue
            }

            if character == "/", peek(1) == "/" { break }

            if character == "/", peek(1) == "*" {
                state.inBlockComment = true
                index += 2
                continue
            }

            if character == "\"", peek(1) == "\"", peek(2) == "\"" {
                state.inMultilineString = true
                index += 3
                continue
            }

            if character == "\"" {
                inStringLiteral = true
                index += 1
                continue
            }

            code.append(character)
            index += 1
        }
        return code
    }

    /// A declaration, not a mention: only modifiers may stand before `class`,
    /// which keeps prose in a doc comment and a name inside a string literal
    /// out of the answer.
    static func declaredTestCaseClass(in line: String) -> String? {
        let words = line.trimmingCharacters(in: .whitespaces).split(separator: " ")
        guard let keyword = words.firstIndex(of: "class"), keyword + 1 < words.count else {
            return nil
        }

        let modifiers = Set(words[..<keyword].map(String.init))
        let known: Set<String> = ["open", "public", "internal", "fileprivate", "private", "final"]
        guard modifiers.isSubset(of: known) else { return nil }
        guard modifiers.isDisjoint(with: ["private", "fileprivate"]) else { return nil }

        let declaration = words[(keyword + 1)...].joined(separator: " ")
        guard let colon = declaration.firstIndex(of: ":") else { return nil }
        guard declaration[declaration.index(after: colon)...].contains("XCTestCase") else {
            return nil
        }

        let name = declaration[..<colon].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
            return nil
        }
        return name
    }
}
