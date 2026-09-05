import XCTest
@testable import SageVoiceCore

final class GlassesPairingStoreTests: XCTestCase {
    func testPairingSurvivesRestartAndCanBeRevoked() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("pairing.json")
        let store = GlassesPairingStore(url: url)
        let recipient = ChannelRecipient(kind: .whatsapp, address: "owner@lid", identity: "owner")
        try store.save(.init(token: String(repeating: "a", count: 32), recipient: recipient))
        let restored = try XCTUnwrap(GlassesPairingStore(url: url).load())
        XCTAssertEqual(restored.recipient, recipient)
        XCTAssertEqual(restored.token, String(repeating: "a", count: 32))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try store.remove()
        XCTAssertNil(try store.load())
    }
    func testCorruptCredentialIsNotAccepted() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GlassesPairingStore(url: directory.appendingPathComponent("pairing.json"))
        try store.save(.init(token: "not-a-token", recipient: .init(kind: .signal, address: "owner")))
        XCTAssertThrowsError(try store.load())
    }
}
