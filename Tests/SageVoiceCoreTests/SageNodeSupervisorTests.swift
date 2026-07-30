import XCTest
@testable import SageVoiceCore

/// Starting a node, and the three variables that let a fresh one remember.
///
/// The fault these exist to keep out is not a crash. Mynah spawned
/// `sage-gui mcp` — a client — from five places and never ran `serve`, so on a
/// Mac that never had SAGE the appliance came up looking configured and talked
/// to a port with no listener. Everything "worked"; nothing was stored.
///
/// The second half is worse because it cannot be repaired later: the vendored
/// companion contract is read at genesis only, and SAGE refuses to retrofit it
/// onto an existing chain. A node created without it is permanently a node that
/// cannot remember. So the assertions about *which* node gets the variables are
/// load-bearing, not tidiness.
final class SageNodeSupervisorTests: XCTestCase {

    private let home = URL(fileURLWithPath: "/Users/someone")

    // MARK: - The genesis contract

    /// The values SAGE's own fixture uses for Mynah
    /// (`cmd/sage-gui/appv23_vendored_bootstrap_test.go`). If these drift, a
    /// fresh install silently goes back to being mute.
    func testBootstrapEnvironmentCarriesTheCompanionContract() {
        let env = SageNodeSupervisor.vendoredBootstrapEnvironment(homeDirectory: home)

        XCTAssertEqual(
            env["SAGE_VENDORED_AGENT_KEY_FILE"],
            MynahIdentity.applianceKeyURL(homeDirectory: home).path
        )
        XCTAssertEqual(env["SAGE_VENDORED_AGENT_HOME_DOMAIN"], "voice-interface")
        XCTAssertEqual(env["SAGE_VENDORED_AGENT_CLEARANCE"], "2")
    }

    /// The home domain must be the domain the appliance actually writes to.
    /// A mismatch fails the original silent way: writes refused, nothing said.
    func testBootstrapHomeDomainIsTheDomainTheApplianceWritesTo() {
        let env = SageNodeSupervisor.vendoredBootstrapEnvironment(homeDirectory: home)
        XCTAssertEqual(env["SAGE_VENDORED_AGENT_HOME_DOMAIN"], SageRitual.memoryDomain)
    }

    /// Genesis refuses to let Root and companion be the same key file, which is
    /// `MynahIdentity`'s own rule enforced a layer down. The appliance key is
    /// deliberately not the node operator key.
    func testBootstrapKeyIsNotTheNodeOperatorKey() {
        let env = SageNodeSupervisor.vendoredBootstrapEnvironment(homeDirectory: home)
        let operatorKey = home.appendingPathComponent(".sage/agent.key").path
        XCTAssertNotEqual(env["SAGE_VENDORED_AGENT_KEY_FILE"], operatorKey)
    }

    // MARK: - Which node may be bootstrapped

    /// The one that must never regress. Those variables against a chain that
    /// was not born from that genesis make `serve` refuse to boot at all, so
    /// pointing them at the owner's node takes a working SAGE and stops it
    /// starting.
    func testAnInstalledNodeIsStartedWithoutBootstrapEnvironment() throws {
        let supervisor = SageNodeSupervisor()
        let choice = SageNodeChoice(executable: URL(fileURLWithPath: "/bin/echo"), source: .installed)

        let outcome = supervisor.startIfNeeded(choice: choice, homeDirectory: home)
        defer { supervisor.stop() }

        XCTAssertEqual(outcome, .started(executablePath: "/bin/echo", bootstrapped: false))
    }

    func testAVendoredNodeIsStartedWithTheBootstrapContract() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SageNodeSupervisorTests-\(UUID().uuidString)")
        let executable = try Self.makeBundle(at: root, version: "11.16.0")
        defer { try? FileManager.default.removeItem(at: root) }

        let supervisor = SageNodeSupervisor()
        let outcome = supervisor.startIfNeeded(
            choice: SageNodeChoice(executable: executable, source: .vendored),
            homeDirectory: home
        )
        defer { supervisor.stop() }

        XCTAssertEqual(outcome, .started(executablePath: executable.path, bootstrapped: true))
    }

    // MARK: - The version gate, and why refusing beats starting

    /// 11.14.1 is what was actually vendored when this was written, and it does
    /// not contain the string `SAGE_VENDORED_AGENT_KEY_FILE` at all. It would
    /// not reject the contract — it would ignore it, and mint a chain whose
    /// agent can never be given one.
    func testTheVendoredBuildThatShippedIsRefused() {
        XCTAssertFalse(SageNodeSupervisor.supportsCompanionBootstrap(version: "11.14.1"))
    }

    /// 11.15.1 bootstraps correctly and commits a first memory, and is still
    /// refused: recall fails on it with "Memory classification state is
    /// unavailable", measured at two heights on a fresh vendored node. An
    /// appliance that stores and cannot recall looks like it works, which is
    /// the failure this supervisor exists to prevent.
    func testABuildThatBootstrapsButCannotRecallIsRefused() {
        XCTAssertFalse(SageNodeSupervisor.supportsCompanionBootstrap(version: "11.15.0"))
        XCTAssertFalse(SageNodeSupervisor.supportsCompanionBootstrap(version: "11.15.1"))
    }

    func testABuildCarryingTheContractIsAccepted() {
        XCTAssertTrue(SageNodeSupervisor.supportsCompanionBootstrap(version: "11.16.0"))
        XCTAssertTrue(SageNodeSupervisor.supportsCompanionBootstrap(version: "11.16.1"))
        XCTAssertTrue(SageNodeSupervisor.supportsCompanionBootstrap(version: "12.0.0"))
    }

    /// "Cannot tell" has to mean no. The failure being guarded is permanent, so
    /// an unreadable `Info.plist` must not be resolved in favour of starting.
    func testAnUnreadableVersionIsRefused() {
        XCTAssertFalse(SageNodeSupervisor.supportsCompanionBootstrap(version: nil))
        XCTAssertFalse(SageNodeSupervisor.supportsCompanionBootstrap(version: ""))
        XCTAssertFalse(SageNodeSupervisor.supportsCompanionBootstrap(version: "not a version"))
    }

    /// A vendored bundle too old to carry the contract is not started at all.
    /// No node is visible and recoverable; an un-bootstrappable node is neither.
    func testAnOldVendoredBundleIsNotStarted() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SageNodeSupervisorTests-\(UUID().uuidString)")
        let executable = try Self.makeBundle(at: root, version: "11.14.1")
        defer { try? FileManager.default.removeItem(at: root) }

        let supervisor = SageNodeSupervisor()
        let outcome = supervisor.startIfNeeded(
            choice: SageNodeChoice(executable: executable, source: .vendored),
            homeDirectory: home
        )

        XCTAssertEqual(outcome, .vendoredNodeTooOld(version: "11.14.1"))
    }

    /// The gate is about *our* copy only. An owner's installed node is started
    /// as it is — Mynah does not version-gate somebody else's SAGE, and never
    /// passes it the genesis contract either.
    func testAnOldInstalledBundleIsStartedAnyway() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SageNodeSupervisorTests-\(UUID().uuidString)")
        let executable = try Self.makeBundle(at: root, version: "11.14.1")
        defer { try? FileManager.default.removeItem(at: root) }

        let supervisor = SageNodeSupervisor()
        let outcome = supervisor.startIfNeeded(
            choice: SageNodeChoice(executable: executable, source: .installed),
            homeDirectory: home
        )
        defer { supervisor.stop() }

        XCTAssertEqual(outcome, .started(executablePath: executable.path, bootstrapped: false))
    }

    /// A runnable `SAGE.app` reporting `version`, so the gate can be exercised
    /// without a 555 MB bundle.
    private static func makeBundle(at root: URL, version: String) throws -> URL {
        let macOS = root.appendingPathComponent("SAGE.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)

        let plist = root.appendingPathComponent("SAGE.app/Contents/Info.plist")
        let contents: [String: Any] = [
            "CFBundleIdentifier": "com.sage.brain",
            "CFBundleShortVersionString": version
        ]
        try PropertyListSerialization
            .data(fromPropertyList: contents, format: .xml, options: 0)
            .write(to: plist)

        let executable = macOS.appendingPathComponent("sage-gui")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }

    // MARK: - Not starting

    func testNothingToStartWhenThereIsNoNodeAtAll() {
        let supervisor = SageNodeSupervisor()
        XCTAssertEqual(supervisor.startIfNeeded(choice: nil, homeDirectory: home), .noNodeAvailable)
    }

    /// A bundle that is present but has no runnable executable inside it is
    /// handed to the system, which is QuietType's fallback: SAGE.app serves its
    /// own node when opened.
    func testABundleWithNoExecutableIsHandedToTheSystem() throws {
        let bundle = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SageNodeSupervisorTests-\(UUID().uuidString)/SAGE.app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }

        let opened = OpenedBundleRecorder()
        let supervisor = SageNodeSupervisor(openApplication: { opened.record($0) })
        let missing = bundle.appendingPathComponent("Contents/MacOS/sage-gui")

        let outcome = supervisor.startIfNeeded(
            choice: SageNodeChoice(executable: missing, source: .installed),
            homeDirectory: home
        )

        XCTAssertEqual(outcome, .openedApplication(bundlePath: bundle.path))
        XCTAssertEqual(opened.urls.map(\.path), [bundle.path])
    }

    // MARK: - The spawn loop this must not become

    /// `serve` is fail-closed about the companion contract and exits
    /// immediately when it is not satisfied. Without a cooldown every probe
    /// would spawn another one and watch it die, forever.
    func testASecondStartWithinTheCooldownIsRefused() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SageNodeSupervisorTests-\(UUID().uuidString)")
        let executable = try Self.makeBundle(at: root, version: "11.16.0")
        defer { try? FileManager.default.removeItem(at: root) }

        var clock = Date(timeIntervalSince1970: 1_000)
        let supervisor = SageNodeSupervisor(now: { clock })
        let choice = SageNodeChoice(executable: executable, source: .vendored)

        XCTAssertEqual(
            supervisor.startIfNeeded(choice: choice, homeDirectory: home),
            .started(executablePath: executable.path, bootstrapped: true)
        )
        // Empties the slot, which is what a `serve` that exited fail-closed
        // leaves behind. Done explicitly rather than by waiting for `/bin/echo`
        // to be reaped: `isRunning` stays true until then, and a test that
        // depended on that timing would report the cooldown working when what
        // it actually observed was a process that had not died yet.
        supervisor.stop()

        clock = clock.addingTimeInterval(SageNodeSupervisor.retryCooldownSeconds - 1)
        XCTAssertEqual(supervisor.startIfNeeded(choice: choice, homeDirectory: home), .cooledDown)
    }

    func testAStartIsAllowedOnceTheCooldownHasPassed() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SageNodeSupervisorTests-\(UUID().uuidString)")
        let executable = try Self.makeBundle(at: root, version: "11.16.0")
        defer { try? FileManager.default.removeItem(at: root) }

        var clock = Date(timeIntervalSince1970: 1_000)
        let supervisor = SageNodeSupervisor(now: { clock })
        let choice = SageNodeChoice(executable: executable, source: .vendored)

        _ = supervisor.startIfNeeded(choice: choice, homeDirectory: home)
        supervisor.stop()
        clock = clock.addingTimeInterval(SageNodeSupervisor.retryCooldownSeconds + 1)

        XCTAssertEqual(
            supervisor.startIfNeeded(choice: choice, homeDirectory: home),
            .started(executablePath: executable.path, bootstrapped: true)
        )
        supervisor.stop()
    }

    // MARK: - "Nothing is listening", and nothing else

    /// Narrow on purpose. A node that answers with a real HTTP error is running
    /// and has something else wrong with it; starting a second `serve` would
    /// not fix it and would be a second brain on a Mac that asked for one.
    func testOnlyConnectionShapedFailuresMeanNoNodeIsRunning() {
        for code in [
            NSURLErrorCannotConnectToHost,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorTimedOut,
            NSURLErrorCannotFindHost,
            NSURLErrorNotConnectedToInternet
        ] {
            let error = NSError(domain: NSURLErrorDomain, code: code)
            XCTAssertTrue(
                SageNodeSupervisor.isNodeNotRunning(error),
                "URL error \(code) should mean no node is listening"
            )
        }

        XCTAssertFalse(
            SageNodeSupervisor.isNodeNotRunning(
                NSError(domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse)
            )
        )
        XCTAssertFalse(
            SageNodeSupervisor.isNodeNotRunning(NSError(domain: "SomethingElse", code: -1004))
        )
    }

    func testTheStatusCodesThatMeanNoNodeIsRunning() {
        XCTAssertTrue(SageNodeSupervisor.isNodeNotRunning(httpStatus: 0))
        XCTAssertTrue(SageNodeSupervisor.isNodeNotRunning(httpStatus: 502))
        XCTAssertTrue(SageNodeSupervisor.isNodeNotRunning(httpStatus: 503))

        // A node that answers 200/404/500 is running.
        for status in [200, 404, 500] {
            XCTAssertFalse(SageNodeSupervisor.isNodeNotRunning(httpStatus: status))
        }
    }
}

/// Collects the bundles handed to the system, without needing AppKit.
private final class OpenedBundleRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ url: URL) {
        lock.lock()
        storage.append(url)
        lock.unlock()
    }
}
