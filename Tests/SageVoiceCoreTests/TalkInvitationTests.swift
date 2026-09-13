import XCTest
@testable import MynahMac

/// The invitation to send something from the phone, and the one word in it that
/// depends on what the appliance can actually do.
///
/// Its own file because the failure is specific and silent: a screenshot of this
/// screen cannot show that a promise is unkeepable, and the owner only finds out
/// by sending a photo to a brain with no eyes and being told it was saved but
/// not read.
final class TalkInvitationTests: XCTestCase {

    /// The branch that changed. A multimodal appliance — the local default, and
    /// every provider whose Quick model is in the vision table — should say so,
    /// because "you can send a photo" is the single most useful thing an owner
    /// can learn about this product that they would never guess.
    func testAPhoneThatCanSeeIsInvitedToSendAPicture() {
        let message = TalkInvitation.sendItSomething(seesImages: true)
        XCTAssertTrue(message.contains("photo"))
        XCTAssertTrue(message.contains("voice note"))
        XCTAssertTrue(
            message.contains("Photograph the thing you are asking about"),
            "the sentence says a photo is allowed without saying what to do with one"
        )
        XCTAssertTrue(
            message.contains("remembers"),
            "the promise that survives every brain was dropped"
        )
    }

    /// **The branch that must not move.** A text-only local model gets the
    /// sentence this screen had before vision existed, and the photo clause is
    /// absent from it rather than softened.
    func testAPhoneThatCannotSeeIsNotOfferedAPhoto() {
        let message = TalkInvitation.sendItSomething(seesImages: false)
        XCTAssertFalse(
            message.lowercased().contains("photo"),
            "the empty state promised a photograph on an appliance that cannot read one"
        )
        XCTAssertFalse(message.lowercased().contains("picture"))
        XCTAssertTrue(message.contains("voice note"))
        XCTAssertTrue(message.contains("remembers"))
    }

    /// The same rule, under the composer, where there is less room and no
    /// second chance to explain.
    func testTheComposerHintFollowsTheSameRule() {
        let seeing = TalkInvitation.alsoFromYourPhone(seesImages: true)
        XCTAssertTrue(seeing.contains("photo"))

        let blind = TalkInvitation.alsoFromYourPhone(seesImages: false)
        XCTAssertFalse(blind.lowercased().contains("photo"))
        XCTAssertTrue(blind.contains("voice note"))
    }

    /// Owner-facing copy, so the settled vocabulary applies — and the offer to
    /// look at a picture must not turn into a claim that it definitely saw
    /// anything. "It will tell you what it is" is about the thing in the photo;
    /// a promise about the model's eyes belongs to the Privacy screen, where the
    /// exception is named.
    func testTheCopyUsesTheProductsOwnWords() {
        for message in [
            TalkInvitation.sendItSomething(seesImages: true),
            TalkInvitation.sendItSomething(seesImages: false),
            TalkInvitation.alsoFromYourPhone(seesImages: true),
            TalkInvitation.alsoFromYourPhone(seesImages: false)
        ] {
            XCTAssertFalse(message.lowercased().contains("domain"))
            XCTAssertFalse(message.lowercased().contains("attachment"))
            XCTAssertFalse(message.isEmpty)
        }
    }
}
