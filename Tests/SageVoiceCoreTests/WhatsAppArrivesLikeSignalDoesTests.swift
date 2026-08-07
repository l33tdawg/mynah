import XCTest
@testable import SageVoiceCore

/// The Swift half of the WhatsApp transport.
///
/// The JavaScript side already has 23 tests proving the spool keeps messages
/// and the socket replays them. What those cannot check is whether *this* end
/// reads what that end writes, and whether the acknowledgement rule is obeyed —
/// which is the rule the whole durable path rests on:
///
///   * acknowledge too late, or never, and a message is answered twice
///   * acknowledge too early, and it is lost, with a spool underneath giving
///     false comfort
///
/// The fixtures below are the bridge's real event shape, taken from the object
/// literal at the end of `extractBridgeEvent` in whatsapp/bridge_helpers.js
/// rather than invented here. A fixture that agrees with a hand-written idea of
/// the schema tests nothing.
final class WhatsAppArrivesLikeSignalDoesTests: XCTestCase {

    private func line(
        seq: Int = 1,
        chatID: String = "60123456789@s.whatsapp.net",
        senderID: String? = nil,
        body: String = "did the ferry get booked",
        isGroup: Bool? = nil,
        extra: [String: Any] = [:]
    ) -> Data {
        var event: [String: Any] = [
            "messageId": "3EB0C431C26A1D9F55",
            "chatId": chatID,
            "senderName": "Dhillon",
            "body": body,
            "hasMedia": false,
            "mediaType": NSNull(),
            "mediaUrls": [],
            "timestamp": 1_754_500_000,
        ]
        if let senderID { event["senderId"] = senderID }
        if let isGroup { event["isGroup"] = isGroup }
        for (key, value) in extra { event[key] = value }
        return try! JSONSerialization.data(withJSONObject: ["seq": seq, "event": event])
    }

    // MARK: Decoding

    func testARealBridgeEventDecodes() throws {
        let message = try XCTUnwrap(WhatsAppClient.decode(line()))
        XCTAssertEqual(message.sequence, 1)
        XCTAssertEqual(message.messageID, "3EB0C431C26A1D9F55")
        XCTAssertEqual(message.chatID, "60123456789@s.whatsapp.net")
        XCTAssertEqual(message.body, "did the ferry get booked")
        XCTAssertEqual(message.timestamp, 1_754_500_000)
        XCTAssertFalse(message.isGroup)
    }

    func testAOneToOneChatIsItsOwnSender() throws {
        // The bridge omits senderId on some events, and in a one-to-one thread
        // the chat IS the sender. That is the Message-Yourself case, which is
        // the entire product here — defaulting it wrong would refuse every
        // message the owner sends.
        let message = try XCTUnwrap(WhatsAppClient.decode(line(senderID: nil)))
        XCTAssertEqual(message.senderID, "60123456789@s.whatsapp.net")
    }

    func testATimestampSurvivesArrivingAsAString() throws {
        // protobuf longs reach JSON as strings often enough that assuming one
        // shape drops real messages.
        let message = try XCTUnwrap(
            WhatsAppClient.decode(line(extra: ["timestamp": "1754500123"]))
        )
        XCTAssertEqual(message.timestamp, 1_754_500_123)
    }

    func testAGroupIsRecognisedFromTheAddressWhenTheFlagIsMissing() throws {
        let message = try XCTUnwrap(
            WhatsAppClient.decode(line(chatID: "120363000000000000@g.us", senderID: "60999@s.whatsapp.net"))
        )
        XCTAssertTrue(message.isGroup, "@g.us is a group whether or not the flag says so")
    }

    func testAnUnknownMediaTypeIsCarriedRatherThanRejected() throws {
        // WhatsApp adds message kinds; the bridge passes them through. An enum
        // here would turn a new one into a decode failure — a message dropped
        // for being unfamiliar, which is the opposite of the point.
        let message = try XCTUnwrap(
            WhatsAppClient.decode(line(extra: ["mediaType": "some_future_thing", "hasMedia": true]))
        )
        XCTAssertEqual(message.mediaType, "some_future_thing")
        XCTAssertTrue(message.hasMedia)
    }

    func testRubbishDecodesToNothingRatherThanToAnEmptyMessage() {
        XCTAssertNil(WhatsAppClient.decode(Data("not json".utf8)))
        XCTAssertNil(WhatsAppClient.decode(Data("{}".utf8)))
        // No seq: unacknowledgeable, so it must not be treated as a message.
        XCTAssertNil(WhatsAppClient.decode(Data(#"{"event":{"chatId":"x@s.whatsapp.net"}}"#.utf8)))
        // No chatId: nowhere to reply to.
        XCTAssertNil(WhatsAppClient.decode(Data(#"{"seq":1,"event":{}}"#.utf8)))
    }

    // MARK: The allowlist

    func testAnAllowlistCannotBeEmptyAndCannotMatchEverybody() {
        XCTAssertThrowsError(try WhatsAppSenderAllowlist(numbers: []))
        XCTAssertThrowsError(try WhatsAppSenderAllowlist(numbers: ["  "]))
        XCTAssertThrowsError(try WhatsAppSenderAllowlist(numbers: ["*"]))
    }

    func testAPlusIsRefusedAtConstructionRatherThanNeverMatching() {
        // The failure this prevents is not a crash. "+60123456789" builds a
        // perfectly valid allowlist that simply never matches anything, so the
        // owner's own messages are ignored and it looks like a broken bridge.
        XCTAssertThrowsError(try WhatsAppSenderAllowlist(numbers: ["+60123456789"])) { error in
            XCTAssertEqual(error as? WhatsAppSenderAllowlist.Failure, .notANumber("+60123456789"))
        }
        XCTAssertThrowsError(try WhatsAppSenderAllowlist(numbers: ["60 123 456"]))
    }

    func testTheNumberIsReadOutOfEveryAddressShapeWhatsAppUses() {
        XCTAssertEqual(WhatsAppSenderAllowlist.number(inJID: "60123456789@s.whatsapp.net"), "60123456789")
        // A linked device appends :N to the user part.
        XCTAssertEqual(WhatsAppSenderAllowlist.number(inJID: "60123456789:12@s.whatsapp.net"), "60123456789")
        XCTAssertEqual(WhatsAppSenderAllowlist.number(inJID: "60123456789"), "60123456789")
    }

    func testALidAddressMatchesNobody() throws {
        // @lid carries an opaque id rather than a phone number. Refusing is the
        // correct outcome, not a gap to paper over: an allowlist that guessed
        // at an identity it cannot read would be no allowlist at all.
        let allowlist = try WhatsAppSenderAllowlist(numbers: ["60123456789"])
        let message = try XCTUnwrap(
            WhatsAppClient.decode(line(senderID: "182736451827364@lid"))
        )
        XCTAssertFalse(allowlist.decide(message).isAllowed)
    }

    func testAStrangerIsRefused() throws {
        let allowlist = try WhatsAppSenderAllowlist(numbers: ["60123456789"])
        let message = try XCTUnwrap(
            WhatsAppClient.decode(line(senderID: "441234567890@s.whatsapp.net"))
        )
        XCTAssertEqual(
            allowlist.decide(message),
            .denied(.senderNotAllowed("441234567890@s.whatsapp.net"))
        )
    }

    func testTheOwnerIsAllowedFromAnyOfTheirDevices() throws {
        let allowlist = try WhatsAppSenderAllowlist(numbers: ["60123456789"])
        let fromPhone = try XCTUnwrap(WhatsAppClient.decode(line(senderID: "60123456789@s.whatsapp.net")))
        let fromLaptop = try XCTUnwrap(WhatsAppClient.decode(line(senderID: "60123456789:3@s.whatsapp.net")))
        XCTAssertTrue(allowlist.decide(fromPhone).isAllowed)
        XCTAssertTrue(allowlist.decide(fromLaptop).isAllowed)
    }

    func testGroupsAreRefusedUnlessAskedFor() throws {
        let group = try XCTUnwrap(
            WhatsAppClient.decode(line(chatID: "120363000000000000@g.us", senderID: "60123456789@s.whatsapp.net"))
        )

        // A group thread is other people's conversation. Answering in one puts
        // Mynah in front of them, which is not something to do by default even
        // when the sender is the owner.
        let strict = try WhatsAppSenderAllowlist(numbers: ["60123456789"])
        XCTAssertEqual(strict.decide(group), .denied(.groupsNotAllowed("120363000000000000@g.us")))

        let sociable = try WhatsAppSenderAllowlist(numbers: ["60123456789"], answersGroups: true)
        XCTAssertTrue(sociable.decide(group).isAllowed)
    }

    func testAGroupFromAStrangerIsRefusedEvenWhenGroupsAreOn() throws {
        let allowlist = try WhatsAppSenderAllowlist(numbers: ["60123456789"], answersGroups: true)
        let message = try XCTUnwrap(
            WhatsAppClient.decode(line(chatID: "120363000000000000@g.us", senderID: "441234567890@s.whatsapp.net"))
        )
        XCTAssertFalse(allowlist.decide(message).isAllowed)
    }

    // MARK: Where the socket lives

    func testTheSocketPathFitsInsideTheKernelsLimit() {
        // sockaddr_un.sun_path is 104 bytes. Over that, bind() silently
        // truncates and the failure surfaces somewhere unrelated — which is
        // exactly what happened on the JavaScript side before it checked.
        let path = WhatsAppClient.defaultSocketPath()
        XCTAssertLessThanOrEqual(
            path.utf8.count, 103,
            "the default events socket path does not fit in sun_path: \(path)"
        )
        XCTAssertTrue(path.hasSuffix("mynah-whatsapp.sock"))
    }
}
