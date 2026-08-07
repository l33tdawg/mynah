import XCTest
@testable import SageVoiceCore

/// The places where "the same route" had a Signal-shaped assumption in it.
///
/// Each of these was found by walking the daemon's own path with a WhatsApp
/// message in hand and asking what the line actually does. None of them fails on
/// Signal, which is why they survived the transport work: a defect that only
/// appears on the channel nothing was running yet is invisible until the day it
/// ships.
final class AWhatsAppMessageIsNotASignalOneTests: XCTestCase {

    // MARK: - What gets logged

    /// **The scrub matched `+` then seven to fifteen digits, and a WhatsApp
    /// address has no `+`.**
    ///
    /// `redactingNumbers` is applied once, at the daemon's single log seam, so
    /// that a future call site interpolating a raw recipient is wrong in a way
    /// that does not reach disk. That guarantee held for Signal and was simply
    /// absent for WhatsApp: every JID the daemon logged would have gone to
    /// `bridge.log` in full — which is the exact leak this function was written
    /// after, arriving again through the other door.
    func testAWhatsAppAddressIsRedactedToo() {
        let line = SignalSenderAllowlist.redactingNumbers(
            in: "[daemon] whatsapp from 60123821767@s.whatsapp.net at 1"
        )
        XCTAssertFalse(line.contains("60123821767"), "a WhatsApp number reached the log in full: \(line)")
        XCTAssertTrue(line.contains("@s.whatsapp.net"), "the shape of the address was destroyed as well: \(line)")
    }

    func testAGroupJidIsRedactedToo() {
        let line = SignalSenderAllowlist.redactingNumbers(in: "chat 120363012345678901@g.us")
        XCTAssertFalse(line.contains("120363012345678901"), line)
    }

    /// The narrowness is what makes this safe to apply to every log line. A
    /// Signal timestamp is thirteen bare digits, and turning those into asterisks
    /// would make the log useless for correlating anything.
    func testATimestampIsStillATimestamp() {
        XCTAssertEqual(
            SignalSenderAllowlist.redactingNumbers(in: "replied at 1754582400123 in 30.4s"),
            "replied at 1754582400123 in 30.4s"
        )
    }

    func testRunningItTwiceChangesNothingTheSecondTime() {
        let once = SignalSenderAllowlist.redactingNumbers(in: "from 60123821767@s.whatsapp.net")
        XCTAssertEqual(SignalSenderAllowlist.redactingNumbers(in: once), once)
    }

    /// `ChannelMessage.logDescription` says "log-safe" in its doc comment. Its
    /// Signal twin said the same thing for months while printing his number
    /// twenty-six times into one file. A sentence is not a mechanism.
    func testTheMessageDescriptionCannotCarryTheNumber() {
        let message = ChannelMessage(
            kind: .whatsapp,
            recipient: ChannelRecipient(kind: .whatsapp, address: "60123821767@s.whatsapp.net"),
            id: "ABC",
            senderDisplayName: "Dhillon",
            text: "the thing I actually said",
            timestamp: 1754582400
        )
        let rendered = message.logDescription
        XCTAssertFalse(rendered.contains("60123821767"), rendered)
        XCTAssertFalse(rendered.contains("the thing I actually said"), "message text reached a log line: \(rendered)")
    }

    // MARK: - What the daemon does with a file

    /// **A voice note that is not recognised as one is filed, not transcribed.**
    ///
    /// The owner speaks a question; Mynah replies that it has saved their voice
    /// as an attachment and offers to switch brains so it can look at it. That
    /// exact reply has happened once already on Signal, and the fix was
    /// `isAudio`. WhatsApp calls a voice note `ptt`, and it arrives as `.ogg`.
    func testAWhatsAppVoiceNoteIsHeardRatherThanFiled() {
        let message = WhatsAppChannel.translate(WhatsAppIncomingMessage(
            sequence: 1,
            messageID: "A",
            chatID: "60123821767@s.whatsapp.net",
            senderID: "60123821767@s.whatsapp.net",
            hasMedia: true,
            mediaType: "ptt",
            mediaPaths: ["/tmp/mynah/audio_cache/note-1.ogg"]
        ))
        XCTAssertNotNil(message.voiceNoteURL, "a spoken question would have been saved as a document")
        XCTAssertTrue(message.imageURLs.isEmpty)
    }

    /// The bridge does not always give a usable extension. WhatsApp's own
    /// category is then the only thing left, and losing it is the same failure
    /// as above.
    func testAVoiceNoteWithNoExtensionIsStillHeard() {
        let message = WhatsAppChannel.translate(WhatsAppIncomingMessage(
            sequence: 1,
            messageID: "A",
            chatID: "60123821767@s.whatsapp.net",
            senderID: "60123821767@s.whatsapp.net",
            hasMedia: true,
            mediaType: "ptt",
            mediaPaths: ["/tmp/mynah/audio_cache/note-1"]
        ))
        XCTAssertNotNil(message.voiceNoteURL)
    }

    /// A `.jpg` on disk says more than "image" does, so the extension rules and
    /// no type is invented over it.
    func testTheSavedFilesOwnExtensionIsPreferredToTheCategory() {
        XCTAssertNil(WhatsAppChannel.contentType(for: "image", path: "/tmp/photo.jpg"))
        XCTAssertEqual(WhatsAppChannel.contentType(for: "image", path: "/tmp/photo"), "image/jpeg")
    }

    /// `document` means "the owner attached a file", which is precisely the case
    /// where guessing what it is would be wrong.
    func testADocumentIsNeverGuessedAt() {
        XCTAssertNil(WhatsAppChannel.contentType(for: "document", path: "/tmp/no-extension"))
    }

    func testAPhotoIsSomethingTheModelIsAskedToLookAt() {
        let message = WhatsAppChannel.translate(WhatsAppIncomingMessage(
            sequence: 2,
            messageID: "B",
            chatID: "60123821767@s.whatsapp.net",
            senderID: "60123821767@s.whatsapp.net",
            body: "what is this",
            hasMedia: true,
            mediaType: "image",
            mediaPaths: ["/tmp/mynah/image_cache/photo-1.jpg"]
        ))
        XCTAssertEqual(message.imageURLs.count, 1)
        XCTAssertNil(message.voiceNoteURL)
    }

    /// A PDF is kept for later retrieval rather than shown to a vision model —
    /// the owner's own rule: *"if i drop a png jpg other image type; then try
    /// and interpret it / read it - if its pdf, docx, xls - keep it for later"*.
    func testADocumentIsKeptRatherThanLookedAt() {
        let message = WhatsAppChannel.translate(WhatsAppIncomingMessage(
            sequence: 3,
            messageID: "C",
            chatID: "60123821767@s.whatsapp.net",
            senderID: "60123821767@s.whatsapp.net",
            hasMedia: true,
            mediaType: "document",
            mediaPaths: ["/tmp/mynah/document_cache/ferry-booking.pdf"]
        ))
        XCTAssertTrue(message.imageURLs.isEmpty)
        XCTAssertNil(message.voiceNoteURL)
        XCTAssertEqual(message.attachments.count, 1)
    }

    /// Two files on one message need two ids: the attachment store keys on them,
    /// and WhatsApp gives one id for the message rather than one per file.
    func testTwoFilesOnOneMessageDoNotShareAnIdentity() {
        let message = WhatsAppChannel.translate(WhatsAppIncomingMessage(
            sequence: 4,
            messageID: "D",
            chatID: "60123821767@s.whatsapp.net",
            senderID: "60123821767@s.whatsapp.net",
            hasMedia: true,
            mediaType: "image",
            mediaPaths: ["/tmp/a.jpg", "/tmp/b.jpg"]
        ))
        XCTAssertEqual(Set(message.attachments.map(\.id)).count, 2, "two photos would have landed on each other")
    }

    // MARK: - What is kept, and what the note says about it

    /// **The note is the searchable half.** "The ferry booking I sent on
    /// WhatsApp" only finds anything if the note says WhatsApp — and this said
    /// "Sent to Mynah on Signal" for every attachment, whichever app it came
    /// from. A remembered fact that is simply false.
    func testTheKeptFileRemembersWhichAppItCameFrom() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mynah-attachments-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("ferry.pdf")
        try Data("%PDF-1.4".utf8).write(to: file)

        let kept = SignalAttachmentStore(notesDirectory: directory).keep(
            [ChannelAttachment(id: "1", contentType: "application/pdf", filename: "ferry.pdf", localURL: file)],
            via: .whatsapp,
            caption: "the ferry booking",
            receivedAt: Date(timeIntervalSince1970: 1_754_582_400)
        )
        let note = try XCTUnwrap(kept.first?.note)
        let text = try String(contentsOf: note, encoding: .utf8)
        XCTAssertTrue(text.contains("WhatsApp"), "the note says the wrong app: \(text)")
        XCTAssertFalse(text.contains("on Signal"), "the note says the wrong app: \(text)")
    }

    // MARK: - The apology after a crash

    /// **A promise made on WhatsApp has to be apologised for on WhatsApp.**
    ///
    /// Sent to Signal, the address is not a Signal account, so the send fails,
    /// so the record is never cleared, so the appliance apologises for the same
    /// question on every boot from then on.
    func testAPromiseRemembersWhichChannelItWasMadeOn() throws {
        let promise = PromisedAnswer(
            account: "60123821767@s.whatsapp.net",
            question: "what time is the ferry",
            promisedAt: Date(timeIntervalSince1970: 1_754_582_400),
            channel: .whatsapp
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let round = try decoder.decode(PromisedAnswer.self, from: encoder.encode(promise))
        XCTAssertEqual(round, promise, "a promise did not survive being written and read back")
        XCTAssertEqual(round.channel, .whatsapp)
    }

    /// **The one upgrade where this feature matters most is the one it would
    /// have failed.** A promise written by a Signal-only build has no `channel`
    /// key, and a synthesised decoder throws on that — which `outstanding()`
    /// turns into `nil`, silently discarding an answer the owner is still owed.
    func testAPromiseWrittenBeforeWhatsAppExistedIsStillKept() throws {
        let old = #"{"account":"+60123821767","promisedAt":"2026-08-07T12:00:00Z","question":"what time is the ferry"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let promise = try decoder.decode(PromisedAnswer.self, from: Data(old.utf8))
        XCTAssertEqual(promise.channel, .signal)
        XCTAssertEqual(promise.account, "+60123821767")
    }

    /// The account is the address alone. `ChannelRecipient.description` carries
    /// the channel name in front of it, and storing that would send the apology
    /// to a Signal account literally called "whatsapp:60…".
    func testTheStoredAccountIsSomethingAReplyCanBeAddressedTo() {
        var ledger = PromiseLedger()
        let recipient = ChannelRecipient(kind: .whatsapp, address: "60123821767@s.whatsapp.net")
        let promise = ledger.promised(
            to: recipient.address,
            channel: recipient.kind,
            question: "what time is the ferry",
            at: Date(timeIntervalSince1970: 1)
        )
        XCTAssertEqual(promise?.account, "60123821767@s.whatsapp.net")
        XCTAssertEqual(
            ChannelRecipient(kind: promise!.channel, address: promise!.account, isGroup: false),
            recipient,
            "the apology would not have gone back to the thread that asked"
        )
    }

    // MARK: - Emphasis

    /// **`0:8:BOLD` means nothing to WhatsApp.** Passed through a shared reply
    /// path it would arrive either printed in front of every answer or dropped,
    /// depending on which end noticed first.
    func testTheSameEmphasisIsSpelledTwoWays() {
        let emphasis = SignalReplyText.emphasis(forPrefix: "MYNAH >> ")
        XCTAssertEqual(SignalChannel.styles(for: emphasis), ["0:8:BOLD"])
        XCTAssertEqual(
            WhatsAppChannel.render("MYNAH >> the ferry leaves at nine", emphasis: emphasis),
            "*MYNAH >>* the ferry leaves at nine"
        )
    }

    /// The old `styles(forPrefix:)` still has to produce the wire form, because
    /// `SignalChannel` sends it. Expressed in terms of the new one so the two
    /// cannot come apart.
    func testTheSignalWireFormIsUnchanged() {
        XCTAssertEqual(SignalReplyText.styles(forPrefix: "MYNAH >> "), ["0:8:BOLD"])
        XCTAssertEqual(SignalReplyText.styles(forPrefix: ""), [])
        XCTAssertEqual(SignalReplyText.emphasis(forPrefix: "   "), [])
    }

    /// UTF-16 offsets, counted the way Signal's wire format does. `count` is a
    /// character count and the two disagree the moment a marker holds an emoji —
    /// which would put the bold over the wrong words rather than failing loudly.
    func testAMarkerWithAnEmojiIsMeasuredTheWayTheWireFormatMeasuresIt() {
        let emphasis = SignalReplyText.emphasis(forPrefix: "🕊 MYNAH ")
        XCTAssertEqual(emphasis.first?.utf16Length, "🕊 MYNAH".utf16.count)
        XCTAssertEqual(
            WhatsAppChannel.render("🕊 MYNAH hello", emphasis: emphasis),
            "*🕊 MYNAH* hello",
            "the asterisks landed off a character boundary"
        )
    }
}
