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

/// **"says not connected but it is".**
///
/// The owner, on 1.3.0, with Signal working, the helper Running and the socket
/// present on disk. Nothing about the check was wrong — the path was right, the
/// app is not sandboxed, and `fileExists` does see a unix socket. The row was
/// simply read once in `onAppear` and never again.
///
/// signal-cli creates that socket a few seconds after launch, longer on a cold
/// Mac. Open Settings inside that window and "Not connected" stays on the screen
/// until the owner navigates away and back — underneath a sentence promising it
/// will change on its own. Every other changing thing in the pane was already
/// re-asked; this was the one that was not, and it is the one somebody reads to
/// decide whether their phone works.
@MainActor
final class PhoneReachabilityWatchTests: XCTestCase {

    /// A link whose answer can change between reads, which is the whole point.
    private final class ChangingPhoneLink: PhoneLinking, @unchecked Sendable {
        private let lock = NSLock()
        private var reachable: Bool

        init(reachable: Bool) { self.reachable = reachable }

        func set(reachable: Bool) {
            lock.lock(); defer { lock.unlock() }
            self.reachable = reachable
        }

        var status: PhoneStatus {
            lock.lock(); defer { lock.unlock() }
            return PhoneStatus(
                isReachable: reachable,
                linkedNumber: "+6012·····89",
                socketPath: "/tmp/daemon.socket"
            )
        }

        var canUnlink: Bool { true }
        func unlink() async throws -> String? { nil }
    }

    private func model(_ link: any PhoneLinking) -> SettingsModel {
        let defaults = UserDefaults(suiteName: "mynah.phone.\(UUID().uuidString)")!
        let updates = FileManager.default.temporaryDirectory
            .appendingPathComponent("mynah.phone.\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("update-preferences.json", isDirectory: false)
        UpdatePreferences.amend(at: updates) { $0.checksForUpdates = false }
        return SettingsModel(defaults: defaults, updatePreferences: updates, phoneLink: link)
    }

    /// Waits for the watch to notice, rather than sleeping for a fixed guess —
    /// a test that sleeps exactly one interval fails on a loaded machine.
    private func waitForReachable(_ model: SettingsModel, within: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(within)
        while Date() < deadline {
            if model.phone.isReachable { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return model.phone.isReachable
    }

    /// The report, exactly. The socket turns up after the screen is already
    /// open, and the row has to notice without being reopened.
    func testTheRowNoticesTheSocketAppearing() async {
        let link = ChangingPhoneLink(reachable: false)
        let model = model(link)
        XCTAssertFalse(model.phone.isReachable, "precondition")

        let watch = Task { await model.watchPhoneReachability() }
        defer { watch.cancel() }

        link.set(reachable: true)

        let noticed = await waitForReachable(model)
        XCTAssertTrue(noticed, "the row still said Not connected after the socket appeared")
    }

    /// And back again, so a daemon that dies is not reported as healthy for as
    /// long as the window stays open.
    func testItAlsoNoticesTheSocketGoingAway() async {
        let link = ChangingPhoneLink(reachable: true)
        let model = model(link)

        let watch = Task { await model.watchPhoneReachability() }
        defer { watch.cancel() }

        _ = await waitForReachable(model)
        link.set(reachable: false)

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, model.phone.isReachable {
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(model.phone.isReachable)
    }

    /// Cancelling ends it. SwiftUI cancels the enclosing `.task` when the pane
    /// goes away, and a loop that ignored that would keep polling for the life
    /// of the app.
    func testItStopsWhenTheScreenGoesAway() async {
        let link = ChangingPhoneLink(reachable: false)
        let model = model(link)

        let watch = Task { await model.watchPhoneReachability() }
        watch.cancel()
        _ = await watch.value

        XCTAssertTrue(watch.isCancelled)
    }

    /// The detail line promises the row will change on its own — *"Mynah is
    /// starting the private Signal link. If this does not change…"*. That was a
    /// promise the code did not keep, which is what made it a bug report rather
    /// than a cosmetic issue. It keeps it now, and says how long to expect.
    func testTheWordingPromisesSomethingTheCodeNowDoes() {
        let starting = PhoneStatus(isReachable: false, linkedNumber: "+6012·····89", socketPath: "/tmp/s")
        let detail = starting.reachabilityDetail(helper: .running)

        XCTAssertTrue(detail.lowercased().contains("starting"), detail)
        XCTAssertTrue(detail.contains("ten seconds"), "it should say how long: \(detail)")
    }
}
#endif  // os(macOS)
