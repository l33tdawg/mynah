import XCTest
@testable import SageVoiceCore

/// Messages the owner sent as one thought, answered as one turn.
///
/// The reported case:
///
///     "look up xyz and make me a list"
///     "oh and add abc to it as well"
///
/// Answered separately, the first turn spends up to five minutes building a list
/// without abc in it, and the second arrives to a finished list. The owner did
/// not change their mind — they finished their sentence late, which is what a
/// chat thread is for.
final class MessageCoalescerTests: XCTestCase {

    /// Built through `SignalChannel.translate` rather than as a bare
    /// `ChannelMessage`, so these tests keep exercising the seam the daemon
    /// actually reads through. Constructing the destination type directly would
    /// leave the translation itself untested by everything here.
    ///
    /// Force-unwrapped deliberately: `translate` returns nil only when there is
    /// no reply address, and `destinationNumber` is set on every message below.
    /// A nil here means the translation broke, and failing loudly at the line
    /// that built the message says so better than a nil threading through six
    /// assertions.
    private func message(_ text: String, from number: String = "+60123821767") -> ChannelMessage {
        SignalChannel.translate(SignalIncomingMessage(
            kind: .syncSent,
            sourceNumber: number,
            destinationNumber: number,
            timestamp: 0,
            text: text
        ))!
    }

    private func whatsAppMessage(_ text: String, from number: String = "60123821767") -> ChannelMessage {
        WhatsAppChannel.translate(WhatsAppIncomingMessage(
            sequence: 1,
            messageID: "wa-\(text.hashValue)",
            chatID: "\(number)@s.whatsapp.net",
            senderID: "\(number)@s.whatsapp.net",
            body: text
        ))
    }

    // MARK: Merging

    func testTheFollowUpEndsUpInTheSameTurn() {
        XCTAssertEqual(
            MessageCoalescer.merge(["look up xyz and make me a list", "oh and add abc to it as well"]),
            "look up xyz and make me a list\noh and add abc to it as well"
        )
    }

    /// Arrival order is meaning. "make a list of shops in Chiang Mai" then
    /// "actually make it Bangkok" is a correction; reversed, it is the opposite
    /// instruction.
    func testOrderIsNeverRearranged() {
        let merged = MessageCoalescer.merge(["shops in Chiang Mai", "actually make it Bangkok"])
        let chiang = merged.range(of: "Chiang Mai")
        let bangkok = merged.range(of: "Bangkok")
        XCTAssertNotNil(chiang)
        XCTAssertNotNil(bangkok)
        XCTAssertTrue(chiang!.lowerBound < bangkok!.lowerBound, "the correction was moved ahead of what it corrects")
    }

    /// Two lines rather than one run-on sentence: the second being an
    /// afterthought is information the model can use, and ". " glues them into a
    /// single confusing instruction.
    func testTheJoinKeepsThemAsSeparateUtterances() {
        XCTAssertTrue(MessageCoalescer.merge(["a", "b"]).contains("\n"))
        XCTAssertEqual(MessageCoalescer.merge(["a", "   ", "b"]), "a\nb", "blank message became a blank line")
        XCTAssertEqual(MessageCoalescer.merge([]), "")
    }

    // MARK: Who belongs together

    /// Two people writing at the same moment are two conversations. Merging them
    /// would put one owner's words inside the other's turn — the same isolation
    /// the per-thread history already keeps.
    func testDifferentThreadsAreNeverMerged() {
        let batch = [message("first", from: "+60123821767")]
        XCTAssertFalse(
            MessageCoalescer.belongsTogether(batch: batch, next: message("second", from: "+15550000000"))
        )
        XCTAssertTrue(
            MessageCoalescer.belongsTogether(batch: batch, next: message("second"))
        )
    }

    /// **The same person on two channels is two threads.**
    ///
    /// A WhatsApp message arriving while the owner is mid-sentence on Signal
    /// must not be merged into that turn: the single answer would go back on
    /// whichever channel came first, and he would watch one of the two
    /// conversations go silent.
    ///
    /// **Asserted with the same address on both, deliberately.** In the wild the
    /// two are `+60123821767` and `60123821767@s.whatsapp.net`, which differ as
    /// strings — so a comparison that ignored the channel entirely would still
    /// separate them, and a test built only from realistic values would pass
    /// against the bug. That difference is an accident of how two other
    /// companies write addresses, not something this code controls, and
    /// `ChannelRecipient` claims the channel is what keeps them apart. This
    /// makes the claim the thing being tested.
    func testTheSamePersonOnTwoChannelsIsNotOneTurn() {
        func addressed(_ kind: ChannelKind, _ address: String) -> ChannelMessage {
            ChannelMessage(
                kind: kind,
                recipient: ChannelRecipient(kind: kind, address: address),
                id: "\(kind)-\(address)"
            )
        }
        XCTAssertFalse(
            MessageCoalescer.belongsTogether(
                batch: [addressed(.signal, "60123821767")],
                next: addressed(.whatsapp, "60123821767")
            ),
            "one address on two channels was merged into a single turn"
        )
        XCTAssertTrue(
            MessageCoalescer.belongsTogether(
                batch: [addressed(.whatsapp, "60123821767")],
                next: addressed(.whatsapp, "60123821767")
            ),
            "two messages in one WhatsApp thread stopped being one turn"
        )
        // And the shapes that actually arrive, so the realistic case is covered
        // too rather than only the constructed one.
        XCTAssertFalse(
            MessageCoalescer.belongsTogether(
                batch: [message("look up xyz", from: "+60123821767")],
                next: whatsAppMessage("and abc", from: "60123821767")
            )
        )
    }

    func testABurstStopsBeingOneTurnEventually() {
        let batch = (0..<MessageCoalescer.maximumMerged).map { message("m\($0)") }
        XCTAssertFalse(
            MessageCoalescer.belongsTogether(batch: batch, next: message("one too many")),
            "an unbounded burst becomes one unbounded prompt"
        )
    }

    // MARK: The inbox

    func testMessagesArrivingTogetherComeOutAsOneBatch() async {
        let inbox = MessageInbox()
        await inbox.append(message("look up xyz and make me a list"))
        await inbox.append(message("oh and add abc to it as well"))

        let batch = await inbox.takeBatch(quietWindow: .milliseconds(20))

        XCTAssertEqual(batch.count, 2)
        XCTAssertEqual(
            MessageCoalescer.merge(batch.compactMap(\.text)),
            "look up xyz and make me a list\noh and add abc to it as well"
        )
    }

    /// The window restarts on each arrival, so "and one more thing" does not
    /// tail off into its own turn just because it was third.
    func testTheWindowRestartsWhileTheOwnerIsStillTyping() async {
        let inbox = MessageInbox()
        await inbox.append(message("look up xyz"))

        // Generous margins, because this asserts an ordering and a shared CI
        // runner cannot promise a schedule.
        //
        // It was 60ms gaps against a 120ms window — a ratio that holds on an
        // idle machine and not on a loaded one, where a sleep overshooting by
        // 60ms closes the window before the third message and the test reports
        // a coalescing bug that is not there. Each gap is now well under half
        // the window, so the property under test survives a slow scheduler
        // while still failing if the window genuinely stops restarting.
        Task {
            try? await Task.sleep(for: .milliseconds(80))
            await inbox.append(message("oh and abc"))
            try? await Task.sleep(for: .milliseconds(80))
            await inbox.append(message("and def"))
        }

        let batch = await inbox.takeBatch(quietWindow: .milliseconds(400))
        XCTAssertEqual(batch.count, 3, "a late third message started its own turn")
    }

    /// A single message must not pay for a follow-up that never comes beyond one
    /// window. This is the common case and the one that would make the appliance
    /// feel slower for nothing.
    func testALoneMessageWaitsOnlyOneWindow() async {
        let inbox = MessageInbox()
        await inbox.append(message("morning mate"))

        let started = ContinuousClock.now
        let batch = await inbox.takeBatch(quietWindow: .milliseconds(50))
        let elapsed = ContinuousClock.now - started

        XCTAssertEqual(batch.count, 1)
        XCTAssertLessThan(elapsed, .milliseconds(400), "a lone message waited through more than one window")
    }

    /// Another thread's message is left queued rather than dropped or swallowed
    /// into someone else's turn.
    func testAnotherThreadsMessageSurvivesToItsOwnTurn() async {
        let inbox = MessageInbox()
        await inbox.append(message("mine", from: "+60123821767"))
        await inbox.append(message("theirs", from: "+15550000000"))

        let first = await inbox.takeBatch(quietWindow: .milliseconds(20))
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first.first?.text, "mine")

        let second = await inbox.takeBatch(quietWindow: .milliseconds(20))
        XCTAssertEqual(second.first?.text, "theirs", "the other thread's message was dropped")
    }

    func testWaitingReturnsWhenTheStreamCloses() async {
        let inbox = MessageInbox()
        Task {
            try? await Task.sleep(for: .milliseconds(30))
            await inbox.close()
        }
        await inbox.waitForArrival()
        let closed = await inbox.isClosed
        XCTAssertTrue(closed, "the answering loop would spin forever after the stream ended")
    }

    /// The window is a typing pause, not a thinking pause, and it is paid on
    /// every turn — so it has to stay small against the thing it protects.
    func testTheWindowIsSmallAgainstATurn() {
        XCTAssertLessThanOrEqual(MessageCoalescer.defaultQuietWindow, .seconds(3))
        XCTAssertGreaterThanOrEqual(MessageCoalescer.defaultQuietWindow, .seconds(1))
    }

    /// A second thread typing steadily kept restarting the first thread's quiet
    /// window: measured at 1.86s for a one-message batch that should have left
    /// after one window. On Note-to-Self that is the owner delaying themselves.
    func testAChattySecondThreadDoesNotDelayTheFirst() async {
        let inbox = MessageInbox()
        await inbox.append(message("look up xyz", from: "+60123821767"))

        let noise = Task {
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(20))
                if Task.isCancelled { return }
                await inbox.append(message("noise", from: "+15550000000"))
            }
        }

        let started = ContinuousClock.now
        let batch = await inbox.takeBatch(quietWindow: .milliseconds(60))
        let waited = ContinuousClock.now - started
        noise.cancel()

        XCTAssertEqual(batch.count, 1)
        XCTAssertLessThan(waited, .milliseconds(300), "another thread's traffic held this batch open")
    }
}
