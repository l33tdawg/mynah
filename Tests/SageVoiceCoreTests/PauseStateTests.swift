import XCTest
@testable import SageVoiceCore

/// Pause, which used to stop nothing.
///
/// `TalkView` said "It won't answer your phone, or this window". Settings said
/// the same. Every reader of `isPaused` was view code — nothing in
/// `SageVoiceCore` or `sage-voiced` had ever heard of it — so the owner flipped
/// it before a meeting and their phone kept being answered.
///
/// It became more serious the moment the daemon went under launchd with
/// `KeepAlive`: the appliance is now harder to stop by hand, so the switch that
/// claims to stop it is the only thing between the owner and an assistant
/// talking during their meeting.
final class PauseStateTests: XCTestCase {

    private var directory: URL!
    private var pause: PauseState!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pause-\(UUID().uuidString)", isDirectory: true)
        pause = PauseState(fileURL: directory.appendingPathComponent("paused"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// The whole point: a second process has to be able to see it. The app and
    /// the daemon share no channel, which is why UserDefaults could never have
    /// worked.
    func testAnotherProcessCanSeeThePause() throws {
        XCTAssertFalse(pause.isPaused())

        try pause.setPaused(true)
        let asTheDaemonSeesIt = PauseState(fileURL: directory.appendingPathComponent("paused"))
        XCTAssertTrue(asTheDaemonSeesIt.isPaused(), "the daemon cannot tell the owner paused")

        try pause.setPaused(false)
        XCTAssertFalse(asTheDaemonSeesIt.isPaused(), "the daemon would stay paused forever")
    }

    /// Presence is the signal, not the contents. A flag that has to be parsed
    /// can fail open — a truncated write or an empty file reading as "not
    /// paused" would answer the phone anyway.
    func testAnEmptyOrOddFileStillCountsAsPaused() throws {
        try OwnerOnlyFileSecurity.prepareDirectory(directory)
        let file = directory.appendingPathComponent("paused")

        try Data().write(to: file)
        XCTAssertTrue(pause.isPaused(), "an empty flag file failed open")

        try Data("not json at all".utf8).write(to: file)
        XCTAssertTrue(pause.isPaused(), "an unparseable flag file failed open")
    }

    func testPausingIsIdempotent() throws {
        try pause.setPaused(true)
        try pause.setPaused(true)
        XCTAssertTrue(pause.isPaused())

        try pause.setPaused(false)
        try pause.setPaused(false)
        XCTAssertFalse(pause.isPaused())
    }

    /// The flag holds no content, but it lives beside the owner's conversations
    /// and keys and gets the same treatment as the rest of that directory.
    func testTheFlagIsOwnerOnly() throws {
        try pause.setPaused(true)
        let file = directory.appendingPathComponent("paused")
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode, 0o600)
    }

    func testItRecordsWhenThePauseStarted() throws {
        XCTAssertNil(pause.pausedAt())
        try pause.setPaused(true)
        let at = pause.pausedAt()
        XCTAssertNotNil(at)
        XCTAssertLessThan(abs(at!.timeIntervalSinceNow), 5)
    }

    /// Unpausing something that was never paused must not throw — the app calls
    /// this on every launch to reconcile its saved preference.
    func testUnpausingWhenNotPausedIsHarmless() {
        XCTAssertNoThrow(try pause.setPaused(false))
        XCTAssertFalse(pause.isPaused())
    }
}
