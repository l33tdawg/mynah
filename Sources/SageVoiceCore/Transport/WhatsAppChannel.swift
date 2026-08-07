import Foundation

/// `WhatsAppClient` seen as a `MessageChannel`, plus the sending half.
///
/// Reading and sending take different routes, and that is a deliberate split
/// rather than an inconsistency:
///
///   * **In** is a push over the `0600` UNIX socket, because an inbound message
///     is something the bridge must not lose and must be able to replay. That
///     is `WhatsAppClient` and the spool behind it.
///   * **Out** is `POST /send` on the bridge's loopback HTTP port, which is
///     upstream's own endpoint, upstream-tested, and the natural shape for a
///     request that has a reply. A send that fails is a send the daemon finds
///     out about immediately and can report; there is nothing to spool.
///
/// The honest cost of that choice: the loopback TCP port stays. It binds
/// 127.0.0.1 and validates the Host header (upstream's fix for
/// GHSA-ppp5-vxwm-4cf7), which stops a browser being tricked into reaching it,
/// but on a Mac with more than one login it is reachable by the other accounts
/// in a way the socket is not. Worth revisiting by moving sends onto the socket
/// too; not worth blocking the feature on, and written down here rather than
/// discovered later.
public actor WhatsAppChannel: MessageChannel {

    public nonisolated let kind: ChannelKind = .whatsapp

    public struct Configuration: Sendable {
        public var client: WhatsAppClient
        /// Where the bridge's HTTP endpoint listens. Loopback only.
        public var sendPort: Int
        public var sendTimeoutSeconds: TimeInterval

        public init(client: WhatsAppClient, sendPort: Int = 39930, sendTimeoutSeconds: TimeInterval = 30) {
            self.client = client
            self.sendPort = sendPort
            self.sendTimeoutSeconds = sendTimeoutSeconds
        }
    }

    public enum Failure: Error, CustomStringConvertible {
        case notConnected
        case rejected(status: Int, detail: String)

        public var description: String {
            switch self {
            case .notConnected:
                return "The WhatsApp bridge is not answering on loopback. It is started by Mynah; if it is not running, WhatsApp is off or the helper stopped."
            case .rejected(let status, let detail):
                return "The WhatsApp bridge refused the send (HTTP \(status)): \(detail)"
            }
        }
    }

    private let configuration: Configuration
    private let session: URLSession
    public nonisolated let incomingMessages: AsyncStream<ChannelMessage>
    private let translation: Task<Void, Never>

    public init(configuration: Configuration) {
        self.configuration = configuration

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = configuration.sendTimeoutSeconds
        // Loopback only. A proxy in the owner's environment must not see, or be
        // able to redirect, a message on its way to a local helper.
        sessionConfiguration.connectionProxyDictionary = [:]
        self.session = URLSession(configuration: sessionConfiguration)

        var continuation: AsyncStream<ChannelMessage>.Continuation!
        self.incomingMessages = AsyncStream(bufferingPolicy: .bufferingNewest(256)) { continuation = $0 }
        let out = continuation!
        let client = configuration.client
        self.translation = Task {
            for await message in client.incomingMessages {
                out.yield(Self.translate(message))
            }
            out.finish()
        }
    }

    deinit {
        translation.cancel()
    }

    static func translate(_ message: WhatsAppIncomingMessage) -> ChannelMessage {
        ChannelMessage(
            kind: .whatsapp,
            // The chat, never the sender. In a group they differ, and replying
            // to the sender would take the answer out of the conversation it
            // belongs to and into a private thread the owner did not open.
            recipient: ChannelRecipient(
                kind: .whatsapp,
                address: message.chatID,
                isGroup: message.isGroup
            ),
            id: message.messageID,
            senderDisplayName: message.senderName,
            text: message.body.isEmpty ? nil : message.body,
            attachmentPaths: message.mediaPaths,
            timestamp: message.timestamp,
            acknowledgementToken: message.sequence
        )
    }

    /// WhatsApp has no styling protocol — emphasis is asterisks in the text
    /// itself, the way anybody typing it would.
    ///
    /// Applied back to front so that an earlier range's inserted characters do
    /// not shift a later range's offsets. Offsets are UTF-16, because that is
    /// what `ChannelEmphasis` documents and what Signal's format required;
    /// converting through `String.Index` here keeps a marker containing an
    /// emoji from wrapping the wrong words.
    static func render(_ text: String, emphasis: [ChannelEmphasis]) -> String {
        guard !emphasis.isEmpty else { return text }
        var result = text
        for run in emphasis.sorted(by: { $0.utf16Offset > $1.utf16Offset }) {
            let utf16 = result.utf16
            guard run.utf16Offset >= 0, run.utf16Length > 0,
                  let start = utf16.index(utf16.startIndex, offsetBy: run.utf16Offset, limitedBy: utf16.endIndex),
                  let end = utf16.index(start, offsetBy: run.utf16Length, limitedBy: utf16.endIndex),
                  let from = String.Index(start, within: result),
                  let to = String.Index(end, within: result)
            else { continue }   // a range that does not land on character boundaries is skipped, not guessed at
            result.replaceSubrange(from..<to, with: "*\(result[from..<to])*")
        }
        return result
    }

    public func start() async { await configuration.client.start() }
    public func stop() async { await configuration.client.stop() }

    public var isConnected: Bool {
        get async {
            guard let url = URL(string: "http://127.0.0.1:\(configuration.sendPort)/health") else { return false }
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            guard let (data, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return false }
            // "the process is up" is not "WhatsApp will receive this". The
            // bridge answers /health while it is reconnecting, and a send in
            // that window is refused with 503.
            return (body["status"] as? String) == "connected"
        }
    }

    public func send(_ reply: ChannelReply, to recipient: ChannelRecipient) async throws {
        // Text and attachments are separate calls upstream, and the text goes
        // first so that a failure to send a document still leaves the owner
        // with the words explaining what was meant to arrive.
        if let text = reply.text, !text.isEmpty {
            try await post(
                path: "/send",
                body: ["chatId": recipient.address, "message": Self.render(text, emphasis: reply.emphasis)]
            )
        }
        for path in reply.attachmentPaths {
            try await post(path: "/send-media", body: ["chatId": recipient.address, "filePath": path])
        }
    }

    public func acknowledge(_ message: ChannelMessage) async {
        guard let token = message.acknowledgementToken else { return }
        await configuration.client.acknowledge(sequence: token)
    }

    private func post(path: String, body: [String: Any]) async throws {
        guard let url = URL(string: "http://127.0.0.1:\(configuration.sendPort)\(path)") else {
            throw Failure.notConnected
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The bridge rejects a request whose Host is not a loopback name.
        request.setValue("127.0.0.1:\(configuration.sendPort)", forHTTPHeaderField: "Host")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.notConnected
        }
        guard let http = response as? HTTPURLResponse else { throw Failure.notConnected }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0?["error"] as? String }
                ?? String(data: data.prefix(200), encoding: .utf8)
                ?? "no detail"
            throw Failure.rejected(status: http.statusCode, detail: detail)
        }
    }
}
