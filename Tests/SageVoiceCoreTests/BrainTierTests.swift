import XCTest
@testable import SageVoiceCore

/// The owner's rule, pinned: *"local model can do up to x - api models can do x
/// + y + z"*.
///
/// **These exist because the rule was previously enforced by folklore.** It was
/// decided in nine separate places, and the ninth had no branch at all —
/// `ToolLoop.Configuration.maxToolResultCharacters`, a hardcoded 6,000 applied
/// after `VoiceToolBudget` had already granted a hosted brain 32,000. Nobody
/// noticed for the life of the feature, because the local content budget is
/// *also* exactly 6,000, so the second cut never bit on this Mac.
///
/// Two numbers that happen to be equal, in different units, in different files,
/// are not one rule. That is what these assert against.
final class BrainTierTests: XCTestCase {

    // MARK: The rule itself

    /// Every ceiling is at least as generous on a hosted brain. This is the
    /// owner's sentence as an assertion, and it holds for every numeric field
    /// rather than for the ones somebody remembered.
    func testAHostedBrainIsNeverHeldToATighterCeilingThanALocalOne() {
        let local = BrainCapabilities.onDevice
        let hosted = BrainCapabilities.hosted

        XCTAssertGreaterThanOrEqual(hosted.minimumOutputTokens, local.minimumOutputTokens)
        XCTAssertGreaterThanOrEqual(hosted.directoryResultBytes, local.directoryResultBytes)
        XCTAssertGreaterThanOrEqual(hosted.contentResultBytes, local.contentResultBytes)
        XCTAssertGreaterThanOrEqual(hosted.maxRoutableTools, local.maxRoutableTools)
        XCTAssertGreaterThanOrEqual(
            hosted.toolResultBackstopCharacters,
            local.toolResultBackstopCharacters
        )
    }

    /// The tier is derived from where the owner's words go, never declared
    /// beside it. A backend able to state both is a backend able to make them
    /// disagree.
    func testTheTierComesFromWhetherTheWordsLeaveTheMac() {
        XCTAssertEqual(BrainTier.onDevice.capabilities.tier, .onDevice)
        XCTAssertEqual(BrainTier.hosted.capabilities.tier, .hosted)
        XCTAssertEqual(BrainCapabilities(tier: .onDevice), .onDevice)
        XCTAssertEqual(BrainCapabilities(tier: .hosted), .hosted)
    }

    // MARK: The numbers that were written twice

    /// **The floor existed in two files with the same reasoning typed out
    /// twice.** `BrainRequest.hostedMinimumOutputTokens` and
    /// `AnthropicBackend.minimumMaxOutputTokens` were both 4,096 and had to
    /// agree; nothing made them. Two constants that must match and cannot be
    /// made to is how one gets raised and the other does not.
    func testTheTwoOldFloorConstantsNowReadTheSameTier() {
        XCTAssertEqual(
            BrainRequest.hostedMinimumOutputTokens,
            BrainCapabilities.hosted.minimumOutputTokens
        )
        XCTAssertEqual(
            AnthropicBackend.minimumMaxOutputTokens,
            BrainCapabilities.hosted.minimumOutputTokens
        )
    }

    /// **The absolute floor, asserted against a literal.** The suite's existing
    /// checks compared the wire body to the constant that produced it —
    /// `max(1024, C) == C`, green for every C at or above 1,024 — so setting the
    /// floor to 1,024 would have reinstated the v1.5.1 truncation bug with a
    /// green suite. A floor has to be pinned to a number, not to itself.
    func testTheHostedFloorIsPinnedToANumberAndNotToItself() {
        XCTAssertGreaterThanOrEqual(
            BrainCapabilities.hosted.minimumOutputTokens, 4096,
            "below this, a reasoning model spends the whole allowance thinking and "
                + "returns stop_reason: max_tokens with nothing in it"
        )
    }

    /// Zero, not a sentinel. `max(n, 0) == n`, so the local ceiling stays
    /// exactly what `ReplyStyle` chose — and raising it would be actively
    /// harmful, since qwen3.5:4b was measured generating 4,069 tokens over 190
    /// seconds and returning empty content.
    func testTheLocalFloorLeavesTheReplyStyleAlone() {
        XCTAssertEqual(BrainCapabilities.onDevice.minimumOutputTokens, 0)

        let asked = BrainRequest(messages: [], maxOutputTokens: 1024)
        XCTAssertEqual(asked.maxOutputTokens(for: .onDevice, default: 512), 1024)
        XCTAssertEqual(
            asked.maxOutputTokens(for: .hosted, default: 512),
            BrainCapabilities.hosted.minimumOutputTokens,
            "a hosted ask below the floor must be raised to it"
        )
    }

    /// **The floor has to be able to emit the thing it exists for.**
    ///
    /// It was 4,096, and the arithmetic that nobody had done end to end says
    /// that could not work: `write_note` accepts 32,000 characters, the document
    /// travels *inside* the tool call, and 4,096 tokens cuts that JSON at around
    /// 16,000 characters — half of what the tool would have accepted. The
    /// ceiling meant to bound the document was bounding it below its own limit,
    /// and on a reasoning model thinking comes out of the same allowance first.
    ///
    /// Asserted as a relationship rather than a number so it cannot rot the way
    /// the two hardcoded 4096s in this file did: raise the note limit and this
    /// fails until the budget follows.
    func testTheHostedFloorCanActuallyEmitTheLongestNote() {
        // ~4 characters per token, the usual rough conversion.
        let tokensForLongestNote = NotesToolSource.maximumContentCharacters / 4

        XCTAssertGreaterThanOrEqual(
            BrainCapabilities.hosted.minimumOutputTokens,
            tokensForLongestNote,
            "the hosted budget cannot carry a full \(NotesToolSource.maximumContentCharacters)-character "
                + "note, so write_note gets cut off mid-argument and the owner is told the document "
                + "cannot be produced at all"
        )
    }

    /// A deliberate one-token probe stays one token on either tier. The floor
    /// exists to stop a local model's budget starving a reasoning model, not to
    /// bill the owner for a reachability test.
    func testATinyProbeIsNeverInflated() {
        let probe = BrainRequest(messages: [], maxOutputTokens: 1)
        XCTAssertEqual(probe.maxOutputTokens(for: .hosted, default: 4096), 1)
        XCTAssertEqual(probe.maxOutputTokens(for: .onDevice, default: 4096), 1)
    }

    // MARK: The backstop that cancelled the budget

    /// **The defect, stated as arithmetic.** The backstop must never be able to
    /// cut something the budget deliberately allowed — which is exactly what a
    /// hardcoded 6,000 did to a 32,000-byte hosted allowance.
    func testTheBackstopCannotCutWhatTheBudgetAllowed() {
        for capabilities in [BrainCapabilities.onDevice, .hosted] {
            for tool in ["sage_inbox", "sage_status", "read_note", "list_notes"] {
                XCTAssertGreaterThan(
                    capabilities.toolResultBackstopCharacters,
                    VoiceToolBudget.budget(forTool: tool, brain: capabilities),
                    "\(capabilities.tier) would re-cut a fitted \(tool) result"
                )
            }
        }
    }

    /// And the headroom is not slack: `fit` appends a sentence saying what it
    /// removed, and that sentence is the one thing that must survive every
    /// adjustment to these numbers. A backstop set equal to the budget would cut
    /// it off and leave the model reading half a result as though it were whole.
    func testTheHeadroomLeavesRoomForTheSentenceSayingItWasCut() {
        for capabilities in [BrainCapabilities.onDevice, .hosted] {
            let largest = max(capabilities.directoryResultBytes, capabilities.contentResultBytes)
            XCTAssertGreaterThanOrEqual(
                capabilities.toolResultBackstopCharacters - largest, 150,
                "no room for the note `fit` appends, so the two truncations would stack"
            )
        }
    }

    /// The reported case, through the loop's own ceiling rather than through
    /// `fit` in isolation — which is how the original bug hid. Two long agent
    /// messages, about 8 KB of inbox: cut on device, whole on a hosted brain.
    func testAnAgentsLongMessageSurvivesOnAHostedBrain() {
        let inbox = String(repeating: "the tail of this message is the errand. ", count: 205)
        XCTAssertGreaterThan(inbox.utf8.count, 8_000)

        let onCloud = VoiceToolBudget.fit(inbox, tool: "sage_inbox", brain: .hosted)
        XCTAssertEqual(onCloud, inbox, "the hosted allowance is 32,000 and this is 8,000")
        XCTAssertLessThan(
            onCloud.count, BrainCapabilities.hosted.toolResultBackstopCharacters,
            "and the loop's backstop must not take back what the budget just granted"
        )

        let onDevice = VoiceToolBudget.fit(inbox, tool: "sage_inbox", brain: .onDevice)
        XCTAssertLessThan(onDevice.utf8.count, inbox.utf8.count, "6,000 on device, so this is cut")
    }

    // MARK: The catalogue ratchet

    /// **A ratchet, and the only job this field currently has.**
    ///
    /// The ceiling is 22 and the allowlist holds twenty-one, so there is one
    /// slot of room here — but not in the product. `PromptLatencyBudgetTests`
    /// bounds the same count at 21, so the effective ceiling is that one and the
    /// real headroom is zero. Two constants, one job, and they have disagreed
    /// since 19 Aug 2026; read that file before quoting this one's slack. The sweep
    /// on 19 Aug 2026 (qwen3.5:4b, real prompt, `scripts/measure-tool-routing.py`)
    /// scored an identical 9/12 at composed sizes 20, 21, 22, 24 and 27, then
    /// fell to 6/12 at 32. `sage_message_handoff` took the twenty-first slot on
    /// 21 Aug 2026 and was re-measured the same day rather than read off that
    /// table: composed 21 scores 10/12, flat to composed 28. Both tables are in
    /// `BrainCapabilities.maxRoutableTools`, and they are not directly
    /// comparable — the second carries the spoken hints, which did not exist
    /// when the first was taken. See `BrainCapabilities.maxRoutableTools` for the
    /// table and for why the older "12/12 at 14, 5-6/12 at 27" is superseded and
    /// not comparable — it was measured against a list the appliance never ran.
    ///
    /// A twenty-third tool turns this red and forces somebody to rerun the
    /// measurement rather than letting the catalogue drift past the cliff —
    /// which it already did once, past the "18" its own comment claimed. The
    /// remedy is a rerun and a pasted table, never an argument.
    func testATwentyThirdToolForcesARemeasurement() {
        XCTAssertLessThanOrEqual(
            BrainPrompts.voiceToolAllowlist.count,
            BrainCapabilities.onDevice.maxRoutableTools,
            """
            The local catalogue has grown past the number routing was last sized for. \
            Re-run scripts/measure-tool-routing.py against qwen3.5:4b and move \
            BrainCapabilities.onDevice.maxRoutableTools with the measurement in the comment.
            """
        )
    }

    // MARK: Calls

    /// The owner's ruling of 4 August 2026, after a tester spent a call on
    /// qwen3.5:4b: *"calling on qwen seems unusable we should disable //call for
    /// local - only api - voice notes local handles fine but realtime calls is
    /// too much"*.
    func testARealtimeCallNeedsAHostedBrain() {
        XCTAssertFalse(BrainCapabilities.onDevice.holdsARealtimeCall)
        XCTAssertTrue(BrainCapabilities.hosted.holdsARealtimeCall)
    }

    // MARK: Vision

    /// `false` on hosted states a fact about this repository, not about the
    /// vendors: the word "image" does not appear in either hosted encoder, so a
    /// hosted backend declaring vision would be claiming to have seen a picture
    /// it dropped on the floor.
    func testAHostedBrainIsStillBlindBecauseNobodyWroteTheEncoder() throws {
        XCTAssertFalse(BrainCapabilities.hosted.mayCarryImages)

        for file in ["AnthropicBackend.swift", "OpenAICompatBackend.swift"] {
            let source = try String(
                contentsOf: URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent().deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent("Sources/SageVoiceCore/Brain/\(file)"),
                encoding: .utf8
            )
            XCTAssertFalse(
                source.lowercased().contains("image"),
                """
                \(file) mentions images now. If the encoder has landed, flip \
                BrainCapabilities.hosted.mayCarryImages and narrow it per model in \
                CloudBrainModelCatalog — a model missing from that table must read as blind.
                """
            )
        }
    }

    // MARK: The wire, which is where the floor actually has to happen

    /// **The fix I claimed and did not make.** Commit 23703d0 said, in its
    /// message and in a doc comment written as fact, that an OpenAI-shaped
    /// *local* server had stopped getting the hosted 4,096 floor. It had not:
    /// the tier-aware API was added and the one call site that needed it was
    /// never rewired, so `maxOutputTokens(for:default:)` had zero production
    /// callers and `requestBody` still hardcoded `.hosted`.
    ///
    /// Three independent reviewers found it within an hour, and nothing in the
    /// suite could have: every `requestBody` test used `.deepSeek` or
    /// `.openAI`, and there was no local-provider case anywhere in the file.
    ///
    /// So this asserts on the **wire body**, not on the helper. A floor that is
    /// right in a function nobody calls is not a floor.
    func testALocalOpenAIServerKeepsTheCeilingItAskedFor() throws {
        let body = OpenAICompatBackend.requestBody(
            for: BrainRequest(messages: [.user("hello")], maxOutputTokens: 1024),
            model: "qwen3.5-4b",
            provider: .lmStudio()
        )

        XCTAssertEqual(
            body["max_tokens"] as? Int, 1024,
            "a model on this Mac was raised to a cloud reasoning model's floor"
        )
    }

    /// And the hosted side still gets its floor, or the fix would have traded
    /// one silent truncation for another — this is the v1.5.1 bug's own path.
    func testAHostedOpenAIProviderStillGetsTheFloor() throws {
        let body = OpenAICompatBackend.requestBody(
            for: BrainRequest(messages: [.user("hello")], maxOutputTokens: 1024),
            model: "deepseek-v4-flash",
            provider: .deepSeek
        )

        XCTAssertEqual(
            body["max_tokens"] as? Int,
            BrainCapabilities.hosted.minimumOutputTokens,
            "DeepSeek asked for 1024 and must be raised to the hosted floor; this is the path the "
                + "v1.5.1 bug took, where eight write_note calls arrived with no content"
        )
    }
}
