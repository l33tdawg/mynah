import XCTest
@testable import SageVoiceCore

/// A turn may only claim sight of a photograph it is actually carrying.
///
/// ## The lie this ends
///
/// Two facts about one turn were computed from two different places and never
/// compared. `VoiceBridgeDaemon` asked the *backend* whether it reads pictures
/// — `OllamaBackend.seesImages`, a compile-time `true` — and wrote the model an
/// instruction based on the answer: *"You can see it — say what it is,
/// specifically."* Separately it asked `VisionAttachment` to turn the owner's
/// file into bytes, and off Darwin that has no decoder and refuses every file,
/// so `BrainRequest.images` was empty for every photograph ever sent to a Linux
/// appliance.
///
/// The model then did exactly as instructed. With a caption, an order to be
/// specific, and nothing to look at, it described a photograph out of nothing —
/// to an owner holding the real one. Nothing failed, nothing was logged as an
/// error, and the only sentence the owner could check was the invented one.
///
/// ## What is asserted here
///
/// The invariant is deliberately about the turn and not about the platform:
/// **no message handed to a brain may contain the sight instruction unless that
/// same message carries image bytes.** That holds on a Mac, where it is the
/// decoder that occasionally refuses (a corrupt file, one over
/// `VisionAttachment.maximumSourceBytes`), and on Linux, where it always
/// refuses. A test written as "on Linux, expect blindness" would have gone
/// green the day someone hard-coded blindness on Linux and stayed green when
/// the Mac started lying.
///
/// Every test in this file runs on both platforms — no `MynahMac`, no
/// `#if os(macOS)` around the assertions — because the bug was a disagreement
/// between platforms and only a test that runs on both can see one.
final class TheModelIsToldWhatActuallyWentTests: XCTestCase {

    /// The exact wording the note uses to claim sight. Duplicated from
    /// `AttachmentArrivalNote` on purpose: if that sentence is reworded, this
    /// file must be reread rather than silently stop testing anything.
    private static let claimsSight = "You can see it"
    private static let admitsBlindness = "You have NOT seen it"
    /// Present in both branches, so a note that vanished entirely cannot pass
    /// for a note that told the truth.
    private static let announcesTheFile = "already saved as"

    // MARK: - The invariant

    func testNoTurnEverClaimsSightOfAPhotographItIsNotCarrying() async throws {
        let turn = try Turn()
        let outcome = await turn.send(
            caption: "what is this plant?",
            attachment: try turn.realPhotograph(named: "the plant on my balcony.png")
        )

        let requests = turn.backend.recordedRequests
        XCTAssertFalse(
            requests.isEmpty,
            "the turn never reached a brain, so this test proved nothing: \(outcome)"
        )
        XCTAssertTrue(
            requests.contains { request in
                request.messages.contains { $0.content.contains(Self.announcesTheFile) }
            },
            """
            no attachment note reached the model at all, so this test would have passed on
            silence. Nothing was kept, and the daemon said why:
                \(turn.log)
            """
        )

        for request in requests.filter(Self.isAQuestion) {
            for message in request.messages where message.content.contains(Self.claimsSight) {
                XCTAssertFalse(
                    message.images.isEmpty,
                    """
                    a turn told the model "\(Self.claimsSight)" and handed it zero image bytes. \
                    That instruction is what makes a model describe a photograph it has not been \
                    shown, confidently, to the owner who took it.
                    """
                )
            }
        }
    }

    /// Whether the model is being asked to answer, or merely to read.
    ///
    /// One turn produced four requests here, and the fourth is not a question:
    /// it ends in an assistant message because `anchorPromptCache` replays the
    /// finished turn to prefill llama.cpp's prefix cache and throws the output
    /// away. Its history copy has no image bytes — `ToolLoop` strips them from
    /// everything replayable on purpose, at 125 KB of base64 a request — so the
    /// sentence in there is a record of a turn that *did* carry a photograph,
    /// not a promise to a model about one it is holding now. Nothing that
    /// request produces is ever shown to anyone.
    ///
    /// Requests that end in a user or tool message are the ones with an owner
    /// waiting on the other side, and they are what this file polices.
    private static func isAQuestion(_ request: BrainRequest) -> Bool {
        request.messages.last?.role != .assistant
    }

    /// The other half, and the reason the first test cannot be satisfied by
    /// simply never mentioning the picture: when the bytes *do* go, the model
    /// must still be told to look.
    func testWhenTheBytesGoTheModelIsToldToLook() async throws {
        let turn = try Turn()
        _ = await turn.send(
            caption: "what is this plant?",
            attachment: try turn.realPhotograph(named: "the plant on my balcony.png")
        )
        let sent = try XCTUnwrap(turn.userTurn)

        if sent.images.isEmpty {
            XCTAssertTrue(
                sent.content.contains(Self.admitsBlindness),
                """
                no image bytes went and the model was not told so. It was handed a caption about \
                a photograph and left to invent the photograph.
                """
            )
            XCTAssertFalse(sent.content.contains(Self.claimsSight))
        } else {
            XCTAssertTrue(
                sent.content.contains(Self.claimsSight),
                """
                \(sent.images.count) image(s) were put on the wire and the model was told it \
                could not see them — it will refuse to describe a picture it is holding.
                """
            )
            XCTAssertFalse(sent.content.contains(Self.admitsBlindness))
        }
    }

    /// A build with a decoder still has to survive files it cannot decode: a
    /// truncated download, something that is not really a PNG, anything over
    /// `VisionAttachment.maximumSourceBytes`. `resolveImages` drops those by
    /// design and answers the turn without them — which is right, and which
    /// used to leave the sight instruction standing over an empty array on
    /// macOS too.
    func testAFileThatCannotBeDecodedIsNeverClaimedAsSeen() async throws {
        let turn = try Turn()
        _ = await turn.send(
            caption: "what does this say?",
            attachment: try turn.unreadableFile(named: "screenshot.png")
        )
        let sent = try XCTUnwrap(turn.userTurn)

        XCTAssertTrue(sent.images.isEmpty, "a file that is not an image was encoded as one")
        XCTAssertTrue(
            sent.content.contains(Self.announcesTheFile),
            """
            the attachment was not announced at all. The daemon's own account of the turn:
                \(turn.log)
            """
        )
        XCTAssertFalse(
            sent.content.contains(Self.claimsSight),
            """
            an undecodable file was announced to the model as something it could see. \
            The model describes it; the owner is looking at the file that failed.
            """
        )
        XCTAssertTrue(sent.content.contains(Self.admitsBlindness))
    }

    /// A backend that does not read images is still, correctly, told nothing
    /// about sight — the fix must not have made blindness depend only on the
    /// encoder.
    func testABlindBackendIsNeverToldItCanSeeEvenWithBytesInHand() async throws {
        let turn = try Turn(backendSeesImages: false)
        _ = await turn.send(
            caption: "what is this plant?",
            attachment: try turn.realPhotograph(named: "the plant on my balcony.png")
        )
        let sent = try XCTUnwrap(turn.userTurn)

        XCTAssertFalse(sent.content.contains(Self.claimsSight))
        XCTAssertTrue(
            sent.content.contains(Self.admitsBlindness),
            "the model was told nothing either way about a file it cannot see:\n    \(turn.log)"
        )
    }

    /// Documents are not photographs and never were: no sight claim, no
    /// blindness apology, on any platform. Here so the count that now gates the
    /// image sentence cannot start leaking into the document one.
    func testADocumentIsKeptWithoutAnyClaimAboutLookingAtIt() async throws {
        let turn = try Turn()
        _ = await turn.send(
            caption: "keep this",
            attachment: try turn.document(named: "ferry booking.pdf")
        )
        let sent = try XCTUnwrap(turn.userTurn)

        XCTAssertTrue(
            sent.content.contains(Self.announcesTheFile),
            "the owner's document was never announced to the model:\n    \(turn.log)"
        )
        XCTAssertFalse(sent.content.contains(Self.claimsSight))
        XCTAssertFalse(sent.content.contains(Self.admitsBlindness))
    }

    // MARK: - The two ends of the wire agree

    /// The promise `seesImages` makes is about the HTTP body, so this reads the
    /// HTTP body. Everything else in this file asks whether `BrainMessage`
    /// carried bytes; if the wire encoder quietly stopped emitting them — a
    /// renamed key, a shape change in a later Ollama — the array would still be
    /// full, every other test here would stay green, and the model would again
    /// be told to look at nothing.
    func testTheOllamaWireBodyCarriesTheBytesSeesImagesPromises() throws {
        let photo = try Self.pngBytes()
        let withPhoto = BrainMessage.user("what is this plant?", images: [photo]).ollamaWireObject

        XCTAssertEqual(
            withPhoto["images"] as? [String],
            [photo.base64EncodedString()],
            "the backend that claims to send pictures wrote a request body with none in it"
        )
        XCTAssertNil(
            BrainMessage.user("no photo here").ollamaWireObject["images"],
            "a text-only turn grew an images key, which changes the cached prompt prefix"
        )
    }

    /// `OllamaBackend.seesImages` is a promise that the request it builds will
    /// carry bytes, and only `VisionAttachment.encoded` can produce them. This
    /// asks the encoder, on whatever platform is running, and demands the
    /// backend's answer match — so a build that gains an image decoder without
    /// telling the backend, or loses one without telling it, reddens here
    /// rather than in a fabricated description of the owner's balcony.
    func testOllamaClaimsSightExactlyWhenAnImageCanBeEncodedHere() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let photo = directory.appendingPathComponent("probe.png")
        try Self.pngBytes().write(to: photo)

        let encoded: Data?
        do {
            encoded = try VisionAttachment.encoded(contentsOf: photo)
        } catch {
            encoded = nil
        }

        XCTAssertEqual(
            OllamaBackend().seesImages,
            encoded != nil,
            """
            OllamaBackend.seesImages says \(OllamaBackend().seesImages) and VisionAttachment \
            \(encoded == nil ? "cannot encode an image on this platform" : "encoded one fine"). \
            Those two disagreeing is defect 2: the note promises the model a picture that no \
            code path on this build can put on the wire.
            """
        )
        XCTAssertEqual(OllamaBackend.canPutImageBytesOnTheWire, OllamaBackend().seesImages)
    }

    // MARK: - Fixture

    private static func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("what-actually-went-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// A real 16×16 PNG, so a platform with a decoder genuinely decodes it and
    /// a platform without one genuinely refuses it. A fabricated "image" would
    /// fail everywhere and the macOS half of this file would test nothing.
    private static func pngBytes() throws -> Data {
        let base64 = """
        iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAABlklEQVR4nBXRURVEIQhFUSMY\
        gQhGMAIRiGCEE8EIRiACEYhABCLMG7/ZrMt1jMEcyGAN9kAHNjgDBnfwBj6IQQ5q0IMxJnMi\
        kzXZE53Y5EyY3Mmb+CQmOalJzw8IUxBhCVtQwYQjIFzhCS6EkEIJLR9YzIUs1mIvdGGLs2Bx\
        F2/hi1jkoha9PrCZG9mszd7oxjZnw+Zu3sY3sclNbXp/QJmKKEvZiiqmHAXlKk9xJZRUSmn9\
        gDENMZaxDTXMOAbGNZ7hRhhplNH2gcM8yGEd9kEPdjgHDvfwDn6IQx7q0OcD/wK/Sr4jv9hf\
        kG/1N/x/Fx44BCQU9Pc94zIvclmXfdGLXc79j9/Lu/glLnmpS98PPOZDHuuxH/qwx3n/5ffx\
        Hv6IRz7q0e8DznTEWc521DHn+D/KdZ7jTjjplNP+gWAGEqxgBxpYcOIf/AYv8CCCDCro+EAy\
        E0lWshNNLDn5P/MmL/Ekkkwq6fxAMQspVrELLaw49S/lFq/wIoosquj6QDMbaVazG22sOf2v\
        8Dav8SaabKrp5geIAnAQEbP2+wAAAABJRU5ErkJggg==
        """
        return try XCTUnwrap(Data(base64Encoded: base64), "the embedded PNG is not valid base64")
    }

    /// One turn, end to end: a message with an attachment goes into the daemon
    /// and whatever the daemon handed the brain comes back out. The note is
    /// built four layers down and is private, so nothing short of the real path
    /// would have caught this — the old unit tests on `AttachmentArrivalNote`
    /// all pass, and always did, because they were handed the wrong `seesImages`
    /// by the same caller that lied to the model.
    private final class Turn {
        let recipient = ChannelRecipient(kind: .whatsapp, address: "60123821767@s.whatsapp.net")
        let backend: RecordingBackend
        let daemon: VoiceBridgeDaemon
        private let directory: URL
        private var counter = 0
        /// Kept, not dropped, because every way this fixture can fail is a
        /// silent one — a file that was not stored, an image that would not
        /// encode — and the daemon says which in a log line nobody would ever
        /// see. A red assertion here quotes it, so the failure names the layer
        /// that actually refused instead of leaving the next reader to bisect
        /// the daemon.
        private let lines = LogLines()

        init(backendSeesImages: Bool = true) throws {
            directory = try TheModelIsToldWhatActuallyWentTests.temporaryDirectory()
            backend = RecordingBackend(seesImages: backendSeesImages)
            let lines = lines
            daemon = VoiceBridgeDaemon(
                channels: ChannelSet([SilentChannel()]),
                transcriber: NoopAudioFileTranscriber(),
                loop: ToolLoop(backend: backend, mcp: NoTools()),
                // A one-millisecond quiet window, because this suite has no
                // reason to wait 2.5 seconds a turn for a burst that will never
                // arrive.
                configuration: .init(messageQuietWindow: .milliseconds(1)),
                // Kept files go to a temporary folder, never the owner's real
                // notes directory: this test files a plant photograph on every
                // run.
                notes: NotesToolSource(directory: directory.appendingPathComponent("Notes")),
                conversations: ConversationStore(
                    fileURL: directory.appendingPathComponent("conversations.json")
                ),
                pause: PauseState(fileURL: directory.appendingPathComponent("paused")),
                log: { lines.append($0) }
            )
        }

        deinit { try? FileManager.default.removeItem(at: directory) }

        /// What the daemon said while it worked, for a failure message.
        var log: String { lines.all.joined(separator: "\n    ") }

        func send(caption: String, attachment: ChannelAttachment) async -> VoiceBridgeDaemon.Outcome {
            counter += 1
            return await daemon.handle(ChannelMessage(
                kind: .whatsapp,
                recipient: recipient,
                id: "message-\(counter)",
                text: caption,
                attachments: [attachment]
            ))
        }

        /// The owner's turn as the brain received it — the words and the bytes
        /// together, which is the only place the two can be compared.
        var userTurn: BrainMessage? {
            backend.recordedRequests.first?.messages.last { $0.role == .user }
        }

        func realPhotograph(named name: String) throws -> ChannelAttachment {
            let url = directory.appendingPathComponent(name)
            try TheModelIsToldWhatActuallyWentTests.pngBytes().write(to: url)
            return ChannelAttachment(
                id: name, contentType: "image/png", filename: name, localURL: url
            )
        }

        /// Announced as a PNG, and not one. A truncated download looks exactly
        /// like this.
        func unreadableFile(named name: String) throws -> ChannelAttachment {
            let url = directory.appendingPathComponent(name)
            try Data("this is not a picture".utf8).write(to: url)
            return ChannelAttachment(
                id: name, contentType: "image/png", filename: name, localURL: url
            )
        }

        func document(named name: String) throws -> ChannelAttachment {
            let url = directory.appendingPathComponent(name)
            try Data("%PDF-1.4 ferry booking".utf8).write(to: url)
            return ChannelAttachment(
                id: name, contentType: "application/pdf", filename: name, localURL: url
            )
        }
    }

    /// Records what it was asked, answers once, and declares sight — the
    /// pessimistic default would have hidden the whole defect.
    private final class RecordingBackend: BrainBackend, @unchecked Sendable {
        let identifier = "what-actually-went"
        let modelName = "stub"
        let isLocal = true
        let seesImages: Bool
        private let lock = NSLock()
        private var requests: [BrainRequest] = []

        init(seesImages: Bool) { self.seesImages = seesImages }

        var recordedRequests: [BrainRequest] {
            lock.lock()
            defer { lock.unlock() }
            return requests
        }

        func isAvailable() async -> Bool { true }

        func complete(_ request: BrainRequest) async throws -> BrainReply {
            lock.lock()
            requests.append(request)
            lock.unlock()
            return BrainReply(
                model: modelName, message: .assistant("Saved."), stopReason: .endTurn
            )
        }
    }

    private final class SilentChannel: MessageChannel, @unchecked Sendable {
        let kind: ChannelKind = .whatsapp
        nonisolated let incomingMessages: AsyncStream<ChannelMessage>

        init() {
            incomingMessages = AsyncStream { $0.finish() }
        }

        func start() async {}
        func stop() async {}
        var isConnected: Bool { get async { true } }
        func acknowledge(_ message: ChannelMessage) async {}
        func send(_ reply: ChannelReply, to recipient: ChannelRecipient) async throws {}
    }

    /// The daemon logs from whatever thread the turn is on, so this is locked.
    private final class LogLines: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []

        func append(_ line: String) {
            lock.lock()
            defer { lock.unlock() }
            lines.append(line)
        }

        var all: [String] {
            lock.lock()
            defer { lock.unlock() }
            return lines
        }
    }

    /// One allowlisted tool and nothing else. An empty catalogue is refused by
    /// the loop — rightly — and the turn would never reach a brain, which is a
    /// way for every assertion in this file to pass without testing anything.
    private struct NoTools: ToolProviding {
        func listTools() async throws -> [MCPTool] {
            [MCPTool(
                name: "sage_recall",
                description: "read",
                inputSchema: .object(["type": .string("object")])
            )]
        }
        func call(name: String, arguments: [String: JSONValue]) async throws -> String { "" }
    }
}
