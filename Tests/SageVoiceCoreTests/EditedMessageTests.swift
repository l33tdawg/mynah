import XCTest
@testable import SageVoiceCore

/// An edited Signal message must still be a message.
///
/// ## What this cost
///
/// On 4 August 2026 the owner reported *"signal is completely dead"*. Both
/// processes were up, signal-cli held a live socket to Signal's servers, and the
/// daemon was subscribed. His messages arrived and the log said:
///
///     [daemon] syncSent from +60******767 at 1785839007659 (text)
///         -> ignored (no text, no audio)
///
/// He had typed a question, then edited it to add a second question mark. Signal
/// re-delivers an edited message with its payload nested inside
/// `editMessage.dataMessage`, so `text` came back empty and the daemon dropped
/// it — silently, and correctly by its own rules, because an envelope with no
/// text is an ordinary thing: a receipt, a typing indicator, a read sync. This
/// one looked exactly like those.
///
/// ## Why the existing fix did not cover it
///
/// `parseEnvelope` already unwrapped `editMessage.dataMessage` — on the
/// `dataMessage` branch. The appliance is driven from Note-to-Self, so every
/// message the owner sends it arrives as `syncMessage.sentMessage` and takes the
/// *other* branch. The one path that had the fix was the one path that never
/// runs here, and nothing in the suite tested either.
///
/// The same shape as three other bugs this week: a guard written for one call
/// site while a second, identical one went unwatched.
final class EditedMessageTests: XCTestCase {

    private let directory = FileManager.default.temporaryDirectory

    private func parse(_ envelope: [String: Any]) -> SignalIncomingMessage? {
        SignalEnvelopeParser.parseEnvelope(
            envelope,
            account: "+60123821767",
            attachmentsDirectory: directory
        )
    }

    /// Note-to-Self, edited. This is the exact shape that went missing.
    private func editedSyncEnvelope(_ text: String) -> [String: Any] {
        [
            "source": "+60123821767",
            "sourceNumber": "+60123821767",
            "timestamp": 1_785_839_007_659,
            "syncMessage": [
                "sentMessage": [
                    "destinationNumber": "+60123821767",
                    "timestamp": 1_785_839_007_000,
                    "editMessage": [
                        "targetSentTimestamp": 1_785_839_007_000,
                        "dataMessage": [
                            "timestamp": 1_785_839_007_659,
                            "message": text
                        ]
                    ]
                ]
            ]
        ]
    }

    // MARK: The bug

    func testAnEditedNoteToSelfMessageStillCarriesItsText() throws {
        let parsed = try XCTUnwrap(
            parse(editedSyncEnvelope("when is my next dentist appointment ??")),
            "an edited message parsed to nothing, which is how it got dropped"
        )

        XCTAssertEqual(parsed.text, "when is my next dentist appointment ??")
        XCTAssertTrue(parsed.hasText)
        XCTAssertEqual(parsed.kind, .syncSent)
    }

    // MARK: Carrying the text was not enough

    /// **The first fix made this worse and the test above stayed green.**
    ///
    /// It rebound `sentMessage` to the inner `dataMessage` wholesale. The
    /// addressing fields — `destination`, `destinationNumber`,
    /// `destinationUuid` — live on the *outer* sentMessage and the inner one has
    /// none of them, so `destinationIdentifiers` came back empty and
    /// `SignalClient.handleReceive` dropped the message as
    /// `syncDestinationNotAllowlisted` one stage before the daemon.
    ///
    /// The owner's experience did not change by a single message. Only the log
    /// line did, from `ignored (no text, no audio)` to `DROPPED …`.
    ///
    /// The test above could not see it, because it asked what the message said
    /// and never asked who it was for. Both are needed for a message to be
    /// answered, and only one was pinned.
    func testAnEditedNoteToSelfMessageIsStillAddressedToTheOwner() throws {
        let parsed = try XCTUnwrap(parse(editedSyncEnvelope("edited and addressed")))

        XCTAssertEqual(
            parsed.destinationNumber, "+60123821767",
            "the edit unwrap threw away who the message was for"
        )
        XCTAssertTrue(
            parsed.destinationIdentifiers.contains("+60123821767"),
            "no destination survived: \(parsed.destinationIdentifiers)"
        )
        XCTAssertNotNil(
            parsed.replyRecipient,
            "nothing to reply to, so the daemon would fail the turn before answering"
        )
    }

    /// The whole point, stated as the thing the owner actually experiences:
    /// **an edited message must survive the allowlist**, under the policy the
    /// appliance really ships with.
    ///
    /// Note-to-Self only, which is the shipped default, and the one that denied
    /// this message. Asserted against the same envelope unedited so the test
    /// says the edit is what makes the difference rather than merely that
    /// something was allowed.
    func testAnEditedNoteToSelfMessageSurvivesTheAllowlist() throws {
        // `.strict` is the shipped default and carries
        // `syncDestinationRule: .noteToSelfOnly` — the rule that denied this.
        let allowlist = try SignalSenderAllowlist(
            commaSeparated: "+60123821767",
            policy: .strict
        )
        XCTAssertEqual(
            allowlist.policy.syncDestinationRule, .noteToSelfOnly,
            "this test is only meaningful under the rule that did the denying"
        )

        let edited = try XCTUnwrap(parse(editedSyncEnvelope("edited")))
        let plain = try XCTUnwrap(parse(uneditedSyncEnvelope("not edited")))

        XCTAssertEqual(
            allowlist.evaluate(plain), SignalSenderAllowlist.Decision.allow,
            "the unedited case is the control and it must pass"
        )
        XCTAssertEqual(
            allowlist.evaluate(edited), SignalSenderAllowlist.Decision.allow,
            """
            an edited message from the owner to his own Note-to-Self was refused \
            by the allowlist, which is the appliance going silent on him again by \
            a different route
            """
        )
    }

    /// The unedited shape, for the control above.
    private func uneditedSyncEnvelope(_ text: String) -> [String: Any] {
        [
            "source": "+60123821767",
            "sourceNumber": "+60123821767",
            "timestamp": 1_785_839_007_659,
            "syncMessage": [
                "sentMessage": [
                    "destinationNumber": "+60123821767",
                    "timestamp": 1_785_839_007_000,
                    "message": text
                ]
            ]
        ]
    }

    /// The direct path was already right. Pinned so a future tidy-up cannot
    /// "simplify" the two branches back into one that only handles one of them.
    func testAnEditedDirectMessageStillCarriesItsText() throws {
        let parsed = try XCTUnwrap(parse([
            "source": "+60111111111",
            "timestamp": 1_785_839_007_659,
            "editMessage": [
                "targetSentTimestamp": 1_785_839_007_000,
                "dataMessage": ["timestamp": 1_785_839_007_659, "message": "edited direct"]
            ]
        ]))

        XCTAssertEqual(parsed.text, "edited direct")
        XCTAssertEqual(parsed.kind, .direct)
    }

    // MARK: What must not change

    /// The ordinary case, which is every message he has ever sent that he did
    /// not edit. An unwrap that quietly changed this would trade one silence for
    /// another.
    func testAnUneditedNoteToSelfMessageIsUntouched() throws {
        let parsed = try XCTUnwrap(parse([
            "source": "+60123821767",
            "timestamp": 1_785_839_007_659,
            "syncMessage": [
                "sentMessage": [
                    "destinationNumber": "+60123821767",
                    "timestamp": 1_785_839_007_659,
                    "message": "what's on my list today"
                ]
            ]
        ]))

        XCTAssertEqual(parsed.text, "what's on my list today")
        XCTAssertEqual(parsed.timestamp, 1_785_839_007_659)
    }

    /// Envelopes that genuinely carry nothing must still parse to nothing —
    /// receipts and typing indicators are most of the traffic, and treating one
    /// as a question would have the appliance answering a read receipt.
    func testAReceiptStillParsesToNothing() {
        XCTAssertNil(parse([
            "source": "+60123821767",
            "timestamp": 1_785_839_007_659,
            "receiptMessage": ["when": 1_785_839_007_659, "isDelivery": true]
        ]))
        XCTAssertNil(parse([
            "source": "+60123821767",
            "syncMessage": ["readMessages": [["timestamp": 1_785_839_007_659]]]
        ]))
    }

    /// An edited message that carries an attachment keeps it — he edits captions,
    /// and a photo whose caption was fixed must not lose the photo.
    func testAnEditedMessageKeepsItsAttachments() throws {
        var envelope = editedSyncEnvelope("here's the one I meant")
        var sync = envelope["syncMessage"] as! [String: Any]
        var sent = sync["sentMessage"] as! [String: Any]
        var edit = sent["editMessage"] as! [String: Any]
        var data = edit["dataMessage"] as! [String: Any]
        data["attachments"] = [["id": "abc", "contentType": "image/jpeg", "filename": "photo.jpg"]]
        edit["dataMessage"] = data
        sent["editMessage"] = edit
        sync["sentMessage"] = sent
        envelope["syncMessage"] = sync

        let parsed = try XCTUnwrap(parse(envelope))
        XCTAssertEqual(parsed.text, "here's the one I meant")
        XCTAssertEqual(parsed.attachments.count, 1, "the edit dropped the photo")
    }
}
