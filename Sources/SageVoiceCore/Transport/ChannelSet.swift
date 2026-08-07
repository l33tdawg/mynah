import Foundation

/// Every channel the owner has turned on, as one inbox and one way out.
///
/// **The owner's requirement was "signal or whatsapp or both", and `both` is the
/// word that decides this design.** With one channel a daemon can hold the
/// channel. With two it has to hold something, and the two candidates are very
/// different: a second daemon per channel, or one daemon reading a merged
/// stream. `MessageChannel` already argues against the first — two copies of the
/// turn loop drift, and the second one is always the one missing the fix. This
/// is the other half of that argument made concrete.
///
/// Deliberately **not** a `MessageChannel` itself, tempting as that is. The
/// protocol requires a `kind`, and a set of channels does not have one; the
/// conformance would need a lie (`.signal`, whichever is first, a new
/// `.multiple` case nobody can send to) sitting at exactly the place a reply
/// picks its route. `ChannelRecipient.kind` is what routes a send, and it comes
/// from the message that asked — never from the transport that happens to be
/// holding it.
public final class ChannelSet: Sendable {

    private let channels: [any MessageChannel]

    /// Every enabled channel's messages, in arrival order across all of them.
    ///
    /// One stream rather than one per channel because the daemon's coalescing
    /// window is per *turn*, not per transport: the owner sending a photo on
    /// WhatsApp and then typing the question is one request, and two streams
    /// would make it two.
    public nonisolated let incomingMessages: AsyncStream<ChannelMessage>

    private let pumps: [Task<Void, Never>]

    public init(_ channels: [any MessageChannel]) {
        self.channels = channels

        var continuation: AsyncStream<ChannelMessage>.Continuation!
        // **Unbounded. The bounded version I wrote here was wrong twice over,
        // and both halves of its reasoning were false.**
        //
        // It said the daemon reads into `MessageInbox` immediately. It does not:
        // `run()` starts the channels and then spends seconds — a SAGE inception
        // round trip and a measured ~14s of model prefill — before the reader
        // task exists. `start()` is exactly when the bridge dumps its entire
        // unacknowledged spool down the socket in one burst, so that window is
        // precisely when a backlog arrives with nobody draining it.
        //
        // It also said dropping was harmless for WhatsApp because the bridge
        // still holds the message. It does not: `WhatsAppClient.receive` calls
        // `ledger.deliver` before yielding, so a dropped element is a sequence
        // the ledger holds open for ever. The watermark stops, the spool stops
        // truncating, and the channel dies quietly while `/health` still says
        // connected.
        //
        // The reader now starts before any of that work — see `run()` — and this
        // is unbounded as well, because a fix that relies on ordering alone is
        // one reordering away from the same failure.
        self.incomingMessages = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        let out = continuation!

        // **Finishes only when every channel has finished.** A merged stream
        // that ends with the first channel to end would let a WhatsApp bridge
        // exiting take Signal down with it — the daemon's `run()` loop returns
        // when this stream ends, so that is not a degraded appliance, it is a
        // stopped one.
        let remaining = ChannelSet.Remaining(channels.count)
        if channels.isEmpty {
            // Nobody can message this appliance. A legitimate state during
            // setup; see `ChannelSelection`. Finishing at once means `run()`
            // returns rather than blocking for ever on a stream nothing writes.
            out.finish()
            self.pumps = []
            return
        }
        self.pumps = channels.map { channel in
            Task {
                for await message in channel.incomingMessages {
                    out.yield(message)
                }
                if await remaining.oneFinished() { out.finish() }
            }
        }
    }

    deinit {
        for pump in pumps { pump.cancel() }
    }

    private actor Remaining {
        private var count: Int
        init(_ count: Int) { self.count = count }
        /// - Returns: whether that was the last one.
        func oneFinished() -> Bool {
            count -= 1
            return count <= 0
        }
    }

    public var kinds: [ChannelKind] { channels.map(\.kind) }
    public var isEmpty: Bool { channels.isEmpty }

    public func start() async {
        // Concurrently: signal-cli takes seconds to come up and the WhatsApp
        // bridge's first connection can take longer, and serialising them means
        // the owner's Signal messages are unanswered for the sum rather than the
        // maximum.
        await withTaskGroup(of: Void.self) { group in
            for channel in channels {
                group.addTask { await channel.start() }
            }
        }
    }

    public func stop() async {
        await withTaskGroup(of: Void.self) { group in
            for channel in channels {
                group.addTask { await channel.stop() }
            }
        }
    }

    /// Whether a reply could reach *this* recipient — not whether anything is up.
    ///
    /// The daemon waits on this before apologising for an unkept promise, and an
    /// "is anything connected?" answer would have it apologise into a dead
    /// WhatsApp because Signal happened to be fine.
    public func isConnected(_ kind: ChannelKind) async -> Bool {
        guard let channel = channels.first(where: { $0.kind == kind }) else { return false }
        return await channel.isConnected
    }

    /// Whether any enabled channel could carry a message right now. For status
    /// display, and for the case where the caller genuinely has no recipient.
    public func isAnyConnected() async -> Bool {
        for channel in channels where await channel.isConnected { return true }
        return false
    }

    public enum Failure: Error, CustomStringConvertible {
        case noSuchChannel(ChannelKind)

        public var description: String {
            switch self {
            case .noSuchChannel(let kind):
                return "\(kind.displayName) is not turned on, so there is nowhere to send this. "
                    + "Turn it on in Mynah's setup, or reply on a channel that is."
            }
        }
    }

    /// Routed by the recipient's own `kind`, which travelled with the message
    /// that asked. Nothing here inspects the address: a WhatsApp JID and a
    /// Signal group id are both opaque strings, and telling them apart by shape
    /// is how a reply to one person reaches another.
    public func send(_ reply: ChannelReply, to recipient: ChannelRecipient) async throws {
        guard let channel = channels.first(where: { $0.kind == recipient.kind }) else {
            throw Failure.noSuchChannel(recipient.kind)
        }
        try await channel.send(reply, to: recipient)
    }

    /// Retires a message on the channel it came from.
    ///
    /// Silent when that channel is gone, and that is the right shape: the only
    /// way to get here with no matching channel is a message that arrived before
    /// the owner turned the channel off, and there is nothing left to tell.
    public func acknowledge(_ message: ChannelMessage) async {
        guard let channel = channels.first(where: { $0.kind == message.kind }) else { return }
        await channel.acknowledge(message)
    }
}
