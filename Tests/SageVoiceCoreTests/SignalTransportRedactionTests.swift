import XCTest
@testable import SageVoiceCore

/// Whether a phone number can reach a log file.
///
/// **Written after finding twenty-six of the owner's number in one
/// `bridge.log`.** Every one came from `SignalIncomingMessage.logDescription`,
/// whose own doc comment said "log-safe" — while the twin that does the same job
/// in `SignalClient` redacted correctly. One call site drifted from a convention
/// everybody else followed, and nothing failed.
///
/// So this asserts the property rather than the practice: build a message
/// carrying a real number, render everything this package logs, and assert the
/// number is not in the output. A field added later that forgets to redact
/// fails here rather than appearing on somebody's disk.
final class SignalTransportRedactionTests: XCTestCase {

    /// A number long enough that a partial match is not a coincidence, in the
    /// shape the owner's actually takes.
    private let number = "+60123821767"

    private func message(
        sourceNumber: String? = nil,
        source: String? = nil,
        sourceUUID: String? = nil
    ) -> SignalIncomingMessage {
        SignalIncomingMessage(
            kind: .direct,
            source: source,
            sourceNumber: sourceNumber,
            sourceUUID: sourceUUID,
            timestamp: 1_753_000_000,
            text: "are you there?",
            attachments: []
        )
    }

    // MARK: The leak

    func testTheSendersNumberNeverReachesTheLogLine() {
        let rendered = message(sourceNumber: number).logDescription

        XCTAssertFalse(
            rendered.contains(number),
            "the sender's number is in a line we write to disk: \(rendered)"
        )
        // It still has to identify *somebody*, or the log stops being useful.
        XCTAssertTrue(rendered.contains("767"), "redaction removed the identifier entirely")
    }

    /// Three fields can carry the sender and the code falls through them in
    /// order. A fix applied to the first would leave the other two leaking.
    func testEveryFieldThatCanCarryASenderIsRedacted() {
        for rendered in [
            message(sourceNumber: number).logDescription,
            message(source: number).logDescription,
            message(sourceUUID: number).logDescription
        ] {
            XCTAssertFalse(rendered.contains(number), "an unredacted sender survived: \(rendered)")
        }
    }

    /// The doc comment's other promise, which was true and is worth keeping true.
    func testTheMessageTextNeverReachesTheLogLine() {
        XCTAssertFalse(message(sourceNumber: number).logDescription.contains("are you there?"))
    }

    func testAMessageFromNobodySaysSoRatherThanRenderingEmpty() {
        XCTAssertTrue(message().logDescription.contains("<unknown>"))
    }

    // MARK: The events

    /// The two events that carry a sender are constructed with `redact` at their
    /// call sites — which is the convention that failed above. This pins the
    /// rendering rather than the call site: whatever is handed in, the event
    /// must not print something that looks like a whole number.
    func testTheEventsRenderWhatTheyAreGivenWithoutWideningIt() {
        let redacted = SignalSenderAllowlist.redact(number)

        let rejected = SignalTransportEvent.senderRejected(
            sender: redacted,
            reason: .senderNotAllowlisted
        ).description
        let sent = SignalTransportEvent.sent(recipient: redacted, timestamp: 1).description

        for line in [rejected, sent] {
            XCTAssertFalse(line.contains(number))
            XCTAssertTrue(line.contains(redacted))
        }
    }

    // MARK: The seam — the part that is a mechanism rather than a convention

    /// **The assertion the two leaks would have failed.**
    ///
    /// Fixing `logDescription` and the send-failure line fixes the two call
    /// sites that exist. This pins the property for the ones that do not exist
    /// yet: whatever a caller hands the daemon's log closure, a number does not
    /// reach the file. `redact` was available and idiomatic in eleven places
    /// when those two forgot it — so the fix that lasts is the one no call site
    /// has to remember.
    func testTheScrubberCatchesANumberACallSiteForgot() {
        let careless = "[daemon] could not send reply to \(number): timed out"

        let scrubbed = SignalSenderAllowlist.redactingNumbers(in: careless)

        XCTAssertFalse(scrubbed.contains(number))
        XCTAssertTrue(scrubbed.contains("timed out"), "the scrub ate the diagnostic")
        XCTAssertTrue(scrubbed.contains("could not send reply"))
    }

    func testEveryNumberInALineIsScrubbedRatherThanTheFirst() {
        let line = "sync from \(number) to +60111222333 at 1753000000000"

        let scrubbed = SignalSenderAllowlist.redactingNumbers(in: line)

        XCTAssertFalse(scrubbed.contains(number))
        XCTAssertFalse(scrubbed.contains("+60111222333"))
        // The Signal timestamp is thirteen bare digits and must survive: it is
        // the message id, and it is how a log line is matched to a message.
        XCTAssertTrue(scrubbed.contains("1753000000000"))
    }

    /// The scrub must not damage the numbers a diagnosis actually reads.
    func testItLeavesTheNumbersThatAreNotPhoneNumbersAlone() {
        for harmless in [
            "replied in 16.7s to are you there?",
            "reconnecting to signal-cli (attempt 24) in 9.2s",
            "resumed 3 conversation(s), 128 turns",
            "subscribed to receive (subscription 1)"
        ] {
            XCTAssertEqual(SignalSenderAllowlist.redactingNumbers(in: harmless), harmless)
        }
    }

    /// Applied at a seam, so it runs over lines that were already redacted at
    /// their call site. It must not chew them further into uselessness.
    func testScrubbingAnAlreadyRedactedLineChangesNothing() {
        let once = SignalSenderAllowlist.redactingNumbers(in: "sent to \(number)")
        XCTAssertEqual(SignalSenderAllowlist.redactingNumbers(in: once), once)
    }

    /// What redaction is: enough to tell two people apart, not enough to dial.
    func testRedactionKeepsTheTailAndDropsTheMiddle() {
        let redacted = SignalSenderAllowlist.redact(number)

        XCTAssertNotEqual(redacted, number)
        XCTAssertTrue(redacted.hasSuffix("767"))
        XCTAssertFalse(redacted.contains("12382"))
    }
}
