import XCTest
@testable import SageVoiceCore

/// **What the model is told about a photo must match what the request carries.**
///
/// This defect class has now produced three different lies, and the third is the
/// one these tests exist for.
///
/// 1. Told nothing, a model handed a caption with no picture said *"I can't see
///    an image attached to this message, nothing came through"* — a claim about
///    the owner's phone, and false.
/// 2. Told it could not see, it apologised and offered to switch models. Fixed
///    by `AttachmentArrivalNote`, whose sentences these tests do not touch.
/// 3. **Told it *could* see, and sent nothing.** The note was built from what
///    `SignalAttachmentStore` had put on disk; the bytes came from a separate
///    pass that dropped anything the encoder could not read and capped the rest
///    at three. Nothing compared the two lists. So a fourth photo, or one
///    malformed HEIC, arrived with *"You can see it — say what it is,
///    specifically"* attached to it, and the model obliged.
///
/// The third is the worst of the three, because the other two are the model
/// reasoning from what it was given. This one is the appliance instructing it to
/// invent.
final class ABrainNeverClaimsToSeeWhatItWasNotSentTests: XCTestCase {

    private let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0])

    // MARK: The loop's own gate

    /// **The mechanism that makes the note and the wire incapable of
    /// disagreeing.** Both are decided from `backend.seesImages`; this is the
    /// half that governs the bytes.
    func testTheLoopWithholdsThePhotoFromABlindBackend() async throws {
        let backend = PhotoRecordingBackend(seesImages: false)
        let loop = ToolLoop(
            backend: backend,
            mcp: SingleStubToolSource(),
            configuration: ToolLoop.Configuration(maxIterations: 1, deadlineSeconds: nil, allowedToolNames: [])
        )

        _ = try await loop.run(transcript: "what is this plant", images: [jpeg])

        let user = try XCTUnwrap(backend.lastRequest?.messages.last(where: { $0.role == .user }))
        XCTAssertTrue(
            user.images.isEmpty,
            "a backend that will not send the bytes was still handed them"
        )
        XCTAssertTrue(user.content.contains("what is this plant"))
    }

    /// **The other arm, and it is not optional.** Without it, a loop that
    /// dropped every image would pass the test above and this whole feature
    /// would be a no-op with a green suite.
    func testASightedBackendIsHandedThePhoto() async throws {
        let backend = PhotoRecordingBackend(seesImages: true)
        let loop = ToolLoop(
            backend: backend,
            mcp: SingleStubToolSource(),
            configuration: ToolLoop.Configuration(maxIterations: 1, deadlineSeconds: nil, allowedToolNames: [])
        )

        _ = try await loop.run(transcript: "what is this plant", images: [jpeg])

        let user = try XCTUnwrap(backend.lastRequest?.messages.last(where: { $0.role == .user }))
        XCTAssertEqual(user.images, [jpeg])
    }

    // MARK: The note, per file

    /// **The reported bug, on this platform.** One photo encodes and one does
    /// not; the model must be told both facts, each about the right file.
    func testAnImageThatCouldNotBeEncodedIsNotClaimedToHaveBeenSeen() throws {
        let note = try XCTUnwrap(AttachmentArrivalNote.text([
            .init(title: "the plant on my balcony", isImage: true, wasSent: true),
            .init(title: "the broken heic", isImage: true, wasSent: false)
        ]))

        XCTAssertTrue(note.contains("You can see it"), note)
        XCTAssertTrue(note.contains("NOT seen it"), note)

        // Each title in the half that is true of it. **Split on the seen
        // sentence's own ending, not on the NOT-seen one**: a title is named
        // before the verdict about it, so splitting on "You have NOT seen it"
        // would put the unseen file's title in the seen half and prove nothing.
        let halves = note.components(separatedBy: "You can see it")
        XCTAssertEqual(halves.count, 2, "expected exactly one seen sentence")
        XCTAssertTrue(halves[0].contains("the plant on my balcony"), note)
        XCTAssertFalse(
            halves[0].contains("the broken heic"),
            "a file whose bytes never left was named in the half that says it was seen"
        )
        XCTAssertTrue(halves[1].contains("the broken heic"), note)
        XCTAssertFalse(halves[1].contains("the plant on my balcony"), note)
    }

    /// **The fourth photo.** `ChannelMessage.maximumImagesPerMessage` is 3 and
    /// the cap used to be applied to the bytes only, while the note was built
    /// from an uncapped list.
    func testTheFourthPhotoIsNotClaimedToHaveBeenSeen() throws {
        var arrivals = (1...3).map {
            AttachmentArrivalNote.Arrival(title: "receipt \($0)", isImage: true, wasSent: true)
        }
        arrivals.append(.init(title: "receipt 4", isImage: true, wasSent: false))

        let note = try XCTUnwrap(AttachmentArrivalNote.text(arrivals))
        let halves = note.components(separatedBy: "You can see it")
        XCTAssertEqual(halves.count, 2)
        XCTAssertTrue(halves[0].contains("receipt 1"), note)
        XCTAssertFalse(
            halves[0].contains("receipt 4"),
            "the photo over the cap was announced as one the model had looked at"
        )
        XCTAssertTrue(halves[1].contains("receipt 4"), note)
        XCTAssertTrue(halves[1].contains("NOT seen it"), note)
    }

    /// When nothing went out — a blind brain, the ordinary case — the note is
    /// exactly the one that shipped before, with no seen half at all.
    func testAWhollyBlindTurnSaysOnlyTheOldSentence() throws {
        let note = try XCTUnwrap(AttachmentArrivalNote.text([
            .init(title: "the plant on my balcony", isImage: true, wasSent: false)
        ]))
        XCTAssertFalse(note.contains("You can see it"), note)
        XCTAssertTrue(note.contains("NOT seen it"), note)
        XCTAssertTrue(note.contains("do not say it failed to arrive"), note)
    }

    /// A document is never read at any capability, so `wasSent` must not leak
    /// into its sentence — the owner sent it to be kept.
    func testADocumentIsUnaffectedByWhatWasSent() throws {
        let note = try XCTUnwrap(AttachmentArrivalNote.text([
            .init(title: "ferry booking", isImage: false)
        ]))
        XCTAssertTrue(note.contains("kept for later, not for reading"), note)
        XCTAssertFalse(note.contains("NOT seen"), note)
        XCTAssertFalse(note.contains("You can see it"), note)
    }

    // MARK: The tables, from the owner's end

    /// The appliance's shipped default has no eyes, and for months the prompt
    /// told it otherwise.
    func testATextOnlyLocalModelIsNotAdvertisedAsSighted() {
        XCTAssertFalse(OllamaBackend(model: "qwen3.5:4b").seesImages)
        XCTAssertTrue(OllamaBackend(model: "llava:13b").seesImages)
        XCTAssertFalse(
            OllamaBackend(model: "gemma3:1b").seesImages,
            "a family whose vision depends on the size tag must not be guessed at"
        )
    }
}

// MARK: - Doubles

/// Answers immediately and keeps the last request, so a test can read exactly
/// what the loop handed the wire.
final class PhotoRecordingBackend: BrainBackend, @unchecked Sendable {
    let identifier = "recording"
    let modelName = "recording-model"
    let isLocal = true
    let seesImages: Bool

    private let lock = NSLock()
    private var requests: [BrainRequest] = []

    init(seesImages: Bool) { self.seesImages = seesImages }

    /// Every request this backend was given, in order. The wrap-up turn is the
    /// last one, which is what makes the mid-turn invariants checkable.
    var allRequests: [BrainRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    var lastRequest: BrainRequest? { allRequests.last }

    func isAvailable() async -> Bool { true }

    func complete(_ request: BrainRequest) async throws -> BrainReply {
        lock.lock()
        requests.append(request)
        lock.unlock()
        return BrainReply(
            model: modelName,
            message: .assistant("that is a fiddle-leaf fig"),
            stopReason: .endTurn,
            usage: BrainUsage(inputTokens: 1, outputTokens: 1)
        )
    }
}

/// The loop refuses to run with an empty catalogue, so every test needs one
/// tool even when it never calls it.
final class SingleStubToolSource: ToolProviding, @unchecked Sendable {
    func listTools() async throws -> [MCPTool] {
        [MCPTool(name: "sage_recall", description: "stub", inputSchema: .object(["type": .string("object")]))]
    }

    func call(name: String, arguments: [String: JSONValue]) async throws -> String { "ok" }
}
