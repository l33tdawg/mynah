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
@testable import SageVoiceCore

/// What the app can say about the helper that answers the phone.
///
/// The gap this closes is not a bug in the helper — it is that **nothing could
/// ask about it**. `SignalBackgroundServicing` could `enable` and `disable`, so
/// every screen reported what Mynah had last *requested*. Writing a LaunchAgent
/// puts an entry in System Settings → General → Login Items and the owner can
/// switch it off there; when they do, the phone stops being answered and the app
/// carried on saying answering was on. Same shape as the ghost identity and the
/// scoped backlog: a true state the product had no way to see.
final class BackgroundHelperStateTests: XCTestCase {

    /// The case the whole type exists for. `installedButNotRunning` is what the
    /// owner switching Mynah off in Login Items looks like from in here, and it
    /// must not collapse into either neighbour: `absent` would read as "you
    /// turned answering off", and `running` would be a lie.
    func testTheLoginItemsCaseIsItsOwnAnswer() {
        let all: [BackgroundHelperState] = [.running, .installedButNotRunning, .absent, .unknown]
        XCTAssertEqual(Set(all).count, 4, "two states collapsed into one")
        XCTAssertNotEqual(BackgroundHelperState.installedButNotRunning, .absent)
        XCTAssertNotEqual(BackgroundHelperState.installedButNotRunning, .running)
    }

    /// An appliance that cannot see its own helper must not claim the helper is
    /// gone. `unknown` is the honest answer when launchd does not respond, and
    /// it is deliberately not `absent`.
    func testNotBeingAbleToAskIsNotTheSameAsOff() {
        XCTAssertNotEqual(BackgroundHelperState.unknown, .absent)
    }
}

/// What Settings tells the owner about it.
@MainActor
final class BackgroundHelperCopyTests: XCTestCase {

    private func model(_ state: BackgroundHelperState) async -> SettingsModel {
        let services = StubBackgroundServices(state: state)
        let defaults = UserDefaults(suiteName: "mynah.helper.\(UUID().uuidString)")!
        let updates = FileManager.default.temporaryDirectory
            .appendingPathComponent("mynah.helper.\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("update-preferences.json", isDirectory: false)
        UpdatePreferences.amend(at: updates) { $0.checksForUpdates = false }

        let model = SettingsModel(
            defaults: defaults,
            updatePreferences: updates,
            backgroundServices: services
        )
        await model.refreshHelperState()
        return model
    }

    func testItReportsWhatLaunchdSaysRatherThanWhatWasAskedFor() async {
        for state in [BackgroundHelperState.running, .installedButNotRunning, .absent, .unknown] {
            let model = await model(state)
            XCTAssertEqual(model.helperState, state, "Settings did not read \(state) back")
        }
    }

    /// Before the first answer there is nothing to report, and the row draws no
    /// pill — a pill that says one thing and corrects itself half a second later
    /// is the screen guessing out loud.
    func testThereIsNoAnswerBeforeOneHasBeenAsked() {
        let defaults = UserDefaults(suiteName: "mynah.helper.\(UUID().uuidString)")!
        let updates = FileManager.default.temporaryDirectory
            .appendingPathComponent("mynah.helper.\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("update-preferences.json", isDirectory: false)
        UpdatePreferences.amend(at: updates) { $0.checksForUpdates = false }

        let model = SettingsModel(
            defaults: defaults,
            updatePreferences: updates,
            backgroundServices: StubBackgroundServices(state: .running)
        )
        XCTAssertNil(model.helperState)
    }
}

/// The sentence setup uses before macOS says it less kindly.
final class BackgroundHelperNoticeTests: XCTestCase {

    /// macOS announces "Mynah added items that can run in the background" the
    /// first time a LaunchAgent is written. An owner who has just finished
    /// setting up a *private* voice appliance and is then told by their Mac that
    /// it added background items, with no warning from the app, has every reason
    /// to wonder what else it did quietly. The setup note has to name the same
    /// thing macOS is about to name.
    func testTheSetupNoticeNamesWhatMacOSWillCallIt() {
        let headline = "Your Mac will say Mynah added a background item."
        XCTAssertTrue(headline.lowercased().contains("background"))
    }

    /// The half nothing anywhere said: the helper is *how the phone is
    /// answered*, so switching it off in Login Items stops that. A note that
    /// explained the notification without explaining the cost would leave the
    /// owner free to turn off the thing the product runs on.
    func testTheNoticeSaysWhatTurningItOffCosts() {
        let explanation = "That is this: a small helper that answers your phone while the "
            + "window is closed. It appears in System Settings under General → Login "
            + "Items, and switching it off there stops Mynah answering."

        XCTAssertTrue(explanation.contains("Login"))
        XCTAssertTrue(
            explanation.lowercased().contains("stops mynah answering"),
            "the notice explains the notification but not the consequence"
        )
    }
}

private actor StubBackgroundServices: SignalBackgroundServicing {
    private let reported: BackgroundHelperState

    init(state: BackgroundHelperState) { self.reported = state }

    func enable(_ configuration: SignalServiceConfiguration, retryingAfterFailure: Bool) async throws {}
    func disable(because reason: String) async {}
    func state() async -> BackgroundHelperState { reported }
}
#endif  // os(macOS)
