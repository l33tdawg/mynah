import XCTest
@testable import SageVoiceCore

/// Off-Darwin, the owner installs SAGE himself and Mynah has to find it.
///
/// That is the only supported Linux arrangement — nothing is vendored there —
/// so a resolver that only knows `/Applications/SAGE.app` cannot answer on any
/// real Linux machine. The product shipped two detectors that disagreed:
/// `EnvironmentProbe.probeSage` searched `PATH` and the well-known install
/// directories and found the node, while `SageNodeChoice` looked in two macOS
/// Applications folders and did not. Setup printed one answer; the daemon died
/// naming the other.
///
/// The half of this that is platform-independent — the search list and the
/// version-line parser — is tested on every platform, because a macOS test run
/// that cannot see the Linux code is how the Linux code rots.
final class SageNodeChoiceLinuxTests: XCTestCase {

    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sage-linux-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    // MARK: Fixtures

    /// A binary that answers `version` the way SAGE does, and nothing else.
    ///
    /// A script rather than a mock, so the argument, the exit code and the
    /// output shape are all exercised for real. `--version` deliberately fails
    /// here exactly as it fails on the real thing.
    @discardableResult
    private func makeExecutable(named name: String, script: String, in directory: URL) -> URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        FileManager.default.createFile(
            atPath: url.path,
            contents: Data(script.utf8),
            attributes: [.posixPermissions: 0o755]
        )
        return url
    }

    @discardableResult
    private func makeRealSage(named name: String = "sage", in directory: URL) -> URL {
        makeExecutable(
            named: name,
            script: """
            #!/bin/sh
            if [ "$1" = "version" ]; then
              echo "sage-gui 11.18.14 (commit 5053ca0c, built 2026-08-16T04:48:49Z)"
              exit 0
            fi
            echo "Unknown command: $1" >&2
            exit 1
            """,
            in: directory
        )
    }

    /// SageMath. Installs a `sage` on `PATH`, on exactly the kind of Linux box
    /// this runs on, and it is not a memory node.
    @discardableResult
    private func makeSageMath(named name: String = "sage", in directory: URL) -> URL {
        makeExecutable(
            named: name,
            script: """
            #!/bin/sh
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

    // MARK: The version line is the identity, and it has a real shape

    /// Measured against SAGE 11.18.14, not guessed.
    func testTheRealSageVersionLineIsRecognised() {
        let banner = SageNodeLocator.parseVersionBanner(
            "sage-gui 11.18.14 (commit 5053ca0c, built 2026-08-16T04:48:49Z)\n"
        )
        XCTAssertEqual(banner?.program, "sage-gui")
        XCTAssertEqual(banner?.version, "11.18.14")
    }

    /// A SAGE built from source without the release ldflags is still SAGE.
    func testASourceBuiltVersionLineIsStillRecognised() {
        XCTAssertNotNil(
            SageNodeLocator.parseVersionBanner("sage dev (commit unknown, built unknown)"),
            "a locally built SAGE would be refused, and the owner told to reinstall a working node"
        )
    }

    /// The collision this check exists for.
    func testSageMathIsNotMistakenForTheOwnersMemory() {
        XCTAssertNil(
            SageNodeLocator.parseVersionBanner("SageMath version 10.3, Release Date: 2024-03-19"),
            "SageMath would be run as the owner's brain"
        )
    }

    /// Nor is anything else that merely says the word.
    func testOtherProgramsAreNotMistakenForSage() {
        for line in [
            "Docker version 24.0.5, build ced0996",
            "go version go1.22.0 linux/amd64",
            "sage",
            "",
            "Error: /usr/bin/sage was built from commit abc123"
        ] {
            XCTAssertNil(
                SageNodeLocator.parseVersionBanner(line),
                "\"\(line)\" was accepted as a SAGE version line"
            )
        }
    }

    /// `version`, not `--version`.
    ///
    /// SAGE 11.18.14 has no `--version` flag: it prints `Unknown command` and
    /// the whole usage banner. A check written against the flag everyone
    /// assumes exists would refuse every genuine node on the machine.
    func testTheVersionArgumentIsTheOneSageActuallyHas() {
        XCTAssertEqual(SageNodeLocator.versionArgument, "version")

        let sage = makeRealSage(in: root.appendingPathComponent("bin"))
        XCTAssertTrue(
            SageNodeLocator.identify(executableAt: sage).isProven,
            "the identity check does not ask the question SAGE can answer"
        )
    }

    /// Running it is the check, and a refusal says what it saw.
    func testAnImpostorIsRefusedAndTheRefusalSaysWhy() {
        let impostor = makeSageMath(in: root.appendingPathComponent("bin"))
        let evidence = SageNodeLocator.identify(executableAt: impostor)

        XCTAssertFalse(evidence.isProven, "SageMath passed as the owner's node")
        XCTAssertTrue(
            evidence.evidence.contains("version"),
            "the refusal does not say what was asked or what came back: \(evidence.evidence)"
        )
    }

    /// A binary that never answers must not hang the daemon's startup.
    func testABinaryThatNeverAnswersTimesOutRatherThanHanging() {
        let wedged = makeExecutable(
            named: "sage",
            script: "#!/bin/sh\nsleep 60\n",
            in: root.appendingPathComponent("wedged")
        )
        let started = Date()
        let evidence = SageNodeLocator.identify(executableAt: wedged, timeout: 1)

        XCTAssertEqual(evidence, .timedOut)
        XCTAssertLessThan(
            Date().timeIntervalSince(started), 15,
            "a wedged binary held the resolver open"
        )
    }

    /// Nothing there is not the same as refused.
    func testAMissingBinaryIsReportedAsMissing() {
        let missing = root.appendingPathComponent("nowhere/sage")
        guard case .notExecutable = SageNodeLocator.identify(executableAt: missing) else {
            return XCTFail("a path with nothing at it was not reported as such")
        }
    }

    // MARK: One search, not two

    /// `PATH` first, then the well-known locations — the same order, and the
    /// same call, `EnvironmentProbe.probeSage` uses.
    func testTheSearchFindsABinaryOnPath() {
        let bin = root.appendingPathComponent("bin")
        let sage = makeRealSage(in: bin)

        let found = SageNodeLocator.locateInstalledExecutable(
            environment: ["PATH": bin.path],
            homeDirectory: root
        )
        XCTAssertEqual(found?.path, sage.path)
    }

    /// And in the places a user-installed SAGE actually lands.
    func testTheSearchFindsAHomeInstalledBinary() {
        for relative in SageNodeLocator.installedHomeRelativePaths where !relative.contains(".app") {
            let home = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let target = home.appendingPathComponent(relative)
            makeExecutable(
                named: target.lastPathComponent,
                script: "#!/bin/sh\nexit 0\n",
                in: target.deletingLastPathComponent()
            )

            let found = SageNodeLocator.locateInstalledExecutable(
                environment: ["PATH": "/nonexistent"],
                homeDirectory: home
            )
            XCTAssertEqual(
                found?.path, target.path,
                "a SAGE installed at ~/\(relative) is invisible to the daemon"
            )
        }
    }

    /// The list and the single answer cannot disagree.
    ///
    /// `locateInstalledExecutable` is the literal `ExecutableLookup.find` call
    /// `EnvironmentProbe.probeSage` makes; `installedExecutableCandidates` is
    /// the same search kept whole. If the first of the list ever stopped being
    /// what the probe would have picked, the resolver and the probe would be
    /// back to disagreeing — just more subtly than before.
    func testTheFirstCandidateIsWhatTheProbeWouldHaveFound() {
        let bin = root.appendingPathComponent("bin")
        makeSageMath(in: bin)
        makeRealSage(named: "sagectl", in: bin)
        makeRealSage(in: root.appendingPathComponent(".sage/bin"))

        let environment = ["PATH": bin.path]
        let candidates = SageNodeLocator.installedExecutableCandidates(
            environment: environment,
            homeDirectory: root
        )
        let single = SageNodeLocator.locateInstalledExecutable(
            environment: environment,
            homeDirectory: root
        )

        XCTAssertEqual(candidates.first?.path, single?.path)
        XCTAssertEqual(candidates.count, 3, "the search lost a candidate: \(candidates.map(\.path))")
    }

    /// **The two detectors must not drift apart again.**
    ///
    /// This is the actual defect: `EnvironmentProbe.probeSage` and
    /// `SageNodeChoice` each knew where SAGE lives, and they knew different
    /// things. The lists now live on `SageNodeLocator`; `probeSage` still
    /// spells them as literals because it is not this change's to edit, so this
    /// test reads its source and fails the moment the two disagree.
    ///
    /// The fix when it fails is to make `probeSage` call
    /// `SageNodeLocator.installedExecutableNames` and
    /// `installedHomeRelativePaths` — not to update the copy.
    func testBothDetectorsSearchTheSamePlaces() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: repository
                .appendingPathComponent("Sources/SageVoiceCore/Setup/EnvironmentProbe.swift"),
            encoding: .utf8
        )

        guard let probeStart = source.range(of: "private func probeSage()"),
              let call = source.range(of: "let executable = locate(", range: probeStart.upperBound..<source.endIndex),
              let callEnd = source.range(of: "\n        )", range: call.upperBound..<source.endIndex) else {
            return XCTFail("probeSage no longer has a recognisable search; check it by hand")
        }
        let searchCall = String(source[call.upperBound..<callEnd.lowerBound])

        guard let namesEnd = searchCall.range(of: "]"),
              let homeStart = searchCall.range(of: "homeRelativePaths: [") else {
            return XCTFail("probeSage's search no longer names its two lists")
        }
        let probeNames = quotedStrings(in: String(searchCall[searchCall.startIndex..<namesEnd.lowerBound]))
        let probeHomePaths = quotedStrings(
            in: String(searchCall[homeStart.upperBound..<searchCall.endIndex])
        )

        XCTAssertEqual(
            probeNames, SageNodeLocator.installedExecutableNames,
            "the probe and the resolver look for different binaries, so setup will report a SAGE "
                + "the daemon then refuses to run (or the reverse)"
        )
        XCTAssertEqual(
            probeHomePaths, SageNodeLocator.installedHomeRelativePaths,
            "the probe and the resolver search different directories; this is the exact split that "
                + "made the daemon die naming /Applications/SAGE.app on Linux"
        )
    }

    private func quotedStrings(in text: String) -> [String] {
        var found: [String] = []
        var current: String?
        for character in text {
            if character == "\"" {
                if let value = current {
                    found.append(value)
                    current = nil
                } else {
                    current = ""
                }
            } else if current != nil {
                current?.append(character)
            }
        }
        return found
    }

    // MARK: What the resolver does off-Darwin

    #if !canImport(Darwin)

    /// The defect, in one test: a user-installed SAGE on `PATH` is the node.
    func testAUserInstalledSageOnPathIsFound() {
        let bin = root.appendingPathComponent("bin")
        let sage = makeRealSage(in: bin)

        let choice = SageNodeChoice.resolve(
            vendored: nil,
            installedCandidates: SageNodeChoice.defaultInstalledCandidates(
                homeDirectory: root,
                environment: ["PATH": bin.path]
            )
        )

        XCTAssertEqual(choice?.executable.path, sage.path, "the daemon still cannot find SAGE")
        XCTAssertEqual(choice?.source, .installed)
        XCTAssertFalse(
            choice?.mayBeManagedByMynah == true,
            "Mynah believes it may replace a node the owner installed himself"
        )
    }

    /// And it is not trusted for its name.
    func testAnExecutableNamedSageThatIsNotSageIsRefusedNotUsed() {
        let bin = root.appendingPathComponent("bin")
        makeSageMath(in: bin)

        let candidates = SageNodeChoice.defaultInstalledCandidates(
            homeDirectory: root,
            environment: ["PATH": bin.path]
        )
        XCTAssertFalse(candidates.isEmpty, "the search did not even see it")

        let choice = SageNodeChoice.resolve(vendored: nil, installedCandidates: candidates)
        XCTAssertNil(choice, "SageMath was handed to the daemon as the owner's memory")
    }

    /// SageMath in front of the owner's node must not end the search.
    ///
    /// This is the case that makes refusing-loudly insufficient on its own: the
    /// machine really does have SAGE, it is just second in line. Stopping at
    /// the first `sage` would tell the owner to go and install what he already
    /// has.
    func testAnImpostorFirstOnPathDoesNotHideTheRealNode() {
        let bin = root.appendingPathComponent("bin")
        makeSageMath(in: bin)
        let real = makeRealSage(in: root.appendingPathComponent(".sage/bin"))

        let choice = SageNodeChoice.resolve(
            vendored: nil,
            installedCandidates: SageNodeChoice.defaultInstalledCandidates(
                homeDirectory: root,
                environment: ["PATH": bin.path]
            )
        )

        XCTAssertEqual(
            choice?.executable.path, real.path,
            "SageMath shadowed the owner's real node and Mynah gave up"
        )
    }

    /// A refusal has to name itself and name the next action.
    func testTheRefusalNamesWhatItFoundAndWhatToDo() {
        let bin = root.appendingPathComponent("bin")
        let impostor = makeSageMath(in: bin)

        let outcome = SageNodeChoice.decide(
            vendored: nil,
            installedCandidates: SageNodeChoice.defaultInstalledCandidates(
                homeDirectory: root,
                environment: ["PATH": bin.path]
            )
        )
        guard case .failure(let error) = outcome else {
            return XCTFail("an unidentified binary was accepted")
        }

        let message = error.description
        XCTAssertTrue(message.contains(impostor.path), "the refusal does not say which binary: \(message)")
        XCTAssertTrue(message.contains("--sage"), "the refusal does not say what to do next: \(message)")
    }

    /// Nothing installed is an answer, and it says where it looked.
    func testNothingInstalledSaysWhereItLookedAndHowToFixIt() {
        let outcome = SageNodeChoice.decide(
            vendored: nil,
            installedCandidates: SageNodeChoice.defaultInstalledCandidates(
                homeDirectory: root,
                environment: ["PATH": "/nonexistent"]
            )
        )
        guard case .failure(.noNodeInstalled(let searched)) = outcome else {
            return XCTFail("a machine with no SAGE produced something other than 'no SAGE'")
        }

        XCTAssertTrue(searched.contains { $0.hasPrefix("PATH") }, "\(searched)")
        XCTAssertTrue(
            outcome.failureDescription.contains("github.com"),
            "the owner is not told where to get SAGE: \(outcome.failureDescription)"
        )
    }

    /// A Mac build unpacked into a Linux home directory is still recognised for
    /// what it is — by its bundle identifier, not by running it.
    func testAnUnpackedMacBundleStillProvesItselfTheMacWay() {
        let bundle = root.appendingPathComponent("Applications/SAGE.app")
        let macos = bundle.appendingPathComponent("Contents/MacOS")
        makeExecutable(
            named: SageNodeLocator.executableName,
            script: "#!/bin/sh\nexit 1\n",
            in: macos
        )
        let plist = try? PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": SageNodeLocator.expectedBundleIdentifier],
            format: .xml,
            options: 0
        )
        try? plist?.write(to: bundle.appendingPathComponent("Contents/Info.plist"))

        let choice = SageNodeChoice.resolve(vendored: nil, installedCandidates: [bundle])
        XCTAssertEqual(
            choice?.executable.path,
            macos.appendingPathComponent(SageNodeLocator.executableName).path
        )
    }

    #endif
}

private extension Result where Failure == SageNodeError {
    var failureDescription: String {
        if case .failure(let error) = self { return error.description }
        return ""
    }
}
