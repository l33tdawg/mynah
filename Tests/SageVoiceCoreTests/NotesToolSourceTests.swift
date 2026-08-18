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

        let written = source.drainOutgoingFiles()
        // **Not `hostileTitles.count`.** Several of these slug to the same
        // filename — ".." and "-" both become `note` — so they are one file
        // written twice, and the queue deliberately holds it once. Attaching it
        // twice is the duplicate `deliver` exists to stop.
        //
        // Asserted against what is on disk rather than against a slug count
        // recomputed here, because that recomputation would have to reproduce
        // `write`'s own fallbacks — a blank title takes its name from the
        // document's first line — and a test that reimplements the code it is
        // checking agrees with itself, not with the product.
        XCTAssertFalse(written.isEmpty)
        let onDisk = try FileManager.default
            .contentsOfDirectory(atPath: source.notesDirectory.path)
            .filter { $0.hasSuffix(".md") }
        XCTAssertEqual(
            written.count, onDisk.count,
            "the reply should carry every file that was written, once each"
        )

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
        let written = Set(source.drainOutgoingFiles().map(\.lastPathComponent))
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
        XCTAssertTrue(source.drainOutgoingFiles().isEmpty)
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

        let url = try XCTUnwrap(source.drainOutgoingFiles().first)
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
        XCTAssertEqual(source.drainOutgoingFiles().count, 1)
        XCTAssertTrue(source.drainOutgoingFiles().isEmpty)
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

    /// The exact bug that made web search a silent no-op when it shipped: a
    /// tool can be published perfectly and still never reach the model.
    ///
    /// **This used to assert membership of `BrainPrompts.voiceToolAllowlist`,
    /// and that membership is what slice 1 deliberately deletes.** This source
    /// self-declares now — `CompositeToolSource.Source.inProcess` has no name
    /// parameter to list it in — so the only place the question can honestly be
    /// asked is the composed catalogue. Asserting the old way would be
    /// asserting that a name is in a set that must never contain it.
    func testTheNoteToolsAreInTheComposedCatalogue() async throws {
        let offered = try await ComposedCatalogue.conversation()
        for name in NotesToolSource.toolNames {
            XCTAssertTrue(
                offered.contains(name),
                "\(name) is published but never reaches the model: \(offered.sorted())"
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
        let url = try XCTUnwrap(source.drainOutgoingFiles().first)

        let file = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(file[.posixPermissions] as? NSNumber, OwnerOnlyFileSecurity.filePermissions)

        let directory = try FileManager.default.attributesOfItem(atPath: source.notesDirectory.path)
        XCTAssertEqual(directory[.posixPermissions] as? NSNumber, OwnerOnlyFileSecurity.directoryPermissions)
    }
}

// MARK: - Documents

/// `write_note` with a format on it.
///
/// The rule being defended: **the markdown is always written and always kept.**
/// Everything else is a conversion that may or may not be possible on this Mac,
/// and every way it can fail has to leave the owner holding the note they asked
/// for rather than an apology.
final class NoteDocumentTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("note-docs-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeSource(exporter: DocumentExporter?) -> NotesToolSource {
        NotesToolSource(
            directory: root.appendingPathComponent("Notes", isDirectory: true),
            delivery: .attachedToReply,
            exporter: exporter
        )
    }

    private func write(
        _ source: NotesToolSource,
        title: String = "Quarterly brief",
        content: String = "A paragraph.\n\n## What we found\n\n- One thing\n- Another\n",
        format: String? = nil
    ) async throws -> String {
        var arguments: [String: JSONValue] = [
            "title": .string(title),
            "content": .string(content)
        ]
        if let format { arguments["format"] = .string(format) }
        return try await source.call(name: NotesToolSource.writeToolName, arguments: arguments)
    }

    func testWithoutAFormatItIsStillJustANote() async throws {
        let source = makeSource(exporter: nil)
        _ = try await write(source)

        XCTAssertEqual(
            source.drainOutgoingFiles().map(\.lastPathComponent), ["quarterly-brief.md"]
        )
    }

    func testAFormatThisMacCannotProduceLeavesTheOwnerHoldingTheNote() async throws {
        let source = makeSource(exporter: nil)

        let answer = try await write(source, format: "pdf")

        XCTAssertTrue(
            answer.contains("can't make a PDF"),
            "the model has to be told, or it will say it sent a PDF: \(answer)"
        )
        XCTAssertEqual(
            source.drainOutgoingFiles().map(\.lastPathComponent), ["quarterly-brief.md"],
            "the note is what gets attached when the document could not be made"
        )
    }

    func testAFormatNobodyRecognisesIsSaidRatherThanGuessedAt() async throws {
        let source = makeSource(exporter: nil)

        let answer = try await write(source, format: "epub")

        XCTAssertTrue(answer.contains("isn't a format"), answer)
        XCTAssertEqual(source.drainOutgoingFiles().map(\.lastPathComponent), ["quarterly-brief.md"])
    }

    func testAFailedConversionKeepsTheNoteAndSaysWhy() async throws {
        // A "pandoc" that exits non-zero, which is every real conversion
        // failure: a malformed table, an image that is not there.
        let source = makeSource(exporter: DocumentExporter(
            pandoc: URL(fileURLWithPath: "/usr/bin/false"),
            pdfEngine: URL(fileURLWithPath: "/usr/bin/false")
        ))

        let answer = try await write(source, format: "docx")

        XCTAssertTrue(answer.contains("failed"), answer)
        XCTAssertEqual(
            source.drainOutgoingFiles().map(\.lastPathComponent), ["quarterly-brief.md"],
            "a failed conversion must not cost the owner the note as well"
        )
    }

    func testTheSchemaOnlyOffersWhatThisMacCanDo() async throws {
        let withoutPandoc = makeSource(exporter: nil)
        XCTAssertEqual(withoutPandoc.offeredFormats, [.markdown])

        let withoutPDF = makeSource(exporter: DocumentExporter(
            pandoc: URL(fileURLWithPath: "/usr/bin/true"),
            pdfEngine: nil
        ))
        XCTAssertEqual(
            withoutPDF.offeredFormats, [.markdown, .docx, .pptx],
            "a model told `pdf` is available will use it and say it did"
        )
    }

    /// **A model told it can chart on a Mac that cannot would write the fence
    /// and the owner would never see it drawn** — the same trap the diagram
    /// sentence is gated against, one layer down. A chart needs no package, so
    /// the gate is the PDF and nothing else.
    func testTheChartSentenceIsOnlyOfferedWhereAChartCanBeDrawn() throws {
        let withoutPandoc = makeSource(exporter: nil)
        XCTAssertFalse(
            withoutPandoc.contentGuidance.contains("```chart"),
            "a chart was offered on a Mac with no converter: \(withoutPandoc.contentGuidance)"
        )

        let withoutPDF = makeSource(exporter: DocumentExporter(
            pandoc: URL(fileURLWithPath: "/usr/bin/true"),
            pdfEngine: nil
        ))
        XCTAssertFalse(
            withoutPDF.contentGuidance.contains("```chart"),
            "a chart was offered where only Word and slides can be made, and neither draws "
                + "one: \(withoutPDF.contentGuidance)"
        )

        let withPDF = makeSource(exporter: DocumentExporter(
            pandoc: URL(fileURLWithPath: "/usr/bin/true"),
            pdfEngine: URL(fileURLWithPath: "/usr/bin/true")
        ))
        XCTAssertTrue(
            withPDF.contentGuidance.contains("```chart"),
            "nothing ever tells the model charts exist: \(withPDF.contentGuidance)"
        )
    }

    /// **The anti-lying guard.** A dropped diagram leaves a hole the model can
    /// see; a chart that became a table leaves the numbers exactly where they
    /// were, so a model that is not told will describe bars that are not on the
    /// page. It has to reach the tool result.
    func testAChartThatBecameATableIsToldToTheModel() async throws {
        guard let exporter = DocumentExporter.locate() else {
            throw XCTSkip("pandoc is not staged; run scripts/provision-pandoc.sh")
        }
        let source = makeSource(exporter: exporter)

        // A Word document, which is never typeset by Typst and therefore never
        // draws one.
        let answer = try await write(
            source,
            content: "The comparison.\n\n```chart\nLocal Mac | 1200\nHosted API | 3400\n```\n",
            format: "docx"
        )

        XCTAssertTrue(
            answer.contains("chart") && answer.contains("table"),
            "the model will describe a picture that is not there: \(answer)"
        )
        XCTAssertEqual(source.drainOutgoingFiles().map(\.lastPathComponent), ["quarterly-brief.docx"])
    }

    /// And a chart that drew reports nothing, so the model has nothing to
    /// apologise for.
    func testADrawnChartReportsNoLoss() async throws {
        guard let exporter = DocumentExporter.locate(), exporter.canProduce(.pdf) else {
            throw XCTSkip("typst is not staged; run scripts/provision-typst.sh")
        }
        let source = makeSource(exporter: exporter)

        let answer = try await write(
            source,
            content: "The comparison.\n\n```chart\nLocal Mac | 1200\nHosted API | 3400\n```\n",
            format: "pdf"
        )

        XCTAssertFalse(
            answer.contains("could not be drawn"),
            "a chart that drew was apologised for: \(answer)"
        )
    }

    /// The whole errand, on a Mac where the converter is staged.
    func testARealDocumentIsWhatGetsAttached() async throws {
        guard let exporter = DocumentExporter.locate() else {
            throw XCTSkip("pandoc is not staged; run scripts/provision-pandoc.sh")
        }
        let source = makeSource(exporter: exporter)

        let answer = try await write(source, format: "docx")

        XCTAssertTrue(answer.contains("Word document"), answer)
        let attached = source.drainOutgoingFiles()
        XCTAssertEqual(attached.map(\.lastPathComponent), ["quarterly-brief.docx"])
        XCTAssertEqual(
            attached.first?.deletingLastPathComponent().lastPathComponent, "documents",
            "converted files live beside the notes, not among them — list_notes and "
                + "read_note work on the markdown"
        )
        // And the note itself is still there, which is what read_note reads.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: source.notesDirectory.appendingPathComponent("quarterly-brief.md").path
        ))
    }
}
