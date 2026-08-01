import XCTest
@testable import MynahMac
@testable import SageVoiceCore

/// **That changing where the words go changes the model with it.**
///
/// *"if the user tries to change from cloud to local; OBVIOUSLY the model must
/// be changed to the last used local model OR qwen by default — you can't
/// change one without the other; same when you go back the other way."*
@MainActor
final class BrainSwitchingTests: XCTestCase {

    private func scratchDefaults() -> UserDefaults {
        UserDefaults(suiteName: "brain-switching-\(UUID().uuidString)")!
    }

    private var localOption: BrainSetupOption {
        BrainSetupOption(
            id: .fullyLocal, label: "Fully on this Mac", summary: "",
            requirement: .nothing, keepsWordsOnDevice: true,
            availability: .available, tier: .fullyLocal,
            backendIdentifier: "ollama", modelName: "qwen3.5:4b"
        )
    }

    private func cloudOption(
        _ id: BrainSetupOptionID,
        backend: String
    ) -> BrainSetupOption {
        BrainSetupOption(
            id: id, label: backend, summary: "",
            requirement: .apiKey, keepsWordsOnDevice: false,
            availability: .available, tier: .typedAPIKey,
            backendIdentifier: backend
        )
    }

    // MARK: Cloud to local

    /// Qwen by default, even when it does not sort first — the owner named this
    /// one specifically, and "whatever sorts first" would land on gemma.
    func testMovingToLocalPicksQwenWhenThereIsNoHistory() {
        var choice = BrainProviderChoice(current: nil, installedLocalModels: [])
        choice.moved(
            to: .thisMac,
            localOption: localOption,
            cloudOptions: [],
            current: nil,
            installedLocalModels: ["gemma3:4b", "qwen3.5:4b", "llama3.2:3b"],
            defaults: scratchDefaults()
        )

        XCTAssertEqual(choice.localModel, "qwen3.5:4b", "the default local model is not qwen")
        XCTAssertNotNil(choice.resolved(), "moving to local produced nothing committable")
    }

    /// And the last one they actually used wins over the default.
    func testMovingToLocalPrefersTheLastLocalModelUsed() {
        let defaults = scratchDefaults()
        var used = localOption
        used.modelName = "llama3.2:3b"
        LastBrainModelStore.remember(used, defaults: defaults)

        var choice = BrainProviderChoice(current: nil, installedLocalModels: [])
        choice.moved(
            to: .thisMac, localOption: localOption, cloudOptions: [], current: nil,
            installedLocalModels: ["gemma3:4b", "qwen3.5:4b", "llama3.2:3b"],
            defaults: defaults
        )

        XCTAssertEqual(choice.localModel, "llama3.2:3b")
    }

    /// A remembered model that has since been deleted must not be preselected —
    /// that is a dot on a row that does not exist.
    func testAnUninstalledMemoryFallsBackToQwen() {
        let defaults = scratchDefaults()
        var used = localOption
        used.modelName = "a-model-since-deleted"
        LastBrainModelStore.remember(used, defaults: defaults)

        var choice = BrainProviderChoice(current: nil, installedLocalModels: [])
        choice.moved(
            to: .thisMac, localOption: localOption, cloudOptions: [], current: nil,
            installedLocalModels: ["qwen3.5:4b"], defaults: defaults
        )

        XCTAssertEqual(choice.localModel, "qwen3.5:4b")
    }

    // MARK: Local to cloud

    /// A provider whose key is already on the disk is one they can commit
    /// without typing anything, so that is where the cloud side lands.
    func testMovingToCloudLandsOnTheProviderWithASavedKey() {
        var choice = BrainProviderChoice(current: localOption, installedLocalModels: [])
        choice.moved(
            to: .cloud,
            localOption: localOption,
            cloudOptions: [
                cloudOption(.anthropicAPIKey, backend: "anthropic"),
                cloudOption(.deepSeekAPIKey, backend: "deepseek")
            ],
            current: localOption,
            hasSavedKey: { $0 == "deepseek" },
            defaults: scratchDefaults()
        )

        XCTAssertEqual(choice.selected?.id, .deepSeekAPIKey, "the saved key was ignored")
    }

    /// A key with no history gets the quick model, not nothing and not the
    /// expensive one: *"if its a new key, never selected model, we always select
    /// the fastest / cheapest option."*
    func testANewKeyGetsTheQuickModel() {
        var choice = BrainProviderChoice(current: localOption, installedLocalModels: [])
        choice.moved(
            to: .cloud, localOption: localOption,
            cloudOptions: [cloudOption(.deepSeekAPIKey, backend: "deepseek")],
            current: localOption,
            hasSavedKey: { _ in true },
            defaults: scratchDefaults()
        )

        XCTAssertEqual(choice.selected?.modelName, "deepseek-v4-flash")
        XCTAssertEqual(
            choice.selected?.modelName,
            CloudBrainModelCatalog.pick(forProvider: "deepseek")?.fast,
            "the cheapest tier is not what a fresh key lands on"
        )
    }

    /// And a provider they had already moved to Careful stays on Careful.
    func testAProviderRemembersTheTierTheOwnerChose() {
        let defaults = scratchDefaults()
        var used = cloudOption(.deepSeekAPIKey, backend: "deepseek")
        used.modelName = "deepseek-v4-pro"
        LastBrainModelStore.remember(used, defaults: defaults)

        var choice = BrainProviderChoice(current: localOption, installedLocalModels: [])
        choice.moved(
            to: .cloud, localOption: localOption,
            cloudOptions: [cloudOption(.deepSeekAPIKey, backend: "deepseek")],
            current: localOption,
            hasSavedKey: { _ in true },
            defaults: defaults
        )

        XCTAssertEqual(choice.selected?.modelName, "deepseek-v4-pro")
    }

    /// A model this build no longer offers is not carried forward — the vendor
    /// may have retired it, and a silent 404 is the failure the catalogue exists
    /// to make survivable.
    func testARetiredModelIsNotCarriedForward() {
        let defaults = scratchDefaults()
        var used = cloudOption(.deepSeekAPIKey, backend: "deepseek")
        used.modelName = "deepseek-chat"      // discontinued 2026-07-24
        LastBrainModelStore.remember(used, defaults: defaults)

        XCTAssertEqual(
            LastBrainModelStore.cloudModel(
                for: .deepSeekAPIKey, provider: "deepseek", defaults: defaults
            ),
            "deepseek-v4-flash",
            "a discontinued model was restored from history"
        )
    }

    /// Each brain keeps its own model. One entry for all of them is what made
    /// the way back forget: moving to local overwrote what DeepSeek was on.
    func testEachBrainRemembersItsOwnModel() {
        let defaults = scratchDefaults()
        var deepseek = cloudOption(.deepSeekAPIKey, backend: "deepseek")
        deepseek.modelName = "deepseek-v4-pro"
        LastBrainModelStore.remember(deepseek, defaults: defaults)

        var local = localOption
        local.modelName = "llama3.2:3b"
        LastBrainModelStore.remember(local, defaults: defaults)

        XCTAssertEqual(
            LastBrainModelStore.model(for: .deepSeekAPIKey, defaults: defaults),
            "deepseek-v4-pro",
            "switching to local forgot what the provider was on"
        )
        XCTAssertEqual(LastBrainModelStore.model(for: .fullyLocal, defaults: defaults), "llama3.2:3b")
    }
}
