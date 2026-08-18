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

/// Turning WhatsApp on and off has to change what launchd is running.
///
/// **The failure shape this file exists for has happened twice in this
/// codebase already.** On 5 August a reconcile wrote new plists, restarted
/// nothing, and convinced every later attempt there was nothing to do; the
/// repair was to ask launchd which build it had actually loaded. Adding a third
/// job re-opens exactly that door — a check that asks about two of three jobs
/// declares itself finished while the third has never started, and
/// `isAlreadyReconciled` then declines to try again for ever.
///
/// So each of these drives `enable` against `FakeLaunchd`, which loads a build
/// stamp out of the plist it is handed and reports what it holds, rather than
/// asserting that the right launchctl command was typed.
final class TheThirdLaunchAgentTests: XCTestCase {

    private struct Fixture {
        let scratch: URL
        let configuration: SignalServiceConfiguration
        let launchd: FakeLaunchd
        let manager: SignalBackgroundServiceManager

        var launchAgents: URL {
            scratch.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        }
        func plist(_ label: String) -> URL {
            launchAgents.appendingPathComponent("\(label).plist")
        }
    }

    private func fixture(withWhatsApp: Bool, name: String = #function) throws -> Fixture {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("mynah-third-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        func executable(_ name: String) throws -> URL {
            let url = scratch.appendingPathComponent(name)
            try Data(name.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url
        }

        let node = try executable("node")
        let bridgeScript = scratch.appendingPathComponent("bridge.js")
        try Data("// bridge".utf8).write(to: bridgeScript)

        let launchd = FakeLaunchd()
        return Fixture(
            scratch: scratch,
            configuration: SignalServiceConfiguration(
                account: "+60123821767",
                signalCLI: try executable("signal-cli"),
                bridge: try executable("sage-voiced"),
                sage: try executable("sage-gui"),
                provider: "ollama",
                model: nil,
                socketPath: scratch.appendingPathComponent("daemon.socket").path,
                channels: withWhatsApp ? .both : .signalOnly,
                whatsApp: withWhatsApp
                    ? WhatsAppServiceConfiguration(
                        node: node,
                        bridge: bridgeScript,
                        numbers: ["60123821767"],
                        port: 39930,
                        socketPath: scratch.appendingPathComponent("wa.sock").path
                    )
                    : nil
            ),
            launchd: launchd,
            manager: SignalBackgroundServiceManager(runner: launchd, homeDirectory: scratch, userID: 501)
        )
    }

    func testTurningWhatsAppOnInstallsAndStartsItsHelper() async throws {
        let f = try fixture(withWhatsApp: true)
        defer { try? FileManager.default.removeItem(at: f.scratch) }

        try await f.manager.enable(f.configuration)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: f.plist(SignalBackgroundServiceManager.whatsAppLabel).path),
            "WhatsApp was chosen and no LaunchAgent was written for it"
        )
        let bootstraps = await f.launchd.bootstraps
        XCTAssertEqual(bootstraps, 3, "one of the three jobs was never asked to start")
    }

    /// **Not "leave whatever is there alone".** WhatsApp being off means there
    /// must be no WhatsApp helper — a bridge left loaded after the owner
    /// switched the channel off is this app holding a live connection to their
    /// WhatsApp account after telling them it had stopped.
    func testTurningWhatsAppOffRemovesTheHelperRatherThanIgnoringIt() async throws {
        let on = try fixture(withWhatsApp: true)
        defer { try? FileManager.default.removeItem(at: on.scratch) }
        try await on.manager.enable(on.configuration)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: on.plist(SignalBackgroundServiceManager.whatsAppLabel).path
        ))

        // The same home directory and the same launchd, with the channel turned
        // off — which is exactly what the Settings picker produces.
        let off = SignalServiceConfiguration(
            account: on.configuration.account,
            signalCLI: on.configuration.signalCLI,
            bridge: on.configuration.bridge,
            sage: on.configuration.sage,
            provider: on.configuration.provider,
            model: on.configuration.model,
            socketPath: on.configuration.socketPath,
            channels: .signalOnly,
            whatsApp: nil
        )
        try await on.manager.enable(off)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: on.plist(SignalBackgroundServiceManager.whatsAppLabel).path),
            "the plist survived, so the helper comes back at the next login"
        )
        let stillLoaded = await on.launchd.isLoaded(SignalBackgroundServiceManager.whatsAppLabel)
        XCTAssertFalse(stillLoaded, "launchd is still running a WhatsApp bridge the owner turned off")
    }

    /// A reconcile that already matches must change nothing. Every caller —
    /// launch, the phone-link sheet, the model picker — reaches `enable`, and
    /// each unnecessary restart drops the socket the daemon is holding for as
    /// long as it takes signal-cli to come back.
    func testAsecondReconcileWithNothingChangedRestartsNothing() async throws {
        let f = try fixture(withWhatsApp: true)
        defer { try? FileManager.default.removeItem(at: f.scratch) }

        try await f.manager.enable(f.configuration)
        await f.launchd.forgetCalls()
        try await f.manager.enable(f.configuration)

        let bootouts = await f.launchd.bootouts
        let bootstraps = await f.launchd.bootstraps
        XCTAssertEqual(bootouts, 0, "an idempotent reconcile stopped the owner's helpers")
        XCTAssertEqual(bootstraps, 0)
    }

    /// **The check that would otherwise have been asked about two of three
    /// jobs.** With the WhatsApp helper refusing to come up, `enable` must fail
    /// loudly rather than report the installed build running — otherwise the
    /// owner has WhatsApp switched on, no error anywhere, and an app that never
    /// tries again.
    func testAWhatsAppHelperThatWillNotStartIsNotReportedAsRunning() async throws {
        let f = try fixture(withWhatsApp: true)
        defer { try? FileManager.default.removeItem(at: f.scratch) }

        await f.launchd.refuseToStartWhatsApp()

        do {
            try await f.manager.enable(f.configuration)
            XCTFail("a WhatsApp helper that never started was reported as a finished reconcile")
        } catch {
            // The expected shape. What matters is that it threw at all.
        }
    }

    /// Turning WhatsApp off while its job is somehow still loaded must not read
    /// as reconciled either — the `nil` side of the same question.
    func testAStrayHelperMeansTheWorldIsNotReconciled() async throws {
        let f = try fixture(withWhatsApp: true)
        defer { try? FileManager.default.removeItem(at: f.scratch) }
        try await f.manager.enable(f.configuration)

        let off = SignalServiceConfiguration(
            account: f.configuration.account,
            signalCLI: f.configuration.signalCLI,
            bridge: f.configuration.bridge,
            sage: f.configuration.sage,
            provider: f.configuration.provider,
            model: f.configuration.model,
            socketPath: f.configuration.socketPath,
            channels: .signalOnly,
            whatsApp: nil
        )
        try await f.manager.enable(off)
        await f.launchd.forgetCalls()

        // Somebody loads it again — a leftover plist bootstrapped at login, or a
        // hand-run launchctl. The next reconcile has to notice.
        await f.launchd.loadStrayWhatsApp()
        try await f.manager.enable(off)

        let stillLoaded = await f.launchd.isLoaded(SignalBackgroundServiceManager.whatsAppLabel)
        XCTAssertFalse(stillLoaded, "a stray WhatsApp helper survived a reconcile that should have removed it")
    }

    /// **A second WhatsApp number changes no executable at all.**
    ///
    /// `bridge.js` is byte-identical, so the build-stamp check correctly answers
    /// "yes, launchd is running what is installed". The configuration is what
    /// moved, and only a comparison of the plists can see it. Without one, the
    /// reconcile declares itself finished and the number the owner just added
    /// never reaches the bridge — WhatsApp keeps ignoring them, with nothing in
    /// the app or the log to say why.
    ///
    /// Which comparison catches it is not what this asserts, and that is
    /// deliberate: today it is the daemon's plist, because that job repeats
    /// `--whatsapp-allow`. This pins the behaviour the owner can observe, so it
    /// keeps working if the flags are rearranged.
    func testAddingANumberRestartsTheHelperEvenThoughTheBridgeIsUnchanged() async throws {
        let f = try fixture(withWhatsApp: true)
        defer { try? FileManager.default.removeItem(at: f.scratch) }
        try await f.manager.enable(f.configuration)
        await f.launchd.forgetCalls()

        let whatsApp = try XCTUnwrap(f.configuration.whatsApp)
        let widened = SignalServiceConfiguration(
            account: f.configuration.account,
            signalCLI: f.configuration.signalCLI,
            bridge: f.configuration.bridge,
            sage: f.configuration.sage,
            provider: f.configuration.provider,
            model: f.configuration.model,
            socketPath: f.configuration.socketPath,
            channels: .both,
            whatsApp: WhatsAppServiceConfiguration(
                node: whatsApp.node,
                bridge: whatsApp.bridge,      // the same file, byte for byte
                numbers: whatsApp.numbers + ["6598765432"],
                port: whatsApp.port,
                socketPath: whatsApp.socketPath
            )
        )
        try await f.manager.enable(widened)

        let bootstraps = await f.launchd.bootstraps
        XCTAssertGreaterThan(bootstraps, 0, "a changed allowlist restarted nothing")

        let written = try XCTUnwrap(
            NSDictionary(contentsOfFile: f.plist(SignalBackgroundServiceManager.whatsAppLabel).path)
        )
        let environment = try XCTUnwrap(written["EnvironmentVariables"] as? [String: String])
        XCTAssertEqual(
            environment["WHATSAPP_ALLOWED_USERS"], "60123821767,6598765432",
            "the second number never reached the bridge"
        )
    }

    /// `disable` named two labels before this release. The third has to go too.
    func testDisableRemovesTheWhatsAppHelperAsWell() async throws {
        let f = try fixture(withWhatsApp: true)
        defer { try? FileManager.default.removeItem(at: f.scratch) }
        try await f.manager.enable(f.configuration)

        await f.manager.disable(because: "the owner turned answering off")

        for label in SignalBackgroundServiceManager.managedLabels {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: f.plist(label).path),
                "\(label).plist survived disable, so it loads again at the next login"
            )
            let loaded = await f.launchd.isLoaded(label)
            XCTAssertFalse(loaded, "\(label) is still running after the owner turned answering off")
        }
    }

    /// The session and the spool hold the credential that lets this Mac send as
    /// the owner, and their message text. `bridge.js` would create them under
    /// launchd's umask, which is how `bridge.log` arrived `0644` with his phone
    /// number in it.
    func testTheWhatsAppStateDirectoriesAreOwnerOnly() async throws {
        let f = try fixture(withWhatsApp: true)
        defer { try? FileManager.default.removeItem(at: f.scratch) }

        try await f.manager.enable(f.configuration)

        let state = f.scratch
            .appendingPathComponent("Library/Application Support/SAGE Voice Bridge", isDirectory: true)
            .appendingPathComponent("WhatsApp", isDirectory: true)
        for path in [state, state.appendingPathComponent("session"), state.appendingPathComponent("spool")] {
            let mode = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(mode, 0o700, "\(path.lastPathComponent) is readable by every account on this Mac")
        }
    }
}
#endif  // os(macOS)
