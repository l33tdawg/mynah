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
/// **The loopback port is authenticated, and the paragraph that used to sit
/// here understated what was wrong with it.** It said the port was reachable by
/// other accounts on the Mac and called that a cost worth accepting. An audit
/// put it plainly: the Host-header check is not authentication, so *any* local
/// process could `POST /send` as the owner, `POST /send-media` with any path it
/// liked to read a file off this Mac into a WhatsApp chat, and `GET /messages`
/// to drain the owner's inbound queue — with one curl and a constant header.
///
/// Both ends now share a 32-byte secret out of a `0600` file in the same
/// owner-only directory as the session keys. `/health` stays open, because it
/// says nothing about the owner and it is what answers before this side has
/// read anything.
///
/// A token file rather than a launch argument: an argument is in the plist,
/// which is world-readable, and in `ps` for every account on the machine.
public actor WhatsAppChannel: MessageChannel {

    public nonisolated let kind: ChannelKind = .whatsapp

    public struct Configuration: Sendable {
        public var client: WhatsAppClient
        /// Where the bridge's HTTP endpoint listens. Loopback only.
        public var sendPort: Int
        public var sendTimeoutSeconds: TimeInterval
        /// The file the bridge writes its API token to.
        public var tokenPath: String

        public init(
            client: WhatsAppClient,
            sendPort: Int = 39930,
            sendTimeoutSeconds: TimeInterval = 30,
            tokenPath: String = WhatsAppChannel.defaultTokenPath()
        ) {
            self.client = client
            self.sendPort = sendPort
            self.sendTimeoutSeconds = sendTimeoutSeconds
            self.tokenPath = tokenPath
        }
    }

    public enum Failure: Error, CustomStringConvertible {
        case notConnected
        case rejected(status: Int, detail: String)
        case noToken(String)
        /// The words arrived and a file did not.
        ///
        /// **Its own case because the caller's recovery differs.** `reply`
        /// handles a failed send by retrying without attachments, which is right
        /// for Signal — signal-cli takes text and files in one call, so a throw
        /// means nothing was sent. WhatsApp has no such call: `send` is a POST
        /// for the text and one more per file, so a throw after the text
        /// succeeded means the owner already has the words. Retrying sends them
        /// a second time.
        case attachmentsFailedAfterText(String)

        public var description: String {
            switch self {
            case .notConnected:
                return "The WhatsApp bridge is not answering on loopback. It is started by Mynah; if it is not running, WhatsApp is off or the helper stopped."
            case .rejected(let status, let detail):
                return "The WhatsApp bridge refused the send (HTTP \(status)): \(detail)"
            case .attachmentsFailedAfterText(let detail):
                return "The message was sent but the file was not: \(detail)"
            case .noToken(let path):
                // Every dead end names the next action. The token is written by
                // the bridge on its first start, so "it is not there" almost
                // always means "the bridge has never run".
                return "Mynah could not read the WhatsApp bridge's API token at \(path). "
                    + "The bridge writes it the first time it starts, so this usually means it has "
                    + "not started yet — turn WhatsApp off and on again in Settings, or check "
                    + "~/Library/Logs/Mynah/whatsapp.log."
            }
        }
    }

    /// Beside the session keys, not in `$TMPDIR`. Unlike the socket this has to
    /// survive a reboot, and unlike the socket its length is not constrained by
    /// `sockaddr_un`.
    public static func defaultTokenPath(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        homeDirectory
            .appendingPathComponent("Library/Application Support/SAGE Voice Bridge", isDirectory: true)
            .appendingPathComponent("WhatsApp", isDirectory: true)
            .appendingPathComponent("api-token")
            .path
    }

    /// Read per request rather than cached.
    ///
    /// The bridge mints a new token if the file is missing, which happens when
    /// the owner clears the WhatsApp state. A cached token would then be wrong
    /// for the life of the daemon — every send refused with a 401, and a restart
    /// the only cure. A file read on a send that is about to do network I/O is
    /// not a cost worth optimising against that.
    private func token() throws -> String {
        guard let raw = try? String(contentsOfFile: configuration.tokenPath, encoding: .utf8) else {
            throw Failure.noToken(configuration.tokenPath)
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.noToken(configuration.tokenPath) }
        return trimmed
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
        // Unbounded, for the reason `WhatsAppClient` gives at length: the
        // spool is the bound on this path, and a buffer that drops its oldest
        // element wedges acknowledgement permanently rather than losing one
        // message.
        self.incomingMessages = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
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
            attachments: message.mediaPaths.enumerated().map { index, path in
                ChannelAttachment(
                    // WhatsApp gives one id for the message, not one per file.
                    // Suffixed so two attachments on one message are distinct,
                    // which is what the attachment store keys on.
                    id: message.mediaPaths.count > 1 ? "\(message.messageID)-\(index)" : message.messageID,
                    contentType: Self.contentType(for: message.mediaType, path: path),
                    filename: (path as NSString).lastPathComponent,
                    caption: message.body.isEmpty ? nil : message.body,
                    localURL: URL(fileURLWithPath: path)
                )
            },
            timestamp: message.timestamp,
            acknowledgementToken: message.sequence
        )
    }

    /// WhatsApp names a *category* — `ptt`, `image`, `document` — where Signal
    /// gives a MIME type, and `ChannelAttachment` decides voice-note-versus-photo
    /// from the MIME type with the extension as a fallback.
    ///
    /// **The saved file's own extension is the better answer whenever there is
    /// one**, so this returns nil and lets it rule: the bridge writes what
    /// WhatsApp actually sent, and `.ogg` or `.jpg` says more than "audio" or
    /// "image" does. Inventing `audio/ogg` over a real `.mp3` would put a wrong
    /// type in the log and a wrong extension on the kept copy for no gain.
    ///
    /// The fallback is not decoration. A media file the bridge saved without an
    /// extension has nothing else to go on, and a voice note misread as a
    /// document is not a small error — it is filed rather than transcribed, and
    /// the owner's spoken question is answered by Mynah telling them it has
    /// saved a file.
    ///
    /// `document` deliberately has no fallback: it means "the owner attached a
    /// file", which is precisely the case where guessing is wrong.
    static func contentType(for mediaType: String?, path: String) -> String? {
        if !(path as NSString).pathExtension.isEmpty { return nil }
        switch (mediaType ?? "").lowercased() {
        case "ptt", "audio": return "audio/ogg"      // WhatsApp voice notes are opus in ogg
        case "image", "sticker": return "image/jpeg"
        case "video": return "video/mp4"
        default: return nil
        }
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
        // Tracked, so a failure here is distinguishable from one before the
        // text went. See `attachmentsFailedAfterText`.
        let wordsAreThere = !(reply.text ?? "").isEmpty
        for path in reply.attachmentPaths {
            do {
                try await post(path: "/send-media", body: ["chatId": recipient.address, "filePath": path])
            } catch {
                guard wordsAreThere else { throw error }
                throw Failure.attachmentsFailedAfterText("\(error)")
            }
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
        // …and one that does not carry the shared secret. The Host check is
        // about a browser being tricked; this is about every other process on
        // the Mac.
        request.setValue(try token(), forHTTPHeaderField: "X-Mynah-Token")
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
