import Foundation

/// Whether this quit is a restart.
///
/// **The difference is not cosmetic.** Quitting Mynah stops the appliance —
/// `applicationShouldTerminate` removes both LaunchAgents so that a quit means
/// what quitting means everywhere else on the Mac, and it takes `.terminateLater`
/// plus two `launchctl bootout` calls to do it. Restarting is the opposite
/// errand: the app is coming back in the same second, the owner's phone should
/// go on being answered throughout, and the jobs that would be removed are the
/// jobs the next launch would immediately put back.
///
/// So the quit path asks this before it starts tearing anything down.
///
/// A shared object with a lock rather than a `@MainActor` flag, because the two
/// sides are not on the same actor: `SettingsModel` sets it from the main
/// actor, and `NSApplicationDelegate` is not main-actor isolated here — the
/// sibling `applicationWillTerminate` needs `MainActor.assumeIsolated` to touch
/// the HUD, which is the proof.
///
/// One-way on purpose. Nothing clears it, because the only thing that happens
/// after it is set is the process ending.
final class RestartIntent: @unchecked Sendable {

    static let shared = RestartIntent()

    private let lock = NSLock()
    private var underway = false

    /// Called immediately before `NSApplication.terminate`.
    func begin() {
        lock.lock()
        underway = true
        lock.unlock()
    }

    var isUnderway: Bool {
        lock.lock()
        defer { lock.unlock() }
        return underway
    }

    /// Tests only. The shared instance is process-wide and one test setting it
    /// would otherwise decide the answer for every test after it.
    func resetForTesting() {
        lock.lock()
        underway = false
        lock.unlock()
    }
}
