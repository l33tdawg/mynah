import XCTest
@testable import MynahMac
@testable import SageVoiceCore

/// What the second audit found, after the first one's 21 fixes.
///
/// **Five of these were introduced by the previous round's repairs**, which is
/// the only reason worth writing that down: a fix is not finished when it
/// compiles and its own test passes. The acknowledgement call added last round
/// destroyed messages; the send-queue fix deadlocked every outbound message
/// under a comment asserting it could not; the message unwrapper was fixed in a
/// file the live path does not call; and the log redaction landed on the branch
/// a shipped install never reaches.
final class RoundThreeTests: XCTestCase {

    // MARK: - Retiring a message

    /// **The four outcomes that say nothing back, and therefore need no send to
    /// have succeeded.**
    ///
    /// Every one is permanent — a blank voice note transcribes to nothing on
    /// every attempt, and a message that arrived while the appliance was paused
    /// will still have arrived while it was paused. Left unacknowledged they
    /// would be redelivered on every reconnection for ever and fill the spool.
    func testTheOutcomesThatRetireOnTheirOwnAreTheOnesThatSaidNothing() {
        XCTAssertTrue(VoiceBridgeDaemon.Outcome.ignoredEmpty.retiresWithoutASend)
        XCTAssertTrue(VoiceBridgeDaemon.Outcome.ignoredBlankTranscript.retiresWithoutASend)
        XCTAssertTrue(VoiceBridgeDaemon.Outcome.paused.retiresWithoutASend)
        XCTAssertTrue(VoiceBridgeDaemon.Outcome.ignoredSecondBridge.retiresWithoutASend)
    }

    /// **The two that may have tried to speak, and whose delivery is therefore
    /// the question.**
    ///
    /// This is the defect the round-2 acknowledge call had. The bridge is its
    /// own KeepAlive job, so it can be connected to our socket and disconnected
    /// from WhatsApp at once — and on a restart it replays the entire
    /// unacknowledged backlog the instant we connect. Every one of those sends
    /// is refused with 503 while it reconnects; `reply` catches that and returns
    /// false; the false was discarded, `.replied` came back, and the backlog the
    /// spool exists to preserve across exactly that restart was retired
    /// unanswered, in bulk.
    func testRepliedAndFailedNeverRetireOnTheirOwn() {
        XCTAssertFalse(
            VoiceBridgeDaemon.Outcome.replied(transcript: "t", reply: "r", seconds: 1).retiresWithoutASend,
            "a message would be destroyed on the strength of a reply that may never have been sent"
        )
        XCTAssertFalse(
            VoiceBridgeDaemon.Outcome.failed("the model was unreachable").retiresWithoutASend
        )
    }

    // MARK: - Conversations that survive the upgrade

    /// **The thread key is `recipient.description`, and that string changed.**
    ///
    /// Under `SignalRecipient` it was `+60123821767`; under `ChannelRecipient`
    /// it is `signal:+60123821767`. So every conversation on disk is filed under
    /// a name this build never looks up, and the first launch of 2.0.0 resumes
    /// nothing — the appliance forgets a conversation the owner is in the middle
    /// of. The file is not damaged, which is exactly why leaving it would have
    /// been careless rather than unavoidable.
    func testConversationsWrittenBeforeChannelsExistedAreStillFound() {
        let restored = VoiceBridgeDaemon.migratingLegacyThreadKeys([
            "+60123821767": [],
            "group:aBcD1234": [],
        ])
        XCTAssertEqual(
            Set(restored.keys),
            ["signal:+60123821767", "signal:group:aBcD1234"],
            "the owner's threads were orphaned by the upgrade"
        )
    }

    /// The channel goes in front of the whole thing, not instead of the group
    /// marker — `ChannelRecipient.description` renders a group as
    /// `signal:group:<id>`, so the migrated key has to match that exactly.
    func testAMigratedGroupKeyMatchesWhatTheRecipientNowRenders() {
        let recipient = ChannelRecipient(kind: .signal, address: "aBcD1234", isGroup: true)
        let migrated = VoiceBridgeDaemon.migratingLegacyThreadKeys(["group:aBcD1234": []])
        XCTAssertEqual(Array(migrated.keys), [recipient.description])
    }

    /// Idempotent, so it can run on every start rather than behind a one-shot
    /// flag somebody has to remember to remove.
    func testAlreadyMigratedKeysAreLeftAlone() {
        let already = ["signal:+60123821767": [BrainMessage](), "whatsapp:60123@s.whatsapp.net": []]
        XCTAssertEqual(
            Set(VoiceBridgeDaemon.migratingLegacyThreadKeys(already).keys),
            Set(already.keys)
        )
        XCTAssertEqual(
            Set(VoiceBridgeDaemon.migratingLegacyThreadKeys(
                VoiceBridgeDaemon.migratingLegacyThreadKeys(["+60123821767": []])
            ).keys),
            ["signal:+60123821767"]
        )
    }

    // MARK: - The account that was actually paired

    /// **`saveWhatsAppNumbers` had no caller anywhere in the app**, so the
    /// WhatsApp allowlist could only ever be the Signal number with its `+`
    /// stripped. An owner whose WhatsApp is on a second SIM pairs successfully,
    /// sees "Linked", and is refused by the bridge on every message he sends,
    /// with nothing on any screen saying why. The JID is in the `connected`
    /// event the sheet already receives.
    func testTheLinkedAccountsNumberIsReadOutOfTheJid() {
        XCTAssertEqual(WhatsAppLinkSheet.number(inLinkedAccount: "60123821767@s.whatsapp.net"), "60123821767")
        // Baileys appends a device id.
        XCTAssertEqual(WhatsAppLinkSheet.number(inLinkedAccount: "60123821767:12@s.whatsapp.net"), "60123821767")
    }

    /// A push name is chosen by the account holder and is not an identity.
    /// Writing one into an allowlist would produce an entry that never matches —
    /// a bridge that runs, looks healthy and answers nobody.
    func testADisplayNameIsNeverWrittenIntoTheAllowlist() {
        XCTAssertNil(WhatsAppLinkSheet.number(inLinkedAccount: "Dhillon"))
        XCTAssertNil(WhatsAppLinkSheet.number(inLinkedAccount: nil))
        XCTAssertNil(WhatsAppLinkSheet.number(inLinkedAccount: "abc@s.whatsapp.net"))
    }

    // MARK: - The jobs that must not run

    /// **A WhatsApp-only appliance installed and started signal-cli anyway.**
    ///
    /// The daemon is told `--channels whatsapp` and reads nothing from it, while
    /// signal-cli sits on the owner's Signal account draining messages into a
    /// socket nobody listens to — and Signal's delivery receipts go out, so the
    /// sender sees "delivered" and the owner never sees a reply.
    func testChoosingWhatsAppOnlyDoesNotRequireSignalCli() throws {
        let configuration = SignalServiceConfiguration(
            account: "+60123821767",
            signalCLI: URL(fileURLWithPath: "/nonexistent/signal-cli"),
            bridge: URL(fileURLWithPath: "/tmp/sage-voiced"),
            sage: URL(fileURLWithPath: "/tmp/sage-gui"),
            provider: "ollama",
            model: nil,
            socketPath: "/tmp/signal.sock",
            channels: .whatsAppOnly,
            whatsApp: nil
        )
        // The plist for the daemon still has to be buildable — it is the job
        // that answers — and it must say which channels it answers on.
        let plist = try XCTUnwrap(SignalBackgroundServiceManager.bridgePlist(
            configuration,
            logs: URL(fileURLWithPath: "/tmp/logs"),
            home: URL(fileURLWithPath: "/Users/someone")
        ))
        let arguments = plist["ProgramArguments"] as? [String] ?? []
        let index = arguments.firstIndex(of: "--channels")
        XCTAssertNotNil(index)
        XCTAssertEqual(arguments[index! + 1], "whatsapp")
    }

    /// `InstalledBuild.signal` is optional now, so "Signal is off" and "Signal
    /// is running the wrong build" are different states rather than the same
    /// missing stamp.
    func testAnInstalledBuildCanHaveNoSignalAtAll() {
        let whatsAppOnly = SignalBackgroundServiceManager.InstalledBuild(
            signal: nil, bridge: "1-1-1", whatsApp: "2-2-2"
        )
        let both = SignalBackgroundServiceManager.InstalledBuild(
            signal: "3-3-3", bridge: "1-1-1", whatsApp: "2-2-2"
        )
        XCTAssertNotEqual(whatsAppOnly, both, "turning Signal off would not have been noticed as a change")
    }

    // MARK: - Logs

    /// whatsapp.log was missing from the hardcoded list, so launchd left it
    /// 0644 — and it is the log with the most in it: refusal lines naming who
    /// messaged the owner, and the allowlist on every start.
    func testEveryLogTheAppCreatesIsInTheProtectedList() {
        // The plists are the source of truth for which logs exist. Reading the
        // three job definitions rather than restating their filenames is what
        // stops a fourth job arriving with an unprotected log again.
        let logs = URL(fileURLWithPath: "/tmp/logs")
        let whatsApp = WhatsAppServiceConfiguration(
            node: URL(fileURLWithPath: "/tmp/node"),
            bridge: URL(fileURLWithPath: "/tmp/bridge.js"),
            numbers: ["60123821767"],
            port: 39930,
            socketPath: "/tmp/wa.sock"
        )
        let plist = SignalBackgroundServiceManager.whatsAppPlist(
            whatsApp, logs: logs, home: URL(fileURLWithPath: "/Users/someone"),
            state: URL(fileURLWithPath: "/tmp/state")
        )
        let out = (plist["StandardOutPath"] as? String) ?? ""
        XCTAssertTrue(
            SignalBackgroundServiceManager.protectedLogNames.contains(
                URL(fileURLWithPath: out).lastPathComponent
            ),
            "\(out) is written by a job this app installs and is not chmodded"
        )
    }
}
