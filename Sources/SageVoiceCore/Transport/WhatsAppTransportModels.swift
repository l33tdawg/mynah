import Foundation

/// One inbound WhatsApp message, as the bridge in `whatsapp/` emits it.
///
/// The wire form is one JSON object per line — `{"seq":12,"event":{…}}` — which
/// is signal-cli's shape, so `SignalLineSocket` reads it without modification
/// and this is the only new decoding in the WhatsApp path.
///
/// Only the fields Mynah acts on are decoded. The bridge sends a good deal more
/// (poll metadata, reaction targets, read-receipt keys, quoted-message
/// ancestry) and adding a property here for each one would be inventing a
/// second, staler copy of a schema that already exists in
/// `whatsapp/bridge_helpers.js`. When one of those becomes load-bearing, decode
/// it then.
public struct WhatsAppIncomingMessage: Equatable, Sendable {

    /// The spool's sequence number, and the only thing that retires it.
    ///
    /// **Not decoration and not a message id.** The bridge keeps this message on
    /// disk until somebody acknowledges this exact number, and replays it to
    /// every consumer that connects until then. Dropping it on the floor means
    /// the message is answered again after the next restart; acknowledging it
    /// before the turn is safely recorded means the message is lost. See
    /// `whatsapp/event_spool.js`.
    public let sequence: Int

    /// WhatsApp's own id for the message. Distinct from `sequence`: this one
    /// identifies the message to WhatsApp, that one identifies it to the spool.
    public let messageID: String

    /// The conversation. `60123456789@s.whatsapp.net` for a person,
    /// `…@g.us` for a group.
    public let chatID: String

    /// Who sent it. In the Message-Yourself setup this is the owner, and it
    /// equals `chatID`.
    public let senderID: String

    /// WhatsApp's push name — what the sender calls themselves. Chosen by them,
    /// so it is a label and never an identity: `senderID` is the identity.
    public let senderName: String?

    public let isGroup: Bool

    /// The words. Empty for a message that is only an attachment, which is why
    /// this and `hasMedia` are both here rather than one being inferred.
    public let body: String

    public let hasMedia: Bool

    /// `image`, `video`, `audio`, `ptt`, `document`, `sticker`, `location`,
    /// `contact`, `reaction`, `poll`, … Left as a string on purpose: the bridge
    /// gains types as WhatsApp does, and an enum here would turn a new one into
    /// a decode failure — a message dropped for being unfamiliar, which is the
    /// opposite of what the spool is for.
    public let mediaType: String?

    /// Where the bridge saved any attachments, already decrypted.
    public let mediaPaths: [String]

    /// Seconds since epoch, as WhatsApp reports it.
    public let timestamp: Int64

    public init(
        sequence: Int,
        messageID: String,
        chatID: String,
        senderID: String,
        senderName: String? = nil,
        isGroup: Bool = false,
        body: String = "",
        hasMedia: Bool = false,
        mediaType: String? = nil,
        mediaPaths: [String] = [],
        timestamp: Int64 = 0
    ) {
        self.sequence = sequence
        self.messageID = messageID
        self.chatID = chatID
        self.senderID = senderID
        self.senderName = senderName
        self.isGroup = isGroup
        self.body = body
        self.hasMedia = hasMedia
        self.mediaType = mediaType
        self.mediaPaths = mediaPaths
        self.timestamp = timestamp
    }
}

/// Who may talk to Mynah over WhatsApp.
///
/// **The bridge already enforces an allowlist, and this one exists anyway.**
/// That is not redundancy for its own sake: the bridge's list comes from an
/// environment variable on a process this app launches, and the day somebody
/// starts the bridge by hand — debugging, or from a stale LaunchAgent written
/// by an older build — that variable is whatever they typed. This list is
/// compiled into the app and applied on the reading side, so a message from a
/// stranger cannot reach the brain even if the bridge was misconfigured.
///
/// `SignalSenderAllowlist` makes the same argument for Signal and states the
/// rule this follows: there is no way to construct one that matches everybody.
public struct WhatsAppSenderAllowlist: Equatable, Sendable, CustomStringConvertible {

    public enum Denial: Equatable, Sendable, CustomStringConvertible {
        case senderNotAllowed(String)
        case groupsNotAllowed(String)

        public var description: String {
            switch self {
            case .senderNotAllowed(let who):
                return "sender \(who) is not on the allowlist"
            case .groupsNotAllowed(let chat):
                return "group \(chat) is not answered"
            }
        }
    }

    public enum Decision: Equatable, Sendable {
        case allowed
        case denied(Denial)

        public var isAllowed: Bool { self == .allowed }
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case empty
        case notANumber(String)

        public var description: String {
            switch self {
            case .empty:
                return """
                    A WhatsApp allowlist with nobody on it would answer nobody, and one \
                    that matched everybody would answer strangers. Give at least one number.
                    """
            case .notANumber(let entry):
                return """
                    '\(entry)' is not a WhatsApp number. WhatsApp identifies people by \
                    digits — country code first, no '+', no spaces and no dashes. A '+' \
                    here does not fail loudly; it fails as an entry that never matches.
                    """
            }
        }
    }

    /// Bare digits, no `+`, no suffix. `60123456789`.
    public let numbers: Set<String>

    /// Groups are off unless asked for. A group thread is other people's
    /// conversation, and answering in one puts Mynah in front of them.
    public let answersGroups: Bool

    public init(numbers: [String], answersGroups: Bool = false) throws {
        var cleaned: Set<String> = []
        for entry in numbers {
            let trimmed = entry.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard trimmed.allSatisfy(\.isNumber) else { throw Failure.notANumber(entry) }
            cleaned.insert(trimmed)
        }
        guard !cleaned.isEmpty else { throw Failure.empty }
        self.numbers = cleaned
        self.answersGroups = answersGroups
    }

    public init(commaSeparated: String, answersGroups: Bool = false) throws {
        try self.init(
            numbers: commaSeparated.split(separator: ",").map(String.init),
            answersGroups: answersGroups
        )
    }

    /// The digits in front of the `@` — `60123456789@s.whatsapp.net` is
    /// `60123456789`, and a device suffix (`:12@…`) is dropped too.
    ///
    /// Also handles WhatsApp's `@lid` addresses, which carry an opaque id
    /// rather than a phone number. Those never match a number, and that is the
    /// correct outcome rather than a bug to work around: an allowlist that
    /// guessed at an identity it could not read would be no allowlist.
    public static func number(inJID jid: String) -> String {
        let withoutDomain = jid.split(separator: "@", maxSplits: 1).first.map(String.init) ?? jid
        let withoutDevice = withoutDomain.split(separator: ":", maxSplits: 1).first.map(String.init) ?? withoutDomain
        return withoutDevice.filter(\.isNumber)
    }

    public func decide(_ message: WhatsAppIncomingMessage) -> Decision {
        if message.isGroup && !answersGroups {
            return .denied(.groupsNotAllowed(message.chatID))
        }
        let sender = Self.number(inJID: message.senderID)
        guard !sender.isEmpty, numbers.contains(sender) else {
            return .denied(.senderNotAllowed(message.senderID))
        }
        return .allowed
    }

    public var description: String {
        "WhatsApp allowlist(\(numbers.count) number(s), groups: \(answersGroups ? "yes" : "no"))"
    }
}

public enum WhatsAppTransportError: Error, Equatable, CustomStringConvertible {
    case socketPathTooLong(String)
    case bridgeUnavailable(String)

    public var description: String {
        switch self {
        case .socketPathTooLong(let path):
            return """
                The WhatsApp events socket path is too long for the kernel (104 bytes): \
                \(path). Binding it would silently succeed on a truncated name.
                """
        case .bridgeUnavailable(let detail):
            return "The WhatsApp bridge is not reachable: \(detail)"
        }
    }
}

/// What the client tells its owner about, in the same shape
/// `SignalTransportLogger` uses so a caller can log both the same way.
public enum WhatsAppTransportEvent: Equatable, Sendable {
    case connected(String)
    case disconnected(String)
    case refused(WhatsAppSenderAllowlist.Denial)
    case failure(String)
    case note(String)
}

public typealias WhatsAppTransportLogger = @Sendable (WhatsAppTransportEvent) -> Void

public enum WhatsAppTransportLog {
    public static let standardError: WhatsAppTransportLogger = { event in
        switch event {
        case .connected(let path):    FileHandle.standardError.write(Data("[whatsapp] connected \(path)\n".utf8))
        case .disconnected(let why):  FileHandle.standardError.write(Data("[whatsapp] disconnected: \(why)\n".utf8))
        case .refused(let denial):    FileHandle.standardError.write(Data("[whatsapp] refused: \(denial)\n".utf8))
        case .failure(let detail):    FileHandle.standardError.write(Data("[whatsapp] error: \(detail)\n".utf8))
        case .note(let detail):       FileHandle.standardError.write(Data("[whatsapp] \(detail)\n".utf8))
        }
    }
    public static let silent: WhatsAppTransportLogger = { _ in }
}
