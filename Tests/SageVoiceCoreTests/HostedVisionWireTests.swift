import XCTest
@testable import SageVoiceCore

/// **What the two hosted encoders actually put on the wire.**
///
/// `BrainMessage.images` existed from the day the type was written and only
/// `OllamaClient` ever read it. Every hosted backend accepted the array and
/// dropped it — no error, no log — so the owner watched Signal upload a photo
/// and was told *"I can't see an image attached to this message, nothing came
/// through."* The daemon had found it, read 94 KB off disk and encoded it.
///
/// These assert on the serialised body rather than on a helper, for the reason
/// `BrainTierTests` records about the output-token floor: a correct encoder
/// nobody calls is not an encoder. Every case here would have passed trivially
/// before this feature existed, because there was nothing to assert on.
final class HostedVisionWireTests: XCTestCase {

    /// Deliberately not a real JPEG. Nothing in either encoder decodes the
    /// bytes — they are base64'd and posted — so a fixture that is recognisably
    /// itself in the output is worth more than a valid image.
    private let photo = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46])

    private var photoBase64: String { photo.base64EncodedString() }

    // MARK: Anthropic

    /// The shape Anthropic documents: a base64 `image` block, then the caption.
    func testAnthropicPutsTheJPEGOnTheWireAsABase64ImageBlock() throws {
        let encoded = try AnthropicBackend.encodeMessages(
            [.user("what is this plant", images: [photo])],
            carryingImages: true
        )

        XCTAssertEqual(encoded.count, 1)
        let blocks = try XCTUnwrap(encoded[0]["content"] as? [[String: Any]])
        XCTAssertEqual(blocks.count, 2, "expected one image block and one text block")

        // **Image first.** Anthropic's own guidance — "Claude works best when
        // images come before text" — and it makes the caption read as being
        // about the picture.
        XCTAssertEqual(blocks[0]["type"] as? String, "image")
        let source = try XCTUnwrap(blocks[0]["source"] as? [String: Any])
        XCTAssertEqual(source["type"] as? String, "base64")
        XCTAssertEqual(source["media_type"] as? String, "image/jpeg")
        XCTAssertEqual(source["data"] as? String, photoBase64)

        XCTAssertEqual(blocks[1]["type"] as? String, "text")
        XCTAssertEqual(blocks[1]["text"] as? String, "what is this plant")
    }

    /// The `data:` prefix is the OpenAI shape and Anthropic rejects it. Asserted
    /// separately from the block shape because it is one character class of
    /// mistake that produces a 400 on the owner's real key.
    func testAnthropicSendsBareBase64RatherThanADataURI() throws {
        let encoded = try AnthropicBackend.encodeMessages(
            [.user("what is this", images: [photo])],
            carryingImages: true
        )
        let blocks = try XCTUnwrap(encoded[0]["content"] as? [[String: Any]])
        let data = try XCTUnwrap((blocks[0]["source"] as? [String: Any])?["data"] as? String)
        XCTAssertFalse(data.hasPrefix("data:"), "that is the OpenAI shape; Anthropic rejects it")
    }

    /// **The gate, from the paying end.** A model the table does not name gets
    /// the caption and nothing else — not a truncated image, not an empty
    /// block: the base64 must appear nowhere in the request at all.
    func testAnthropicSendsNothingForAModelTheTableDoesNotName() throws {
        let encoded = try AnthropicBackend.encodeMessages(
            [.user("what is this plant", images: [photo])],
            carryingImages: false
        )

        let body = try PromptStableJSON.data(from: ["messages": encoded])
        let json = String(decoding: body, as: UTF8.self)
        XCTAssertFalse(json.contains(photoBase64), "photo bytes reached a blind model")
        XCTAssertFalse(json.contains("\"image\""), "an image block reached a blind model")
        XCTAssertTrue(json.contains("what is this plant"), "the caption was dropped too")
    }

    /// **The prompt cache prefix must not move.** Anthropic matches an exact
    /// byte prefix and `PromptStableJSON` is what keeps it still, so a text turn
    /// has to serialise identically whether or not vision exists in the build.
    /// An unconditional content array — even one with an empty image list —
    /// would re-price every text turn in the product to buy nothing.
    func testATextOnlyAnthropicTurnIsByteIdenticalToBefore() throws {
        let carrying = try AnthropicBackend.encodeMessages(
            [.user("morning mate")], carryingImages: true
        )
        let notCarrying = try AnthropicBackend.encodeMessages(
            [.user("morning mate")], carryingImages: false
        )

        let a = try PromptStableJSON.data(from: ["messages": carrying])
        let b = try PromptStableJSON.data(from: ["messages": notCarrying])
        XCTAssertEqual(a, b, "vision changed the bytes of a turn with no image in it")

        let blocks = try XCTUnwrap(carrying[0]["content"] as? [[String: Any]])
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0]["type"] as? String, "text")
    }

    /// Several photos in one message keep their order and all reach the model,
    /// still ahead of the caption.
    func testEveryPhotoInOneTurnIsCarried() throws {
        let second = Data([0x01, 0x02, 0x03])
        let encoded = try AnthropicBackend.encodeMessages(
            [.user("which of these", images: [photo, second])],
            carryingImages: true
        )
        let blocks = try XCTUnwrap(encoded[0]["content"] as? [[String: Any]])
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual((blocks[0]["source"] as? [String: Any])?["data"] as? String, photoBase64)
        XCTAssertEqual(
            (blocks[1]["source"] as? [String: Any])?["data"] as? String,
            second.base64EncodedString()
        )
        XCTAssertEqual(blocks[2]["type"] as? String, "text")
    }

    // MARK: OpenAI-compatible

    /// The chat-completions shape: a text part, then an `image_url` part whose
    /// url is a data URI.
    ///
    /// **Driven through LM Studio, and that is a real limitation worth stating.**
    /// Of the hosted OpenAI-compatible ids this product offers, the sighted ones
    /// are `gpt-5.6-luna`, `gpt-5.6-sol`, `kimi-k2.6`, `kimi-k3` and
    /// `gemini-3.6-flash` — any of which would serve here. A local model
    /// exercises the identical encoder (`openAIWireObject(carryingImages:)`) and
    /// additionally pins the second table, so it is the case that would break
    /// first if `carriesImages` stopped consulting `LocalVisionModels`.
    func testOpenAICompatSendsADataURIImagePart() throws {
        let body = OpenAICompatBackend.requestBody(
            for: BrainRequest(messages: [.user("what is this plant", images: [photo])]),
            model: "llava-v1.6-mistral-7b",
            provider: .lmStudio()
        )

        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let parts = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 2)

        // Text first, matching the vendors' own examples for this endpoint.
        XCTAssertEqual(parts[0]["type"] as? String, "text")
        XCTAssertEqual(parts[0]["text"] as? String, "what is this plant")

        XCTAssertEqual(parts[1]["type"] as? String, "image_url")
        let url = try XCTUnwrap((parts[1]["image_url"] as? [String: Any])?["url"] as? String)
        XCTAssertEqual(url, "data:image/jpeg;base64,\(photoBase64)")

        // `input_image` is the Responses API part type. None of the five
        // providers behind this adapter implement it on chat/completions.
        XCTAssertNil(parts[1]["input_image"])
    }

    /// A sighted hosted model takes the same path, so the hosted arm of the
    /// table is pinned on the wire rather than only through `seesImages`.
    func testASightedHostedModelGetsTheImagePart() throws {
        let body = OpenAICompatBackend.requestBody(
            for: BrainRequest(messages: [.user("read this screenshot", images: [photo])]),
            model: "gpt-5.6-luna",
            provider: .openAI
        )
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let parts = try XCTUnwrap(
            messages[0]["content"] as? [[String: Any]],
            "a model OpenAI documents as taking image input got no image part"
        )
        XCTAssertEqual(parts.last?["type"] as? String, "image_url")
    }

    /// **Content stays a String on a text-only turn.** Some compatible servers
    /// reject a parts array outright there, and DeepSeek prices a context-cache
    /// hit about ten times cheaper than a miss — so this is money, not tidiness.
    func testOpenAICompatKeepsContentAStringWhenThereAreNoImages() throws {
        for (model, provider) in [
            ("llava-v1.6-mistral-7b", OpenAICompatProvider.lmStudio()),
            ("gpt-5.6-luna", .openAI),
            ("deepseek-v4-flash", .deepSeek)
        ] {
            let body = OpenAICompatBackend.requestBody(
                for: BrainRequest(messages: [.user("morning mate")]),
                model: model,
                provider: provider
            )
            let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
            XCTAssertEqual(
                messages[0]["content"] as? String, "morning mate",
                "\(model) promoted a text-only turn to the parts array"
            )
        }
    }

    /// **The gate is the model, not the provider.** DeepSeek's own docs put no
    /// image part on this schema, so a photo must not reach it — even though the
    /// provider is hosted and the adapter is the same one that carries images
    /// for OpenAI.
    func testABlindProviderNeverGetsImageBytes() throws {
        let body = OpenAICompatBackend.requestBody(
            for: BrainRequest(messages: [.user("what is this plant", images: [photo])]),
            model: "deepseek-v4-flash",
            provider: .deepSeek
        )

        let json = String(decoding: try PromptStableJSON.data(from: body), as: UTF8.self)
        XCTAssertFalse(json.contains("image_url"), "an image part reached a text-only model")
        XCTAssertFalse(json.contains(photoBase64), "photo bytes reached a text-only model")

        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages[0]["content"] as? String, "what is this plant")
    }

    /// A local server running a text-only model is blind for the same reason,
    /// through the other table.
    func testALocalTextOnlyModelNeverGetsImageBytes() throws {
        let body = OpenAICompatBackend.requestBody(
            for: BrainRequest(messages: [.user("what is this", images: [photo])]),
            model: "qwen3.5-4b",
            provider: .lmStudio()
        )
        let json = String(decoding: try PromptStableJSON.data(from: body), as: UTF8.self)
        XCTAssertFalse(json.contains(photoBase64))
    }

    // MARK: The table itself

    /// **The default is blind, and there is no other fallback.** The two errors
    /// are not symmetric: omitting a sighted model costs one description, while
    /// including a blind one ships a confident invention about the owner's own
    /// photo.
    func testAModelMissingFromTheTableReadsAsBlind() {
        XCTAssertFalse(CloudBrainModelCatalog.seesImages(model: "deepseek-v4-flash"))
        XCTAssertFalse(CloudBrainModelCatalog.seesImages(model: "a-model-nobody-listed"))
        XCTAssertFalse(CloudBrainModelCatalog.seesImages(model: ""))
        // No prefix cleverness: vision is a property of the exact model, and
        // guessing from the family name is guessing in the direction that lies.
        XCTAssertFalse(CloudBrainModelCatalog.seesImages(model: "claude-haiku-4-5-20251001"))
        XCTAssertFalse(CloudBrainModelCatalog.seesImages(model: "gpt-5.6"))
    }

    func testTheModelsWeConfirmedAreNamed() {
        for model in ["claude-haiku-4-5", "claude-sonnet-5", "gpt-5.6-luna",
                      "gpt-5.6-sol", "kimi-k2.6", "kimi-k3", "gemini-3.6-flash"] {
            XCTAssertTrue(
                CloudBrainModelCatalog.seesImages(model: model),
                "\(model) was read off its vendor's documentation as taking image input"
            )
        }
    }

    /// **A typo in the table would sit there matching nothing forever**, looking
    /// like coverage that does not exist — and the only symptom would be a
    /// photo silently never sent, which is the quiet half of this defect class.
    func testEveryModelInTheVisionTableIsOneWeActuallyOffer() {
        let offered = Set(
            CloudBrainModelCatalog.providersWithAPick
                .flatMap { CloudBrainModelCatalog.models(forProvider: $0) }
        )
        for model in CloudBrainModelCatalog.sightedModels {
            XCTAssertTrue(
                offered.contains(model),
                "\(model) is in the vision table but no provider offers it — a typo here "
                    + "matches nothing and reads as support that is not there"
            )
        }
    }

    // MARK: Local families

    /// **The regression that shipped.** `qwen3.5:4b` is the appliance's default
    /// model and has no visual encoder; `seesImages` returned a hardcoded
    /// `true`, so the prompt told it to say what it could see.
    func testATextOnlyLocalModelIsNotAdvertisedAsSighted() {
        XCTAssertFalse(LocalVisionModels.sees("qwen3.5:4b"))
        XCTAssertTrue(LocalVisionModels.sees("llava:13b"))
        XCTAssertTrue(LocalVisionModels.sees("llava-v1.6-mistral-7b"), "LM Studio names too")
        XCTAssertTrue(LocalVisionModels.sees("qwen2.5vl:7b-q4_K_M"))
        XCTAssertTrue(LocalVisionModels.sees("LLaVA:13B"), "tags and case are the owner's, not ours")
    }

    /// **Families whose vision depends on the size tag stay out.** `gemma3:1b`
    /// is text-only and `gemma3:4b` is not, so a family match would claim sight
    /// for the small one — the fabrication direction. Both read blind until
    /// something can tell them apart, which is what the `/api/show` probe is
    /// for.
    func testASizeDependentFamilyIsNotGuessedAt() {
        XCTAssertFalse(LocalVisionModels.sees("gemma3:1b"))
        XCTAssertFalse(LocalVisionModels.sees("gemma3:4b"))
        XCTAssertFalse(LocalVisionModels.sees("mistral-small3:latest"))
        XCTAssertFalse(LocalVisionModels.sees(""))
    }

    /// A prefix, not a substring: a model merely mentioning a family in a
    /// fine-tune suffix has not inherited its eyes.
    func testAFamilyNameBuriedInAModelNameDoesNotGrantSight() {
        XCTAssertFalse(LocalVisionModels.sees("mistral-llava-merge:7b"))
    }

    // MARK: Backends agree with the tables

    func testEachBackendComputesSeesImagesFromItsOwnModel() {
        XCTAssertTrue(OllamaBackend(model: "llava:13b").seesImages)
        XCTAssertFalse(OllamaBackend(model: "qwen3.5:4b").seesImages)

        let seeing = AnthropicBackend(modelName: "claude-sonnet-5", apiKey: "k")
        let blind = AnthropicBackend(modelName: "claude-opus-4-1", apiKey: "k")
        XCTAssertTrue(seeing.seesImages)
        XCTAssertFalse(blind.seesImages, "an id the table does not name must read blind")
    }
}
