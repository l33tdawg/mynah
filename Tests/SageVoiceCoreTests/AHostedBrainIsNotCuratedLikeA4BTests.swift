import XCTest
@testable import SageVoiceCore

/// **The bug the owner found on 2.3.1, stated as the thing that must not happen
/// again.**
///
/// He asked Mynah whether two messages had been read. It answered *"there is no
/// sage_message_status tool on my side"*, listed the two message ids it had
/// just read out of its own outbox, and reported them pending — because the
/// workflow status was the only status it could see. The tool had been on the
/// node the whole time.
///
/// Two causes, and the second is the larger one.
///
/// **The stale reason.** `sage_message_status` was excluded from
/// `BrainPrompts.voiceToolAllowlist` with the written justification that it
/// "answers 'was this delivered' about an id the model does not hold". That was
/// true when it was written. `sage_message_history` was added afterwards — to
/// fix a different failure, where the model could not read its own outbox — and
/// history returns a `message_id` on every item. From that day the model held
/// the ids and had nothing to spend them on. Two decisions, each correct alone.
///
/// **One list for every brain.** Catalogue size costs routing accuracy *on a
/// small local model*, and `BrainCapabilities.hosted.maxRoutableTools` is
/// larger precisely because that result was only ever taken on local models.
/// The curated list was nevertheless applied to every brain, so a frontier
/// model was refused a tool on evidence gathered from a 4B.
///
/// The figure this paragraph used to quote — "12/12 with 14 tools and 5-6/12
/// with 27" — is superseded and was never comparable: it was measured against a
/// tool list that had drifted out of the appliance, containing `sage_pipe` and
/// `sage_pipe_result` and missing all three message tools. The 19 Aug 2026
/// sweep against what actually ships is in `BrainCapabilities.maxRoutableTools`,
/// and its shape is a flat 9/12 to composed 27 and a cliff after it — so size
/// is not what costs the three misses that remain below the cliff. Colliding
/// tool descriptions are.
///
/// These assertions go through `ToolLoop.availableTools()` rather than reading
/// the set out of `BrainPrompts`, because the set is not what the model is
/// offered — the loop is the only place that knows the brain, and it is where
/// the widening happens.
final class AHostedBrainIsNotCuratedLikeA4BTests: XCTestCase {

    /// SAGE's published catalogue as the owner's node lists it, all 33.
    ///
    /// Written out rather than trimmed to the interesting names: the whole
    /// point of a curated list is what it leaves behind, and a stub publishing
    /// only the names we keep would pass every assertion here while proving
    /// nothing about the ones we drop.
    private static let sagePublishesToday = [
        "sage_backlog", "sage_corroborate", "sage_directory", "sage_domains",
        "sage_federation", "sage_find_agent", "sage_forget", "sage_gov_propose",
        "sage_gov_status", "sage_gov_vote", "sage_inbox", "sage_inception",
        "sage_link", "sage_list", "sage_message_handoff", "sage_message_history",
        "sage_message_replies", "sage_message_reply", "sage_message_send",
        "sage_message_status", "sage_messages_receive", "sage_recall",
        "sage_reflect", "sage_register", "sage_reinstate", "sage_remember",
        "sage_rename", "sage_scope_get", "sage_scope_list", "sage_status",
        "sage_task", "sage_timeline", "sage_turn"
    ]

    /// The composed catalogue also carries what this repository implements, and
    /// the allowlist names those too — leaving `web_search` out of it was once a
    /// silent no-op for the whole web-search feature.
    private var everythingPublished: [String] {
        Self.sagePublishesToday
            + NotesToolSource.toolNames.sorted()
            + [WebSearchToolSource.toolName]
    }

    private func offered(to tier: BrainTier) async throws -> Set<String> {
        let loop = ToolLoop(
            backend: TieredBackend(isLocal: tier == .onDevice),
            mcp: PublishingSource(everythingPublished),
            // Exactly what production passes: `Configuration`'s default. If that
            // default changes, this test is asking the wrong question and should
            // fail rather than quietly test a set nobody ships.
            configuration: ToolLoop.Configuration()
        )
        return Set(try await loop.availableTools().map(\.name))
    }

    // MARK: The bug

    func testAHostedBrainCanAskWhetherAMessageWasRead() async throws {
        let hosted = try await offered(to: .hosted)

        XCTAssertTrue(
            hosted.contains("sage_message_status"),
            """
            A hosted brain still cannot answer "did they read it?". That question \
            has exactly one tool, the node has published it throughout, and the \
            appliance told the owner it did not exist.
            """
        )
    }

    /// The other half, and the reason this is a split rather than an addition.
    ///
    /// The local catalogue is the one that was measured, and the hosted tier
    /// must not quietly become the way things are added to it.
    ///
    /// **This asserted `count == maxRoutableTools` until 19 Aug 2026 and that
    /// was right at the time**: the ceiling was 20, the catalogue was 20, and
    /// zero headroom was the deliberate design — the twenty-first tool was
    /// meant to be a refusal somebody had to read. The sweep then measured an
    /// identical 9/12 at composed 20, 21, 22, 24 and 27, falling to 6/12 only at
    /// 32, so the ceiling moved to 22 and the equality stopped being true. The
    /// relationship is now `<=` with two measured slots of room, and the
    /// assertion says so rather than being loosened quietly.
    ///
    /// What still has to hold exactly is the CONTENTS: the local brain is
    /// offered the curated set and nothing else, whatever room the ceiling
    /// leaves. Room is not an invitation.
    func testTheLocalBrainKeepsExactlyWhatWasMeasuredForIt() async throws {
        let local = try await offered(to: .onDevice)

        XCTAssertFalse(
            local.contains("sage_message_status"),
            "the on-device catalogue grew past what routing was measured at"
        )
        XCTAssertEqual(
            local, BrainPrompts.voiceToolAllowlist,
            "the local catalogue is no longer the curated set it was measured as"
        )
        XCTAssertLessThanOrEqual(
            local.count, BrainCapabilities.onDevice.maxRoutableTools,
            """
            The local catalogue is over its own ceiling, which ToolLoop does not \
            enforce on this release line — so this is the only thing standing \
            between a 4B and a catalogue routing was never measured at. Rerun \
            scripts/measure-tool-routing.py before raising either number.
            """
        )
    }

    /// Headroom is not permission.
    ///
    /// `sage_message_replies` duplicates `sage_message_history(folder: "outbox")`
    /// — its own schema calls it "the explicit sender-side pager behind
    /// sage_inbox.reply_items" — and `sage_message_handoff` takes over work
    /// another session has claimed, on a judgement about a foreign process's
    /// liveness that a language model cannot make. Both were considered when the
    /// tier split was made and both were refused; this pins that decision so the
    /// next reader does not have to infer it from an absence.
    func testHeadroomWasNotSpentOnEverythingTheNodeOffers() async throws {
        let hosted = try await offered(to: .hosted)

        for withheld in ["sage_message_replies", "sage_message_handoff"] {
            XCTAssertFalse(
                hosted.contains(withheld),
                "\(withheld) was added without the reasoning beside "
                    + "BrainPrompts.sageToolsAHostedBrainAlsoGets being updated"
            )
        }
        XCTAssertLessThanOrEqual(
            hosted.count, BrainCapabilities.hosted.maxRoutableTools,
            "the hosted catalogue passed its own ceiling"
        )
    }

    /// The widening may only ever add; every curated name a local brain gets, a
    /// hosted one gets too. Stated because the split is a `union` today and a
    /// `switch` is one edit away from making the two sets diverge.
    func testTheHostedCatalogueIsTheLocalOnePlusTheExtras() async throws {
        let local = try await offered(to: .onDevice)
        let hosted = try await offered(to: .hosted)

        XCTAssertTrue(
            local.isSubset(of: hosted),
            "a hosted brain lost a tool the local one has: \(local.subtracting(hosted).sorted())"
        )
        XCTAssertEqual(
            hosted.subtracting(local), BrainPrompts.sageToolsAHostedBrainAlsoGets,
            "the difference between the tiers is no longer the documented set"
        )
    }

    /// A tool the node does not publish cannot be conjured by naming it.
    ///
    /// The widening is a `union` over the allowlist, and the filter intersects
    /// with what `tools/list` returned — so an older node that has never heard
    /// of `sage_message_status` simply offers one fewer tool rather than
    /// producing a name the model would call into nothing.
    func testAnOlderNodeThatDoesNotPublishItIsNotGivenIt() async throws {
        let withoutIt = everythingPublished.filter { $0 != "sage_message_status" }
        let loop = ToolLoop(
            backend: TieredBackend(isLocal: false),
            mcp: PublishingSource(withoutIt),
            configuration: ToolLoop.Configuration()
        )

        let offered = Set(try await loop.availableTools().map(\.name))

        XCTAssertFalse(offered.contains("sage_message_status"))
        XCTAssertEqual(
            offered, BrainPrompts.voiceToolAllowlist,
            "a node without the tool should offer exactly the curated set, no more and no less"
        )
    }

    // MARK: Stubs

    /// Publishes names and answers nothing. The tier is what is under test, so
    /// nothing here records calls.
    private final class PublishingSource: ToolProviding, @unchecked Sendable {
        private let names: [String]

        init(_ names: [String]) { self.names = names }

        func listTools() async throws -> [MCPTool] {
            names.map {
                MCPTool(
                    name: $0,
                    description: "stub \($0)",
                    inputSchema: .object(["type": .string("object")])
                )
            }
        }

        func call(name: String, arguments: [String: JSONValue]) async throws -> String {
            "stub ran \(name)"
        }
    }

    /// Carries a tier and nothing else. `BrainBackend.tier` is derived from
    /// `isLocal` rather than declared beside it, so this is the only knob there
    /// is — see `BrainTier`'s "derived, never declared".
    private struct TieredBackend: BrainBackend {
        let identifier = "tiered-stub"
        let modelName = "stub-model"
        let isLocal: Bool

        func isAvailable() async -> Bool { true }

        func complete(_ request: BrainRequest) async throws -> BrainReply {
            BrainReply(model: modelName, message: .assistant("unused"), stopReason: .endTurn)
        }
    }
}
