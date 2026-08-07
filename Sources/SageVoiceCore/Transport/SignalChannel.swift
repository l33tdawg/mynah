import Foundation

/// `SignalClient` seen as a `MessageChannel`.
///
/// Thin on purpose. Everything that makes Signal work — the JSON-RPC dialect,
/// the reconnect policy, the allowlist, the attachment locator — stays in
/// `SignalClient`, which has been carrying the product for months and is not
/// improved by being disturbed. This translates vocabulary and nothing else.
public final class SignalChannel: MessageChannel {

    public let kind: ChannelKind = .signal

    private let client: SignalClient
    public nonisolated let incomingMessages: AsyncStream<ChannelMessage>
    private let translation: Task<Void, Never>

    public init(client: SignalClient) {
        self.client = client
        var continuation: AsyncStream<ChannelMessage>.Continuation!
        self.incomingMessages = AsyncStream(bufferingPolicy: .bufferingNewest(256)) { continuation = $0 }
        let out = continuation!
        self.translation = Task {
            for await message in client.incomingMessages {
                guard let translated = Self.translate(message) else {
                    // No reply address means no conversation. `SignalClient`
                    // has already allowed it, so this is a shape signal-cli
                    // sent that carries no route home — dropping it is the only
                    // option, and it is not silent: the daemon's own logging
                    // sees the gap because nothing arrives.
                    continue
                }
                out.yield(translated)
            }
            out.finish()
        }
    }

    deinit {
        translation.cancel()
    }

    static func translate(_ message: SignalIncomingMessage) -> ChannelMessage? {
        guard let recipient = message.replyRecipient else { return nil }
        let channelRecipient: ChannelRecipient
        switch recipient {
        case .account(let value):
            channelRecipient = ChannelRecipient(kind: .signal, address: value, isGroup: false)
        case .group(let id):
            channelRecipient = ChannelRecipient(kind: .signal, address: id, isGroup: true)
        }
        return ChannelMessage(
            kind: .signal,
            recipient: channelRecipient,
            // Signal has no separate message id: the send timestamp is the id,
            // which is why `SignalIncomingMessage` documents it as doing both
            // jobs.
            id: String(message.timestamp),
            senderDisplayName: message.sourceName,
            text: message.text,
            attachmentPaths: message.attachments.compactMap { $0.localURL?.path },
            timestamp: message.timestamp / 1000,   // Signal counts milliseconds
            acknowledgementToken: nil              // nothing to acknowledge
        )
    }

    static func signalRecipient(_ recipient: ChannelRecipient) -> SignalRecipient {
        recipient.isGroup ? .group(base64ID: recipient.address) : .account(recipient.address)
    }

    /// `ChannelEmphasis` back into signal-cli's own `start:length:STYLE`.
    static func styles(for emphasis: [ChannelEmphasis]) -> [String] {
        emphasis.map { "\($0.utf16Offset):\($0.utf16Length):\($0.style.rawValue.uppercased())" }
    }

    public func start() async { await client.start() }
    public func stop() async { await client.stop() }
    public var isConnected: Bool { get async { await client.isConnected } }

    public func send(_ reply: ChannelReply, to recipient: ChannelRecipient) async throws {
        _ = try await client.send(
            text: reply.text,
            attachmentPaths: reply.attachmentPaths,
            textStyles: Self.styles(for: reply.emphasis),
            to: Self.signalRecipient(recipient)
        )
    }

    /// Nothing to do. signal-cli pushes and forgets; there is no spool behind
    /// it holding anything open. Empty rather than absent so the daemon can
    /// acknowledge every message it finishes without asking which channel it
    /// came from — the moment it has to ask, "the same route" has two branches
    /// in it again.
    public func acknowledge(_ message: ChannelMessage) async {}
}
