import XCTest
@testable import SageVoiceCore

// MARK: - The pieces the installer talks to

/// A GitHub that answers with one scripted release.
private struct ScriptedReleases: UpdateCheck.Transport {
    let status: Int
    let body: String

    func fetch(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        (status, Data(body.utf8))
    }
}

/// A download that writes whatever bytes the test wants, and reports arriving.
private struct ScriptedDownload: UpdateFetching {
    var status = 200
    /// **The bytes it writes, and they have to be the bytes the release says it
    /// published** — the release body below declares `"size":2048`, and the
    /// installer now checks what landed against it. It used to be 1024, which
    /// meant every one of these tests was quietly downloading a file half the
    /// size of the one it asked for; nothing noticed because nothing looked.
    var bytes = 2048
    var failure: Error?

    func download(
        _ request: URLRequest,
        to destination: URL,
        progress: @escaping @Sendable (UpdateTransfer) -> Void
    ) async throws -> Int {
        if let failure { throw failure }
        progress(UpdateTransfer(received: Int64(bytes / 2), expected: Int64(bytes)))
        try Data(repeating: 0x4D, count: bytes).write(to: destination)
        progress(UpdateTransfer(received: Int64(bytes), expected: Int64(bytes)))
        return status
    }
}

/// **A connection that stops part way, and then gets asked again.**
///
/// The owner's report on 22 September 2026 was "download seems to fail half way",
/// and the code behind it could only ever start the whole 670 MB again. This stub
/// is the shape of that failure: it writes the bytes it managed, throws, and
/// records what the next attempt asked for — which is where a `Range` header
/// shows up, or does not.
private final class StoppingDownload: UpdateFetching, @unchecked Sendable {

    struct Attempt: Equatable {
        /// The `Range` header, if the request carried one. `nil` on a fresh start.
        let range: String?
        /// Bytes already on disk when this attempt began.
        let alreadyOnDisk: Int
    }

    private let lock = NSLock()
    private var attempts: [Attempt] = []
    /// Bytes to write per attempt, in order. Every attempt after the last one in
    /// this list completes the file.
    private let chunks: [Int]
    /// Statuses per attempt, same indexing. Defaults to 200; 206 stands for the
    /// appended tail a resumed request earns.
    private let statuses: [Int]
    private let total: Int

    init(chunks: [Int], statuses: [Int] = [], total: Int) {
        self.chunks = chunks
        self.statuses = statuses
        self.total = total
    }

    var recordedAttempts: [Attempt] {
        lock.lock()
        defer { lock.unlock() }
        return attempts
    }

    func download(
        _ request: URLRequest,
        to destination: URL,
        progress: @escaping @Sendable (UpdateTransfer) -> Void
    ) async throws -> Int {
        let onDisk = (try? FileManager.default.attributesOfItem(atPath: destination.path))?[.size] as? Int ?? 0
        lock.lock()
        attempts.append(Attempt(range: request.value(forHTTPHeaderField: "Range"),
                                alreadyOnDisk: onDisk))
        let index = attempts.count - 1
        lock.unlock()

        // A server honouring a range answers 206; ours pretends to when the
        // request asked for the tail.
        let asked = request.value(forHTTPHeaderField: "Range")
        let status = index < statuses.count
            ? statuses[index]
            : (asked == nil ? 200 : 206)
        let written = index < chunks.count ? chunks[index] : max(0, total - onDisk)
        let tail = Data(repeating: 0x4D, count: max(0, written))
        if asked != nil, FileManager.default.fileExists(atPath: destination.path) {
            let handle = try FileHandle(forWritingTo: destination)
            try handle.seekToEnd()
            try handle.write(contentsOf: tail)
            try handle.close()
        } else {
            try tail.write(to: destination)
        }
        let final = (try? FileManager.default.attributesOfItem(atPath: destination.path))?[.size] as? Int ?? 0
        progress(UpdateTransfer(received: Int64(final), expected: Int64(total)))

        // Short of the whole file: this is the drop half way. The partial is
        // left exactly where it is, which is what the installer has to resume
        // from rather than delete.
        guard final >= total else {
            throw URLError(.networkConnectionLost)
        }
        return status
    }
}

/// `hdiutil`, `codesign` and `spctl`, answered by the test.
///
/// The closure gets the tool's name and its arguments, which is enough to tell
/// the two `codesign -dv` calls apart — one asks about the copy that is running
/// and one about the copy in the image, and the whole signer check is the
/// difference between those two answers.
private struct ScriptedTools: UpdateCommanding {
    let answer: @Sendable (String, [String]) throws -> String
    let recorder: ToolLog

    func run(_ tool: String, _ arguments: [String]) throws -> String {
        let name = URL(fileURLWithPath: tool).lastPathComponent
        recorder.note("\(name) \(arguments.joined(separator: " "))")
        return try answer(name, arguments)
    }
}

/// Locked, because the installer runs these off the test's thread and an
/// unsynchronised array of strings is how a test suite starts crashing for
/// reasons that have nothing to do with what it is testing.
private final class ToolLog: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []

    func note(_ call: String) {
        lock.lock()
        calls.append(call)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func ran(_ tool: String) -> Bool { all.contains { $0.hasPrefix(tool) } }
}

// MARK: - A Mac made of temporary directories

/// Everything the installer touches, under one folder that is deleted after.
private struct FakeMac {
    let root: URL
    /// Stands in for `/Applications`.
    let applications: URL
    /// Where the running app is.
    let app: URL
    /// Stands in for the mounted disk image.
    let volume: URL
    /// The app inside the image.
    let candidate: URL
    let support: URL

    init(identifier: String = "local.sage.voicebridge", newIdentifier: String? = nil) throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("update-\(UUID().uuidString)", isDirectory: true)
        applications = root.appendingPathComponent("Applications", isDirectory: true)
        app = applications.appendingPathComponent("Mynah.app", isDirectory: true)
        volume = root.appendingPathComponent("Volumes/Mynah", isDirectory: true)
        candidate = volume.appendingPathComponent("Mynah.app", isDirectory: true)
        support = root.appendingPathComponent("Support", isDirectory: true)

        try Self.makeApp(at: app, identifier: identifier, marker: "old")
        try Self.makeApp(at: candidate, identifier: newIdentifier ?? identifier, marker: "new")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    }

    private static func makeApp(at url: URL, identifier: String, marker: String) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": "0"]
        try PropertyListSerialization
            .data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try Data(marker.utf8).write(to: contents.appendingPathComponent("which"))
    }

    /// Which build is at the installed path — the whole question of the swap.
    func installedMarker() -> String? {
        try? String(contentsOf: app.appendingPathComponent("Contents/which"), encoding: .utf8)
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    var attachPlist: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>system-entities</key><array>
        <dict><key>dev-entry</key><string>/dev/disk4</string></dict>
        <dict><key>dev-entry</key><string>/dev/disk4s1</string>
        <key>mount-point</key><string>\(volume.path)</string></dict>
        </array></dict></plist>
        """
    }
}

private func releaseBody(
    tag: String = "v1.3.0",
    assets: String = """
    {"name":"Mynah-1.3.0-macOS-arm64.dmg",
     "browser_download_url":"https://github.com/l33tdawg/mynah/releases/download/v1.3.0/Mynah-1.3.0-macOS-arm64.dmg",
     "size":2048}
    """
) -> String {
    """
    {"tag_name":"\(tag)","name":"Mynah \(tag)",
     "html_url":"https://github.com/l33tdawg/mynah/releases/tag/\(tag)",
     "assets":[\(assets)]}
    """
}

// MARK: - Tests

final class UpdateInstallTests: XCTestCase {

    private var mac: FakeMac!
    private var log: ToolLog!

    override func setUpWithError() throws {
        mac = try FakeMac()
        log = ToolLog()
    }

    override func tearDown() {
        mac?.tearDown()
        mac = nil
        super.tearDown()
    }

    /// Every tool answering the way it does on a Mac where the download is
    /// genuinely the same app from the same signer.
    private func everythingAgrees(team: String = "2N7GKZ8D8Z") -> ScriptedTools {
        let plist = mac.attachPlist
        return ScriptedTools(
            answer: { tool, arguments in
                switch tool {
                case "hdiutil":
                    return arguments.first == "attach" ? plist : ""
                case "codesign":
                    return arguments.first == "-dv" ? "TeamIdentifier=\(team)\n" : ""
                default:
                    return "accepted\nsource=Notarized Developer ID"
                }
            },
            recorder: log
        )
    }

    private func installer(
        running: String = "1.2.0",
        release: String = releaseBody(),
        status: Int = 200,
        download: any UpdateFetching = ScriptedDownload(),
        tools: UpdateCommanding? = nil,
        bundle: URL? = nil
    ) -> UpdateInstaller {
        UpdateInstaller(
            runningVersion: running,
            bundleURL: bundle ?? mac.app,
            bundleIdentifier: "local.sage.voicebridge",
            support: mac.support,
            transport: ScriptedReleases(status: status, body: release),
            fetcher: download,
            commands: tools ?? everythingAgrees()
        )
    }

    private func run(_ installer: UpdateInstaller) async -> Result<String, UpdateInstallProblem> {
        await installer.run { _ in }
    }

    // MARK: The whole errand

    /// **The report: "download seems to fail half way."**
    ///
    /// A transfer that stops at 1024 of 2048 bytes used to be the end of the
    /// errand — the partial was deleted and the owner was told the download had
    /// stopped, having paid for half a gigabyte that went in the bin. Now the
    /// next attempt asks for `bytes=1024-`, the server answers 206 with the tail,
    /// and the file becomes the whole release.
    func testADownloadThatStopsHalfWayIsPickedUpWhereItLeftOff() async throws {
        let download = StoppingDownload(chunks: [1024], total: 2048)
        let outcome = await run(installer(download: download))

        let attempts = download.recordedAttempts
        XCTAssertEqual(attempts.count, 2, "it did not try again: \(attempts)")
        XCTAssertNil(attempts.first?.range, "the first attempt asked for a range")
        XCTAssertEqual(attempts.last?.range, "bytes=1024-", "the second attempt started over")
        XCTAssertEqual(attempts.last?.alreadyOnDisk, 1024, "the first attempt's bytes were thrown away")

        guard case .success = outcome else {
            return XCTFail("a resumed download did not finish: \(outcome)")
        }
        // And the whole errand really did complete: the new build is installed.
        XCTAssertEqual(mac.installedMarker(), "new")
    }

    /// A refused request is an *answer*, not a transfer that stopped. Asking
    /// again gets the same one, and five rounds of that is a support ticket.
    func testARefusalIsNotRetried() async throws {
        let download = StoppingDownload(chunks: [], statuses: [403], total: 2048)
        let outcome = await run(installer(download: download))

        XCTAssertEqual(download.recordedAttempts.count, 1)
        guard case .failure(.downloadRefused(403)) = outcome else {
            return XCTFail("a refusal was reported as something else: \(outcome)")
        }
    }

    /// And a download that never finishes gives up rather than looping — five
    /// attempts, then the sentence the owner already knows.
    func testADownloadThatNeverFinishesStopsTrying() async throws {
        let download = StoppingDownload(chunks: [1, 1, 1, 1, 1], total: 4096)
        let outcome = await run(installer(download: download))

        XCTAssertEqual(download.recordedAttempts.count, UpdateInstaller.downloadAttempts)
        guard case .failure(.downloadFailed) = outcome else {
            return XCTFail("an unfinished download reported something else: \(outcome)")
        }
    }

    func testInstallsTheNewerBuildAndKeepsTheOldOne() async throws {
        let outcome = await run(installer())

        XCTAssertEqual(try outcome.get(), "1.3.0")
        XCTAssertEqual(mac.installedMarker(), "new", "the app in Applications should be the download")

        let backups = mac.support.appendingPathComponent("Backups")
        let kept = try FileManager.default.contentsOfDirectory(atPath: backups.path)
        XCTAssertEqual(kept.count, 1, "the copy that was replaced should still exist")
        XCTAssertEqual(
            try String(contentsOf: backups.appendingPathComponent(kept[0])
                .appendingPathComponent("Contents/which"), encoding: .utf8),
            "old"
        )

        // 555 MB that has done its job. The app backup is kept; a release can be
        // pulled, and then the backup is the only copy of it left.
        let updates = mac.support.appendingPathComponent("Updates")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: updates.path)) ?? []
        XCTAssertEqual(leftovers, [], "the disk image should not be kept after it is installed")

        XCTAssertTrue(log.ran("hdiutil attach"), "the image has to be opened to be checked")
        XCTAssertTrue(log.all.contains { $0.hasPrefix("hdiutil detach") }, "and closed afterwards")
        XCTAssertTrue(log.ran("spctl"), "Gatekeeper's own verdict is not optional")
    }

    func testReportsEveryStageInOrder() async throws {
        let stages = StageLog()
        _ = await installer().run { stages.note($0.stage) }

        XCTAssertEqual(
            stages.distinct,
            [.finding, .downloading, .checking, .installing, .installed]
        )
    }

    func testSaysNothingIsNewerWhenTheReleaseIsNotNewer() async throws {
        let outcome = await run(installer(running: "1.3.0"))

        XCTAssertEqual(outcome.problem, .alreadyCurrent("1.3.0"))
        XCTAssertEqual(mac.installedMarker(), "old")
        XCTAssertFalse(log.ran("hdiutil"), "nothing should be downloaded to be told this")
    }

    // MARK: Refusals that happen before anything is fetched

    func testRefusesToReplaceACopyRunningFromTheDiskImage() async throws {
        // The state every owner is in for the first ten seconds: opened the DMG
        // and pressed the app inside it.
        let outcome = await run(installer(bundle: URL(fileURLWithPath: "/Volumes/Mynah/Mynah.app")))

        XCTAssertEqual(outcome.problem, .runningFromTheImage)
        XCTAssertFalse(outcome.problem?.offersThePage ?? true,
                       "the door here is Applications, not another download")
        XCTAssertTrue(outcome.problem?.spokenDescription.contains("Applications") ?? false)
    }

    func testRefusesWhenThisCopyCarriesNoSignature() async throws {
        let tools = ScriptedTools(
            answer: { tool, arguments in
                guard tool == "codesign", arguments.first == "-dv" else { return "" }
                return "Identifier=local.sage.voicebridge\nTeamIdentifier=not set\n"
            },
            recorder: log
        )
        let outcome = await run(installer(tools: tools))

        XCTAssertEqual(outcome.problem, .thisCopyIsUnsigned)
        XCTAssertFalse(log.ran("hdiutil"))
    }

    // MARK: Refusals that happen with the download already on disk

    func testRefusesAnAppThatIsNotThisApp() async throws {
        mac.tearDown()
        mac = try FakeMac(newIdentifier: "com.somebody.else")
        let outcome = await run(installer(tools: everythingAgrees()))

        XCTAssertEqual(outcome.problem, .differentApp(found: "com.somebody.else"))
        XCTAssertEqual(mac.installedMarker(), "old", "the copy that works must be left alone")
    }

    func testRefusesADownloadSignedBySomebodyElse() async throws {
        // The running copy says one team, the download says another. This is the
        // check that stops an update channel becoming a way onto the Mac.
        let plist = mac.attachPlist
        let ours = mac.app.path
        let tools = ScriptedTools(
            answer: { tool, arguments in
                switch tool {
                case "hdiutil":
                    return arguments.first == "attach" ? plist : ""
                case "codesign" where arguments.first == "-dv":
                    return arguments.last == ours
                        ? "TeamIdentifier=2N7GKZ8D8Z\n"
                        : "TeamIdentifier=ZZZZZZZZZZ\n"
                default:
                    return ""
                }
            },
            recorder: log
        )
        let outcome = await run(installer(tools: tools))

        XCTAssertEqual(outcome.problem, .differentSigner(found: "ZZZZZZZZZZ"))
        XCTAssertEqual(mac.installedMarker(), "old")
    }

    func testRefusesWhatGatekeeperRefuses() async throws {
        let plist = mac.attachPlist
        let tools = ScriptedTools(
            answer: { tool, arguments in
                switch tool {
                case "hdiutil":
                    return arguments.first == "attach" ? plist : ""
                case "codesign" where arguments.first == "-dv":
                    return "TeamIdentifier=2N7GKZ8D8Z\n"
                case "spctl":
                    throw UpdateCommandFailure(
                        tool: "spctl",
                        status: 3,
                        output: "Mynah.app: rejected\nsource=no usable signature"
                    )
                default:
                    return ""
                }
            },
            recorder: log
        )
        let outcome = await run(installer(tools: tools))

        XCTAssertEqual(outcome.problem, .gatekeeperRefused("source=no usable signature"))
        XCTAssertEqual(mac.installedMarker(), "old")
    }

    func testKeepsTheWorkingCopyWhenTheDownloadFails() async throws {
        let outcome = await run(installer(download: ScriptedDownload(status: 403)))

        XCTAssertEqual(outcome.problem, .downloadRefused(403))
        XCTAssertEqual(mac.installedMarker(), "old")
        let updates = mac.support.appendingPathComponent("Updates")
        XCTAssertEqual(
            (try? FileManager.default.contentsOfDirectory(atPath: updates.path)) ?? [],
            [],
            "a refusal's body is not a build and should not be left lying about"
        )
    }

    func testReportsAReleaseWithNoAppleSiliconBuild() async throws {
        let intelOnly = """
        {"name":"Mynah-1.3.0-macOS-x86_64.dmg",
         "browser_download_url":"https://github.com/l33tdawg/mynah/releases/download/v1.3.0/x.dmg"}
        """
        let outcome = await run(installer(release: releaseBody(assets: intelOnly)))

        XCTAssertEqual(outcome.problem, .noBuildToInstall)
    }

    func testPassesGitHubsRefusalsThroughInTheCheckersWords() async throws {
        let rateLimited = await run(installer(release: "{}", status: 403))
        XCTAssertEqual(rateLimited.problem, .cannotAsk(.rateLimited))

        let missing = await run(installer(release: "{}", status: 404))
        XCTAssertEqual(missing.problem, .cannotAsk(.notVisible))

        let nonsense = await run(installer(release: "not json", status: 200))
        XCTAssertEqual(nonsense.problem, .cannotAsk(.unreadable))
    }

    // MARK: The rules, on their own

    func testPrefersTheVersionedImageOverTheFixedName() throws {
        let assets = try JSONDecoder().decode(
            [UpdateInstaller.ReleasePayload.Asset].self,
            from: Data("""
            [{"name":"Mynah-macOS-arm64.dmg",
              "browser_download_url":"https://github.com/l33tdawg/mynah/releases/download/v1/a.dmg"},
             {"name":"Mynah-1.3.0-macOS-arm64.dmg",
              "browser_download_url":"https://github.com/l33tdawg/mynah/releases/download/v1/b.dmg"},
             {"name":"Mynah-1.3.0-macOS-arm64.dmg.sha256",
              "browser_download_url":"https://github.com/l33tdawg/mynah/releases/download/v1/c.txt"}]
            """.utf8)
        )

        XCTAssertEqual(UpdateInstaller.pick(from: assets)?.name, "Mynah-1.3.0-macOS-arm64.dmg")
    }

    func testWillNotFollowADownloadLinkOffGitHub() throws {
        let assets = try JSONDecoder().decode(
            [UpdateInstaller.ReleasePayload.Asset].self,
            from: Data("""
            [{"name":"Mynah-1.3.0-macOS-arm64.dmg",
              "browser_download_url":"http://example.com/Mynah-1.3.0-macOS-arm64.dmg"}]
            """.utf8)
        )

        XCTAssertNil(UpdateInstaller.pick(from: assets),
                     "the release body arrives over the network and is not a place to be told "
                     + "where to fetch a replacement app from")
    }

    func testReadsTheMountPointOutOfWhatHdiutilPrints() {
        XCTAssertEqual(
            UpdateInstaller.mountPoint(inPropertyList: mac.attachPlist)?.path,
            mac.volume.path
        )
        XCTAssertNil(UpdateInstaller.mountPoint(inPropertyList: "hdiutil: attach failed"))
    }

    func testReadsTheTeamOutOfWhatCodesignPrints() {
        let output = """
        Executable=/Applications/Mynah.app/Contents/MacOS/Mynah
        Identifier=local.sage.voicebridge
        TeamIdentifier=2N7GKZ8D8Z
        """
        XCTAssertEqual(UpdateInstaller.team(inCodesignOutput: output), "2N7GKZ8D8Z")
        XCTAssertNil(UpdateInstaller.team(inCodesignOutput: "TeamIdentifier=not set"))
        XCTAssertNil(UpdateInstaller.team(inCodesignOutput: "CodeDirectory v=20400"))
    }

    func testTransferSaysBothNumbersAndNeverInventsATotal() {
        let known = UpdateTransfer(received: 100, expected: 200)
        XCTAssertEqual(known.fraction, 0.5)
        XCTAssertTrue(known.spokenDescription.contains(" of "))

        let unknown = UpdateTransfer(received: 100, expected: nil)
        XCTAssertNil(unknown.fraction)
        XCTAssertFalse(unknown.spokenDescription.contains(" of "))

        // A server that lies about the length must not produce 140%.
        XCTAssertEqual(UpdateTransfer(received: 300, expected: 200).fraction, 1)
        XCTAssertNil(UpdateTransfer(received: 10, expected: 0).expected)
    }

    /// Every refusal has to end somewhere the owner can go.
    func testEveryProblemNamesSomethingToDo() {
        let problems: [UpdateInstallProblem] = [
            .cannotAsk(.noAnswer), .noBuildToInstall, .alreadyCurrent("1.2.0"),
            .notEnoughRoom(needed: 2_000_000_000), .downloadRefused(403), .downloadFailed,
            .cancelled, .imageWouldNotOpen, .imageHasNoApp, .differentApp(found: "x"),
            .thisCopyIsUnsigned, .differentSigner(found: "x"), .gatekeeperRefused("x"),
            .runningFromTheImage, .cannotWriteThere("/x"), .putBack("x"), .leftInBackup("/x"),
            .couldNotRestart
        ]
        for problem in problems {
            let sentence = problem.spokenDescription
            XCTAssertFalse(sentence.isEmpty)
            XCTAssertTrue(sentence.hasSuffix(".") || sentence.hasSuffix("s."),
                          "\(problem) does not end in a full stop: \(sentence)")
        }
    }
}

/// The stages, in the order they were reported.
private final class StageLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stages: [UpdateInstallStage] = []

    func note(_ stage: UpdateInstallStage) {
        lock.lock()
        stages.append(stage)
        lock.unlock()
    }

    /// Runs of the same stage collapsed — the download reports many times.
    var distinct: [UpdateInstallStage] {
        lock.lock()
        defer { lock.unlock() }
        return stages.reduce(into: []) { seen, stage in
            if seen.last != stage { seen.append(stage) }
        }
    }
}

private extension Result where Failure == UpdateInstallProblem {
    var problem: UpdateInstallProblem? {
        if case .failure(let problem) = self { return problem }
        return nil
    }
}
