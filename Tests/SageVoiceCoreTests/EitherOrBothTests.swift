import XCTest
@testable import MynahMac
@testable import SageVoiceCore

/// **"its either or both" — the owner, 8 August 2026, reporting 2.0.0-beta.3.**
///
/// Link WhatsApp, do not link Signal, and Mynah said it could not reach your
/// phone and answered no WhatsApp message. Everything in `enable` and everything
/// in the daemon was already channel-aware; one Signal-shaped guard at the top of
/// `SignalServiceConfiguration.current()` was in front of all of it, and returning
/// `nil` from there means `cannotTell`, which by design does nothing at all. No
/// LaunchAgent, no error, no screen saying why.
///
/// **The reason no test caught it is worth stating, because it is the same reason
/// twice in this file's history.** `current()` read `SignalTooling.linkedNumber()`
/// and `SignalTooling.helper()` directly — the real accounts.json and the real
/// PATH — so on any Mac with Signal linked, which is every Mac anybody develops
/// this on, the WhatsApp-only branch was unreachable from a test. The seams are
/// now parameters with production defaults.
final class EitherOrBothTests: XCTestCase {

    // MARK: - Fixtures

    private var scratch: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("mynah-either-or-both-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        suite = "mynah.tests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        BrainSelectionStore.save(.fixtureBrain, defaults: defaults)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: scratch)
    }

    /// A bundle that carries the vendored bridge, which is what
    /// `WhatsAppServiceConfiguration.availability` actually looks for: an
    /// executable interpreter and a bridge.js beside it.
    private func bundleCarryingWhatsApp() throws -> URL {
        let bundle = scratch.appendingPathComponent("Mynah.app", isDirectory: true)
        let resources = bundle.appendingPathComponent("Contents/Resources", isDirectory: true)
        let nodeBin = resources.appendingPathComponent("node/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: nodeBin, withIntermediateDirectories: true)
        let node = nodeBin.appendingPathComponent("node")
        try Data("#!/bin/sh\n".utf8).write(to: node)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: node.path)

        let whatsapp = resources.appendingPathComponent("whatsapp", isDirectory: true)
        try FileManager.default.createDirectory(at: whatsapp, withIntermediateDirectories: true)
        try Data("// bridge".utf8).write(to: whatsapp.appendingPathComponent("bridge.js"))
        return bundle
    }

    /// A bundle with no vendored Node — every build before 2.0, and the state
    /// `.notInThisBuild` exists for.
    private func bundleWithoutWhatsApp() throws -> URL {
        let bundle = scratch.appendingPathComponent("Plain.app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("Contents/MacOS", isDirectory: true),
            withIntermediateDirectories: true
        )
        return bundle
    }

    private func executable(_ name: String) throws -> URL {
        let url = scratch.appendingPathComponent(name)
        try Data(name.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    // MARK: - The configuration a WhatsApp-only Mac has to produce

    /// The reported bug, at the line it starts on.
    func testAMacWithNoSignalStillGetsAnAppliance() throws {
        ChannelSelectionStore.save(.whatsAppOnly, to: defaults)
        ChannelSelectionStore.saveWhatsAppNumbers(["60123821767"], to: defaults)

        let configuration = SignalServiceConfiguration.current(
            appBundle: try bundleCarryingWhatsApp(),
            defaults: defaults,
            linkedNumber: { nil },
            signalCLI: { nil }
        )

        let made = try XCTUnwrap(
            configuration,
            "a Mac set up for WhatsApp alone produced no configuration, so nothing was installed"
        )
        XCTAssertEqual(made.channels, .whatsAppOnly)
        XCTAssertNil(made.account, "there is no Signal account on this Mac to name")
        XCTAssertNil(made.signalCLI)
        XCTAssertEqual(made.whatsApp?.numbers, ["60123821767"])
    }

    /// `--allow` is the one flag the daemon refuses to start without, and it
    /// names the *person*, not the Signal account. A WhatsApp-only appliance has
    /// the first and not the second.
    func testTheOwnerIsNamedByTheirWhatsAppNumberWhenThereIsNoSignalAccount() throws {
        ChannelSelectionStore.save(.whatsAppOnly, to: defaults)
        ChannelSelectionStore.saveWhatsAppNumbers(["60123821767"], to: defaults)

        let made = try XCTUnwrap(SignalServiceConfiguration.current(
            appBundle: try bundleCarryingWhatsApp(),
            defaults: defaults,
            linkedNumber: { nil },
            signalCLI: { nil }
        ))
        XCTAssertEqual(made.ownerNumber, "+60123821767")
    }

    /// **One channel of two is not none.** The owner chose Both and has only got
    /// as far as scanning the WhatsApp code; running nothing until they link
    /// Signal too is the same dead end one channel over.
    func testChoosingBothWithOnlyWhatsAppLinkedRunsWhatsApp() throws {
        ChannelSelectionStore.save(.both, to: defaults)
        ChannelSelectionStore.saveWhatsAppNumbers(["60123821767"], to: defaults)

        let made = try XCTUnwrap(SignalServiceConfiguration.current(
            appBundle: try bundleCarryingWhatsApp(),
            defaults: defaults,
            linkedNumber: { nil },
            signalCLI: { nil }
        ))
        XCTAssertEqual(
            made.channels, .whatsAppOnly,
            "the daemon would be told to open a Signal channel with no account behind it"
        )
    }

    /// The mirror, and the one that must not regress: Signal alone still
    /// produces exactly what every shipped install already has.
    func testASignalOnlyMacIsUnchanged() throws {
        ChannelSelectionStore.save(.signalOnly, to: defaults)
        let cli = try executable("signal-cli")

        let made = try XCTUnwrap(SignalServiceConfiguration.current(
            appBundle: try bundleWithoutWhatsApp(),
            defaults: defaults,
            linkedNumber: { "+60123821767" },
            signalCLI: { cli }
        ))
        XCTAssertEqual(made.channels, .signalOnly)
        XCTAssertEqual(made.account, "+60123821767")
        XCTAssertEqual(made.signalCLI, cli)
        XCTAssertNil(made.whatsApp)
        XCTAssertEqual(made.ownerNumber, "+60123821767")
    }

    /// **`nil` still has to mean "I could not tell".** Widening this must not
    /// turn a half-finished setup into a decision — `cannotTell` is what stops a
    /// momentary unreadable file uninstalling the owner's phone bridge, and that
    /// has happened.
    func testNothingRunnableIsStillAnUnansweredQuestion() throws {
        ChannelSelectionStore.save(.signalOnly, to: defaults)

        XCTAssertNil(
            SignalServiceConfiguration.current(
                appBundle: try bundleCarryingWhatsApp(),
                defaults: defaults,
                linkedNumber: { nil },
                signalCLI: { nil }
            ),
            "an appliance with no runnable channel is not a configuration"
        )
    }

    /// A build with no vendored Node cannot run WhatsApp however the picker is
    /// set, and saying otherwise would install a job launchd retries for ever.
    func testAWhatsAppChoiceOnABuildWithoutTheBridgeRunsNothing() throws {
        ChannelSelectionStore.save(.whatsAppOnly, to: defaults)
        ChannelSelectionStore.saveWhatsAppNumbers(["60123821767"], to: defaults)

        XCTAssertNil(SignalServiceConfiguration.current(
            appBundle: try bundleWithoutWhatsApp(),
            defaults: defaults,
            linkedNumber: { nil },
            signalCLI: { nil }
        ))
    }

    /// Pairing writes the number — `WhatsAppLinkSheet.number(inLinkedAccount:)` —
    /// and without one the bridge refuses every message it is sent. Installing it
    /// anyway is a helper that runs, looks healthy and answers nobody.
    func testWhatsAppWithNoNumberYetIsNotRunnable() throws {
        ChannelSelectionStore.save(.whatsAppOnly, to: defaults)

        XCTAssertNil(SignalServiceConfiguration.current(
            appBundle: try bundleCarryingWhatsApp(),
            defaults: defaults,
            linkedNumber: { nil },
            signalCLI: { nil }
        ))
    }

    // MARK: - What the daemon is started with

    private func whatsAppOnlyConfiguration() throws -> SignalServiceConfiguration {
        SignalServiceConfiguration(
            account: nil,
            signalCLI: nil,
            bridge: try executable("sage-voiced"),
            sage: try executable("sage-gui"),
            provider: "ollama",
            model: nil,
            socketPath: scratch.appendingPathComponent("daemon.socket").path,
            channels: .whatsAppOnly,
            whatsApp: WhatsAppServiceConfiguration(
                node: try executable("node"),
                bridge: try executable("bridge.js"),
                numbers: ["60123821767"],
                port: 39930,
                socketPath: scratch.appendingPathComponent("wa.sock").path
            )
        )
    }

    func testTheDaemonIsToldWhoToAnswerAndNotToldASignalAccount() throws {
        let plist = try XCTUnwrap(SignalBackgroundServiceManager.bridgePlist(
            try whatsAppOnlyConfiguration(),
            logs: scratch,
            home: scratch
        ))
        let arguments = try XCTUnwrap(plist["ProgramArguments"] as? [String])

        let allow = try XCTUnwrap(arguments.firstIndex(of: "--allow"))
        XCTAssertEqual(arguments[allow + 1], "+60123821767")
        XCTAssertFalse(
            arguments.contains("--account"),
            "SignalClient would be told to serve an account signal-cli has never heard of"
        )
        let channels = try XCTUnwrap(arguments.firstIndex(of: "--channels"))
        XCTAssertEqual(arguments[channels + 1], "whatsapp")
    }

    func testThereIsNoSignalJobToWriteWithoutASignalAccount() throws {
        XCTAssertNil(
            SignalBackgroundServiceManager.signalPlist(
                try whatsAppOnlyConfiguration(),
                logs: scratch,
                home: scratch
            ),
            "a signal-cli job would be written with no account and no binary"
        )
    }

    /// The end of the chain the owner reported: launchd holding the two jobs a
    /// WhatsApp appliance needs, and not the one it does not.
    func testAWhatsAppOnlyApplianceInstallsTwoJobsAndNoSignalOne() async throws {
        let launchd = FakeLaunchd()
        let manager = SignalBackgroundServiceManager(
            runner: launchd,
            homeDirectory: scratch,
            userID: 501
        )
        try await manager.enable(try whatsAppOnlyConfiguration())

        let agents = scratch.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        func installed(_ label: String) -> Bool {
            FileManager.default.fileExists(
                atPath: agents.appendingPathComponent("\(label).plist").path
            )
        }
        XCTAssertTrue(
            installed(SignalBackgroundServiceManager.bridgeLabel),
            "nothing would answer a WhatsApp message"
        )
        XCTAssertTrue(installed(SignalBackgroundServiceManager.whatsAppLabel))
        XCTAssertFalse(
            installed(SignalBackgroundServiceManager.signalLabel),
            "signal-cli would be started on a Mac with no Signal account"
        )
        let bootstraps = await launchd.bootstraps
        XCTAssertEqual(bootstraps, 2)
    }

    /// A configuration naming nobody is refused with a sentence, rather than
    /// installed as a job launchd retries every thirty seconds for ever.
    func testAnApplianceWithNobodyToAnswerIsRefusedOutLoud() async throws {
        let configuration = SignalServiceConfiguration(
            account: nil,
            signalCLI: nil,
            bridge: try executable("sage-voiced"),
            sage: try executable("sage-gui"),
            provider: "ollama",
            model: nil,
            socketPath: scratch.appendingPathComponent("daemon.socket").path,
            channels: .whatsAppOnly,
            whatsApp: nil
        )
        let manager = SignalBackgroundServiceManager(
            runner: FakeLaunchd(),
            homeDirectory: scratch,
            userID: 501
        )
        do {
            try await manager.enable(configuration)
            XCTFail("an appliance with no owner was installed")
        } catch {
            // Every dead end needs a door: the message has to name the next
            // action, not just the problem.
            let said = error.localizedDescription
            XCTAssertTrue(
                said.contains("Link Signal or WhatsApp"),
                "the owner is told what is wrong and nothing to do about it: \(said)"
            )
        }
    }

    // MARK: - What the window says about it

    private func status(
        channels: ChannelSelection,
        signalUp: Bool = false,
        signalLinked: Bool = false,
        whatsAppUp: Bool = false,
        whatsAppLinked: Bool = false
    ) -> PhoneStatus {
        PhoneStatus(
            isReachable: signalUp,
            linkedNumber: signalLinked ? "+6012·····89" : nil,
            socketPath: "/tmp/signal.sock",
            whatsAppIsReachable: whatsAppUp,
            whatsAppIsLinked: whatsAppLinked,
            channels: channels
        )
    }

    /// The sentence the owner actually saw.
    func testAWorkingWhatsAppApplianceIsNotReportedAsUnreachable() {
        let phone = status(
            channels: .whatsAppOnly,
            whatsAppUp: true,
            whatsAppLinked: true
        )
        XCTAssertEqual(phone.reachabilityLabel(helper: .running), "Connected")
        XCTAssertTrue(phone.isReachableOnEveryChosenChannel)
        XCTAssertTrue(
            phone.reachabilityDetail(helper: .running).contains("WhatsApp"),
            "the row names a channel this Mac does not use"
        )
    }

    /// "Link your phone above first" pointed at a Signal row that a WhatsApp
    /// owner does not have, to fix a channel they did not choose.
    func testAnUnpairedWhatsAppIsNamedRatherThanBlamedOnSignal() {
        let detail = status(channels: .whatsAppOnly).reachabilityDetail(helper: .absent)
        XCTAssertTrue(detail.contains("WhatsApp"), detail)
        XCTAssertFalse(detail.contains("Signal"), detail)
    }

    /// Both chosen, one answering. "Connected" hides a dead channel and "Not
    /// connected" hides a live one; the row says which.
    func testOneChannelUpOfTwoIsNamedRatherThanRoundedOff() {
        let phone = status(
            channels: .both,
            signalUp: true,
            signalLinked: true,
            whatsAppLinked: true
        )
        XCTAssertEqual(phone.reachabilityLabel(helper: .running), "Signal only")
        XCTAssertFalse(
            phone.isReachableOnEveryChosenChannel,
            "the pill would be green over a WhatsApp bridge that is down"
        )
    }

    /// Signal's four states are unchanged — this row has been read by owners
    /// since 1.0 and the widening must not have moved it.
    func testTheSignalOnlyReadingIsUnchanged() {
        XCTAssertEqual(
            status(channels: .signalOnly, signalUp: true, signalLinked: true)
                .reachabilityLabel(helper: .running),
            "Connected"
        )
        XCTAssertEqual(
            status(channels: .signalOnly, signalLinked: true).reachabilityLabel(helper: .running),
            "Starting"
        )
        XCTAssertEqual(
            status(channels: .signalOnly, signalLinked: true).reachabilityLabel(helper: .absent),
            "Not connected"
        )
        XCTAssertEqual(
            status(channels: .signalOnly).reachabilityLabel(helper: .running),
            "Not connected",
            "an unlinked account is not a helper that is still starting"
        )
        XCTAssertTrue(
            status(channels: .signalOnly).reachabilityDetail(helper: .absent).contains("link"),
            "a new owner is told what is wrong and not what to do"
        )
    }

    /// A `PhoneStatus` built without the two new fields still reads as the
    /// Signal-only appliance every existing install is, which is what makes the
    /// default safe.
    func testTheDefaultReadingIsSignalOnly() {
        let old = PhoneStatus(isReachable: true, linkedNumber: "+6012·····89", socketPath: "/tmp/s")
        XCTAssertEqual(old.channels, .signalOnly)
        XCTAssertEqual(old.reachabilityLabel(helper: .running), "Connected")
    }
}

private extension BrainSetupOption {
    static let fixtureBrain = BrainSetupOption(
        id: .anthropicAPIKey,
        label: "Anthropic API key",
        summary: "Test",
        requirement: .apiKey,
        keepsWordsOnDevice: false,
        availability: .available,
        tier: .typedAPIKey,
        backendIdentifier: "anthropic",
        modelName: "claude-sonnet-4-5"
    )
}
