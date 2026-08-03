import XCTest
@testable import SageVoiceCore

/// **The rule is the file type, not what the brain happens to be capable of.**
///
/// This wording has now been wrong twice, in opposite directions, and the second
/// was produced by fixing the first.
///
/// Told nothing, a model handed a caption with no picture said *"I can't see an
/// image attached to this message — nothing came through"*, which is a claim
/// about the owner's phone and false. Told it could not see the picture, it
/// apologised and offered to switch to a local model in Settings so it could
/// look — remediation for something nobody asked for.
///
/// Backend capability was the wrong axis. The owner supplied the right one:
///
/// > if i drop a png jpg other image type; then try and interpret it / read it -
/// > if its pdf, docx, xls - keep it for later retrieval
///
/// It matches why somebody sends the thing. A photo is sent to be looked at, so
/// not looking is a real gap worth stating. A booking confirmation is sent to be
/// kept, and reading it out answers a question nobody asked.
final class AttachmentArrivalNoteTests: XCTestCase {

    private func image(_ titles: [String], seesImages: Bool = false) -> String {
        AttachmentArrivalNote.text(
            titles.map { .init(title: $0, isImage: true) }, seesImages: seesImages
        ) ?? ""
    }

    private func document(_ titles: [String], seesImages: Bool = false) -> String {
        AttachmentArrivalNote.text(
            titles.map { .init(title: $0, isImage: false) }, seesImages: seesImages
        ) ?? ""
    }

    // MARK: - Nothing arrived

    func testNothingSaidWhenNothingWasSent() {
        XCTAssertNil(AttachmentArrivalNote.text([], seesImages: false))
        XCTAssertNil(AttachmentArrivalNote.text([], seesImages: true))
    }

    // MARK: - A document, at any capability

    /// **The case the owner was describing.** A PDF is kept, and that is the
    /// whole errand — no description, no summary, no apology for not producing
    /// one.
    func testADocumentIsKeptAndNotRead() {
        for sees in [true, false] {
            let text = document(["ferry booking"], seesImages: sees)

            XCTAssertTrue(text.contains("already saved"), text)
            XCTAssertTrue(text.contains("\"ferry booking\""), text)
            XCTAssertTrue(text.contains("kept for later, not for reading"), text)
            XCTAssertTrue(text.contains("do not describe what is in it"), text)
            XCTAssertTrue(text.contains("in one line"), text)
        }
    }

    /// A brain that *can* read is told the same thing. Capability is not
    /// permission: he sent it to be filed.
    func testASeeingBrainIsStillNotAskedToReadADocument() {
        let text = document(["ferry booking"], seesImages: true)

        XCTAssertFalse(text.contains("You can see it"), text)
        XCTAssertFalse(text.lowercased().contains("specifically"), text)
    }

    /// Nothing to be sorry about, so nothing that reads as regret — and no
    /// mention of vision at all, which would invite the model to bring it up.
    func testADocumentNoteNeverMentionsNotBeingAbleToSeeIt() {
        let text = document(["ferry booking"]).lowercased()

        XCTAssertFalse(text.contains("not seen"), text)
        XCTAssertFalse(text.contains("pictures"), text)
        XCTAssertFalse(text.contains("switch"), text)
        XCTAssertFalse(text.contains("sorry"), text)
        XCTAssertFalse(text.contains("apolog"), text)
    }

    // MARK: - An image

    /// *"if i drop a png jpg other image type; then try and interpret it"* — so
    /// where it works it should be used, and used well.
    func testASeeingBrainIsAskedToDescribeAPicture() {
        let text = image(["the plant on my balcony"], seesImages: true)

        XCTAssertTrue(text.contains("You can see it"), text)
        XCTAssertTrue(text.contains("specifically"), text)
        // Kept either way — the errand does not depend on the brain.
        XCTAssertTrue(text.contains("already saved"), text)
        XCTAssertFalse(text.contains("NOT seen"), text)
    }

    /// **The one place the limitation is worth stating**, because looking is
    /// what they wanted. Said once, plainly, and without an offer to reconfigure
    /// anything.
    func testABlindBrainSaysSoOnceAndOffersNoRemedy() {
        let text = image(["the plant on my balcony"], seesImages: false)

        XCTAssertTrue(text.contains("NOT seen it"), text)
        XCTAssertTrue(text.contains("Say so plainly"), text)
        XCTAssertTrue(text.contains("do not offer to switch models"), text)
        XCTAssertFalse(text.lowercased().contains("settings"), text)
        XCTAssertFalse(text.lowercased().contains("sorry"), text)
        XCTAssertFalse(text.lowercased().contains("apolog"), text)
    }

    /// The original fabrication still has to be blocked. "Saved, but I cannot
    /// see it" and "it never arrived" are opposite claims, and only the second
    /// makes somebody re-send a photo that is already on the Mac.
    func testItStillForbidsSayingTheFileNeverArrived() {
        let text = image(["ferry booking"], seesImages: false)

        XCTAssertTrue(text.contains("do not say it failed to arrive"), text)
        XCTAssertTrue(text.contains("do not guess what is in it"), text)
    }

    // MARK: - Both in one message

    /// A photo and a PDF in the same message get different treatment in the same
    /// note, which is the point of splitting on type rather than on backend.
    func testAPhotoAndADocumentTogetherAreTreatedDifferently() {
        let text = AttachmentArrivalNote.text([
            .init(title: "the plant on my balcony", isImage: true),
            .init(title: "ferry booking", isImage: false)
        ], seesImages: true) ?? ""

        XCTAssertTrue(text.contains("\"the plant on my balcony\""), text)
        XCTAssertTrue(text.contains("\"ferry booking\""), text)
        XCTAssertTrue(text.contains("You can see it"), text)
        XCTAssertTrue(text.contains("kept for later, not for reading"), text)
    }

    // MARK: - What it is filed under

    /// **The title, not the filename on disk.** `send_file` takes a title, so
    /// the only useful thing to say back is the name the owner will need to ask
    /// for it later — `here-s-the-ferry-booking-please-store-it-4ee798.jpg`
    /// tells them where it went, not how to get it.
    func testItNamesWhatToAskForRatherThanWhereTheBytesLanded() {
        let text = document(["ferry booking"])

        XCTAssertTrue(text.contains(NotesToolSource.sendToolName), text)
        XCTAssertFalse(text.contains(".jpg"), text)
        XCTAssertFalse(text.contains("attachments/"), text)
    }

    /// One caption over three photos writes one note, so the titles arrive
    /// repeated. Saying the same name three times reads as three separate
    /// things and would have the owner asking for a file that does not exist.
    func testRepeatedTitlesAreSaidOnce() {
        let text = image(["hotel receipts", "hotel receipts", "hotel receipts"])

        XCTAssertEqual(text.components(separatedBy: "\"hotel receipts\"").count - 1, 1, text)
        XCTAssertTrue(text.contains("3 images"), text)
    }

    func testSeveralDifferentFilesAreAllNamed() {
        let text = document(["ferry booking", "hotel receipt"])

        XCTAssertTrue(text.contains("\"ferry booking\""), text)
        XCTAssertTrue(text.contains("\"hotel receipt\""), text)
        XCTAssertTrue(text.contains("2 files"), text)
    }

    // MARK: - Shape

    /// Bracketed, because it is the daemon speaking inside the owner's message
    /// rather than something the owner said — and the prompt tells the model to
    /// believe the brackets over its own instincts about what it can see.
    func testItIsMarkedAsNotBeingTheOwnersWords() {
        for text in [image(["a"], seesImages: true), image(["a"]), document(["a"])] {
            XCTAssertTrue(text.hasPrefix("["), text)
            XCTAssertTrue(text.hasSuffix("]"), text)
        }
    }

    /// It rides on every message carrying a file, so it is prefill the owner
    /// pays for on those turns. The branch this replaced was 380 characters of
    /// remediation; these have a job and should stay near it.
    func testItStaysShortEnoughToRideOnEveryAttachment() {
        XCTAssertLessThanOrEqual(image(["ferry booking"]).count, 420)
        XCTAssertLessThanOrEqual(image(["ferry booking"], seesImages: true).count, 250)
        XCTAssertLessThanOrEqual(document(["ferry booking"]).count, 340)
    }
}
