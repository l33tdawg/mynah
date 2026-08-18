#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - What a wake is

/// One hint that canonical inbox work was durably inserted for this appliance.
///
/// **Payload-free on purpose, and the emptiness is the contract.** SAGE's own
/// note on the route says the JSON contains exactly `version`, `seq` and
/// `pending` and "never contains a message ID, sender, intent, payload, count,
/// proof, receipt, delivery, read, claim, result, or presence field". So this
/// type cannot grow a `from` or a `count` later without the node having changed
/// first, and a reader that wants any of that still has to go and ask.
public struct MessageWake: Sendable, Equatable {

    /// The recipient's durable sequence. Monotonic, and the cursor a reconnect
    /// resumes from.
    public let seq: UInt64

    /// Whether anything is *currently* claimable, which is not the same as
    /// "this wake was about something new".
    ///
    /// Worth the distinction: the node emits the current state on connect, so a
    /// reconnect against unfinished work re-announces `pending: true` at a
    /// sequence already seen. Acting on `pending` rather than on novelty is
    /// what makes that harmless — the check that follows is idempotent, and the
    /// alternative (trusting the sequence to mean "new") strands work across a
    /// restart.
    public let pending: Bool

    public init(seq: UInt64, pending: Bool) {
        self.seq = seq
        self.pending = pending
    }
}

// MARK: - Reading the stream

/// Splits a byte stream into lines, **keeping the empty ones**.
///
/// ## Why this is not `AsyncBytes.lines`
///
/// It was, and the whole feature was silently dead. Foundation's
/// `AsyncLineSequence` does not yield an empty line: a `\n\n` reaches the
/// consumer as one delimiter, not as a line terminator followed by a blank
/// line. Every other line-oriented use of it is right to do that. SSE is the
/// case where it is catastrophic, because **the blank line is the dispatch** —
/// an event is not delivered by its `data:` line, it is delivered by the empty
/// line that follows.
///
/// Measured against the owner's live node on 15 August 2026, reading
/// `GET /v1/messages/wake` through `.lines`:
///
///     t=0.01s  [id: 1]
///     t=0.01s  [event: wake]
///     t=0.01s  [data: {"version":1,"seq":1,"pending":false}]
///     t=15.01s [: heartbeat]
///
/// The blank line between the event and the heartbeat never arrived. The node
/// was behaving perfectly, the reader below was correct, and no wake was ever
/// dispatched — the failure of the whole component was one absent empty string.
/// A unit test over the reader passes either way, because a test feeds it the
/// blank line the transport was eating.
public struct MessageWakeLineSplitter: Sendable {

    private var buffer: [UInt8] = []

    public init() {}

    /// Returns a line when this byte ended one. `\r\n` and `\n` both end a
    /// line, and a lone `\r` does not — the SSE grammar allows all three, and
    /// the node sends `\n`, so the third is left alone rather than guessed at.
    public mutating func accept(byte: UInt8) -> String? {
        guard byte == 0x0A else {
            buffer.append(byte)
            return nil
        }
        if buffer.last == 0x0D { buffer.removeLast() }
        let line = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll(keepingCapacity: true)
        return line
    }
}

/// Turns server-sent-event lines into wakes.
///
/// Pure and incremental so the framing can be tested without a node — which
/// matters more than it sounds, because the two things most likely to go wrong
/// here are both invisible to a happy-path integration test: a heartbeat
/// comment being mistaken for an event, and a dispatch that never fires because
/// the blank-line terminator was missed.
public struct MessageWakeReader: Sendable {

    private var eventName = ""
    private var data = ""

    /// The last `id:` seen, which is the cursor a reconnect resumes from.
    ///
    /// Tracked separately from the parsed payload's `seq` even though SAGE sets
    /// them to the same number, because SSE says the id is what a client echoes
    /// back in `Last-Event-ID` and the payload is application content. They
    /// agree today; a reader that conflated them would resume from the wrong
    /// place on the day they stop agreeing.
    public private(set) var lastEventID: UInt64?

    public init() {}

    /// Feed one line, stripped of its newline. Returns a wake when the line
    /// completed one.
    public mutating func accept(line: String) -> MessageWake? {
        // A comment. SAGE sends `: heartbeat` every fifteen seconds so a live
        // stream with nothing to say is distinguishable from a dead one.
        //
        // **This is belt and braces, and saying so is the point.** A comment
        // line's first colon is at index zero, so the field name parses as the
        // empty string and the `default:` case below already ignores it —
        // deleting this line changes no behaviour today, which a mutation test
        // proved rather than assumed. It stays because it is the SSE grammar's
        // own rule and states the intent at the top where a reader looks for
        // it. Anyone narrowing that `default:` later needs this to be here.
        if line.hasPrefix(":") { return nil }

        // The blank line is the dispatch, not the `data:` line — an event with
        // no terminator is still being assembled.
        if line.isEmpty { return dispatch() }

        let field: String
        var value: String
        if let colon = line.firstIndex(of: ":") {
            field = String(line[line.startIndex..<colon])
            value = String(line[line.index(after: colon)...])
            // Exactly one leading space is part of the framing, not the value.
            if value.hasPrefix(" ") { value.removeFirst() }
        } else {
            field = line
            value = ""
        }

        switch field {
        case "event":
            eventName = value
        case "data":
            // Multiple `data:` lines join with newlines, per the SSE grammar.
            data += data.isEmpty ? value : "\n" + value
        case "id":
            if let parsed = UInt64(value) { lastEventID = parsed }
        default:
            // `retry:` and anything unrecognised are ignored by design; an
            // unknown field must never discard the event being assembled.
            break
        }
        return nil
    }

    private mutating func dispatch() -> MessageWake? {
        defer {
            eventName = ""
            data = ""
        }
        // A dispatched-but-empty buffer is what a doubled blank line produces.
        guard !data.isEmpty else { return nil }
        guard eventName == "wake" else { return nil }
        guard let payload = data.data(using: .utf8) else { return nil }
        guard
            let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { return nil }

        // `seq` is required; `pending` is read defensively because a wake whose
        // pending flag failed to parse should mean "go and look", not "ignore".
        guard let seq = (object["seq"] as? NSNumber)?.uint64Value else { return nil }
        let pending = (object["pending"] as? Bool) ?? true
        return MessageWake(seq: seq, pending: pending)
    }
}

// MARK: - The latch

/// "Something arrived; check on the next tick."
///
/// **Deliberately not a queue, and deliberately not cleared by reading it.**
/// The proactive loop is allowed to decline to check — the owner can have the
/// whole feature switched off, and quiet hours suppress everything until
/// morning. A latch that cleared on read would drop a 3am message on the floor,
/// and it would do so silently, which is the failure this whole feature exists
/// to stop. So the flag survives every tick that declines, and is cleared only
/// by the check that actually ran.
public actor MessageWakeLatch {

    private var woken = false

    public init() {}

    public func wake() { woken = true }

    /// Whether a check is owed. Does not clear.
    public func isWoken() -> Bool { woken }

    /// Called after a check has actually reached the node.
    public func clear() { woken = false }
}

// MARK: - The bus

/// Holds `GET /v1/messages/wake` open and reports what arrives.
///
/// ## What this replaces
///
/// Nothing — it shortens a wait. `ProactiveWatch` already polls, on an interval
/// the owner chooses and defaults to fifteen minutes, and it keeps doing so:
/// this bus is an accelerator, not a transport, and the node's own note is
/// explicit that a wake is "a payload-free, exact-recipient hint" after which
/// "the supervisor still calls the canonical inbox operation to claim work".
/// Every guarantee about *what* the appliance says still comes from the check
/// that follows. If this stream never connects, Mynah behaves exactly as it did
/// before, fifteen minutes later.
///
/// That is the reason every failure below backs off rather than escalating.
/// There is no failure of this component that should reach the owner, because
/// there is no failure of it that costs them anything but promptness.
///
/// ## The lease, which is why `consumerID` must be stable
///
/// One agent holds at most one wake lease. A reconnect presenting the *same*
/// `consumer_id` supersedes its own stale stream; a *different* one is refused
/// with `409` until the old lease expires, which takes five minutes. So a
/// consumer id regenerated per connection would lock the appliance out of its
/// own wake bus for five minutes after every drop — the exact opposite of what
/// this is for. It is derived once per process from the appliance id and left
/// alone.
public actor MessageWakeBus {

    /// Why the bus stopped for good, when it did.
    public enum Ending: Error, Sendable, Equatable {
        /// No key, or an endpoint that is not this machine. Nothing to retry.
        case notConfigured
        /// The node has no wake route — anything before SAGE 11.18.12. The
        /// fifteen-minute poll is the whole mechanism on such a node, which is
        /// what it was before this existed, so this is a log line and not a
        /// problem.
        case unsupportedByNode
    }

    private let endpoint: URL
    private let consumerID: String
    private let key: Curve25519.Signing.PrivateKey
    private let session: URLSession
    private let log: @Sendable (String) -> Void

    /// The cursor. Starts at zero, which asks the node for the current state
    /// immediately rather than only for what happens next — so an appliance
    /// that starts up with work already waiting learns about it at once instead
    /// of on the first poll.
    private var afterSeq: UInt64 = 0

    /// Consecutive failures, for the backoff. Reset by any successful connect.
    private var failures = 0

    public init?(
        endpoint: URL? = nil,
        key: Curve25519.Signing.PrivateKey? = nil,
        consumerID: String? = nil,
        session: URLSession? = nil,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        guard let key = key ?? SageRequestSigning.applianceKey() else { return nil }
        let base = endpoint ?? Self.defaultEndpoint()
        guard LoopbackSecurity.isLoopback(base) else { return nil }
        self.endpoint = base
        self.key = key
        self.consumerID = consumerID ?? Self.defaultConsumerID(for: key)
        // Thirty seconds of silence against a fifteen-second heartbeat: long
        // enough that one missed beat is not a disconnection, short enough that
        // a node that died without closing the socket is noticed promptly.
        self.session = session ?? LoopbackSecurity.makeStreamingSession(idleTimeout: 30)
        self.log = log
    }

    /// The same default and the same override `CerebrumTaskSource` uses, and
    /// ignored for the same reason unless it points at this machine: a wake
    /// from a stranger's node would make this appliance announce someone else's
    /// mail.
    public static func defaultEndpoint(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let fallback = URL(string: "http://127.0.0.1:8080")!
        let configured = environment["SAGE_API_URL"].flatMap(URL.init(string:))
        return LoopbackSecurity.isLoopback(configured) ? (configured ?? fallback) : fallback
    }

    /// The request line, and the exact string that gets signed.
    nonisolated static func wakePath(consumerID: String, afterSeq: UInt64) -> String {
        "/v1/messages/wake?consumer_id=\(consumerID)&after_seq=\(afterSeq)"
    }

    /// Stable across reconnects, distinct across machines, and inside the
    /// node's 128-byte ceiling.
    static func defaultConsumerID(for key: Curve25519.Signing.PrivateKey) -> String {
        let agent = key.publicKey.rawRepresentation
            .prefix(4).map { String(format: "%02x", $0) }.joined()
        return "mynah-voiced-\(agent)"
    }

    /// Runs until cancelled, or until the node says this will never work.
    ///
    /// `onWake` is called for every wake that reports work pending. It is not
    /// called for a wake that reports none, which happens when the last item
    /// was claimed elsewhere between the insert and this stream reading state.
    @discardableResult
    public func run(onWake: @Sendable @escaping (MessageWake) async -> Void) async -> Ending? {
        while !Task.isCancelled {
            do {
                try await connectAndRead(onWake: onWake)
                // A clean end of stream is ordinary: the node closed, or the
                // five-minute lease turned over. Reconnect without counting it
                // as a failure, but still pause, so a node that closes
                // instantly cannot become a spin loop.
                try await Task.sleep(for: .seconds(1))
            } catch let ending as Ending {
                log("[wake] \(ending == .notConfigured ? "not configured" : "node has no wake bus")"
                    + "; the periodic check is the whole mechanism")
                return ending
            } catch is CancellationError {
                return nil
            } catch {
                failures += 1
                let pause = Self.backoff(after: failures)
                log("[wake] stream ended (\(error.localizedDescription)); retrying in \(Int(pause))s")
                try? await Task.sleep(for: .seconds(pause))
            }
        }
        return nil
    }

    /// One connection, read to its end.
    private func connectAndRead(onWake: @Sendable @escaping (MessageWake) async -> Void) async throws {
        // Built once and used twice — for the URL and for the signature — so
        // the two cannot drift apart. They must be byte-identical: the node
        // rebuilds the signed path as `r.URL.Path + "?" + r.URL.RawQuery`, so a
        // path that is signed and then decorated is a 401 that says nothing
        // about queries. See `SageRequestSigning`.
        let path = Self.wakePath(consumerID: consumerID, afterSeq: afterSeq)
        guard let url = URL(string: endpoint.absoluteString.trimmingTrailingSlash() + path) else {
            throw Ending.notConfigured
        }
        try LoopbackSecurity.requireLoopback(url)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // Signed over the path *including* the query, because that is what the
        // node rebuilds and verifies. See `SageRequestSigning`.
        guard let headers = SageRequestSigning.headers(
            method: "GET",
            path: path,
            key: key,
            timestamp: Int64(Date().timeIntervalSince1970),
            nonce: SageRequestSigning.freshNonce()
        ) else { throw Ending.notConfigured }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }

        // `PortableByteStream` and not `session.bytes(for:)` directly: that
        // method is Darwin-only, and the substitute Foundation offers elsewhere
        // returns the whole body at once — on a stream the node never closes,
        // that is a call that returns at shutdown. On a Mac this *is*
        // `session.bytes(for:)`; see the file for what it is off one.
        let (stream, response) = try await PortableByteStream.open(request, on: session)
        try LoopbackSecurity.verifyResponseOrigin(response, expected: url)
        guard let http = response as? HTTPURLResponse else { throw WakeFailure.unreadable }

        switch http.statusCode {
        case 200:
            break
        case 404, 501:
            // No such route, or a store that cannot serve wakes. Both mean this
            // node will not answer however long we wait.
            throw Ending.unsupportedByNode
        case 409:
            try await handleConflict(http)
            return
        case 401:
            // Not a permissions problem to surface: on this route the appliance
            // is the only possible recipient, so a 401 is a signing fault in
            // this process. Loud in the log, silent to the owner, and retried
            // slowly in case it is a clock that has not settled yet.
            failures += 1
            log("[wake] the node rejected the appliance's signature; retrying slowly")
            try await Task.sleep(for: .seconds(Self.backoff(after: failures)))
            return
        default:
            throw WakeFailure.status(http.statusCode)
        }

        failures = 0
        log("[wake] listening from seq \(afterSeq)")

        var splitter = MessageWakeLineSplitter()
        var reader = MessageWakeReader()
        // Byte at a time, deliberately. See `MessageWakeLineSplitter`: the
        // convenient `.lines` swallows the blank line that dispatches an SSE
        // event. This stream carries a few dozen bytes a minute, so the cost of
        // not using it is nothing.
        for try await byte in stream {
            guard !Task.isCancelled else { throw CancellationError() }
            guard let line = splitter.accept(byte: byte) else { continue }
            guard let wake = reader.accept(line: line) else { continue }
            // Advance before acting. A wake that is announced and then not
            // recorded would be re-announced on the next reconnect; the other
            // order costs at most one missed hint, which the periodic check
            // picks up anyway.
            afterSeq = reader.lastEventID ?? wake.seq
            // Logged before the pending test, not after. A wake carrying
            // `pending: false` is the ordinary result of the work being claimed
            // between the node inserting it and this stream reading state, and
            // it is indistinguishable in a log from no wake at all unless it
            // says so — which is exactly the confusion the first live probe of
            // this client ran into.
            log("[wake] seq \(wake.seq), pending \(wake.pending)")
            guard wake.pending else { continue }
            await onWake(wake)
        }
    }

    /// The two conflicts the node distinguishes, which need opposite responses.
    private func handleConflict(_ response: HTTPURLResponse) async throws {
        // "Wake cursor is ahead" — this appliance resumed from a sequence the
        // node no longer has, which is what a restored backup or a rebuilt node
        // looks like. Rewinding to zero is always safe: the sequence is a
        // cursor into hints, not into work, and the check that follows a wake
        // reads the real inbox.
        //
        // Told apart by the `Retry-After` the lease conflict carries and the
        // cursor conflict does not, rather than by matching English in a title.
        if response.value(forHTTPHeaderField: "Retry-After") == nil {
            log("[wake] cursor was ahead of the node; rewinding to the start")
            afterSeq = 0
            try await Task.sleep(for: .seconds(1))
            return
        }
        // Another runtime holds the lease — ordinarily this appliance's own
        // previous stream, still inside its five-minute expiry after an
        // unclean exit. Waiting is the entire fix.
        failures += 1
        let pause = max(2, Self.backoff(after: failures))
        log("[wake] another consumer holds the wake lease; retrying in \(Int(pause))s")
        try await Task.sleep(for: .seconds(pause))
    }

    /// Doubling, capped at a minute.
    ///
    /// The cap matters more than the curve: this is an accelerator over a
    /// fifteen-minute poll, so a backoff allowed to grow past the poll interval
    /// would make the component worse than absent.
    nonisolated static func backoff(after failures: Int) -> Double {
        min(60, pow(2, Double(max(0, failures - 1))))
    }

    enum WakeFailure: Error, LocalizedError {
        case unreadable
        case status(Int)

        var errorDescription: String? {
            switch self {
            case .unreadable: return "the node's reply was not HTTP"
            case .status(let code): return "HTTP \(code)"
            }
        }
    }
}

private extension String {
    func trimmingTrailingSlash() -> String {
        hasSuffix("/") ? String(dropLast()) : self
    }
}
