import Foundation

/// A completed inbound turn whose answer has not crossed the transport yet.
/// Kept outside conversation history because an undelivered answer is not part
/// of the conversation, and outside the WhatsApp spool because that holds only
/// the question. Together the two records let a replay resend the completed
/// answer without executing its tools a second time.
struct PendingDelivery: Codable, Equatable, Sendable {
    struct Recipient: Codable, Equatable, Sendable {
        var kind: ChannelKind
        var address: String
        var identity: String?
        var isGroup: Bool

        init(_ recipient: ChannelRecipient) {
            kind = recipient.kind
            address = recipient.address
            identity = recipient.identity
            isGroup = recipient.isGroup
        }

        var channelRecipient: ChannelRecipient {
            ChannelRecipient(kind: kind, address: address, identity: identity, isGroup: isGroup)
        }
    }

    struct MessageReference: Codable, Equatable, Sendable {
        var kind: ChannelKind
        var id: String
        var acknowledgementToken: Int
        var acknowledgementEpoch: String?

        init?(_ message: ChannelMessage) {
            guard let token = message.acknowledgementToken else { return nil }
            kind = message.kind
            id = message.id
            acknowledgementToken = token
            acknowledgementEpoch = message.acknowledgementEpoch
        }
    }

    struct Turn: Codable, Equatable, Sendable {
        var role: String
        var content: String

        init(_ message: BrainMessage) {
            role = message.role.rawValue
            content = message.content
        }

        var message: BrainMessage? {
            guard let role = BrainRole(rawValue: role), role == .user || role == .assistant else {
                return nil
            }
            return BrainMessage(role: role, content: content)
        }
    }

    var key: String
    var recipient: Recipient
    var messages: [MessageReference]
    var question: String
    var reply: String
    var turns: [Turn]
    var attachmentPaths: [String]
    var promise: PromisedAnswer?
    /// Where `turns` begins in conversation history once delivery succeeds.
    /// Written to the journal before history itself is committed, so replay can
    /// distinguish this exact delivered turn from an older identical exchange.
    var historyOffset: Int?
    var createdAt: Date
}

/// A tiny durable journal. There can be more than one entry: after a transport
/// outage the owner can send another message before the first one is replayed,
/// and overwriting either completed answer would force its mutations to rerun.
public struct PendingDeliveryStore: Sendable {
    private let fileURL: URL

    public init(fileURL: URL = Self.defaultFileURL()) { self.fileURL = fileURL }

    public static func defaultFileURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/SAGE Voice Bridge", isDirectory: true)
            .appendingPathComponent("pending-deliveries.json")
    }

    private var mayTouch: Bool {
        !MynahLog.isRunningUnderXCTest
            || fileURL.standardizedFileURL != Self.defaultFileURL().standardizedFileURL
    }

    func delivery(for key: String) -> PendingDelivery? { load()[key] }

    func allDeliveries() -> [PendingDelivery] {
        load().values.sorted { $0.createdAt < $1.createdAt }
    }

    func contains(_ promise: PromisedAnswer) -> Bool {
        load().values.contains { $0.promise == promise }
    }

    @discardableResult
    func record(_ delivery: PendingDelivery) -> Bool {
        guard mayTouch else { return false }
        var all = load()
        all[delivery.key] = delivery
        return save(all)
    }

    @discardableResult
    func clear(ifStill delivery: PendingDelivery) -> Bool {
        guard mayTouch else { return false }
        var all = load()
        guard all[delivery.key] == delivery else { return false }
        all.removeValue(forKey: delivery.key)
        return save(all)
    }

    /// A delivered turn is safe to clear by identity after every one of its
    /// inbound references has been acknowledged. This also removes an older
    /// on-disk revision when a newer revision could only be held in memory.
    @discardableResult
    func clear(key: String) -> Bool {
        guard mayTouch else { return false }
        var all = load()
        guard all.removeValue(forKey: key) != nil else { return true }
        return save(all)
    }

    private func load() -> [String: PendingDelivery] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = (try? decoder.decode([String: PendingDelivery].self, from: data)) ?? [:]
        let cutoff = Date().addingTimeInterval(-ConversationStore.maximumAge)
        return decoded.filter { $0.value.createdAt >= cutoff }
    }

    private func save(_ deliveries: [String: PendingDelivery]) -> Bool {
        guard !deliveries.isEmpty else {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return true }
            do {
                try FileManager.default.removeItem(at: fileURL)
                return true
            } catch {
                return false
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(deliveries) else { return false }
        do {
            try OwnerOnlyFileSecurity.write(data, to: fileURL)
            return true
        } catch {
            return false
        }
    }
}
