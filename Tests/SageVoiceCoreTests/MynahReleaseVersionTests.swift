import XCTest
@testable import SageVoiceCore

/// **That "newer" means the same thing here as it does in QuietType.**
///
/// This type is a port of the sibling app's, so the cases worth testing are the
/// ones its updater already learned: the three input shapes, and the prerelease
/// ordering that decides whether somebody on a stable build gets offered a beta of
/// what they are already running.
final class MynahReleaseVersionTests: XCTestCase {

    // MARK: Reading

    /// Three shapes, because all three occur: a git tag, this repo's DMG
    /// filename, and a bare bundle version.
    func testItReadsTagsArtifactNamesAndBareVersions() {
        let expected = MynahReleaseVersion(major: 1, minor: 1, patch: 0)
        for input in ["1.1.0", "v1.1.0", "V1.1.0", "Mynah-1.1.0-macOS-arm64.dmg",
                      "mynah-1.1.0-macos-arm64.dmg", "  1.1.0  "] {
            XCTAssertEqual(
                MynahReleaseVersion.parse(input), expected,
                "\(input.debugDescription) did not parse to 1.1.0"
            )
        }
    }

    func testItReadsPrereleases() {
        XCTAssertEqual(
            MynahReleaseVersion.parse("1.1.0-beta.2"),
            MynahReleaseVersion(major: 1, minor: 1, patch: 0, channel: .beta, prereleaseNumber: 2)
        )
        XCTAssertEqual(
            MynahReleaseVersion.parse("v1.1.0-rc.1"),
            MynahReleaseVersion(
                major: 1, minor: 1, patch: 0, channel: .releaseCandidate, prereleaseNumber: 1
            )
        )
    }

    /// **Refused rather than guessed.** An unparseable prerelease that quietly
    /// became stable would outrank the release it precedes, which is the one
    /// mistake this type exists to prevent.
    func testUnparseableInputIsRefused() {
        for input in ["", "1.1", "1.1.0.0", "one.one.zero", "1.1.0-beta",
                      "1.1.0-beta.0", "1.1.0-nightly.1", "-1.1.0", "latest"] {
            XCTAssertNil(
                MynahReleaseVersion.parse(input),
                "\(input.debugDescription) parsed when it should not have"
            )
        }
    }

    // MARK: Ordering

    func testNumbersOrderBeforeAnythingElse() {
        let ordered = [
            MynahReleaseVersion(major: 1, minor: 0, patch: 0),
            MynahReleaseVersion(major: 1, minor: 0, patch: 1),
            MynahReleaseVersion(major: 1, minor: 1, patch: 0),
            MynahReleaseVersion(major: 2, minor: 0, patch: 0)
        ]
        XCTAssertEqual(ordered.sorted(), ordered)
    }

    /// **The case that matters.** `1.1.0-beta.2` is older than `1.1.0`, so a
    /// stable build is never offered a beta of itself as an update.
    func testAPrereleasePrecedesTheReleaseItLeadsTo() {
        let beta = MynahReleaseVersion.parse("1.1.0-beta.2")!
        let candidate = MynahReleaseVersion.parse("1.1.0-rc.1")!
        let stable = MynahReleaseVersion.parse("1.1.0")!

        XCTAssertLessThan(beta, candidate)
        XCTAssertLessThan(candidate, stable)
        XCTAssertFalse(stable < beta, "a stable build would be offered a beta as an update")
    }

    func testPrereleasesOfTheSameChannelOrderByNumber() {
        XCTAssertLessThan(
            MynahReleaseVersion.parse("1.1.0-beta.2")!,
            MynahReleaseVersion.parse("1.1.0-beta.10")!
        )
    }

    /// A prerelease of a *later* version still outranks the current stable one,
    /// or somebody who opted into betas would stop being offered them.
    func testALaterPrereleaseStillOutranksAnEarlierStable() {
        XCTAssertLessThan(
            MynahReleaseVersion.parse("1.1.0")!,
            MynahReleaseVersion.parse("1.2.0-beta.1")!
        )
    }

    // MARK: The running build

    func testTheRunningVersionComesFromTheBundle() {
        // The test bundle has no CFBundleShortVersionString we control, so this
        // asserts the contract rather than a value: it always answers, and an
        // unreadable bundle reads as 0.0.0 so every release looks newer and the
        // owner is offered the update rather than stranded.
        let current = MynahReleaseVersion.current()
        XCTAssertGreaterThanOrEqual(current.major, 0)
        XCTAssertLessThan(current, MynahReleaseVersion(major: 999, minor: 0, patch: 0))
    }

    // MARK: Showing

    func testItSaysWhatTheOwnerReads() {
        XCTAssertEqual(MynahReleaseVersion.parse("1.1.0")!.displayName, "1.1.0")
        XCTAssertEqual(MynahReleaseVersion.parse("1.1.0-beta.2")!.displayName, "1.1.0 beta 2")
        XCTAssertEqual(MynahReleaseVersion.parse("1.1.0-rc.1")!.displayName, "1.1.0 rc 1")
    }

    /// The DMG this repo actually produces has to round-trip, or the updater
    /// compares against nothing. `create-dmg.sh` names it this way.
    func testTheArtifactThisRepoBuildsRoundTrips() {
        let parsed = MynahReleaseVersion.parse("Mynah-1.0.0-macOS-arm64.dmg")
        XCTAssertEqual(parsed?.displayName, "1.0.0")
    }
}
