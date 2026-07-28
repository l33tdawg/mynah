import XCTest
@testable import MynahMac

/// How the settings screen is divided.
///
/// The failure mode here is silent in the worst possible way: a group that no
/// tab claims still compiles, still has all its rows written out in the source,
/// and simply never appears on screen. Nothing throws, nothing logs, and the
/// owner's evidence is "the thing that used to be in Settings isn't there any
/// more" — which is indistinguishable from them not remembering where it was.
///
/// These assertions are only worth anything because `SettingsView` and
/// `SettingsTab.groups` read the *same* constants out of `SettingsGroupTitle`.
/// If either side ever starts typing the words again, delete this file rather
/// than leave a test that agrees with itself.
final class SettingsTabsTests: XCTestCase {

    // MARK: Nothing lost

    /// The whole point of the split.
    func testEveryGroupIsOnATab() {
        let claimed = Set(SettingsTab.allCases.flatMap(\.groups))
        for title in SettingsGroupTitle.tabbed {
            XCTAssertTrue(claimed.contains(title), "\"\(title)\" is on no tab, so nothing shows it")
        }
    }

    /// The other direction: a tab naming a group that no longer exists renders
    /// nothing where the owner was told to look.
    func testNoTabClaimsAGroupThatIsNotOnTheScreen() {
        let known = Set(SettingsGroupTitle.tabbed)
        for tab in SettingsTab.allCases {
            for title in tab.groups {
                XCTAssertTrue(
                    known.contains(title),
                    "\(tab.title) claims \"\(title)\", which is not a group on this screen"
                )
            }
        }
    }

    /// A group on two tabs is a control the owner can change in one place and
    /// find unchanged in another — or, more often, one somebody duplicated
    /// while splitting the screen and then only maintained half of.
    func testNoGroupIsOnTwoTabs() {
        let claimed = SettingsTab.allCases.flatMap(\.groups)
        XCTAssertEqual(
            Set(claimed).count,
            claimed.count,
            "a group is claimed by more than one tab: \(claimed.sorted())"
        )
    }

    /// "Unfinished" is deliberately outside the tabs — it is a call to action,
    /// and burying a step the owner deferred behind a tab is the "Later that
    /// leads nowhere" the whole list exists to prevent.
    func testUnfinishedIsNotBehindATab() {
        let claimed = Set(SettingsTab.allCases.flatMap(\.groups))
        XCTAssertFalse(claimed.contains(SettingsGroupTitle.unfinished))
        XCTAssertFalse(SettingsGroupTitle.tabbed.contains(SettingsGroupTitle.unfinished))
    }

    // MARK: The strip itself

    /// Segments share the strip's width evenly, so an empty title is a segment
    /// the owner can press and cannot read.
    func testEveryTabIsNamed() {
        for tab in SettingsTab.allCases {
            XCTAssertFalse(tab.title.isEmpty, "\(tab.rawValue) has no name")
            XCTAssertFalse(tab.groups.isEmpty, "\(tab.title) opens on nothing")
        }
    }

    /// Two segments reading the same word is a coin toss for the owner.
    func testNoTwoTabsShareAName() {
        let names = SettingsTab.allCases.map(\.title)
        XCTAssertEqual(Set(names).count, names.count, "two tabs are called the same thing")
    }

    /// A strip is a strip up to about six segments; past that the words start
    /// truncating and it becomes a menu that forgot to be one. This is a
    /// reminder to group rather than a law of nature — if a seventh tab is
    /// genuinely right, the fix is fewer, broader tabs, not a wider window.
    func testTheStripStaysReadable() {
        XCTAssertLessThanOrEqual(SettingsTab.allCases.count, 6)
        XCTAssertGreaterThanOrEqual(SettingsTab.allCases.count, 2)
    }

    /// The first thing the screen opens on, and it is not a catch-all.
    ///
    /// Settings opens on the question this product exists to answer. Anything
    /// else first — a General tab of switches, an About panel — is the screen
    /// deciding that where the owner's speech goes is a detail.
    func testTheScreenOpensOnWhereTheOwnersWordsGo() {
        XCTAssertEqual(SettingsTab.allCases.first, .words)
        XCTAssertTrue(SettingsTab.words.groups.contains(SettingsGroupTitle.brain))
    }

    /// Where the words go and what leaves this Mac are the same question asked
    /// twice, and the second is the audit of the first. Splitting them across
    /// two tabs let each tell half the truth.
    func testWhereWordsGoAndWhatLeavesAreOnOneScreen() {
        let together = SettingsTab.allCases.first {
            $0.groups.contains(SettingsGroupTitle.brain)
        }
        XCTAssertEqual(
            together?.groups.contains(SettingsGroupTitle.privacy),
            true,
            "the destination and the audit of it are on different tabs again"
        )
    }
}
