import XCTest
@testable import SageVoiceCore

/// **The bytes travel exactly once.**
///
/// `BrainMessage.images` has said since it was written that image bytes are
/// *"deliberately not carried in conversation history: re-sending a photo on
/// every subsequent turn would re-pay its token cost forever, and the model has
/// already described it in its reply."*
///
/// That was documentation, not behaviour. `ToolLoop.run` put the owner's turn
/// back on the replay copy verbatim, `conversationOnly` kept user turns
/// verbatim, and `OllamaClient` re-encoded the photo on every later request — so
/// one picture sat in the context and in the shared prompt-cache budget for all
/// sixteen history turns, at roughly 125 KB of base64 a request. The 1.7.0 audit
/// found an invariant that had been written down and never implemented.
///
/// It is implemented now, and it was unpinned: nothing in the suite asserted any
/// of it, so the two new hosted encoders could have re-introduced the leak with
/// everything green. These are the pins.
///
/// **Both directions matter.** The photo must leave history, and it must stay
/// in the turn — including on the wrap-up call, which is the one that actually
/// composes the sentence the owner hears.
final class APhotoIsSentOnceTests: XCTestCase {

    private let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x2A])

    private func sightedLoop(
        _ backend: BrainBackend,
        maxIterations: Int = 1
    ) -> ToolLoop {
        ToolLoop(
            backend: backend,
            mcp: SingleStubToolSource(),
            configuration: ToolLoop.Configuration(
                maxIterations: maxIterations, deadlineSeconds: nil, allowedToolNames: []
            )
        )
    }

    /// The replayable history a caller gets back carries no image bytes at all.
    func testTheReplayedHistoryCarriesNoImageBytes() async throws {
        let backend = PhotoRecordingBackend(seesImages: true)
        let result = try await sightedLoop(backend).run(
            transcript: "what is this plant", images: [jpeg]
        )

        for message in result.messages {
            XCTAssertTrue(
                message.images.isEmpty,
                "a \(message.role) turn kept the photo in replayable history"
            )
        }
    }

    /// **The same fault observed from the paying end.** History is fed back as
    /// the next turn's `history`, exactly as `VoiceBridgeDaemon` does it, and
    /// the second request must contain no image bytes anywhere.
    func testTheSecondTurnDoesNotResendThePhoto() async throws {
        let backend = PhotoRecordingBackend(seesImages: true)
        let first = try await sightedLoop(backend).run(
            transcript: "what is this plant", images: [jpeg]
        )

        let second = PhotoRecordingBackend(seesImages: true)
        _ = try await sightedLoop(second).run(
            transcript: "and is it poisonous to cats",
            history: Array(first.messages.dropFirst())
        )

        let carried = try XCTUnwrap(second.lastRequest).messages.flatMap(\.images)
        XCTAssertTrue(carried.isEmpty, "the photo was re-paid on the following turn")
    }

    /// **The invariant that must NOT be over-applied.** Dropping the bytes after
    /// the first model call would manufacture the exact fabrication this feature
    /// exists to prevent: the arrival note saying *"You can see it"* is still in
    /// the transcript, and the wrap-up — the tools-withheld call that writes the
    /// sentence the owner hears — would have no picture to write it from.
    ///
    /// The cost of keeping it is bounded and worth stating: roughly 1,050 tokens
    /// for a 1024 px image on Anthropic's (w×h)/750, times at most
    /// `maxIterations` model calls, against a photo that would otherwise be
    /// re-paid on all sixteen history turns forever.
    func testThePhotoIsStillThereForTheToolFreeWrapUp() async throws {
        let backend = ToolHungryPhotoBackend()
        let loop = ToolLoop(
            backend: backend,
            mcp: SingleStubToolSource(),
            configuration: ToolLoop.Configuration(
                maxIterations: 2, deadlineSeconds: nil, allowedToolNames: []
            )
        )

        _ = try await loop.run(transcript: "what is this plant", images: [jpeg])

        let wrapUp = try XCTUnwrap(
            backend.allRequests.last(where: { $0.tools.isEmpty }),
            "the tools-withheld wrap-up never ran"
        )
        XCTAssertEqual(
            wrapUp.messages.flatMap(\.images), [jpeg],
            "the wrap-up composes the answer the owner hears and had no photo to write it from"
        )
    }

    /// Every model call inside the turn keeps the picture, for the same reason.
    func testEveryCallInTheTurnCanStillSeeIt() async throws {
        let backend = ToolHungryPhotoBackend()
        let loop = ToolLoop(
            backend: backend,
            mcp: SingleStubToolSource(),
            configuration: ToolLoop.Configuration(
                maxIterations: 2, deadlineSeconds: nil, allowedToolNames: []
            )
        )

        _ = try await loop.run(transcript: "what is this plant", images: [jpeg])

        XCTAssertGreaterThan(backend.allRequests.count, 1)
        for request in backend.allRequests {
            XCTAssertEqual(request.messages.flatMap(\.images), [jpeg])
        }
    }

    /// **The belt to the loop's braces.** `conversationOnly` is what feeds
    /// `ConversationStore` and `PendingDelivery`, and it used to keep user turns
    /// verbatim — so the strip had to happen upstream or not at all. It now
    /// rebuilds them, and nothing image-shaped can reach disk even if a future
    /// caller hands it photos.
    func testConversationOnlyDropsImageBytes() {
        let carried = VoiceBridgeDaemon.conversationOnly([
            .user("what is this plant", images: [jpeg]),
            .assistant("a fiddle-leaf fig")
        ])

        XCTAssertEqual(carried.count, 2)
        XCTAssertTrue(carried[0].images.isEmpty, "a photo reached the conversation store")
        XCTAssertEqual(carried[0].content, "what is this plant", "the words must survive")
    }
}

/// Asks for one tool on every turn that has tools, then answers when they are
/// withheld — so the loop is forced all the way to its wrap-up call.
final class ToolHungryPhotoBackend: BrainBackend, @unchecked Sendable {
    let identifier = "tool-hungry"
    let modelName = "tool-hungry-model"
    let isLocal = true
    let seesImages = true

    private let lock = NSLock()
    private var requests: [BrainRequest] = []

    var allRequests: [BrainRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    func isAvailable() async -> Bool { true }

    func complete(_ request: BrainRequest) async throws -> BrainReply {
        lock.lock()
        requests.append(request)
        let index = requests.count
        lock.unlock()

        guard !request.tools.isEmpty else {
            return BrainReply(
                model: modelName,
                message: .assistant("it is a fiddle-leaf fig"),
                stopReason: .endTurn,
                usage: BrainUsage(inputTokens: 1, outputTokens: 1)
            )
        }
        return BrainReply(
            model: modelName,
            message: BrainMessage(
                role: .assistant,
                content: "",
                toolCalls: [BrainToolCall(id: "call_\(index)", name: "sage_recall", arguments: [:])]
            ),
            stopReason: .toolUse,
            usage: BrainUsage(inputTokens: 1, outputTokens: 1)
        )
    }
}
