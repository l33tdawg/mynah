import XCTest
@testable import SageVoiceCore

/// The defect these exist for: **on Linux every attachment was silently
/// dropped.**
///
/// The owner sent a PDF, the phone showed it uploaded, the daemon reported the
/// turn handled — and nothing was ever written. `SignalAttachmentStore.keep`
/// threw inside `OwnerOnlyFileSecurity.write`, its `catch` wrote one line to
/// the daemon log and returned `nil`, and a function returning `[Kept]` cannot
/// tell "they sent nothing" apart from "they sent a ferry ticket and it is
/// gone". Both halves are tested here, because fixing either alone leaves the
/// owner in the same chair:
///
/// - **It has to be kept.** `theBytesActuallyLand` walks the whole path against
///   a fresh directory, which is the case that failed: corelibs
///   `FileManager.replaceItemAt` throws `NSCocoaErrorDomain 260` when the
///   *destination* does not exist yet, so the first write of any file died.
/// - **A failure has to reach the owner.** Every refusal path returns a named
///   `Refusal`, and `Outcome.ownerFacingNote` is the sentence that says which
///   file did not save and what to do about it.
///
/// All of these run on Linux. That is the point of them.
final class AnAttachmentThatDidNotSaveIsNotSilenceTests: XCTestCase {

    private var directory = URL(fileURLWithPath: NSTemporaryDirectory())

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mynah-attach-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    /// A source file on disk, standing in for what signal-cli decrypts.
    private func inbound(
        named name: String,
        contentType: String,
        bytes: Data = Data("%PDF-1.4 ferry".utf8)
    ) throws -> ChannelAttachment {
        let source = directory.appendingPathComponent("inbound-\(name)", isDirectory: false)
        try bytes.write(to: source)
        return ChannelAttachment(id: name, contentType: contentType, filename: name, localURL: source)
    }

    private var receivedAt: Date { Date(timeIntervalSince1970: 1_754_582_400) }

    // MARK: - It has to be kept

    /// **The whole of Defect A, in one assertion each.**
    ///
    /// Not "the call returned something" — the bytes are read back off disk and
    /// compared, and the note beside them is read back and checked for the app
    /// name, because a `Kept` describing files that do not exist is exactly the
    /// kind of success this project treats as the worst possible failure.
    ///
    /// The directory is fresh, so both writes are first writes. That is the
    /// case corelibs `replaceItemAt` threw on.
    func testTheBytesActuallyLandAndTheNoteBesideThemNamesTheApp() throws {
        let sent = Data("%PDF-1.4 ferry booking".utf8)
        let attachment = try inbound(named: "ferry.pdf", contentType: "application/pdf", bytes: sent)

        let outcome = SignalAttachmentStore(notesDirectory: directory).keep(
            [attachment],
            via: .whatsapp,
            caption: "the ferry booking",
            receivedAt: receivedAt
        )

        XCTAssertEqual(outcome.refusals, [], "something was refused: \(outcome.refusals)")
        let kept = try XCTUnwrap(outcome.kept.first, "nothing was kept at all")

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: kept.file.path),
            "keep() reported a file at \(kept.file.path) and there is nothing there"
        )
        XCTAssertEqual(try Data(contentsOf: kept.file), sent, "the kept bytes are not the bytes that were sent")

        let note = try String(contentsOf: kept.note, encoding: .utf8)
        XCTAssertTrue(note.contains("WhatsApp"), "the note does not say which app it came from: \(note)")
        XCTAssertTrue(note.contains("the ferry booking"), "the note lost the caption: \(note)")
        XCTAssertTrue(
            note.contains("attachments/\(kept.file.lastPathComponent)"),
            "the note does not point at the file: \(note)"
        )
    }

    /// Everything kept means nothing to apologise for. A note that fires on a
    /// clean turn would train the owner to ignore it.
    func testNothingIsSaidToTheOwnerWhenEverythingWasKept() throws {
        let outcome = SignalAttachmentStore(notesDirectory: directory).keep(
            [try inbound(named: "map.png", contentType: "image/png")],
            via: .signal,
            caption: nil,
            receivedAt: receivedAt
        )
        XCTAssertEqual(outcome.refusals, [])
        XCTAssertNil(outcome.ownerFacingNote, "the owner was told about a failure that did not happen")
    }

    /// The call sites that must keep working unchanged:
    /// `batch.flatMap { store.keep(…) }` in `VoiceBridgeDaemon.keepAttachments`,
    /// and `kept.first?.note` in `AWhatsAppMessageIsNotASignalOneTests`. If
    /// `Outcome` ever stops being a collection of `Kept`, both stop compiling.
    func testTheOutcomeStillReadsAsACollectionOfKeptFiles() throws {
        let outcome = SignalAttachmentStore(notesDirectory: directory).keep(
            [try inbound(named: "ferry.pdf", contentType: "application/pdf")],
            via: .signal,
            caption: nil,
            receivedAt: receivedAt
        )
        let flattened: [SignalAttachmentStore.Kept] = [outcome].flatMap { $0 }
        XCTAssertEqual(flattened, outcome.kept)
        XCTAssertEqual(outcome.count, 1)
        XCTAssertEqual(outcome.first, outcome.kept.first)
    }

    // MARK: - A failure has to reach the owner

    /// **The exact silence that shipped.** signal-cli decrypts to a path that is
    /// not there — or the disk is full, or the file is unreadable — and the old
    /// code logged and returned `nil`. Now it comes back named.
    func testAnAttachmentThatCannotBeReadIsNamedToTheOwner() throws {
        let missing = directory.appendingPathComponent("never-written.pdf", isDirectory: false)
        let outcome = SignalAttachmentStore(notesDirectory: directory).keep(
            [ChannelAttachment(id: "1", contentType: "application/pdf", filename: "ferry.pdf", localURL: missing)],
            via: .whatsapp,
            caption: "the ferry booking",
            receivedAt: receivedAt
        )

        XCTAssertEqual(outcome.kept, [], "a file that does not exist was reported as kept")
        XCTAssertEqual(outcome.refusals.map(\.name), ["ferry.pdf"])

        let told = try XCTUnwrap(outcome.ownerFacingNote, "the owner was told nothing at all")
        XCTAssertTrue(told.contains("ferry.pdf"), "the refusal does not name the file: \(told)")
        XCTAssertTrue(told.contains("could NOT be saved"), "the refusal does not say it failed: \(told)")
        XCTAssertTrue(told.contains("send"), "the refusal does not say what to do next: \(told)")
    }

    /// The channel announced a file it had not written yet. Also a loss, also
    /// the owner's business.
    func testAnAttachmentTheChannelNeverWroteIsNamedToTheOwner() throws {
        let outcome = SignalAttachmentStore(notesDirectory: directory).keep(
            [ChannelAttachment(id: "1", contentType: "image/png", filename: "receipt.png", localURL: nil)],
            via: .signal,
            caption: nil,
            receivedAt: receivedAt
        )
        XCTAssertEqual(outcome.kept, [])
        XCTAssertEqual(outcome.refusals.map(\.name), ["receipt.png"])
        XCTAssertTrue(outcome.refusals.allSatisfy(\.isImage), "a png was not reported as an image")
        let told = try XCTUnwrap(outcome.ownerFacingNote)
        XCTAssertTrue(told.contains("receipt.png"), told)
    }

    /// **The batch-wide silence.** An unusable notes directory returned `[]` —
    /// the same value as "they sent nothing" — and lost the whole message. Every
    /// attachment now comes back named, not just the first.
    func testAnUnusableNotesDirectoryRefusesEveryAttachmentByName() throws {
        // A regular file where the notes directory should be, so creating
        // `<notes>/attachments` cannot succeed on any platform.
        let blocked = directory.appendingPathComponent("blocked", isDirectory: false)
        try Data("not a directory".utf8).write(to: blocked)

        let outcome = SignalAttachmentStore(notesDirectory: blocked).keep(
            [
                ChannelAttachment(id: "1", contentType: "application/pdf", filename: "ferry.pdf", localURL: blocked),
                ChannelAttachment(id: "2", contentType: "application/pdf", filename: "receipt.pdf", localURL: blocked)
            ],
            via: .whatsapp,
            caption: nil,
            receivedAt: receivedAt
        )

        XCTAssertEqual(outcome.kept, [])
        XCTAssertEqual(outcome.refusals.map(\.name), ["ferry.pdf", "receipt.pdf"])
        let told = try XCTUnwrap(outcome.ownerFacingNote, "a whole message was lost in silence")
        XCTAssertTrue(told.contains("ferry.pdf"), told)
        XCTAssertTrue(told.contains("receipt.pdf"), told)
        // Plural, and grammatical — a model reads this sentence out loud.
        XCTAssertTrue(told.contains("2 files that could NOT be saved"), told)
        XCTAssertTrue(told.contains("they were not saved"), told)
        XCTAssertTrue(told.contains("Do NOT say they were saved"), told)
    }

    /// **The third state, which used to be reported as a success.**
    ///
    /// The bytes land and the note beside them does not. `notes_list`,
    /// `notes_read` and `send_file` all go through the note, so a file with no
    /// note can never be asked for by name — from the owner's chair it is gone,
    /// and calling that "kept" is the same lie in a smaller box.
    ///
    /// Forced with a `FileManager` that refuses to create files directly in the
    /// notes directory, which is where the note goes and nothing else does —
    /// the bytes live one level down in `attachments/`. Putting a directory in
    /// the note's way does not work: macOS's `replaceItemAt` deletes it and
    /// writes the file anyway, even when it is not empty.
    func testAFileWhoseNoteCouldNotBeWrittenIsReportedAsALoss() throws {
        let outcome = SignalAttachmentStore(
            notesDirectory: directory,
            fileManager: RefusesToWriteNotes(notesDirectory: directory)
        ).keep(
            [try inbound(named: "ferry.pdf", contentType: "application/pdf")],
            via: .whatsapp,
            caption: "the ferry booking",
            receivedAt: receivedAt
        )
        XCTAssertEqual(outcome.kept, [], "a file nothing can find was reported as kept")
        XCTAssertEqual(outcome.refusals.map(\.name), ["ferry.pdf"])
        XCTAssertTrue(
            try XCTUnwrap(outcome.ownerFacingNote).contains("ferry.pdf"),
            "the owner was not told which file went missing"
        )
        // And the bytes are still there rather than deleted: a copy they cannot
        // search for beats a copy that no longer exists.
        let attachments = directory.appendingPathComponent(SignalAttachmentStore.subdirectory, isDirectory: true)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: attachments.path).count,
            1,
            "the bytes were thrown away as well"
        )
    }

    /// A photo and a document lost together are two different sentences —
    /// "image" and "file" are the nouns `AttachmentArrivalNote` uses, and a
    /// refusal that called a PDF an image would have the owner hunting for the
    /// wrong thing.
    func testAPhotoAndADocumentLostTogetherAreNamedSeparately() throws {
        let gone = directory.appendingPathComponent("gone", isDirectory: false)
        let outcome = SignalAttachmentStore(notesDirectory: directory).keep(
            [
                ChannelAttachment(id: "1", contentType: "application/pdf", filename: "ferry.pdf", localURL: gone),
                ChannelAttachment(id: "2", contentType: "image/png", filename: "map.png", localURL: gone)
            ],
            via: .whatsapp,
            caption: nil,
            receivedAt: receivedAt
        )
        let told = try XCTUnwrap(outcome.ownerFacingNote)
        XCTAssertTrue(told.contains("an image that could NOT be saved: \"map.png\""), told)
        XCTAssertTrue(told.contains("a file that could NOT be saved: \"ferry.pdf\""), told)
    }

    /// **The sentence must never read as a success.** Handed a name and no
    /// bytes, a model will describe the picture, or say it was saved, or both —
    /// that is the fabrication `AttachmentArrivalNote` was written to stop, and
    /// a refusal that invites it is worse than the silence.
    func testTheOwnerFacingNoteNeverClaimsAnythingWasSaved() throws {
        let outcome = SignalAttachmentStore(notesDirectory: directory).keep(
            [ChannelAttachment(
                id: "1",
                contentType: "image/png",
                filename: "plant.png",
                localURL: directory.appendingPathComponent("gone.png")
            )],
            via: .signal,
            caption: "what is this plant",
            receivedAt: receivedAt
        )
        let told = try XCTUnwrap(outcome.ownerFacingNote)
        XCTAssertFalse(told.contains("already saved"), "the refusal claims the file was saved: \(told)")
        XCTAssertFalse(told.contains("sendable"), "the refusal offers a file that does not exist: \(told)")
        XCTAssertTrue(told.contains("it was not saved"), told)
        XCTAssertTrue(told.contains("Do NOT say it was saved"), told)
        XCTAssertTrue(told.contains("do NOT describe it"), told)
        XCTAssertTrue(told.hasPrefix("[") && told.hasSuffix("]"), "not shaped like a transcript aside: \(told)")
    }

    /// A refusal the owner cannot act on is barely better than the silence. The
    /// channel gives a filename when it has one and nothing when it does not, so
    /// there is always a fallback and it is never empty.
    func testARefusalIsAlwaysNamedSomething() {
        XCTAssertEqual(
            SignalAttachmentStore.ownerFacingName(
                for: ChannelAttachment(id: "1", contentType: "application/pdf", filename: "ferry.pdf")
            ),
            "ferry.pdf"
        )
        XCTAssertEqual(
            SignalAttachmentStore.ownerFacingName(
                for: ChannelAttachment(id: "1", contentType: "image/png", filename: nil),
                source: URL(fileURLWithPath: "/tmp/sig-1234.png")
            ),
            "sig-1234.png"
        )
        XCTAssertEqual(
            SignalAttachmentStore.ownerFacingName(
                for: ChannelAttachment(id: "1", contentType: "application/pdf", filename: "   ")
            ),
            "the application/pdf they sent"
        )
        XCTAssertEqual(
            SignalAttachmentStore.ownerFacingName(for: ChannelAttachment(id: "1")),
            "the file they sent"
        )
    }

    // MARK: - The date, which is the innocent suspect

    /// **`Date.formatted` is not the bug, and the obvious fix for it is a macOS
    /// regression.** Pinned here so nobody has to re-measure.
    ///
    /// Every string below was produced identically by macOS 15 and by
    /// swift:6.0-jammy, byte for byte. Swapping to `DateFormatter` with
    /// `dateStyle`/`timeStyle` — the natural "make it portable" move — changes
    /// thirteen of twenty locales: `de_DE` abbreviated becomes `07.08.2025`,
    /// `ja_JP` becomes `2025/08/07`, and `th_TH` switches to the Buddhist
    /// calendar and prints **2568**. A captionless title becomes a filename
    /// through `NoteSlug.slug`, so that swap renames files the owner already
    /// has.
    func testTheDateStampIsTheOneBothPlatformsAlreadyAgreeOn() {
        let utc = TimeZone(identifier: "UTC")!
        func note(_ locale: String) -> String {
            var style = SignalAttachmentStore.noteDateStyle
            style.locale = Locale(identifier: locale)
            style.timeZone = utc
            return SignalAttachmentStore.stamp(receivedAt, style: style)
        }
        func title(_ locale: String) -> String {
            var style = SignalAttachmentStore.titleDateStyle
            style.locale = Locale(identifier: locale)
            style.timeZone = utc
            return SignalAttachmentStore.stamp(receivedAt, style: style)
        }

        XCTAssertEqual(note("en_US"), "August 7, 2025 at 4:00\u{202F}PM")
        XCTAssertEqual(title("en_US"), "Aug 7, 2025 at 4:00\u{202F}PM")
        XCTAssertEqual(note("de_DE"), "7. August 2025 um 16:00")
        XCTAssertEqual(title("de_DE"), "7. Aug. 2025, 16:00")
        XCTAssertEqual(title("ja_JP"), "2025年8月7日 16:00")
        XCTAssertEqual(title("th_TH"), "7 ส.ค. 2025 16:00", "the Buddhist calendar means DateFormatter got in")
    }

    /// The stamp must stay exactly what `receivedAt.formatted(date:time:)`
    /// produced when this shipped, in whatever locale the owner's machine is
    /// set to — including this one. This is the guard that reddens if the
    /// implementation is ever swapped for something merely equivalent-looking.
    func testTheStampMatchesTheExpressionMacOSHasAlwaysUsed() {
        XCTAssertEqual(
            SignalAttachmentStore.stamp(receivedAt, style: SignalAttachmentStore.noteDateStyle),
            receivedAt.formatted(date: .long, time: .shortened)
        )
        XCTAssertEqual(
            SignalAttachmentStore.stamp(receivedAt, style: SignalAttachmentStore.titleDateStyle),
            receivedAt.formatted(date: .abbreviated, time: .shortened)
        )
        XCTAssertEqual(
            SignalAttachmentStore.title(caption: nil, receivedAt: receivedAt),
            "Attachment from \(receivedAt.formatted(date: .abbreviated, time: .shortened))"
        )
    }

    /// And on Linux it has to actually come out as something. An empty stamp
    /// would leave the note reading "Sent to Mynah on Signal, ." and would
    /// collapse every captionless title onto one filename.
    func testTheNoteCarriesAReadableDateOnThisPlatform() throws {
        let outcome = SignalAttachmentStore(notesDirectory: directory).keep(
            [try inbound(named: "ferry.pdf", contentType: "application/pdf")],
            via: .signal,
            caption: nil,
            receivedAt: receivedAt
        )
        let kept = try XCTUnwrap(outcome.kept.first)
        let note = try String(contentsOf: kept.note, encoding: .utf8)
        XCTAssertTrue(note.contains("2025"), "the date did not render on this platform: \(note)")
        XCTAssertFalse(
            note.contains("Signal, ."),
            "the date came out empty, which no assertion about the file would have caught: \(note)"
        )
        XCTAssertTrue(
            SignalAttachmentStore.title(caption: nil, receivedAt: receivedAt).count > "Attachment from ".count,
            "a captionless title has no date in it, so every one of them shares a filename"
        )
    }
}

/// Refuses to create a file directly in the notes directory, and nowhere else.
private final class RefusesToWriteNotes: FileManager, @unchecked Sendable {
    private let notesDirectory: String

    init(notesDirectory: URL) {
        self.notesDirectory = notesDirectory.path
        super.init()
    }

    override func createFile(
        atPath path: String,
        contents data: Data?,
        attributes attr: [FileAttributeKey: Any]? = nil
    ) -> Bool {
        guard (path as NSString).deletingLastPathComponent != notesDirectory else { return false }
        return super.createFile(atPath: path, contents: data, attributes: attr)
    }
}
