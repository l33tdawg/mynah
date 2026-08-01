import Foundation

/// A client for `signal-cli daemon` in JSON-RPC mode.
///
///     signal-cli -a +NUMBER daemon --socket=$HOME/.local/share/signal-cli/daemon.socket
///
/// Responsibilities:
///   * stay connected (reconnect with exponential backoff when signal-cli restarts),
///   * turn `receive` notifications into `SignalIncomingMessage`,
///   * refuse everything that is not on the sender allowlist, before the caller ever sees it,
///   * send text replies.
///
/// Nothing reaches `incomingMessages` without passing `Configuration.allowlist`. There is no
/// way to construct a `Configuration` without one, and no way to construct an allowlist that
/// matches everybody.
public actor SignalClient {
    public enum ReceiveMode: String, Equatable, Sendable {
        /// The daemon was started with the default `--receive-mode=on-start`; notifications
        /// arrive unsolicited on every connected client.
        case automatic
        /// The daemon was started with `--receive-mode=manual`; this client issues
        /// `subscribeReceive` after connecting.
        case manual
    }

    public struct Configuration: Sendable {
        public var endpoint: SignalEndpoint
        /// Required only when the daemon runs in multi-account mode (started without `-a`).
        public var account: String?
        /// The security boundary. No default — it must be a deliberate act.
        public var allowlist: SignalSenderAllowlist
        /// Where signal-cli writes decrypted attachments.
        public var attachmentsDirectory: URL
        public var receiveMode: ReceiveMode
        public var requestTimeoutSeconds: TimeInterval
        public var backoff: SignalBackoffPolicy
        public var logger: SignalTransportLogger

        public init(
            allowlist: SignalSenderAllowlist,
            endpoint: SignalEndpoint = .defaultUnixSocket(),
            account: String? = nil,
            attachmentsDirectory: URL = SignalAttachmentLocator.defaultAttachmentsDirectory(),
            receiveMode: ReceiveMode = .automatic,
            requestTimeoutSeconds: TimeInterval = 30,
            backoff: SignalBackoffPolicy = SignalBackoffPolicy(),
            logger: @escaping SignalTransportLogger = SignalTransportLog.standardError
        ) {
            self.allowlist = allowlist
            self.endpoint = endpoint
            self.account = account
            self.attachmentsDirectory = attachmentsDirectory
            self.receiveMode = receiveMode
            self.requestTimeoutSeconds = requestTimeoutSeconds
            self.backoff = backoff
            self.logger = logger
        }
    }

    private let configuration: Configuration
    private let messagesContinuation: AsyncStream<SignalIncomingMessage>.Continuation

    /// Allowlisted messages only. One consumer; iterate it from the agent loop.
    public nonisolated let incomingMessages: AsyncStream<SignalIncomingMessage>

    private var socket: SignalLineSocket?
    private var supervisor: Task<Void, Never>?
    private var pending: [String: CheckedContinuation<Data, Error>] = [:]
    private var requestCounter: UInt64 = 0
    private var isStopped = false
    private var subscriptionID: Int?

    public init(configuration: Configuration) {
        self.configuration = configuration
        var continuation: AsyncStream<SignalIncomingMessage>.Continuation!
        self.incomingMessages = AsyncStream(bufferingPolicy: .bufferingNewest(256)) { continuation = $0 }
        self.messagesContinuation = continuation
    }

    public init(allowlist: SignalSenderAllowlist, endpoint: SignalEndpoint = .defaultUnixSocket()) {
        self.init(configuration: Configuration(allowlist: allowlist, endpoint: endpoint))
    }

    deinit {
        messagesContinuation.finish()
    }

    // MARK: Lifecycle

    /// Starts (and keeps) the connection to signal-cli. Idempotent.
    public func start() {
        guard supervisor == nil, !isStopped else {
            return
        }
        supervisor = Task { [weak self] in
            await self?.supervise()
        }
    }

    /// Stops reconnecting, drops the socket and finishes `incomingMessages`.
    public func stop() {
        isStopped = true
        supervisor?.cancel()
        supervisor = nil
        socket?.close()
        socket = nil
        failAllPending(with: SignalTransportError.notConnected)
        messagesContinuation.finish()
    }

    public var isConnected: Bool {
        socket != nil
    }

    // MARK: Sending

    /// Sends a plain text message. Returns the Signal timestamp of the sent message.
    @discardableResult
    public func sendText(_ text: String, to recipient: SignalRecipient) async throws -> Int64 {
        try await send(text: text, attachmentPaths: [], to: recipient)
    }

    /// Replies to a message on whichever thread it arrived on. For a Note to Self command
    /// this sends back to the owner's own number, which is what shows up in their app.
    @discardableResult
    public func reply(to message: SignalIncomingMessage, text: String) async throws -> Int64 {
        guard let recipient = message.replyRecipient else {
            throw SignalTransportError.noReplyRecipient
        }
        return try await sendText(text, to: recipient)
    }

    /// Sends text and/or file attachments.
    ///
    /// Voice-note replies (a later phase) go through here: synthesise to an audio file that
    /// the signal-cli process can read, then pass its path. signal-cli has no "voice note"
    /// flag — Signal carries voice notes as ordinary `audio/*` attachments — so recipients
    /// see an audio attachment rather than the waveform bubble.
    /// - Parameter textStyles: Signal's own formatting ranges, each
    ///   `start:length:STYLE` with the offsets counted in **UTF-16 code units**,
    ///   which is what signal-cli documents and what Signal's wire format uses.
    ///   Passing character counts would misplace the range the moment a reply
    ///   contains an emoji.
    @discardableResult
    public func send(
        text: String?,
        attachmentPaths: [String],
        textStyles: [String] = [],
        to recipient: SignalRecipient
    ) async throws -> Int64 {
        var params: [String: Any] = [:]
        switch recipient {
        case .account(let value):
            params["recipient"] = [value]
        case .group(let id):
            params["groupId"] = id
        }
        if let text, !text.isEmpty {
            params["message"] = text
        }
        if !attachmentPaths.isEmpty {
            params["attachments"] = attachmentPaths
        }
        if !textStyles.isEmpty {
            params["textStyle"] = textStyles
        }

        let result = try await request(method: "send", params: params)
        let timestamp = SignalEnvelopeParser.int64((result as? [String: Any])?["timestamp"]) ?? 0
        log(.sent(recipient: SignalSenderAllowlist.redact(recipient.description), timestamp: timestamp))
        return timestamp
    }

    /// Escape hatch for JSON-RPC methods this client does not wrap
    /// (`listGroups`, `sendTyping`, `sendReceipt`, …).
    @discardableResult
    public func call(method: String, params: [String: Any] = [:]) async throws -> Any? {
        try await request(method: method, params: params)
    }

    // MARK: Connection supervision

    private func supervise() async {
        var attempt = 0
        while !isStopped && !Task.isCancelled {
            do {
                let socket = try await SignalLineSocket.connect(to: configuration.endpoint)
                self.socket = socket
                attempt = 0
                log(.connected(configuration.endpoint))

                if configuration.receiveMode == .manual {
                    // Runs concurrently with the read loop below: its response arrives
                    // through that same loop.
                    Task { [weak self] in
                        await self?.subscribeReceive()
                    }
                }

                for try await line in socket.lines() {
                    handle(line: line)
                }
                log(.disconnected(reason: nil))
            } catch {
                log(.disconnected(reason: String(describing: error)))
            }

            socket?.close()
            socket = nil
            subscriptionID = nil
            failAllPending(with: SignalTransportError.notConnected)

            if isStopped || Task.isCancelled {
                break
            }

            attempt += 1
            let delay = configuration.backoff.delay(forAttempt: attempt)
            log(.reconnecting(attempt: attempt, afterSeconds: delay))
            do {
                try await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            } catch {
                break
            }
        }
        messagesContinuation.finish()
    }

    private func subscribeReceive() async {
        do {
            let result = try await request(method: "subscribeReceive", params: [:])
            let id = SignalEnvelopeParser.int(result) ?? 0
            subscriptionID = id
            log(.subscribed(subscription: id))
        } catch {
            log(.failure("subscribeReceive failed: \(error)"))
        }
    }

    // MARK: Frame handling

    private func handle(line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line),
              let frame = object as? [String: Any] else {
            log(.warning("ignored a non-object JSON-RPC frame (\(line.count) bytes)"))
            return
        }

        if let method = frame["method"] as? String {
            guard method == SignalEnvelopeParser.receiveMethod else {
                return
            }
            handleReceive(frame: frame)
            return
        }

        guard let id = identifier(from: frame["id"]) else {
            if let error = frame["error"] as? [String: Any] {
                log(.failure("signal-cli reported \(error)"))
            }
            return
        }
        if let continuation = pending.removeValue(forKey: id) {
            continuation.resume(returning: line)
        }
    }

    private func handleReceive(frame: [String: Any]) {
        guard let message = SignalEnvelopeParser.parseNotification(
            frame,
            attachmentsDirectory: configuration.attachmentsDirectory
        ) else {
            return  // receipt, typing indicator, read sync, …
        }

        // ---- security boundary -------------------------------------------------
        switch configuration.allowlist.evaluate(message) {
        case .deny(let reason):
            let sender = message.senderIdentifiers.first.map(SignalSenderAllowlist.redact) ?? "<unknown>"
            log(.senderRejected(sender: sender, reason: reason))
            return
        case .allow:
            break
        }
        // ------------------------------------------------------------------------

        for attachment in message.attachments where attachment.localURL == nil {
            log(.attachmentNotFound(
                id: attachment.id,
                directory: configuration.attachmentsDirectory.path
            ))
        }

        log(.messageAccepted(summary: message.logDescription))
        messagesContinuation.yield(message)
    }

    // MARK: Requests

    private func request(method: String, params: [String: Any]) async throws -> Any? {
        guard let socket, !isStopped else {
            throw SignalTransportError.notConnected
        }

        requestCounter += 1
        let id = "sage-\(requestCounter)"

        var effectiveParams = params
        if let account = configuration.account, effectiveParams["account"] == nil {
            effectiveParams["account"] = account
        }
        var payload: [String: Any] = ["jsonrpc": "2.0", "method": method, "id": id]
        if !effectiveParams.isEmpty {
            payload["params"] = effectiveParams
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes])

        let timeout = configuration.requestTimeoutSeconds
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
            guard !Task.isCancelled else {
                return
            }
            await self?.fail(
                requestID: id,
                with: SignalTransportError.requestTimedOut(method: method, seconds: timeout)
            )
        }
        defer { timeoutTask.cancel() }

        let responseLine: Data = try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task { [weak self] in
                do {
                    try await socket.writeLine(data)
                } catch {
                    await self?.fail(requestID: id, with: error)
                }
            }
        }

        return try Self.result(fromResponseLine: responseLine)
    }

    private func fail(requestID: String, with error: Error) {
        guard let continuation = pending.removeValue(forKey: requestID) else {
            return
        }
        continuation.resume(throwing: error)
    }

    private func failAllPending(with error: Error) {
        let inflight = pending
        pending.removeAll()
        for (_, continuation) in inflight {
            continuation.resume(throwing: error)
        }
    }

    static func result(fromResponseLine line: Data) throws -> Any? {
        guard let object = try? JSONSerialization.jsonObject(with: line),
              let frame = object as? [String: Any] else {
            throw SignalTransportError.malformedResponse(String(data: line, encoding: .utf8) ?? "<non-utf8>")
        }
        if let error = frame["error"] as? [String: Any] {
            throw SignalTransportError.rpcError(
                code: SignalEnvelopeParser.int(error["code"]) ?? -1,
                message: SignalEnvelopeParser.string(error["message"]) ?? "unknown error"
            )
        }
        return frame["result"]
    }

    private func identifier(from value: Any?) -> String? {
        if let value = value as? String {
            return value
        }
        if let value = value as? NSNumber {
            return value.stringValue
        }
        return nil
    }

    private func log(_ event: SignalTransportEvent) {
        configuration.logger(event)
    }
}
