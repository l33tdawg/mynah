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
        let detail = status(reachable: false, number: nil).reachabilityDetail

        XCTAssertFalse(
            detail.contains("turn answering off and on"),
            "advice that cannot work is worse than none: \(detail)"
        )
    }

    /// And it names the thing that *does* work, on the row above it.
    func testAnUnlinkedPhoneIsPointedAtLinking() {
        XCTAssertTrue(status(reachable: false, number: nil).reachabilityDetail.contains("link your phone"))
    }

    /// A linked phone that has not come up yet is a different problem with a
    /// different answer, and it keeps the old one.
    func testALinkedPhoneThatIsDownStillGetsTheRestartAdvice() {
        let detail = status(reachable: false, number: "+6012·····89").reachabilityDetail

        XCTAssertTrue(detail.contains("turn answering off and on"))
        XCTAssertFalse(detail.contains("link your phone"))
    }

    func testAWorkingLinkJustSaysSo() {
        let detail = status(reachable: true, number: "+6012·····89").reachabilityDetail

        XCTAssertEqual(detail, "The link between this Mac and your phone is up.")
    }

    /// Reachable with nothing linked should not happen, and if it does the
    /// owner is not sent to link a phone they apparently already have. The
    /// reachable branch wins, which is the honest reading of the two facts.
    func testReachableWinsOverAMissingNumber() {
        XCTAssertEqual(
            status(reachable: true, number: nil).reachabilityDetail,
            "The link between this Mac and your phone is up."
        )
    }
}
