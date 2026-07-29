import XCTest
@testable import MynahMac
@testable import SageVoiceCore

/// **That "where your words go" asks the question that matters first.**
///
/// The sheet used to be one flat list mixing local and cloud, ordered by an
/// internal "tier". That buried the only distinction on the screen with
/// consequences: a cloud row spends the owner's money and sends his words to a
/// company, and the local row does neither. Sorting them together presented that
/// as a preference.
///
/// Two of his reports drive what is asserted here. *"there's no where to set the
/// api keys for cloud providers"* — true, because picking one closed the sheet,
/// saved a brain that could not answer, and opened a second sheet. And *"yes
/// models you have pulled bro - wtf free text!? thats fucking dumb"* — also
/// true, because a model name typed by hand is a typo that becomes a failure two
/// screens later.
///
/// **These test `BrainProviderChoice` rather than the view, and that is why the
/// rules exist as a value type at all.** The first draft of this file assigned
/// to the view's `@State` and asserted on the result; every write was silently
/// discarded, because `@State` has no storage outside a SwiftUI render. Four
/// tests "failed" for reasons that had nothing to do with the behaviour they
/// named — and one of them, buried among the noise, was a real bug.
final class BrainProviderSheetTests: XCTestCase {

    private var planned: BrainSetupChoices {
        BrainSetupPlanner().plan(for: .machine())
    }

    private func option(_ id: BrainSetupOptionID) -> BrainSetupOption? {
        planned.option(withID: id)
    }

    /// No key saved for anything, unless a test says otherwise. The real
    /// `KeyStorage` is never consulted — these must not depend on, or disturb,
    /// whatever is on the machine running them.
    private func noKeys(_ provider: String) -> Bool { false }
    private func everyKey(_ provider: String) -> Bool { true }

    private func choice(
        current: BrainSetupOption? = nil,
        models: [String] = ["qwen3:8b", "llama3.2:3b"]
    ) -> BrainProviderChoice {
        BrainProviderChoice(current: current, installedLocalModels: models)
    }

    // MARK: The two sides

    func testTheTwoSidesAreSplitByWhereTheWordsGo() {
        let choices = planned

        XCTAssertEqual(choices.localOption?.id, .fullyLocal)
        XCTAssertFalse(choices.cloudOptions.isEmpty, "no cloud provider is offered")
        XCTAssertTrue(
            choices.cloudOptions.allSatisfy { $0.keyProviderIdentifier != nil },
            "something that needs no key was filed under Cloud"
        )
        XCTAssertFalse(
            choices.cloudOptions.contains { $0.id == .fullyLocal },
            "the local brain appeared in the cloud list"
        )
    }

    /// Opens where he already is, because this sheet is reached to adjust far
    /// more often than to switch sides.
    func testItOpensOnTheSideTheOwnerIsAlreadyOn() throws {
        XCTAssertEqual(choice(current: try XCTUnwrap(option(.fullyLocal))).destination, .thisMac)
        XCTAssertEqual(choice(current: try XCTUnwrap(option(.anthropicAPIKey))).destination, .cloud)
    }

    func testEachSideSaysWhatItCosts() {
        XCTAssertTrue(
            BrainProviderChoice.Destination.thisMac.explanation.contains("never leave this Mac")
        )
        XCTAssertTrue(BrainProviderChoice.Destination.cloud.explanation.contains("pay"))
        XCTAssertTrue(BrainProviderChoice.Destination.cloud.explanation.contains("company"))
    }

    /// Switching sides must not leave a selection from the other one behind —
    /// "Use this brain" would then commit something that is not on screen.
    func testSwitchingSidesDoesNotCarryAnInvisibleSelection() throws {
        let choices = planned
        var subject = choice(current: try XCTUnwrap(option(.anthropicAPIKey)))
        subject.typedKey = "sk-ant-something"

        subject.moved(
            to: .thisMac,
            localOption: choices.localOption,
            cloudOptions: choices.cloudOptions,
            current: option(.anthropicAPIKey)
        )

        XCTAssertEqual(subject.selected?.id, .fullyLocal)
        XCTAssertTrue(subject.typedKey.isEmpty, "a key typed for one provider survived the switch")
    }

    // MARK: Models are the ones you have

    /// **The real bug the broken first draft was hiding.**
    ///
    /// The recorded model can be one Ollama no longer has — removed, or the
    /// record predates a reinstall. Preselecting it put the dot on a row that
    /// does not exist, so the sheet looked like nothing was chosen while
    /// insisting something was.
    func testAModelThatIsNoLongerInstalledIsNotPreselected() throws {
        var stale = try XCTUnwrap(option(.fullyLocal))
        stale.modelName = "a-model-that-was-deleted"

        let subject = choice(current: stale, models: ["qwen3:8b", "llama3.2:3b"])

        XCTAssertEqual(
            subject.localModel, "qwen3:8b",
            "a model that is not installed was preselected"
        )
    }

    /// The recorded model is kept when it *is* still there.
    func testTheRecordedModelIsKeptWhenItIsStillInstalled() throws {
        var current = try XCTUnwrap(option(.fullyLocal))
        current.modelName = "llama3.2:3b"

        XCTAssertEqual(choice(current: current).localModel, "llama3.2:3b")
    }

    /// With nothing pulled there is nothing to choose, and no local brain can be
    /// committed — rather than one being committed with no model behind it.
    func testWithNoModelsPulledThereIsNothingToCommit() throws {
        var subject = choice(current: nil, models: [])
        subject.selected = try XCTUnwrap(option(.fullyLocal))

        XCTAssertNil(subject.localModel)
        XCTAssertNil(subject.resolved(), "a local brain with no model resolved anyway")
        XCTAssertFalse(subject.canCommit(current: nil, hasSavedKey: noKeys))
    }

    /// The chosen model is folded into what gets saved, or picking a different
    /// one would change nothing.
    func testTheChosenModelIsCarriedIntoWhatGetsSaved() throws {
        var subject = choice(current: try XCTUnwrap(option(.fullyLocal)))
        subject.selected = try XCTUnwrap(option(.fullyLocal))
        subject.localModel = "llama3.2:3b"

        XCTAssertEqual(try XCTUnwrap(subject.resolved()).modelName, "llama3.2:3b")
    }

    /// Changing only the model is a real change. A no-op guard comparing option
    /// ids alone would make the model picker inert.
    func testChangingOnlyTheModelCanStillBeCommitted() throws {
        var current = try XCTUnwrap(option(.fullyLocal))
        current.modelName = "qwen3:8b"

        var subject = choice(current: current)
        subject.selected = current
        subject.localModel = "llama3.2:3b"

        XCTAssertTrue(
            subject.canCommit(current: current, hasSavedKey: noKeys),
            "the model picker cannot commit anything"
        )
    }

    func testReselectingWhatIsAlreadyInUseCannotBeCommitted() throws {
        var current = try XCTUnwrap(option(.fullyLocal))
        current.modelName = "qwen3:8b"

        var subject = choice(current: current)
        subject.selected = current
        subject.localModel = "qwen3:8b"

        XCTAssertFalse(subject.canCommit(current: current, hasSavedKey: noKeys))
    }

    // MARK: The key

    /// **The whole reason the field moved onto this sheet.** The old flow saved
    /// the brain and then went looking for a key, leaving a Mac configured to
    /// use something that could not answer.
    func testACloudProviderWithNoKeyCannotBeCommitted() throws {
        var subject = choice()
        subject.destination = .cloud
        subject.selected = try XCTUnwrap(option(.deepSeekAPIKey))

        XCTAssertFalse(
            subject.canCommit(current: nil, hasSavedKey: noKeys),
            "a keyless cloud brain could be saved"
        )
    }

    func testTypingAKeyIsEnoughToCommitACloudProvider() throws {
        var subject = choice()
        subject.destination = .cloud
        subject.selected = try XCTUnwrap(option(.deepSeekAPIKey))
        subject.typedKey = "sk-not-a-real-key"

        XCTAssertTrue(subject.canCommit(current: nil, hasSavedKey: noKeys))
    }

    /// A key already on the machine is enough — he does not have to paste it
    /// again to switch back to a provider he has used before.
    func testAKeyAlreadySavedIsEnough() throws {
        var subject = choice()
        subject.destination = .cloud
        subject.selected = try XCTUnwrap(option(.deepSeekAPIKey))

        XCTAssertTrue(subject.canCommit(current: nil, hasSavedKey: everyKey))
    }

    /// Whitespace is not a key. Pasting from a page that included a newline must
    /// not read as having supplied one.
    func testWhitespaceIsNotAKey() throws {
        var subject = choice()
        subject.destination = .cloud
        subject.selected = try XCTUnwrap(option(.deepSeekAPIKey))
        subject.typedKey = "   \n  "

        XCTAssertFalse(subject.canCommit(current: nil, hasSavedKey: noKeys))
    }

    /// Replacing a key on the provider already in use is a real change, even
    /// though the option has not moved — otherwise an expired key could never be
    /// fixed.
    func testReplacingTheKeyOnTheCurrentProviderIsAChange() throws {
        let current = try XCTUnwrap(option(.anthropicAPIKey))
        var subject = choice(current: current)
        subject.selected = current
        subject.typedKey = "sk-ant-replacement"

        XCTAssertTrue(
            subject.canCommit(current: current, hasSavedKey: everyKey),
            "an expired key could never be replaced"
        )
    }

    // MARK: What is offered at all

    /// The agent CLIs stay off both sides. They were withdrawn, the explanation
    /// that replaced them was withdrawn too, and neither returns by way of this
    /// sheet.
    func testTheAgentCLIsAppearOnNeitherSide() {
        let choices = planned
        let everything = [choices.localOption].compactMap { $0 } + choices.cloudOptions

        for id in [BrainSetupOptionID.claudeCodeCLI, .codexCLI, .googleSignIn] {
            XCTAssertFalse(everything.contains { $0.id == id }, "\(id) is being offered")
        }
    }

    /// Every cloud row can explain how to get its key, or the field under it is
    /// a dead end.
    func testEveryCloudProviderCanExplainHowToGetAKey() {
        for option in planned.cloudOptions {
            let provider = option.keyProviderIdentifier
            XCTAssertNotNil(provider, "\(option.id) is on the cloud side with no provider")
            XCTAssertNotNil(
                provider.flatMap(APIKeyOnboarding.instructions(forProvider:)),
                "\(option.id) offers a key field with no instructions behind it"
            )
        }
    }
}
