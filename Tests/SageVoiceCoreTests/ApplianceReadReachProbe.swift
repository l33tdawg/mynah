import XCTest
@testable import MynahMac
@testable import SageVoiceCore

/// What the *appliance's own identity* can read. Opt-in; a probe, not a rule.
@MainActor
final class ApplianceReadReachProbe: XCTestCase {

    func testWhatMynahCanActuallyRead() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MYNAH_LIVE_NODE_TESTS"] == "1",
            "opt-in: signs as the appliance and reads from the live node"
        )

        // `SageMemoryStore` is the app's own reader and signs with
        // `MynahIdentity.applianceEnvironment()` — Mynah's key, not this
        // session's.
        for domain in ["general", "voice-interface", "native-shell-ci", "sage-release", "self"] {
            do {
                let page = try await SageMemoryStore.shared.recent(topic: domain, limit: 2, offset: 0)
                print("READ \(domain): ok, \(page.memories.count) of \(page.total)")
            } catch {
                print("READ \(domain): REFUSED — \(String(describing: error))")
            }
        }
        // And with no domain filter at all, which is what the screen does.
        do {
            let page = try await SageMemoryStore.shared.recent(topic: nil, limit: 3, offset: 0)
            print("READ <no filter>: ok, \(page.memories.count) of \(page.total)")
        } catch {
            print("READ <no filter>: REFUSED — \(String(describing: error))")
        }
    }
}
