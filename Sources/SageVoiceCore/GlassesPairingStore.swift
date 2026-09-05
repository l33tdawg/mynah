import Foundation

/// One owner-authorized G2 pairing. Never persisted in logs or chat history caches.
public struct GlassesPairingStore: Sendable {
    public struct Pairing: Codable, Sendable {
        public let token: String
        let kind: ChannelKind
        let address: String
        let identity: String?
        public var recipient: ChannelRecipient { ChannelRecipient(kind: kind, address: address, identity: identity) }
        public init(token: String, recipient: ChannelRecipient) {
            self.token = token; kind = recipient.kind; address = recipient.address; identity = recipient.identity
        }
    }
    public let url: URL
    public init(url: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".sage/g2/pairing.json")) { self.url = url }
    public func load() throws -> Pairing? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let pairing = try JSONDecoder().decode(Pairing.self, from: Data(contentsOf: url))
        guard pairing.token.count == 32, pairing.token.allSatisfy({ "0123456789abcdef".contains($0) }), !pairing.address.isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return pairing
    }
    public func save(_ pairing: Pairing) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try JSONEncoder().encode(pairing).write(to: url, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func remove() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
