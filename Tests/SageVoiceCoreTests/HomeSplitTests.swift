// **Mac-only, because it tests `MynahMac`.**
//
// `MynahMac` is the AppKit/SwiftUI half of this package, and Package.swift does
// not declare that target off Darwin — so the import below resolves on a Mac
// and nowhere else. The guard wraps the whole file rather than just the import,
// because every test in here drives a Mac type: a file that compiled down to an
// empty test class would let Linux report a green suite that ran nothing, which
// is the exact failure this branch exists to stop. See `coreTestDependencies`
// in Package.swift.
#if os(macOS)
import XCTest
@testable import MynahMac

/// Folding away half of Home.
///
/// The owner asked for this and named both directions in one sentence: "you
/// don't always want chat to be so big but at the same time you don't always
/// need to see all tasks list thing". A collapse that only hides the board
/// solves half of it, and one that forgets overnight solves none of it — he
/// would fold the same half away every morning.
@MainActor
final class HomeSplitTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "mynah.split.\(UUID().uuidString)")!
        defaults.set(true, forKey: "mynah.setupComplete")
        return defaults
    }

    // MARK: Both directions

    /// The half-solution this guards against is a control that only folds the
    /// conversation, because that is the one somebody would build first.
    func testEitherHalfCanBeFoldedAway() {
        XCTAssertFalse(AppModel.HomeSplit.conversationOnly.showsBoard)
        XCTAssertTrue(AppModel.HomeSplit.conversationOnly.showsConversation)

        XCTAssertTrue(AppModel.HomeSplit.boardOnly.showsBoard)
        XCTAssertFalse(AppModel.HomeSplit.boardOnly.showsConversation)
    }

    func testBothIsBothAndIsWhereItStarts() {
        XCTAssertTrue(AppModel.HomeSplit.both.showsBoard)
        XCTAssertTrue(AppModel.HomeSplit.both.showsConversation)

        let app = AppModel(defaults: makeDefaults(), backgroundServices: InertAppliance())
        XCTAssertEqual(app.homeSplit, .both, "a window that has never been folded opens folded")
    }

    /// There is no state where the window is empty. Every case shows at least
    /// one half, so no sequence of clicks can leave somebody looking at a
    /// health line and a composer wondering where their app went.
    func testNoStateHidesEverything() {
        for split in AppModel.HomeSplit.allCases {
            XCTAssertTrue(
                split.showsBoard || split.showsConversation,
                "\(split) folds away the entire window"
            )
        }
    }

    // MARK: It has to be there tomorrow

    func testAFoldSurvivesRelaunch() {
        let defaults = makeDefaults()

        let first = AppModel(defaults: defaults, backgroundServices: InertAppliance())
        first.homeSplit = .conversationOnly

        let afterRelaunch = AppModel(defaults: defaults, backgroundServices: InertAppliance())
        XCTAssertEqual(
            afterRelaunch.homeSplit,
            .conversationOnly,
            "the fold reset on relaunch, so the owner re-does it every morning"
        )
    }

    func testFoldingBackToBothAlsoSurvives() {
        let defaults = makeDefaults()

        let first = AppModel(defaults: defaults, backgroundServices: InertAppliance())
        first.homeSplit = .boardOnly
        first.homeSplit = .both

        XCTAssertEqual(AppModel(defaults: defaults, backgroundServices: InertAppliance()).homeSplit, .both)
    }

    /// A value written by a newer build, or a corrupted one, opens showing both
    /// halves rather than refusing to launch or opening on nothing.
    func testAnUnreadableStoredValueOpensOnBoth() {
        let defaults = makeDefaults()
        defaults.set("something-else", forKey: "mynah.homeSplit")

        XCTAssertEqual(AppModel(defaults: defaults, backgroundServices: InertAppliance()).homeSplit, .both)
    }

    /// Two windows over one preference must not disagree about which half is
    /// folded — the value is the app's, not the view's.
    func testTheFoldIsAPropertyOfTheAppAndNotOfAView() {
        let defaults = makeDefaults()
        let app = AppModel(defaults: defaults, backgroundServices: InertAppliance())

        app.homeSplit = .boardOnly

        XCTAssertEqual(defaults.string(forKey: "mynah.homeSplit"), "boardOnly")
    }
}
#endif  // os(macOS)
