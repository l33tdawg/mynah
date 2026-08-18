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
import Foundation
@testable import MynahMac

/// An appliance that does nothing to the machine running the tests.
///
/// **Why every test that builds an `AppModel` should pass one of these.**
///
/// `AppModel.init` defaults `backgroundServices` to
/// `SignalBackgroundServiceManager.shared`, which is aimed at the real home
/// directory. A test that does not inject is therefore holding the live thing,
/// whatever the test is actually about — and on 29 July that is what happened:
/// tests about the *pause marker* deleted both LaunchAgent plists out of
/// `~/Library/LaunchAgents` and left the owner's phone unanswered for an hour.
/// No test failed. Nothing logged. The window kept working, because the window
/// does not go through the bridge.
///
/// The manager now refuses to touch launchd when a test reaches the real home,
/// so nothing can be destroyed by forgetting. **That is a different property
/// from this one, and both are worth having.** The guard protects tests that
/// have not been written yet, including ones written by somebody who never
/// reads this. Injecting makes *this* test hermetic without depending on a
/// safety check somewhere else being correct — and a test whose harmlessness
/// rests on a guard elsewhere is one refactor away from not being harmless.
///
/// The live surface is narrow and worth knowing, because it is what makes this
/// easy to miss: only `isPaused`, `keepsAnsweringWhenClosed` and
/// `refreshPauseState()` reach `reconcileAnsweringService`. `homeSplit` and
/// `showsTooltips` do not. So a file can construct fifteen live managers and be
/// perfectly safe until somebody adds an ordinary property that reconciles, at
/// which point all fifteen arm themselves at once and nothing says so.
actor InertAppliance: SignalBackgroundServicing {
    private(set) var enabledCount = 0
    private(set) var disableCount = 0
    private(set) var reasons: [String] = []

    func enable(_ configuration: SignalServiceConfiguration, retryingAfterFailure: Bool) async throws {
        enabledCount += 1
    }

    func disable(because reason: String) async {
        disableCount += 1
        reasons.append(reason)
    }

    /// Never `.running`. These tests install nothing, and reporting otherwise
    /// would be the same lie `BackgroundHelperState` exists to prevent — saying
    /// what was last asked for rather than what macOS is doing.
    func state() async -> BackgroundHelperState { .absent }
}
#endif  // os(macOS)
