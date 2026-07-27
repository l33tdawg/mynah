import XCTest
@testable import SageVoiceCore

final class ImageAttachmentPathTests: XCTestCase {
    func testRealWorldJPEGAttachmentIsFoundAndClassified() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("imgtest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Exactly what is on the appliance right now.
        let id = "64Q-B3y70-w9M1WAji98"
        try Data([0xFF, 0xD8, 0xFF]).write(to: dir.appendingPathComponent("\(id).jpg"))

        let envelope: [String: Any] = [
            "attachments": [["id": id, "contentType": "image/jpeg", "size": 46186]]
        ]
        let found = SignalEnvelopeParser.attachments(
            from: envelope, directory: dir, fileManager: .default
        )
        XCTAssertEqual(found.count, 1)
        XCTAssertTrue(found[0].isImage, "image/jpeg must classify as an image")
        XCTAssertNotNil(found[0].localURL, "the .jpg on disk must be located")
    }

    /// signal-cli often reports no contentType at all.
    func testJPEGWithNoContentTypeStillClassifies() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("imgtest2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = "NoTypeAttachment01"
        try Data([0xFF, 0xD8, 0xFF]).write(to: dir.appendingPathComponent("\(id).jpg"))

        let found = SignalEnvelopeParser.attachments(
            from: ["attachments": [["id": id]]], directory: dir, fileManager: .default
        )
        XCTAssertEqual(found.count, 1)
        XCTAssertNotNil(found[0].localURL)
        XCTAssertTrue(found[0].isImage, "extension fallback must classify a .jpg with no MIME type")
    }
}
