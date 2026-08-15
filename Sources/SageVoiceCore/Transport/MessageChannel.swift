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
    /// The channel's own address, in the channel's own form. **What a reply is
    /// sent to**, and never anything else — see `identity`.
    public let address: String
    /// The same chat, named in a way that does not change when the transport
    /// changes how it addresses it. `nil` when the address is already stable,
    /// which is Signal always and WhatsApp whenever the bridge could resolve it.
    ///
    /// **These are two different things and conflating them cost a
    /// conversation.** WhatsApp is migrating to LID addressing: the owner's own
    /// chat arrived on 7 August as `161228928336031@lid`, not as his number.
    /// That form is a property of the transport at a moment in time, so keying
    /// history on it means the same person becomes a second conversation the
    /// day WhatsApp changes its mind — the appliance forgets mid-sentence, with
    /// nothing on any screen to say why. It is the defect the Signal thread key
    /// had to be migrated for, one release earlier, on the other channel.
    ///
    /// Replying still goes to `address`. WhatsApp may not accept the phone JID
    /// for a chat it is addressing by LID, and the first working exchange went
    /// out over the LID — so this must not become "resolve it and use that
    /// everywhere", which is the obvious fix and would break sending.
    public let identity: String?
    public let isGroup: Bool

    public init(kind: ChannelKind, address: String, identity: String? = nil, isGroup: Bool = false) {
        self.kind = kind
        self.address = address
        // Stored as nil when it says nothing new, so `addressDescription` and
        // `description` differ only when there is a real distinction to make.
        self.identity = identity == address ? nil : identity
        self.isGroup = isGroup
    }

    /// The conversation key. Stable across a change of address form.
    public var description: String {
        "\(kind.rawValue):\(isGroup ? "group:" : "")\(identity ?? address)"
    }

    /// What `description` would have been if the address were the identity.
    ///
    /// Equal to `description` unless the transport is addressing this chat by
    /// something other than its stable name. Exists so a conversation filed
    /// under an older address form can still be found — see
    /// `VoiceBridgeDaemon.adoptingEarlierAddressForm`.
    public var addressDescription: String {
        "\(kind.rawValue):\(isGroup ? "group:" : "")\(address)"
    }
}

/// One file that arrived with a message, already decrypted onto disk.
///
/// **Not `[String]` of paths, which is what this was.** The daemon has to know
/// three things a path cannot answer: is this the voice note that *is* the
/// message (transcribe it, do not file it), is it a picture (show the model),
/// or is it a document (keep it for later). Signal answers those from the MIME
/// type with the extension as a fallback, because signal-cli reports voice
/// notes as `audio/aac` with no filename at all. WhatsApp has the same problem
/// and the same answer, so the rule lives here once rather than being re-derived
/// per channel — two copies of "is this a picture" is how a photo becomes a
/// document on one channel and not the other.
public struct ChannelAttachment: Equatable, Sendable {
    public let id: String
    public let contentType: String?
    /// Filename chosen by the sender. Voice notes normally have none.
    public let filename: String?
    public let size: Int64?
    public let caption: String?
    /// The decrypted file on disk, if it could be found.
    public let localURL: URL?

    public init(
        id: String,
        contentType: String? = nil,
        filename: String? = nil,
        size: Int64? = nil,
        caption: String? = nil,
        localURL: URL? = nil
    ) {
        self.id = id
        self.contentType = contentType
        self.filename = filename
        self.size = size
        self.caption = caption
        self.localURL = localURL
    }

    /// Neither channel has a protocol-level "voice note" flag that survives into
    /// what we are handed, so audio is detected from the MIME type, falling back
    /// to the extension. Signal voice notes arrive as `audio/aac` with no
    /// filename; WhatsApp's are `audio/ogg; codecs=opus`.
    public var isAudio: Bool {
        if let contentType, !contentType.isEmpty {
            let normalized = contentType.lowercased()
            if normalized.hasPrefix("audio/") {
                return true
            }
            if normalized.hasPrefix("video/") || normalized.hasPrefix("image/") {
                return false
            }
        }
        guard let ext = Self.fileExtension(of: filename ?? localURL?.lastPathComponent) else {
            return false
        }
        return SignalAttachmentLocator.audioFileExtensions.contains(ext)
    }

    /// A still image a vision model could look at.
    ///
    /// MIME type first, extension as the fallback, mirroring `isAudio` — and
    /// like it, this has to answer for attachments reported with no filename at
    /// all.
    ///
    /// GIFs are excluded on purpose: Signal sends them as `video/mp4`, WhatsApp
    /// sends them as a video too, and the ones that do arrive as `image/gif` are
    /// animations whose first frame is rarely the point.
    public var isImage: Bool {
        if let contentType, !contentType.isEmpty {
            let normalized = contentType.lowercased()
            if normalized == "image/gif" {
                return false
            }
            if normalized.hasPrefix("image/") {
                return true
            }
            if normalized.hasPrefix("audio/") || normalized.hasPrefix("video/") {
                return false
            }
        }
        guard let ext = Self.fileExtension(of: filename ?? localURL?.lastPathComponent) else {
            return false
        }
        return Self.imageFileExtensions.contains(ext)
    }

    static let imageFileExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp", "tiff", "bmp"]

    /// A video copied into the owner's self-chat. MIME is authoritative when
    /// present; MP4/MOV extension fallback covers transports that omit it.
    public var isVideo: Bool {
        if let contentType, !contentType.isEmpty {
            let normalized = contentType.lowercased()
                .split(separator: ";", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if ["video/mp4", "video/quicktime", "video/x-quicktime"].contains(normalized) {
                return true
            }
            if !["application/octet-stream", "binary/octet-stream"].contains(normalized) {
                return false
            }
        }
        guard let ext = Self.fileExtension(of: filename ?? localURL?.lastPathComponent) else {
            return false
        }
        return Self.videoFileExtensions.contains(ext)
    }

    static let videoFileExtensions: Set<String> = ["mp4", "mov"]

    /// Any video, used only to give non-MP4/MOV formats the normal actionable
    /// attachment path instead of mistaking them for passive self-chat copies.
    public var isAnyVideo: Bool {
        if let contentType, contentType.lowercased().hasPrefix("video/") { return true }
        guard let ext = Self.fileExtension(of: filename ?? localURL?.lastPathComponent) else {
            return false
        }
        return Self.videoFileExtensions.union(["webm", "mkv", "avi", "m4v"]).contains(ext)
    }

    private static func fileExtension(of name: String?) -> String? {
        guard let name, let dot = name.lastIndex(of: "."), dot != name.index(before: name.endIndex) else {
            return nil
        }
        return String(name[name.index(after: dot)...]).lowercased()
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
    public let attachments: [ChannelAttachment]
    /// Seconds since epoch.
    public let timestamp: Int64

    /// What `acknowledge` needs to retire this message, when the channel has
    /// such a concept. `nil` for Signal.
    public let acknowledgementToken: Int?

    /// Which run of the channel's numbering `acknowledgementToken` belongs to.
    ///
    /// **Carried on the message because a turn outlives the thing it is a
    /// token for.** A minute is an ordinary turn, and a spool recreated inside
    /// that minute renumbers from 1 — so the token this message is holding then
    /// names a different message, or none. Without the epoch travelling
    /// alongside it, retiring this message would retire that one.
    public let acknowledgementEpoch: String?

    public init(
        kind: ChannelKind,
        recipient: ChannelRecipient,
        id: String,
        senderDisplayName: String? = nil,
        text: String? = nil,
        attachments: [ChannelAttachment] = [],
        timestamp: Int64 = 0,
        acknowledgementToken: Int? = nil,
        acknowledgementEpoch: String? = nil
    ) {
        self.kind = kind
        self.recipient = recipient
        self.id = id
        self.senderDisplayName = senderDisplayName
        self.text = text
        self.attachments = attachments
        self.timestamp = timestamp
        self.acknowledgementToken = acknowledgementToken
        self.acknowledgementEpoch = acknowledgementEpoch
    }

    public var attachmentPaths: [String] { attachments.compactMap { $0.localURL?.path } }

    public var audioAttachments: [ChannelAttachment] { attachments.filter(\.isAudio) }

    /// The first audio attachment that actually exists on disk, ready for ASR.
    public var voiceNoteURL: URL? { audioAttachments.compactMap(\.localURL).first }

    public var imageAttachments: [ChannelAttachment] { attachments.filter(\.isImage) }

    /// Images that exist on disk, ready for a vision model.
    ///
    /// Capped, because either channel will happily carry twenty photos in one
    /// message and each one costs context on a 4B model. The owner asking about
    /// "this screenshot" means the one they just sent, not a gallery.
    public var imageURLs: [URL] {
        Array(imageAttachments.compactMap(\.localURL).prefix(Self.maximumImagesPerMessage))
    }

    public static let maximumImagesPerMessage = 3

    public var hasText: Bool {
        !(text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Textless video in a self-chat is a passive device-to-device copy, not a
    /// request to archive or analyse it. A caption makes the same attachment an
    /// ordinary actionable message. Mixed attachment batches are not guessed at.
    public var isPassiveVideoCopy: Bool {
        !recipient.isGroup
            && !hasText
            && !attachments.isEmpty
            && attachments.allSatisfy(\.isVideo)
            && attachments.allSatisfy {
                ($0.caption ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
    }

    /// Short, log-safe rendering. Deliberately does not include message text.
    ///
    /// **The Signal twin of this line printed the owner's phone number in full
    /// for months**, twenty-six times in one `bridge.log`, while its doc comment
    /// said "log-safe" — see `SignalIncomingMessage.logDescription`, which keeps
    /// the whole account. The mechanism that stops it recurring is
    /// `SignalTransportRedactionTests`, and it now builds a WhatsApp message as
    /// well as a Signal one: a JID carries the owner's number too, with no `+`
    /// in front of it.
    public var logDescription: String {
        let sender = SignalSenderAllowlist.redact(recipient.address)
        let shape = attachments.isEmpty ? "text" : "text+\(attachments.count) attachment(s)"
        return "\(kind.rawValue) from \(sender) at \(timestamp) (\(shape))"
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
public struct ChannelSelection: Equatable, Hashable, Sendable, Codable {
    public var enabled: Set<ChannelKind>

    public init(_ enabled: Set<ChannelKind> = []) {
        self.enabled = enabled
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case unknown(String)

        public var description: String {
            switch self {
            case .unknown(let name):
                return "'\(name)' is not a channel. Choose from "
                    + ChannelKind.allCases.map(\.rawValue).joined(separator: ", ")
                    + " — or several, comma-separated, for more than one at once."
            }
        }
    }

    /// What the daemon's `--channels` flag and the app's stored setting both
    /// parse. One reader, so a value the app writes cannot mean something else
    /// to the process that has to act on it.
    ///
    /// An empty string is the empty selection rather than an error, matching
    /// `ChannelSelection.none`: an appliance nobody can message is a real state
    /// during setup, and refusing to parse it would make the UI's own "neither
    /// yet" unrepresentable.
    public init(commaSeparated raw: String) throws {
        var found: Set<ChannelKind> = []
        for piece in raw.split(separator: ",") {
            let name = piece.trimmingCharacters(in: .whitespaces).lowercased()
            if name.isEmpty { continue }
            guard let kind = ChannelKind(rawValue: name) else { throw Failure.unknown(name) }
            found.insert(kind)
        }
        self.enabled = found
    }

    public static let none = ChannelSelection([])
    public static let signalOnly = ChannelSelection([.signal])
    public static let whatsAppOnly = ChannelSelection([.whatsapp])
    public static let both = ChannelSelection([.signal, .whatsapp])

    public var isEmpty: Bool { enabled.isEmpty }
    public func includes(_ kind: ChannelKind) -> Bool { enabled.contains(kind) }

    /// This selection plus one more channel.
    ///
    /// **Adding rather than replacing, and that is the whole reason it exists.**
    /// The setup screen offers Signal and WhatsApp side by side, so somebody who
    /// links one and then the other must not have the first switched off by the
    /// second. Writing `.whatsAppOnly` at that call site is the obvious thing
    /// and it silently unlinks a channel the owner just finished setting up.
    public func adding(_ kind: ChannelKind) -> ChannelSelection {
        ChannelSelection(enabled.union([kind]))
    }

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
