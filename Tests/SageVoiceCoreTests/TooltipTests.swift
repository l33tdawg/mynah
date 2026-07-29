import SwiftUI
import XCTest
@testable import MynahMac

/// Hover explanations, and the rule that makes them safe.
///
/// The owner asked for these to take text off the screen. The hazard in that is
/// obvious once stated: hover does not exist for everyone. A trackpad user
/// scrolling with two fingers, somebody driving the app by keyboard, VoiceOver —
/// none of them get a tooltip, and neither does anyone who has used the switch.
/// So a fact that lives only on hover is a fact that is missing.
@MainActor
final class TooltipPreferenceTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "mynah.tooltips.\(UUID().uuidString)")!
        defaults.set(true, forKey: "mynah.setupComplete")
        return defaults
    }

    /// On for a first run. Somebody meeting this app needs the explanations;
    /// turning them off is a choice made after learning your way around, and a
    /// default of off would hide the product's reasoning from the one person who
    /// has not read any of it.
    func testExplanationsAreOnUntilTurnedOff() {
        XCTAssertTrue(AppModel(defaults: makeDefaults()).showsTooltips)
    }

    /// A preference that reset overnight would be worse than none — the owner
    /// would switch it off every morning.
    func testTheChoiceSurvivesRelaunch() {
        let defaults = makeDefaults()
        AppModel(defaults: defaults).showsTooltips = false

        XCTAssertFalse(AppModel(defaults: defaults).showsTooltips)
    }

    func testTurningThemBackOnAlsoSurvives() {
        let defaults = makeDefaults()
        let app = AppModel(defaults: defaults)
        app.showsTooltips = false
        app.showsTooltips = true

        XCTAssertTrue(AppModel(defaults: defaults).showsTooltips)
    }

    /// The environment default is what a view sees when nobody has supplied the
    /// preference — a preview, a detached render, a sheet built outside the
    /// window root. It must match the app's default, or a screen behaves one way
    /// in the product and another everywhere it is inspected.
    func testTheEnvironmentDefaultMatchesTheAppDefault() {
        XCTAssertEqual(
            EnvironmentValues().mynahShowsTooltips,
            AppModel(defaults: makeDefaults()).showsTooltips
        )
    }
}

/// The rule itself, asserted where it can be.
///
/// Most of "nothing is only in a tooltip" is a review property rather than a
/// compilable one — it is about where a sentence *also* appears. What can be
/// pinned is the two mechanical halves: the copy promises it, and the text stays
/// reachable to a screen reader that has no hover at all.
final class TooltipContentRuleTests: XCTestCase {

    /// `SettingsRow` attaches its own `detail` as the hover text, and that
    /// detail is drawn on the row regardless. So the tooltip is a second
    /// rendering of something already on screen — which is the whole reason this
    /// arrangement is safe, and the thing that breaks if somebody later moves
    /// the caption *into* the tooltip to save a line.
    func testTheRowsHoverTextIsTheCaptionItAlreadyShows() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/MynahMac/Style/Components.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            source.contains(".mynahTooltip(detail)"),
            "SettingsRow no longer offers its caption on hover"
        )
        // The caption must still be drawn. If this disappears, the detail has
        // become hover-only and the rule is broken.
        XCTAssertTrue(source.contains("MynahWidth.settingsCaption"))
    }

    /// A tooltip is invisible to VoiceOver unless the text is also attached as a
    /// hint, because there is no hover to trigger it.
    func testTheExplanationReachesAScreenReaderWithoutHover() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/MynahMac/Style/MynahTooltip.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            source.contains(".accessibilityHint(text)"),
            "the hover text no longer reaches anyone who cannot hover"
        )
    }

    /// The switch's own copy has to say that turning it off costs nothing, or an
    /// owner reasonably assumes it hides something they need.
    func testTheSwitchPromisesNothingIsHiddenBehindIt() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/MynahMac/Main/SettingsView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("nothing is only in a tooltip"))
    }
}
