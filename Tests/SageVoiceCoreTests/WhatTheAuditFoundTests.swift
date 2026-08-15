import XCTest
@testable import MynahMac
@testable import SageVoiceCore

/// The defects a 43-agent audit of this branch confirmed, each pinned so it
/// cannot come back.
///
/// **Three of them were in code written the same day, by the hand that was
/// fixing the previous round.** That is the honest reason this file exists
/// rather than a line in a commit message: the acknowledgement ledger had
/// already been rewritten once to stop a watermark walking over a live message,
/// and it still did — by a second route nobody had looked for. Writing the
/// scenario down as a test is the only thing that makes "fixed" mean something
/// on the third pass.
final class WhatTheAuditFoundTests: XCTestCase {

    // MARK: - The ledger, round three

    /// **The bridge replays, and a replay lands on a sequence the ledger had
    /// already put aside.**
    ///
    /// `settle(5)` while 3 is outstanding parks 5 in `settled`. The bridge's own
    /// mark is still below 3 — it only moves when we acknowledge — so on the next
    /// reconnect it replays 5, and `deliver(5)` used to insert into `outstanding`
    /// while leaving 5 sitting in `settled`. When 3 and 4 finally settled, the
    /// contiguous run strode straight through 5 and acknowledged a message that
    /// was still being answered. Exactly the loss this type was written to end.
    func testAReplayedMessageIsNotWalkedOverWhenTheGapBelowItCloses() {
        var ledger = WhatsAppAcknowledgementLedger()
        ledger.deliver(3)
        ledger.deliver(4)
        ledger.deliver(5)
        ledger.settle(5)                    // finished early, parked
        XCTAssertEqual(ledger.watermark, 2, "the watermark moved over unfinished work")

        ledger.deliver(5)                   // the bridge replays it
        ledger.settle(3)
        ledger.settle(4)

        XCTAssertEqual(
            ledger.watermark, 4,
            "the watermark passed 5 while it was in flight, so that message was retired unread"
        )
        XCTAssertEqual(ledger.blocking, 5)

        ledger.settle(5)
        XCTAssertEqual(ledger.watermark, 5)
        XCTAssertNil(ledger.blocking)
    }

    /// A repeated acknowledgement of something already retired changes nothing.
    ///
    /// **This does not pin `settle`'s unconditional `outstanding.remove`, and
    /// saying so is the point.** The audit reported that removal as a fix for a
    /// stale `blocking` entry; with the redelivery bug above closed, the state it
    /// describes is no longer reachable, and moving that line back below the
    /// guard leaves this test green. The line stays for the reason its own
    /// comment gives. What this test actually covers is idempotence, which is
    /// worth having and is not the same claim.
    func testAnAlreadyCoveredSequenceStopsBeingReportedAsBlocking() {
        var ledger = WhatsAppAcknowledgementLedger()
        ledger.deliver(1)
        ledger.deliver(2)
        ledger.settle(1)
        ledger.settle(2)
        XCTAssertEqual(ledger.watermark, 2)

        // A late redelivery of something already covered, then its answer.
        ledger.deliver(2)
        ledger.settle(2)

        XCTAssertEqual(ledger.outstandingCount, 0, "a retired message is still counted as in flight")
        XCTAssertNil(ledger.blocking, "the stuck-acknowledgement diagnostic names a message that is done")
    }

    // MARK: - The reply that could not be sent

    /// **The Host header is not authentication, and it was the only thing in
    /// front of `POST /send`.**
    ///
    /// Any local process could send WhatsApp as the owner, read a file off this
    /// Mac into a chat via `/send-media`, or drain the inbound queue. Both ends
    /// now share a secret out of a `0600` file. This asserts the Swift half
    /// refuses to send at all when it cannot read it — rather than sending
    /// unauthenticated and being refused by the bridge, which would work today
    /// and stop working the moment somebody made the token optional.
    func testASendWithoutTheSharedSecretIsRefusedBeforeItLeaves() async {
        let channel = WhatsAppChannel(configuration: .init(
            client: WhatsAppClient(configuration: .init(
                allowlist: try! WhatsAppSenderAllowlist(numbers: ["60123821767"]),
                socketPath: "/nonexistent/never-connected.sock",
                logger: { _ in }
            )),
            tokenPath: "/nonexistent/no-such-token"
        ))
        do {
            try await channel.send(
                ChannelReply(text: "hello"),
                to: ChannelRecipient(kind: .whatsapp, address: "60123821767@s.whatsapp.net")
            )
            XCTFail("a send went out with no token")
        } catch let failure as WhatsAppChannel.Failure {
            guard case .noToken(let path) = failure else {
                return XCTFail("wrong failure: \(failure)")
            }
            XCTAssertTrue(failure.description.contains(path))
            // Every dead end names the next action.
            XCTAssertTrue(
                failure.description.contains("Settings") || failure.description.contains("log"),
                "the failure tells the owner nothing to do: \(failure.description)"
            )
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    /// The token lives with the session keys rather than in `$TMPDIR`: unlike the
    /// socket it has to survive a reboot.
    func testTheTokenSitsBesideTheSessionAndNotInTemp() {
        let path = WhatsAppChannel.defaultTokenPath(homeDirectory: URL(fileURLWithPath: "/Users/someone"))
        XCTAssertEqual(
            path,
            "/Users/someone/Library/Application Support/SAGE Voice Bridge/WhatsApp/api-token"
        )
    }

    // MARK: - What reaches a log

    /// **The person refused most often is somebody the owner knows.** This wrote
    /// their full number into `whatsapp.log` for the crime of not being on a
    /// list; Signal's equivalent path logs no identifier at all.
    func testARefusedSendersNumberIsNotWrittenOutInFull() {
        let denial = WhatsAppSenderAllowlist.Denial.senderNotAllowed("60987654321@s.whatsapp.net")
        XCTAssertFalse(
            denial.description.contains("60987654321"),
            "a third party's number reached the log: \(denial.description)"
        )
        // Redacted, not removed: enough to tell two refusals apart is the job.
        XCTAssertTrue(denial.description.contains("609"), denial.description)
    }

    func testARefusedGroupIsRedactedTheSameWay() {
        let denial = WhatsAppSenderAllowlist.Denial.groupsNotAllowed("120363012345678901@g.us")
        XCTAssertFalse(denial.description.contains("120363012345678901"), denial.description)
    }

    // MARK: - The helper's PATH

    /// **`/usr/bin:/bin` guaranteed the audio conversion failed on every Mac.**
    ///
    /// `/send-media` shells out to ffmpeg so a spoken reply arrives as a voice
    /// bubble. ffmpeg ships with neither macOS nor this app, so with that PATH
    /// the conversion could not succeed anywhere — the fallback ran every time
    /// and, until this release, mislabelled the result as `audio/mpeg`.
    func testTheWhatsAppHelperCanFindAnFfmpegTheOwnerInstalled() throws {
        let plist = SignalBackgroundServiceManager.whatsAppPlist(
            WhatsAppServiceConfiguration(
                node: URL(fileURLWithPath: "/Applications/Mynah.app/Contents/Resources/node/bin/node"),
                bridge: URL(fileURLWithPath: "/Applications/Mynah.app/Contents/Resources/whatsapp/bridge.js"),
                numbers: ["60123821767"],
                port: 39930,
                socketPath: "/tmp/wa.sock"
            ),
            logs: URL(fileURLWithPath: "/tmp/logs"),
            home: URL(fileURLWithPath: "/Users/someone"),
            state: URL(fileURLWithPath: "/tmp/state")
        )
        let environment = try XCTUnwrap(plist["EnvironmentVariables"] as? [String: String])
        let path = try XCTUnwrap(environment["PATH"])
        XCTAssertTrue(path.contains("/opt/homebrew/bin"), "PATH is \(path)")
        XCTAssertTrue(path.contains("/usr/local/bin"), "PATH is \(path)")
    }

    // MARK: - The choice the owner could not undo

    /// **A `Picker` whose selection is not among its tags shows blank.**
    ///
    /// The WhatsApp options were emitted only when this build could run
    /// WhatsApp, while the stored choice is read from disk regardless. An owner
    /// who chose Both and then moved to a build without the vendored Node got an
    /// empty, disabled control holding a value they could neither see nor
    /// change — and the one thing they would want at that moment is to put it
    /// back to Signal.
    ///
    /// Asserted over the model rather than the view: `setChannels` is what the
    /// control calls, and a disabled control is the only thing that could stop
    /// it. The disabled condition now excludes exactly this state.
    func testAStoredWhatsAppChoiceCanAlwaysBePutBackToSignal() throws {
        let suite = "mynah.tests.picker.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        ChannelSelectionStore.save(.both, to: defaults)
        XCTAssertEqual(ChannelSelectionStore.current(defaults), .both)

        ChannelSelectionStore.save(.signalOnly, to: defaults)
        XCTAssertEqual(
            ChannelSelectionStore.current(defaults), .signalOnly,
            "the owner could not get back to a channel this build can honour"
        )
    }

    /// The picker cannot express "neither", and the model refuses it anyway.
    /// An appliance nobody can message is a real state during setup and is not
    /// something Settings should be able to produce.
    @MainActor
    func testSettingsCannotTurnOffEveryChannel() throws {
        let suite = "mynah.tests.empty.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        ChannelSelectionStore.save(.signalOnly, to: defaults)

        let model = SettingsModel(defaults: defaults, backgroundServices: InertBackgroundServices())
        XCTAssertFalse(model.setChannels(.none), "Settings made the appliance unreachable")
        XCTAssertEqual(ChannelSelectionStore.current(defaults), .signalOnly)
    }
}

/// A background-services stand-in that touches nothing.
///
/// `SettingsModel` defaults to the real manager, which reaches the real
/// launchd — the hazard `SignalBackgroundServiceManager.isTestReachingTheRealMachine`
/// exists for, and which took the owner's Signal down twice on 29 July.
private struct InertBackgroundServices: SignalBackgroundServicing {
    func enable(_ configuration: SignalServiceConfiguration, retryingAfterFailure: Bool) async throws {}
    func disable(because reason: String) async {}
    func state() async -> BackgroundHelperState { .absent }
}
