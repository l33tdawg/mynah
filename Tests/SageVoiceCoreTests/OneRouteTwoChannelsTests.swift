import XCTest
@testable import SageVoiceCore

/// *"it should follow the same flow as signal — so you can choose, signal or
/// whatsapp or both"* and *"the functionality would be the same … through the
/// same established route as signal"* — 7 August 2026.
///
/// One daemon, two channels. These tests cover the seam where that could go
/// wrong: the translation between a channel's own vocabulary and the neutral
/// one the shared loop speaks. A defect here does not look like a crash — it
/// looks like an answer arriving in the wrong conversation, or bold text
/// spelled out as `0:8:BOLD`, or a message answered twice.
final class OneRouteTwoChannelsTests: XCTestCase {

    // MARK: Choosing channels

    func testTheOwnerCanChooseEitherOrBothOrNeither() {
        XCTAssertEqual(ChannelSelection.both.summary, "Signal and WhatsApp")
        XCTAssertEqual(ChannelSelection.signalOnly.summary, "Signal")
        XCTAssertEqual(ChannelSelection.whatsAppOnly.summary, "WhatsApp")

        // Not an error. An appliance nobody can message is a real state during
        // setup, and a UI that cannot describe it will show something false.
        XCTAssertTrue(ChannelSelection.none.isEmpty)
        XCTAssertEqual(ChannelSelection.none.summary, "nothing yet")

        XCTAssertTrue(ChannelSelection.both.includes(.signal))
        XCTAssertTrue(ChannelSelection.both.includes(.whatsapp))
        XCTAssertFalse(ChannelSelection.signalOnly.includes(.whatsapp))
    }

    func testTheSummaryReadsTheSameWhicheverOrderTheSetHappensToIterate() {
        // A Set has no order. Built the other way round, this must still say
        // "Signal and WhatsApp" rather than sometimes "WhatsApp and Signal" —
        // a sentence in front of the owner that changes between launches reads
        // as a bug even though nothing is wrong.
        let assembled = ChannelSelection([.whatsapp, .signal])
        XCTAssertEqual(assembled.summary, ChannelSelection.both.summary)
    }

    func testASelectionSurvivesBeingStoredAndReadBack() throws {
        let encoded = try JSONEncoder().encode(ChannelSelection.both)
        XCTAssertEqual(try JSONDecoder().decode(ChannelSelection.self, from: encoded), .both)
    }

    // MARK: Signal, translated

    private func signalMessage(
        kind: SignalIncomingMessage.Kind = .syncSent,
        destinationNumber: String? = "+60123456789",
        sourceNumber: String? = "+60123456789",
        groupID: String? = nil,
        text: String? = "did the ferry get booked"
    ) -> SignalIncomingMessage {
        SignalIncomingMessage(
            kind: kind,
            sourceNumber: sourceNumber,
            sourceName: "Dhillon",
            destinationNumber: destinationNumber,
            groupID: groupID,
            timestamp: 1_754_500_000_000,
            text: text,
            attachments: []
        )
    }

    func testANoteToSelfRepliesToTheOwnerNotIntoTheVoid() throws {
        // syncSent is how "message yourself" reaches a linked device, and it is
        // the primary path for this product. The reply address is the
        // DESTINATION — reading the source instead would be right for a normal
        // message and wrong for every message the owner actually sends.
        let translated = try XCTUnwrap(SignalChannel.translate(signalMessage()))
        XCTAssertEqual(translated.kind, .signal)
        XCTAssertEqual(translated.recipient.address, "+60123456789")
        XCTAssertFalse(translated.recipient.isGroup)
        XCTAssertNil(translated.acknowledgementToken, "Signal has nothing to acknowledge")
    }

    func testASignalTimestampBecomesSecondsLikeEveryOtherChannel() throws {
        // Signal counts milliseconds and WhatsApp counts seconds. If the shared
        // loop is handed both without conversion, one of them is dated 1970 and
        // the other is fifty thousand years out.
        let translated = try XCTUnwrap(SignalChannel.translate(signalMessage()))
        XCTAssertEqual(translated.timestamp, 1_754_500_000)
    }

    func testAMessageWithNoWayHomeIsNotPassedOn() {
        XCTAssertNil(
            SignalChannel.translate(signalMessage(destinationNumber: nil, sourceNumber: nil)),
            "no reply address means no conversation; it must not reach the loop"
        )
    }

    func testASignalGroupStaysAGroupInBothDirections() throws {
        let translated = try XCTUnwrap(SignalChannel.translate(signalMessage(groupID: "Z3JvdXA=")))
        XCTAssertTrue(translated.recipient.isGroup)
        XCTAssertEqual(
            SignalChannel.signalRecipient(translated.recipient),
            .group(base64ID: "Z3JvdXA="),
            "a group that round-trips as an account sends the reply to a person"
        )
    }

    func testSignalEmphasisIsRenderedInSignalsOwnFormat() {
        XCTAssertEqual(
            SignalChannel.styles(for: [ChannelEmphasis(utf16Offset: 0, utf16Length: 8)]),
            ["0:8:BOLD"]
        )
        XCTAssertEqual(SignalChannel.styles(for: []), [])
    }

    // MARK: WhatsApp, translated

    private func whatsAppMessage(
        chatID: String = "60123456789@s.whatsapp.net",
        senderID: String = "60123456789@s.whatsapp.net",
        isGroup: Bool = false,
        body: String = "did the ferry get booked",
        sequence: Int = 7
    ) -> WhatsAppIncomingMessage {
        WhatsAppIncomingMessage(
            sequence: sequence,
            messageID: "3EB0C431C26A1D9F55",
            chatID: chatID,
            senderID: senderID,
            senderName: "Dhillon",
            isGroup: isGroup,
            body: body,
            timestamp: 1_754_500_000
        )
    }

    func testAWhatsAppMessageCarriesTheTokenThatRetiresIt() {
        let translated = WhatsAppChannel.translate(whatsAppMessage())
        XCTAssertEqual(translated.kind, .whatsapp)
        XCTAssertEqual(
            translated.acknowledgementToken, 7,
            "without this the bridge replays the message for ever"
        )
    }

    func testAGroupReplyGoesToTheGroupAndNotToTheSender() {
        // In a group the chat and the sender differ. Replying to the sender
        // would take the answer out of the conversation the owner is having and
        // into a private thread he did not open — and the other people in the
        // group would see him ask and never see an answer.
        let translated = WhatsAppChannel.translate(
            whatsAppMessage(
                chatID: "120363000000000000@g.us",
                senderID: "60123456789@s.whatsapp.net",
                isGroup: true
            )
        )
        XCTAssertEqual(translated.recipient.address, "120363000000000000@g.us")
        XCTAssertTrue(translated.recipient.isGroup)
    }

    func testAnAttachmentOnlyMessageHasNoTextRatherThanEmptyText() {
        // The loop asks "is there anything to read"; an empty string answers
        // yes. A voice note with no caption is the ordinary case here.
        let translated = WhatsAppChannel.translate(whatsAppMessage(body: ""))
        XCTAssertNil(translated.text)
    }

    // MARK: Emphasis, which is where the two channels genuinely differ

    func testWhatsAppEmphasisIsAsterisksBecauseThereIsNoStylingProtocol() {
        XCTAssertEqual(
            WhatsAppChannel.render("MYNAH >> here you go", emphasis: [ChannelEmphasis(utf16Offset: 0, utf16Length: 8)]),
            "*MYNAH >>* here you go"
        )
    }

    func testSignalsRangeFormatNeverReachesWhatsAppAsText() {
        // The failure this prevents: passing Signal's "0:8:BOLD" through a
        // shared type would put that string in front of the owner, or drop the
        // emphasis silently. Each channel renders the description its own way.
        let rendered = WhatsAppChannel.render("MYNAH >> hello", emphasis: [ChannelEmphasis(utf16Offset: 0, utf16Length: 8)])
        XCTAssertFalse(rendered.contains("BOLD"))
        XCTAssertFalse(rendered.contains("0:8"))
    }

    func testTwoRunsBothLandOnTheRightWords() {
        // Applied back to front, because inserting an asterisk shifts every
        // offset after it. Front to back, the second run would wrap the wrong
        // characters — off by exactly the two asterisks the first one added.
        let rendered = WhatsAppChannel.render(
            "one two three",
            emphasis: [
                ChannelEmphasis(utf16Offset: 0, utf16Length: 3),
                ChannelEmphasis(utf16Offset: 8, utf16Length: 5),
            ]
        )
        XCTAssertEqual(rendered, "*one* two *three*")
    }

    func testEmphasisOverEmojiWrapsTheWordsItWasAskedTo() {
        // The reason ChannelEmphasis is documented in UTF-16 units: an emoji is
        // one Character and two code units, so a character count and a UTF-16
        // count disagree the moment a marker contains one. SignalReplyText
        // already learned this; the WhatsApp renderer must not relearn it.
        let text = "🎉 party time"
        let utf16Length = "🎉 party".utf16.count
        XCTAssertEqual(
            WhatsAppChannel.render(text, emphasis: [ChannelEmphasis(utf16Offset: 0, utf16Length: utf16Length)]),
            "*🎉 party* time"
        )
    }

    func testAnImpossibleRangeIsSkippedRatherThanCrashingOrGuessing() {
        let text = "short"
        XCTAssertEqual(
            WhatsAppChannel.render(text, emphasis: [ChannelEmphasis(utf16Offset: 99, utf16Length: 4)]),
            "short"
        )
        XCTAssertEqual(
            WhatsAppChannel.render(text, emphasis: [ChannelEmphasis(utf16Offset: 0, utf16Length: 99)]),
            "short"
        )
        XCTAssertEqual(WhatsAppChannel.render(text, emphasis: []), "short")
    }

    func testARangeThatSplitsAnEmojiIsSkippedRatherThanCorrupting() {
        // Offset 1 lands inside the surrogate pair. Cutting there would produce
        // an unpaired surrogate — a message that renders as a replacement
        // character on the owner's phone.
        let rendered = WhatsAppChannel.render("🎉ok", emphasis: [ChannelEmphasis(utf16Offset: 1, utf16Length: 2)])
        XCTAssertEqual(rendered, "🎉ok")
    }

    // MARK: The property that makes "both" safe

    func testEveryRecipientKnowsWhichChannelItBelongsTo() {
        let fromSignal = SignalChannel.translate(signalMessage())
        let fromWhatsApp = WhatsAppChannel.translate(whatsAppMessage())
        XCTAssertEqual(fromSignal?.recipient.kind, .signal)
        XCTAssertEqual(fromWhatsApp.recipient.kind, .whatsapp)

        // With both channels running, a reply addressed with the wrong kind is
        // the one genuinely new failure "both" introduces: an answer to a
        // WhatsApp question delivered over Signal, or to a number that means
        // something else entirely on the other network. Carrying the kind on
        // the address is what makes that checkable rather than a convention.
        XCTAssertNotEqual(fromSignal?.recipient, fromWhatsApp.recipient)
    }
}
