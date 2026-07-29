import XCTest
@testable import MynahMac
@testable import SageVoiceCore

/// Pause has one store, and it is the file.
///
/// The owner reported this as *"the app keeps going offline / going to sleep —
/// I can't send it messages, I need to click pause and resume then it wakes
/// up."* It was not sleeping. The daemon was paused and the window said Online,
/// twice in an hour, each time swallowing a message he was waiting on:
///
///     [daemon] paused — ignoring: are you online ??
///
/// Two stores, reconciled only on change. `UserDefaults` lives in the app
/// container; the `paused` marker lives in Application Support and survives a
/// reinstall. `didSet` does not fire for an assignment in an initializer, so
/// the launch path believed defaults and never wrote the file.
///
/// Every test here is about the disagreement rather than about pausing, because
/// pausing worked fine — it was the agreement that did not.
@MainActor
final class PauseIsOneStoreTests: XCTestCase {

    private var root: URL!
    private var marker: URL!
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pause-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        marker = root.appendingPathComponent("paused", isDirectory: false)
        suite = "PauseIsOneStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    /// Injects **both** shared dependencies, not just the one this file is about.
    ///
    /// The pause marker was injected from the start, for the reason on
    /// `AppModel.pauseState`. `backgroundServices` was not, and that turned out
    /// to matter far more: it defaults to the real `SignalBackgroundServiceManager`
    /// aimed at the real home directory, and setting `isPaused` here fired a
    /// reconcile that — with a fresh defaults suite and therefore no stored
    /// brain — took a branch that **deleted the appliance's launchd plists off
    /// the developer's own Mac**. These tests uninstalled the owner's Signal
    /// appliance every time they ran, silently, without failing.
    ///
    /// `chrome` found it and the manager now refuses to touch launchd when a
    /// test reaches the real home. This injection is belt and braces on top of
    /// that guard, and belt and braces is the right posture when the failure
    /// mode is destructive and silent: a test should not depend on a safety
    /// check elsewhere being correct in order to be harmless.
    ///
    /// The lesson generalises past launchd. Any default that points at the real
    /// machine is shared state, and a test that does not name it is a test
    /// whose result — or whose damage — depends on whose Mac it ran on.
    private func makeApp() -> AppModel {
        AppModel(
            defaults: defaults,
            backgroundServices: InertBackgroundServices(),
            pauseState: PauseState(fileURL: marker)
        )
    }

    private func markerExists() -> Bool {
        FileManager.default.fileExists(atPath: marker.path)
    }

    // MARK: - The shape that bit him

    /// **The reinstall.** A fresh build has empty `UserDefaults` and a `paused`
    /// marker left in Application Support by the install before it.
    ///
    /// This is invisible to any test that sets both stores, which is why it
    /// shipped: the old launch path read `defaults.bool(forKey:)`, got `false`
    /// for a key that had never been written, and reported Online over a marker
    /// that was telling the daemon to ignore every message.
    func testAFreshInstallAdoptsAStaleMarkerRatherThanContradictingIt() throws {
        try PauseState(fileURL: marker).setPaused(true)
        // Deliberately not setting "mynah.paused" — a reinstall has no defaults.
        XCTAssertTrue(makeApp().isPaused, "the window would say Online while the daemon ignored everything")
    }

    /// The mirror image, and the reason deleting the defaults copy is safe: an
    /// absent marker means answering, whatever any leftover key from an older
    /// build happens to say.
    func testAStaleDefaultsKeyCannotPauseAnApplianceThatIsRunning() {
        defaults.set(true, forKey: "mynah.paused")
        XCTAssertFalse(makeApp().isPaused, "a defaults key nothing writes any more decided the answer")
    }

    /// Launch must not merely *read* the right store — it must leave the two
    /// processes agreeing. The old code path could not, because `didSet` does
    /// not fire from an initializer.
    func testLaunchLeavesTheFileAndTheWindowAgreeing() {
        let app = makeApp()
        XCTAssertEqual(app.isPaused, PauseState(fileURL: marker).isPaused())
    }

    // MARK: - Writing

    func testPausingWritesTheMarkerTheDaemonReads() {
        let app = makeApp()
        app.isPaused = true
        XCTAssertTrue(markerExists())
        app.isPaused = false
        XCTAssertFalse(markerExists())
    }

    /// The daemon obeys the file. Nothing else may claim to.
    func testPausingWritesNothingToUserDefaults() {
        let app = makeApp()
        app.isPaused = true
        XCTAssertNil(
            defaults.object(forKey: "mynah.paused"),
            "a second store is back, and it can disagree with the first"
        )
    }

    // MARK: - Staleness in the other direction

    /// The daemon reads the marker per message; the window caches it. So the
    /// window is the half that goes stale — when a second process, or the owner
    /// with `rm`, changes it underneath a running app.
    func testTheWindowAdoptsAChangeMadeByAnotherProcess() throws {
        let app = makeApp()
        XCTAssertFalse(app.isPaused)
        try PauseState(fileURL: marker).setPaused(true)
        XCTAssertFalse(app.isPaused, "nothing has told it to look yet")
        app.refreshPauseState()
        XCTAssertTrue(app.isPaused, "the window is still promising to answer")
    }

    func testTheWindowAdoptsAResumeMadeByAnotherProcess() throws {
        try PauseState(fileURL: marker).setPaused(true)
        let app = makeApp()
        XCTAssertTrue(app.isPaused)
        try PauseState(fileURL: marker).setPaused(false)
        app.refreshPauseState()
        XCTAssertFalse(app.isPaused)
    }

    /// Adopting the file's state must not write it back.
    ///
    /// `PauseState.pausedAt()` reports the marker's modification date as
    /// "paused since 14:32", so a refresh that rewrote an identical value would
    /// quietly reset that clock every time the owner clicked back into the
    /// window — and the answer would always be "just now".
    func testAdoptingFromDiskDoesNotTouchTheMarker() throws {
        try PauseState(fileURL: marker).setPaused(true)
        let app = makeApp()
        let before = try XCTUnwrap(PauseState(fileURL: marker).pausedAt())

        app.refreshPauseState()
        app.refreshPauseState()

        XCTAssertTrue(app.isPaused)
        XCTAssertEqual(
            try XCTUnwrap(PauseState(fileURL: marker).pausedAt()),
            before,
            "\"paused since\" would restart every time the window came forward"
        )
    }

    /// Same guarantee for an ordinary no-op assignment, which SwiftUI bindings
    /// produce freely.
    func testARedundantAssignmentDoesNotTouchTheMarker() throws {
        try PauseState(fileURL: marker).setPaused(true)
        let app = makeApp()
        let before = try XCTUnwrap(PauseState(fileURL: marker).pausedAt())
        app.isPaused = true
        XCTAssertEqual(try XCTUnwrap(PauseState(fileURL: marker).pausedAt()), before)
    }

    // MARK: - The marker's own failure direction

    /// Presence is the signal, so a corrupt or empty marker still reads as
    /// paused. Worth pinning: the safe direction for this flag is "still
    /// paused", never "started answering again on its own".
    func testAnEmptyMarkerStillMeansPaused() throws {
        try Data().write(to: marker)
        XCTAssertTrue(PauseState(fileURL: marker).isPaused())
        XCTAssertTrue(makeApp().isPaused)
    }
}

/// Does nothing to this Mac.
///
/// These tests are about which store pause lives in. Whether launchd jobs get
/// installed is a different subject, and letting it be a live dependency is how
/// tests about a marker file came to uninstall an appliance.
private actor InertBackgroundServices: SignalBackgroundServicing {
    private(set) var enabledCount = 0
    private(set) var disableCount = 0

    func enable(_ configuration: SignalServiceConfiguration) async throws { enabledCount += 1 }
    func disable() async { disableCount += 1 }
}
