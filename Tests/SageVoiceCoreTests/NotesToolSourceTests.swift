import XCTest
@testable import SageVoiceCore

/// The tool that writes to disk, driven by a model that is fed speech
/// recognition output and web pages written by strangers.
///
/// The containment claim in `NotesToolSource` is specific — "there is no input
/// to `write_note` that produces a file outside the notes directory" — and a
/// claim like that is worth nothing unmeasured, so most of this file is one
/// test hammering it.
final class NotesToolSourceTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("notes-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeSource(delivery: NotesToolSource.Delivery = .attachedToReply) -> NotesToolSource {
        NotesToolSource(directory: root.appendingPathComponent("Notes", isDirectory: true), delivery: delivery)
    }

    // MARK: - Containment

    /// Every title a hostile or misheard instruction could produce must land
    /// inside the notes directory.
    ///
    /// Asserted on the resolved path rather than on the absence of ".." in the
    /// slug, because `/etc/passwd` needs no traversal sequence at all and a
    /// substring check would pass it.
    func testNoTitleCanWriteOutsideTheNotesDirectory() async throws {
        let source = makeSource()
        let notesDirectory = source.notesDirectory.resolvingSymlinksInPath().standardizedFileURL

        let hostileTitles = [
            "../../../../etc/passwd",
            "..",
            "../../../../../../../../tmp/escaped",
            "/etc/crontab",
            "/Users/ableton/.ssh/authorized_keys",
            "~/.zshrc",
            "..%2f..%2fescaped",
            "....//....//escaped",
            "note\u{0000}.md",
            "note/../../escaped",
            "\\..\\..\\escaped",
            "con",                       // reserved on other platforms; must not crash here
            ".hidden",
            "-",
            "   ",
            String(repeating: "a", count: 5_000)
        ]

        for title in hostileTitles {
            _ = try await source.call(
                name: NotesToolSource.writeToolName,
                arguments: ["title": .string(title), "content": .string("body")]
            )
        }

        let written = source.drainWrittenNotes()
        XCTAssertEqual(written.count, hostileTitles.count, "every call should have written exactly one file")

        for url in written {
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            XCTAssertEqual(
                resolved.deletingLastPathComponent().path,
                notesDirectory.path,
                "\(url.lastPathComponent) escaped the notes directory"
            )
            XCTAssertEqual(url.pathExtension, "md")
        }

        // And nothing was created anywhere above it.
        let siblings = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(siblings, ["Notes"], "something was written next to the notes directory")
    }

    /// A slug is only a safe filename if it is also a *stable* one — the model
    /// asks to read back the title it was given, not the filename it never saw.
    func testATitleRoundTripsThroughTheSlug() async throws {
        let source = makeSource()
        _ = try await source.call(
            name: NotesToolSource.writeToolName,
            arguments: ["title": .string("Tokyo Modular Shops!"), "content": .string("Errorinstruments, Daikanyama")]
        )

        let read = try await source.call(
            name: NotesToolSource.readToolName,
            arguments: ["title": .string("Tokyo Modular Shops!")]
        )
        XCTAssertTrue(read.contains("Errorinstruments"), "got: \(read)")

        // Punctuation and casing are lost by design, so a differently-typed
        // version of the same title must still find it.
        let again = try await source.call(
            name: NotesToolSource.readToolName,
            arguments: ["title": .string("tokyo modular shops")]
        )
        XCTAssertTrue(again.contains("Errorinstruments"), "got: \(again)")
    }

    /// The owner photographs Japanese signage and asks about it. Collapsing
    /// every non-ASCII title to one slug would silently overwrite notes.
    func testNonLatinTitlesGetDistinctFiles() async throws {
        let source = makeSource()
        for title in ["書道", "抹茶", "モジュラー"] {
            _ = try await source.call(
                name: NotesToolSource.writeToolName,
                arguments: ["title": .string(title), "content": .string(title)]
            )
        }
        let written = Set(source.drainWrittenNotes().map(\.lastPathComponent))
        XCTAssertEqual(written.count, 3, "titles collided: \(written)")
    }

    // MARK: - Behaviour the model reads

    /// Overwriting is the right default for a voice product — "note-1, note-2,
    /// note-3" is worse — but it destroys the owner's data, so the model has to
    /// be told it happened and be able to say so.
    func testRewritingTheSameTitleSaysItReplacedSomething() async throws {
        let source = makeSource()
        let first = try await source.call(
            name: NotesToolSource.writeToolName,
            arguments: ["title": .string("Packing list"), "content": .string("socks")]
        )
        XCTAssertFalse(first.lowercased().contains("replaced"))

        let second = try await source.call(
            name: NotesToolSource.writeToolName,
            arguments: ["title": .string("packing list"), "content": .string("cables")]
        )
        XCTAssertTrue(second.lowercased().contains("replaced"), "got: \(second)")

        let read = try await source.call(
            name: NotesToolSource.readToolName,
            arguments: ["title": .string("Packing list")]
        )
        XCTAssertTrue(read.contains("cables"))
        XCTAssertFalse(read.contains("socks"))
    }

    /// The two hosts differ in what happens to the file, and the model says the
    /// difference out loud. Getting this wrong sends the owner looking for an
    /// attachment that was never sent.
    func testTheDeliverySentenceMatchesTheHost() async throws {
        let attached = try await makeSource(delivery: .attachedToReply).call(
            name: NotesToolSource.writeToolName,
            arguments: ["title": .string("a"), "content": .string("b")]
        )
        XCTAssertTrue(attached.contains("attached to your reply"), "got: \(attached)")

        let saved = try await makeSource(delivery: .savedOnDisk).call(
            name: NotesToolSource.writeToolName,
            arguments: ["title": .string("a"), "content": .string("b")]
        )
        XCTAssertFalse(saved.contains("attached"), "the app would be promising a delivery it cannot make: \(saved)")
    }

    func testEmptyContentWritesNothing() async throws {
        let source = makeSource()
        let answer = try await source.call(
            name: NotesToolSource.writeToolName,
            arguments: ["title": .string("Empty"), "content": .string("   \n  ")]
        )
        XCTAssertTrue(answer.lowercased().contains("no content"), "got: \(answer)")
        XCTAssertTrue(source.drainWrittenNotes().isEmpty)
    }

    /// A reasoning runaway was measured at 4,069 tokens on this model. The cap
    /// is what stops a loop like that filling the appliance's disk.
    func testOverlongContentIsCutAndTheModelIsTold() async throws {
        let source = makeSource()
        let huge = String(repeating: "line of text\n", count: 20_000)
        let answer = try await source.call(
            name: NotesToolSource.writeToolName,
            arguments: ["title": .string("Huge"), "content": .string(huge)]
        )
        XCTAssertTrue(answer.contains("too long"), "got: \(answer)")

        let url = try XCTUnwrap(source.drainWrittenNotes().first)
        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertLessThanOrEqual(
            written.count,
            NotesToolSource.maximumContentCharacters + 200,  // heading and title
            "the cap did not hold"
        )
    }

    /// Draining, not reading. A note that rode out on a second, unrelated reply
    /// would be a miserable bug to chase from a phone.
    func testDrainingClearsTheList() async throws {
        let source = makeSource()
        _ = try await source.call(
            name: NotesToolSource.writeToolName,
            arguments: ["title": .string("One"), "content": .string("x")]
        )
        XCTAssertEqual(source.drainWrittenNotes().count, 1)
        XCTAssertTrue(source.drainWrittenNotes().isEmpty)
    }

    /// Reading a title that was never written must not read as an empty note —
    /// the model would summarise the silence as "it's blank".
    func testReadingAMissingNoteSaysSoAndOffersWhatExists() async throws {
        let source = makeSource()
        _ = try await source.call(
            name: NotesToolSource.writeToolName,
            arguments: ["title": .string("Gear list"), "content": .string("x")]
        )
        let answer = try await source.call(
            name: NotesToolSource.readToolName,
            arguments: ["title": .string("Shopping list")]
        )
        XCTAssertTrue(answer.contains("no note titled"), "got: \(answer)")
        XCTAssertTrue(answer.contains("gear list"), "should name what does exist: \(answer)")
    }

    func testListingIsOrderedSoThePromptPrefixStaysStable() async throws {
        let source = makeSource()
        for title in ["Zebra", "Apple", "Mango"] {
            _ = try await source.call(
                name: NotesToolSource.writeToolName,
                arguments: ["title": .string(title), "content": .string("x")]
            )
        }
        let first = try await source.call(name: NotesToolSource.listToolName, arguments: [:])
        let second = try await source.call(name: NotesToolSource.listToolName, arguments: [:])
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.contains("apple, mango, zebra"), "got: \(first)")
    }

    func testAnUnknownToolNameIsRefused() async throws {
        let source = makeSource()
        do {
            _ = try await source.call(name: "delete_everything", arguments: [:])
            XCTFail("should have refused")
        } catch CompositeToolSource.Failure.unknownTool(let name) {
            XCTAssertEqual(name, "delete_everything")
        }
    }

    // MARK: - Catalogue

    /// The exact bug that made web search a silent no-op when it shipped: the
    /// allowlist filters the *composed* catalogue, so a tool missing from it is
    /// a tool the model never sees, however correctly its source publishes it.
    func testTheNoteToolsAreOnTheVoiceAllowlist() {
        for name in NotesToolSource.toolNames {
            XCTAssertTrue(
                BrainPrompts.voiceToolAllowlist.contains(name),
                "\(name) is published but filtered out before the model sees it"
            )
        }
    }

    func testTheCatalogueIsWhatTheAllowlistExpects() async throws {
        let published = Set(try await makeSource().listTools().map(\.name))
        XCTAssertEqual(published, NotesToolSource.toolNames)
    }

    /// Files are what the owner opens, so the permissions are theirs alone —
    /// the same 0600/0700 the provider keys and the OAuth token get.
    func testNotesAreOwnerOnlyOnDisk() async throws {
        let source = makeSource()
        _ = try await source.call(
            name: NotesToolSource.writeToolName,
            arguments: ["title": .string("Private"), "content": .string("x")]
        )
        let url = try XCTUnwrap(source.drainWrittenNotes().first)

        let file = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(file[.posixPermissions] as? NSNumber, OwnerOnlyFileSecurity.filePermissions)

        let directory = try FileManager.default.attributesOfItem(atPath: source.notesDirectory.path)
        XCTAssertEqual(directory[.posixPermissions] as? NSNumber, OwnerOnlyFileSecurity.directoryPermissions)
    }
}
