import XCTest
@testable import MynahMac

/// **What a brand-new owner is told about their phone.**
///
/// Reported from the field: *"new users are saying for signal after install It
/// says Not Set, but it doesn't say how to set it."* Two rows on the same screen
/// described a state neither of them could get the owner out of — the QR flow
/// existed the whole time, two groups away, behind a group that only renders
/// when there is a deferred step to render.
///
/// The button is view code and is not asserted here. This is the half that can
/// be: the sentence underneath it, which used to hand a new owner advice that
/// cannot work.
final class PhoneSettingsTests: XCTestCase {

    private func status(reachable: Bool, number: String?) -> PhoneStatus {
        PhoneStatus(isReachable: reachable, linkedNumber: number, socketPath: "/tmp/sock")
    }

    /// The regression. Toggling answering cannot conjure an account, so saying
    /// so sends the owner round a loop that ends where it started.
    func testAnUnlinkedPhoneIsNotToldToToggleAnswering() {
        let detail = status(reachable: false, number: nil).reachabilityDetail(helper: .absent)

        XCTAssertFalse(
            detail.contains("turn answering off and on"),
            "advice that cannot work is worse than none: \(detail)"
        )
    }

    /// And it names the thing that *does* work, on the row above it.
    func testAnUnlinkedPhoneIsPointedAtLinking() {
        XCTAssertTrue(
            status(reachable: false, number: nil)
                .reachabilityDetail(helper: .absent)
                .contains("link your phone")
        )
    }

    /// A linked phone whose helper is *not* running is a real fault, and it
    /// keeps the advice that addresses it.
    func testALinkedPhoneWhoseHelperIsStoppedGetsTheRestartAdvice() {
        let detail = status(reachable: false, number: "+6012·····89")
            .reachabilityDetail(helper: .installedButNotRunning)

        XCTAssertTrue(detail.contains("turn answering off and on"))
        XCTAssertFalse(detail.contains("link your phone"))
    }

    func testAWorkingLinkJustSaysSo() {
        let detail = status(reachable: true, number: "+6012·····89").reachabilityDetail(helper: .running)

        XCTAssertEqual(detail, "The link between this Mac and your phone is up.")
    }

    /// Reachable with nothing linked should not happen, and if it does the
    /// owner is not sent to link a phone they apparently already have. The
    /// reachable branch wins, which is the honest reading of the two facts.
    func testReachableWinsOverAMissingNumber() {
        XCTAssertEqual(
            status(reachable: true, number: nil).reachabilityDetail(helper: .running),
            "The link between this Mac and your phone is up."
        )
    }

    // MARK: Starting is not a fault

    /// **Measured, not guessed.** On the owner's Mac signal-cli's daemon started
    /// at 07:28:55 and its socket appeared at 07:29:04. For those nine seconds
    /// the pill said "Not connected", which describes a fault where there is a
    /// JVM starting — and launchd already knew the difference.
    func testAHelperThatIsRunningWithoutASocketIsStartingRatherThanBroken() {
        let starting = status(reachable: false, number: "+6012·····89")

        XCTAssertEqual(starting.reachabilityLabel(helper: .running), "Starting")
        XCTAssertTrue(starting.reachabilityDetail(helper: .running).contains("ten seconds"))
        XCTAssertFalse(
            starting.reachabilityDetail(helper: .running).contains("turn answering off and on"),
            "nothing is wrong yet, so nothing should be prescribed"
        )
    }

    /// With no helper running there is nothing starting, so the word must not be
    /// used — it would promise a recovery that is not coming.
    func testNothingIsStartingWhenNoHelperIsRunning() {
        for helper in [BackgroundHelperState.absent, .installedButNotRunning, .unknown] {
            XCTAssertEqual(
                status(reachable: false, number: "+6012·····89").reachabilityLabel(helper: helper),
                "Not connected",
                "\(helper)"
            )
        }
    }

    /// An unlinked Mac is never "Starting", whatever launchd is doing — there is
    /// no account for it to start with.
    func testAnUnlinkedMacIsNeverStarting() {
        XCTAssertEqual(status(reachable: false, number: nil).reachabilityLabel(helper: .running), "Not connected")
    }

    func testAReachablePhoneIsConnectedWhateverLaunchdSays() {
        for helper in [BackgroundHelperState.running, .absent, .installedButNotRunning, .unknown] {
            XCTAssertEqual(
                status(reachable: true, number: "+6012·····89").reachabilityLabel(helper: helper),
                "Connected",
                "\(helper)"
            )
        }
    }

    /// Before launchd has answered, `helperState` is nil. That is not "running",
    /// so it must not claim something is starting.
    func testAnUnansweredHelperStateDoesNotClaimItIsStarting() {
        XCTAssertEqual(status(reachable: false, number: "+6012·····89").reachabilityLabel(helper: nil), "Not connected")
    }
}
