import XCTest
@testable import MynahMac
@testable import SageVoiceCore

/// The owner's requirement, made checkable: *"it should follow the same flow as
/// signal - so you can choose - signal or whatsapp or both"*.
///
/// **Everything here is over a value or a plist, and that is the point.** The
/// parts of this feature that need a socket, a paired WhatsApp account and a
/// phone with a camera cannot be tested, so the design put the rules where they
/// can be: `ChannelSet` routes by a `kind` that travels with the message,
/// `ChannelSelectionStore` is a string, `WhatsAppPairing.event` is a function
/// over a line of text, and a LaunchAgent is a dictionary. The same argument
/// `WhatsAppAcknowledgementLedger` makes about being a value rather than four
/// lines inside an actor — where that bug survived fifteen passing tests.
final class SignalOrWhatsAppOrBothTests: XCTestCase {

    // MARK: - A channel that records what it was asked to do

    private final class RecordingChannel: MessageChannel, @unchecked Sendable {
        let kind: ChannelKind
        nonisolated let incomingMessages: AsyncStream<ChannelMessage>
        private let feed: AsyncStream<ChannelMessage>.Continuation

        private(set) var started = 0
        private(set) var stopped = 0
        private(set) var sent: [(ChannelReply, ChannelRecipient)] = []
        private(set) var acknowledged: [ChannelMessage] = []
        var connected = true
        var refuses = false

        init(_ kind: ChannelKind) {
            self.kind = kind
            var continuation: AsyncStream<ChannelMessage>.Continuation!
            self.incomingMessages = AsyncStream { continuation = $0 }
            self.feed = continuation
        }

        func emit(_ message: ChannelMessage) { feed.yield(message) }
        func finish() { feed.finish() }

        func start() async { started += 1 }
        func stop() async { stopped += 1 }
        var isConnected: Bool { get async { connected } }

        struct Refused: Error {}
        func send(_ reply: ChannelReply, to recipient: ChannelRecipient) async throws {
            if refuses { throw Refused() }
            sent.append((reply, recipient))
        }
        func acknowledge(_ message: ChannelMessage) async { acknowledged.append(message) }
    }

    private func message(_ kind: ChannelKind, _ text: String) -> ChannelMessage {
        ChannelMessage(
            kind: kind,
            recipient: ChannelRecipient(kind: kind, address: "60123821767"),
            id: text,
            text: text
        )
    }

    // MARK: - One inbox

    func testBothChannelsArriveOnOneStream() async {
        let signal = RecordingChannel(.signal)
        let whatsapp = RecordingChannel(.whatsapp)
        let set = ChannelSet([signal, whatsapp])

        signal.emit(message(.signal, "on signal"))
        whatsapp.emit(message(.whatsapp, "on whatsapp"))
        signal.finish()
        whatsapp.finish()

        var seen: [ChannelKind] = []
        for await message in set.incomingMessages { seen.append(message.kind) }
        XCTAssertEqual(Set(seen), [.signal, .whatsapp], "a message from one of the two channels never arrived")
    }

    /// **The failure this prevents is a stopped appliance, not a degraded one.**
    ///
    /// `VoiceBridgeDaemon.run()` returns when the merged stream ends. A merge
    /// that finished with the first channel to finish would let a WhatsApp
    /// bridge exiting — which it does on `logged_out`, by design — end the
    /// daemon's loop, and Signal would go unanswered until something restarted
    /// the process.
    func testOneChannelEndingDoesNotEndTheOther() async {
        let signal = RecordingChannel(.signal)
        let whatsapp = RecordingChannel(.whatsapp)
        let set = ChannelSet([signal, whatsapp])

        whatsapp.finish()
        signal.emit(message(.signal, "still here"))
        signal.finish()

        var texts: [String] = []
        for await message in set.incomingMessages { texts.append(message.text ?? "") }
        XCTAssertEqual(texts, ["still here"], "Signal stopped when WhatsApp did")
    }

    /// The empty selection is a real state during setup. A stream that never
    /// finishes would leave `run()` blocked for ever on something nothing writes.
    func testNoChannelsFinishesRatherThanHanging() async {
        let set = ChannelSet([])
        var count = 0
        for await _ in set.incomingMessages { count += 1 }
        XCTAssertEqual(count, 0)
        XCTAssertTrue(set.isEmpty)
    }

    // MARK: - One way out

    func testAReplyGoesToTheChannelTheQuestionCameFrom() async throws {
        let signal = RecordingChannel(.signal)
        let whatsapp = RecordingChannel(.whatsapp)
        let set = ChannelSet([signal, whatsapp])

        try await set.send(
            ChannelReply(text: "answer"),
            to: ChannelRecipient(kind: .whatsapp, address: "60123821767@s.whatsapp.net")
        )

        XCTAssertEqual(signal.sent.count, 0, "a WhatsApp reply was sent over Signal")
        XCTAssertEqual(whatsapp.sent.count, 1)
    }

    /// **The address is never inspected, and this is the test that says so.**
    ///
    /// The owner's Signal number and his WhatsApp number are the same digits.
    /// Anything that routed by looking at the string would send both of these to
    /// the same place, and half his conversation would arrive in the wrong app.
    func testTheSameAddressOnTwoChannelsGoesToTwoPlaces() async throws {
        let signal = RecordingChannel(.signal)
        let whatsapp = RecordingChannel(.whatsapp)
        let set = ChannelSet([signal, whatsapp])

        try await set.send(ChannelReply(text: "a"), to: ChannelRecipient(kind: .signal, address: "60123821767"))
        try await set.send(ChannelReply(text: "b"), to: ChannelRecipient(kind: .whatsapp, address: "60123821767"))

        XCTAssertEqual(signal.sent.map(\.0.text), ["a"])
        XCTAssertEqual(whatsapp.sent.map(\.0.text), ["b"])
    }

    func testSendingToAChannelThatIsOffSaysSoRatherThanGoingQuiet() async {
        let set = ChannelSet([RecordingChannel(.signal)])
        do {
            try await set.send(ChannelReply(text: "x"), to: ChannelRecipient(kind: .whatsapp, address: "60123821767"))
            XCTFail("a reply to a channel that is not running was accepted")
        } catch let failure as ChannelSet.Failure {
            // Every dead end names the next action. A bare "not connected" would
            // leave the owner with a reply that vanished and no idea why.
            XCTAssertTrue(
                failure.description.contains("setup"),
                "the failure does not say what to do about it: \(failure.description)"
            )
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    /// The daemon waits on this before apologising for a promise a crashed run
    /// never kept. "Is anything connected?" would have it apologise into a dead
    /// WhatsApp because Signal happened to be fine.
    func testConnectednessIsAskedOfOneChannelNotOfAny() async {
        let signal = RecordingChannel(.signal)
        let whatsapp = RecordingChannel(.whatsapp)
        signal.connected = true
        whatsapp.connected = false
        let set = ChannelSet([signal, whatsapp])

        let signalUp = await set.isConnected(.signal)
        let whatsAppUp = await set.isConnected(.whatsapp)
        let anyUp = await set.isAnyConnected()
        XCTAssertTrue(signalUp)
        XCTAssertFalse(whatsAppUp, "a dead WhatsApp reported as connected because Signal was up")
        XCTAssertTrue(anyUp)
    }

    func testAcknowledgementGoesBackToTheChannelThatHoldsTheMessage() async {
        let signal = RecordingChannel(.signal)
        let whatsapp = RecordingChannel(.whatsapp)
        let set = ChannelSet([signal, whatsapp])

        await set.acknowledge(message(.whatsapp, "one"))

        XCTAssertEqual(signal.acknowledged.count, 0)
        XCTAssertEqual(whatsapp.acknowledged.map(\.id), ["one"])
    }

    func testStartAndStopReachEveryChannel() async {
        let signal = RecordingChannel(.signal)
        let whatsapp = RecordingChannel(.whatsapp)
        let set = ChannelSet([signal, whatsapp])

        await set.start()
        await set.stop()

        XCTAssertEqual(signal.started, 1)
        XCTAssertEqual(whatsapp.started, 1)
        XCTAssertEqual(signal.stopped, 1)
        XCTAssertEqual(whatsapp.stopped, 1)
    }

    // MARK: - The choice, as a value

    func testTheChoiceParsesTheWayTheFlagIsWritten() throws {
        XCTAssertEqual(try ChannelSelection(commaSeparated: "signal"), .signalOnly)
        XCTAssertEqual(try ChannelSelection(commaSeparated: "whatsapp"), .whatsAppOnly)
        XCTAssertEqual(try ChannelSelection(commaSeparated: "signal,whatsapp"), .both)
        XCTAssertEqual(try ChannelSelection(commaSeparated: " Signal , WhatsApp "), .both)
        XCTAssertEqual(try ChannelSelection(commaSeparated: ""), .none)
    }

    func testAnUnknownChannelIsRefusedWithTheOnesThatExist() {
        XCTAssertThrowsError(try ChannelSelection(commaSeparated: "signal,telegram")) { error in
            let text = String(describing: error)
            XCTAssertTrue(text.contains("signal"), "the refusal does not list what is available: \(text)")
            XCTAssertTrue(text.contains("whatsapp"), "the refusal does not list what is available: \(text)")
        }
    }

    func testTheSummaryReadsLikeASentence() {
        XCTAssertEqual(ChannelSelection.both.summary, "Signal and WhatsApp")
        XCTAssertEqual(ChannelSelection.signalOnly.summary, "Signal")
        XCTAssertEqual(ChannelSelection.none.summary, "nothing yet")
    }

    // MARK: - What is remembered

    private func emptyDefaults(_ name: String = #function) throws -> UserDefaults {
        let suite = "mynah.tests.channels.\(name)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// **Every Mac already running Mynah has no such key.** An absent value has
    /// to mean what those installs are already doing, or the first launch of
    /// 2.0.0 takes the owner's phone bridge away and waits to be told to put it
    /// back.
    func testAnUpgradeWithNoStoredChoiceKeepsAnsweringSignal() throws {
        XCTAssertEqual(ChannelSelectionStore.current(try emptyDefaults()), .signalOnly)
    }

    func testTheStoredChoiceSurvivesARoundTrip() throws {
        let defaults = try emptyDefaults()
        ChannelSelectionStore.save(.both, to: defaults)
        XCTAssertEqual(ChannelSelectionStore.current(defaults), .both)
        ChannelSelectionStore.save(.whatsAppOnly, to: defaults)
        XCTAssertEqual(ChannelSelectionStore.current(defaults), .whatsAppOnly)
    }

    /// It is written as the same string the daemon's `--channels` flag takes, so
    /// a value stored here cannot mean something else to the process that acts
    /// on it.
    func testWhatIsStoredIsWhatTheFlagAccepts() throws {
        let defaults = try emptyDefaults()
        ChannelSelectionStore.save(.both, to: defaults)
        let raw = try XCTUnwrap(defaults.string(forKey: ChannelSelectionStore.key))
        XCTAssertEqual(try ChannelSelection(commaSeparated: raw), .both)
    }

    func testAHandEditedPreferenceLeavesTheApplianceAnswering() throws {
        let defaults = try emptyDefaults()
        defaults.set("telegram", forKey: ChannelSelectionStore.key)
        XCTAssertEqual(
            ChannelSelectionStore.current(defaults), .signalOnly,
            "a typo in a plist made Mynah unreachable"
        )
    }

    /// WhatsApp identifies people by digits. A `+` does not fail loudly — it
    /// fails as an allowlist entry that never matches, which is a bridge that
    /// runs, looks healthy and answers nobody.
    func testTheWhatsAppNumberIsDerivedFromTheSignalOneWithoutThePlus() throws {
        XCTAssertEqual(
            ChannelSelectionStore.whatsAppNumbers(try emptyDefaults(), signalAccount: "+60123821767"),
            ["60123821767"]
        )
    }

    func testANumberTypedTheWayAPersonWritesOneIsTheSameEntry() {
        XCTAssertEqual(ChannelSelectionStore.normalise(["+60 12-382 1767"]), ["60123821767"])
        XCTAssertEqual(ChannelSelectionStore.normalise(["60123821767", "+60123821767"]), ["60123821767"])
        XCTAssertEqual(ChannelSelectionStore.normalise(["", "  "]), [])
    }

    func testTheOwnersOwnListWinsOverTheDerivedOne() throws {
        let defaults = try emptyDefaults()
        ChannelSelectionStore.saveWhatsAppNumbers(["6598765432"], to: defaults)
        XCTAssertEqual(
            ChannelSelectionStore.whatsAppNumbers(defaults, signalAccount: "+60123821767"),
            ["6598765432"],
            "a second WhatsApp number could not be set"
        )
    }

    /// **`pairedSession` is passed at a path that does not exist, deliberately.**
    /// The allowlist now falls back to the WhatsApp session on disk, and the
    /// default is the real one — so left alone this read the developer's own
    /// paired account and passed or failed by whether the Mac running it had
    /// WhatsApp linked. "Nothing to derive from" has to mean nothing.
    func testWithNothingToDeriveFromThereIsNoAllowlistAtAll() throws {
        XCTAssertEqual(
            ChannelSelectionStore.whatsAppNumbers(
                try emptyDefaults(),
                signalAccount: nil,
                pairedSession: URL(fileURLWithPath: "/nonexistent/whatsapp-session")
            ),
            []
        )
    }

    // MARK: - The LaunchAgent

    private func whatsAppConfiguration() -> WhatsAppServiceConfiguration {
        WhatsAppServiceConfiguration(
            node: URL(fileURLWithPath: "/Applications/Mynah.app/Contents/Resources/node/bin/node"),
            bridge: URL(fileURLWithPath: "/Applications/Mynah.app/Contents/Resources/whatsapp/bridge.js"),
            numbers: ["60123821767"],
            port: 39930,
            socketPath: "/tmp/mynah-whatsapp.sock"
        )
    }

    private func environment(of plist: [String: Any]) throws -> [String: String] {
        try XCTUnwrap(plist["EnvironmentVariables"] as? [String: String])
    }

    func testTheWhatsAppJobCarriesTheAllowlistItRefusesEverythingWithout() throws {
        let plist = SignalBackgroundServiceManager.whatsAppPlist(
            whatsAppConfiguration(),
            logs: URL(fileURLWithPath: "/tmp/logs"),
            home: URL(fileURLWithPath: "/Users/someone"),
            state: URL(fileURLWithPath: "/tmp/state")
        )
        XCTAssertEqual(try environment(of: plist)["WHATSAPP_ALLOWED_USERS"], "60123821767")
    }

    /// **Unset, the bridge puts its upstream vendor's banner on every reply.**
    ///
    /// Mynah already marks a reply before the text reaches the bridge, so a
    /// prefix here arrives on the owner's phone underneath somebody else's
    /// branding, twice-marked. Empty is the value; this is the test that keeps
    /// it from quietly becoming absent again.
    func testTheBridgeAddsNoBrandingOfItsOwn() throws {
        let plist = SignalBackgroundServiceManager.whatsAppPlist(
            whatsAppConfiguration(),
            logs: URL(fileURLWithPath: "/tmp/logs"),
            home: URL(fileURLWithPath: "/Users/someone"),
            state: URL(fileURLWithPath: "/tmp/state")
        )
        XCTAssertEqual(
            try environment(of: plist)["WHATSAPP_REPLY_PREFIX"], "",
            "a WhatsApp reply would arrive branded as another product"
        )
    }

    /// Without `--events-socket` the bridge behaves exactly as upstream does:
    /// an in-memory queue and no spool. The flag is what turns on the durable
    /// inbound path, and a job missing it loses every message on a restart.
    func testTheWhatsAppJobTurnsOnTheDurablePath() throws {
        let plist = SignalBackgroundServiceManager.whatsAppPlist(
            whatsAppConfiguration(),
            logs: URL(fileURLWithPath: "/tmp/logs"),
            home: URL(fileURLWithPath: "/Users/someone"),
            state: URL(fileURLWithPath: "/tmp/state")
        )
        let arguments = try XCTUnwrap(plist["ProgramArguments"] as? [String])
        XCTAssertTrue(arguments.contains("--events-socket"), "the bridge would run without a spool")
        XCTAssertTrue(arguments.contains("/tmp/mynah-whatsapp.sock"))
        XCTAssertTrue(arguments.contains("--spool"))
        XCTAssertTrue(arguments.contains("/tmp/state/spool"))
        XCTAssertTrue(arguments.contains("--session"))
        XCTAssertTrue(arguments.contains("/tmp/state/session"))
    }

    private func signalConfiguration(
        channels: ChannelSelection,
        whatsApp: WhatsAppServiceConfiguration?
    ) -> SignalServiceConfiguration {
        SignalServiceConfiguration(
            account: "+60123821767",
            signalCLI: URL(fileURLWithPath: "/opt/homebrew/bin/signal-cli"),
            bridge: URL(fileURLWithPath: "/Applications/Mynah.app/Contents/MacOS/sage-voiced"),
            sage: URL(fileURLWithPath: "/Applications/SAGE.app/Contents/MacOS/sage-gui"),
            provider: "ollama",
            model: nil,
            socketPath: "/tmp/signal.sock",
            channels: channels,
            whatsApp: whatsApp
        )
    }

    /// Takes an optional because `bridgePlist` returns one: it cannot be built
    /// for a configuration that names nobody to answer. Unwrapping here rather
    /// than at every call site keeps that a single assertion.
    private func arguments(of plist: [String: Any]?) throws -> [String] {
        try XCTUnwrap(XCTUnwrap(plist)["ProgramArguments"] as? [String])
    }

    /// The daemon defaults to Signal without the flag, so omitting it would
    /// behave identically today — and leave a plist nobody can read to find out
    /// which channels the appliance is answering.
    func testTheDaemonIsToldWhichChannelsEvenWhenItIsOnlySignal() throws {
        let plist = SignalBackgroundServiceManager.bridgePlist(
            signalConfiguration(channels: .signalOnly, whatsApp: nil),
            logs: URL(fileURLWithPath: "/tmp/logs"),
            home: URL(fileURLWithPath: "/Users/someone")
        )
        let arguments = try self.arguments(of: plist)
        let index = try XCTUnwrap(arguments.firstIndex(of: "--channels"))
        XCTAssertEqual(arguments[index + 1], "signal")
    }

    func testTurningWhatsAppOnChangesWhatTheDaemonIsStartedWith() throws {
        let plist = SignalBackgroundServiceManager.bridgePlist(
            signalConfiguration(channels: .both, whatsApp: whatsAppConfiguration()),
            logs: URL(fileURLWithPath: "/tmp/logs"),
            home: URL(fileURLWithPath: "/Users/someone")
        )
        let arguments = try self.arguments(of: plist)
        let channels = try XCTUnwrap(arguments.firstIndex(of: "--channels"))
        XCTAssertEqual(arguments[channels + 1], "signal,whatsapp")
        let allow = try XCTUnwrap(arguments.firstIndex(of: "--whatsapp-allow"))
        XCTAssertEqual(arguments[allow + 1], "60123821767")
        XCTAssertTrue(arguments.contains("--whatsapp-socket"))
    }

    /// **Two plists that differ is what makes `enable` restart anything.** It
    /// compares the bytes it would write against the bytes on disk, so a channel
    /// change that produced an identical plist would be a setting the owner
    /// flipped and nothing acted on.
    func testChangingTheChannelsChangesThePlistBytes() throws {
        let signalOnly = try SignalBackgroundServiceManager.plistData(
            XCTUnwrap(SignalBackgroundServiceManager.bridgePlist(
                signalConfiguration(channels: .signalOnly, whatsApp: nil),
                logs: URL(fileURLWithPath: "/tmp/logs"),
                home: URL(fileURLWithPath: "/Users/someone")
            ))
        )
        let both = try SignalBackgroundServiceManager.plistData(
            XCTUnwrap(SignalBackgroundServiceManager.bridgePlist(
                signalConfiguration(channels: .both, whatsApp: whatsAppConfiguration()),
                logs: URL(fileURLWithPath: "/tmp/logs"),
                home: URL(fileURLWithPath: "/Users/someone")
            ))
        )
        XCTAssertNotEqual(signalOnly, both, "turning WhatsApp on would have restarted nothing")
    }

    /// `disable` named two labels and there are now three. A WhatsApp helper
    /// left loaded after the owner turns answering off is this app keeping a
    /// live connection to their account after telling them it stopped.
    func testEveryManagedJobIsOneThisAppCanRemove() {
        XCTAssertTrue(SignalBackgroundServiceManager.managedLabels.contains(SignalBackgroundServiceManager.whatsAppLabel))
        XCTAssertEqual(Set(SignalBackgroundServiceManager.managedLabels).count, 3)
    }

    func testTheThreeLabelsAreDistinct() {
        XCTAssertNotEqual(SignalBackgroundServiceManager.bridgeLabel, SignalBackgroundServiceManager.whatsAppLabel)
        XCTAssertNotEqual(SignalBackgroundServiceManager.signalLabel, SignalBackgroundServiceManager.whatsAppLabel)
    }

    // MARK: - Pairing, as a line of text

    func testTheCodeToShowIsReadOutOfWhatTheBridgeSaid() {
        XCTAssertEqual(
            WhatsAppPairing.event(from: #"{"ts":1,"event":"qr","qr":"2@abc/def"}"#),
            .qr("2@abc/def")
        )
    }

    func testPairingIsReportedAsFinishedWithWhoItLinkedTo() {
        XCTAssertEqual(
            WhatsAppPairing.event(from: #"{"event":"connected","user":{"id":"60123821767@s.whatsapp.net","name":"Dhillon"}}"#),
            .connected(user: "Dhillon", jid: "60123821767@s.whatsapp.net")
        )
    }

    /// **This assertion used to be `.connected(user: "Dhillon")`, and that is
    /// the defect written down as a test.**
    ///
    /// The JID was dropped whenever the account had a push name, and the sheet
    /// then tried to read the owner's number out of whatever single string
    /// survived. `number(inLinkedAccount:)` correctly refuses to read a number
    /// out of "Dhillon", so nothing was stored — and whether Mynah could answer
    /// WhatsApp came down to whether the owner had ever set a display name.
    ///
    /// Invisible on a Mac with Signal linked, because the allowlist falls back
    /// to the Signal number. On a WhatsApp-only Mac there is nothing to fall
    /// back to, so `current()` finds no number to allow, builds no
    /// configuration, and the appliance does not start — the same silence
    /// 2.0.0-beta.4 was cut to end, arrived at down a second road.
    func testTheNumberSurvivesAnAccountThatHasADisplayName() {
        guard case .connected(_, let jid)? = WhatsAppPairing.event(
            from: #"{"event":"connected","user":{"id":"60123821767@s.whatsapp.net","name":"Dhillon"}}"#
        ) else { return XCTFail("pairing did not report as connected") }
        XCTAssertEqual(
            WhatsAppLinkSheet.number(inLinkedAccount: jid), "60123821767",
            "the owner's number is unrecoverable, so nothing goes on the allowlist"
        )
    }

    /// The name is what the owner calls the account; with none, the JID is a
    /// fine label as well as the identity.
    func testWithNoNameTheAccountIsStillNamed() {
        XCTAssertEqual(
            WhatsAppPairing.event(from: #"{"event":"connected","user":{"id":"60123821767@s.whatsapp.net"}}"#),
            .connected(user: "60123821767@s.whatsapp.net", jid: "60123821767@s.whatsapp.net")
        )
    }

    /// Being logged out needs the session deleted before a retry can work, which
    /// is a different repair from any other failure — so it is a different case.
    func testBeingLoggedOutIsNotJustAnotherFailure() {
        XCTAssertEqual(
            WhatsAppPairing.event(from: #"{"event":"error","error":"logged_out","reason":401}"#),
            .loggedOut
        )
    }

    /// **515 is WhatsApp asking for a restart straight after a successful
    /// scan.** Treated as a failure, this would report pairing broken in the
    /// middle of it working.
    func testAReconnectDuringPairingIsNotAFailure() {
        guard case .disconnected(let reason)? = WhatsAppPairing.event(from: #"{"event":"disconnected","reason":515}"#) else {
            return XCTFail("a routine reconnect was read as something else")
        }
        XCTAssertEqual(reason, 515)
    }

    /// The bridge writes ordinary log lines to stdout as well. A banner must not
    /// be able to fail a pairing.
    func testAnythingThatIsNotAnEventIsIgnoredRatherThanFailing() {
        XCTAssertNil(WhatsAppPairing.event(from: "📱 WhatsApp pairing mode"))
        XCTAssertNil(WhatsAppPairing.event(from: ""))
        XCTAssertNil(WhatsAppPairing.event(from: "{ not json"))
        XCTAssertNil(WhatsAppPairing.event(from: #"{"ts":1}"#))
    }

    /// A new event upstream must not abandon a pairing that is going perfectly.
    func testAnUnfamiliarEventIsKeptRatherThanTreatedAsAnError() {
        XCTAssertEqual(WhatsAppPairing.event(from: #"{"event":"pairing-code"}"#), .unrecognised("pairing-code"))
    }

    func testAQrEventWithNoCodeIsAFailureRatherThanAnEmptySquare() {
        guard case .failed? = WhatsAppPairing.event(from: #"{"event":"qr","qr":""}"#) else {
            return XCTFail("an empty code would have been rendered as a square nobody can scan")
        }
    }

    /// Baileys creates the session directory before it has anything to put in
    /// it, so an abandoned pairing leaves one that looks exactly like a linked
    /// account.
    func testAnAbandonedPairingIsNotReportedAsLinked() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mynah-pairing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertFalse(WhatsAppPairing.isPaired(sessionDirectory: directory))
        try Data("{}".utf8).write(to: directory.appendingPathComponent("creds.json"))
        XCTAssertTrue(WhatsAppPairing.isPaired(sessionDirectory: directory))
    }
}

// MARK: - Linking one channel must not unlink the other

/// **The setup screen offers both, so it can add and must never replace.**
///
/// Reported against 2.0.0-beta.2: onboarding's Ready screen offered "Link my
/// phone" and nothing else, so testers linked Signal because it was the only
/// button on the screen and found WhatsApp — the whole of 2.0 — in Settings or
/// not at all. Both are offered there now.
///
/// Which creates the hazard these pin. The Ready screen has no channel picker,
/// and the stored default is Signal-only, so pairing WhatsApp there has to turn
/// the channel on or the owner scans a code, sees "Linked", and is answered by
/// nothing. The obvious way to write that is `.whatsAppOnly`, and it would
/// silently switch off the Signal somebody linked on the same screen a minute
/// earlier.
extension SignalOrWhatsAppOrBothTests {

    func testLinkingWhatsAppAfterSignalKeepsBoth() {
        XCTAssertEqual(ChannelSelection.signalOnly.adding(.whatsapp), .both)
    }

    func testLinkingSignalAfterWhatsAppKeepsBoth() {
        XCTAssertEqual(ChannelSelection.whatsAppOnly.adding(.signal), .both)
    }

    /// Idempotent, because the Ready screen cannot know whether this is a first
    /// pairing or a re-pairing and must not care.
    func testAddingAChannelAlreadyOnChangesNothing() {
        XCTAssertEqual(ChannelSelection.both.adding(.whatsapp), .both)
        XCTAssertEqual(ChannelSelection.whatsAppOnly.adding(.whatsapp), .whatsAppOnly)
    }

    /// The state a brand-new install is in before anything is linked. Pairing
    /// from setup has to produce a selection that names exactly what was paired.
    func testAddingToNothingSelectedYieldsJustThatChannel() {
        XCTAssertEqual(ChannelSelection.none.adding(.whatsapp), .whatsAppOnly)
        XCTAssertFalse(ChannelSelection.none.adding(.whatsapp).includes(.signal))
    }
}
