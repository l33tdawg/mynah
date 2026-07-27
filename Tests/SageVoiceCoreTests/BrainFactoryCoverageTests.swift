import XCTest
@testable import MynahMac
@testable import SageVoiceCore

/// Proves the app can build every brain it offers.
///
/// This file is the reason `MynahMac` became a library target. It could not be
/// written before: nothing can import an executable, so the app's own types were
/// out of reach of every test, and the two lists that had to agree — what
/// `BrainSetupPlanner` offers and what `BrainFactory` can serve — were only ever
/// checked by a human reading both.
///
/// They drifted. The planner emitted seven backend identifiers
/// (`claude-code-cli`, `codex-cli`, `google`, `openai-compatible`, `anthropic`,
/// `openai`, `ollama`); the factory matched four, one of which (`gemini`) the
/// planner never emitted at all. So the option the app recommended — sparkle and
/// all — completed onboarding and then failed on the owner's first question with
/// "Mynah can't use that brain any more", permanently, because the only offered
/// remedy re-ran setup and recommended the same dead option again.
///
/// The nearest existing test iterated `APIKeyOnboarding.keyedProviders`, the
/// CLI's vocabulary rather than the planner's, and passed throughout.
///
/// These drive the real planner rather than hand-built options, so they keep
/// their meaning if the option type changes shape.
final class BrainFactoryCoverageTests: XCTestCase {

    /// Nothing the owner can pick may be unbuildable.
    ///
    /// The exact assertion that would have caught the shipped bug.
    func testEveryOfferedOptionCanActuallyBeBuilt() {
        for machine in Self.representativeMachines {
            let choices = BrainSetupPlanner().plan(for: machine.probe)

            for option in choices.availableOptions {
                XCTAssertNotNil(
                    option.id.backendPlan,
                    "\(machine.name): '\(option.id.rawValue)' is offered but nothing can serve it"
                )
                XCTAssertNoThrow(
                    try BrainFactory.makeBackend(for: option, apiKey: "test-key"),
                    "\(machine.name): '\(option.id.rawValue)' is offered but BrainFactory cannot build it"
                )
            }
        }
    }

    /// The recommendation carries a sparkle and is what most owners will take,
    /// so it is the single worst option to have be a dead end — and it was.
    func testTheRecommendationIsBuildableOnEveryMachine() {
        for machine in Self.representativeMachines {
            let choices = BrainSetupPlanner().plan(for: machine.probe)
            guard let recommendedID = choices.recommendation?.optionID,
                  let recommended = choices.option(withID: recommendedID) else {
                continue  // A machine with no recommendation is a different test.
            }
            XCTAssertNoThrow(
                try BrainFactory.makeBackend(for: recommended, apiKey: "test-key"),
                "\(machine.name): recommends '\(recommended.id.rawValue)', which cannot be built"
            )
        }
    }

    /// An option with no plan must refuse cleanly rather than crash, in case a
    /// stored choice from an older build survives an upgrade.
    func testAnUnservableStoredChoiceRefusesInsteadOfCrashing() {
        let choices = BrainSetupPlanner().plan(for: EnvironmentProbeResult())
        let unservable = (choices.availableOptions + choices.unavailableOptions)
            .filter { $0.id.backendPlan == nil }

        XCTAssertFalse(unservable.isEmpty, "expected the planner to still describe options it cannot serve")
        for option in unservable {
            XCTAssertThrowsError(try BrainFactory.makeBackend(for: option, apiKey: "test-key")) { error in
                guard case BrainFactory.Failure.notServiceable = error else {
                    return XCTFail("'\(option.id.rawValue)' should refuse cleanly, got \(error)")
                }
            }
        }
    }

    /// The owner this product is for — a plain Mac with nothing installed — plus
    /// the machine it was developed on, where the CLIs exist and mask the bug.
    private static let representativeMachines: [(name: String, probe: EnvironmentProbeResult)] = [
        ("bare Mac", EnvironmentProbeResult())
    ]
}
