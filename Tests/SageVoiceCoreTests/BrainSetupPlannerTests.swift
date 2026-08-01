import XCTest
@testable import SageVoiceCore

/// Tests for the decisions the install screen makes, not for the structs it
/// makes them out of.
///
/// Every case here is a synthetic `EnvironmentProbeResult`, so the ranking and
/// gating rules are exercised for machines nobody on this project owns — a 4 GB
/// Mac, an Intel Mac, a volume with 2 GB free — from whatever machine happens to
/// be running the suite.
final class BrainSetupPlannerTests: XCTestCase {

    private let planner = BrainSetupPlanner()

    // MARK: - Ranking

    /// **This test asserted the card, so it now asserts the card's absence.**
    ///
    /// It used to check that a signed-in Claude Code kept its tier, sorted
    /// first, and stayed unavailable with a reason attached — the theory being
    /// that a disabled row explains itself better than a missing one. The owner
    /// disproved it from the outside: he read grey as "not installed" and said
    /// so, *"we have codex and claude installed clearly; i'm using you right —
    /// yet it thinks we don't"*, because in a list of things you may choose,
    /// that is what grey means. The explanation was losing to the visual state
    /// no matter how it was worded, since the two rows were the only entries on
    /// that screen that were not offers.
    ///
    /// Withdrawn even when the owner is signed in and it is the "best" tier —
    /// entitlement was never the barrier. See `AgentCLINotOffered`.
    func testAgentCLIsAreNotOffered() {
        let probe = EnvironmentProbeResult.machine(
            claudeCode: .signedIn(.claudeCode),
            ambientKeys: AmbientAPIKeyReport(providers: [.anthropic], variableNames: ["ANTHROPIC_API_KEY"])
        )
        let choices = planner.plan(for: probe)

        XCTAssertNil(choices.option(withID: .claudeCodeCLI))
        XCTAssertNil(choices.option(withID: .codexCLI))
        XCTAssertEqual(choices.recommendation?.optionID, .fullyLocal)
    }

    /// The other half, and the one that protects an owner rather than a screen.
    ///
    /// Same guarantee `testGoogleKeepsItsIdentitySoAStoredChoiceStillDecodes`
    /// makes, for the same reason: a build shipped these as selectable, so
    /// `cli.claude-code` may be sitting in somebody's `BrainSelectionStore`. If
    /// the case were deleted their recorded choice would decode to `nil`, and an
    /// unreadable choice is indistinguishable from no choice — the app would
    /// walk them through setup again with a working brain already configured.
    func testAgentCLIsKeepTheirIdentitySoAStoredChoiceStillDecodes() {
        XCTAssertEqual(BrainSetupOptionID(rawValue: "cli.claude-code"), .claudeCodeCLI)
        XCTAssertEqual(BrainSetupOptionID(rawValue: "cli.codex"), .codexCLI)
    }

    /// **The explanation is gone, and this asserts it stays gone.**
    ///
    /// It was two greyed cards in the brain picker, which read as "not detected"
    /// for software the owner was visibly running. That was fixed by moving the
    /// sentence to Settings — which cured the misreading and kept the mistake
    /// underneath it. His verdict on the result: *"remove claude and codex if we
    /// can't use it bro - wtf is the point of this section and message?!"*
    ///
    /// A settings screen is for things you can change. Several paragraphs about
    /// two things that will never appear, shown only to the people most likely
    /// to be irritated by them, is not a feature — and the fix for an
    /// explanation nobody asked for is to stop explaining rather than to move it
    /// somewhere quieter.
    ///
    /// The probe still detects them, because `sage-voiced` reports what it finds
    /// on the machine and that is a diagnostic rather than a menu.
    func testTheAgentCLIsAreNeitherOfferedNorExplained() {
        let choices = planner.plan(for: .machine())

        for id in [BrainSetupOptionID.claudeCodeCLI, .codexCLI] {
            XCTAssertFalse(
                choices.availableOptions.contains { $0.id == id },
                "\(id) came back onto the menu"
            )
        }
    }

    /// **This test asserted the state that was withdrawn, so it now asserts the
    /// withdrawal.**
    ///
    /// It used to check that "Sign in with Google" was listed, unavailable, and
    /// carried the reason "isn't ready yet" — the theory being that a card
    /// explaining itself beats an option that silently is not there. That theory
    /// holds only while the thing is coming. It was not: consumer Google sign-in
    /// routes to Code Assist, a different wire format from the Gemini API, and
    /// nothing in this product speaks it. A permanent "isn't ready yet" on the
    /// first screen the owner reads is a promise nobody intends to keep, and the
    /// test was what kept it there.
    ///
    /// Both Google routes are gone. Not from the vocabulary — see the companion
    /// assertion below, which is the half that actually protects an owner.
    func testGoogleIsNotOfferedByEitherRoute() {
        let choices = planner.plan(for: .machine())

        XCTAssertNil(choices.option(withID: .googleSignIn))
        XCTAssertNil(choices.option(withID: .googleAPIKey))
    }

    /// An ambient key must not resurrect a withdrawn provider.
    ///
    /// Evidence orders the menu; it does not populate it. A `GEMINI_API_KEY`
    /// already exported on this Mac is exactly the case where the old
    /// "rises on evidence" rule would quietly put Google back on the screen.
    func testAnAmbientGoogleKeyDoesNotBringGoogleBack() {
        let probe = EnvironmentProbeResult.machine(
            ambientKeys: AmbientAPIKeyReport(
                providers: [.google],
                variableNames: ["GEMINI_API_KEY"]
            )
        )

        XCTAssertNil(planner.plan(for: probe).option(withID: .googleAPIKey))
    }

    /// The half of the withdrawal that protects an owner who already chose it.
    ///
    /// `key.google` is written to disk by shipped builds. Deleting the case
    /// would make that stored choice decode to `nil` on the next launch — and an
    /// unreadable choice is indistinguishable from no choice, so the appliance
    /// would ask a Gemini owner to set his brain up again while a working key sat
    /// in the file. Removing an offer is not removing an identity.
    func testAStoredGoogleChoiceStillResolvesAndStillHasABackend() throws {
        let stored = try XCTUnwrap(
            BrainSetupOptionID(rawValue: "key.google"),
            "An owner's stored choice must still decode after the offer is withdrawn"
        )

        XCTAssertEqual(stored, .googleAPIKey)
        XCTAssertNotNil(stored.backendPlan, "A withdrawn offer must still be buildable")
        XCTAssertNotNil(
            APIKeyOnboarding.instructions(forProvider: try XCTUnwrap(stored.keyProviderIdentifier)),
            "…and must still be able to explain its own key screen"
        )
    }

    /// An ambient key needs no input, so it outranks a key the owner has to go
    /// and fetch — but it still bills per token, which is why it is tier 2 rather
    /// than tier 0.
    func testAmbientAPIKeyIsZeroInputButPrivacyRemainsTheRecommendation() throws {
        let probe = EnvironmentProbeResult.machine(
            ambientKeys: AmbientAPIKeyReport(providers: [.openAI], variableNames: ["OPENAI_API_KEY"])
        )
        let choices = planner.plan(for: probe)

        let openAI = try XCTUnwrap(choices.option(withID: .openAIAPIKey))
        XCTAssertEqual(openAI.requirement, BrainSetupRequirement.nothing, "An ambient key needs nothing typed")
        XCTAssertEqual(openAI.tier, .ambientAPIKey)

        XCTAssertEqual(choices.recommendation?.optionID, .fullyLocal)
        XCTAssertLessThan(
            try XCTUnwrap(index(of: .openAIAPIKey, in: choices)),
            try XCTUnwrap(index(of: .anthropicAPIKey, in: choices))
        )
    }

    /// No CLI state puts one back on the menu.
    ///
    /// Three were reachable — installed-and-signed-in, installed-not-signed-in,
    /// and installed-with-an-ambient-key — and each produced a differently
    /// worded card. Sign-in was never the barrier, so none of them returns.
    func testNoCLIStateBringsTheOfferBack() {
        for state in [
            EnvironmentProbeResult.machine(claudeCode: .installedNotSignedIn(.claudeCode)),
            EnvironmentProbeResult.machine(claudeCode: .signedIn(.claudeCode)),
            EnvironmentProbeResult.machine(claudeCode: .installedNotSignedIn(.claudeCode),
                                           ambientKeys: AmbientAPIKeyReport(
                                               providers: [.anthropic],
                                               variableNames: ["ANTHROPIC_API_KEY"]
                                           )),
        ] {
            let choices = planner.plan(for: state)
            XCTAssertNil(choices.option(withID: .claudeCodeCLI))
            XCTAssertEqual(choices.recommendation?.optionID, .fullyLocal)
        }
    }

    /// Unavailable options are kept so the UI can explain them, but they must
    /// never be interleaved with things the owner can actually pick.
    func testUnavailableOptionsSortAfterEveryAvailableOne() {
        let choices = planner.plan(for: .machine(hardware: .intel32GB))

        var seenUnavailable = false
        for option in choices.options {
            if option.isAvailable {
                XCTAssertFalse(
                    seenUnavailable,
                    "\(option.id) is available but sorted after an unavailable option"
                )
            } else {
                seenUnavailable = true
            }
        }
        XCTAssertTrue(seenUnavailable, "This fixture should produce at least one unavailable option")
    }

    // MARK: - Fully local is always offered when the hardware allows

    /// Privacy is the product's first principle: the presence of a better-ranked
    /// option must never remove the private one from the list.
    func testFullyLocalIsStillOfferedWhenASignedInCLIExists() throws {
        let probe = EnvironmentProbeResult.machine(
            localRuntime: .servingPreferredModel,
            claudeCode: .signedIn(.claudeCode),
            codex: .signedIn(.codex),
            ambientKeys: AmbientAPIKeyReport(providers: APIKeyProvider.allCases, variableNames: [])
        )
        let choices = planner.plan(for: probe)

        let local = try XCTUnwrap(choices.option(withID: .fullyLocal))
        XCTAssertTrue(local.isAvailable, "Fully local must survive a machine where everything else works")
        XCTAssertTrue(choices.availableOptions.contains { $0.id == .fullyLocal })
    }

    func testOnlyFullyLocalKeepsWordsOnDevice() {
        let probe = EnvironmentProbeResult.machine(
            claudeCode: .signedIn(.claudeCode),
            ambientKeys: AmbientAPIKeyReport(providers: [.openAI], variableNames: ["OPENAI_API_KEY"])
        )
        let choices = planner.plan(for: probe)

        for option in choices.options {
            XCTAssertEqual(
                option.keepsWordsOnDevice,
                option.id == .fullyLocal,
                "\(option.id) reports the wrong answer for whether speech leaves the machine"
            )
        }
    }

    /// One identity across every install state, because the settings panel
    /// stores the owner's choice by id and "fully local" has to keep meaning the
    /// same thing after the model is pulled.
    func testFullyLocalKeepsOneIdentityAcrossInstallStates() {
        let states: [EnvironmentProbeResult] = [
            .machine(localRuntime: .servingPreferredModel),
            .machine(localRuntime: LocalModelRuntimeReport(isRuntimeInstalled: true)),
            .machine(hardware: .intel32GB)
        ]
        for probe in states {
            let local = planner.plan(for: probe).option(withID: .fullyLocal)
            XCTAssertNotNil(local, "Fully local must appear in the catalog in every install state")
        }
    }

    // MARK: - Hardware gating

    func testFullyLocalIsUnavailableOnIntelAndSaysWhy() throws {
        let choices = planner.plan(for: .machine(hardware: .intel32GB))
        let local = try XCTUnwrap(choices.option(withID: .fullyLocal))

        XCTAssertFalse(local.isAvailable)
        let reason = try XCTUnwrap(local.availability.reason)
        XCTAssertTrue(reason.contains("Apple Silicon"), "Reason should name the real constraint: \(reason)")
        XCTAssertTrue(reason.contains("Intel"), "Reason should say what this Mac is: \(reason)")
    }

    /// The reason has to carry both figures — "you need X, you have Y" is
    /// actionable, "not enough memory" is not.
    func testFullyLocalIsUnavailableBelowTheMemoryFloorAndStatesBothFigures() throws {
        let choices = planner.plan(for: .machine(hardware: .appleSilicon4GB))
        let local = try XCTUnwrap(choices.option(withID: .fullyLocal))

        XCTAssertFalse(local.isAvailable)
        let reason = try XCTUnwrap(local.availability.reason)
        XCTAssertTrue(reason.contains("8.6 GB"), "Reason should state the 8 GiB floor: \(reason)")
        XCTAssertTrue(reason.contains("4.3 GB"), "Reason should state what this Mac has: \(reason)")
    }

    /// 8–16 GiB works but swaps against the ASR model. The owner is allowed to
    /// choose that; they are not allowed to be surprised by it.
    func testTightMemoryStillOffersFullyLocalButWarns() throws {
        // The model is already pulled, because that is the only state in which
        // fully-local is offerable at all — see `testFullyLocalIsNotOfferedWhenItWouldNeedADownloadNothingPerforms`.
        let choices = planner.plan(
            for: .machine(hardware: .appleSilicon8GB, localRuntime: .servingPreferredModel)
        )
        let local = try XCTUnwrap(choices.option(withID: .fullyLocal))

        XCTAssertTrue(local.isAvailable, "8 GiB is above the floor, so it must still be offered")
        XCTAssertTrue(
            local.summary.lowercased().contains("slower"),
            "A tight machine must say so in the description: \(local.summary)"
        )
    }

    func testSixteenGigabytesIsTheComfortableThreshold() {
        XCTAssertEqual(HardwareReport.appleSilicon16GB.localModelCapability, .comfortable)
        XCTAssertEqual(HardwareReport.appleSilicon8GB.localModelCapability, .tight)
        XCTAssertEqual(HardwareReport.appleSilicon4GB.localModelCapability, .unsupported)
        XCTAssertEqual(HardwareReport.intel32GB.localModelCapability, .unsupported)
        XCTAssertTrue(HardwareReport.appleSilicon16GB.canComfortablyRunLocalFourBillionModel)
    }

    // MARK: - Disk gating

    func testFullyLocalIsUnavailableWhenTheVolumeIsTooSmallAndStatesBothFigures() throws {
        let choices = planner.plan(for: .machine(hardware: .appleSilicon16GBLowDisk))
        let local = try XCTUnwrap(choices.option(withID: .fullyLocal))

        XCTAssertFalse(local.isAvailable)
        let reason = try XCTUnwrap(local.availability.reason)
        XCTAssertTrue(reason.contains("2.1 GB"), "Reason should state the free space found: \(reason)")
        XCTAssertTrue(reason.contains("free"), "Reason should be about disk, not memory: \(reason)")
    }

    /// The disk gate exists to stop a download filling the boot volume. If the
    /// model is already there, there is no download and no reason to gate.
    func testDiskGateDoesNotApplyWhenTheModelIsAlreadyPulled() throws {
        let probe = EnvironmentProbeResult.machine(
            hardware: .appleSilicon16GBLowDisk,
            localRuntime: .servingPreferredModel
        )
        let local = try XCTUnwrap(planner.plan(for: probe).option(withID: .fullyLocal))

        XCTAssertTrue(local.isAvailable, "A pulled model needs no disk headroom")
        XCTAssertEqual(local.requirement, BrainSetupRequirement.nothing)
        XCTAssertNil(local.approximateDownloadBytes, "Nothing to download, so no size to quote")
        XCTAssertEqual(local.modelName, LocalBrainModelCatalog.preferredModel)
    }

    /// Unknown free space means the measurement failed, not that the disk is
    /// full. Blaming a measurement we never took would send the owner to free up
    /// space they already have.
    func testUnknownFreeSpaceIsNeverBlamedOnTheDisk() throws {
        var hardware = HardwareReport.appleSilicon16GB
        hardware.freeDiskBytes = nil
        let local = try XCTUnwrap(planner.plan(for: .machine(hardware: hardware)).option(withID: .fullyLocal))

        XCTAssertTrue(local.isAvailable, "A failed disk measurement is not evidence of a full disk")
        XCTAssertEqual(local.requirement, .download)
    }

    /// With unknown free space *and* the model already pulled there is nothing
    /// left to gate on, so it is offered.
    func testUnknownFreeSpaceDoesNotHideAnAlreadyPulledModel() throws {
        var hardware = HardwareReport.appleSilicon16GB
        hardware.freeDiskBytes = nil
        let probe = EnvironmentProbeResult.machine(hardware: hardware, localRuntime: .servingPreferredModel)

        XCTAssertTrue(try XCTUnwrap(planner.plan(for: probe).option(withID: .fullyLocal)).isAvailable)
    }

    // MARK: - Download sizing

    func testDownloadSizeIsJustTheModelWhenOllamaIsAlreadyInstalled() throws {
        let probe = EnvironmentProbeResult.machine(
            localRuntime: LocalModelRuntimeReport(isRuntimeInstalled: true)
        )
        let local = try XCTUnwrap(planner.plan(for: probe).option(withID: .fullyLocal))

        XCTAssertEqual(local.requirement, .download)
        XCTAssertEqual(
            local.approximateDownloadBytes,
            LocalBrainModelCatalog.approximateModelDownloadBytes
                + LocalBrainModelCatalog.approximateEmbeddingModelDownloadBytes
        )
    }

    /// Quoting 3.4 GB and then also installing a runtime is the kind of surprise
    /// that makes an appliance feel dishonest.
    func testDownloadSizeIncludesTheRuntimeWhenOllamaIsAbsent() throws {
        let local = try XCTUnwrap(planner.plan(for: .machine()).option(withID: .fullyLocal))

        XCTAssertEqual(local.requirement, .download)
        XCTAssertEqual(
            local.approximateDownloadBytes,
            LocalBrainModelCatalog.approximateModelDownloadBytes
                + LocalBrainModelCatalog.approximateEmbeddingModelDownloadBytes
                + LocalBrainModelCatalog.approximateRuntimeDownloadBytes
        )
        XCTAssertTrue(local.summary.contains("Ollama"), "The extra install must be stated: \(local.summary)")
    }

    func testOnlyDownloadOptionsQuoteASize() {
        let choices = planner.plan(for: .machine())
        for option in choices.options where option.isAvailable {
            if option.requirement == .download {
                XCTAssertNotNil(option.approximateDownloadBytes, "\(option.id) requires a download but quotes no size")
            } else {
                XCTAssertNil(option.approximateDownloadBytes, "\(option.id) quotes a download size it does not need")
            }
        }
    }

    // MARK: - Catalog membership

    /// **This asserted the opposite until the owner noticed.**
    ///
    /// The rule was that niche providers appeared only if their key was already
    /// exported, on the reasoning that a menu of unknown vendors is worse than a
    /// short list. That reasoning was sound and the rule it produced was
    /// self-fulfilling: you cannot choose a provider you are never shown, so
    /// nobody without a key could ever acquire one — and the three shown were
    /// Anthropic, OpenAI and Google.
    ///
    /// His words: *"there is no deepseek, kimi, glm — a bit biased towards US
    /// aren't we"*. The test was pinning the bias in place, which is why it had
    /// to be rewritten rather than deleted.
    ///
    /// What survives is the useful half: evidence still counts, for **ordering**
    /// rather than existence. A provider whose key is already exported needs
    /// nothing pasted, so it ranks ahead on friction.
    ///
    /// **GLM has since left this list, and not for the reason that started it.**
    /// The bias was hiding providers that *worked*, on an assumption about who
    /// the owner is. GLM does not work: it has no grounded model id on the
    /// endpoint this app calls, so picking it asked Zhipu for a model named
    /// `local-model` — after the owner had opened the console and put credit on
    /// a card. Withholding a broken option is not the same act as withholding a
    /// working one, and the fix is to ground the id rather than to keep offering
    /// the wall. See `docs/MODEL-CHOICES.md`, which says what is missing.
    func testEveryProviderWeCanActuallyServeIsOfferableAndEvidenceOnlyChangesTheFriction() {
        let bare = planner.plan(for: .machine())
        for id in [BrainSetupOptionID.moonshotAPIKey, .groqAPIKey, .deepSeekAPIKey] {
            XCTAssertNotNil(
                bare.option(withID: id),
                "\(id) is unreachable for anyone who has not already exported its key"
            )
            XCTAssertEqual(bare.option(withID: id)?.requirement, BrainSetupRequirement.apiKey)
        }

        let withKey = planner.plan(for: .machine(
            ambientKeys: AmbientAPIKeyReport(providers: [.moonshot], variableNames: ["MOONSHOT_API_KEY"])
        ))
        XCTAssertEqual(
            withKey.option(withID: .moonshotAPIKey)?.requirement,
            BrainSetupRequirement.nothing,
            "an already-exported key should cost nothing to pick"
        )
        XCTAssertNotNil(withKey.option(withID: .groqAPIKey), "the others must not vanish because one has evidence")
    }

    /// The mainstream providers stay in the catalog even with no evidence,
    /// because an owner who holds a key needs somewhere to put it.
    ///
    /// Google was the third of these and is deliberately no longer in the list —
    /// see `testGoogleIsNotOfferedByEitherRoute`.
    func testMainstreamProvidersAreAlwaysOffered() {
        let choices = planner.plan(for: .machine())
        for id in [BrainSetupOptionID.anthropicAPIKey, .openAIAPIKey] {
            let option = choices.option(withID: id)
            XCTAssertNotNil(option, "\(id) must always be offerable")
            XCTAssertEqual(option?.requirement, .apiKey)
            XCTAssertTrue(option?.isAvailable ?? false)
        }
    }

    /// The install screen is the first thing the owner ever reads; "a Anthropic
    /// API key" is the sort of thing that makes an appliance feel unfinished.
    func testProviderDescriptionsUseTheRightArticle() throws {
        let choices = planner.plan(for: .machine())

        XCTAssertTrue(
            try XCTUnwrap(choices.option(withID: .anthropicAPIKey)).summary.contains("an Anthropic"),
            "Expected \"an Anthropic\""
        )
        XCTAssertTrue(
            try XCTUnwrap(choices.option(withID: .openAIAPIKey)).summary.contains("an OpenAI"),
            "Expected \"an OpenAI\""
        )
        XCTAssertTrue(
            try XCTUnwrap(choices.option(withID: .deepSeekAPIKey)).summary.contains("a DeepSeek"),
            "Expected \"a DeepSeek\""
        )
    }

    /// A Mac with neither CLI is told nothing about either.
    ///
    /// The withdrawn card had a fourth wording for this case — "Codex isn't
    /// installed on this Mac" — which was a true sentence about software the
    /// owner had never asked about, on the first screen they ever saw.
    func testAMacWithoutTheCLIsIsToldNothingAboutThem() {
        let choices = planner.plan(for: .machine())

        XCTAssertNil(choices.option(withID: .codexCLI))
        XCTAssertNil(choices.option(withID: .claudeCodeCLI))
    }

    // MARK: - Purity and re-runnability

    /// This same code is the "migrate me to fully local" mechanism in settings,
    /// so it has to be safe to run over and over.
    func testPlanningTheSameProbeTwiceGivesAnIdenticalResult() {
        let probe = EnvironmentProbeResult.machine(
            hardware: .appleSilicon8GB,
            localRuntime: .servingPreferredModel,
            claudeCode: .installedNotSignedIn(.claudeCode),
            ambientKeys: AmbientAPIKeyReport(providers: [.groq], variableNames: ["GROQ_API_KEY"])
        )
        XCTAssertEqual(planner.plan(for: probe), BrainSetupPlanner().plan(for: probe))
    }

    func testEveryPlausibleMachineStillYieldsARecommendation() throws {
        let machines: [EnvironmentProbeResult] = [
            .nothingDetected,
            .machine(),
            .machine(hardware: .intel32GB),
            .machine(hardware: .appleSilicon4GB),
            .machine(hardware: .appleSilicon16GBLowDisk),
            .machine(localRuntime: .servingPreferredModel),
            .machine(claudeCode: .signedIn(.claudeCode), codex: .signedIn(.codex))
        ]
        for probe in machines {
            let choices = planner.plan(for: probe)
            let recommendation = try XCTUnwrap(
                choices.recommendation,
                "An install screen must always have something to suggest"
            )
            XCTAssertFalse(choices.availableOptions.isEmpty)
            XCTAssertFalse(
                recommendation.rationale.isEmpty,
                "A recommendation without a reason is just an auto-selection"
            )
        }
    }

    /// Even a probe where every single detection failed must produce a usable
    /// screen rather than an empty one.
    func testAllDetectionFailedStillProducesOfferableOptions() throws {
        let choices = planner.plan(for: .nothingDetected)

        XCTAssertEqual(choices.recommendation?.optionID, .anthropicAPIKey)
        // `nothingDetected` has zero-byte RAM and no Apple Silicon flag, so the
        // local path is correctly withheld — with a reason.
        let local = try XCTUnwrap(choices.option(withID: .fullyLocal))
        XCTAssertFalse(local.isAvailable)
        XCTAssertNotNil(local.availability.reason)
    }

    // MARK: - Never auto-selects

    /// A recommendation is not a selection, and the only route to one is an
    /// explicit id. This is the behavioural half of that guarantee; the
    /// structural half is `BrainSetupSelection`'s internal initialiser.
    func testRecommendationHasToBePassedBackThroughSelectToBecomeAChoice() throws {
        let probe = EnvironmentProbeResult.machine(claudeCode: .signedIn(.claudeCode))
        let choices = planner.plan(for: probe)
        let recommendation = try XCTUnwrap(choices.recommendation)

        // There is no API that turns `recommendation` into a selection; the
        // caller must name the id, which is what makes the choice the owner's.
        let selection = try XCTUnwrap(choices.select(recommendation.optionID))
        XCTAssertEqual(selection.option.id, recommendation.optionID)
        XCTAssertTrue(selection.option.isAvailable)
    }

    func testSelectRefusesAnUnavailableOption() throws {
        let choices = planner.plan(for: .machine(hardware: .intel32GB))

        XCTAssertFalse(try XCTUnwrap(choices.option(withID: .fullyLocal)).isAvailable)
        XCTAssertNil(
            choices.select(.fullyLocal),
            "Selecting an option this machine cannot run must fail, not bind the daemon to it"
        )
    }

    /// **This test asserted a state that no longer exists, so it now asserts the
    /// guarantee that replaced it.**
    ///
    /// It used Groq as an example of an option absent from the catalogue. Every
    /// option is offerable now — the whole point of removing the always-offered
    /// allowlist — so there is no longer any id the planner omits, and a test
    /// looking for one could only be satisfied by re-hiding something.
    ///
    /// Refusing a *selection* is still guarded and still tested: see
    /// `testSelectRefusesAnOptionThisMachineCannotRun`, which is the real rule —
    /// availability, not membership. What is worth pinning here instead is that
    /// every id survives planning, because the failure this replaces was an
    /// owner never being shown a choice he had decided to make.
    ///
    /// **Amended for the Google withdrawal.** The rule is no longer "every id
    /// appears" but "every id appears unless it was deliberately withdrawn", and
    /// the withdrawn set is spelled out here rather than derived. That is the
    /// point: a future option that goes missing by accident still fails this
    /// test, because accidental omission cannot add itself to the list below.
    ///
    /// **Amended again for the two agent CLIs**, withdrawn for a different
    /// reason than Google's — not "we will not serve this" but "a row in a
    /// picker claims choosability, and these never will be". They carried an
    /// explanation for a while, in the picker and then in Settings; it is gone
    /// now, and they are simply absent.
    /// **Amended a third time for GLM, which is a different case again** and is
    /// listed separately so it does not quietly become permanent. Google and the
    /// CLIs are decisions — we will not serve those. GLM is an *unfinished job*:
    /// it is absent only because no GLM model id has been grounded against
    /// `open.bigmodel.cn/api/paas/v4`, so offering it asked Zhipu for a model
    /// called `local-model` and refused the owner after they had paid. One
    /// verified id brings it back, and `docs/MODEL-CHOICES.md` says exactly which.
    func testEveryOptionIsOfferableSoNoChoiceIsHiddenFromTheOwner() {
        let withdrawn: Set<BrainSetupOptionID> = [
            .googleSignIn, .googleAPIKey, .claudeCodeCLI, .codexCLI,
        ]
        let awaitingAGroundedModelID: Set<BrainSetupOptionID> = [.glmAPIKey]
        let choices = planner.plan(for: .machine())

        for id in BrainSetupOptionID.allCases
        where !withdrawn.contains(id) && !awaitingAGroundedModelID.contains(id) {
            XCTAssertNotNil(
                choices.option(withID: id),
                "\(id) is missing from the catalogue — an owner cannot pick what he is never shown"
            )
        }
    }

    func testSelectReturnsExactlyTheNamedOption() throws {
        let choices = planner.plan(for: .machine())
        let selection = try XCTUnwrap(choices.select(.openAIAPIKey))

        XCTAssertEqual(selection.option.id, .openAIAPIKey)
        XCTAssertNotEqual(
            selection.option.id,
            choices.recommendation?.optionID,
            "Selecting something other than the recommendation must be honoured"
        )
    }

    // MARK: - Offered means buildable

    /// Every machine worth planning for, so the guards below are exercised
    /// against the full range rather than the developer's own Mac.
    private static let plausibleMachines: [EnvironmentProbeResult] = [
        .nothingDetected,
        .machine(),
        .machine(hardware: .intel32GB),
        .machine(hardware: .appleSilicon4GB),
        .machine(hardware: .appleSilicon8GB),
        .machine(hardware: .appleSilicon16GBLowDisk),
        .machine(localRuntime: .servingPreferredModel),
        .machine(localRuntime: LocalModelRuntimeReport(isRuntimeInstalled: true)),
        .machine(claudeCode: .signedIn(.claudeCode), codex: .signedIn(.codex)),
        .machine(claudeCode: .installedNotSignedIn(.claudeCode)),
        .machine(ambientKeys: AmbientAPIKeyReport(
            providers: APIKeyProvider.allCases,
            variableNames: APIKeyProvider.allCases.flatMap(\.environmentVariableNames)
        ))
    ]

    /// The guard that would have caught the whole class of bug this suite grew
    /// around: the planner offering something no backend can serve.
    ///
    /// Four of seven cards on the brain screen threw on the owner's first
    /// question because the planner's `backendIdentifier` strings and the app's
    /// factory switch were two independent lists that drifted. `backendPlan` is
    /// now the single mapping, and offering an option without one is a test
    /// failure rather than a dead end thirty seconds into the product.
    func testEveryOfferedOptionCanActuallyBeBuilt() {
        for probe in Self.plausibleMachines {
            for option in planner.plan(for: probe).availableOptions {
                XCTAssertNotNil(
                    option.id.backendPlan,
                    "\(option.id) is offered but nothing in the product can serve it"
                )
            }
        }
    }

    /// An option that needs a key we cannot explain how to get must not be
    /// offerable. "Google Gemini API key" was, and setup resolved the
    /// contradiction by skipping the key screen and declaring success.
    func testEveryOfferedKeyOptionHasInstructionsAndAProvider() throws {
        for probe in Self.plausibleMachines {
            for option in planner.plan(for: probe).availableOptions
            where option.requirement == .apiKey {
                let provider = try XCTUnwrap(
                    option.keyProviderIdentifier,
                    "\(option.id) needs a key but names no provider to file it under"
                )
                XCTAssertNotNil(
                    APIKeyOnboarding.instructions(forProvider: provider),
                    "\(option.id) needs a key but there is nothing to tell the owner"
                )
            }
        }
    }

    /// Setup owns key entry and the local provisioner. No other unsatisfied
    /// requirement may be offered.
    func testNoOfferedOptionAsksForSomethingSetupCannotDeliver() {
        for probe in Self.plausibleMachines {
            for option in planner.plan(for: probe).availableOptions {
                XCTAssertTrue(
                    option.requirement == .nothing
                        || option.requirement == .apiKey
                        || (option.id == .fullyLocal && option.requirement == .download),
                    "\(option.id) is offered with requirement \(option.requirement), "
                        + "which no stage in setup can satisfy"
                )
            }
        }
    }

    /// Missing runtime and model states are all handled by the idempotent local
    /// provisioner, so the card remains actionable throughout recovery.
    func testFullyLocalIsOfferedWhenItNeedsAutomatedProvisioning() throws {
        let states: [LocalModelRuntimeReport] = [
            LocalModelRuntimeReport(),
            LocalModelRuntimeReport(isRuntimeInstalled: true),
            LocalModelRuntimeReport(isRuntimeInstalled: true, isDaemonReachable: true)
        ]
        for runtime in states {
            let local = try XCTUnwrap(
                planner.plan(for: .machine(localRuntime: runtime)).option(withID: .fullyLocal)
            )
            XCTAssertTrue(local.isAvailable, "The provisioner can finish this state")
            XCTAssertEqual(local.requirement, .download)
            XCTAssertNotNil(local.approximateDownloadBytes)
            XCTAssertNil(local.availability.reason)
        }
    }

    /// And the moment the model really is there, it is the option the product
    /// exists for.
    func testFullyLocalIsOfferedTheMomentTheModelIsServing() throws {
        let local = try XCTUnwrap(
            planner.plan(for: .machine(localRuntime: .servingPreferredModel)).option(withID: .fullyLocal)
        )
        XCTAssertTrue(local.isAvailable)
        XCTAssertEqual(local.requirement, BrainSetupRequirement.nothing)
        XCTAssertEqual(local.id.backendPlan, .localOllama)
    }

    /// Three vendors used to share the string `"openai-compatible"`, which meant
    /// three keys collapsing into one slot on disk and none of them resolving to
    /// instructions. Each provider now names itself.
    func testEveryKeyProviderMapsToItsOwnAdapterIdentifier() {
        let expected: [BrainSetupOptionID: String] = [
            .anthropicAPIKey: "anthropic",
            .openAIAPIKey: "openai",
            .googleAPIKey: "gemini",
            .deepSeekAPIKey: "deepseek",
            .moonshotAPIKey: "moonshot",
            .groqAPIKey: "groq"
        ]
        for (id, provider) in expected {
            XCTAssertEqual(id.keyProviderIdentifier, provider)
            XCTAssertNotNil(APIKeyOnboarding.instructions(forProvider: provider))
        }
        XCTAssertEqual(Set(expected.values).count, expected.count, "Two options must never share a key slot")
        for id in [BrainSetupOptionID.fullyLocal, .claudeCodeCLI, .codexCLI, .googleSignIn] {
            XCTAssertNil(id.keyProviderIdentifier, "\(id) must not ask for a pasted key")
        }
    }

    // MARK: - Helpers

    private func index(of id: BrainSetupOptionID, in choices: BrainSetupChoices) -> Int? {
        choices.options.firstIndex { $0.id == id }
    }
}

// MARK: - Synthetic machines

extension HardwareReport {
    /// The reference appliance: a 16 GB M2 mini with room to spare.
    static var appleSilicon16GB: HardwareReport {
        HardwareReport(
            physicalMemoryBytes: 16 * 1024 * 1024 * 1024,
            freeDiskBytes: 400_000_000_000,
            modelStorageDirectory: "/Users/test/.ollama/models",
            cpuBrand: "Apple M2",
            physicalCoreCount: 8,
            isAppleSilicon: true
        )
    }

    /// Above the floor, below comfortable.
    static var appleSilicon8GB: HardwareReport {
        var report = appleSilicon16GB
        report.physicalMemoryBytes = 8 * 1024 * 1024 * 1024
        return report
    }

    /// Below the floor.
    static var appleSilicon4GB: HardwareReport {
        var report = appleSilicon16GB
        report.physicalMemoryBytes = 4 * 1024 * 1024 * 1024
        return report
    }

    /// Plenty of memory, wrong architecture for conversational latency.
    static var intel32GB: HardwareReport {
        HardwareReport(
            physicalMemoryBytes: 32 * 1024 * 1024 * 1024,
            freeDiskBytes: 400_000_000_000,
            modelStorageDirectory: "/Users/test/.ollama/models",
            cpuBrand: "Intel(R) Core(TM) i9-9880H CPU @ 2.30GHz",
            physicalCoreCount: 8,
            isAppleSilicon: false
        )
    }

    /// Comfortable memory, no room for a 3.4 GB pull.
    static var appleSilicon16GBLowDisk: HardwareReport {
        var report = appleSilicon16GB
        report.freeDiskBytes = 2_100_000_000
        return report
    }
}

extension LocalModelRuntimeReport {
    /// Daemon up, measured-good model already pulled.
    static var servingPreferredModel: LocalModelRuntimeReport {
        LocalModelRuntimeReport(
            isRuntimeInstalled: true,
            runtimeExecutablePath: "/usr/local/bin/ollama",
            isDaemonReachable: true,
            installedModels: ["qwen3.5:4b", "nomic-embed-text"]
        )
    }
}

extension AgentCLIReport {
    static func signedIn(_ kind: AgentCLIKind) -> AgentCLIReport {
        AgentCLIReport(
            kind: kind,
            isInstalled: true,
            executablePath: "/usr/local/bin/\(kind.executableNames[0])",
            version: "1.0.0",
            credentialEvidence: ["/Users/test/credential-store"],
            hasSubscriptionCredential: true
        )
    }

    static func installedNotSignedIn(_ kind: AgentCLIKind) -> AgentCLIReport {
        AgentCLIReport(
            kind: kind,
            isInstalled: true,
            executablePath: "/usr/local/bin/\(kind.executableNames[0])",
            version: "1.0.0"
        )
    }
}

extension EnvironmentProbeResult {
    /// Default machine: the reference hardware with nothing else installed.
    static func machine(
        hardware: HardwareReport = .appleSilicon16GB,
        localRuntime: LocalModelRuntimeReport = LocalModelRuntimeReport(),
        claudeCode: AgentCLIReport = AgentCLIReport(kind: .claudeCode),
        codex: AgentCLIReport = AgentCLIReport(kind: .codex),
        ambientKeys: AmbientAPIKeyReport = AmbientAPIKeyReport(),
        sage: SageInstallReport = SageInstallReport()
    ) -> EnvironmentProbeResult {
        EnvironmentProbeResult(
            localRuntime: localRuntime,
            agentCLIs: [claudeCode, codex],
            ambientAPIKeys: ambientKeys,
            hardware: hardware,
            sage: sage
        )
    }
}
