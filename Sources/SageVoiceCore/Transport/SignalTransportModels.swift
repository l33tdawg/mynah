import Foundation

// MARK: - Errors

public enum SignalTransportError: Error, CustomStringConvertible, Equatable {
    case emptyAllowlist
    case invalidAllowlistEntry(String)
    case invalidEndpoint(String)
    case socketPathTooLong(String)
    case connectFailed(String)
    case socketReadFailed(String)
    case socketWriteFailed(String)
    case oversizedFrame(Int)
    case notConnected
    case requestTimedOut(method: String, seconds: TimeInterval)
    case rpcError(code: Int, message: String)
    case malformedResponse(String)
    case noReplyRecipient

    public var description: String {
        switch self {
        case .emptyAllowlist:
            return "Signal sender allowlist is empty. This daemon refuses to run without an explicit allowlist."
        case .invalidAllowlistEntry(let entry):
            return "Allowlist entry is neither an E.164 phone number nor a Signal service id (UUID): \(entry)"
        case .invalidEndpoint(let detail):
            return "Invalid signal-cli endpoint: \(detail)"
        case .socketPathTooLong(let path):
            return "UNIX socket path is too long for sockaddr_un: \(path)"
        case .connectFailed(let detail):
            return "Could not connect to the signal-cli JSON-RPC daemon. \(detail)"
        case .socketReadFailed(let detail):
            return "Read from the signal-cli socket failed: \(detail)"
        case .socketWriteFailed(let detail):
            return "Write to the signal-cli socket failed: \(detail)"
        case .oversizedFrame(let bytes):
            return "signal-cli sent a JSON-RPC frame larger than the \(bytes) byte limit without a newline."
        case .notConnected:
            return "Not connected to the signal-cli JSON-RPC daemon."
        case .requestTimedOut(let method, let seconds):
            return "signal-cli did not answer \(method) within \(Int(seconds.rounded()))s."
        case .rpcError(let code, let message):
            return "signal-cli returned JSON-RPC error \(code): \(message)"
        case .malformedResponse(let detail):
            return "Could not parse the signal-cli response: \(detail)"
        case .noReplyRecipient:
            return "The incoming message carries no usable reply recipient."
        }
    }
}

// MARK: - Endpoint

/// How to reach the `signal-cli daemon` JSON-RPC interface.
///
/// `signal-cli -a ACCOUNT daemon --socket[=PATH]` exports a UNIX socket,
/// `--tcp[=HOST:PORT]` a TCP socket (default `localhost:7583`).
/// Prefer the UNIX socket: it inherits filesystem permissions, whereas the TCP
/// listener is reachable by every local process and user on the machine.
public enum SignalEndpoint: Equatable, Sendable, CustomStringConvertible {
    case unixSocket(path: String)
    case tcp(host: String, port: Int)

    /// The socket path this project asks the operator to pass to `--socket=`.
    public static func defaultUnixSocket(homeDirectory: String = NSHomeDirectory()) -> SignalEndpoint {
        .unixSocket(path: "\(homeDirectory)/.local/share/signal-cli/daemon.socket")
    }

    /// signal-cli's own default when `--tcp` is given without a value.
    public static let defaultTCP = SignalEndpoint.tcp(host: "127.0.0.1", port: 7583)

    public var description: String {
        switch self {
        case .unixSocket(let path):
            return "unix:\(path)"
        case .tcp(let host, let port):
            return "tcp:\(host):\(port)"
        }
    }
}

// MARK: - Recipients

public enum SignalRecipient: Equatable, Sendable, CustomStringConvertible {
    /// An E.164 number or a Signal service id (UUID). Passed as the `recipient` param.
    case account(String)
    /// A base64 group id. Passed as the `groupId` param.
    case group(base64ID: String)

    public var description: String {
        switch self {
        case .account(let value):
            return value
        case .group(let id):
            return "group:\(id)"
        }
    }
}

// MARK: - Attachments

/// One entry of `dataMessage.attachments[]` in a signal-cli `receive` notification.
///
/// signal-cli only reports attachment *metadata* over JSON-RPC; the decrypted bytes
/// are written to `<data-dir>/attachments/`. `localURL` is this library resolving
/// that file for you (see `SignalAttachmentLocator`).
///
/// **The same shape as a WhatsApp attachment, so it is the same type.** This was
/// its own struct with its own `isAudio`/`isImage`, and WhatsApp needed both
/// rules verbatim — a second copy would have let "is this a picture" answer
/// differently depending on which app the owner happened to use. The fields and
/// the rules now live on `ChannelAttachment`; the Signal name stays because the
/// parser and its tests are about signal-cli's JSON and reading `SignalAttachment`
/// there says something true.
public typealias SignalAttachment = ChannelAttachment

// MARK: - Incoming messages

/// A message the daemon is willing to look at, normalised from a signal-cli envelope.
public struct SignalIncomingMessage: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        /// `envelope.dataMessage` — somebody sent us a message.
        case direct
        /// `envelope.syncMessage.sentMessage` — the owner sent a message from another
        /// device on the same account. This is how "message yourself" (Note to Self)
        /// reaches a linked device, so it is the primary path for this product.
        case syncSent
    }

    public let kind: Kind
    /// The local account the daemon received this on (multi-account mode).
    public let account: String?
    public let source: String?
    public let sourceNumber: String?
    public let sourceUUID: String?
    public let sourceName: String?
    public let sourceDevice: Int?
    public let destination: String?
    public let destinationNumber: String?
    public let destinationUUID: String?
    public let groupID: String?
    /// Signal timestamp, milliseconds since epoch. Doubles as the message id.
    public let timestamp: Int64
    public let text: String?
    public let attachments: [SignalAttachment]

    public init(
        kind: Kind,
        account: String? = nil,
        source: String? = nil,
        sourceNumber: String? = nil,
        sourceUUID: String? = nil,
        sourceName: String? = nil,
        sourceDevice: Int? = nil,
        destination: String? = nil,
        destinationNumber: String? = nil,
        destinationUUID: String? = nil,
        groupID: String? = nil,
        timestamp: Int64,
        text: String? = nil,
        attachments: [SignalAttachment] = []
    ) {
        self.kind = kind
        self.account = account
        self.source = source
        self.sourceNumber = sourceNumber
        self.sourceUUID = sourceUUID
        self.sourceName = sourceName
        self.sourceDevice = sourceDevice
        self.destination = destination
        self.destinationNumber = destinationNumber
        self.destinationUUID = destinationUUID
        self.groupID = groupID
        self.timestamp = timestamp
        self.text = text
        self.attachments = attachments
    }

    public var date: Date {
        Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000.0)
    }

    public var isGroupMessage: Bool {
        groupID != nil
    }

    public var audioAttachments: [SignalAttachment] {
        attachments.filter(\.isAudio)
    }

    /// The first audio attachment that actually exists on disk, ready for the ASR core.
    public var voiceNoteURL: URL? {
        audioAttachments.compactMap(\.localURL).first
    }

    public var imageAttachments: [SignalAttachment] {
        attachments.filter(\.isImage)
    }

    /// Images that exist on disk, ready for a vision model.
    ///
    /// Capped, because Signal will happily send twenty photos in one message and
    /// each one costs context on a 4B model. The owner asking about "this
    /// screenshot" means the one they just sent, not a gallery.
    public var imageURLs: [URL] {
        Array(imageAttachments.compactMap(\.localURL).prefix(SignalIncomingMessage.maximumImagesPerMessage))
    }

    public static let maximumImagesPerMessage = 3

    public var hasText: Bool {
        !(text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Everything that identifies the sender, for allowlist matching.
    public var senderIdentifiers: [String] {
        [source, sourceNumber, sourceUUID].compactMap { $0 }
    }

    /// Everything that identifies who the message was addressed to. Only meaningful
    /// for `.syncSent`, where it is what distinguishes Note to Self from "the owner
    /// just texted their dentist".
    public var destinationIdentifiers: [String] {
        [destination, destinationNumber, destinationUUID].compactMap { $0 }
    }

    /// Where a reply should go.
    public var replyRecipient: SignalRecipient? {
        if let groupID {
            return .group(base64ID: groupID)
        }
        switch kind {
        case .syncSent:
            if let value = destinationNumber ?? destination ?? destinationUUID {
                return .account(value)
            }
            return nil
        case .direct:
            if let value = sourceNumber ?? source ?? sourceUUID {
                return .account(value)
            }
            return nil
        }
    }

    /// Short, log-safe rendering. Deliberately does not include message text.
    ///
    /// **It said "log-safe" for months while printing his phone number in
    /// full.** Twenty-six of them in one `bridge.log`, every one from this line
    /// — against twenty-three redacted ones written by the twin twelve files
    /// away in `SignalClient`, which remembered. The doc comment asserted a
    /// property the code did not have, which is the reason it survived review:
    /// anybody checking whether logging was safe read this sentence and moved
    /// on.
    ///
    /// The lesson is not "remember to redact". `SignalSenderAllowlist.redact`
    /// was already used everywhere else; it was applied by everybody
    /// remembering, and the one place nobody remembered leaked every message.
    /// **A convention is not a mechanism.** The mechanism here is
    /// `SignalTransportRedactionTests`, which builds a message carrying a real
    /// number and asserts it cannot be found in anything this type renders — so
    /// a future field that forgets fails rather than ships.
    public var logDescription: String {
        let sender = (sourceNumber ?? source ?? sourceUUID).map(SignalSenderAllowlist.redact)
            ?? "<unknown>"
        let shape = attachments.isEmpty ? "text" : "text+\(attachments.count) attachment(s)"
        return "\(kind.rawValue) from \(sender) at \(timestamp) (\(shape))"
    }
}

// MARK: - Log events

public enum SignalTransportEvent: Equatable, Sendable, CustomStringConvertible {
    case connected(SignalEndpoint)
    case disconnected(reason: String?)
    case reconnecting(attempt: Int, afterSeconds: TimeInterval)
    case subscribed(subscription: Int)
    /// A message was dropped before any processing. This is the security boundary firing.
    case senderRejected(sender: String, reason: SignalAllowlistDenial)
    case messageAccepted(summary: String)
    case attachmentNotFound(id: String, directory: String)
    case sent(recipient: String, timestamp: Int64)
    case warning(String)
    case failure(String)

    public var description: String {
        switch self {
        case .connected(let endpoint):
            return "connected to signal-cli at \(endpoint)"
        case .disconnected(let reason):
            return "signal-cli connection closed\(reason.map { ": \($0)" } ?? "")"
        case .reconnecting(let attempt, let seconds):
            return "reconnecting to signal-cli (attempt \(attempt)) in \(String(format: "%.1f", seconds))s"
        case .subscribed(let subscription):
            return "subscribed to receive (subscription \(subscription))"
        case .senderRejected(let sender, let reason):
            return "DROPPED message from \(sender): \(reason)"
        case .messageAccepted(let summary):
            return "accepted \(summary)"
        case .attachmentNotFound(let id, let directory):
            return "attachment \(id) was not found under \(directory); is signal-cli running with --ignore-attachments?"
        case .sent(let recipient, let timestamp):
            return "sent message to \(recipient) (timestamp \(timestamp))"
        case .warning(let detail):
            return "warning: \(detail)"
        case .failure(let detail):
            return "error: \(detail)"
        }
    }

    /// Rejections and failures must never be silently swallowed.
    public var isSecurityRelevant: Bool {
        if case .senderRejected = self {
            return true
        }
        return false
    }
}

public typealias SignalTransportLogger = @Sendable (SignalTransportEvent) -> Void

public enum SignalTransportLog {
    /// Default logger: everything to stderr, prefixed, one line each.
    public static let standardError: SignalTransportLogger = { event in
        let prefix = event.isSecurityRelevant ? "[signal][SECURITY]" : "[signal]"
        FileHandle.standardError.write(Data("\(prefix) \(event)\n".utf8))
    }

    public static let silent: SignalTransportLogger = { _ in }
}

// MARK: - Backoff

public struct SignalBackoffPolicy: Equatable, Sendable {
    public var initialSeconds: TimeInterval
    public var maximumSeconds: TimeInterval
    public var multiplier: Double
    /// Fraction of the delay to randomise, so a fleet of clients does not resynchronise.
    public var jitterFraction: Double

    public init(
        initialSeconds: TimeInterval = 0.5,
        maximumSeconds: TimeInterval = 30,
        multiplier: Double = 2,
        jitterFraction: Double = 0.2
    ) {
        self.initialSeconds = initialSeconds
        self.maximumSeconds = maximumSeconds
        self.multiplier = multiplier
        self.jitterFraction = jitterFraction
    }

    /// `attempt` is 1-based.
    public func delay(forAttempt attempt: Int) -> TimeInterval {
        guard attempt > 0 else {
            return 0
        }
        let raw = initialSeconds * pow(multiplier, Double(attempt - 1))
        let capped = min(maximumSeconds, raw)
        guard jitterFraction > 0 else {
            return capped
        }
        let spread = capped * jitterFraction
        return max(0, capped - spread + Double.random(in: 0...(2 * spread)))
    }
}
