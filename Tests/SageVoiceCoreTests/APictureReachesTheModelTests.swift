import XCTest
@testable import SageVoiceCore

/// A photo the owner sends, all the way to the bytes on the wire.
///
/// **This file exists because the capability was declared and not built for five
/// releases.** `BrainMessage.images` has been carried since the day it was
/// written; `OllamaClient` read it and every other backend dropped it on the
/// floor. Nothing failed, nothing logged, and the model — handed a caption with
/// no picture — answered the only way it could: *"I'm not able to see any image
/// attached to this message."* The owner had watched his phone upload a dog.
///
/// So these assert on the request bodies rather than on the flags: a test that
/// the capability is *true* would have passed for the whole of that period.
final class APictureReachesTheModelTests: XCTestCase {

    /// Stands in for what `VisionAttachment.encoded` produces: JPEG bytes,
    /// already downscaled. The contents are irrelevant — every backend's job is
    /// to move these bytes, not to read them.
    private let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0xFF, 0xD9])

    private func bytesSent(_ body: [String: Any]) throws -> String {
        String(decoding: try PromptStableJSON.data(from: body), as: UTF8.self)
    }

    // MARK: - The OpenAI-compatible shape (DeepSeek, OpenAI, Kimi, Gemini)

    /// The picture arrives in the owner's turn, as a content part, as a data
    /// URL. This is the whole feature for every provider that speaks this shape.
    func testAnOpenAIShapedRequestCarriesThePictureInTheOwnersTurn() throws {
        let body = OpenAICompatBackend.requestBody(
            for: BrainRequest(messages: [.user("what is this?", images: [jpeg])]),
            model: "deepseek-flash",
            provider: .deepSeek
        )

        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(
            messages.first?["content"] as? [[String: Any]],
            "the owner's turn was flattened to a string, so the picture was dropped"
        )

        XCTAssertEqual(content.count, 2, "one text part and one picture, got \(content)")
        XCTAssertEqual(content[0]["type"] as? String, "text")
        XCTAssertEqual(content[0]["text"] as? String, "what is this?")

        XCTAssertEqual(content[1]["type"] as? String, "image_url")
        let url = try XCTUnwrap(
            (content[1]["image_url"] as? [String: Any])?["url"] as? String
        )
        XCTAssertTrue(url.hasPrefix("data:image/jpeg;base64,"), url)
        XCTAssertEqual(
            url.replacingOccurrences(of: "data:image/jpeg;base64,", with: ""),
            jpeg.base64EncodedString(),
            "the bytes that reached the provider are not the picture"
        )
    }

    /// **The turn that must not change shape.** A text turn's content has to
    /// stay a plain string: these bytes are the prompt-cache prefix, DeepSeek
    /// charges about a tenth as much for a cache hit, and a content array sent
    /// for every ordinary turn would move the prefix on every ordinary turn.
    func testATurnWithNoPictureIsEncodedExactlyAsItAlwaysWas() throws {
        let body = OpenAICompatBackend.requestBody(
            for: BrainRequest(messages: [.user("what is this?")]),
            model: "deepseek-flash",
            provider: .deepSeek
        )

        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["content"] as? String, "what is this?")
    }

    /// And a model that cannot see is sent no image at all — not a text part
    /// saying one exists, and nothing for the model to hallucinate around.
    ///
    /// DeepSeek's own two tiers disagree about this, which is what makes the
    /// case real rather than hypothetical: Quick takes images, Careful does not.
    func testAModelThatCannotSeeIsNeverSentThePicture() throws {
        let request = BrainRequest(messages: [.user("what is this?", images: [jpeg])])
        let body = OpenAICompatBackend.requestBody(
            for: request,
            model: "deepseek-v4-pro",
            provider: .deepSeek
        )

        let encoded = try bytesSent(body)
        XCTAssertFalse(
            encoded.contains(jpeg.base64EncodedString()),
            "an image was put on the wire for a model that cannot read one"
        )
        XCTAssertFalse(encoded.contains("image_url"))
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["content"] as? String, "what is this?")
    }

    // MARK: - The Anthropic shape

    /// Anthropic takes an image as its own block ahead of the text, and the
    /// media type is named rather than guessed — every image reaching here has
    /// already been re-encoded to JPEG by `VisionAttachment`.
    func testAnAnthropicRequestCarriesThePictureAsAnImageBlock() throws {
        let encoded = try AnthropicBackend.encodeMessages(
            [.user("what is this?", images: [jpeg])],
            includingImages: true
        )

        let blocks = try XCTUnwrap(encoded.first?["content"] as? [[String: Any]])
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0]["type"] as? String, "image")

        let source = try XCTUnwrap(blocks[0]["source"] as? [String: Any])
        XCTAssertEqual(source["type"] as? String, "base64")
        XCTAssertEqual(source["media_type"] as? String, "image/jpeg")
        XCTAssertEqual(source["data"] as? String, jpeg.base64EncodedString())
        XCTAssertEqual(blocks[1]["type"] as? String, "text")
    }

    /// A photo with no caption is still a legal turn: the text block goes out
    /// empty rather than being omitted, because Anthropic rejects a turn whose
    /// content array is empty.
    func testAPhotoWithNoCaptionStillMakesALegalAnthropicTurn() throws {
        let encoded = try AnthropicBackend.encodeMessages(
            [.user("", images: [jpeg])],
            includingImages: true
        )

        let blocks = try XCTUnwrap(encoded.first?["content"] as? [[String: Any]])
        XCTAssertEqual(blocks.map { $0["type"] as? String }, ["image", "text"])
    }

    // MARK: - The local shape

    /// Ollama takes bare base64 on the message, and only for a model with a
    /// vision encoder.
    func testALocalPictureRidesOnTheMessageOnlyForAModelThatCanSee() throws {
        let message = BrainMessage.user("what is this?", images: [jpeg])

        let seeing = try XCTUnwrap(
            OllamaClient.wireMessages([message], model: "qwen3.5:4b").first
        )
        XCTAssertEqual(seeing["images"] as? [String], [jpeg.base64EncodedString()])

        let blind = try XCTUnwrap(
            OllamaClient.wireMessages([message], model: "llama3.1:8b").first
        )
        XCTAssertNil(
            blind["images"],
            "an images array was sent to a local model that cannot read one"
        )
        XCTAssertEqual(blind["content"] as? String, "what is this?")
    }

    // MARK: - Which models can see

    /// The appliance's own local brain is multimodal, so the default fully-local
    /// setup reads pictures with no second model and no extra memory. This is
    /// the assertion that would have caught the flat `seesImages = true` being
    /// a claim about the wire rather than about the model.
    func testTheLocalBrainAndItsFamilyCanSeeAndTextOnlyLocalModelsCannot() {
        for model in ["qwen3.5:4b", "qwen3.5:0.8b", "qwen3.5:27b-q8_0", "qwen3.8:27b-mlx"] {
            XCTAssertTrue(LocalBrainModelCatalog.seesImages(model: model), model)
        }
        // Every other entry in the local catalogue is text-only, and saying
        // otherwise is how an owner gets told their photo was read by something
        // that cannot read it.
        for model in ["qwen3:8b", "llama3.1:8b", "mistral-nemo", "nomic-embed-text"] {
            XCTAssertFalse(LocalBrainModelCatalog.seesImages(model: model), model)
        }
    }

    /// Local servers run whatever the owner pulled, so the same list answers for
    /// LM Studio. A model nobody recognises reads as blind.
    func testALocalOpenAIServerIsJudgedByItsModelToo() {
        XCTAssertTrue(
            OpenAICompatBackend.seesImages(model: "qwen3.5:4b", provider: .lmStudio())
        )
        XCTAssertFalse(
            OpenAICompatBackend.seesImages(model: "some-7b-chat", provider: .lmStudio())
        )
    }

    /// **DeepSeek's two tiers disagree, and the code says so out loud.** The
    /// vendor's Models & Pricing page carries a `Vision` row: ✓ for
    /// `deepseek-flash`, "Not supported" for `deepseek-v4-pro`.
    func testDeepSeeksQuickModelCanSeeAndItsCarefulOneCannot() {
        XCTAssertTrue(
            CloudBrainModelCatalog.seesImages(model: "deepseek-flash", forProvider: "deepseek")
        )
        XCTAssertFalse(
            CloudBrainModelCatalog.seesImages(model: "deepseek-v4-pro", forProvider: "deepseek")
        )
        XCTAssertEqual(
            CloudBrainModelCatalog.pictureNote(forProvider: "deepseek", tier: .fast),
            "Can read a picture you send it."
        )
        XCTAssertEqual(
            CloudBrainModelCatalog.pictureNote(forProvider: "deepseek", tier: .pro),
            "Can't read pictures — Quick can."
        )
    }

    /// The name this owner's Mac is actually configured with — read out of
    /// `mynah.brain.lastModel.key.deepseek` — is the retired one, and DeepSeek
    /// still accepts it and serves it from the current Flash model. It has to
    /// keep seeing pictures, or the fix arrives for everybody except the person
    /// who reported the bug.
    func testTheRetiredDeepSeekNameItsOwnersAreStoredOnStillSees() {
        for model in ["deepseek-v4-flash", "deepseek-v4-flash-vision-exp"] {
            XCTAssertTrue(
                CloudBrainModelCatalog.seesImages(model: model, forProvider: "deepseek"),
                model
            )
        }
    }

    /// A model or a provider nobody listed reads as blind, in both directions.
    /// This is the default the whole attachment path leans on.
    func testAnythingNobodyListedReadsAsBlind() {
        XCTAssertFalse(
            CloudBrainModelCatalog.seesImages(model: "gpt-9.9-quasar", forProvider: "openai")
        )
        XCTAssertFalse(
            CloudBrainModelCatalog.seesImages(model: "some-7b-chat", forProvider: "ollama")
        )
        XCTAssertFalse(
            CloudBrainModelCatalog.seesImages(model: "llama3.3-70b-versatile", forProvider: "groq")
        )
        XCTAssertNil(
            CloudBrainModelCatalog.pictureNote(forProvider: "groq", tier: .fast),
            "a provider whose whole line is blind has nothing useful to say about pictures"
        )
    }

    /// Every provider offered in setup has at least one model that can see, so
    /// "send it a photo" is never a choice between providers.
    func testEveryOfferedProviderCanSeeAPictureOnItsQuickModel() {
        for provider in ["anthropic", "openai", "deepseek"] {
            XCTAssertTrue(
                CloudBrainModelCatalog.tierSeesImages(forProvider: provider, tier: .fast),
                provider
            )
        }
    }
}
