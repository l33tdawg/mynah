import XCTest
@testable import SageVoiceCore

/// Listing what the appliance has kept, and deleting only that.
///
/// Three directories have accumulated for the life of the appliance with nothing
/// listing them — notes Mynah wrote, documents converted from them, and every
/// file the owner has ever sent over Signal. The owner: *"we can't view or
/// remove files"*.
///
/// The listing half is ordinary. The removing half is the one worth testing:
/// this is the only code in the app that deletes the owner's own files, and the
/// argument `StoredFiles` makes about never parsing a path has to hold at least
/// as strongly here, because sending the wrong file is recoverable and deleting
/// it is not.
final class SavedFilesTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mynah-files-\(UUID().uuidString)", isDirectory: true)
        for sub in ["", "documents", "attachments"] {
            try FileManager.default.createDirectory(
                at: sub.isEmpty ? root : root.appendingPathComponent(sub, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Listing

    /// Each of the three places, named as the owner would name it.
    func testEachPlaceIsListedAsWhatItIs() throws {
        try write("groceries.md", in: nil)
        try write("budget.pdf", in: "documents")
        try write("ferry-ticket.png", in: "attachments")

        let found = SavedFilesStore(notesDirectory: root).all()

        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: found.map { ($0.name, $0.kind) }),
            [
                "groceries.md": .note,
                "budget.pdf": .document,
                "ferry-ticket.png": .attachment,
            ],
            "\(found.map { "\($0.name):\($0.kind)" })"
        )
    }

    /// **`documents` and `attachments` live inside the notes root.**
    ///
    /// So a listing that recursed, or that did not filter the root to markdown,
    /// would show every document twice — once correctly and once as a "note" —
    /// and the owner would delete one and watch the other stay.
    func testFilesInTheSubfoldersAreNotAlsoListedAsNotes() throws {
        try write("budget.pdf", in: "documents")
        try write("ferry-ticket.png", in: "attachments")

        let found = SavedFilesStore(notesDirectory: root).all()

        XCTAssertEqual(found.count, 2, "listed twice: \(found.map(\.name))")
        XCTAssertEqual(
            found.filter { $0.kind == .note }, [],
            "a document was also counted as a note, so removing it would half-work"
        )
    }

    /// Newest first, which is what somebody looking for what they just sent
    /// wants.
    func testTheNewestIsFirst() throws {
        try write("old.md", in: nil, modified: Date(timeIntervalSinceNow: -6_000))
        try write("new.md", in: nil, modified: Date())

        let found = SavedFilesStore(notesDirectory: root).all()

        XCTAssertEqual(found.map(\.name), ["new.md", "old.md"])
    }

    /// **A small file must not read as an empty one.**
    ///
    /// The owner, looking at the Files list: *"we seem to be storing .md files
    /// of the task along with the file itself"* — pointing at a companion note
    /// shown as `0 KB` next to the photo it describes. The note was 274 bytes
    /// and perfectly fine; `ByteCountFormatter` with `.useKB` as its smallest
    /// unit rounds anything under half a kilobyte to zero.
    ///
    /// Worth its own test because the sizes this screen is worst at are the
    /// ones it shows most often: every attachment writes a companion note of a
    /// few hundred bytes.
    func testASmallFileDoesNotReadAsAnEmptyOne() {
        let note = SavedFile(
            path: "/tmp/x.md", name: "x.md", kind: .note, bytes: 274, saved: Date()
        )

        XCTAssertFalse(
            note.readableSize.hasPrefix("0"),
            """
            a 274-byte note is displayed as "\(note.readableSize)", which reads \
            as an empty file the appliance wrote for no reason
            """
        )
        XCTAssertTrue(
            note.readableSize.localizedCaseInsensitiveContains("byte"),
            "expected bytes for a sub-kilobyte file, got \(note.readableSize)"
        )
    }

    /// And the units still work upwards, so the fix is not "always bytes".
    func testALargeFileStillReadsInKilobytes() {
        let photo = SavedFile(
            path: "/tmp/p.jpg", name: "p.jpg", kind: .attachment, bytes: 218_000, saved: Date()
        )
        XCTAssertTrue(
            photo.readableSize.contains("KB") || photo.readableSize.contains("MB"),
            "a 218 KB photo is displayed as \(photo.readableSize)"
        )
    }

    // MARK: Removing

    func testAFileThatIsOursIsRemoved() throws {
        try write("budget.pdf", in: "documents")
        let store = SavedFilesStore(notesDirectory: root)
        let file = try XCTUnwrap(store.all().first)

        try store.remove(file)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: file.path),
            "the row disappeared from the screen and the file is still on disk"
        )
        XCTAssertEqual(store.all(), [], "\(store.all())")
    }

    /// **The one that matters.** A `SavedFile` built by anything other than a
    /// real directory listing must not be able to delete outside the tree.
    ///
    /// Traversal is the shape to check, because the path is a plain string on
    /// the value: `…/attachments/../../something` resolves out of the tree
    /// entirely, and a prefix check on the unresolved string would accept it.
    func testAPathOutsideTheTreeIsRefusedEvenIfItLooksLikeItIsInside() throws {
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("not-ours-\(UUID().uuidString).txt")
        try "keep me".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }

        let store = SavedFilesStore(notesDirectory: root)
        let traversal = SavedFile(
            path: root.appendingPathComponent("attachments")
                .appendingPathComponent("..")
                .appendingPathComponent("..")
                .appendingPathComponent(outside.lastPathComponent).path,
            name: outside.lastPathComponent,
            kind: .attachment,
            bytes: 7,
            saved: Date()
        )

        XCTAssertThrowsError(try store.remove(traversal)) { error in
            guard case SavedFilesStore.Trouble.notOurs = error else {
                return XCTFail("refused for the wrong reason: \(error)")
            }
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: outside.path),
            "a file outside the appliance's own directories was deleted"
        )
    }

    /// And a plainly foreign path, which is the same rule stated without the
    /// disguise.
    func testAFileSomewhereElseEntirelyIsRefused() throws {
        let store = SavedFilesStore(notesDirectory: root)
        let elsewhere = SavedFile(
            path: "/etc/hosts", name: "hosts", kind: .note, bytes: 1, saved: Date()
        )

        XCTAssertThrowsError(try store.remove(elsewhere))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "/etc/hosts"))
    }

    /// Nested one level down is still not one of the three, and must be refused
    /// rather than accepted for merely being under the root.
    func testSomethingNestedDeeperIsNotOurs() throws {
        let deeper = root.appendingPathComponent("attachments/inner", isDirectory: true)
        try FileManager.default.createDirectory(at: deeper, withIntermediateDirectories: true)
        let file = deeper.appendingPathComponent("x.png")
        try "x".write(to: file, atomically: true, encoding: .utf8)

        let store = SavedFilesStore(notesDirectory: root)
        XCTAssertThrowsError(
            try store.remove(
                SavedFile(path: file.path, name: "x.png", kind: .attachment, bytes: 1, saved: Date())
            ),
            "anything under the root was treated as removable, which is a prefix check not a parent check"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: Fixtures

    private func write(_ name: String, in folder: String?, modified: Date? = nil) throws {
        let directory = folder.map { root.appendingPathComponent($0, isDirectory: true) } ?? root!
        let file = directory.appendingPathComponent(name)
        try "contents of \(name)".write(to: file, atomically: true, encoding: .utf8)
        if let modified {
            try FileManager.default.setAttributes(
                [.modificationDate: modified], ofItemAtPath: file.path
            )
        }
    }
}
