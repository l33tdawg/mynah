import XCTest
@testable import SageVoiceCore

/// **"lets work on the hand stored attachments back to owner via signal or chat next"**
///
/// Everything needed for this existed except the last step. The owner sends a
/// ferry ticket, `SignalAttachmentStore` keeps it and writes a note; `list_notes`
/// and `read_note` find that note; the daemon can attach files to a reply and the
/// window shows them as chips. But the only files that could ride out were the
/// ones written *during that turn*, so "send me that ticket again" had no path —
/// Mynah could describe the file and could not hand it over.
///
/// Two things are being tested here and they fail in opposite directions:
///
/// - **Finding too little.** A title has to be matchable the way somebody
///   actually says it, or the feature is unusable: the ferry ticket is filed
///   under the owner's whole caption and asked for in three words.
/// - **Finding too much.** This tool sends the owner's private files outward.
///   Loose matching here does not produce a wrong note, it mails the wrong
///   document to whoever is in the thread.
final class SendFileTests: XCTestCase {

    private var root: URL!
    private var notes: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("send-file-\(UUID().uuidString)", isDirectory: true)
        notes = root.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    private func makeSource(delivery: NotesToolSource.Delivery = .attachedToReply) -> NotesToolSource {
        NotesToolSource(directory: notes, delivery: delivery, exporter: nil)
    }

    @discardableResult
    private func writeNote(_ slug: String, bytes: Int = 32) throws -> URL {
        let file = notes.appendingPathComponent(slug + ".md")
        try Data(repeating: 0x61, count: bytes).write(to: file)
        return file
    }

    @discardableResult
    private func writeAttachment(_ name: String, bytes: Int = 32) throws -> URL {
        let folder = notes.appendingPathComponent(SignalAttachmentStore.subdirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(name)
        try Data(repeating: 0x62, count: bytes).write(to: file)
        return file
    }

    @discardableResult
    private func writeDocument(_ name: String) throws -> URL {
        let folder = notes.appendingPathComponent("documents", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(name)
        try Data("doc".utf8).write(to: file)
        return file
    }

    private func send(_ title: String, from source: NotesToolSource) async throws -> String {
        try await source.call(
            name: NotesToolSource.sendToolName,
            arguments: ["title": .string(title)]
        )
    }

    /// Symlinks resolved on both sides. `contentsOfDirectory` hands back
    /// `/private/var/...` where the fixture built `/var/...`; comparing the two
    /// raw would fail on a difference that is macOS's, not the code's.
    private func drained(_ source: NotesToolSource) -> [String] {
        source.drainOutgoingFiles().map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
    }

    private func path(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    // MARK: - The errand

    /// The whole feature in one test: the owner sent a thing, and later asks for
    /// it back in fewer words than they filed it under.
    func testTheFerryTicketComesBack() async throws {
        let ticket = try writeAttachment("ferry-ticket-to-betong-a1b2c3.jpg")
        try writeNote("ferry-ticket-to-betong")

        let source = makeSource()
        let answer = try await send("ferry ticket", from: source)

        XCTAssertEqual(drained(source), [path(ticket)])
        XCTAssertTrue(answer.contains("Sending"), answer)
        XCTAssertTrue(answer.contains("attached to your reply"), answer)
    }

    /// **The attachment, not the note about it.** The note is an index card that
    /// exists so the file is findable; sending it instead would be handing
    /// somebody a description of their own ticket.
    func testTheFileWinsOverTheNoteDescribingIt() async throws {
        let ticket = try writeAttachment("ferry-ticket-a1b2c3.jpg")
        try writeNote("ferry-ticket")

        let source = makeSource()
        _ = try await send("ferry ticket", from: source)

        XCTAssertEqual(drained(source), [path(ticket)])
    }

    /// One caption, several photos: the owner said "here are the receipts" once
    /// and three files landed under it. Sending one of three is the kind of
    /// partial success nobody notices until the missing receipt is needed.
    func testEveryPhotoUnderOneCaptionGoesTogether() async throws {
        for hash in ["a1b2c3", "d4e5f6", "070809"] {
            try writeAttachment("hotel-receipts-\(hash).jpg")
        }
        try writeNote("hotel-receipts")

        let source = makeSource()
        let answer = try await send("hotel receipts", from: source)

        XCTAssertEqual(source.drainOutgoingFiles().count, 3)
        XCTAssertTrue(answer.contains("3 files"), answer)
    }

    /// Asked for a document that was exported, they mean the export.
    func testAnExportedDocumentBeatsItsMarkdown() async throws {
        try writeNote("quarterly-brief")
        let pdf = try writeDocument("quarterly-brief.pdf")

        let source = makeSource()
        _ = try await send("quarterly brief", from: source)

        XCTAssertEqual(drained(source), [path(pdf)])
    }

    /// Nothing was exported and nothing was sent in: the markdown is a real file
    /// and is what they asked for.
    func testAPlainNoteIsStillSendable() async throws {
        let note = try writeNote("packing-list")

        let source = makeSource()
        _ = try await send("packing list", from: source)

        XCTAssertEqual(drained(source), [path(note)])
    }

    // MARK: - Matching what somebody actually says

    func testTheWaysAPersonNamesTheirOwnFile() throws {
        let saved = ["ferry-ticket-to-betong-on-the-14th", "quarterly-brief", "najwa-passport-scan"]

        for asked in [
            "ferry ticket to betong on the 14th",   // read straight off the list
            "ferry ticket",                         // a run of words inside it
            "betong ferry",                         // the same words, remembered backwards
            "the ferry ticket to Betong",           // with the noise words a person uses
            "FERRY TICKET"                          // however the recogniser cased it
        ] {
            XCTAssertEqual(
                StoredFiles.slugs(matching: NoteSlug.slug(from: asked), among: saved),
                ["ferry-ticket-to-betong-on-the-14th"],
                asked
            )
        }
    }

    /// **The near-miss that makes fuzzy matching dangerous.** Substring matching
    /// would send the passport scan to somebody asking about a port, and the
    /// brief to somebody asking about art. Matching is word-wise for this
    /// reason, and it is the same failure as the agent-name bug that piped the
    /// owner's messages to strangers: a substring matched, and something private
    /// went somewhere it should not.
    func testHalfAWordIsNotAMatch() throws {
        let saved = ["najwa-passport-scan", "quarterly-brief", "cartier-receipt"]

        for asked in ["port", "art", "rief", "ass", "quarter"] {
            XCTAssertEqual(
                StoredFiles.slugs(matching: NoteSlug.slug(from: asked), among: saved), [],
                "\"\(asked)\" must not match anything"
            )
        }
    }

    /// An exact title is never dragged into a contest with something that merely
    /// shares a word with it.
    func testAnExactTitleWinsOutright() throws {
        let saved = ["invoice", "invoice-march", "invoice-april"]
        XCTAssertEqual(StoredFiles.slugs(matching: "invoice", among: saved), ["invoice"])
    }

    /// **Checked against the shape of real filenames, not invented ones.**
    ///
    /// Titles come from what the owner *said* when they sent the thing, so they
    /// are sentences: the ferry booking on this Mac is filed as
    /// `here-s-the-ferry-booking-please-store-it`. Nobody asks for it by that
    /// name. Every ask below found nothing before the grammar and kind words
    /// were dropped from the request.
    func testTheWordsPeopleAddThatAreNotPartOfTheName() throws {
        let saved = [
            "here-s-the-ferry-booking-please-store-it",
            "thailand-trip-bookings",
            "hugo-boss-store-near-dome-bangsar"
        ]

        let expected: [String: String] = [
            "the thailand bookings": "thailand-trip-bookings",
            "that ferry booking please": "here-s-the-ferry-booking-please-store-it",
            "my hugo boss note": "hugo-boss-store-near-dome-bangsar",
            "the ferry booking photo": "here-s-the-ferry-booking-please-store-it",
            "the thailand doc": "thailand-trip-bookings"
        ]
        for (asked, slug) in expected {
            XCTAssertEqual(
                StoredFiles.slugs(matching: NoteSlug.slug(from: asked), among: saved), [slug], asked
            )
        }
    }

    /// A word that names a *kind* of thing and nothing else identifies nothing.
    /// Answering it with a guess would be picking a file at random.
    func testNamingOnlyTheKindOfFileMatchesNothing() throws {
        let saved = ["here-s-the-ferry-booking-please-store-it", "thailand-trip-bookings"]
        for asked in ["photo", "send me the pdf", "the document", "that file"] {
            XCTAssertEqual(
                StoredFiles.slugs(matching: NoteSlug.slug(from: asked), among: saved), [], asked
            )
        }
    }

    /// Kind words are dropped only as a **last** resort, so a note genuinely
    /// called "voice note" still wins the request for it.
    func testATitleThatReallyContainsAKindWordIsStillFoundFirst() throws {
        let saved = ["voice-note-from-amy", "voice-memo-settings"]
        XCTAssertEqual(
            StoredFiles.slugs(matching: NoteSlug.slug(from: "voice note"), among: saved),
            ["voice-note-from-amy"]
        )
    }

    /// A request made entirely of grammar names no file, and must not land on
    /// the one whose caption happens to contain those words. Captions are
    /// sentences — this one really does end "…please store it".
    func testARequestMadeOnlyOfGrammarMatchesNothing() throws {
        let saved = ["here-s-the-ferry-booking-please-store-it", "thailand-trip-bookings"]
        for asked in ["please", "it", "that one", "the", "my"] {
            XCTAssertEqual(
                StoredFiles.slugs(matching: NoteSlug.slug(from: asked), among: saved), [], asked
            )
        }
    }

    /// Except when it is the actual title. Exact match runs before any of the
    /// loosening, so nothing is lost by the rule above.
    func testATitleThatReallyIsAGrammarWordIsStillFound() throws {
        XCTAssertEqual(StoredFiles.slugs(matching: "it", among: ["it", "thailand-trip"]), ["it"])
    }

    // MARK: - Refusing to guess

    /// Two candidates and no way to tell which: it asks. Sending both would put
    /// a file the owner did not ask for into the thread, and picking one would
    /// be a coin toss reported as an answer.
    func testAnAmbiguousTitleSendsNothingAndSaysWhy() async throws {
        try writeNote("invoice-march")
        try writeNote("invoice-april")

        let source = makeSource()
        let answer = try await send("invoice", from: source)

        XCTAssertTrue(source.drainOutgoingFiles().isEmpty, "nothing may leave on a guess")
        XCTAssertTrue(answer.hasPrefix("NOTHING WAS SENT"), answer)
        XCTAssertTrue(answer.contains("invoice march"), answer)
        XCTAssertTrue(answer.contains("invoice april"), answer)
        XCTAssertTrue(answer.contains("Ask the owner"), answer)
    }

    /// A miss names what is there, so the next turn can succeed rather than
    /// dead-end.
    func testAMissNamesWhatIsActuallySaved() async throws {
        try writeNote("packing-list")

        let source = makeSource()
        let answer = try await send("ferry ticket", from: source)

        XCTAssertTrue(source.drainOutgoingFiles().isEmpty)
        XCTAssertTrue(answer.hasPrefix("NOTHING WAS SENT"), answer)
        XCTAssertTrue(answer.contains("packing list"), answer)
    }

    /// An empty directory is a different sentence, because "here is what is
    /// saved: nothing" is not a list the owner can choose from.
    func testAnEmptyNotesDirectorySaysSoRatherThanListingNothing() async throws {
        let source = makeSource()
        let answer = try await send("ferry ticket", from: source)

        XCTAssertTrue(answer.hasPrefix("NOTHING WAS SENT"), answer)
        XCTAssertTrue(answer.contains("nothing has been saved"), answer)
        XCTAssertFalse(answer.contains("What is saved:"), answer)
    }

    func testNoTitleSendsNothing() async throws {
        try writeNote("packing-list")
        let source = makeSource()

        let answer = try await source.call(
            name: NotesToolSource.sendToolName,
            arguments: ["title": .string("   ")]
        )
        XCTAssertTrue(source.drainOutgoingFiles().isEmpty)
        XCTAssertTrue(answer.contains("nothing was sent"), answer)
    }

    /// **Every refusal has to survive being read by a model that wants to be
    /// helpful.** This is the owner's *"said it did it, but actually didn't …
    /// quite dangerous"* class, pointed outward: a reply of "I've sent it" when
    /// nothing left the Mac is not caught by anything downstream, because the
    /// tool call succeeded.
    func testEveryRefusalSaysNothingWasSentInWordsAModelCannotSoften() async throws {
        try writeNote("invoice-march")
        try writeNote("invoice-april")
        let source = makeSource()

        for title in ["ferry ticket", "invoice"] {
            let answer = try await send(title, from: source)
            XCTAssertTrue(answer.contains("NOTHING WAS SENT"), answer)
            XCTAssertTrue(source.drainOutgoingFiles().isEmpty, title)
        }
    }

    // MARK: - Containment

    /// **A path is never accepted, so traversal is not blocked here — it is
    /// unrepresentable.** The argument is `NotesToolSource`'s and it has to be
    /// stronger for this tool: a traversal in `write_note` corrupts a note, a
    /// traversal here mails the owner's private key to whoever is in the thread.
    func testNoTitleCanNameAFileOutsideTheNotesDirectory() async throws {
        try writeNote("packing-list")
        // A real file outside the notes directory, with a name a hostile title
        // could plausibly aim at.
        let outside = root.appendingPathComponent("id_rsa")
        try Data("secret".utf8).write(to: outside)

        let source = makeSource()
        for title in [
            "../id_rsa",
            "../../id_rsa",
            "/etc/passwd",
            "~/.ssh/id_rsa",
            "..%2f..%2fid_rsa",
            "....//....//id_rsa",
            "packing-list/../../id_rsa",
            "\\..\\..\\id_rsa",
            "attachments/../../id_rsa",
            String(repeating: "../", count: 40) + "etc/passwd"
        ] {
            _ = try await send(title, from: source)
            let sent = source.drainOutgoingFiles()
            for file in sent {
                let resolved = file.resolvingSymlinksInPath().standardizedFileURL.path
                let inside = notes.resolvingSymlinksInPath().standardizedFileURL.path
                XCTAssertTrue(resolved.hasPrefix(inside), "\(title) escaped to \(resolved)")
            }
        }
    }

    /// **A note's own text must never become a path to send.**
    ///
    /// `SignalAttachmentStore` writes "The file is kept at `attachments/x.png`"
    /// into every note, which is exactly the string a naive implementation would
    /// parse. Note bodies are model-written and pass through `web_search`
    /// results, so a note can claim its file is kept anywhere at all. Files are
    /// found by listing `attachments/`, which cannot be talked into containing
    /// something that is not there.
    func testALyingNoteCannotNameAFileToSend() async throws {
        let outside = root.appendingPathComponent("id_rsa")
        try Data("secret".utf8).write(to: outside)

        let note = notes.appendingPathComponent("holiday-photo.md")
        try Data("""
        # holiday photo

        The file is kept at `attachments/../../id_rsa` (image/png).
        """.utf8).write(to: note)

        let source = makeSource()
        _ = try await send("holiday photo", from: source)

        XCTAssertEqual(
            drained(source), [path(note)],
            "only the note itself exists; the path in its body is text, not an instruction"
        )
    }

    /// A file dropped into `attachments/` by hand — no `-<6 hex>` suffix — is not
    /// filed under a slug with its last word chopped off.
    func testOnlyOurOwnAttachmentNamesAreDecoded() {
        XCTAssertEqual(StoredFiles.attachmentSlug(fromFileName: "ferry-ticket-a1b2c3.jpg"), "ferry-ticket")
        XCTAssertNil(StoredFiles.attachmentSlug(fromFileName: "ferry-ticket.jpg"))
        XCTAssertNil(StoredFiles.attachmentSlug(fromFileName: "screenshot-2026-08-03.png"))
        XCTAssertNil(StoredFiles.attachmentSlug(fromFileName: "IMG_4021.HEIC"))
        XCTAssertNil(StoredFiles.attachmentSlug(fromFileName: "a1b2c3.jpg"), "nothing before the hash")
    }

    // MARK: - Size

    /// signal-cli rejects a whole send if one attachment is too big, and the
    /// daemon's recovery is to retry as plain text — so an oversized file would
    /// cost the owner the **answer** as well as the file, with no explanation
    /// anywhere. Refusing here keeps the sentence.
    func testAFileTooBigForSignalIsRefusedWithTheReasonRatherThanFailingTheReply() async throws {
        try writeAttachment(
            "long-video-a1b2c3.mov",
            bytes: NotesToolSource.maximumAttachmentBytes + 1
        )

        let source = makeSource(delivery: .attachedToReply)
        let answer = try await send("long video", from: source)

        XCTAssertTrue(source.drainOutgoingFiles().isEmpty)
        XCTAssertTrue(answer.contains("NOTHING WAS SENT"), answer)
        XCTAssertTrue(answer.contains("too large"), answer)
        // A dead end has to name the next action.
        XCTAssertTrue(answer.contains("still saved on the Mac"), answer)
    }

    /// The window has no Signal ceiling — the file is a chip the owner clicks —
    /// so borrowing the appliance's limit there would refuse something that
    /// works perfectly.
    func testTheWindowHasNoSizeLimitBecauseItIsNotSending() async throws {
        let big = try writeAttachment(
            "long-video-a1b2c3.mov",
            bytes: NotesToolSource.maximumAttachmentBytes + 1
        )

        let source = makeSource(delivery: .savedOnDisk)
        let answer = try await send("long video", from: source)

        XCTAssertEqual(drained(source), [path(big)])
        XCTAssertTrue(answer.contains("click and open"), answer)
    }

    /// A batch where one photo is oversized still delivers the rest, and says
    /// which one did not go.
    func testOneOversizedFileDoesNotStopTheOthers() async throws {
        let small = try writeAttachment("trip-photos-a1b2c3.jpg")
        try writeAttachment("trip-photos-d4e5f6.mov", bytes: NotesToolSource.maximumAttachmentBytes + 1)

        let source = makeSource()
        let answer = try await send("trip photos", from: source)

        XCTAssertEqual(drained(source), [path(small)])
        XCTAssertTrue(answer.contains("Sending"), answer)
        XCTAssertTrue(answer.contains("Not sending"), answer)
        XCTAssertTrue(answer.contains("trip-photos-d4e5f6.mov"), answer)
    }

    // MARK: - Handoff

    /// The queue is shared with `write_note`, and draining is what stops a file
    /// riding out on an unrelated reply — which now matters more, because the
    /// unrelated reply may be in a different Signal thread.
    func testDrainingHandsEachFileOverExactlyOnce() async throws {
        try writeAttachment("ferry-ticket-a1b2c3.jpg")

        let source = makeSource()
        _ = try await send("ferry ticket", from: source)

        XCTAssertEqual(source.drainOutgoingFiles().count, 1)
        XCTAssertTrue(source.drainOutgoingFiles().isEmpty, "a second reply must not carry it again")
    }

    /// **A model being helpful must not send the same file twice.** It writes a
    /// document, then calls `send_file` on the thing it just wrote — one
    /// ordinary turn, two queue entries, and the owner sees two identical
    /// attachments in the thread.
    ///
    /// The two URLs are not equal: `write_note` builds one by appending to the
    /// notes directory and `send_file` reads the other back off disk, which on
    /// macOS is `/var/…` against `/private/var/…` for one file.
    func testWritingAndThenSendingTheSameDocumentAttachesItOnce() async throws {
        let source = makeSource()
        _ = try await source.call(
            name: NotesToolSource.writeToolName,
            arguments: ["title": .string("packing list"), "content": .string("socks")]
        )
        _ = try await send("packing list", from: source)

        XCTAssertEqual(drained(source).count, 1)
    }

    /// A refusal must not leave the queue holding anything, or the *next* turn
    /// hands the owner a file nobody asked for on that turn.
    func testARefusalQueuesNothing() async throws {
        try writeNote("invoice-march")
        try writeNote("invoice-april")

        let source = makeSource()
        _ = try await send("invoice", from: source)
        XCTAssertTrue(source.drainOutgoingFiles().isEmpty)
    }

    // MARK: - The catalogue it is published in

    /// Built, published, and actually offered — three different things, and the
    /// gap between the last two is where web search spent its first release
    /// doing nothing.
    ///
    /// The middle assertion used to read `BrainPrompts.voiceToolAllowlist
    /// .contains(sendToolName)`. That set curates SAGE and nothing else now, so
    /// the question moved to where it can be answered: the catalogue a Signal
    /// conversation composes.
    func testTheToolIsPublishedAndOffered() async throws {
        XCTAssertTrue(NotesToolSource.toolNames.contains(NotesToolSource.sendToolName))

        let published = try await makeSource().listTools().map(\.name)
        XCTAssertTrue(published.contains(NotesToolSource.sendToolName), "\(published)")

        let offered = try await ComposedCatalogue.conversation()
        XCTAssertTrue(
            offered.contains(NotesToolSource.sendToolName),
            "send_file is published and never offered: \(offered.sorted())"
        )
        // And still unreachable on a call, which is the other half of the same
        // sentence: it is offered because a conversation registers the notes
        // source, not because a name is on a list.
        let onACall = try await ComposedCatalogue.call()
        XCTAssertFalse(onACall.contains(NotesToolSource.sendToolName))
    }

    /// **It sends, so it must count as having acted.** `ToolLoop` treats
    /// anything outside `readOnlyTools` as a real action; listing `send_file`
    /// there would make an honest "it's on its way" look like the fabrication
    /// the 1.3.4 guard exists to catch, and the owner would be told their file
    /// was not sent when it was.
    func testSendingIsNotAReadOnlyTool() {
        XCTAssertFalse(ToolLoopTrace.readOnlyTools.contains(NotesToolSource.sendToolName))

        var trace = ToolLoopTrace(model: "m", toolsOffered: 5)
        trace.toolCalls = [
            ToolCallRecord(
                iteration: 1,
                name: NotesToolSource.sendToolName,
                arguments: [:],
                result: "Sending ferry-ticket-a1b2c3.jpg.",
                failed: false,
                durationSeconds: 0.1
            )
        ]
        XCTAssertTrue(trace.didSomething)
    }

    /// "Writing that up" is the wrong thing to say about a file that already
    /// exists — it reads as Mynah having misunderstood the request.
    func testTheWaitingLineTalksAboutFindingRatherThanWriting() throws {
        let line = try XCTUnwrap(
            WorkingReply.line(forTools: [NotesToolSource.sendToolName], previous: nil)
        ).lowercased()

        XCTAssertFalse(line.contains("writ"), line)
        XCTAssertFalse(line.contains("compil"), line)
    }
}
