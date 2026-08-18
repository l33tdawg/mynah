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

/// The five defects found after 2.0.0-beta.1 was installed and used.
///
/// **Four of these were open when the beta shipped and one was found by reading
/// its logs**, which is the distinction worth keeping: the LID thread key was
/// not a hypothesis, it was sitting in the owner's `conversations.json` as
/// `whatsapp:161228928336031@lid` twenty minutes after the first real exchange.
/// The other four were named in the second audit, judged non-blocking, and left
/// — so this file is also the record that "not blocking" was not "not real".
final class RoundFourTests: XCTestCase {

    // MARK: - The address a reply goes to, and the name a conversation is filed under

    /// **WhatsApp addressed the owner's own chat as `161228928336031@lid`.**
    ///
    /// Verified on the live install: `lid-mapping-161228928336031_reverse.json`
    /// in the session directory contains `60123821767`, so the two names are one
    /// chat and only the bridge can say so. Keyed on the address form, the day
    /// WhatsApp switches back to the phone JID the appliance starts a second
    /// conversation and forgets the first mid-sentence.
    func testTheConversationIsFiledUnderTheIdentityAndNotTheAddressItArrivedOn() {
        let recipient = ChannelRecipient(
            kind: .whatsapp,
            address: "161228928336031@lid",
            identity: "60123821767@s.whatsapp.net"
        )
        XCTAssertEqual(recipient.description, "whatsapp:60123821767@s.whatsapp.net")
        XCTAssertEqual(recipient.addressDescription, "whatsapp:161228928336031@lid")
    }

    /// The half that would break sending if it were "resolve it and use that
    /// everywhere". The first working exchange went out over the LID.
    func testTheReplyStillGoesToTheAddressItArrivedOn() {
        let recipient = ChannelRecipient(
            kind: .whatsapp,
            address: "161228928336031@lid",
            identity: "60123821767@s.whatsapp.net"
        )
        XCTAssertEqual(recipient.address, "161228928336031@lid")
    }

    /// Signal has one name for a chat, so nothing here may change for it.
    func testAnIdentityThatSaysNothingNewIsNotStored() {
        let signal = ChannelRecipient(kind: .signal, address: "+60123821767")
        XCTAssertNil(signal.identity)
        XCTAssertEqual(signal.description, "signal:+60123821767")
        XCTAssertEqual(signal.description, signal.addressDescription)

        // The bridge sends `chatIdentity` for every chat, including one whose
        // address was already stable. Storing it would make `description` and
        // `addressDescription` differ for no reason and send the migration
        // looking for a conversation that never existed.
        let same = ChannelRecipient(kind: .whatsapp, address: "60123@s.whatsapp.net",
                                    identity: "60123@s.whatsapp.net")
        XCTAssertNil(same.identity)
        XCTAssertEqual(same.description, same.addressDescription)
    }

    /// A group is `whatsapp:group:<id>`, and the channel goes in front of the
    /// whole thing — the same rule the Signal migration had to match.
    func testAGroupKeepsItsMarkerUnderBothNames() {
        let recipient = ChannelRecipient(
            kind: .whatsapp, address: "1203630@g.us", identity: "1203630@g.us", isGroup: true
        )
        XCTAssertEqual(recipient.description, "whatsapp:group:1203630@g.us")
        XCTAssertEqual(recipient.addressDescription, "whatsapp:group:1203630@g.us")
    }

    // MARK: - Carrying the conversation across a rename nobody scheduled

    /// **The owner's history as it exists on disk right now.**
    ///
    /// Written by 2.0.0-beta.1 under the LID, because that build had no other
    /// name for the chat. The next message arrives with both names, and this is
    /// the moment — the only moment — at which the two can be joined.
    func testAConversationFiledUnderTheOldAddressIsCarriedAcross() {
        var histories: [String: [BrainMessage]] = [
            "whatsapp:161228928336031@lid": [
                BrainMessage(role: .user, content: "Are you there?"),
                BrainMessage(role: .assistant, content: "Yes, I'm here."),
            ]
        ]
        let recipient = ChannelRecipient(
            kind: .whatsapp,
            address: "161228928336031@lid",
            identity: "60123821767@s.whatsapp.net"
        )

        XCTAssertTrue(VoiceBridgeDaemon.adoptingEarlierAddressForm(
            of: recipient, in: &histories, keepingLastTurns: 40
        ))
        XCTAssertEqual(
            Array(histories.keys), ["whatsapp:60123821767@s.whatsapp.net"],
            "the owner's WhatsApp history was orphaned rather than carried across"
        )
        XCTAssertEqual(histories["whatsapp:60123821767@s.whatsapp.net"]?.count, 2)
    }

    /// **Both keys can hold turns, and the order is the assertion.**
    ///
    /// A chat addressed by number before WhatsApp moved it to a LID has history
    /// under both. The address-form key stops being written the moment this
    /// ships, so its turns are the older ones — appending them would tell the
    /// model the oldest exchange was the most recent thing said.
    func testTheOlderTurnsGoFirstWhenBothNamesHoldHistory() {
        var histories: [String: [BrainMessage]] = [
            "whatsapp:161228928336031@lid": [BrainMessage(role: .user, content: "older")],
            "whatsapp:60123821767@s.whatsapp.net": [BrainMessage(role: .user, content: "newer")],
        ]
        let recipient = ChannelRecipient(
            kind: .whatsapp,
            address: "161228928336031@lid",
            identity: "60123821767@s.whatsapp.net"
        )
        XCTAssertTrue(VoiceBridgeDaemon.adoptingEarlierAddressForm(
            of: recipient, in: &histories, keepingLastTurns: 40
        ))

        let merged = histories["whatsapp:60123821767@s.whatsapp.net"] ?? []
        XCTAssertEqual(merged.map(\.content), ["older", "newer"])
        XCTAssertNil(histories["whatsapp:161228928336031@lid"], "the old key was left behind to grow")
    }

    /// Runs on every message, so it has to cost nothing and change nothing when
    /// there is nothing to do. This is the case that is true for every message
    /// after the first.
    func testNothingMovesWhenTheChatHasOnlyEverHadOneName() {
        var histories: [String: [BrainMessage]] = [
            "signal:+60123821767": [BrainMessage(role: .user, content: "hello")]
        ]
        let before = histories
        XCTAssertFalse(VoiceBridgeDaemon.adoptingEarlierAddressForm(
            of: ChannelRecipient(kind: .signal, address: "+60123821767"),
            in: &histories,
            keepingLastTurns: 40
        ))
        XCTAssertEqual(histories.mapValues(\.count), before.mapValues(\.count))
    }

    /// An empty conversation under the old name is not worth reporting as a
    /// migration — and reporting it would put a line in the log on every
    /// message once a chat has been renamed and emptied by trimming.
    func testAnEmptyOldConversationIsNotAnnouncedAsCarriedAcross() {
        var histories: [String: [BrainMessage]] = ["whatsapp:161228928336031@lid": []]
        XCTAssertFalse(VoiceBridgeDaemon.adoptingEarlierAddressForm(
            of: ChannelRecipient(kind: .whatsapp, address: "161228928336031@lid",
                                 identity: "60123821767@s.whatsapp.net"),
            in: &histories,
            keepingLastTurns: 40
        ))
    }

    /// A bridge that predates `chatIdentity` — an update in progress — must
    /// behave exactly as 2.0.0-beta.1 did rather than guess.
    func testAnOlderBridgeThatSendsNoIdentityBehavesAsBefore() {
        let message = WhatsAppIncomingMessage(
            sequence: 1, messageID: "m", chatID: "161228928336031@lid",
            senderID: "60123821767@s.whatsapp.net"
        )
        XCTAssertNil(message.chatIdentity)
        let translated = WhatsAppChannel.translate(message)
        XCTAssertNil(translated.recipient.identity)
        XCTAssertEqual(translated.recipient.description, "whatsapp:161228928336031@lid")
    }

    /// End to end from the wire: the bridge's `chatIdentity` reaches the key.
    func testTheBridgesResolvedIdentityReachesTheConversationKey() throws {
        let line = Data("""
        {"seq":7,"epoch":"abc123","event":{"messageId":"m1","chatId":"161228928336031@lid",\
        "chatIdentity":"60123821767@s.whatsapp.net","senderId":"60123821767@s.whatsapp.net",\
        "body":"Are you there?","timestamp":1786110217}}
        """.utf8)
        let decoded = try XCTUnwrap(WhatsAppClient.decode(line))
        XCTAssertEqual(decoded.chatIdentity, "60123821767@s.whatsapp.net")
        XCTAssertEqual(decoded.chatID, "161228928336031@lid")

        let message = WhatsAppChannel.translate(decoded)
        XCTAssertEqual(message.recipient.description, "whatsapp:60123821767@s.whatsapp.net")
        XCTAssertEqual(message.recipient.address, "161228928336031@lid", "the reply would go nowhere")
    }

    // MARK: - A spool that started counting again

    /// **The wedge, and it is permanent.**
    ///
    /// The watermark is at 57. The spool directory is moved aside — which is
    /// what `event_spool.js`'s own `readAck` failure tells the owner to do — and
    /// the bridge restarts numbering from 1. Every `deliver` and `settle` then
    /// fails the `> watermark` guard, the watermark never moves again, nothing
    /// is ever acknowledged, and the spool fills to 10,000 and refuses inbound
    /// WhatsApp for good.
    func testTheWatermarkRecoversWhenTheSpoolStartsCountingAgain() {
        var ledger = WhatsAppAcknowledgementLedger()
        ledger.deliver(56, epoch: "first")
        ledger.deliver(57, epoch: "first")
        ledger.settle(56, epoch: "first")
        ledger.settle(57, epoch: "first")
        XCTAssertEqual(ledger.watermark, 57)

        // A different spool, saying so.
        ledger.deliver(1, epoch: "second")
        ledger.settle(1, epoch: "second")

        XCTAssertEqual(
            ledger.watermark, 1,
            "the watermark is stranded above every sequence the new spool will ever emit"
        )
        XCTAssertEqual(ledger.rebaselines, 1)
    }

    /// **A recreation whose first arrival is a message the allowlist refuses.**
    ///
    /// `WhatsAppClient` settles directly — without ever delivering — for a
    /// message a stranger sent or one that will not parse. Until 2.0.0-beta.7
    /// the epoch guard in `settle` fired whenever the epochs merely *differed*,
    /// so a settle carrying a spool we had never seen was dropped before
    /// `observe` could look at it, and the ledger went on holding a numbering
    /// that named nothing.
    ///
    /// What that costs is not one message: nothing is acknowledged, the spool
    /// never compacts, and it fills to its bound and refuses inbound WhatsApp
    /// for good — reached whenever the first thing to arrive after a recreation
    /// came from somebody not on the allowlist, which on a phone is most of the
    /// time.
    func testASpoolRecreatedUnderARefusedMessageIsStillNoticed() {
        var ledger = WhatsAppAcknowledgementLedger()
        ledger.deliver(56, epoch: "first")
        ledger.settle(56, epoch: "first")
        XCTAssertEqual(ledger.watermark, 56)

        // A stranger messages first after the spool is recreated: settled, never
        // delivered.
        ledger.settle(1, epoch: "second")

        XCTAssertEqual(ledger.rebaselines, 1, "the recreation went unnoticed")
        XCTAssertEqual(
            ledger.watermark, 0,
            "the watermark is still stranded above everything the new spool will emit"
        )

        // And the next real message baselines it properly.
        ledger.deliver(2, epoch: "second")
        ledger.settle(2, epoch: "second")
        XCTAssertEqual(ledger.watermark, 2)
    }

    /// **The sequence is still dropped, only the epoch is taken.** A settle
    /// names a message in a numbering we have no baseline for; letting it set
    /// one is the loss this type exists to prevent, and adopting the epoch does
    /// not change that.
    func testARefusedMessageFromANewSpoolDoesNotSetTheBaseline() {
        var ledger = WhatsAppAcknowledgementLedger()
        ledger.deliver(56, epoch: "first")
        ledger.settle(56, epoch: "first")

        ledger.settle(900, epoch: "second")

        XCTAssertEqual(
            ledger.watermark, 0,
            "a settle from an unseen spool baselined the watermark at its own sequence"
        )
    }

    /// **And a stale one is still dropped, which is the half that already
    /// worked.** A turn in flight when the spool was recreated comes back
    /// carrying the dead numbering, long after `deliver` adopted the new one.
    /// Re-baselining on that would undo a healthy ledger and re-answer whatever
    /// the new spool had already handled.
    func testALateSettleFromTheSpoolWeLeftIsStillIgnored() {
        var ledger = WhatsAppAcknowledgementLedger()
        ledger.deliver(56, epoch: "first")
        ledger.settle(56, epoch: "first")
        ledger.deliver(1, epoch: "second")
        ledger.settle(1, epoch: "second")
        XCTAssertEqual(ledger.watermark, 1)
        XCTAssertEqual(ledger.rebaselines, 1)

        // The turn that was in flight across the recreation finally answers.
        ledger.settle(57, epoch: "first")

        XCTAssertEqual(ledger.rebaselines, 1, "a spool we had already left was adopted again")
        XCTAssertEqual(ledger.watermark, 1, "the healthy watermark was reset by a dead spool")
    }

    /// **The inference that was rejected, pinned so nobody adds it back.**
    ///
    /// A sequence below the watermark is the ORDINARY shape of a replay after an
    /// acknowledgement failed to land: the bridge replays everything above its
    /// own mark, and its mark is behind ours precisely when our last ack did not
    /// arrive. Re-baselining on "below the watermark" would re-answer messages
    /// already dealt with every time the socket dropped at the wrong moment.
    func testAnOrdinaryReplayBelowTheWatermarkDoesNotRebaseline() {
        var ledger = WhatsAppAcknowledgementLedger()
        for sequence in 1...5 {
            ledger.deliver(sequence, epoch: "same")
            ledger.settle(sequence, epoch: "same")
        }
        XCTAssertEqual(ledger.watermark, 5)

        // The bridge never got our ack and replays 3, 4, 5.
        for sequence in 3...5 { ledger.deliver(sequence, epoch: "same") }

        XCTAssertEqual(ledger.watermark, 5, "already-answered messages were about to be answered again")
        XCTAssertEqual(ledger.rebaselines, 0)
        XCTAssertNil(ledger.blocking)
    }

    /// **A turn in flight when the spool is recreated.**
    ///
    /// A minute is an ordinary turn. Settled against the new baseline, sequence
    /// 40 of the dead spool would be parked in `settled` and then walked over as
    /// the new spool closed the gap beneath it — acknowledging a message of the
    /// new spool that had not arrived. The third route into the loss this type
    /// exists to prevent.
    func testAnAnswerFromTheOldSpoolCannotRetireAMessageOfTheNewOne() {
        var ledger = WhatsAppAcknowledgementLedger()
        ledger.deliver(40, epoch: "first")          // the owner asks something long

        // The spool is recreated while that turn is still running, and the new
        // one starts at 1. Three messages arrive and two are answered.
        for sequence in 1...3 { ledger.deliver(sequence, epoch: "second") }
        ledger.settle(1, epoch: "second")
        ledger.settle(2, epoch: "second")
        XCTAssertEqual(ledger.watermark, 2)
        XCTAssertEqual(ledger.blocking, 3, "message 3 is still being answered")

        // Now the long turn finishes and settles a sequence from the dead spool.
        ledger.settle(40, epoch: "first")

        // Accepted, it re-baselines onto the dead spool's numbering and walks
        // the watermark to 40 — so `{"ack":40}` goes to a spool whose highest
        // sequence is 3. That is refused and latched permanently by
        // `event_spool.js`, the spool never compacts, it fills to 10,000, and
        // inbound WhatsApp stops. Message 3, still unanswered, is dropped from
        // `outstanding` on the way.
        XCTAssertEqual(
            ledger.watermark, 2,
            "the watermark ran past every sequence the live spool has ever written"
        )
        XCTAssertEqual(
            ledger.blocking, 3,
            "a message still being answered stopped holding the watermark down"
        )
    }

    /// A bridge that sends no epoch is 2.0.0-beta.1's bridge, and it must behave
    /// exactly as it did — one nameless epoch, baseline once.
    func testABridgeWithNoEpochBehavesExactlyAsBefore() {
        var ledger = WhatsAppAcknowledgementLedger()
        ledger.deliver(4312)
        ledger.settle(4312)
        XCTAssertEqual(ledger.watermark, 4312, "the first sequence seen is the baseline")
        XCTAssertEqual(ledger.rebaselines, 0)
        XCTAssertNil(ledger.epoch)
    }

    /// The first epoch ever seen is not a re-baseline — there is nothing to
    /// re-baseline from. Getting this wrong would reset on the first message of
    /// every run, which looks identical to working.
    func testTheFirstEpochIsAdoptedRatherThanTreatedAsAChange() {
        var ledger = WhatsAppAcknowledgementLedger()
        ledger.deliver(4312, epoch: "first")
        XCTAssertEqual(ledger.watermark, 4311)
        XCTAssertEqual(ledger.rebaselines, 0)
        XCTAssertEqual(ledger.epoch, "first")
    }

    /// The epoch has to survive the unreadable-line path too: that line is
    /// settled by sequence alone, and settling it against the wrong epoch is the
    /// same mistake as settling a readable one against the wrong epoch.
    func testTheEpochIsReadableFromALineWhoseEventIsNot() {
        let broken = Data(#"{"seq":9,"epoch":"abc123","event":"not an object"}"#.utf8)
        XCTAssertNil(WhatsAppClient.decode(broken))
        XCTAssertEqual(WhatsAppClient.sequence(of: broken), 9)
        XCTAssertEqual(WhatsAppClient.spoolEpoch(of: broken), "abc123")
    }

    // MARK: - What Settings says about WhatsApp

    /// A WhatsApp session directory that is not there.
    ///
    /// **Named at every `availability` call below, deliberately.** The allowlist
    /// falls back to the session on disk so that an install whose pairing never
    /// recorded a number repairs itself — and the default path is the real one,
    /// so a test that omits this reads the developer's own paired account.
    /// `testABuildWithNoNumberYetIsNotReportedAsABuildWithoutWhatsApp` did
    /// exactly that and turned red on the Mac that has WhatsApp linked.
    private var neverPaired: URL {
        URL(fileURLWithPath: "/nonexistent/mynah-whatsapp-session")
    }

    /// **Two unrelated failures shared one sentence, and the wrong one won.**
    ///
    /// `inside(...)` returns nil both for a build with no vendored Node and for
    /// a build that is fine but has no number to allowlist. Settings said "This
    /// build of Mynah can only do Signal" for both — false twice over for the
    /// second, and the first screen a WhatsApp-only owner sees.
    func testABuildWithNoNumberYetIsNotReportedAsABuildWithoutWhatsApp() throws {
        let bundle = try temporaryBundle(withVendoredNode: true)
        defer { try? FileManager.default.removeItem(at: bundle) }
        let defaults = try emptyDefaults()

        switch WhatsAppServiceConfiguration.availability(
            bundle, signalAccount: nil, defaults: defaults.suite, pairedSession: neverPaired
        ) {
        case .noNumberToAllow: break
        case .ready: XCTFail("a bridge was configured with nobody on its allowlist")
        case .notInThisBuild: XCTFail("the build has Node and bridge.js and was called incapable")
        }
    }

    func testABuildWithoutTheVendoredNodeIsStillReportedAsSuch() throws {
        let bundle = try temporaryBundle(withVendoredNode: false)
        defer { try? FileManager.default.removeItem(at: bundle) }
        let defaults = try emptyDefaults()
        ChannelSelectionStore.saveWhatsAppNumbers(["60123821767"], to: defaults.suite)

        switch WhatsAppServiceConfiguration.availability(
            bundle, signalAccount: "+60123821767", defaults: defaults.suite, pairedSession: neverPaired
        ) {
        case .notInThisBuild: break
        default: XCTFail("a build with no interpreter was reported as able to run WhatsApp")
        }
    }

    func testABuildWithBothIsReady() throws {
        let bundle = try temporaryBundle(withVendoredNode: true)
        defer { try? FileManager.default.removeItem(at: bundle) }
        let defaults = try emptyDefaults()

        switch WhatsAppServiceConfiguration.availability(
            bundle, signalAccount: "+60123821767", defaults: defaults.suite, pairedSession: neverPaired
        ) {
        case .ready(let configuration):
            XCTAssertEqual(configuration.numbers, ["60123821767"])
        default:
            XCTFail("a build that can run WhatsApp was refused")
        }
    }

    /// The sentence itself. All three are reachable here and only one is
    /// reachable through the model, which is how the wrong one shipped.
    @MainActor
    func testTheOwnerWithNoNumberIsNotToldTheirBuildIsTheProblem() {
        let noNumber = SettingsModel.channelChoiceDetail(for: .noNumberToAllow)
        XCTAssertFalse(
            noNumber.contains("can only do Signal"),
            "an owner whose build does WhatsApp was told it does not: \(noNumber)"
        )
        // Every dead end names the next action, and this one's next action must
        // not be "link Signal" — that is the thing they chose this build to
        // avoid. Pairing writes the number itself.
        XCTAssertTrue(noNumber.contains("Link WhatsApp"), noNumber)

        let noBuild = SettingsModel.channelChoiceDetail(for: .notInThisBuild)
        XCTAssertTrue(noBuild.contains("can only do Signal"), noBuild)
        XCTAssertNotEqual(noNumber, noBuild, "two different problems still say the same thing")
    }

    // MARK: - A failure the owner can act on

    /// **The latch, and the owner it stranded.**
    ///
    /// One transient launchctl failure and every later attempt returns early —
    /// including the owner switching to Both and pressing Link WhatsApp. The
    /// setting saves, nothing starts, and the only account of it is a line in
    /// `mynah.log`. The throw that names the next action is below the guard, so
    /// they never see it.
    func testAFailedStartIsNotRetriedByTheAppOnItsOwn() async throws {
        let f = try servicesFixture()
        defer { try? FileManager.default.removeItem(at: f.scratch) }

        await f.launchd.refuseToStart()
        await XCTAssertThrowsErrorAsync(try await f.manager.enable(f.configuration))

        await f.launchd.forgetCalls()
        // The app reconciling by itself — a model change, a window opening.
        try await f.manager.enable(f.configuration)
        let bootstraps = await f.launchd.bootstraps
        XCTAssertEqual(bootstraps, 0, "the churn the latch exists to prevent came back")
    }

    /// The fix: the owner asking is a different event, and it gets one honest
    /// attempt. A failure they can see beats a silence they cannot.
    func testTheOwnerAskingDirectlyGetsAnotherAttempt() async throws {
        let f = try servicesFixture()
        defer { try? FileManager.default.removeItem(at: f.scratch) }

        await f.launchd.refuseToStart()
        await XCTAssertThrowsErrorAsync(try await f.manager.enable(f.configuration))

        await f.launchd.forgetCalls()
        await XCTAssertThrowsErrorAsync(
            try await f.manager.enable(f.configuration, retryingAfterFailure: true)
        )
        let bootstraps = await f.launchd.bootstraps
        XCTAssertGreaterThan(
            bootstraps, 0,
            "the owner pressed the button and nothing was even attempted"
        )
    }

    /// And when the transient cause has cleared, the retry actually works —
    /// which is the whole reason the latch was wrong to be permanent.
    func testARetryAfterTheCauseClearsInstallsTheBuild() async throws {
        let f = try servicesFixture()
        defer { try? FileManager.default.removeItem(at: f.scratch) }

        await f.launchd.refuseToStart()
        await XCTAssertThrowsErrorAsync(try await f.manager.enable(f.configuration))

        await f.launchd.allowStarts()
        try await f.manager.enable(f.configuration, retryingAfterFailure: true)
        let running = await f.launchd.isLoaded(SignalBackgroundServiceManager.bridgeLabel)
        XCTAssertTrue(running, "the appliance never came back without a quit and reopen")
    }

    // MARK: - Fixtures

    private struct ServicesFixture {
        let scratch: URL
        let configuration: SignalServiceConfiguration
        let launchd: FakeLaunchd
        let manager: SignalBackgroundServiceManager
    }

    private func servicesFixture() throws -> ServicesFixture {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("mynah-round4-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        func executable(_ name: String) throws -> URL {
            let url = scratch.appendingPathComponent(name)
            try Data(name.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url
        }

        let launchd = FakeLaunchd()
        return ServicesFixture(
            scratch: scratch,
            configuration: SignalServiceConfiguration(
                account: "+60123821767",
                signalCLI: try executable("signal-cli"),
                bridge: try executable("sage-voiced"),
                sage: try executable("sage-gui"),
                provider: "ollama",
                model: nil,
                socketPath: scratch.appendingPathComponent("daemon.socket").path,
                channels: .signalOnly,
                whatsApp: nil
            ),
            launchd: launchd,
            manager: SignalBackgroundServiceManager(
                runner: launchd, homeDirectory: scratch, userID: 501
            )
        )
    }

    /// A directory shaped like `Mynah.app/Contents`, with or without the
    /// vendored interpreter. Built rather than mocked because
    /// `availability` asks the filesystem, and a fake that answered for it would
    /// be testing the fake.
    private func temporaryBundle(withVendoredNode: Bool) throws -> URL {
        let contents = FileManager.default.temporaryDirectory
            .appendingPathComponent("mynah-bundle-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
        let whatsApp = contents.appendingPathComponent("Resources/whatsapp", isDirectory: true)
        try FileManager.default.createDirectory(at: whatsApp, withIntermediateDirectories: true)
        try Data("// bridge".utf8).write(to: whatsApp.appendingPathComponent("bridge.js"))

        if withVendoredNode {
            let bin = contents.appendingPathComponent("Resources/node/bin", isDirectory: true)
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let node = bin.appendingPathComponent("node")
            try Data("#!/bin/sh\n".utf8).write(to: node)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: node.path)
        }
        return contents
    }

    private struct Defaults {
        let suite: UserDefaults
        let name: String
    }

    private func emptyDefaults() throws -> Defaults {
        let name = "mynah.tests.round4.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { suite.removePersistentDomain(forName: name) }
        return Defaults(suite: suite, name: name)
    }
}

/// `XCTAssertThrowsError` has no async form on this toolchain.
func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> some Any,
    _ message: String = "expected an error and none was thrown",
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail(message, file: file, line: line)
    } catch {
        // Expected.
    }
}
#endif  // os(macOS)
