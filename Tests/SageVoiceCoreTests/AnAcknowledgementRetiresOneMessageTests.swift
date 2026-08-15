import XCTest
@testable import SageVoiceCore

/// The rule the whole durable WhatsApp path rests on: acknowledging one message
/// must never retire another.
///
/// **These are regressions.** An audit found that `WhatsAppClient` sent the
/// bridge a cumulative watermark the instant any single message finished, so a
/// stranger's message being refused in microseconds retired the owner's message
/// that was still being answered. Fifteen tests over this transport passed
/// while that was live, because reaching the acknowledgement path needed a live
/// socket and none of them had one.
///
/// So two halves here. The ledger, exhaustively, because it is now a plain
/// value and can be. And the client's own receive path, because the ledger
/// being right is worth nothing if the client stops using it.
final class AnAcknowledgementRetiresOneMessageTests: XCTestCase {

    // MARK: The ledger

    func testTheOwnersMessageSurvivesAStrangerBeingRefusedOverIt() {
        var ledger = WhatsAppAcknowledgementLedger()

        ledger.deliver(1)                       // the owner's, now being answered
        ledger.settle(2)                        // a stranger's, refused instantly

        XCTAssertEqual(
            ledger.watermark, 0,
            "sending {\"ack\":2} here retires the owner's message from the spool"
        )
        XCTAssertEqual(ledger.blocking, 1)

        ledger.settle(1)                        // the turn finishes
        XCTAssertEqual(ledger.watermark, 2, "now both are genuinely done, and one ack says so")
        XCTAssertNil(ledger.blocking)
    }

    func testAWholeRunOfFinishedMessagesCollapsesIntoOneWatermark() {
        // The point of the watermark: settling 2, 3, 4 and 5 above an
        // outstanding 1 must not cost four acknowledgements once 1 lands.
        var ledger = WhatsAppAcknowledgementLedger()
        for sequence in 1...5 { ledger.deliver(sequence) }
        for sequence in [5, 3, 2, 4] { ledger.settle(sequence) }

        XCTAssertEqual(ledger.watermark, 0)
        XCTAssertEqual(ledger.settledAheadCount, 4)

        ledger.settle(1)
        XCTAssertEqual(ledger.watermark, 5)
        XCTAssertEqual(ledger.settledAheadCount, 0, "nothing is held once it is expressed")
    }

    func testOrderOfCompletionDoesNotChangeTheOutcome() {
        // Same five messages, every completion order. The watermark must always
        // end at 5 and must never pass an unfinished one on the way.
        for ordering in [[1, 2, 3, 4, 5], [5, 4, 3, 2, 1], [3, 1, 5, 2, 4], [2, 4, 1, 5, 3]] {
            var ledger = WhatsAppAcknowledgementLedger()
            for sequence in 1...5 { ledger.deliver(sequence) }
            var finished: Set<Int> = []
            for sequence in ordering {
                ledger.settle(sequence)
                finished.insert(sequence)
                let unfinished = (1...5).filter { !finished.contains($0) }.min() ?? 6
                XCTAssertLessThan(
                    ledger.watermark, unfinished,
                    "order \(ordering) let the watermark pass an unfinished message"
                )
            }
            XCTAssertEqual(ledger.watermark, 5, "order \(ordering)")
        }
    }

    func testTheWatermarkStartsWhereTheBridgeIsReplayingFrom() {
        // After a restart, Mynah's memory is empty and the bridge's is not: it
        // replays from its own mark, so the first sequence seen may be 4,312.
        // Counting up from 0 would leave the watermark stuck below messages
        // nobody will ever send again — the spool fills to its limit and
        // inbound WhatsApp stops for good, which is a worse outage than the bug
        // this file is about.
        var ledger = WhatsAppAcknowledgementLedger()
        ledger.deliver(4312)
        XCTAssertEqual(ledger.watermark, 4311, "everything below was retired before we connected")

        ledger.settle(4312)
        XCTAssertEqual(ledger.watermark, 4312)
    }

    func testARepeatedAcknowledgementIsHarmless() {
        // A consumer that reconnects and settles what it already had is
        // behaving correctly. It must not move the watermark backwards or
        // resurrect anything.
        var ledger = WhatsAppAcknowledgementLedger()
        ledger.deliver(1)
        ledger.deliver(2)
        ledger.settle(1)
        ledger.settle(2)
        XCTAssertEqual(ledger.watermark, 2)

        ledger.settle(1)
        ledger.settle(2)
        ledger.deliver(1)
        XCTAssertEqual(ledger.watermark, 2)
        XCTAssertEqual(ledger.outstandingCount, 0, "a redelivery below the mark is already dealt with")
    }

    func testAReplayedMessageStillBlocksTheWatermarkUntilItIsAnswered() {
        // The bridge replays everything above its mark on every connection. A
        // message delivered twice and answered once is answered — but it must
        // still hold the watermark down while it is in flight the second time.
        var ledger = WhatsAppAcknowledgementLedger()
        ledger.deliver(7)
        ledger.deliver(8)
        ledger.deliver(7)                       // reconnect; the bridge sends it again
        XCTAssertEqual(ledger.blocking, 7)

        ledger.settle(8)
        XCTAssertEqual(ledger.watermark, 6, "8 is done, but 7 is not")
        ledger.settle(7)
        XCTAssertEqual(ledger.watermark, 8)
    }

    // MARK: The client, which is where it actually went wrong

    private func line(seq: Int, senderID: String) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "seq": seq,
            "event": [
                "messageId": "3EB0C431C26A1D9F55",
                "chatId": senderID,
                "senderId": senderID,
                "senderName": "somebody",
                "body": "did the ferry get booked",
                "hasMedia": false,
                "mediaUrls": [],
                "timestamp": 1_754_500_000,
            ],
        ])
    }

    private func client() throws -> WhatsAppClient {
        WhatsAppClient(
            configuration: .init(
                allowlist: try WhatsAppSenderAllowlist(numbers: ["60123456789"]),
                socketPath: "/nonexistent/never-connected.sock",
                logger: { _ in }
            )
        )
    }

    func testRefusingAStrangerDoesNotAcknowledgeTheOwnersMessageUnderIt() async throws {
        let client = try client()

        // Exactly the sequence the audit reproduced against a live bridge.
        await client.receive(line(seq: 1, senderID: "60123456789@s.whatsapp.net"))  // the owner
        await client.receive(line(seq: 2, senderID: "441234567890@s.whatsapp.net")) // a stranger

        var state = await client.acknowledgementState
        XCTAssertEqual(state.watermark, 0, "the owner's message is still being answered")
        XCTAssertEqual(state.blockedOn, 1)

        await client.acknowledge(sequence: 1)
        state = await client.acknowledgementState
        XCTAssertEqual(state.watermark, 2)
        XCTAssertEqual(state.outstanding, 0)
    }

    func testALineTheClientCannotReadDoesNotWedgeTheChannelForEver() async throws {
        let client = try client()

        // Unreadable events are byte-identical on every replay. Holding the
        // watermark down for one of them would fill the spool and refuse every
        // later message — losing the channel to save a line we could never have
        // read. The loss is reported; it is not silent.
        await client.receive(Data(#"{"seq":1,"event":{"no":"chatId"}}"#.utf8))
        await client.receive(line(seq: 2, senderID: "60123456789@s.whatsapp.net"))

        var state = await client.acknowledgementState
        XCTAssertEqual(state.watermark, 1)
        XCTAssertEqual(state.blockedOn, 2, "the readable one is still outstanding")

        await client.acknowledge(sequence: 2)
        state = await client.acknowledgementState
        XCTAssertEqual(state.watermark, 2)
    }

    func testALineWithNoSequenceStallsRatherThanGuessing() async throws {
        let client = try client()
        await client.receive(line(seq: 1, senderID: "60123456789@s.whatsapp.net"))
        await client.receive(Data("this is not JSON at all".utf8))
        await client.acknowledge(sequence: 1)

        // Nothing to settle and nothing invented. The watermark reflects only
        // what was genuinely accounted for.
        let state = await client.acknowledgementState
        XCTAssertEqual(state.watermark, 1)
    }
}
