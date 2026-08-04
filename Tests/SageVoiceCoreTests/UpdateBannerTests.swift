import XCTest
@testable import MynahMac
@testable import SageVoiceCore

/// The banner under the header, and the cadence that puts it there.
///
/// **The feature it belongs to was complete and invisible.** The check, the
/// verdict, the signed download, the swap and the restart all worked and all
/// lived behind Settings — a screen nobody opens when nothing is wrong. Six
/// releases shipped in one day and the owner's report was *"haven't even seen
/// our version of the update banner"*. There was no banner to see.
final class UpdateBannerTests: XCTestCase {

    private let page = URL(string: "https://github.com/l33tdawg/mynah/releases/tag/v1.5.2")!

    // MARK: How often it asks

    /// It was once a day, which on an appliance that stays up for days meant a
    /// release could sit unnoticed for most of one.
    func testItAsksEveryFifteenMinutes() {
        XCTAssertEqual(UpdateCheck.interval, 15 * 60)
    }

    /// Four requests an hour, against GitHub's unauthenticated ceiling of sixty.
    /// The margin is the point: this must not be the thing that gets the owner
    /// rate-limited, because a rate-limited check reports "couldn't check"
    /// forever and looks like a broken appliance.
    func testTheCadenceStaysWellInsideGitHubsRateLimit() {
        let perHour = 3600 / UpdateCheck.interval
        XCTAssertLessThanOrEqual(perHour, 12, "\(perHour)/hour is more than this needs to be")
    }

    // MARK: What it draws

    func testANewerVersionGetsABannerNamingIt() throws {
        let banner = try XCTUnwrap(
            UpdateWatch.banner(for: .newer(version: "1.5.2", page: page), installedAndWaiting: nil)
        )
        XCTAssertEqual(banner.headline, "Mynah 1.5.2 is ready.")
        XCTAssertEqual(banner.page, page, "the release page must be the one being offered — the install sheet links it")
        XCTAssertFalse(banner.isWaitingForRestart)
    }

    func testBeingUpToDateDrawsNothing() {
        XCTAssertNil(UpdateWatch.banner(for: .upToDate, installedAndWaiting: nil))
    }

    func testTheFirstCheckStillRunningDrawsNothing() {
        XCTAssertNil(UpdateWatch.banner(for: nil, installedAndWaiting: nil))
    }

    /// **A failed check is not an update.** A band across the window is far too
    /// loud a way to say a background request did not come back, and an owner
    /// who is offline would carry it until they were not.
    func testAFailedCheckDrawsNothing() {
        for problem: UpdateCheckProblem in [.turnedOff, .notCheckedYet, .unknownRunningVersion] {
            XCTAssertNil(
                UpdateWatch.banner(for: .cannotTell(problem), installedAndWaiting: nil),
                "\(problem) put a banner on screen"
            )
        }
    }

    // MARK: After the swap, before the restart

    /// The check goes on reporting a newer version here, and it is right — the
    /// running copy really is the old one. It is just not the sentence the owner
    /// needs, and "Update" is not the verb: the file is already on the disk.
    func testOnceInstalledTheBannerAsksForARestartInstead() throws {
        let banner = try XCTUnwrap(
            UpdateWatch.banner(
                for: .newer(version: "1.5.2", page: page),
                installedAndWaiting: "1.5.2"
            )
        )
        XCTAssertTrue(banner.isWaitingForRestart)
        XCTAssertEqual(banner.headline, "Mynah 1.5.2 is installed.")
        XCTAssertTrue(
            banner.detail.contains("keeps running"),
            "it must say the phone is still being answered on the old one: \(banner.detail)"
        )
    }

    /// The waiting state wins even when the check has not come back yet, which
    /// is exactly the state a restart-prompt has to survive: the app was just
    /// swapped, and nothing has been asked of GitHub since.
    func testTheRestartPromptDoesNotNeedACheckToHaveSucceeded() throws {
        let banner = try XCTUnwrap(
            UpdateWatch.banner(for: nil, installedAndWaiting: "1.5.2")
        )
        XCTAssertTrue(banner.isWaitingForRestart)
        XCTAssertEqual(banner.page, UpdateCheck.releasesPage, "falls back to the releases list")
    }

    // MARK: It does not go away on its own

    /// **No dismiss, by the owner's decision:** *"if you check, we cache and then
    /// the banner stays till you update"*.
    ///
    /// Stated as a property rather than a missing button, because a "remind me
    /// later" is the kind of thing that gets added back by someone who thinks
    /// they are being polite. The banner is a function of the two facts above
    /// and of nothing the owner has clicked, so there is nowhere for a dismissal
    /// to be recorded.
    func testTheSameAnswerKeepsDrawingTheSameBanner() {
        let answer = UpdateAvailability.newer(version: "1.5.2", page: page)
        let first = UpdateWatch.banner(for: answer, installedAndWaiting: nil)
        let hoursLater = UpdateWatch.banner(for: answer, installedAndWaiting: nil)
        XCTAssertNotNil(first)
        XCTAssertEqual(first, hoursLater, "the banner must not fade on its own")
    }

    /// And the one thing that does take it down is having taken the update:
    /// once the new version is the running one, the check says up to date and
    /// there is nothing left to draw.
    func testTakingTheUpdateIsWhatRemovesIt() {
        XCTAssertNotNil(
            UpdateWatch.banner(for: .newer(version: "1.5.2", page: page), installedAndWaiting: nil)
        )
        XCTAssertNil(UpdateWatch.banner(for: .upToDate, installedAndWaiting: nil))
    }

    // MARK: One verb, and only one

    /// **No "What's new" on the band, by the owner's decision:** *"looks good but
    /// remove the 'what's new'"*.
    ///
    /// Asserted the same way the missing dismiss is, and for the same reason: a
    /// link to the release notes is exactly the sort of thing somebody adds back
    /// believing they are being helpful. The notes are still one click away in
    /// the install sheet, which is where somebody who wants them is already
    /// looking.
    func testTheBandOffersNothingToReadOnlySomethingToDo() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/MynahMac/Main/UpdateWatch.swift"),
            encoding: .utf8
        )
        let body = try XCTUnwrap(source.range(of: "struct UpdateBanner").map { String(source[$0.lowerBound...]) })

        XCTAssertFalse(
            body.split(separator: "\n").contains {
                let line = $0.trimmingCharacters(in: .whitespaces)
                return line.contains("What's new") && !line.hasPrefix("//")
            },
            "the release-notes link is back on the band"
        )
    }

    // MARK: The colour, twice asked for and twice missed

    /// **"still white solid", after two attempts to make it green.**
    ///
    /// Both attempts painted `Palette.surface.raised` — pure `0xFFFFFF` — and
    /// then tinted it with a 10% wash. That is white with a hint in it, and no
    /// amount of reordering the layers changes what colour opaque white is. The
    /// owner asked for *"translucent green like quiettype-ish"*, and translucent
    /// means the window shows through, so the band cannot have an opaque surface
    /// of its own at all.
    ///
    /// Asserted on the alpha rather than on a screenshot, because the alpha is
    /// the thing that was wrong both times.
    func testTheBandIsTranslucentRatherThanASurfaceWithATint() throws {
        let band = try XCTUnwrap(NSColor(Palette.state.goodBand).usingColorSpace(.sRGB))

        XCTAssertLessThan(
            band.alphaComponent, 0.5,
            "the band is nearly opaque, so nothing shows through it"
        )
        XCTAssertGreaterThan(
            band.alphaComponent, 0.12,
            "the band is fainter than the reference it was asked to match"
        )
    }

    /// Green, and green by more than a rounding error — the failure mode here is
    /// a tint so slight it reads as grey.
    func testTheBandIsActuallyGreen() throws {
        let band = try XCTUnwrap(NSColor(Palette.state.goodBand).usingColorSpace(.sRGB))

        XCTAssertGreaterThan(
            band.greenComponent, band.redComponent + 0.15,
            "the band is not meaningfully greener than it is red"
        )
        XCTAssertGreaterThan(
            band.greenComponent, band.blueComponent + 0.15,
            "the band is not meaningfully greener than it is blue"
        )
    }

    /// The band must never go back to owning a surface. This is the line that
    /// made it white both times, and it is one careless edit away from
    /// returning.
    func testTheBannerPaintsNoOpaqueSurfaceBehindItself() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/MynahMac/Main/UpdateWatch.swift"),
            encoding: .utf8
        )
        let body = try XCTUnwrap(source.range(of: "struct UpdateBanner").map { String(source[$0.lowerBound...]) })

        XCTAssertFalse(
            body.split(separator: "\n").contains {
                let line = $0.trimmingCharacters(in: .whitespaces)
                return line.hasPrefix(".background") && line.contains("Palette.surface")
            },
            "the banner is painting an opaque surface again, which is what made it white"
        )
    }
}
