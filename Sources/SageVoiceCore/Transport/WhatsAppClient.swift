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
/// `acknowledge(through:)`, and nothing retires a message except that call.
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

    /// The highest sequence this client has been told is safely dealt with.
    ///
    /// Kept so a reconnection can re-send it immediately. The bridge treats a
    /// repeated ack as a no-op, so saying it again costs nothing and saying it
    /// once too few means a message is answered twice.
    private var acknowledgedThrough = 0

    public init(configuration: Configuration) {
        self.configuration = configuration
        var continuation: AsyncStream<WhatsAppIncomingMessage>.Continuation!
        self.incomingMessages = AsyncStream(bufferingPolicy: .bufferingNewest(256)) { continuation = $0 }
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

    /// Retires every message up to and including `sequence`.
    ///
    /// Call this once the turn is durably recorded — not on receipt. See the
    /// note on the type.
    ///
    /// Silent when the bridge is not connected, and that is safe rather than
    /// sloppy: `acknowledgedThrough` is remembered and re-sent the moment a
    /// connection comes back, and the bridge is still holding the message in
    /// the meantime. The alternative — throwing — would push retry logic into
    /// the daemon for a case that resolves itself.
    public func acknowledge(through sequence: Int) async {
        guard sequence > acknowledgedThrough else { return }
        acknowledgedThrough = sequence
        await sendAcknowledgement()
    }

    private func sendAcknowledgement() async {
        guard acknowledgedThrough > 0, let socket else { return }
        let line = Data("{\"ack\":\(acknowledgedThrough)}".utf8)
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

    private func receive(_ line: Data) {
        guard let message = Self.decode(line) else {
            // A line we cannot read is reported, never passed over quietly. The
            // bridge is still holding it — it goes unacknowledged, so it comes
            // back — and a silent skip here would be the one way to lose a
            // message that the spool cannot protect against.
            let preview = String(data: line.prefix(200), encoding: .utf8) ?? "<not utf8>"
            configuration.logger(.failure("unreadable line from the bridge, left unacknowledged: \(preview)"))
            return
        }

        switch configuration.allowlist.decide(message) {
        case .denied(let denial):
            configuration.logger(.refused(denial))
            // Refused, and therefore dealt with. Without this the bridge would
            // replay a stranger's message on every reconnection for ever, and
            // the spool would fill with mail nobody will ever answer.
            Task { await self.acknowledge(through: message.sequence) }
        case .allowed:
            continuation.yield(message)
        }
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
