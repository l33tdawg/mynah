import XCTest
@testable import SageVoiceCore

// MARK: - A GitHub that answers however the test needs it to

/// Replays one scripted answer and records what was asked.
///
/// The request count is the point of half these tests: this feature's failure
/// mode is not a wrong answer on screen, it is an appliance quietly reaching a
/// third party more often than the owner was told it would.
private final class ScriptedGitHub: UpdateCheck.Transport, @unchecked Sendable {

    enum Reply {
        case http(Int, String)
        /// No network at all — the aeroplane, the hotel wifi, the ISP.
        case unreachable
    }

    private let lock = NSLock()
    private let reply: Reply
    private var requests: [URLRequest] = []

    init(_ reply: Reply) {
        self.reply = reply
    }

    func fetch(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        withLock { requests.append(request) }
        switch reply {
        case .unreachable:
            throw URLError(.notConnectedToInternet)
        case .http(let status, let body):
            return (status, Data(body.utf8))
        }
    }

    var callCount: Int { withLock { requests.count } }
    var lastRequest: URLRequest? { withLock { requests.last } }

    /// `NSLock` is `noasync`; a non-async body makes it impossible to suspend
    /// while holding it.
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// A clock reading one day later per step, for the tests that walk several
/// answers through one checker. The day gate would otherwise swallow every
/// answer after the first.
private func aDayApart(_ step: Int) -> Date {
    Date(timeIntervalSince1970: 1_700_000_000).addingTimeInterval(Double(step) * 25 * 60 * 60)
}

private func releaseJSON(
    tag: String = "Mynah-1.2.0",
    name: String = "Mynah 1.2.0",
    url: String = "https://github.com/l33tdawg/sage-voice-bridge/releases/tag/Mynah-1.2.0"
) -> String {
    """
    {"tag_name": "\(tag)", "name": "\(name)", "html_url": "\(url)", "draft": false}
    """
}

// MARK: - Reading and ordering versions

/// Comparing versions as text is the bug this type exists to prevent, and it is
/// invisible until the day a minor number reaches double figures.
final class ReleaseVersionTests: XCTestCase {

    /// The one that a string comparison gets wrong, and the one that will
    /// actually happen: the tenth minor release of the first major version.
    func testTenthMinorReleaseIsNewerThanTheNinth() {
        let ten = ReleaseVersion(tag: "1.10.0")
        let nine = ReleaseVersion(tag: "1.9.0")
        XCTAssertEqual(
            ten.map { $0 > nine! }, true,
            "1.10.0 was not treated as newer than 1.9.0 — an owner on 1.9.0 would never be told "
                + "1.10.0 exists"
        )
        XCTAssertEqual(
            nine.map { $0 > ten! }, false,
            "1.9.0 read as newer than 1.10.0 — an owner on the newest build would be offered an "
                + "older one"
        )
    }

    func testPatchNumbersAreComparedAsNumbers() throws {
        let newer = try XCTUnwrap(ReleaseVersion(tag: "1.0.10"))
        let older = try XCTUnwrap(ReleaseVersion(tag: "1.0.9"))
        XCTAssertGreaterThan(newer, older, "1.0.10 must outrank 1.0.9, whatever the strings do")
    }

    func testAMajorReleaseOutranksAnyMinorBeforeIt() throws {
        let two = try XCTUnwrap(ReleaseVersion(tag: "2.0.0"))
        let one = try XCTUnwrap(ReleaseVersion(tag: "1.99.99"))
        XCTAssertGreaterThan(two, one)
    }

    /// The DMG is named `Mynah-1.0.0`, the plist says `1.0.0`, most repositories
    /// tag `v1.0.0`, and this project has published no release yet — so all
    /// three have to read the same or the first release breaks the check.
    func testTagsReadTheSameHoweverTheyWereWritten() throws {
        let expected = ReleaseVersion(major: 1, minor: 0, patch: 0)
        for tag in ["Mynah-1.0.0", "v1.0.0", "1.0.0", "V1.0.0", "release-1.0.0"] {
            XCTAssertEqual(
                ReleaseVersion(tag: tag), expected,
                "the tag \(tag) did not read as 1.0.0, so a release named that way would be "
                    + "invisible to the owner"
            )
        }
    }

    func testAShortVersionMeansTheMissingPartsAreZero() {
        XCTAssertEqual(ReleaseVersion(tag: "1.0"), ReleaseVersion(major: 1, minor: 0, patch: 0))
        XCTAssertEqual(ReleaseVersion(tag: "2"), ReleaseVersion(major: 2, minor: 0, patch: 0))
    }

    /// A tag with no version in it must be refused, not guessed at. Guessing
    /// produces a number that compares cleanly and means nothing.
    func testATagWithNoVersionInItIsRefused() {
        for tag in ["", "latest", "vNext", "Mynah", "stable-release"] {
            XCTAssertNil(
                ReleaseVersion(tag: tag),
                "the tag '\(tag)' was read as a version, so the owner could be told about an "
                    + "update that does not exist"
            )
        }
    }

    /// A number too large to hold used to drop out of the middle and shift the
    /// ones after it left, turning 1.<huge>.3 into 1.3 — a plausible version
    /// that is not the one in the tag.
    func testAnUnholdableNumberIsRefusedRatherThanPartlyRead() {
        XCTAssertNil(ReleaseVersion(tag: "1.99999999999999999999.3"))
    }

    /// Somebody who installed 1.1.0 must never be offered the beta they left
    /// behind.
    func testAPrereleaseRanksBelowTheReleaseItLeadsTo() throws {
        let release = try XCTUnwrap(ReleaseVersion(tag: "Mynah-1.1.0"))
        let beta = try XCTUnwrap(ReleaseVersion(tag: "Mynah-1.1.0-beta.2"))
        XCTAssertGreaterThan(release, beta, "1.1.0 must outrank its own beta")
        XCTAssertGreaterThan(beta, try XCTUnwrap(ReleaseVersion(tag: "1.0.9")))
    }

    /// Build metadata is explicitly not part of precedence, so two builds of the
    /// same version must not be offered to each other as updates.
    func testBuildMetadataDoesNotMakeAVersionNewer() throws {
        let plain = try XCTUnwrap(ReleaseVersion(tag: "1.0.0"))
        let stamped = try XCTUnwrap(ReleaseVersion(tag: "1.0.0+build7"))
        XCTAssertEqual(plain, stamped)
        XCTAssertFalse(stamped > plain)
    }

    func testTheVersionPrintsBackTheWayItWasRead() {
        XCTAssertEqual(ReleaseVersion(tag: "Mynah-1.2.3")?.description, "1.2.3")
        XCTAssertEqual(ReleaseVersion(tag: "v1.2.3-beta.1")?.description, "1.2.3-beta.1")
    }
}

// MARK: - The check itself

final class UpdateCheckTests: XCTestCase {

    /// Its own directory per test. Writing goes through `OwnerOnlyFileSecurity`,
    /// which hardens the containing directory to owner-only — doing that to the
    /// shared temp directory fails, and the failure is swallowed, which looks
    /// exactly like a store that silently does not persist.
    private var preferencesFile: URL!

    override func setUpWithError() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "mynah-update-prefs-\(name.filter { $0.isLetter || $0.isNumber })",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        preferencesFile = directory.appendingPathComponent("update-preferences.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: preferencesFile.deletingLastPathComponent())
        super.tearDown()
    }

    private func check(
        running: String? = "1.0.0",
        github: ScriptedGitHub,
        now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_700_000_000) }
    ) -> UpdateCheck {
        UpdateCheck(
            runningVersion: running,
            transport: github,
            preferencesFile: preferencesFile,
            now: now
        )
    }

    // MARK: What it will not claim

    /// The repository is private, so an unauthenticated request for its releases
    /// comes back 404 — the same status GitHub gives for a repository that does
    /// not exist. Reading that as "nothing newer" would mean this feature
    /// reassures the owner on every single Mac it ships to, permanently.
    func testAPrivateRepositoryIsNotReportedAsUpToDate() async {
        let github = ScriptedGitHub(.http(404, #"{"message": "Not Found"}"#))

        let answer = await check(github: github).run()

        XCTAssertEqual(
            answer, .cannotTell(.notVisible),
            "a 404 from the private repository was not reported as 'could not check' — the owner "
                + "would be told they are up to date without anything having checked"
        )
    }

    /// The general form of the rule, over every way this can fail at once. Any
    /// new failure path added later has to answer this test.
    func testNoFailureIsEverReportedAsUpToDate() async {
        let failures: [(String, ScriptedGitHub.Reply)] = [
            ("no network", .unreachable),
            ("rate limited", .http(403, #"{"message": "API rate limit exceeded"}"#)),
            ("private repository", .http(404, #"{"message": "Not Found"}"#)),
            ("GitHub is down", .http(503, "")),
            ("a body that is not JSON", .http(200, "<html>502 Bad Gateway</html>")),
            ("JSON with no release in it", .http(200, "{}")),
            ("a release with an empty tag", .http(200, releaseJSON(tag: "", name: ""))),
            ("a tag with no version in it", .http(200, releaseJSON(tag: "latest", name: "latest"))),
        ]

        // A day apart each, because the gate is real: without moving the clock
        // every case after the first would be answered from the file rather
        // than from the reply it is meant to be testing.
        for (index, (situation, reply)) in failures.enumerated() {
            let answer = await check(github: ScriptedGitHub(reply), now: { aDayApart(index) }).run()
            guard case .cannotTell = answer else {
                XCTFail(
                    "with \(situation), the owner was told '\(answer)' instead of that Mynah could "
                        + "not check — silence must never read as agreement"
                )
                continue
            }
        }
    }

    func testEachFailureSaysWhichOneItWas() async {
        let cases: [(ScriptedGitHub.Reply, UpdateCheckProblem)] = [
            (.unreachable, .noAnswer),
            (.http(403, ""), .rateLimited),
            (.http(429, ""), .rateLimited),
            (.http(404, ""), .notVisible),
            (.http(500, ""), .serverProblem),
            (.http(200, "not json"), .unreadable),
        ]

        for (index, (reply, expected)) in cases.enumerated() {
            let answer = await check(github: ScriptedGitHub(reply), now: { aDayApart(index) }).run()
            XCTAssertEqual(
                answer, .cannotTell(expected),
                "the reason the check failed was reported as something else, so the screen would "
                    + "explain the wrong thing to the owner"
            )
        }
    }

    /// Every reason has to be sayable to somebody who does not know what a
    /// status code is, and none of them may end up blank on screen.
    func testEveryReasonHasSomethingToSay() {
        let problems: [UpdateCheckProblem] = [
            .turnedOff, .noAnswer, .notVisible, .rateLimited,
            .serverProblem, .unreadable, .unknownRunningVersion, .notCheckedYet,
        ]
        for problem in problems {
            XCTAssertFalse(
                problem.spokenDescription.isEmpty,
                "\(problem) would leave the owner looking at an empty explanation"
            )
            XCTAssertFalse(
                problem.spokenDescription.contains("!"),
                "\(problem) shouts at the owner about something that is not their fault"
            )
        }
    }

    // MARK: What it does say

    func testANewerReleaseIsNamedAndLinked() async {
        let github = ScriptedGitHub(.http(200, releaseJSON()))

        let answer = await check(running: "1.0.0", github: github).run()

        XCTAssertEqual(
            answer,
            .newer(
                version: "1.2.0",
                page: URL(string: "https://github.com/l33tdawg/sage-voice-bridge/releases/tag/Mynah-1.2.0")!
            ),
            "a published newer version was not offered to the owner, or was offered without "
                + "anywhere to get it"
        )
    }

    func testTheSameVersionIsUpToDate() async {
        let github = ScriptedGitHub(.http(200, releaseJSON(tag: "Mynah-1.0.0")))

        let answer = await check(running: "1.0.0", github: github).run()

        XCTAssertEqual(answer, .upToDate)
    }

    /// Every build made on this machine is ahead of the last published release.
    /// Offering it a "newer" version would walk the owner backwards.
    func testABuildAheadOfTheLatestReleaseIsLeftAlone() async {
        let github = ScriptedGitHub(.http(200, releaseJSON(tag: "Mynah-1.2.0")))

        let answer = await check(running: "1.3.0", github: github).run()

        XCTAssertEqual(answer, .upToDate, "an owner ahead of the release was told to downgrade")
    }

    /// The link comes off the network and is handed to the browser. A payload
    /// pointing somewhere else must not be able to send the owner there.
    func testTheDownloadLinkNeverLeavesGitHub() async {
        let links = [
            "https://mynah-updates.example.com/download",
            "http://github.com/l33tdawg/sage-voice-bridge/releases",
            "javascript:alert(1)",
            "file:///Applications",
        ]
        for (index, link) in links.enumerated() {
            let github = ScriptedGitHub(.http(200, releaseJSON(url: link)))
            let answer = await check(github: github, now: { aDayApart(index) }).run()
            XCTAssertEqual(
                answer, .newer(version: "1.2.0", page: UpdateCheck.releasesPage),
                "a link of '\(link)' from the response was handed to the owner's browser instead "
                    + "of GitHub's own releases page"
            )
        }
    }

    /// `tag_name` is what a release should be versioned by, but nothing enforces
    /// it. A title of "Mynah 1.2.0" beside an unhelpful tag is still an answer.
    func testTheReleaseTitleIsUsedWhenTheTagSaysNothing() async {
        let github = ScriptedGitHub(.http(200, releaseJSON(tag: "latest", name: "Mynah 1.2.0")))

        let answer = await check(github: github).run()

        guard case .newer(let version, _) = answer else {
            return XCTFail("a release named 1.2.0 was missed because its tag was unhelpful")
        }
        XCTAssertEqual(version, "1.2.0")
    }

    // MARK: How often it asks

    /// A version check is a third party being told this Mac exists. Once a day
    /// is what the owner is told happens, so twice is a broken promise.
    func testItAsksAtMostOnceADay() async {
        let github = ScriptedGitHub(.http(200, releaseJSON()))
        let checker = check(github: github)

        let first = await checker.run()
        let second = await checker.run()

        XCTAssertEqual(github.callCount, 1, "Mynah contacted GitHub twice inside one day")
        XCTAssertEqual(second, first, "the second answer forgot what the first one found")
    }

    func testTheDayGateSurvivesRelaunch() async {
        let first = ScriptedGitHub(.http(200, releaseJSON()))
        _ = await check(github: first).run()

        // A fresh checker is what the next launch builds. Nothing is carried in
        // memory between them; only the file is.
        let second = ScriptedGitHub(.http(200, releaseJSON()))
        let answer = await check(github: second).run()

        XCTAssertEqual(
            second.callCount, 0,
            "restarting Mynah made it check again, so an appliance restarted five times a day "
                + "contacts GitHub five times a day"
        )
        guard case .newer(let version, _) = answer else {
            return XCTFail("the version found before the restart was forgotten")
        }
        XCTAssertEqual(version, "1.2.0")
    }

    func testItAsksAgainTheNextDay() async {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        _ = await check(github: ScriptedGitHub(.http(200, releaseJSON())), now: { start }).run()

        let tomorrow = ScriptedGitHub(.http(200, releaseJSON(tag: "Mynah-1.3.0")))
        let answer = await check(
            github: tomorrow,
            now: { start.addingTimeInterval(24 * 60 * 60 + 1) }
        ).run()

        XCTAssertEqual(tomorrow.callCount, 1, "Mynah stopped checking after the first day")
        guard case .newer(let version, _) = answer else {
            return XCTFail("the newer release published overnight was never noticed")
        }
        XCTAssertEqual(version, "1.3.0")
    }

    /// A Mac whose clock was briefly set forward would otherwise store a date in
    /// the future and never check again.
    func testAClockCorrectedBackwardsDoesNotStopTheCheckForever() async {
        let future = Date(timeIntervalSince1970: 2_000_000_000)
        _ = await check(github: ScriptedGitHub(.http(200, releaseJSON())), now: { future }).run()

        let afterCorrection = ScriptedGitHub(.http(200, releaseJSON()))
        _ = await check(
            github: afterCorrection,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        ).run()

        XCTAssertEqual(
            afterCorrection.callCount, 1,
            "a clock that was wrong once left Mynah never checking for updates again"
        )
    }

    /// A failed check must not erase a real answer from the day before.
    func testAFailedCheckDoesNotForgetTheVersionItAlreadyFound() async {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        _ = await check(github: ScriptedGitHub(.http(200, releaseJSON())), now: { start }).run()

        let offline = await check(
            github: ScriptedGitHub(.unreachable),
            now: { start.addingTimeInterval(24 * 60 * 60 + 1) }
        ).run()
        XCTAssertEqual(offline, .cannotTell(.noAnswer))

        // Same day as the failure, so nothing is asked: this is the remembered
        // answer, which is the one the screen shows for the rest of the day.
        let remembered = await check(
            github: ScriptedGitHub(.unreachable),
            now: { start.addingTimeInterval(24 * 60 * 60 + 2) }
        ).run()
        guard case .newer(let version, _) = remembered else {
            return XCTFail(
                "a version Mynah had already found was forgotten because a later check failed"
            )
        }
        XCTAssertEqual(version, "1.2.0")
    }

    /// Checked, learned nothing, and it is not time to try again. There is no
    /// answer to give, and "up to date" is not one.
    func testCheckedRecentlyButNeverAnsweredIsNotUpToDate() async {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        _ = await check(github: ScriptedGitHub(.unreachable), now: { start }).run()

        let answer = await check(
            github: ScriptedGitHub(.unreachable),
            now: { start.addingTimeInterval(60) }
        ).run()

        XCTAssertEqual(answer, .cannotTell(.notCheckedYet))
    }

    // MARK: When it must not ask at all

    /// The switch is a privacy control. If anything still went out after it was
    /// turned off, the sentence beside it would be a lie.
    func testTurningItOffStopsMynahContactingGitHub() async {
        UpdatePreferences.amend(at: preferencesFile) { $0.checksForUpdates = false }
        let github = ScriptedGitHub(.http(200, releaseJSON()))

        let answer = await check(github: github).run()

        XCTAssertEqual(github.callCount, 0, "Mynah contacted GitHub after the owner turned that off")
        XCTAssertEqual(answer, .cannotTell(.turnedOff))
    }

    /// Nothing to compare against means nothing to learn, so the request is not
    /// worth the owner's privacy.
    func testABuildThatCannotNameItselfNeverAsks() async {
        let github = ScriptedGitHub(.http(200, releaseJSON()))

        let answer = await check(running: nil, github: github).run()

        XCTAssertEqual(github.callCount, 0, "Mynah told GitHub it exists to learn nothing")
        XCTAssertEqual(answer, .cannotTell(.unknownRunningVersion))
    }

    // MARK: The request itself

    /// GitHub refuses requests with no User-Agent outright, and the failure
    /// looks exactly like a rate limit, so this is worth pinning.
    func testTheRequestIdentifiesItselfWithoutNamingTheBuild() async {
        let github = ScriptedGitHub(.http(200, releaseJSON()))

        _ = await check(running: "1.0.0", github: github).run()

        let agent = github.lastRequest?.value(forHTTPHeaderField: "User-Agent")
        XCTAssertEqual(agent, "Mynah", "GitHub rejects a request with no User-Agent")
        XCTAssertEqual(
            agent?.contains("1.0.0"), false,
            "the request told GitHub which build this Mac runs, which it does not need to know"
        )
        XCTAssertEqual(
            github.lastRequest?.url, UpdateCheck.latestReleaseAPI,
            "the check asked somewhere other than this project's releases"
        )
    }

    // MARK: Where the preference lives

    /// `UserDefaults` was the shipped bug: the app and the daemon are separate
    /// processes with separate domains, so a switch written to one is invisible
    /// to the other. The same file both of them can read is the fix.
    func testThePreferenceIsAFileBothProcessesCanRead() {
        let url = UpdatePreferences.defaultFileURL(homeDirectory: URL(fileURLWithPath: "/Users/someone"))
        XCTAssertEqual(
            url.path,
            "/Users/someone/Library/Application Support/SAGE Voice Bridge/update-preferences.json",
            "the update preference moved out of the folder the daemon reads its settings from"
        )
    }

    func testThePreferenceFileIsReadableOnlyByTheOwner() async throws {
        _ = await check(github: ScriptedGitHub(.http(200, releaseJSON()))).run()

        let mode = try FileManager.default
            .attributesOfItem(atPath: preferencesFile.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode, 0o600, "another account on this Mac can read the owner's settings")
    }

    func testTheCheckIsOnUntilTheOwnerTurnsItOff() {
        XCTAssertTrue(
            UpdatePreferences.load(from: preferencesFile).checksForUpdates,
            "the owner asked for this check and would find it doing nothing"
        )
    }

    /// A settings file that will not parse costs the owner a preference, never
    /// the screen it is on.
    func testAPreferenceFileThatWillNotParseStillLeavesTheCheckWorking() async throws {
        try Data("{ this is not json".utf8).write(to: preferencesFile)
        let github = ScriptedGitHub(.http(200, releaseJSON()))

        let answer = await check(github: github).run()

        guard case .newer = answer else {
            return XCTFail("a corrupt preferences file stopped the check from working at all")
        }
    }
}
