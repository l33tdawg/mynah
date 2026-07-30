import XCTest
@testable import SageVoiceCore

/// The reply-style setting.
///
/// It exists because two correct rules were in conflict. "At most 40 words, no
/// markdown, no bullet points" was written for text-to-speech, where a
/// synthesiser reads "-" aloud as a hyphen. Then the appliance shipped over
/// Signal text, the owner asked for ramen shops near KLCC, and got prose that
/// had been trimmed for a voice nobody was listening to.
final class ReplyStyleTests: XCTestCase {

    private var directory: URL!
    private var preferences: ReplyPreferences!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("reply-style-\(UUID().uuidString)", isDirectory: true)
        preferences = ReplyPreferences(fileURL: directory.appendingPathComponent("reply-preferences.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: The setting

    /// Voice notes off by default, so written is what a new owner gets. Also the
    /// safer default: a long answer to someone expecting a short one is an
    /// annoyance, while 40 words to someone who asked for a list of shops with
    /// links has silently dropped what they asked for.
    func testVoiceNotesAreOffByDefault() {
        XCTAssertEqual(ReplyStyle.default, .written)
        XCTAssertFalse(ReplyStyle.default.usesVoiceNotes)
        XCTAssertEqual(preferences.style(), .written, "no saved preference did not fall back to the default")
    }

    /// **Spoken replies are gated off, and this is the gate.**
    ///
    /// Mynah answering by voice note is built and covered; it is not shipped,
    /// because the owner judged it past what people will use — sending voice
    /// notes and calling both earn their place, an assistant talking back at you
    /// when you typed does not. Shipping a capability is a different decision
    /// from enabling it.
    ///
    /// Asserted rather than left implicit so that re-enabling is one visible
    /// flip with a test that changes with it, instead of a behaviour that
    /// quietly returns.
    func testSpokenRepliesAreGatedOffRegardlessOfThePreference() throws {
        XCTAssertFalse(
            ReplyStyle.spokenRepliesAreAvailable,
            "spoken replies are being shipped — was that decided?"
        )
        XCTAssertEqual(ReplyStyle(voiceNotes: true), .written)
        XCTAssertEqual(ReplyStyle(voiceNotes: false), .written)
    }

    /// **The gate is on the behaviour, not on the control.**
    ///
    /// An owner who turned spoken replies on before this shipped has `true` in
    /// their preferences file and no switch left to change it. Hiding the row
    /// alone would leave them with a spoken appliance and no way back, so what
    /// the daemon reads has to be `written` even when the saved answer says
    /// otherwise.
    func testAPreviouslySavedPreferenceCannotStrandAnOwner() throws {
        try preferences.save(voiceNotes: true)
        // A separate instance is what the daemon process gets.
        let asRead = ReplyPreferences(fileURL: directory.appendingPathComponent("reply-preferences.json"))
        XCTAssertEqual(
            asRead.style(), .written,
            "an owner who enabled spoken replies is stuck with them"
        )

        try preferences.save(voiceNotes: false)
        XCTAssertEqual(asRead.style(), .written)
    }

    /// Nothing was deleted — the writer still writes, so restoring the feature is
    /// the flag and the Settings row rather than a migration.
    ///
    /// Asserted against the file rather than a property, because `ReplyPreferences`
    /// exposes only `style()` and widening its API to prove a point about a
    /// disabled feature would be the tail wagging the dog.
    func testTheOwnersSavedAnswerIsOverriddenRatherThanDiscarded() throws {
        try preferences.save(voiceNotes: true)
        let saved = try String(
            contentsOf: directory.appendingPathComponent("reply-preferences.json"), encoding: .utf8
        )
        XCTAssertTrue(
            saved.contains("true"),
            "the owner's answer was thrown away rather than overridden: \(saved)"
        )
    }

    /// A preferences file that will not parse should cost the owner their
    /// preference, not their appliance.
    func testACorruptFileFallsBackRatherThanFailing() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("nonsense".utf8).write(to: directory.appendingPathComponent("reply-preferences.json"))
        XCTAssertEqual(preferences.style(), .default)
    }

    func testTheFileIsOwnerOnly() throws {
        try preferences.save(voiceNotes: true)
        let file = directory.appendingPathComponent("reply-preferences.json")
        let perms = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms, 0o600)
    }

    // MARK: What each style tells the model

    /// The spoken prompt is the one that was measured — 40 words, no markup —
    /// and it must stay that way, because a synthesiser reading bullet points
    /// aloud is the failure it was written for.
    func testSpokenKeepsTheRulesWrittenForASynthesiser() {
        let prompt = BrainPrompts.voiceAgentManager(style: .spoken)
        XCTAssertTrue(prompt.contains("at most 40 words"))
        XCTAssertTrue(prompt.contains("No markdown, no bullet points"))
        XCTAssertTrue(prompt.contains("read aloud by a speech synthesiser"))
    }

    /// The reported failure, inverted: the owner asked for shops and links, so
    /// the written style has to permit a list and demand tappable URLs.
    func testWrittenAsksForTheWholeAnswer() {
        let prompt = BrainPrompts.voiceAgentManager(style: .written)
        XCTAssertTrue(prompt.contains("Give the whole answer"))
        XCTAssertTrue(prompt.contains("its own line"), "no way to render a list of shops")
        XCTAssertTrue(prompt.contains("starting with https://"), "links stay untappable")
        XCTAssertFalse(prompt.contains("at most 40 words"), "the spoken limit leaked into the written style")
    }

    /// Neither style is a licence for markup the owner never wanted. Signal
    /// renders none of it, so headings and bold are clutter in both.
    func testNeitherStyleAllowsHeadingsOrBold() {
        for style in ReplyStyle.allCases {
            let prompt = BrainPrompts.voiceAgentManager(style: style)
            XCTAssertTrue(
                prompt.contains("No headings") || prompt.contains("no headings"),
                "\(style) permits headings"
            )
            XCTAssertTrue(prompt.contains("do not list the tools you used"), "\(style) lost the tool-narration rule")
        }
    }

    /// Everything below HOW YOU SPEAK is shared. Splitting the prompt must not
    /// quietly fork the tool-routing rules, which are the expensive part to get
    /// right and were measured once.
    func testOnlyTheSpeakingSectionDiffers() {
        for style in ReplyStyle.allCases {
            let prompt = BrainPrompts.voiceAgentManager(style: style)
            for shared in [
                "WHEN TO USE A TOOL",
                "REMEMBERING EARLIER CONVERSATIONS",
                "One recall is rarely enough",
                "LINKING TO A PLACE",
                "SENDING WORK TO ANOTHER AGENT",
                "GROUND RULES"
            ] {
                XCTAssertTrue(prompt.contains(shared), "\(style) is missing \"\(shared)\"")
            }
        }
    }

    /// The default constant and the default style have to agree, or the daemon
    /// and everything that reads `voiceAgentManager` describe different products.
    func testTheBareConstantIsTheDefaultStyle() {
        XCTAssertEqual(BrainPrompts.voiceAgentManager, BrainPrompts.voiceAgentManager(style: .default))
    }

    /// The system prompt is the prompt cache's prefix, so each style has to
    /// serialise identically every time. A prompt that varies between turns is a
    /// cache that never hits — the fault that cost this appliance 17 seconds a
    /// turn until it was found.
    func testEachStyleIsByteStable() {
        for style in ReplyStyle.allCases {
            XCTAssertEqual(
                BrainPrompts.voiceAgentManager(style: style),
                BrainPrompts.voiceAgentManager(style: style)
            )
        }
        XCTAssertNotEqual(
            BrainPrompts.voiceAgentManager(style: .spoken),
            BrainPrompts.voiceAgentManager(style: .written),
            "the setting does not change the prompt, so it changes nothing"
        )
    }

    /// Both styles are prefilled on every cold turn, so both are held to the
    /// budget — not just the one that happens to be the default.
    func testBothStylesFitThePrefillBudget() {
        for style in ReplyStyle.allCases {
            XCTAssertLessThanOrEqual(
                BrainPrompts.voiceAgentManager(style: style).count,
                PromptLatencyBudgetTests.systemPromptCharacterBudget,
                "\(style) is over the prefill budget"
            )
        }
    }
}
