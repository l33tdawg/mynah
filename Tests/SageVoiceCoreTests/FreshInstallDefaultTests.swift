import XCTest
@testable import SageVoiceCore

/// **That a fresh install sets itself up privately, and says why when it can't.**
///
/// The product claimed privacy by default in its README, its planner recommended
/// the local option, and its install screen drew it first — while the flow itself
/// opened with a menu and selected nothing. The fastest path through that menu
/// was whatever cloud key happened to be exported in the owner's shell.
///
/// *"by default first install / fresh install pulls everything you need to get
/// setup locally with qwen as the local model — anything after, the user must
/// configure themselves."*
///
/// A default nobody is given is a preference. These tests are the difference.
final class FreshInstallDefaultTests: XCTestCase {

    private let planner = BrainSetupPlanner()

    // MARK: The default itself

    /// The plain case: a Mac that can run a brain gets one, without being asked.
    func testACapableMacDefaultsToTheLocalBrain() {
        let choices = planner.plan(for: .machine())
        let fallback = choices.freshInstallDefault

        XCTAssertNotNil(fallback, "a 16 GB Apple Silicon Mac was asked to choose")
        XCTAssertEqual(fallback?.option.id, .fullyLocal)
        XCTAssertTrue(
            fallback?.option.keepsWordsOnDevice == true,
            "the fresh-install default sends the owner's words somewhere"
        )
        XCTAssertNil(choices.freshInstallDefaultObstacle, "an obstacle with nothing obstructed")
    }

    /// **The model is qwen, named rather than inferred.** The owner asked for
    /// this one specifically, and "whatever the local catalogue happens to
    /// prefer" is how that becomes something else in six months without anyone
    /// deciding to change it.
    func testTheDefaultModelIsQwen() {
        let fallback = planner.plan(for: .machine()).freshInstallDefault
        XCTAssertEqual(fallback?.option.modelName, "qwen3.5:4b")
        XCTAssertEqual(LocalBrainModelCatalog.preferredModel, "qwen3.5:4b")
    }

    /// A Mac already serving the model still defaults to it, with nothing to
    /// fetch — the returning owner, and the settings-panel path.
    func testAMacAlreadyServingTheModelNeedsNoDownload() {
        let choices = planner.plan(
            for: .machine(localRuntime: .servingPreferredModel)
        )
        XCTAssertEqual(choices.freshInstallDefault?.option.id, .fullyLocal)
        XCTAssertEqual(choices.freshInstallDefault?.option.requirement, .nothing)
    }

    // MARK: When it cannot

    /// **Every refusal carries a reason.** This is the one that matters for the
    /// owner's standing instruction: a `nil` default means somebody is about to
    /// be asked to make a decision they were never going to have to make, and
    /// the screen doing the asking has to be able to say why.
    func testEveryMacThatCannotRunLocallySaysWhy() {
        let cases: [(String, EnvironmentProbeResult)] = [
            ("Intel", .machine(hardware: .intel32GB)),
            ("4 GB", .machine(hardware: .appleSilicon4GB)),
            ("no disk", .machine(hardware: .appleSilicon16GBLowDisk))
        ]

        for (name, probe) in cases {
            let choices = planner.plan(for: probe)
            XCTAssertNil(choices.freshInstallDefault, "\(name) was defaulted to a local brain")

            let obstacle = choices.freshInstallDefaultObstacle
            XCTAssertNotNil(obstacle, "\(name) is refused with no reason to show anyone")
            XCTAssertFalse(
                obstacle?.isEmpty ?? true,
                "\(name) is refused with an empty reason, which reads as a blank screen"
            )
            // A reason that does not mention the obstacle is a shrug with
            // punctuation. Each of these names the actual thing.
            XCTAssertGreaterThan(
                obstacle?.count ?? 0, 40,
                "\(name)'s reason is too short to be telling anyone anything: \(obstacle ?? "")"
            )
        }
    }

    /// The specific machines, so a reworded reason cannot quietly stop naming
    /// the obstacle it exists to name.
    func testTheReasonNamesTheActualObstacle() {
        let intel = planner.plan(for: .machine(hardware: .intel32GB)).freshInstallDefaultObstacle
        XCTAssertTrue(
            intel?.contains("Apple Silicon") == true,
            "an Intel owner is not told it is about the chip: \(intel ?? "")"
        )

        let disk = planner.plan(
            for: .machine(hardware: .appleSilicon16GBLowDisk)
        ).freshInstallDefaultObstacle
        XCTAssertTrue(
            disk?.lowercased().contains("space") == true || disk?.contains("GB") == true,
            "a full-disk owner is not told it is about disk: \(disk ?? "")"
        )
    }

    // MARK: The guard it is an exception to

    /// **The auto-selection may only ever be the local one.**
    ///
    /// `BrainSetupSelection`'s initialiser is internal so that nothing can bind
    /// the owner to a brain they did not choose. That guard exists to stop two
    /// specific harms — spending their money and sending their words away — and
    /// `.fullyLocal` can do neither, which is the entire argument for this
    /// exception. If `freshInstallDefault` ever returns anything else, the
    /// argument is gone and so is the guard.
    func testTheDefaultIsNeverAProviderEvenWhenOneIsCheaperToReach() {
        // A Mac with every ambient key exported and a local runtime ready. The
        // planner ranks the keys above local on friction; the default must
        // ignore that entirely.
        let keys = AmbientAPIKeyReport(providers: APIKeyProvider.allCases)
        let choices = planner.plan(for: .machine(ambientKeys: keys))

        XCTAssertEqual(
            choices.freshInstallDefault?.option.id, .fullyLocal,
            "an exported API key pulled the fresh-install default off the private brain"
        )
        XCTAssertTrue(choices.freshInstallDefault?.option.keepsWordsOnDevice == true)
    }

    /// And on a Mac that cannot run local, the answer is `nil` — never "well,
    /// this cloud one then". Falling back to a provider automatically is the
    /// exact harm the guard was built for: it would bill an owner who never
    /// agreed to be billed.
    func testAMacThatCannotRunLocallyIsDefaultedToNothingAtAll() {
        let choices = planner.plan(
            for: .machine(
                hardware: .intel32GB,
                ambientKeys: AmbientAPIKeyReport(providers: [.deepSeek])
            )
        )

        XCTAssertNil(
            choices.freshInstallDefault,
            "setup would have silently bound this owner to a metered provider"
        )
        // The menu is still there — this is a fallback, not a dead end.
        XCTAssertFalse(choices.availableOptions.isEmpty, "and now there is nothing to choose from")
    }

    // MARK: Nothing on the menu may dead-end

    /// **Every provider offered can actually be asked a question.**
    ///
    /// GLM shipped offerable and unusable: it has key instructions, so the
    /// planner listed it, and no entry in `CloudBrainModelCatalog`, so
    /// `BrainFactory.defaultModelName` fell through to its `?? "local-model"`
    /// and asked Zhipu for a model called `local-model`. Somebody could read the
    /// instructions, open the Zhipu console, put credit on a card, paste a
    /// working key, and be told no.
    ///
    /// This walks the menu the planner actually produces rather than a list
    /// written out here, so the next provider added with only half of what it
    /// needs fails without anyone remembering to update a test.
    func testNoOfferedProviderIsMissingAModelToAskFor() {
        let choices = BrainSetupPlanner().plan(
            for: .machine(ambientKeys: AmbientAPIKeyReport(providers: APIKeyProvider.allCases))
        )

        for option in choices.options where !option.keepsWordsOnDevice {
            guard let provider = option.keyProviderIdentifier else { continue }
            XCTAssertNotNil(
                CloudBrainModelCatalog.model(forProvider: provider),
                "\(option.label) is on the menu with no model behind it — picking it asks "
                    + "the provider for \"local-model\" and fails after the owner has paid"
            )
        }
    }

    /// The specific one, named, so it cannot come back by accident.
    func testGLMIsNotOfferedWhileItHasNoModelPick() {
        let choices = BrainSetupPlanner().plan(
            for: .machine(ambientKeys: AmbientAPIKeyReport(providers: [.glm]))
        )
        XCTAssertNil(
            choices.option(withID: .glmAPIKey),
            "GLM is offered again and still has no model this product knows to ask for"
        )
        // And the withdrawal is only of the *offer*. An owner who chose it in an
        // older build still has a decodable identity, exactly as with Google.
        XCTAssertNotNil(BrainSetupOptionID(rawValue: "key.glm"))
    }
}
