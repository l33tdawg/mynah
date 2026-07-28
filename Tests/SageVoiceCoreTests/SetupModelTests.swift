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

        XCTAssertEqual(model.stage, .phone, "Not now must actually leave the key screen")
    }
}
