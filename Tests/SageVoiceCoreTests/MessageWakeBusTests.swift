#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import XCTest
@testable import SageVoiceCore
#if canImport(FoundationNetworking)
// `URLRequest`, `URLSession` and `HTTPURLResponse` are in Foundation on a Mac
// and in this second module everywhere else. Same convention as the twenty-eight
// files under Sources/ that already reach for the network.
import FoundationNetworking
#endif

/// The durable message wake bus, SAGE 11.18.12's `GET /v1/messages/wake`.
///
/// Two halves, tested for different reasons.
///
/// **The signature is pinned against a vector**, because it is the one thing
/// here that cannot be checked by reading the code: a wrong canonical string
/// produces a perfectly well-formed signature that the node rejects with a 401,
/// and a 401 on a route reads like a permissions problem rather than a client
/// bug. This product has made exactly that mistake before —
/// `ApplianceStanding` exists because an unsigned `GET /v1/agents` got a 401
/// and the conclusion drawn was that the appliance could not report its own
/// standing.
///
/// The vectors below were produced by signing with a fixed seed and are anchored
/// to reality rather than to this implementation: the same construction, with
/// the appliance's real key, was accepted by the owner's live 11.18.12 node on
/// 15 August 2026, which answered `200` and delivered
/// `id: 1 / event: wake / data: {"version":1,"seq":1,"pending":true}`.
///
/// **The framing is tested for the two things a happy-path check cannot see**:
/// a heartbeat comment mistaken for an event, and a dispatch that never fires.
/// A stream that only ever delivers correct events proves neither.
final class MessageWakeBusTests: XCTestCase {

    // MARK: - Signing

    /// `seed = 00 01 02 … 1f`, which derives to agent `03a107bf…`.
    private var vectorKey: Curve25519.Signing.PrivateKey {
        try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
    }

    private let vectorPath = "/v1/messages/wake?consumer_id=mynah&after_seq=7"
    private let vectorTimestamp: Int64 = 1_786_793_100

    func testTheDerivedAgentIDIsTheHexOfThePublicKey() {
        XCTAssertEqual(
            SageAgentIdentity.agentID(ofKeyBytes: Data(0..<32)),
            "03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8"
        )
    }

    /// **The vectors pin the message, not the signature.**
    ///
    /// CryptoKit's Ed25519 is *hedged*: signing identical bytes with an
    /// identical key produces a different 64 bytes on every call. Both verify,
    /// and the node only ever verifies — but it means a pinned signature hex
    /// would be pinning a random number, and the first version of these tests
    /// did exactly that and failed three ways on the first run.
    ///
    /// The message is the actual contract with `internal/auth/ed25519.go`, and
    /// it is deterministic. Each test below pins those bytes and then proves the
    /// signature over them verifies, which together cover the whole path.
    func testMessageWithoutANonceMatchesTheNodesScheme() {
        let message = SageRequestSigning.message(
            method: "GET", path: vectorPath, body: Data(),
            timestamp: vectorTimestamp, nonce: Data()
        )
        XCTAssertEqual(
            hex(message),
            "6ae2d1abc6f18782ba9294bda4c7d804df152f5813123308359234d9cd751dd3"
                + "000000006a804c8c"
        )
        XCTAssertTrue(verifies(message))
    }

    /// The nonce is appended *after* the big-endian timestamp, not folded into
    /// the hash. Sixteen bytes longer, same first forty.
    func testTheNonceIsAppendedAfterTheTimestamp() {
        let message = SageRequestSigning.message(
            method: "GET", path: vectorPath, body: Data(),
            timestamp: vectorTimestamp, nonce: Data(0..<16)
        )
        XCTAssertEqual(
            hex(message),
            "6ae2d1abc6f18782ba9294bda4c7d804df152f5813123308359234d9cd751dd3"
                + "000000006a804c8c"
                + "000102030405060708090a0b0c0d0e0f"
        )
        XCTAssertTrue(verifies(message))
    }

    /// The body is inside the hashed canonical request, not appended after it.
    /// Nothing in this product sends a signed body yet; the vector exists so the
    /// first caller that does is not the one discovering the placement.
    func testTheBodyIsHashedInsideTheCanonicalRequest() {
        let message = SageRequestSigning.message(
            method: "POST", path: "/v1/messages", body: Data(#"{"a":1}"#.utf8),
            timestamp: vectorTimestamp, nonce: Data(0..<16)
        )
        XCTAssertEqual(
            hex(message),
            "77a11f24aa82f79a53760649365a42ba03d6300e5663006e0549358d55279f02"
                + "000000006a804c8c"
                + "000102030405060708090a0b0c0d0e0f"
        )
        XCTAssertTrue(verifies(message))
        // The body is not on the end: a 32-byte digest, 8 of timestamp, 16 of
        // nonce, and nothing else however long the body is.
        XCTAssertEqual(message.count, 56)
    }

    /// **Whether two signings of the same bytes collide is the platform's
    /// choice, and the two platforms chose differently.**
    ///
    /// CryptoKit's Ed25519 is hedged — it mixes fresh randomness into every
    /// signature, so signing identical bytes twice gives two different 64-byte
    /// values. swift-crypto's is BoringSSL's, which is RFC 8032 to the letter
    /// and therefore deterministic: the same key over the same bytes gives the
    /// same signature every time.
    ///
    /// This matters because the node's replay cache is keyed on
    /// `(agentID, signature)`. On a Mac the hedging made that key incidentally
    /// unique; on Linux it does not, and the only thing keeping two identical
    /// requests apart is `X-Nonce`. The nonce was always what this product
    /// relies on — see `testEveryNonceIsFresh` — but off Darwin it is
    /// load-bearing rather than redundant, and this is where that shows up.
    ///
    /// What both sides must agree on is the half below the split: whatever the
    /// bytes are, they verify.
    func testSigningTheSameBytesTwiceGivesTwoValidSignatures() {
        let message = SageRequestSigning.message(
            method: "GET", path: vectorPath, body: Data(),
            timestamp: vectorTimestamp, nonce: Data()
        )
        let first = try! vectorKey.signature(for: message)
        let second = try! vectorKey.signature(for: message)
        #if canImport(CryptoKit)
        XCTAssertNotEqual(first, second)
        #else
        XCTAssertEqual(first, second)
        #endif
        XCTAssertTrue(vectorKey.publicKey.isValidSignature(first, for: message))
        XCTAssertTrue(vectorKey.publicKey.isValidSignature(second, for: message))
    }

    /// **The query string is part of what is signed.**
    ///
    /// `Ed25519AuthMiddleware` rebuilds the path as
    /// `r.URL.Path + "?" + r.URL.RawQuery`, so a client that signs the bare path
    /// and then attaches query items has signed a request it did not make. The
    /// symptom is a 401 with nothing in it about queries.
    func testTheQueryStringChangesTheSignature() {
        let withQuery = SageRequestSigning.message(
            method: "GET", path: vectorPath, body: Data(),
            timestamp: vectorTimestamp, nonce: Data()
        )
        let withoutQuery = SageRequestSigning.message(
            method: "GET", path: "/v1/messages/wake", body: Data(),
            timestamp: vectorTimestamp, nonce: Data()
        )
        XCTAssertNotEqual(withQuery, withoutQuery)
    }

    /// The method is bound too, which is what stops a signature for a read being
    /// replayed against a write.
    func testTheMethodChangesTheSignature() {
        let get = SageRequestSigning.message(
            method: "GET", path: "/v1/messages", body: Data(),
            timestamp: vectorTimestamp, nonce: Data()
        )
        let post = SageRequestSigning.message(
            method: "POST", path: "/v1/messages", body: Data(),
            timestamp: vectorTimestamp, nonce: Data()
        )
        XCTAssertNotEqual(get, post)
    }

    /// A Mac whose clock has been set before 1970 must produce a bad signature,
    /// not a crash. `UInt64(timestamp)` would trap here and take the daemon with
    /// it; `UInt64(bitPattern:)` is what the node does.
    func testANegativeTimestampDoesNotTrap() {
        let message = SageRequestSigning.message(
            method: "GET", path: "/health", body: Data(), timestamp: -1, nonce: Data()
        )
        XCTAssertEqual(message.count, 32 + 8)
        XCTAssertEqual(Array(message.suffix(8)), Array(repeating: 0xff, count: 8))
    }

    func testEveryNonceIsFresh() {
        let nonces = (0..<32).map { _ in SageRequestSigning.freshNonce() }
        XCTAssertEqual(nonces.first?.count, 16)
        XCTAssertEqual(Set(nonces).count, nonces.count)
    }

    func testHeadersCarryAllFourFieldsTheNodeReads() {
        let headers = SageRequestSigning.headers(
            method: "GET", path: vectorPath, key: vectorKey,
            timestamp: vectorTimestamp, nonce: Data(0..<16)
        )
        XCTAssertEqual(
            headers?["X-Agent-ID"],
            "03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8"
        )
        XCTAssertEqual(headers?["X-Timestamp"], "1786793100")
        XCTAssertEqual(headers?["X-Nonce"], "000102030405060708090a0b0c0d0e0f")
        XCTAssertEqual(headers?["X-Signature"]?.count, 128)
    }

    /// A key file that is neither a seed nor a seed-plus-public-key is refused
    /// rather than truncated into something that signs as a different agent.
    func testAKeyFileOfTheWrongLengthIsRefused() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("agent.key")
        try Data(repeating: 7, count: 48).write(to: url)
        XCTAssertNil(SageRequestSigning.applianceKey(at: url))
    }

    func testAThirtyTwoByteSeedLoads() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("agent.key")
        try Data(0..<32).write(to: url)
        let key = SageRequestSigning.applianceKey(at: url)
        XCTAssertEqual(
            key.map { hex($0.publicKey.rawRepresentation) },
            "03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8"
        )
    }

    /// The 64-byte form is seed followed by public key, and taking the first 32
    /// must derive the same agent as the seed alone — otherwise the same
    /// appliance would sign as two different agents depending on which shape its
    /// node happened to write.
    func testTheSixtyFourByteFormDerivesTheSameAgent() throws {
        let directory = try temporaryDirectory()
        let seedOnly = directory.appendingPathComponent("seed.key")
        let full = directory.appendingPathComponent("full.key")
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
        try Data(0..<32).write(to: seedOnly)
        try (Data(0..<32) + key.publicKey.rawRepresentation).write(to: full)

        XCTAssertEqual(
            SageRequestSigning.applianceKey(at: seedOnly)?.publicKey.rawRepresentation,
            SageRequestSigning.applianceKey(at: full)?.publicKey.rawRepresentation
        )
    }

    // MARK: - Reading the stream

    /// Captured verbatim from the owner's live 11.18.12 node, signed as the
    /// appliance key `74140c2d…`, 15 August 2026.
    func testTheLiveNodesFirstFrameParses() {
        var reader = MessageWakeReader()
        XCTAssertNil(reader.accept(line: "id: 1"))
        XCTAssertNil(reader.accept(line: "event: wake"))
        XCTAssertNil(reader.accept(line: #"data: {"version":1,"seq":1,"pending":true}"#))
        XCTAssertEqual(reader.accept(line: ""), MessageWake(seq: 1, pending: true))
        XCTAssertEqual(reader.lastEventID, 1)
    }

    /// The heartbeat is the reason a live-but-idle stream is distinguishable
    /// from a dead one. A reader that treated it as an event would announce a
    /// wake every fifteen seconds forever.
    ///
    /// This pins the observable contract rather than one line of the parser:
    /// removing the explicit comment guard leaves this green, because a comment
    /// line's field name parses as empty and the `default:` case ignores it
    /// too. That is recorded in `MessageWakeReader` so the two nets are not
    /// mistaken for one.
    func testAHeartbeatCommentIsNotAWake() {
        var reader = MessageWakeReader()
        XCTAssertNil(reader.accept(line: ": heartbeat"))
        XCTAssertNil(reader.accept(line: ""))
        XCTAssertNil(reader.lastEventID)
    }

    /// A heartbeat arriving mid-event must not discard the event being
    /// assembled. SAGE does not currently interleave them; nothing stops it.
    func testAHeartbeatMidEventDoesNotDiscardIt() {
        var reader = MessageWakeReader()
        _ = reader.accept(line: "event: wake")
        _ = reader.accept(line: ": heartbeat")
        _ = reader.accept(line: #"data: {"seq":9,"pending":true}"#)
        XCTAssertEqual(reader.accept(line: ""), MessageWake(seq: 9, pending: true))
    }

    /// The blank line dispatches, not the data line. Mutate the reader to
    /// dispatch on `data:` and this reddens.
    func testAnEventWithNoBlankLineIsNotYetDispatched() {
        var reader = MessageWakeReader()
        _ = reader.accept(line: "event: wake")
        XCTAssertNil(reader.accept(line: #"data: {"seq":4,"pending":true}"#))
    }

    /// Some other event on the same stream is not a wake. There is none today;
    /// this is what stops the first one that appears from being announced as
    /// mail.
    func testAnEventThatIsNotAWakeIsIgnored() {
        var reader = MessageWakeReader()
        _ = reader.accept(line: "event: something-else")
        _ = reader.accept(line: #"data: {"seq":3,"pending":true}"#)
        XCTAssertNil(reader.accept(line: ""))
    }

    func testMultipleDataLinesJoinWithNewlines() {
        var reader = MessageWakeReader()
        _ = reader.accept(line: "event: wake")
        _ = reader.accept(line: #"data: {"seq":12,"#)
        _ = reader.accept(line: #"data: "pending":false}"#)
        XCTAssertEqual(reader.accept(line: ""), MessageWake(seq: 12, pending: false))
    }

    /// A wake whose `pending` could not be read means "go and look", not
    /// "ignore" — the check that follows is idempotent, so the safe direction is
    /// to run it.
    func testAWakeWithNoPendingFieldIsTreatedAsPending() {
        var reader = MessageWakeReader()
        _ = reader.accept(line: "event: wake")
        _ = reader.accept(line: #"data: {"version":1,"seq":5}"#)
        XCTAssertEqual(reader.accept(line: ""), MessageWake(seq: 5, pending: true))
    }

    func testMalformedJSONIsNotAWake() {
        var reader = MessageWakeReader()
        _ = reader.accept(line: "event: wake")
        _ = reader.accept(line: "data: {not json")
        XCTAssertNil(reader.accept(line: ""))
    }

    /// Exactly one leading space is framing. Two means the second is content,
    /// which for JSON is harmless and for the id would not parse.
    func testOnlyOneLeadingSpaceIsStripped() {
        var reader = MessageWakeReader()
        _ = reader.accept(line: "id:  7")
        XCTAssertNil(reader.lastEventID)
        _ = reader.accept(line: "id: 7")
        XCTAssertEqual(reader.lastEventID, 7)
    }

    /// The reader must be reusable across events on one connection, which is
    /// what a stream that stays open for hours actually does.
    func testTheReaderResetsBetweenEvents() {
        var reader = MessageWakeReader()
        _ = reader.accept(line: "id: 1")
        _ = reader.accept(line: "event: wake")
        _ = reader.accept(line: #"data: {"seq":1,"pending":true}"#)
        XCTAssertEqual(reader.accept(line: ""), MessageWake(seq: 1, pending: true))

        _ = reader.accept(line: "id: 2")
        _ = reader.accept(line: "event: wake")
        _ = reader.accept(line: #"data: {"seq":2,"pending":false}"#)
        XCTAssertEqual(reader.accept(line: ""), MessageWake(seq: 2, pending: false))
        XCTAssertEqual(reader.lastEventID, 2)
    }

    // MARK: - Splitting the bytes

    private func lines(of text: String) -> [String] {
        var splitter = MessageWakeLineSplitter()
        return Array(text.utf8).compactMap { splitter.accept(byte: $0) }
    }

    /// **The empty line is a line.** This is the one Foundation's
    /// `AsyncLineSequence` drops, and dropping it silently disabled the entire
    /// feature against a node that was behaving perfectly.
    func testTwoNewlinesProduceAnEmptyLine() {
        XCTAssertEqual(lines(of: "data: x\n\n"), ["data: x", ""])
    }

    func testAFullFrameSplitsIntoFourLinesEndingInABlank() {
        XCTAssertEqual(
            lines(of: "id: 1\nevent: wake\ndata: {}\n\n"),
            ["id: 1", "event: wake", "data: {}", ""]
        )
    }

    /// `\r\n` is legal SSE framing. The node sends `\n`, so this is about not
    /// leaving a stray carriage return inside a field value if that changes.
    func testCarriageReturnsAreStripped() {
        XCTAssertEqual(lines(of: "event: wake\r\n\r\n"), ["event: wake", ""])
    }

    /// A line is only emitted once its terminator arrives — a half-received
    /// frame must not be parsed as a whole one.
    func testAnUnterminatedLineIsNotEmitted() {
        XCTAssertEqual(lines(of: "data: {\"seq\":1"), [])
    }

    /// Bytes arrive in whatever pieces the network hands over, so the same
    /// input split anywhere must produce the same lines.
    func testTheSplitterDoesNotCareWhereTheChunksFall() {
        let frame = "id: 7\nevent: wake\ndata: {}\n\n"
        XCTAssertEqual(lines(of: frame), ["id: 7", "event: wake", "data: {}", ""])

        var splitter = MessageWakeLineSplitter()
        var collected: [String] = []
        for byte in Array(frame.utf8) {
            if let line = splitter.accept(byte: byte) { collected.append(line) }
        }
        XCTAssertEqual(collected, ["id: 7", "event: wake", "data: {}", ""])
    }

    /// UTF-8 that straddles a chunk boundary must not be mangled — the splitter
    /// decodes a whole line at a time rather than a byte at a time.
    func testMultiByteCharactersSurvive() {
        XCTAssertEqual(lines(of: "data: \u{201C}caf\u{00E9}\u{201D}\n"), ["data: \u{201C}caf\u{00E9}\u{201D}"])
    }

    // MARK: - The latch

    /// Reading does not clear. This is the whole reason the latch is a type
    /// rather than a `Bool` passed around: a wake that arrives during quiet
    /// hours must still be there in the morning.
    func testReadingTheLatchDoesNotClearIt() async {
        let latch = MessageWakeLatch()
        await latch.wake()
        var seen = await latch.isWoken()
        XCTAssertTrue(seen)
        seen = await latch.isWoken()
        XCTAssertTrue(seen)
        await latch.clear()
        seen = await latch.isWoken()
        XCTAssertFalse(seen)
    }

    // MARK: - What a wake is allowed to override

    private var alwaysOn: ProactivePreferences {
        ProactivePreferences(isOn: true, everyMinutes: 60, quietFrom: 0, quietUntil: 0)
    }

    /// The point of the feature: a message arriving does not wait out the
    /// owner's hour.
    func testAWakeChecksBeforeTheIntervalHasElapsed() {
        let now = Date()
        let justChecked = now.addingTimeInterval(-60)
        XCTAssertFalse(
            ProactiveSchedule.isDue(now: now, lastChecked: justChecked, preferences: alwaysOn)
        )
        XCTAssertTrue(
            ProactiveSchedule.isDue(
                now: now, lastChecked: justChecked, preferences: alwaysOn, wokenByMessage: true
            )
        )
    }

    /// **A wake does not switch the feature on.** An owner who turned proactive
    /// checks off gets silence, and a message arriving is not consent.
    func testAWakeDoesNotOverrideTheOwnersSwitch() {
        let off = ProactivePreferences(isOn: false, everyMinutes: 60)
        XCTAssertFalse(
            ProactiveSchedule.isDue(
                now: Date(), lastChecked: nil, preferences: off, wokenByMessage: true
            )
        )
    }

    /// **A wake does not break quiet hours.** An appliance that pings at 3am
    /// because a stranger answered an errand is a worse appliance, and nothing
    /// is lost: the latch is not cleared by a tick that declines.
    func testAWakeDoesNotOverrideQuietHours() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let threeInTheMorning = calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 15, hour: 3)
        )!
        let quiet = ProactivePreferences(
            isOn: true, everyMinutes: 60, quietFrom: 22, quietUntil: 8
        )
        XCTAssertFalse(
            ProactiveSchedule.isDue(
                now: threeInTheMorning, lastChecked: nil, preferences: quiet,
                calendar: calendar, wokenByMessage: true
            )
        )
    }

    // MARK: - Reconnect policy

    /// Doubling, and capped below the poll interval it accelerates. A backoff
    /// allowed to grow past fifteen minutes would make this component worse
    /// than absent.
    func testBackoffDoublesAndIsCappedAtAMinute() {
        XCTAssertEqual(MessageWakeBus.backoff(after: 1), 1)
        XCTAssertEqual(MessageWakeBus.backoff(after: 2), 2)
        XCTAssertEqual(MessageWakeBus.backoff(after: 3), 4)
        XCTAssertEqual(MessageWakeBus.backoff(after: 20), 60)
        XCTAssertLessThan(
            MessageWakeBus.backoff(after: 99),
            Double(ProactivePreferences.fastest) * 60
        )
    }

    /// Stable across reconnects — a fresh one per connection would lock the
    /// appliance out of its own wake lease for five minutes after every drop —
    /// and inside the node's 128-byte ceiling.
    func testTheConsumerIDIsStableAndWithinTheNodesCeiling() {
        let first = MessageWakeBus.defaultConsumerID(for: vectorKey)
        let second = MessageWakeBus.defaultConsumerID(for: vectorKey)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, "mynah-voiced-03a107bf")
        XCTAssertLessThanOrEqual(first.utf8.count, 128)
    }

    func testADifferentApplianceGetsADifferentConsumerID() throws {
        let other = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(repeating: 9, count: 32)
        )
        XCTAssertNotEqual(
            MessageWakeBus.defaultConsumerID(for: vectorKey),
            MessageWakeBus.defaultConsumerID(for: other)
        )
    }

    /// A wake from a stranger's node would make this appliance announce someone
    /// else's mail, so an override that is not this machine is ignored rather
    /// than honoured.
    func testANonLoopbackOverrideIsIgnored() {
        XCTAssertEqual(
            MessageWakeBus.defaultEndpoint(environment: ["SAGE_API_URL": "http://10.0.0.4:8080"]),
            URL(string: "http://127.0.0.1:8080")!
        )
        XCTAssertEqual(
            MessageWakeBus.defaultEndpoint(environment: ["SAGE_API_URL": "http://127.0.0.1:9999"]),
            URL(string: "http://127.0.0.1:9999")!
        )
        XCTAssertEqual(
            MessageWakeBus.defaultEndpoint(environment: [:]),
            URL(string: "http://127.0.0.1:8080")!
        )
    }

    /// Constructing against a node that is not this machine fails rather than
    /// dialling it.
    func testTheBusRefusesANonLoopbackEndpoint() {
        XCTAssertNil(
            MessageWakeBus(
                endpoint: URL(string: "http://example.com:8080")!,
                key: vectorKey
            )
        )
    }

    /// **The path is built once and used for both the URL and the signature.**
    ///
    /// This is the failure mode `SageRequestSigning` is written around, and the
    /// only one that produces a 401 with nothing in it about what went wrong.
    /// Mutate `connectAndRead` to sign `"/v1/messages/wake"` while requesting
    /// the decorated path — or to build the string a second time — and this
    /// reddens.
    func testTheSignedPathIsTheRequestedPath() throws {
        let source = try busSource()
        let builds = source.components(separatedBy: "\"/v1/messages/wake").count - 1
        XCTAssertEqual(
            builds, 1,
            "the wake path is written in more than one place, so the signed and "
                + "requested paths can drift apart"
        )
        XCTAssertTrue(
            source.contains("let path = Self.wakePath(consumerID: consumerID, afterSeq: afterSeq)"),
            "the connection no longer builds its path from the single builder"
        )
        XCTAssertTrue(
            source.contains("path: path,"),
            "the signature no longer covers the path the request was built from"
        )
    }

    func testTheWakePathCarriesTheCursorAndConsumer() {
        XCTAssertEqual(
            MessageWakeBus.wakePath(consumerID: "mynah-voiced-03a107bf", afterSeq: 42),
            "/v1/messages/wake?consumer_id=mynah-voiced-03a107bf&after_seq=42"
        )
    }

    /// A fresh appliance asks from zero, which makes the node report its
    /// current state at once rather than only what happens next — so work that
    /// was already waiting at startup is learned about immediately instead of
    /// on the first poll.
    func testAFreshBusAsksFromZero() {
        XCTAssertTrue(
            MessageWakeBus.wakePath(consumerID: "c", afterSeq: 0).hasSuffix("after_seq=0")
        )
    }

    // MARK: - That the daemon actually dials it

    /// `main.swift` is an executable target and cannot be imported, so the
    /// wiring is asserted by scanning it — the precedent
    /// `AfterTheCallTests` and `SignalOrWhatsAppOrBothTests` already set.
    ///
    /// Without this the whole feature can be perfect and unreachable: every
    /// type above is exercised by the tests in this file whether or not one
    /// line in the daemon ever constructs them.
    func testTheDaemonStartsTheWakeBusAndFeedsTheWatch() throws {
        let main = try daemonSource()

        XCTAssertTrue(
            main.contains("MessageWakeBus(log:"),
            "the daemon never constructs a wake bus, so nothing dials the stream"
        )
        XCTAssertTrue(
            main.contains("await bus.run { _ in await wakeLatch.wake() }"),
            "the bus is constructed but its wakes are not latched"
        )
        XCTAssertTrue(
            main.contains("wakeLatch: wakeLatch"),
            "the latch is set but never handed to the watch, so nothing reads it"
        )
        XCTAssertTrue(
            main.contains("defer { wakeTask.cancel() }"),
            "the wake stream outlives the daemon, holding the node's lease after shutdown"
        )
        XCTAssertTrue(
            main.contains("await wakeLatch?.clear()"),
            "a wake is never cleared, so every tick after the first would check the node"
        )
    }

    /// The lease is per agent, and the daemon is the process that can act on a
    /// wake. A second consumer in the window would be refused for five minutes
    /// at a time while being unable to announce anything itself.
    func testOnlyTheDaemonDialsTheWakeBus() throws {
        let window = repositoryRoot().appendingPathComponent("Sources/MynahMac")
        let files = FileManager.default.enumerator(at: window, includingPropertiesForKeys: nil)
        var dialled: [String] = []
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if text.contains("MessageWakeBus(") { dialled.append(url.lastPathComponent) }
        }
        XCTAssertEqual(
            dialled, [],
            "the window dials the wake bus too; it will fight the daemon for the node's lease"
        )
    }

    // MARK: - Helpers

    private func busSource() throws -> String {
        try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/SageVoiceCore/Proactive/MessageWakeBus.swift"),
            encoding: .utf8
        )
    }

    private func daemonSource() throws -> String {
        try String(
            contentsOf: repositoryRoot().appendingPathComponent("Sources/sage-voiced/main.swift"),
            encoding: .utf8
        )
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Signs with the vector key and checks the node's own verification step.
    private func verifies(_ message: Data) -> Bool {
        guard let signature = try? vectorKey.signature(for: message) else { return false }
        return vectorKey.publicKey.isValidSignature(signature, for: message)
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// Nested in a per-test directory: `OwnerOnlyFileSecurity` refuses a
    /// directory the process does not own, and a file written straight into
    /// `NSTemporaryDirectory()` silently fails to persist.
    private func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wake-bus-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

// MARK: - The whole client, against a stubbed stream

/// Serves one canned event stream on loopback, a chunk at a time.
///
/// Exists because the live probe that found the `.lines` defect is not
/// something a suite can run: it needs the owner's node, his key, and a message
/// actually waiting. This covers the same path — signed request out, bytes in,
/// split, parsed, delivered — with none of that.
final class StubWakeStream: URLProtocol, @unchecked Sendable {

    /// What every instance serves. One test at a time, which is why this is
    /// static rather than threaded through the session.
    nonisolated(unsafe) static var body = ""
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        let response = HTTPURLResponse(
            url: request.url!, statusCode: Self.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // Fed in small pieces so a reader that only works on whole-frame
        // delivery fails here rather than in front of the owner.
        for chunk in Array(Self.body.utf8).chunked(into: 7) {
            client?.urlProtocol(self, didLoad: Data(chunk))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubWakeStream.self]
        return URLSession(configuration: configuration)
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

final class MessageWakeBusStreamTests: XCTestCase {

    private var key: Curve25519.Signing.PrivateKey {
        try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
    }

    override func tearDown() {
        StubWakeStream.body = ""
        StubWakeStream.status = 200
        StubWakeStream.lastRequest = nil
        super.tearDown()
    }

    private func bus() throws -> MessageWakeBus {
        try XCTUnwrap(
            MessageWakeBus(
                endpoint: URL(string: "http://127.0.0.1:8080")!,
                key: key,
                consumerID: "test-consumer",
                session: StubWakeStream.session()
            )
        )
    }

    /// **The regression test for the defect the live probe found.**
    ///
    /// The node's frame ends `data: …\n\n`, and the blank line is what
    /// dispatches it. Reading this stream through `AsyncBytes.lines` — which is
    /// what this client did first — never delivers that blank line, so the wake
    /// is assembled and never fired. Swap `MessageWakeLineSplitter` back for
    /// `.lines` in `connectAndRead` and this times out.
    func testAWakeOnTheWireReachesTheCaller() async throws {
        StubWakeStream.body = "id: 4\nevent: wake\ndata: {\"version\":1,\"seq\":4,\"pending\":true}\n\n"
        let bus = try bus()
        let arrived = expectation(description: "onWake called")
        let seen = Locked<MessageWake?>(nil)

        let task = Task {
            await bus.run { wake in
                seen.set(wake)
                arrived.fulfill()
            }
        }
        await fulfillment(of: [arrived], timeout: 5)
        task.cancel()

        XCTAssertEqual(seen.get(), MessageWake(seq: 4, pending: true))
    }

    /// Heartbeats and a non-actionable wake ahead of the real one, because that
    /// is what an idle stream looks like before anything happens.
    func testAWakeArrivesAfterHeartbeatsAndANonPendingWake() async throws {
        StubWakeStream.body = """
        : heartbeat

        id: 1
        event: wake
        data: {"version":1,"seq":1,"pending":false}

        : heartbeat

        id: 2
        event: wake
        data: {"version":1,"seq":2,"pending":true}


        """
        let bus = try bus()
        let arrived = expectation(description: "onWake called")
        let calls = Locked<[MessageWake]>([])

        let task = Task {
            await bus.run { wake in
                calls.mutate { $0.append(wake) }
                arrived.fulfill()
            }
        }
        await fulfillment(of: [arrived], timeout: 5)
        task.cancel()

        // Only the pending one is delivered — a wake reporting nothing
        // claimable must not send the appliance looking.
        XCTAssertEqual(calls.get(), [MessageWake(seq: 2, pending: true)])
    }

    /// The request the node actually receives: signed, and asking from the
    /// cursor with the stable consumer id.
    func testTheRequestIsSignedAndCarriesTheCursor() async throws {
        StubWakeStream.body = "id: 1\nevent: wake\ndata: {\"seq\":1,\"pending\":true}\n\n"
        let bus = try bus()
        let arrived = expectation(description: "onWake called")
        let task = Task { await bus.run { _ in arrived.fulfill() } }
        await fulfillment(of: [arrived], timeout: 5)
        task.cancel()

        let request = try XCTUnwrap(StubWakeStream.lastRequest)
        XCTAssertEqual(
            request.url?.absoluteString,
            "http://127.0.0.1:8080/v1/messages/wake?consumer_id=test-consumer&after_seq=0"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-Agent-ID"),
            "03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Signature")?.count, 128)
        XCTAssertNotNil(request.value(forHTTPHeaderField: "X-Timestamp"))
        XCTAssertNotNil(request.value(forHTTPHeaderField: "X-Nonce"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
    }

    /// A node with no wake route ends the bus rather than retrying forever. The
    /// fifteen-minute poll is the whole mechanism there, which is what it was
    /// before this existed.
    func testANodeWithoutTheRouteStopsTheBus() async throws {
        StubWakeStream.status = 404
        StubWakeStream.body = ""
        let bus = try bus()
        let ending = await bus.run { _ in XCTFail("no wake should arrive") }
        XCTAssertEqual(ending, .unsupportedByNode)
    }
}

/// The smallest possible box for a value two tasks touch.
private final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ new: Value) { lock.lock(); value = new; lock.unlock() }
    func mutate(_ change: (inout Value) -> Void) { lock.lock(); change(&value); lock.unlock() }
}
