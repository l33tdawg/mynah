import XCTest
@testable import SageVoiceCore

/// Files holding the owner's words are owner-only from the first byte.
///
/// `Data.write(to:options:.atomic)` creates a fresh file at 0644 and can only be
/// chmod'ed afterwards, so every first write published the contents
/// world-readable for the moment in between. Small window, on the owner's own
/// conversations and preferences — which is exactly the material that does not
/// get a small window.
final class OwnerOnlyWriteTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("owner-only-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func mode(of url: URL) throws -> NSNumber? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
    }

    func testAFirstWriteIsNeverWorldReadable() throws {
        let file = directory.appendingPathComponent("conversations.json")
        try OwnerOnlyFileSecurity.write(Data("the owner's words".utf8), to: file)

        XCTAssertEqual(try mode(of: file), 0o600)
        XCTAssertEqual(try mode(of: directory), 0o700, "the directory was left readable")
    }

    /// The failure this replaces, kept as a contrast so nobody reintroduces it
    /// thinking the chmod afterwards is equivalent.
    func testThePlainAtomicWriteThisReplacesReallyIsWorldReadable() throws {
        try OwnerOnlyFileSecurity.prepareDirectory(directory)
        let file = directory.appendingPathComponent("naive.json")
        try Data("x".utf8).write(to: file, options: .atomic)

        XCTAssertNotEqual(
            try mode(of: file),
            0o600,
            "premise changed: a plain atomic write now produces 0600, so the custom writer may be unnecessary"
        )
    }

    func testRewritingAnExistingFileKeepsItOwnerOnly() throws {
        let file = directory.appendingPathComponent("conversations.json")
        try OwnerOnlyFileSecurity.write(Data("first".utf8), to: file)
        try OwnerOnlyFileSecurity.write(Data("second".utf8), to: file)

        XCTAssertEqual(try mode(of: file), 0o600)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "second")
    }

    /// No half-written file survives a failure, and no staging file is left
    /// behind — the daemon is killed by `pkill` on every deploy.
    func testNoStagingFilesAreLeftBehind() throws {
        let file = directory.appendingPathComponent("conversations.json")
        try OwnerOnlyFileSecurity.write(Data("content".utf8), to: file)

        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(contents, ["conversations.json"], "left temporary files in the owner's directory")
    }
}
