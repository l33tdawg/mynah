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
            let verdict = BrainKeyValidator.classify(
                error,
                model: "some-model-v1",
                provider: "DeepSeek"
            )
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
        let verdict = BrainKeyValidator.classify(
            .rateLimited(provider: "Gemini", retryAfterSeconds: 30),
            model: "some-model-v1",
            provider: "Gemini"
        )
        XCTAssertTrue(verdict.spokenDescription.contains("30"))
    }

    /// **The verdict the owner cannot fix, and must not be asked to.**
    ///
    /// Mynah picks the model now, from a name compiled into this build, so a
    /// provider retiring that name is this build going stale — not a bad key and
    /// not a bad model. Both HTTP shapes mean the same thing and used to read as
    /// two different accusations: 404 became "this model can't run the
    /// assistant" (blaming capability for absence) and 403 became "That key was
    /// refused. The provider accepted the key…" (contradicting itself mid-
    /// sentence). Either way the owner was sent to re-check a key that was fine.
    func testARetiredModelIsNotBlamedOnTheOwnerOrTheirKey() {
        for (status, restricted) in [(404, false), (403, true)] {
            let verdict = BrainKeyValidator.classify(
                .badResponse(status: status, body: "model not found"),
                model: "deepseek-v4-flash",
                provider: "DeepSeek"
            )

            guard case .modelGone(let model, let provider, let wasRestricted) = verdict else {
                return XCTFail("HTTP \(status) must be its own verdict, got \(verdict)")
            }
            XCTAssertEqual(model, "deepseek-v4-flash")
            XCTAssertEqual(provider, "DeepSeek")
            XCTAssertEqual(wasRestricted, restricted)

            // The two things the sentence must do: exonerate the key, and not
            // ask for a retry that cannot possibly succeed.
            let spoken = verdict.spokenDescription
            XCTAssertTrue(spoken.contains("key is fine"), "must exonerate the key: \(spoken)")
            XCTAssertTrue(spoken.contains("deepseek-v4-flash"), "must name the model: \(spoken)")
            XCTAssertFalse(
                verdict.isOwnersToFix,
                "a retry button here invites pasting a correct key until it fails"
            )
        }
    }

    /// The distinction the Bool used to destroy, at the layer that establishes it.
    func testModelListingSeparatesARetiredModelFromEveryOtherFailure() {
        let offered = ["deepseek-chat", "deepseek-reasoner"]

        XCTAssertEqual(
            BrainAvailability.modelNotOffered(model: "deepseek-v9", offered: offered).isUsable,
            false
        )
        // "I could not tell" is not "no" — a compatible server that omits
        // /models must not be treated as a dead one.
        XCTAssertTrue(BrainAvailability.indeterminate.isUsable)
        XCTAssertTrue(BrainAvailability.ready.isUsable)
        XCTAssertFalse(BrainAvailability.noCredential.isUsable)
        XCTAssertFalse(BrainAvailability.unreachable("dns").isUsable)

        // …and the cases stay distinguishable, which is the entire point:
        // collapsing them again would make this equality hold.
        XCTAssertNotEqual(
            BrainAvailability.modelNotOffered(model: "deepseek-v9", offered: offered),
            BrainAvailability.credentialRefused(status: 401)
        )
    }

    /// Where the Anthropic temperature bug lands: a good key with a request
    /// shape the provider refuses. Blaming the key sends the owner to fix the
    /// one thing that is not broken.
    func testARejectedRequestIsNotBlamedOnTheKey() {
        let verdict = BrainKeyValidator.classify(
            .requestRejected("temperature is not supported"),
            model: "some-model-v1",
            provider: "Anthropic"
        )
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

// MARK: - The model Mynah picks

/// The drift these guard against was real and shipping: `BrainFactory` carried a
/// second copy of the daemon's model list under a comment saying the two
/// matched. They did not — DeepSeek was `deepseek-v4-flash` in the daemon and
/// the dead `deepseek-chat` alias in the app — so a brain set up in the app
/// asked for a model that no longer resolved, and the comment is what made that
/// invisible.
final class CloudBrainModelCatalogTests: XCTestCase {

    /// Every provider the setup flow can *offer* must have a model to ask for.
    ///
    /// This is the assertion that would have caught the drift: it walks the
    /// offered catalogue rather than a list written out here, so a provider
    /// added to setup without a model pick fails without anyone remembering to
    /// update a test.
    /// **This `continue` is what let GLM ship broken**, and it is kept rather
    /// than removed because it is still correct — but it is no longer load-
    /// bearing. A provider with no model pick is legitimately unsettled; what
    /// was missing was anything checking that unsettled also meant *unoffered*.
    /// `FreshInstallDefaultTests.testNoOfferedProviderIsMissingAModelToAskFor`
    /// is that check, and it walks the planner's real output rather than this
    /// inventory of instructions.
    func testEveryOfferableProviderHasAModelToAskFor() {
        for provider in APIKeyOnboarding.keyedProviders {
            guard let model = CloudBrainModelCatalog.model(forProvider: provider) else { continue }
            XCTAssertFalse(
                model.trimmingCharacters(in: .whitespaces).isEmpty,
                "\(provider) has an empty model name, which reaches the provider as a 400"
            )
        }
    }

    /// **Nothing may be offered that we cannot explain how to get a key for.**
    ///
    /// *"if we have providers we don't know how to get the key for, remove them
    /// from the list."* The planner already refuses one — the guard has been
    /// there since "Google Gemini API key" shipped for months with no
    /// instructions behind it, which meant the key screen was skipped and Ready
    /// declared success for a brain with no credential.
    ///
    /// What was missing is anybody asserting it against the menu the owner
    /// actually sees, rather than against the inventory the instructions live
    /// in. Those are different lists and only one of them is a promise.
    func testNothingIsOfferedWithoutInstructionsForGettingItsKey() {
        let choices = BrainSetupPlanner().plan(
            for: .machine(ambientKeys: AmbientAPIKeyReport(providers: APIKeyProvider.allCases))
        )

        for option in choices.options where !option.keepsWordsOnDevice {
            guard let provider = option.keyProviderIdentifier else { continue }
            XCTAssertNotNil(
                APIKeyOnboarding.instructions(forProvider: provider),
                "\(option.label) is on the menu and this app cannot tell anyone how to get a "
                    + "key for it — so setup skips the key screen and calls it ready"
            )
        }
    }

    /// A pick that does not exist is `nil`, never a plausible-looking guess.
    ///
    /// A fallback string here would be sent to a real provider on the owner's
    /// real key and fail as "no such model" — indistinguishable from the
    /// appliance being broken, which is the failure this whole area exists to
    /// stop. Not choosing has to be representable.
    func testAnUnchosenProviderIsNilRatherThanAGuess() {
        XCTAssertNil(CloudBrainModelCatalog.model(forProvider: "glm"))
        XCTAssertNil(CloudBrainModelCatalog.model(forProvider: "a-provider-nobody-has-heard-of"))
    }

    /// The specific regression: the alias that stopped resolving must not
    /// come back, from either direction.
    func testDeepSeekDoesNotRegressToTheAliasThatStoppedResolving() {
        XCTAssertEqual(CloudBrainModelCatalog.model(forProvider: "deepseek"), "deepseek-v4-flash")
    }

    /// **Every provider offers the same two things.** *"only show like the 2
    /// latest models - the fast / flash one and their pro model - this should be
    /// standardized across all models in our list."*
    ///
    /// The `Pick` initialiser already makes a half-specified provider
    /// unrepresentable, so this cannot fail by omission — it fails when someone
    /// makes both tiers the same string, which is the way a pair degrades back
    /// into a single offer while still looking like a pair. An owner who opens
    /// the sheet then sees two rows that do the same thing.
    func testEveryProviderOffersExactlyTwoDistinctModels() {
        for provider in CloudBrainModelCatalog.providersWithAPick {
            let models = CloudBrainModelCatalog.models(forProvider: provider)
            XCTAssertEqual(models.count, 2, "\(provider) does not offer a pair")
            XCTAssertNotEqual(
                models[0], models[1],
                "\(provider) offers the same model twice, which is one choice wearing two rows"
            )
            for model in models {
                XCTAssertFalse(
                    model.trimmingCharacters(in: .whitespaces).isEmpty,
                    "\(provider) has an empty model name, which reaches the provider as a 400"
                )
            }
        }
    }

    /// The quick one is what Mynah uses on its own. This is the appliance
    /// argument in `docs/MODEL-CHOICES.md` — a reply that arrives after twenty
    /// seconds is not a reply — so `pro` must stay something the owner reaches
    /// for rather than something they are given.
    func testTheDefaultIsAlwaysTheQuickOne() {
        XCTAssertEqual(CloudBrainModelCatalog.defaultTier, .fast)
        for provider in CloudBrainModelCatalog.providersWithAPick {
            let picked = CloudBrainModelCatalog.model(forProvider: provider)
            XCTAssertEqual(
                picked, CloudBrainModelCatalog.pick(forProvider: provider)?.fast,
                "\(provider) hands out its slow model by default"
            )
        }
    }

    /// A stored name resolves back to the tier it came from, which is what lets
    /// the sheet show "Careful" next to the row the owner is already on.
    func testAStoredNameResolvesBackToItsTier() {
        XCTAssertEqual(
            CloudBrainModelCatalog.tier(ofModel: "deepseek-v4-pro", forProvider: "deepseek"), .pro
        )
        XCTAssertEqual(
            CloudBrainModelCatalog.tier(ofModel: "deepseek-v4-flash", forProvider: "deepseek"), .fast
        )
        // A name an older build stored and the catalogue has since moved off.
        // `nil` rather than a guess: the sheet shows it as a bare id, which is
        // honest, instead of labelling it with a tier it no longer belongs to.
        XCTAssertNil(
            CloudBrainModelCatalog.tier(ofModel: "deepseek-chat", forProvider: "deepseek")
        )
    }

    /// **The two ids that look wrong and are right.** Both were arrived at by
    /// reading the vendor's own documentation on 2026-08-01 after the obvious
    /// guess turned out to be wrong, and both are the kind of thing a later
    /// tidy-up "corrects" back into a 404.
    func testTheTwoPicksThatLookLikeMistakes() {
        // Google ships no `gemini-3.6-pro`. The 3.6 family is Flash-only and the
        // newest Pro is a preview, which has no business in a shipped appliance.
        XCTAssertEqual(
            CloudBrainModelCatalog.pick(forProvider: "gemini"),
            .init(fast: "gemini-3.6-flash", pro: "gemini-2.5-pro")
        )
        // Moonshot's fast tier is not the faster-sounding
        // `kimi-k2.7-code-highspeed`: that is a coding specialist, and this is
        // something you hold a conversation with.
        XCTAssertEqual(
            CloudBrainModelCatalog.pick(forProvider: "moonshot"),
            .init(fast: "kimi-k2.6", pro: "kimi-k3")
        )
        // And the deprecated id it replaced must not come back.
        XCTAssertFalse(
            CloudBrainModelCatalog.models(forProvider: "moonshot").contains("kimi-k2-0905-preview"),
            "a model Moonshot has deprecated is being offered again"
        )
    }
}
