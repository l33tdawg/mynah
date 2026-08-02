import SwiftUI
import XCTest
@testable import MynahMac
@testable import SageVoiceCore

/// **That amber stays gone, and that what replaced it is a mechanism.**
///
/// This supersedes `CautionInkTests`, which spent its life defending an
/// increasingly complicated set of rules about *which* amber was allowed where.
/// Those rules existed because the colour meant four things at once — paused,
/// restricted, setup unfinished, words leaving the Mac — and the owner proved
/// what a colour with four jobs does: he looked at a yellow mark on a stale
/// task list and reported that Signal had crashed. It had not. Both processes
/// were up.
///
/// Two separate rules were written to contain that, and both required you to
/// already know the rule in order to pick a colour correctly. He ended it in one
/// line: *"amber accent kill it bro - its meaningless; if something is not
/// working, we should disable the send button or something instead; that makes
/// more visual sense"*.
///
/// The second half of that sentence is the important half, and it is why this
/// file is not merely a colour check. **He replaced a signal with a
/// constraint.** A disabled Send cannot be misread the way a hue can.
@MainActor
final class AmberIsGoneTests: XCTestCase {

    // MARK: The mechanism

    /// **The one that would have caught the original bug.**
    ///
    /// When the engine is blocked, Home used to draw "Not ready yet" in amber
    /// beside a Send button that still worked — so nothing but the owner's
    /// reading of a colour stood between him and a turn that could not succeed.
    /// Now the control is off.
    func testAJammedEngineDisablesSendRatherThanColouringSomething() {
        let model = ConversationModel(readiness: .blocked(Self.jammed))
        model.draft = "are you there?"

        XCTAssertNotNil(model.trouble, "the fixture stopped reaching the blocked state")
        XCTAssertFalse(
            model.canSend,
            "Send is live on an engine that cannot answer — the colour was the only guard"
        )
    }

    /// The other side of it, so the guard cannot be satisfied by disabling Send
    /// permanently. A working appliance sends.
    func testAWorkingApplianceStillSends() {
        let model = ConversationModel(readiness: Self.working)
        model.draft = "are you there?"

        XCTAssertNil(model.trouble)
        XCTAssertTrue(model.canSend)
    }

    /// Disabling on trouble must not swallow the ordinary reasons Send is off,
    /// which were already right and are easy to lose in a rewrite.
    func testTheOrdinaryReasonsSendIsOffSurvive() {
        let model = ConversationModel(readiness: Self.working)

        XCTAssertFalse(model.canSend, "an empty draft should not send")

        model.draft = "   \n  "
        XCTAssertFalse(model.canSend, "whitespace is an empty draft")

        model.draft = "ok"
        XCTAssertTrue(model.canSend)

    }

    /// **Waking up stopped being a reason to refuse.**
    ///
    /// It was one, on the theory that a turn must not be queued into a
    /// half-built engine. The theory was already unfounded — `runTurn` awaits
    /// `connect()`, which *joins* the start-up in flight rather than starting a
    /// second one — and the cost was the owner's first impression: start-up is
    /// ten seconds on a good day, and he opens the app specifically to ask
    /// something. His words: *"this is when you straight send a message when
    /// the app opens"*.
    ///
    /// The message now appears at once and answers as soon as the engine is up.
    func testAMessageTypedWhileItWakesIsAccepted() {
        let waking = ConversationModel(readiness: .connecting)
        waking.draft = "ok"

        XCTAssertTrue(waking.canSend, "the turn waits for the engine; the owner should not wait to type")
    }

    /// The distinction that survives: waking is a wait that ends by itself,
    /// trouble is a wait that never ends without the owner doing something.
    func testTroubleStillStopsIt() {
        let blocked = ConversationModel(readiness: .blocked(Self.jammed))
        blocked.draft = "ok"

        XCTAssertFalse(blocked.canSend)
    }

    private static let working = ConversationModel.Readiness.ready(
        destination: "this Mac",
        model: "qwen3.5:4b",
        staysOnDevice: true
    )

    private static let jammed = Exchange.Failure(
        headline: "Mynah can't think right now.",
        explanation: "Set it up again in Settings."
    )

    // MARK: The colour

    /// The token is gone rather than redefined to grey.
    ///
    /// Redefining it would have been the cheaper change and the worse one: a
    /// token named `caution` that renders as ordinary ink is a lie that the next
    /// person reaches for precisely because it still exists. Deleting it makes
    /// every former call site a compile error somebody had to answer for.
    ///
    /// Asserted on the palette source, because "this identifier does not exist"
    /// is not a thing a value test can express.
    /// **The token is back, for one meaning, and the reasoning has to be beside
    /// it.**
    ///
    /// The owner reversed this himself: *"if user is using api key, these model
    /// thing should be in yellow / orange - green only when its fully private;
    /// makes sense i think"*. It does make sense, and it is not the change that
    /// was reverted. The old amber meant four things — paused, restricted,
    /// setup unfinished, words leaving the Mac — and died of that. This is the
    /// fourth of those and nothing else, and it completes a pair whose other
    /// half already exists: green has only ever meant "stays on this Mac".
    ///
    /// So this test stops checking that the token is absent and starts checking
    /// that the argument is present. A token somebody adds without reading why
    /// the last one was removed is how four meanings happen again.
    func testTheCautionTokenCarriesTheArgumentForItsOwnExistence() throws {
        let palette = try read("Sources/MynahMac/Style/MynahTheme.swift")

        XCTAssertTrue(palette.contains("static let caution"), "the caution token vanished")
        // Phrases that sit on one line. The first attempt required "never
        // acquire a second one", which the palette does say — across a line
        // break, so the substring is not contiguous and the test failed on
        // prose it was happy with.
        for required in ["Words leave this Mac", "one half of a pair", "kill it bro"] {
            XCTAssertTrue(
                palette.contains(required),
                "the palette no longer explains what caution means or why it is limited to one job"
            )
        }
    }

    /// **The sweep, done as a property rather than as a list.**
    ///
    /// The first pass at this change reported five call sites and there were
    /// thirty-five — a `grep | head` that truncated, which is the third time in
    /// one day a partial search has been mistaken for a complete one. A test
    /// that greps the whole tree cannot make that mistake twice.
    ///
    /// `AgentMessaging.Trust.caution` is excluded by name: it is a `String`
    /// explaining why a message from another agent should be treated carefully,
    /// it has never been a colour, and it is the exact false positive a naive
    /// sweep produces.
    /// Every file allowed to draw in amber, and why each one is.
    ///
    /// `MynahTheme` and `Components` define the token and the tone. `Settings`
    /// is the only surface that uses it, on the three rows that answer "where
    /// do my words go" — the provider pill on Home's status row, the appliance's
    /// destination, and the Privacy list where the pair reads plainest with
    /// "Stays here" in green two rows below.
    private static let mayDrawInAmber: Set<String> = [
        "MynahTheme.swift", "Components.swift", "SettingsView.swift"
    ]

    /// **The sweep, done as a property rather than as a list.**
    ///
    /// The first pass at removing amber reported five call sites and there were
    /// thirty-five — a `grep | head` that truncated, which is the third time in
    /// one day a partial search had been mistaken for a complete one. A test
    /// that greps the whole tree cannot make that mistake twice.
    ///
    /// It no longer forbids amber outright — see the token test above — but the
    /// containment is the entire reason the colour is allowed back, so the
    /// sweep stays and is now an allowlist. Any *new* file reaching for it is a
    /// second meaning arriving, which is the failure this whole file exists to
    /// prevent.
    ///
    /// `AgentMessaging.Trust.caution` is excluded by name: it is a `String`
    /// explaining why a message from another agent should be treated carefully,
    /// it has never been a colour, and it is the exact false positive a naive
    /// sweep produces.
    func testOnlyTheRowsAboutWhereWordsGoDrawInAmber() throws {
        let offenders = try swiftFiles(under: "Sources").compactMap { url -> String? in
            guard !Self.mayDrawInAmber.contains(url.lastPathComponent) else { return nil }
            let source = try String(contentsOf: url, encoding: .utf8)
            let hits = source.split(separator: "\n").enumerated().filter { _, line in
                guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("///") else { return false }
                guard !line.contains("trust.caution") else { return false }
                return line.contains("state.caution")
                    || line.contains("cautionWash")
                    || line.contains("tone: .caution")
                    || line.contains("StatusDot(.caution)")
            }
            guard !hits.isEmpty else { return nil }
            return "\(url.lastPathComponent): \(hits.map { "line \($0.offset + 1)" }.joined(separator: ", "))"
        }

        XCTAssertEqual(
            offenders, [],
            "amber has picked up a second meaning: \(offenders.joined(separator: "; "))"
        )
    }

    /// Green and amber must stay a pair rather than becoming a synonym.
    func testPrivateAndNotPrivateAreDrawnDifferently() {
        XCTAssertNotEqual(
            MynahTone.good.ink.description,
            MynahTone.caution.ink.description,
            "a cloud model and an on-device one are now the same colour"
        )
        XCTAssertNotEqual(
            MynahTone.caution.ink.description,
            MynahTone.neutral.ink.description,
            "caution collapsed into ordinary ink, so only the absence of green says anything"
        )
    }

    /// The accent is ink, not a hue. The amber hexes are the thing to pin —
    /// a later edit could reintroduce the colour under any token name.
    func testTheAccentIsInkAndNotAWarmYellow() throws {
        let palette = try read("Sources/MynahMac/Style/MynahTheme.swift")

        for amber in ["0xF0A020", "0xFFB833", "0x8A5000", "0xFFC451", "0x9C5F00", "0xF0A73B"] {
            XCTAssertFalse(palette.contains(amber), "\(amber) is back in the palette")
        }
    }

    /// Green survives, and it survives *because* it never had a second job — it
    /// means "stays on this Mac" and nothing has ever used it for a fault. Red
    /// survives because a failure is not a shade of a warning. Deleting either
    /// while sweeping the amber would be the over-correction.
    func testTheTwoHonestColoursAreStillThere() {
        XCTAssertNotEqual(
            MynahTone.good.ink.description,
            Palette.ink.secondary.description,
            "green collapsed into ordinary ink"
        )
        XCTAssertNotEqual(
            MynahTone.critical.ink.description,
            Palette.ink.secondary.description,
            "red collapsed into ordinary ink"
        )
    }

    /// The setup card was the last amber and the argument for keeping it was
    /// good: on a card the owner is *deciding*, and the colour was the cue
    /// separating the two kinds of choice. It went anyway, because the cue was
    /// never only the colour — the green dot and the company's own name carry
    /// it. This pins that the comparison still exists without the hue.
    func testTheSetupCardStillDistinguishesTheTwoChoicesWithoutAHue() {
        XCTAssertNotEqual(
            OptionCardInk.sendsWordsAway.description,
            OptionCardInk.staysHere.description,
            "both halves of the choice are now drawn identically"
        )
        XCTAssertEqual(
            OptionCardInk.sendsWordsAway.description,
            Palette.ink.secondary.description,
            "a destination is being drawn as something other than ordinary text"
        )
    }

    /// The reasoning has to live where somebody picking a colour will meet it,
    /// which is the palette — not a commit message and not this file.
    func testThePaletteExplainsWhyThereIsNoAmber() throws {
        let palette = try read("Sources/MynahMac/Style/MynahTheme.swift")

        XCTAssertTrue(
            palette.contains("There is no amber") || palette.contains("there is no amber"),
            "the palette no longer says the amber is deliberate, so it reads as an omission"
        )
        XCTAssertTrue(
            palette.contains("disabled"),
            "the palette does not say what replaced the amber"
        )
    }

    // MARK: Reading the tree

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: repoRoot().appendingPathComponent(path), encoding: .utf8)
    }

    private func swiftFiles(under path: String) throws -> [URL] {
        let root = repoRoot().appendingPathComponent(path)
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }
}
