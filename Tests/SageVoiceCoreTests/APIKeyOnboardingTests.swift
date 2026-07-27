import XCTest
@testable import SageVoiceCore

private final class StubBackend: BrainBackend, @unchecked Sendable {
    let identifier = "stub"
    let modelName: String
    let isLocal = false

    private let outcome: Result<BrainReply, BrainBackendError>
    private let lock = NSLock()
    private var seen: [BrainRequest] = []

    init(modelName: String = "stub-model", outcome: Result<BrainReply, BrainBackendError>) {
        self.modelName = modelName
        self.outcome = outcome
    }

    func isAvailable() async -> Bool { true }

    func complete(_ request: BrainRequest) async throws -> BrainReply {
        lock.lock(); seen.append(request); lock.unlock()
        return try outcome.get()
    }

    var requests: [BrainRequest] {
        lock.lock(); defer { lock.unlock() }
        return seen
    }
}

private func reply(content: String, toolCalls: [BrainToolCall] = [], model: String = "stub-model") -> BrainReply {
    BrainReply(
        model: model,
        message: BrainMessage(role: .assistant, content: content, toolCalls: toolCalls),
        stopReason: toolCalls.isEmpty ? .endTurn : .toolUse
    )
}

final class APIKeyOnboardingTests: XCTestCase {

    // MARK: Instructions

    /// Every extra navigation step is somewhere for a non-technical owner to
    /// get lost, so these link to the key page itself.
    func testInstructionsLinkStraightToTheKeyPage() {
        XCTAssertEqual(
            APIKeyOnboarding.gemini.keyPageURL.absoluteString,
            "https://aistudio.google.com/apikey"
        )
        for instructions in [APIKeyOnboarding.gemini, APIKeyOnboarding.openAI, APIKeyOnboarding.anthropic] {
            XCTAssertFalse(instructions.steps.isEmpty)
            XCTAssertFalse(instructions.looksLikeHint.isEmpty)
        }
    }

    /// Gemini is the recommended default precisely because it is free, and the
    /// owner should learn that before choosing, not after adding a card.
    func testCostIsStatedUpFront() {
        XCTAssertEqual(APIKeyOnboarding.gemini.costNote?.contains("free"), true)
        XCTAssertEqual(APIKeyOnboarding.openAI.costNote?.contains("card"), true)
    }

    func testUnknownProvidersHaveNoInstructions() {
        XCTAssertNil(APIKeyOnboarding.instructions(forProvider: "nonesuch"))
    }

    /// Regression: `deepseek` was a working backend with no instructions, so
    /// setup answered "no key instructions for provider 'deepseek'" for a
    /// provider the product genuinely supports. Silent, and only findable by
    /// trying it.
    func testEveryKeyedProviderHasInstructions() {
        for provider in APIKeyOnboarding.keyedProviders {
            XCTAssertNotNil(
                APIKeyOnboarding.instructions(forProvider: provider),
                "\(provider) can be built as a backend but has no setup instructions"
            )
        }
    }

    func testEveryKeyedProviderHasAKnownEnvironmentVariable() {
        for provider in APIKeyOnboarding.keyedProviders {
            XCTAssertNotNil(
                ProviderKeyStore.environmentVariable(forProvider: provider),
                "\(provider) has instructions but no environment variable to read"
            )
        }
    }

    /// Cost is the thing a person most needs to know before choosing, and the
    /// only free one should be the only one that says so.
    func testOnlyGeminiIsDescribedAsFree() {
        for provider in APIKeyOnboarding.keyedProviders where provider != "gemini" && provider != "groq" {
            let note = APIKeyOnboarding.instructions(forProvider: provider)?.costNote ?? ""
            XCTAssertFalse(note.isEmpty, "\(provider) must state its cost")
        }
    }

    // MARK: Shape checks

    func testAWholeExportLineIsCaught() {
        XCTAssertEqual(
            APIKeyOnboarding.shapeProblem(of: "export GEMINI_API_KEY=AIzaXXXX", expecting: "gemini"),
            .looksLikeAnEnvironmentLine
        )
    }

    func testAPastedURLIsCaught() {
        XCTAssertEqual(
            APIKeyOnboarding.shapeProblem(of: "https://aistudio.google.com/apikey", expecting: "gemini"),
            .looksLikeAURL
        )
    }

    /// Someone with several providers configured will paste the wrong one.
    func testAKeyFromAnotherProviderIsNamed() {
        XCTAssertEqual(
            APIKeyOnboarding.shapeProblem(of: "sk-ant-api03-xxxx", expecting: "gemini"),
            .wrongProvider(guessed: "an Anthropic")
        )
        XCTAssertEqual(
            APIKeyOnboarding.shapeProblem(of: "sk-proj-xxxx", expecting: "gemini"),
            .wrongProvider(guessed: "an OpenAI")
        )
        XCTAssertEqual(
            APIKeyOnboarding.shapeProblem(of: "AIzaSyXXXX", expecting: "openai"),
            .wrongProvider(guessed: "a Google")
        )
    }

    func testAPlausibleKeyPasses() {
        XCTAssertNil(APIKeyOnboarding.shapeProblem(
            of: "AIzaSyA1B2C3D4E5F6G7H8I9J0K1L2M3N4O5P6Q7R",
            expecting: "gemini"
        ))
    }

    func testEmptyIsCaught() {
        XCTAssertEqual(APIKeyOnboarding.shapeProblem(of: "   ", expecting: "gemini"), .empty)
    }

    /// The shape check must never be the thing that rejects a valid key, so it
    /// stays deliberately loose about anything it cannot be sure of.
    func testAnUnknownProviderAcceptsAnyShape() {
        XCTAssertNil(APIKeyOnboarding.shapeProblem(of: "whatever-123", expecting: "groq"))
    }

    // MARK: Normalisation

    func testWhatPeopleActuallyPasteIsCleanedUp() {
        XCTAssertEqual(APIKeyOnboarding.normalise("  AIzaKEY \n"), "AIzaKEY")
        XCTAssertEqual(APIKeyOnboarding.normalise("\"AIzaKEY\""), "AIzaKEY")
        XCTAssertEqual(APIKeyOnboarding.normalise("'AIzaKEY'"), "AIzaKEY")
        XCTAssertEqual(APIKeyOnboarding.normalise("Bearer AIzaKEY"), "AIzaKEY")
    }

    func testNormalisationLeavesAPlainKeyAlone() {
        XCTAssertEqual(APIKeyOnboarding.normalise("AIzaKEY"), "AIzaKEY")
    }
}

final class BrainKeyValidatorTests: XCTestCase {

    /// The bug this whole type exists to prevent. `AnthropicBackend.isAvailable()`
    /// passed while every real turn failed, because availability sent
    /// `temperature: nil` and real turns sent `0`, which Opus 4.7+ rejects.
    /// Setup said "you're all set" and the appliance broke on first speech.
    func testValidationSendsTheSameTemperatureRealTurnsDo() async {
        let backend = StubBackend(outcome: .success(reply(
            content: "",
            toolCalls: [BrainToolCall(id: "1", name: "get_time", arguments: [:])]
        )))

        _ = await BrainKeyValidator().validate(backend, temperature: 0)

        XCTAssertEqual(backend.requests.first?.temperature, 0,
                       "validating with different parameters than real turns is how this broke before")
    }

    /// This product is almost entirely tool calls, so a key that works for
    /// chat but not for tools is not a working key.
    func testValidationAttachesAToolAndExpectsItToBeCalled() async {
        let backend = StubBackend(outcome: .success(reply(
            content: "",
            toolCalls: [BrainToolCall(id: "1", name: "get_time", arguments: [:])]
        )))

        let verdict = await BrainKeyValidator().validate(backend)

        XCTAssertEqual(backend.requests.first?.tools.count, 1)
        XCTAssertTrue(verdict.isUsable)
    }

    func testAModelThatIgnoresToolsIsReportedAsUnusable() async {
        let backend = StubBackend(outcome: .success(reply(content: "It is half past three.")))

        let verdict = await BrainKeyValidator().validate(backend)

        XCTAssertFalse(verdict.isUsable)
        guard case .unusable = verdict else { return XCTFail("expected unusable, got \(verdict)") }
    }

    func testAnEmptyReplyIsUnusable() async {
        let backend = StubBackend(outcome: .success(reply(content: "")))
        let verdict = await BrainKeyValidator().validate(backend)
        XCTAssertFalse(verdict.isUsable)
    }

    func testASuccessNamesTheModelSoTheOwnerSeesWhatTheyConnectedTo() async {
        let backend = StubBackend(modelName: "gemini-3.6-flash", outcome: .success(reply(
            content: "",
            toolCalls: [BrainToolCall(id: "1", name: "get_time", arguments: [:])],
            model: "gemini-3.6-flash"
        )))

        let verdict = await BrainKeyValidator().validate(backend)

        XCTAssertTrue(verdict.spokenDescription.contains("gemini-3.6-flash"))
    }

    // MARK: Failure classification

    func testCommonFailuresBecomeSomethingTheOwnerCanActOn() {
        let errors: [BrainBackendError] = [
            .unauthorized(provider: "Gemini", detail: "API_KEY_INVALID"),
            .rateLimited(provider: "Gemini", retryAfterSeconds: nil),
            .badResponse(status: 403, body: "PERMISSION_DENIED"),
            .badResponse(status: 404, body: "model not found"),
            .badResponse(status: 502, body: "<html>bad gateway</html>"),
            .malformedResponse("unexpected JSON")
        ]
        for error in errors {
            let verdict = BrainKeyValidator.classify(error)
            XCTAssertFalse(verdict.isUsable)
            XCTAssertFalse(verdict.spokenDescription.isEmpty)
            for leak in ["HTTP", "PERMISSION_DENIED", "API_KEY_INVALID", "<html>", "502"] {
                XCTAssertFalse(
                    verdict.spokenDescription.contains(leak),
                    "raw provider internals must not reach a non-technical owner: \(leak)"
                )
            }
        }
    }

    /// A rate limit that says when to come back should say so.
    func testARetryAfterIsPassedOn() {
        let verdict = BrainKeyValidator.classify(.rateLimited(provider: "Gemini", retryAfterSeconds: 30))
        XCTAssertTrue(verdict.spokenDescription.contains("30"))
    }

    /// Where the Anthropic temperature bug lands: a good key with a request
    /// shape the provider refuses. Blaming the key sends the owner to fix the
    /// one thing that is not broken.
    func testARejectedRequestIsNotBlamedOnTheKey() {
        let verdict = BrainKeyValidator.classify(.requestRejected("temperature is not supported"))
        guard case .unusable = verdict else {
            return XCTFail("expected unusable, got \(verdict)")
        }
    }

    func testAnUnreachableProviderIsNotReportedAsABadKey() async {
        let backend = StubBackend(outcome: .failure(.unreachable("network is down")))

        let verdict = await BrainKeyValidator().validate(backend)

        guard case .unreachable = verdict else {
            return XCTFail("a network failure must not be blamed on the key, got \(verdict)")
        }
    }
}
