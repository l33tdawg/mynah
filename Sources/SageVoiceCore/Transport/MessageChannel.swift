import Foundation

/// A way for the owner to reach Mynah by message.
///
/// **The owner's requirement, 7 August 2026: "you can choose — signal or
/// whatsapp or both", and "the functionality would be the same — voice notes,
/// text, docs back, research, memories, SAGE, calls, through the same
/// established route as signal".**
///
/// "The same route" is the load-bearing half. It rules out the easy design,
/// which is a second daemon that happens to do similar things: two copies of
/// the turn loop drift, and the second one is always the one missing the fix.
/// So there is one `VoiceBridgeDaemon`, and a channel is something it reads
/// from and replies to.
///
/// The surface here is deliberately exactly what the daemon already used from
/// `SignalClient` and nothing more — start, stop, a stream in, a send out, and
/// a connectivity check. Anything wider would be an invitation to reach for a
/// channel-specific feature from inside the shared loop, which is how "the same
/// route" quietly becomes two routes again.
public protocol MessageChannel: Sendable {
    var kind: ChannelKind { get }

    /// Allowlisted messages only. The channel refuses everything else before
    /// the daemon can see it — that rule is `SignalClient`'s and it is kept.
    nonisolated var incomingMessages: AsyncStream<ChannelMessage> { get }

    func start() async
    func stop() async

    /// Whether a send would reach anybody right now.
    var isConnected: Bool { get async }

    func send(_ reply: ChannelReply, to recipient: ChannelRecipient) async throws

    /// Tells the channel this message is dealt with and need not be redelivered.
    ///
    /// **Only WhatsApp does anything here, and the asymmetry is real rather
    /// than an oversight.** signal-cli pushes and forgets, so Signal has no
    /// concept to acknowledge and its implementation is empty. The WhatsApp
    /// bridge keeps every message on disk until this is called, because by the
    /// time it has one, WhatsApp has already been told it was delivered and
    /// there is no copy left to ask for.
    ///
    /// Call it when the turn is durably recorded and the answer sent — not on
    /// receipt. Too early loses the message on a crash; never means it is
    /// answered again after the next restart.
    func acknowledge(_ message: ChannelMessage) async
}

public enum ChannelKind: String, Equatable, Sendable, CaseIterable, Codable {
    case signal
    case whatsapp

    /// What to call it in front of the owner.
    public var displayName: String {
        switch self {
        case .signal: return "Signal"
        case .whatsapp: return "WhatsApp"
        }
    }
}

/// Where a reply goes.
///
/// Opaque on purpose: a Signal recipient is an E.164 number or a group's base64
/// id, a WhatsApp one is a JID. The daemon never has to know which, and the
/// `kind` travelling with it is what stops a reply being sent down the wrong
/// channel when both are running — the failure this type exists to make
/// impossible.
public struct ChannelRecipient: Equatable, Sendable, CustomStringConvertible {
    public let kind: ChannelKind
    /// The channel's own address, in the channel's own form.
    public let address: String
    public let isGroup: Bool

    public init(kind: ChannelKind, address: String, isGroup: Bool = false) {
        self.kind = kind
        self.address = address
        self.isGroup = isGroup
    }

    public var description: String {
        "\(kind.rawValue):\(isGroup ? "group:" : "")\(address)"
    }
}

/// One inbound message, whichever channel it came in on.
public struct ChannelMessage: Equatable, Sendable {
    public let kind: ChannelKind
    /// Who to reply to. Carried rather than derived, because deriving it is
    /// where a reply to a group goes to a person and vice versa.
    public let recipient: ChannelRecipient
    /// The channel's own id for this message, for logs and de-duplication.
    public let id: String
    public let senderDisplayName: String?
    public let text: String?
    /// Files the channel has already decrypted and written to disk.
    public let attachmentPaths: [String]
    /// Seconds since epoch.
    public let timestamp: Int64

    /// What `acknowledge` needs to retire this message, when the channel has
    /// such a concept. `nil` for Signal.
    public let acknowledgementToken: Int?

    public init(
        kind: ChannelKind,
        recipient: ChannelRecipient,
        id: String,
        senderDisplayName: String? = nil,
        text: String? = nil,
        attachmentPaths: [String] = [],
        timestamp: Int64 = 0,
        acknowledgementToken: Int? = nil
    ) {
        self.kind = kind
        self.recipient = recipient
        self.id = id
        self.senderDisplayName = senderDisplayName
        self.text = text
        self.attachmentPaths = attachmentPaths
        self.timestamp = timestamp
        self.acknowledgementToken = acknowledgementToken
    }
}

/// A run of characters a channel should emphasise.
///
/// **Offsets and lengths are in UTF-16 code units.** That is what Signal's wire
/// format uses and what signal-cli documents, and `SignalReplyText` already
/// says why it matters: a character count and a UTF-16 count disagree the
/// moment the text contains an emoji, which puts the bold over the wrong words
/// rather than failing loudly.
public struct ChannelEmphasis: Equatable, Sendable {
    public enum Style: String, Equatable, Sendable {
        case bold
    }

    public let utf16Offset: Int
    public let utf16Length: Int
    public let style: Style

    public init(utf16Offset: Int, utf16Length: Int, style: Style = .bold) {
        self.utf16Offset = utf16Offset
        self.utf16Length = utf16Length
        self.style = style
    }
}

/// What Mynah says back.
///
/// **Emphasis is described, not spelled.** The daemon used to hand signal-cli
/// its own `"0:8:BOLD"` range strings, which is Signal's format and means
/// nothing to WhatsApp — WhatsApp wants the run wrapped in asterisks in the
/// text itself. Passing the Signal form through a shared type would have made
/// every WhatsApp reply arrive with `0:8:BOLD` either ignored or, worse,
/// printed. So each channel renders this its own way.
public struct ChannelReply: Equatable, Sendable {
    public let text: String?
    public let attachmentPaths: [String]
    public let emphasis: [ChannelEmphasis]

    public init(
        text: String?,
        attachmentPaths: [String] = [],
        emphasis: [ChannelEmphasis] = []
    ) {
        self.text = text
        self.attachmentPaths = attachmentPaths
        self.emphasis = emphasis
    }
}

/// Which channels the owner has turned on.
///
/// A set rather than an enum with a `.both` case: `.both` would need a third
/// branch at every use, and a fourth the day a third channel arrives. The empty
/// set is meaningful and is not an error here — it is an appliance nobody can
/// message, which is a legitimate state during setup and one the UI must be
/// able to describe.
public struct ChannelSelection: Equatable, Sendable, Codable {
    public var enabled: Set<ChannelKind>

    public init(_ enabled: Set<ChannelKind> = []) {
        self.enabled = enabled
    }

    public static let none = ChannelSelection([])
    public static let signalOnly = ChannelSelection([.signal])
    public static let whatsAppOnly = ChannelSelection([.whatsapp])
    public static let both = ChannelSelection([.signal, .whatsapp])

    public var isEmpty: Bool { enabled.isEmpty }
    public func includes(_ kind: ChannelKind) -> Bool { enabled.contains(kind) }

    /// In front of the owner. "Signal and WhatsApp", not "signal, whatsapp".
    public var summary: String {
        let names = ChannelKind.allCases
            .filter(enabled.contains)
            .map(\.displayName)
        switch names.count {
        case 0: return "nothing yet"
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }
}
