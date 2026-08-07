import Foundation

/// Why a message was refused. Every refusal is logged; nothing else is done with the message.
public enum SignalAllowlistDenial: Equatable, Sendable, CustomStringConvertible {
    case senderNotAllowlisted
    case unidentifiedSender
    case groupMessagesNotAllowed
    /// A `syncMessage.sentMessage` addressed to somebody other than an allowlisted id.
    /// Without this rule, every message the owner sends to anyone from their phone would
    /// be replayed to this daemon as a command.
    case syncDestinationNotAllowlisted
    case accountNotAllowlisted

    public var description: String {
        switch self {
        case .senderNotAllowlisted:
            return "sender is not on the allowlist"
        case .unidentifiedSender:
            return "envelope carried no parseable sender identifier"
        case .groupMessagesNotAllowed:
            return "group messages are not accepted"
        case .syncDestinationNotAllowlisted:
            return "sync-sent message was addressed to a non-allowlisted recipient"
        case .accountNotAllowlisted:
            return "message arrived on an account this client does not serve"
        }
    }
}

/// The security boundary in front of the whole daemon.
///
/// There is deliberately no "allow everything" constructor and no default value:
/// `SignalClient.Configuration` cannot be built without one of these, and one of these
/// cannot be built from an empty list. Failing to configure it is a compile error or a
/// throw at startup, never a silently open door.
public struct SignalSenderAllowlist: Equatable, Sendable, CustomStringConvertible {
    /// A normalised Signal identity. Anything that cannot be normalised into one of these
    /// can never match, which makes matching fail-closed.
    public enum Identity: Hashable, Sendable, CustomStringConvertible {
        /// E.164, e.g. `+60123456789`.
        case phoneNumber(String)
        /// Signal service id (ACI or PNI), lowercased UUID.
        case serviceID(String)

        public var description: String {
            switch self {
            case .phoneNumber(let value):
                return value
            case .serviceID(let value):
                return value
            }
        }
    }

    /// How `.syncSent` envelopes are treated.
    ///
    /// A `.syncSent` envelope is "the owner sent a message from another device".
    /// Only *Note to Self* is a command to this daemon; everything else is the
    /// owner talking to another human and must not be executed.
    public enum SyncDestinationRule: Equatable, Sendable {
        /// Destination must be the linked account itself. The only safe default.
        case noteToSelfOnly
        /// Destination merely has to be on the allowlist.
        ///
        /// UNSAFE with more than one allowlist entry: if a colleague is
        /// allowlisted so they can issue commands, then every message the owner
        /// sends *to* that colleague also becomes an executed fleet command, and
        /// the agent's reply is delivered into the colleague's thread.
        case anyAllowlistedDestination
        /// No destination check at all. Test-only.
        case unrestricted
    }

    public struct Policy: Equatable, Sendable {
        /// Group traffic is off by default: a group is by definition other people's inbox.
        public var allowGroupMessages: Bool
        /// How `.syncSent` (owner-sent-from-another-device) envelopes are gated.
        public var syncDestinationRule: SyncDestinationRule
        /// Optional second gate for multi-account daemons: only serve these accounts.
        public var servedAccounts: Set<String>

        public init(
            allowGroupMessages: Bool = false,
            syncDestinationRule: SyncDestinationRule = .noteToSelfOnly,
            servedAccounts: Set<String> = []
        ) {
            self.allowGroupMessages = allowGroupMessages
            self.syncDestinationRule = syncDestinationRule
            self.servedAccounts = servedAccounts
        }

        public static let strict = Policy()
    }

    public enum Decision: Equatable, Sendable {
        case allow
        case deny(SignalAllowlistDenial)

        public var isAllowed: Bool {
            self == .allow
        }
    }

    public let identities: Set<Identity>
    public let policy: Policy

    /// - Throws: `SignalTransportError.emptyAllowlist` if `entries` yields nothing,
    ///           `SignalTransportError.invalidAllowlistEntry` for anything unparseable.
    public init(entries: [String], policy: Policy = .strict) throws {
        var identities: Set<Identity> = []
        for entry in entries {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }
            guard let identity = Self.normalize(trimmed) else {
                throw SignalTransportError.invalidAllowlistEntry(trimmed)
            }
            identities.insert(identity)
        }
        guard !identities.isEmpty else {
            throw SignalTransportError.emptyAllowlist
        }
        self.identities = identities
        self.policy = policy
    }

    /// Convenience for config files / launchd plists: `"+6012...,+6019...,uuid"`.
    public init(commaSeparated: String, policy: Policy = .strict) throws {
        try self.init(
            entries: commaSeparated.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" }).map(String.init),
            policy: policy
        )
    }

    /// Reads the allowlist from an environment variable. Throws (rather than defaulting
    /// to open) when the variable is missing or empty.
    public static func fromEnvironment(
        _ name: String = "SAGE_SIGNAL_ALLOWLIST",
        environment: [String: String] = ProcessInfo.processInfo.environment,
        policy: Policy = .strict
    ) throws -> SignalSenderAllowlist {
        guard let raw = environment[name], !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SignalTransportError.emptyAllowlist
        }
        return try SignalSenderAllowlist(commaSeparated: raw, policy: policy)
    }

    public var description: String {
        let rendered = identities.map(\.description).sorted().map(Self.redact).joined(separator: ", ")
        return "SignalSenderAllowlist(\(rendered))"
    }

    // MARK: Evaluation

    public func evaluate(_ message: SignalIncomingMessage) -> Decision {
        if !policy.servedAccounts.isEmpty {
            guard let account = message.account, policy.servedAccounts.contains(account) else {
                return .deny(.accountNotAllowlisted)
            }
        }

        if message.isGroupMessage && !policy.allowGroupMessages {
            return .deny(.groupMessagesNotAllowed)
        }

        let senders = Self.normalizeAll(message.senderIdentifiers)
        guard !senders.isEmpty else {
            return .deny(.unidentifiedSender)
        }
        guard !senders.isDisjoint(with: identities) else {
            return .deny(.senderNotAllowlisted)
        }

        if message.kind == .syncSent && !message.isGroupMessage {
            let destinations = Self.normalizeAll(message.destinationIdentifiers)
            switch policy.syncDestinationRule {
            case .noteToSelfOnly:
                // The destination must be the linked account itself. Anything
                // else is the owner talking to another person, not to us.
                //
                // Fail closed: if the envelope carries no account (so we cannot
                // prove it was Note to Self) we deny, rather than falling back
                // to the weaker allowlist-membership check.
                guard let account = message.account,
                      let accountIdentity = Self.normalize(account) else {
                    return .deny(.syncDestinationNotAllowlisted)
                }
                guard destinations.contains(accountIdentity) else {
                    return .deny(.syncDestinationNotAllowlisted)
                }
            case .anyAllowlistedDestination:
                guard !destinations.isEmpty, !destinations.isDisjoint(with: identities) else {
                    return .deny(.syncDestinationNotAllowlisted)
                }
            case .unrestricted:
                break
            }
        }

        return .allow
    }

    public func permits(_ message: SignalIncomingMessage) -> Bool {
        evaluate(message).isAllowed
    }

    public func contains(_ rawIdentifier: String) -> Bool {
        guard let identity = Self.normalize(rawIdentifier) else {
            return false
        }
        return identities.contains(identity)
    }

    // MARK: Normalisation

    static func normalizeAll(_ raw: [String]) -> Set<Identity> {
        Set(raw.compactMap(normalize))
    }

    /// Returns `nil` for anything that is not recognisably a Signal identity.
    /// Callers treat `nil` as "cannot match", never as "matches everything".
    public static func normalize(_ raw: String) -> Identity? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return nil
        }

        // Signal renders PNIs as "PNI:<uuid>".
        if value.uppercased().hasPrefix("PNI:") {
            value = String(value.dropFirst(4))
        }
        if let uuid = normalizedUUID(value) {
            return .serviceID(uuid)
        }
        if let number = normalizedPhoneNumber(value) {
            return .phoneNumber(number)
        }
        return nil
    }

    static func normalizedUUID(_ value: String) -> String? {
        guard value.count == 36, UUID(uuidString: value) != nil else {
            return nil
        }
        return value.lowercased()
    }

    static func normalizedPhoneNumber(_ value: String) -> String? {
        var digits = ""
        for character in value {
            if character.isNumber {
                digits.append(character)
            } else if character == "+" && digits.isEmpty {
                continue
            } else if character == " " || character == "-" || character == "(" || character == ")" || character == "." {
                continue
            } else {
                return nil
            }
        }
        // E.164: leading digit 1-9, 7 to 15 digits total.
        guard digits.count >= 7, digits.count <= 15, let first = digits.first, first != "0" else {
            return nil
        }
        return "+" + digits
    }

    /// Keeps enough of an identifier to correlate log lines without printing the owner's
    /// full phone number into a log file.
    /// Redacts every phone-number-shaped run inside an arbitrary log line.
    ///
    /// **This exists because `redact` is a convention and conventions lose.**
    /// `redact` was already available, already used in eleven places, and the
    /// two places that forgot it wrote the owner's number into `bridge.log`
    /// twenty-six times — one of them under a doc comment promising the line was
    /// "log-safe". Fixing those two call sites fixes today; it does nothing
    /// about the next line somebody adds.
    ///
    /// So this is applied once, at the daemon's single log seam, to whatever a
    /// caller hands it. A future call site that interpolates a raw recipient is
    /// then wrong in a way that does not reach disk.
    ///
    /// The pattern is deliberately narrow — `+` then 7 to 15 digits, which is
    /// E.164 and is not any other number this daemon logs. Signal timestamps are
    /// thirteen bare digits with no `+`, durations carry a decimal point, and
    /// attachment counts are small. Running it over an already-redacted string
    /// is a no-op, because `+60******767` no longer matches.
    ///
    /// **The second alternative is WhatsApp, and leaving it out would have
    /// repeated the exact leak this function exists to end.** A WhatsApp address
    /// is `60123456789@s.whatsapp.net` — the same number, with no `+` in front
    /// of it, so the E.164 pattern above sees nothing and every JID the daemon
    /// logged would have gone to disk in full. `@` is what makes the bare digit
    /// run safe to match: a Signal timestamp is thirteen bare digits too, and
    /// nothing else this daemon logs puts one immediately before an `@`. Group
    /// JIDs (`120363…@g.us`) and LID addresses (`…@lid`) are the same shape and
    /// are covered by the same branch.
    ///
    /// It is not a claim that nothing sensitive can reach a log. It is one
    /// specific thing — the identifier that is also a way to contact him — made
    /// structurally unable to arrive there by accident.
    public static func redactingNumbers(in line: String) -> String {
        guard let pattern = try? NSRegularExpression(pattern: #"\+\d{7,15}|\d{7,20}(?=@)"#) else { return line }
        let text = line as NSString
        var result = line
        let matches = pattern.matches(in: line, range: NSRange(location: 0, length: text.length))
        // Backwards, so each replacement leaves the earlier ranges valid.
        for match in matches.reversed() {
            let found = text.substring(with: match.range)
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: redact(found))
        }
        return result
    }

    public static func redact(_ identifier: String) -> String {
        guard identifier.count > 6 else {
            return String(repeating: "*", count: identifier.count)
        }
        let head = identifier.prefix(3)
        let tail = identifier.suffix(3)
        return "\(head)\(String(repeating: "*", count: identifier.count - 6))\(tail)"
    }
}
