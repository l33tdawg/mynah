import XCTest
@testable import MynahMac
@testable import SageVoiceCore

@MainActor
final class SetupModelTests: XCTestCase {
    func testDeferringAnUnverifiedKeyMovesToPhone() {
        let option = BrainSetupOption(
            id: .anthropicAPIKey,
            label: "Anthropic API key",
            summary: "Test",
            requirement: .apiKey,
            keepsWordsOnDevice: false,
            availability: .available,
            tier: .typedAPIKey,
            backendIdentifier: "anthropic",
            modelName: "claude-sonnet-4-5"
        )
        let model = SetupModel(
            initialChoices: BrainSetupChoices(options: [option], recommendation: nil)
        )

        model.advance()
        model.selectedOptionID = .anthropicAPIKey
        model.advance()
        XCTAssertEqual(model.stage, .key)
        XCTAssertFalse(model.canContinue, "an unverified key must remain blocking")

        model.skipKey()

        XCTAssertEqual(model.stage, .ready, "Not now must actually leave the key screen")
    }
}

/// What the owner is made to do before they may use the app.
///
/// Setup gates the product, so anything on it is something a person must get
/// past to reach what they paid for. Linking a phone was the fourth of five
/// screens and needs a second device, a working camera and a QR code that
/// expires — it is the step most likely to fail, and it failed twice for the
/// owner on the notarized build. Mynah has a conversation, a board and a memory
/// in its own window without it.
final class OnboardingGateTests: XCTestCase {

    /// The regression this guards is somebody re-adding it as a stage because
    /// the flow "feels incomplete" without it.
    func testLinkingAPhoneIsNotAStepOfSettingTheAppUp() {
        let titles = SetupModel.Stage.allCases.map(\.title)
        XCTAssertFalse(titles.contains("Phone"), "linking a phone is back on the onboarding gate")
        XCTAssertEqual(titles, ["Welcome", "Brain", "Connect", "Ready"])
    }

    /// Every stage that remains is something the app genuinely cannot run
    /// without: which brain does the thinking, and the key that brain needs.
    /// `Connect` is itself skippable — it lands in Settings as unfinished work.
    func testTheFlowEndsAtReady() {
        XCTAssertEqual(SetupModel.Stage.allCases.last, .ready)
        XCTAssertEqual(SetupModel.Stage.allCases.first, .welcome)
    }

    /// The rail numbers the stages, so a gap in the raw values would draw a
    /// four-step flow with a missing dot.
    func testTheStagesAreStillContiguous() {
        for (index, stage) in SetupModel.Stage.allCases.enumerated() {
            XCTAssertEqual(stage.rawValue, index, "\(stage) leaves a hole in the progress rail")
        }
    }
}

/// **That the private default cannot be a one-way door.**
///
/// The failure screen's "Use a provider instead" set a flag nothing cleared, so
/// an owner whose 3.4 GB download dropped once could never reach the private
/// setup again — not by retrying, not by going back to Welcome and forward.
/// A default you can be knocked permanently out of is not a default, and the
/// most likely cause of that first failure is a dropped connection.
@MainActor
final class PrivateSetupIsNotAOneWayDoorTests: XCTestCase {

    /// A capable Mac, planned the way the app plans it.
    private func modelOnACapableMac() -> SetupModel {
        let choices = BrainSetupPlanner().plan(
            for: .machine(hardware: .appleSilicon16GB)
        )
        let model = SetupModel(initialChoices: choices)
        model.selectedOptionID = choices.freshInstallDefault?.option.id
        return model
    }

    func testACapableMacStartsOnThePrivatePathWithoutBeingAsked() {
        let model = modelOnACapableMac()
        XCTAssertTrue(
            model.setsUpPrivatelyWithoutAsking,
            "a 16 GB Apple Silicon Mac is being shown the menu"
        )
        XCTAssertNil(model.whyYouAreBeingAsked, "and being given a reason for a question it isn't asked")
    }

    func testSteppingAwayFromThePrivatePathIsReversible() {
        let model = modelOnACapableMac()

        model.chooseBrainInstead()
        XCTAssertFalse(model.setsUpPrivatelyWithoutAsking, "the owner asked for the menu and did not get it")
        XCTAssertNil(model.selectedOptionID, "the option that just failed is still selected and ready to fail again")
        XCTAssertTrue(model.ownerAskedToChooseInstead)

        model.returnToPrivateSetup()
        XCTAssertTrue(
            model.setsUpPrivatelyWithoutAsking,
            "the owner cannot get back to the private brain — this is the one-way door"
        )
        XCTAssertEqual(model.selectedOptionID, .fullyLocal)
        XCTAssertNil(model.localBrainPhase, "the old failure is still on screen after starting over")
    }

    /// On a Mac that cannot run one, there is nothing to step away from and
    /// nothing to go back to — the menu is the whole screen, and it explains
    /// itself rather than offering a door into a wall.
    func testAMacThatCannotRunLocallyIsAskedAndTold() {
        let choices = BrainSetupPlanner().plan(for: .machine(hardware: .intel32GB))
        let model = SetupModel(initialChoices: choices)

        XCTAssertFalse(model.setsUpPrivatelyWithoutAsking)
        let reason = model.whyYouAreBeingAsked
        XCTAssertNotNil(reason, "asked to choose with no account of why")
        XCTAssertTrue(
            reason?.contains("Apple Silicon") == true,
            "the reason does not name the obstacle: \(reason ?? "")"
        )
    }
}
