import XCTest

/// **The daemon downloaded a 129 MB macOS archive on every Linux start.**
///
/// `sage-voiced daemon` defaults to `--provider ollama`, and both places that
/// acted on that reached `OllamaRuntimeInstaller` with no platform guard:
///
///   * `runDaemon` called `LocalBrainInstaller(runtime: .shared).install()` at
///     boot, and
///   * `makeBackend` handed the same installer to `OllamaBackend` as its
///     `managedRuntime`, which calls `ensureRuntimeAvailable()` from
///     `complete()` — so on Linux *every turn* would have tried again.
///
/// What it fetches is `ollama-darwin.tgz`: Mach-O binaries, pinned by digest,
/// unpacked by shelling `/usr/bin/tar`. On Linux the download is wasted before
/// the extraction fails, and it happened on machines that already had a working
/// `ollama serve` on 11434.
///
/// The owner's ruling for SAGE applies here too — off Darwin the runtime is the
/// owner's to install, and Mynah only detects it. So these assert on a property
/// stronger than "somebody added a guard": **no line that a non-Darwin compiler
/// would even see may mention the installer, the Mac app directory or
/// `/usr/bin/open`.**
///
/// The mirror-image assertions matter just as much. Deleting the feature
/// off Darwin would satisfy every negative test above, so each one is paired
/// with a check that the Mac still does what it did and that Linux says out
/// loud what it wants instead.
final class TheDarwinArchiveStaysOnDarwinTests: XCTestCase {

    private static let daemonSourcePath = "Sources/sage-voiced/main.swift"

    private func source(_ path: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(path),
            encoding: .utf8
        )
    }

    // MARK: - the analyser

    /// What one `#if` branch is worth to a compiler that is not building for a Mac.
    private enum Reach {
        /// Definitely compiled off Darwin — `#if !os(macOS)`.
        case yes
        /// Definitely not — `#if os(macOS)`.
        case no
        /// Not about the platform at all (`canImport(KokoroEngine)`), so it has
        /// to be treated as compiled. Assuming otherwise would let a real
        /// unguarded call hide inside a neutral `#if` and pass.
        case maybe
    }

    private static func reach(ofCondition condition: String) -> Reach {
        let c = condition.replacingOccurrences(of: " ", with: "")
        // Only the exact forms this file uses are decided. Anything compound —
        // `os(macOS) || os(iOS)` — falls through to `.maybe`, which is the
        // conservative answer: it keeps the line in view of the assertions.
        switch c {
        case "os(macOS)", "canImport(Darwin)", "canImport(AppKit)", "canImport(EventKit)":
            return .no
        case "!os(macOS)", "!canImport(Darwin)":
            return .yes
        default:
            return .maybe
        }
    }

    /// The lines of `source` a non-Darwin compiler would still see.
    ///
    /// Line numbers are kept so a failure can name where to look.
    private static func compiledOffDarwin(_ source: String) -> [(line: Int, text: String)] {
        /// One `#if` chain: whether the branch now open reaches off Darwin, and
        /// what the branches already closed were worth (for `#else`).
        struct Frame {
            var current: Reach
            var anyEarlierYes: Bool
            var anyEarlierMaybe: Bool
        }
        var stack: [Frame] = []
        var kept: [(line: Int, text: String)] = []

        for (index, raw) in source.components(separatedBy: "\n").enumerated() {
            let text = raw.trimmingCharacters(in: .whitespaces)

            if text.hasPrefix("#if ") {
                let r = Self.reach(ofCondition: String(text.dropFirst(4)))
                stack.append(Frame(
                    current: r,
                    anyEarlierYes: r == .yes,
                    anyEarlierMaybe: r == .maybe
                ))
                continue
            }
            if text.hasPrefix("#elseif "), !stack.isEmpty {
                let r = Self.reach(ofCondition: String(text.dropFirst(8)))
                stack[stack.count - 1].anyEarlierYes = stack[stack.count - 1].anyEarlierYes || r == .yes
                stack[stack.count - 1].anyEarlierMaybe = stack[stack.count - 1].anyEarlierMaybe || r == .maybe
                stack[stack.count - 1].current = r
                continue
            }
            if text == "#else", !stack.isEmpty {
                let frame = stack[stack.count - 1]
                // Reached only when nothing before it was taken.
                if frame.anyEarlierYes {
                    stack[stack.count - 1].current = .no
                } else if frame.anyEarlierMaybe {
                    stack[stack.count - 1].current = .maybe
                } else {
                    stack[stack.count - 1].current = .yes
                }
                continue
            }
            if text == "#endif" {
                if !stack.isEmpty { stack.removeLast() }
                continue
            }

            if stack.allSatisfy({ $0.current != .no }) {
                kept.append((line: index + 1, text: raw))
            }
        }
        return kept
    }

    /// Prose is not code. These files argue with themselves in comments —
    /// this one names `OllamaRuntimeInstaller` and the `/Applications` path in
    /// order to explain why neither may be reached — and a test that matched on
    /// comment text would go red for the documentation and could never go green.
    ///
    /// Whole-line comments only. A trailing `//` is left alone because stripping
    /// it means finding the end of a string literal, and `https://ollama.com`
    /// inside the refusal text is exactly the thing that would be cut in half.
    private static func code(_ lines: [(line: Int, text: String)]) -> [(line: Int, text: String)] {
        lines.filter { !$0.text.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }

    /// The body of one top-level `func`, from its signature to the next
    /// declaration at column zero.
    ///
    /// **Whole-file matching was not enough, and a mutation proved it.** The
    /// daemon's readiness check was deleted outright and the file-wide assertion
    /// stayed green, because `runBrain` still carried a call to the same
    /// function — a passing test over a daemon that starts on Linux with no
    /// brain and says nothing. Each entry point is now asked about itself.
    private static func body(ofFunction name: String, in source: String) -> String {
        let lines = source.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix("func \(name)(") }) else {
            return ""
        }
        var end = lines.count
        for index in (start + 1)..<lines.count where lines[index].hasPrefix("func ")
            || lines[index].hasPrefix("// MARK:") {
            end = index
            break
        }
        return lines[start..<end].joined(separator: "\n")
    }

    /// **The analyser is the thing every other test here leans on**, so it is
    /// tested first. A broken one would report an empty off-Darwin source and
    /// green every assertion below while the bug shipped — which is the exact
    /// failure mode this whole file exists to catch.
    func testTheAnalyserSeesWhatANonDarwinCompilerSees() {
        let sample = """
        alwaysA
        #if os(macOS)
        macOnly
        #else
        elseOfMac
        #endif
        #if !os(macOS)
        offDarwinOnly
        #else
        elseOfOffDarwin
        #endif
        #if canImport(KokoroEngine)
        neutralBranch
        #else
        neutralElse
        #endif
        // aCommentMentioningMacOnly
        #if os(macOS)
        outerMac
        #if canImport(KokoroEngine)
        nestedInsideMac
        #endif
        #endif
        alwaysB
        """
        let seen = Set(Self.compiledOffDarwin(sample).map { $0.text })

        XCTAssertEqual(
            seen,
            [
                "alwaysA", "elseOfMac", "offDarwinOnly", "neutralBranch", "neutralElse",
                "// aCommentMentioningMacOnly", "alwaysB"
            ],
            "the #if analyser disagrees with what a Linux compiler would read, so every "
                + "guard test in this file is measuring the wrong text"
        )
        XCTAssertEqual(
            Self.code(Self.compiledOffDarwin(sample)).map(\.text)
                .filter { $0.contains("aCommentMentioningMacOnly") },
            [],
            "whole-line comments are being matched as code, so this file would go red for "
                + "the prose that explains itself"
        )

        let two = """
        func runOne(_ x: Int) -> Never {
            insideOne
        }

        func runTwo(_ x: Int) -> Never {
            insideTwo
        }
        """
        XCTAssertTrue(Self.body(ofFunction: "runOne", in: two).contains("insideOne"))
        XCTAssertFalse(
            Self.body(ofFunction: "runOne", in: two).contains("insideTwo"),
            "the slicer runs past the end of the function, so one entry point's guard would "
                + "vouch for another's — the exact hole a mutation opened here once"
        )
        XCTAssertEqual(
            Self.body(ofFunction: "runNowhere", in: two), "",
            "a renamed function must slice to nothing, so the assertion that reads it fails "
                + "loudly instead of passing over an empty string"
        )
    }

    // MARK: - nothing Mac-shaped survives off Darwin

    func testTheMacOllamaInstallerIsUnreachableOffDarwin() throws {
        let offDarwin = Self.code(Self.compiledOffDarwin(try source(Self.daemonSourcePath)))

        for name in ["OllamaRuntimeInstaller", "LocalBrainInstaller"] {
            let hits = offDarwin.filter { $0.text.contains(name) }
            XCTAssertTrue(
                hits.isEmpty,
                "\(Self.daemonSourcePath) reaches \(name) off Darwin at line(s) "
                    + "\(hits.map(\.line)) — that installer downloads ollama-darwin.tgz "
                    + "(129 MB of Mach-O, verified by digest, unpacked with /usr/bin/tar), "
                    + "so a Linux daemon fetches a Mac archive it can never run. "
                    + "Detect a user-installed Ollama instead; see UserInstalledOllama."
            )
        }
    }

    func testTheMacApplicationDirectoryIsUnreachableOffDarwin() throws {
        let offDarwin = Self.code(Self.compiledOffDarwin(try source(Self.daemonSourcePath)))
        let hits = offDarwin.filter { $0.text.contains("/Applications/") }

        XCTAssertTrue(
            hits.isEmpty,
            "\(Self.daemonSourcePath) falls back to a /Applications path off Darwin at line(s) "
                + "\(hits.map(\.line)) — there is no /Applications on Linux, so MCPClient fails "
                + "to spawn and names a Mac directory, which reads like a broken build rather "
                + "than 'install SAGE and pass --sage'."
        )
    }

    func testNoMacOnlyProgramIsShelledOffDarwin() throws {
        let offDarwin = Self.code(Self.compiledOffDarwin(try source(Self.daemonSourcePath)))
        let hits = offDarwin.filter { $0.text.contains("/usr/bin/open") }

        XCTAssertTrue(
            hits.isEmpty,
            "\(Self.daemonSourcePath) shells /usr/bin/open off Darwin at line(s) "
                + "\(hits.map(\.line)) — that program is macOS's. `try? run()` on a path that "
                + "does not exist swallows the failure, so the owner waits on a browser that "
                + "is never coming."
        )
    }

    // MARK: - and the honest behaviour is actually there

    /// Deleting the ollama path off Darwin would pass every test above. This is
    /// the half that says the daemon still refuses out loud, and names the
    /// command that fixes it.
    func testLinuxRefusesByNameAndSaysHowToInstallOllama() throws {
        let whole = try source(Self.daemonSourcePath)
        let offDarwin = Self.code(Self.compiledOffDarwin(whole)).map(\.text).joined(separator: "\n")

        // Both entry points that can build an Ollama backend, each checked in
        // its own body. See `body(ofFunction:in:)` for why one file-wide match
        // was not enough.
        for entryPoint in ["runDaemon", "runBrain"] {
            let body = Self.body(ofFunction: entryPoint, in: whole)
            XCTAssertFalse(body.isEmpty, "\(entryPoint) has been renamed, so this test reads nothing")
            let reachable = Self.code(Self.compiledOffDarwin(body)).map(\.text).joined(separator: "\n")
            XCTAssertTrue(
                reachable.contains("UserInstalledOllama.refusal("),
                "\(entryPoint) never checks off Darwin whether the local runtime is actually "
                    + "there, so it comes up 'ready' with no brain and meets the owner's first "
                    + "voice note with dead air"
            )
        }
        for door in ["ollama serve", "ollama pull", "https://ollama.com"] {
            XCTAssertTrue(
                offDarwin.contains(door),
                "the off-Darwin refusal never mentions '\(door)', so it is a dead end with no "
                    + "door: it says the runtime is missing without saying how to get one"
            )
        }
        // The SAGE-node door, read out of the refusal itself rather than out of
        // the whole file. `usage()` also prints `--sage PATH`, so a file-wide
        // match would vouch for a refusal that had lost its door entirely.
        //
        // **The spelling here is the product's, not this test's.** It asserted
        // `--sage /path/to/sage-gui` for a while and went red on both platforms
        // for a product that was right: `sage-gui` is the name of the executable
        // *inside the Mac app bundle*
        // (`/Applications/SAGE.app/Contents/MacOS/sage-gui`), and `--sage` takes
        // a path to whatever the owner's SAGE binary is called. Off Darwin that
        // is normally plain `sage` — `SageNodeLocator` accepts `sage`,
        // `sage-gui`, `sagectl` and `saged`, and deliberately does not compare
        // the name against the filename at all. Every producer of this sentence
        // spells the placeholder `/path/to/sage`: main.swift's `sageNodeRefusal`
        // and both `SageNodeError` descriptions in `SageNodeLocator`. Telling a
        // Linux owner to type a Mac bundle's executable name would have been the
        // defect; the test inventing one was.
        let refusal = Self.body(ofFunction: "sageNodeRefusal", in: whole)
        XCTAssertFalse(
            refusal.isEmpty,
            "sageNodeRefusal has been renamed, so this test reads nothing and would pass over "
                + "a Linux daemon that dies without naming the flag that would fix it"
        )
        let refusalText = Self.code(Self.compiledOffDarwin(refusal)).map(\.text)
            .joined(separator: "\n")
        XCTAssertTrue(
            refusalText.contains("--sage /path/to/sage"),
            "the off-Darwin refusal for a missing SAGE node does not name the flag that "
                + "supplies one, so the daemon exits telling the owner their memory is "
                + "unreachable without telling them how to point at it"
        )
    }

    /// The Mac must be untouched: it still installs, and still has its
    /// conventional last-resort path.
    func testTheMacKeepsInstallingItsOwnRuntime() throws {
        let whole = try source(Self.daemonSourcePath)
        // Everything the analyser drops off Darwin is, by construction, the
        // Mac-only text.
        let offDarwinLines = Set(Self.compiledOffDarwin(whole).map(\.line))
        let macOnly = whole.components(separatedBy: "\n").enumerated()
            .filter { !offDarwinLines.contains($0.offset + 1) }
            .map { (line: $0.offset + 1, text: $0.element) }
        let macOnlyCode = Self.code(macOnly).map(\.text).joined(separator: "\n")

        XCTAssertTrue(
            macOnlyCode.contains("LocalBrainInstaller("),
            "the Mac no longer sets up its own local brain at daemon start — the platform "
                + "guard was supposed to spare Linux, not remove the feature from macOS"
        )
        XCTAssertTrue(
            macOnlyCode.contains("OllamaRuntimeInstaller.shared"),
            "the Mac backend no longer carries a managed runtime, so an owner whose Ollama "
                + "is not running gets a connection error instead of an install"
        )
        XCTAssertTrue(
            macOnlyCode.contains("/Applications/SAGE.app/Contents/MacOS/sage-gui"),
            "the Mac lost its conventional last-resort node path, so a daemon started by "
                + "hand with no --sage can no longer find an installed SAGE"
        )
    }

    /// One place decides which node this process talks to. Two is how one of
    /// them ends up starting a duplicate beside the owner's.
    func testOnlyOnePlaceDecidesWhichNodeToRun() throws {
        let whole = try source(Self.daemonSourcePath)
        let everyLine = whole.components(separatedBy: "\n").enumerated()
            .map { (line: $0.offset + 1, text: $0.element) }
        let occurrences = Self.code(everyLine)
            .filter { $0.text.contains("/Applications/SAGE.app/Contents/MacOS/sage-gui") }
            .count

        XCTAssertEqual(
            occurrences, 1,
            "the node path is decided in \(occurrences) places in \(Self.daemonSourcePath); "
                + "resolvedSagePath exists so there is exactly one, because the platform "
                + "guard has to be applied in exactly one"
        )
    }
}
