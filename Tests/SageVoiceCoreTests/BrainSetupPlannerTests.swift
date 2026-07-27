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

    /// Tier 0. The owner already pays for this and has already signed in, so
    /// nothing else can beat it.
    func testSignedInAgentCLIOutranksEverythingElse() {
        let probe = EnvironmentProbeResult.machine(
            claudeCode: .signedIn(.claudeCode),
            ambientKeys: AmbientAPIKeyReport(providers: [.anthropic], variableNames: ["ANTHROPIC_API_KEY"])
        )
        let choices = planner.plan(for: probe)

        XCTAssertEqual(choices.recommendation?.optionID, .claudeCodeCLI)
        XCTAssertEqual(choices.options.first?.id, .claudeCodeCLI)
        XCTAssertEqual(choices.option(withID: .claudeCodeCLI)?.requirement, BrainSetupRequirement.nothing)
        XCTAssertEqual(choices.option(withID: .claudeCodeCLI)?.tier, .signedInSubscription)
    }

    /// The majority case the product is aimed at: no CLI, no key, just a person
    /// with a Google account.
    func testGoogleSignInIsRecommendedOnAnOtherwiseBareMachine() {
        let choices = planner.plan(for: .machine())

        XCTAssertEqual(choices.recommendation?.optionID, .googleSignIn)
        XCTAssertEqual(choices.option(withID: .googleSignIn)?.requirement, .signIn)
    }

    /// An ambient key needs no input either, but it bills per token. Ranking it
    /// above a flat-rate subscription or a free tier would be a quiet way to
    /// spend the owner's money, so it sits at tier 2 on purpose.
    func testAmbientAPIKeyIsZeroInputButStillRanksBelowGoogleSignIn() {
        let probe = EnvironmentProbeResult.machine(
            ambientKeys: AmbientAPIKeyReport(providers: [.anthropic], variableNames: ["ANTHROPIC_API_KEY"])
        )
        let choices = planner.plan(for: probe)

        let anthropic = choices.option(withID: .anthropicAPIKey)
        XCTAssertEqual(anthropic?.requirement, BrainSetupRequirement.nothing, "An ambient key needs nothing typed")
        XCTAssertEqual(anthropic?.tier, .ambientAPIKey)

        XCTAssertEqual(choices.recommendation?.optionID, .googleSignIn)
        XCTAssertLessThan(
            try XCTUnwrap(index(of: .googleSignIn, in: choices)),
            try XCTUnwrap(index(of: .anthropicAPIKey, in: choices))
        )
    }

    /// A binary on disk proves nothing about entitlement — the owner may have
    /// installed it and never subscribed. So it is offered, but below the paths
    /// we have actual evidence for.
    func testInstalledButUnauthenticatedCLIRanksBelowATypedAPIKey() throws {
        let probe = EnvironmentProbeResult.machine(claudeCode: .installedNotSignedIn(.claudeCode))
        let choices = planner.plan(for: probe)

        let claude = try XCTUnwrap(choices.option(withID: .claudeCodeCLI))
        XCTAssertTrue(claude.isAvailable)
        XCTAssertEqual(claude.requirement, .signIn)
        XCTAssertEqual(claude.tier, .installedCLINeedingSignIn)

        XCTAssertGreaterThan(
            try XCTUnwrap(index(of: .claudeCodeCLI, in: choices)),
            try XCTUnwrap(index(of: .anthropicAPIKey, in: choices))
        )
        XCTAssertEqual(choices.recommendation?.optionID, .googleSignIn)
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
        let choices = planner.plan(for: .machine(hardware: .appleSilicon8GB))
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
    /// full. Refusing on a measurement we never took would hide a working option.
    func testUnknownFreeSpaceDoesNotHideFullyLocal() throws {
        var hardware = HardwareReport.appleSilicon16GB
        hardware.freeDiskBytes = nil
        let local = try XCTUnwrap(planner.plan(for: .machine(hardware: hardware)).option(withID: .fullyLocal))

        XCTAssertTrue(local.isAvailable)
    }

    // MARK: - Download sizing

    func testDownloadSizeIsJustTheModelWhenOllamaIsAlreadyInstalled() throws {
        let probe = EnvironmentProbeResult.machine(
            localRuntime: LocalModelRuntimeReport(isRuntimeInstalled: true)
        )
        let local = try XCTUnwrap(planner.plan(for: probe).option(withID: .fullyLocal))

        XCTAssertEqual(local.requirement, .download)
        XCTAssertEqual(local.approximateDownloadBytes, LocalBrainModelCatalog.approximateModelDownloadBytes)
    }

    /// Quoting 3.4 GB and then also installing a runtime is the kind of surprise
    /// that makes an appliance feel dishonest.
    func testDownloadSizeIncludesTheRuntimeWhenOllamaIsAbsent() throws {
        let local = try XCTUnwrap(planner.plan(for: .machine()).option(withID: .fullyLocal))

        XCTAssertEqual(local.requirement, .download)
        XCTAssertEqual(
            local.approximateDownloadBytes,
            LocalBrainModelCatalog.approximateModelDownloadBytes
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

    /// The product intent is to show what this machine actually has, not a menu
    /// of vendors the owner has never heard of.
    func testNicheProvidersAppearOnlyWhenTheirKeyIsAlreadySet() {
        let bare = planner.plan(for: .machine())
        XCTAssertNil(bare.option(withID: .moonshotAPIKey))
        XCTAssertNil(bare.option(withID: .groqAPIKey))
        XCTAssertNil(bare.option(withID: .deepSeekAPIKey))

        let withKey = planner.plan(for: .machine(
            ambientKeys: AmbientAPIKeyReport(providers: [.moonshot], variableNames: ["MOONSHOT_API_KEY"])
        ))
        XCTAssertNotNil(withKey.option(withID: .moonshotAPIKey))
        XCTAssertEqual(withKey.option(withID: .moonshotAPIKey)?.requirement, BrainSetupRequirement.nothing)
        XCTAssertNil(withKey.option(withID: .groqAPIKey), "Only the provider with evidence should appear")
    }

    /// The three mainstream providers stay in the catalog even with no evidence,
    /// because an owner who holds a key needs somewhere to put it.
    func testMainstreamProvidersAreAlwaysOffered() {
        let choices = planner.plan(for: .machine())
        for id in [BrainSetupOptionID.anthropicAPIKey, .openAIAPIKey, .googleAPIKey] {
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
            try XCTUnwrap(choices.option(withID: .googleAPIKey)).summary.contains("a Google"),
            "Expected \"a Google\""
        )
    }

    /// A CLI that is not installed is explained, not hidden.
    func testMissingCLIIsListedWithAReason() throws {
        let choices = planner.plan(for: .machine())
        let codex = try XCTUnwrap(choices.option(withID: .codexCLI))

        XCTAssertFalse(codex.isAvailable)
        XCTAssertTrue(try XCTUnwrap(codex.availability.reason).contains("isn't installed"))
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

        XCTAssertEqual(choices.recommendation?.optionID, .googleSignIn)
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
        XCTAssertEqual(selection.option.id, .claudeCodeCLI)
    }

    func testSelectRefusesAnUnavailableOption() throws {
        let choices = planner.plan(for: .machine(hardware: .intel32GB))

        XCTAssertFalse(try XCTUnwrap(choices.option(withID: .fullyLocal)).isAvailable)
        XCTAssertNil(
            choices.select(.fullyLocal),
            "Selecting an option this machine cannot run must fail, not bind the daemon to it"
        )
    }

    func testSelectRefusesAnOptionThatIsNotInTheCatalog() {
        let choices = planner.plan(for: .machine())

        XCTAssertNil(choices.option(withID: .groqAPIKey))
        XCTAssertNil(choices.select(.groqAPIKey))
    }

    func testSelectReturnsExactlyTheNamedOption() throws {
        let choices = planner.plan(for: .machine())
        let selection = try XCTUnwrap(choices.select(.anthropicAPIKey))

        XCTAssertEqual(selection.option.id, .anthropicAPIKey)
        XCTAssertNotEqual(
            selection.option.id,
            choices.recommendation?.optionID,
            "Selecting something other than the recommendation must be honoured"
        )
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
            installedModels: ["qwen3.5:4b", "embeddinggemma:300m"]
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
