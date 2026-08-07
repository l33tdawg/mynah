import Foundation

/// Reads inbound WhatsApp messages from the bridge, and acknowledges them.
///
/// Deliberately the same shape as `SignalClient`: an actor that owns a
/// connection, reconnects with backoff, refuses everything not on its allowlist
/// before the caller can see it, and hands out messages on an `AsyncStream`.
/// The two transports look alike on purpose — the daemon consuming them should
/// not have to hold two different mental models of "a message arrived".
///
/// It reuses `SignalLineSocket` outright. That is the payoff for making the
/// bridge speak newline-delimited JSON over a UNIX socket rather than keeping
/// upstream's loopback HTTP: no second socket implementation, no second set of
/// framing bugs, and the path-length check that file already had.
///
/// **What is different, and it is the important part.** Signal's daemon pushes
/// and forgets; this one keeps every message on disk until it is acknowledged.
/// So `incomingMessages` is only half the contract. The other half is
/// `acknowledge(sequence:)`, and nothing retires a message except that call.
///
///   * Never call it, and every message is redelivered on the next connection.
///   * Call it too early — on receipt, say — and a crash mid-turn loses the
///     message exactly the way upstream's design did, with the spool
///     underneath it giving false comfort.
///
/// The right moment is when the turn is durably recorded and the answer sent.
/// At-least-once is the deliberate trade: a message answered twice is
/// embarrassing, a message answered never is a broken product.
public actor WhatsAppClient {

    public struct Configuration: Sendable {
        /// The bridge's events socket. `0600`, so this is also the access check.
        public var socketPath: String
        /// The security boundary. No default — it must be a deliberate act.
        public var allowlist: WhatsAppSenderAllowlist
        public var backoff: SignalBackoffPolicy
        public var logger: WhatsAppTransportLogger

        public init(
            allowlist: WhatsAppSenderAllowlist,
            socketPath: String = WhatsAppClient.defaultSocketPath(),
            backoff: SignalBackoffPolicy = SignalBackoffPolicy(),
            logger: @escaping WhatsAppTransportLogger = WhatsAppTransportLog.standardError
        ) {
            self.allowlist = allowlist
            self.socketPath = socketPath
            self.backoff = backoff
            self.logger = logger
        }
    }

    /// `$TMPDIR`, not Application Support, and the reason is a kernel limit
    /// rather than taste: `sockaddr_un.sun_path` is 104 bytes, and
    /// `~/Library/Application Support/SAGE Voice Bridge/WhatsApp/events.sock`
    /// is 82 of them on the account this was written on — under the limit, but
    /// it grows with the length of the home directory and a longer username is
    /// enough to break it. `$TMPDIR` is per-user, `0700` and short.
    ///
    /// Nothing is kept here. The spool, which must survive a restart, stays in
    /// Application Support; a socket has no state to lose.
    public static func defaultSocketPath() -> String {
        let base = ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp"
        return URL(fileURLWithPath: base)
            .appendingPathComponent("mynah-whatsapp.sock")
            .path
    }

    private let configuration: Configuration
    private let continuation: AsyncStream<WhatsAppIncomingMessage>.Continuation

    /// Allowlisted messages only. One consumer; iterate it from the agent loop.
    public nonisolated let incomingMessages: AsyncStream<WhatsAppIncomingMessage>

    private var socket: SignalLineSocket?
    private var supervisor: Task<Void, Never>?
    private var isStopped = false

    /// What may be acknowledged, and what is still being answered.
    ///
    /// The bridge speaks a watermark and the product does not; keeping the two
    /// apart is `WhatsAppAcknowledgementLedger`'s whole job, and the reason it
    /// is a separate type is written down there.
    private var ledger = WhatsAppAcknowledgementLedger()

    public init(configuration: Configuration) {
        self.configuration = configuration
        var continuation: AsyncStream<WhatsAppIncomingMessage>.Continuation!
        // **Unbounded, and the 256 it replaces was a silent message shredder.**
        //
        // `bufferingNewest(256)` discards the OLDEST element when the consumer
        // falls behind, and `yield`'s result was thrown away. `deliver` runs
        // just before this, so a discarded element is a sequence the ledger
        // believes is in flight with nothing left alive to settle it: the
        // contiguous-run watermark never passes it, the spool never truncates,
        // and at 10,000 unacknowledged records every further inbound message is
        // refused outright. One dropped element costs the channel, not a
        // message.
        //
        // Unbounded is not "no limit" — `event_spool.js` bounds this path at
        // `maxUnacked`, loudly, on disk, where the owner's messages actually
        // are. A second bound here could only ever be the lossy one.
        self.incomingMessages = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        self.continuation = continuation
    }

    deinit {
        continuation.finish()
    }

    // MARK: Lifecycle

    /// Starts, and keeps, the connection to the bridge. Idempotent.
    public func start() {
        guard supervisor == nil, !isStopped else { return }
        supervisor = Task { [weak self] in
            await self?.supervise()
        }
    }

    public func stop() {
        isStopped = true
        supervisor?.cancel()
        supervisor = nil
        socket?.close()
        socket = nil
        continuation.finish()
    }

    /// Retires **this one message**, and nothing else.
    ///
    /// Named for what it does. The previous name was `acknowledge(through:)`,
    /// which described the wire format rather than the contract and invited
    /// exactly the bug that was found here — a caller finishing message 2 and
    /// silently retiring message 1 along with it.
    ///
    /// Call it once the turn is durably recorded — not on receipt. See the note
    /// on the type.
    ///
    /// Silent when the bridge is not connected, and that is safe rather than
    /// sloppy: the watermark is remembered and re-sent the moment a connection
    /// comes back, and the bridge is still holding the message meanwhile. The
    /// alternative — throwing — would push retry logic into the daemon for a
    /// case that resolves itself.
    public func acknowledge(sequence: Int) async {
        ledger.settle(sequence)
        await sendAcknowledgement()
    }

    /// For the daemon's diagnostics, and for the tests. The sequence the
    /// watermark is waiting on is the only useful thing to print when
    /// acknowledgement looks stuck.
    public var acknowledgementState: (watermark: Int, outstanding: Int, blockedOn: Int?) {
        (ledger.watermark, ledger.outstandingCount, ledger.blocking)
    }

    private func sendAcknowledgement() async {
        guard ledger.watermark > 0, let socket else { return }
        let line = Data("{\"ack\":\(ledger.watermark)}".utf8)
        do {
            try await socket.writeLine(line)
        } catch {
            // The connection went away. Nothing is lost: the bridge still holds
            // everything past its own ack mark, and `supervise()` re-sends this
            // as soon as it reconnects.
            configuration.logger(.note("acknowledgement deferred: \(error)"))
        }
    }

    // MARK: The connection

    private func supervise() async {
        var attempt = 0
        while !Task.isCancelled && !isStopped {
            do {
                let socket = try await SignalLineSocket.connect(
                    to: .unixSocket(path: configuration.socketPath)
                )
                self.socket = socket
                attempt = 0
                configuration.logger(.connected(configuration.socketPath))

                // **First thing on every connection.** The bridge replays
                // everything past its own ack mark the moment a consumer
                // appears, which after a Mynah restart includes messages this
                // client already dealt with — it just has no way to know that.
                // Saying where we got to turns a duplicate storm into nothing.
                await sendAcknowledgement()

                for try await line in socket.lines() {
                    if Task.isCancelled || isStopped { break }
                    receive(line)
                }
                configuration.logger(.disconnected("the bridge closed the connection"))
            } catch {
                configuration.logger(.disconnected("\(error)"))
            }

            socket?.close()
            socket = nil
            if Task.isCancelled || isStopped { break }

            attempt += 1
            let delay = configuration.backoff.delay(forAttempt: attempt)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    // MARK: Decoding

    /// Internal rather than private so a test can drive it without a socket.
    /// The acknowledgement bug this file now guards against was reachable only
    /// through here, which is why the fifteen tests over this transport all
    /// passed while it was live.
    func receive(_ line: Data) {
        guard let message = Self.decode(line) else {
            // A line we cannot read is reported, never passed over quietly.
            let preview = String(data: line.prefix(200), encoding: .utf8) ?? "<not utf8>"
            configuration.logger(.failure("unreadable line from the bridge: \(preview)"))

            // Settled if we can at least tell which sequence it was, because it
            // will be byte-identical on every replay: leaving it outstanding
            // would hold the watermark down for ever, the spool would fill, and
            // *every* later message would be refused. One line we could never
            // have read is a smaller loss than the channel.
            //
            // If even the sequence is unreadable there is nothing to settle,
            // and the watermark stalls behind it deliberately. That means the
            // socket framing itself is broken, and the bridge says so loudly
            // when its spool fills rather than dropping anything.
            if let sequence = Self.sequence(of: line) {
                ledger.settle(sequence)
                Task { await self.sendAcknowledgement() }
            }
            return
        }

        switch configuration.allowlist.decide(message) {
        case .denied(let denial):
            configuration.logger(.refused(denial))
            // **A refusal here destroys the message, so the cost of a wrong one
            // is total — and this side cannot evaluate every address WhatsApp
            // uses.**
            //
            // The bridge allowlisted everything in the spool before it got here,
            // so a refusal at this point means the two lists disagree. That is
            // usually the case this second check exists for: a plist somebody
            // edited, where destroying the message is exactly right.
            //
            // It was also reachable for an address this side simply cannot read.
            // WhatsApp increasingly addresses people by LID — `<digits>@lid`,
            // an opaque id that is not a phone number — and `number(inJID:)`
            // compares bare digits, so the owner's own message could arrive,
            // fail to match, and be acknowledged away. The bridge now resolves
            // LIDs to phone numbers before the event leaves it, using the
            // mapping files only it has; see `resolveLidToPhoneJid` in
            // bridge.js. An unresolvable LID is still refused, which is correct
            // — nobody can attribute it — and is why this logs rather than
            // passing over in silence.
            //
            // Settling is still right for a genuine refusal: without it the
            // bridge replays a stranger's message on every reconnection for
            // ever, and the spool fills at 10,000 with mail nobody will answer,
            // at which point the owner's own messages start being refused.
            //
            // Through the ledger, never straight to the watermark: if the
            // owner's message is outstanding underneath this one, saying
            // `{"ack":2}` here would retire his message too.
            ledger.settle(message.sequence)
            Task { await self.sendAcknowledgement() }
        case .allowed:
            ledger.deliver(message.sequence)
            continuation.yield(message)
        }
    }

    /// Just the sequence, for a line whose event we could not read.
    static func sequence(of line: Data) -> Int? {
        (try? JSONSerialization.jsonObject(with: line) as? [String: Any])?["seq"] as? Int
    }

    /// `{"seq":12,"event":{…}}` → a message, or nil.
    static func decode(_ line: Data) -> WhatsAppIncomingMessage? {
        guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let sequence = root["seq"] as? Int,
              let event = root["event"] as? [String: Any],
              let chatID = event["chatId"] as? String
        else { return nil }

        // `senderId` is absent on some bridge events; the chat is the sender in
        // a one-to-one thread, which is the whole Message-Yourself case.
        let senderID = (event["senderId"] as? String) ?? chatID

        // WhatsApp sends this as a number, but protobuf longs arrive as strings
        // often enough that assuming one shape drops real messages.
        let timestamp: Int64
        if let number = event["timestamp"] as? NSNumber {
            timestamp = number.int64Value
        } else if let text = event["timestamp"] as? String, let parsed = Int64(text) {
            timestamp = parsed
        } else {
            timestamp = 0
        }

        return WhatsAppIncomingMessage(
            sequence: sequence,
            messageID: (event["messageId"] as? String) ?? "",
            chatID: chatID,
            senderID: senderID,
            senderName: event["senderName"] as? String,
            isGroup: (event["isGroup"] as? Bool) ?? chatID.hasSuffix("@g.us"),
            body: (event["body"] as? String) ?? "",
            hasMedia: (event["hasMedia"] as? Bool) ?? false,
            mediaType: event["mediaType"] as? String,
            mediaPaths: (event["mediaUrls"] as? [String]) ?? [],
            timestamp: timestamp
        )
    }
}
