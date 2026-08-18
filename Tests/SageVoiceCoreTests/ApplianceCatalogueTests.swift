import XCTest
@testable import SageVoiceCore

// MARK: - Stubs

/// SAGE's real published catalogue, as the owner's node lists it today.
///
/// Written out rather than trimmed to the interesting names, because the whole
/// point of curation is what it leaves behind: a stub publishing only the
/// fifteen we keep would pass every test below while proving nothing about the
/// eighteen we drop.
let sagePublishesToday = [
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

final class NamedSource: ToolProviding, @unchecked Sendable {
    private let names: [String]

    init(_ names: [String]) { self.names = names }

    func listTools() async throws -> [MCPTool] {
        names.map {
            MCPTool(name: $0, description: "stub \($0)", inputSchema: .object(["type": .string("object")]))
        }
    }

    /// Answers rather than records. Nothing here asserts *which* provider ran a
    /// tool — the composite's own tests do that with their own stub — and a
    /// lock held across an `async` boundary is an error in Swift 6.
    func call(name: String, arguments: [String: JSONValue]) async throws -> String {
        "stub ran \(name)"
    }
}

/// A backend that exists only to carry a tier, because the tier is what decides
/// the ceiling. `BrainBackend.brain` is derived from `isLocal` — see
/// `BrainTier`'s "the tier is derived, never declared".
private struct TieredBackend: BrainBackend {
    let identifier = "tiered-stub"
    let modelName = "stub-model"
    let isLocal: Bool

    func isAvailable() async -> Bool { true }

    func complete(_ request: BrainRequest) async throws -> BrainReply {
        BrainReply(
            model: modelName,
            message: .assistant("unused"),
            stopReason: .endTurn,
            usage: BrainUsage(inputTokens: 0, outputTokens: 0)
        )
    }
}

/// **What the model is actually offered, for the tests that used to read a
/// `Set<String>` out of `BrainPrompts`.**
///
/// Six test files asserted membership of `voiceToolAllowlist` — that
/// `sage_forget` is offered, that `sage_turn` is not, that the note tools
/// survive the filter. Every one of those questions is really a question about
/// the composed catalogue, and while one global set *was* the catalogue they
/// were the same question. They are not any more: a tool this repository
/// implements never appears in `sageToolCuration`, so asserting its absence
/// there would pass for the wrong reason forever.
///
/// Shared rather than copied into each file, because six copies of a catalogue
/// composition is how the three production copies drifted.
enum ComposedCatalogue {

    /// Defaults to `.onDevice`, which is the strictest tier and the one whose
    /// count has zero headroom. A caller that means the hosted catalogue says
    /// so, so no assertion here can widen by accident.
    static func conversation(
        sage: [String] = sagePublishesToday,
        brain: BrainTier = .onDevice
    ) async throws -> Set<String> {
        Set(try await ApplianceCatalogue.conversation(
            memory: NamedSource(sage),
            notes: NotesToolSource(directory: scratch()),
            web: WebSearchToolSource(backends: []),
            brain: brain
        ).listTools().map(\.name))
    }

    static func call(
        sage: [String] = sagePublishesToday,
        brain: BrainTier = .onDevice
    ) async throws -> Set<String> {
        Set(try await ApplianceCatalogue.call(
            memory: NamedSource(sage),
            afterTheCall: AfterTheCallToolSource(
                queue: CallActionQueue(fileURL: scratch().appendingPathComponent("after-the-call.json"))
            ),
            web: WebSearchToolSource(backends: []),
            brain: brain
        ).listTools().map(\.name))
    }

    static func scratch() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mynah-catalogue-\(UUID().uuidString)", isDirectory: true)
    }
}

// MARK: - Tests

/// **The golden set, and it is the whole safety argument for this change.**
///
/// Curation moved out of `BrainPrompts.voiceToolAllowlist` — one set filtering
/// the composed catalogue, which meant a tool this repository wrote itself
/// needed a line in `BrainPrompts` before the model could see it — and into
/// `CompositeToolSource`, per source. The claim that made that safe to do in
/// one commit is arithmetic: the composed catalogues come out at *exactly* the
/// same twenty names and *exactly* the same seventeen names as before.
///
/// It has to be exact and it has to be a literal here. Zero headroom is not a
/// figure of speech: `BrainCapabilities.onDevice.maxRoutableTools` is 20, the
/// conversation catalogue is 20, and two other tests ratchet against that. One
/// tool added or dropped in transit and the failure lands somewhere unrelated,
/// blamed on whoever touches the catalogue next. A golden set belongs in a test
/// rather than in a constant, because a constant would be updated by the same
/// edit that broke it.
final class ApplianceCatalogueTests: XCTestCase {

    private func scratchDirectory() -> URL { ComposedCatalogue.scratch() }

    private func conversationCatalogue(
        sage: ToolProviding = NamedSource(sagePublishesToday),
        brain: BrainTier = .onDevice
    ) -> CompositeToolSource {
        ApplianceCatalogue.conversation(
            memory: sage,
            notes: NotesToolSource(directory: scratchDirectory()),
            web: WebSearchToolSource(backends: []),
            brain: brain
        )
    }

    private func callCatalogue(
        sage: ToolProviding = NamedSource(sagePublishesToday),
        brain: BrainTier = .onDevice
    ) -> CompositeToolSource {
        ApplianceCatalogue.call(
            memory: sage,
            afterTheCall: AfterTheCallToolSource(queue: CallActionQueue(fileURL: scratchDirectory()
                .appendingPathComponent("after-the-call.json"))),
            web: WebSearchToolSource(backends: []),
            brain: brain
        )
    }

    // MARK: The golden sets

    /// Fifteen curated from SAGE, four this repository's notes source
    /// publishes, one for web search. These twenty names, in this order, are
    /// what a Signal message, a voice note and the Mac window are offered.
    func testTheConversationCatalogueIsExactlyTheseTwentyTools() async throws {
        let names = try await conversationCatalogue().listTools().map(\.name).sorted()

        XCTAssertEqual(names, [
            "list_notes",
            "read_note",
            "sage_backlog",
            "sage_corroborate",
            "sage_directory",
            "sage_federation",
            "sage_forget",
            "sage_inbox",
            "sage_link",
            "sage_message_history",
            "sage_message_reply",
            "sage_message_send",
            "sage_recall",
            "sage_remember",
            "sage_status",
            "sage_task",
            "sage_timeline",
            "send_file",
            "web_search",
            "write_note"
        ])
        XCTAssertEqual(
            names.count, BrainCapabilities.onDevice.maxRoutableTools,
            "the catalogue and the tier ceiling are the same number by design, and the "
                + "moment they are not, one of the two moved without the other being re-measured"
        )
    }

    /// Seventeen: the same fifteen from SAGE, `web_search`, and the queue.
    /// Strictly smaller than a conversation, never larger — catalogue size is
    /// the dominant term in routing accuracy on a small model, and a call has
    /// the least of that budget to spend.
    func testTheCallCatalogueIsExactlyTheseSeventeenTools() async throws {
        let names = try await callCatalogue().listTools().map(\.name).sorted()

        XCTAssertEqual(names, [
            "after_the_call",
            "sage_backlog",
            "sage_corroborate",
            "sage_directory",
            "sage_federation",
            "sage_forget",
            "sage_inbox",
            "sage_link",
            "sage_message_history",
            "sage_message_reply",
            "sage_message_send",
            "sage_recall",
            "sage_remember",
            "sage_status",
            "sage_task",
            "sage_timeline",
            "web_search"
        ])
    }

    /// The eighteen SAGE tools that are curated *out* stay out of the composed
    /// catalogue, which is the half a golden set of what is present cannot
    /// prove on its own — a stub that published nothing would satisfy an
    /// "absent" assertion and a subset would satisfy a "present" one.
    func testTheCuratedOutSageToolsAreNotOfferedOnEitherSurface() async throws {
        for brain in BrainTier.allCases {
            let dropped = Set(sagePublishesToday)
                .subtracting(BrainPrompts.sageToolCuration(for: brain))
            XCTAssertEqual(
                dropped.count, brain == .onDevice ? 18 : 17,
                "SAGE's catalogue changed shape for \(brain); re-read the exclusion prose"
            )

            for catalogue in [
                conversationCatalogue(brain: brain), callCatalogue(brain: brain)
            ] {
                let offered = Set(try await catalogue.listTools().map(\.name))
                XCTAssertTrue(
                    offered.isDisjoint(with: dropped),
                    "curated-out tools reached the \(brain) model: "
                        + "\(offered.intersection(dropped).sorted())"
                )
            }
        }
    }

    // MARK: The tier split

    /// **The bug the owner hit on 2.3.1, stated as the thing that must not
    /// happen again.**
    ///
    /// He asked whether two messages had been read. Mynah answered "there is no
    /// sage_message_status tool on my side", listed the two ids it had just
    /// read out of its own outbox, and reported them pending — because workflow
    /// state was the only state it could see. The tool existed on the node the
    /// whole time. It was withheld by a curated list whose stated reason was
    /// that the model "does not hold" a message id, written before
    /// `sage_message_history` was added and started handing it exactly those.
    ///
    /// Asserted on the composed catalogue rather than on the curation set,
    /// because the set is not what the model is offered — that distinction is
    /// the reason this file exists.
    func testAHostedBrainCanAskWhetherAMessageWasRead() async throws {
        let offered = try await ComposedCatalogue.conversation(brain: .hosted)

        XCTAssertTrue(
            offered.contains("sage_message_status"),
            """
            A hosted brain cannot answer "did they read it?". That question has \
            one tool, the node has published it throughout, and the appliance \
            answered the owner that it did not exist.
            """
        )
    }

    /// The other half, and the reason this is a split rather than an addition.
    ///
    /// A conversation is the curated SAGE names plus four notes tools plus
    /// `web_search`. On device the ceiling is 20 and the catalogue is 20, so a
    /// sixteenth SAGE name is not a slower appliance — `ToolLoop.availableTools()`
    /// throws `catalogueOverTierCeiling` and the turn is refused. The local
    /// brain keeps exactly what was measured for it.
    func testTheLocalBrainIsNotGivenTheExtraToolAndStaysAtItsCeiling() async throws {
        let offered = try await ComposedCatalogue.conversation(brain: .onDevice)

        XCTAssertFalse(
            offered.contains("sage_message_status"),
            "the on-device catalogue grew past what routing was measured at"
        )
        XCTAssertEqual(
            offered.count, BrainCapabilities.onDevice.maxRoutableTools,
            "the local catalogue and its ceiling are the same number by design"
        )
    }

    /// Hosted has headroom; headroom is not permission.
    ///
    /// `sage_message_replies` duplicates `sage_message_history(folder: "outbox")`
    /// and `sage_message_handoff` takes over another session's claimed work on a
    /// judgement about a foreign process's liveness. Both were considered when
    /// the tier split was made and both were refused, so this pins the decision
    /// rather than leaving the next reader to infer it from an absence.
    func testHeadroomOnAHostedBrainWasNotSpentOnEverythingAvailable() async throws {
        let offered = try await ComposedCatalogue.conversation(brain: .hosted)

        for withheld in ["sage_message_replies", "sage_message_handoff"] {
            XCTAssertFalse(
                offered.contains(withheld),
                "\(withheld) was added without the reasoning beside sageToolsAHostedBrainAlsoGets being updated"
            )
        }
        XCTAssertLessThanOrEqual(
            offered.count, BrainCapabilities.hosted.maxRoutableTools,
            "the hosted catalogue passed its own ceiling"
        )
    }

    // MARK: A call cannot send

    /// **The assertion the whole after-the-call feature rests on**, and it is
    /// now asserted twice over: the name is not in the composed catalogue, and
    /// calling it anyway is refused by name.
    ///
    /// The test this replaces asserted that `send_file` was absent from a
    /// `Set<String>` in `BrainPrompts`. That was the weaker half — a filtered
    /// name still routes if its provider is registered, which is exactly how
    /// `send_file` stayed live on every call from the day calls shipped while a
    /// design note claimed it was subtracted. Not registering the source is the
    /// mechanism; this is what proves the mechanism rather than the note.
    func testACallCannotReachTheNotesTools() async throws {
        let catalogue = callCatalogue()
        let offered = Set(try await catalogue.listTools().map(\.name))

        for name in NotesToolSource.toolNames {
            XCTAssertFalse(
                offered.contains(name),
                "\(name) is offered on a call. A call must not send files or emit documents "
                    + "while the line is open — the work is queued and drained at hang-up."
            )
        }
        XCTAssertTrue(
            offered.contains(AfterTheCallToolSource.toolName),
            "a call has no way to record what the owner asked for, so the request is simply lost"
        )

        do {
            _ = try await catalogue.call(name: NotesToolSource.sendToolName, arguments: [:])
            XCTFail("a call routed send_file — the file went out while the line was open")
        } catch let failure as CompositeToolSource.Failure {
            XCTAssertEqual(failure, .unknownTool(NotesToolSource.sendToolName))
        }
    }

    /// A call stays strictly smaller than a conversation. The old form of this
    /// compared two `Set<String>` constants; there are no constants now, so it
    /// compares the two things the model is actually handed.
    func testTheCallCatalogueIsSmallerThanTheConversationOne() async throws {
        let conversation = Set(try await conversationCatalogue().listTools().map(\.name))
        let call = Set(try await callCatalogue().listTools().map(\.name))

        XCTAssertLessThan(
            call.count, conversation.count,
            "the call surface now offers at least as many tools as a Signal message, which "
                + "spends the routing budget the call has least of"
        )
        XCTAssertEqual(
            call.subtracting(conversation), [AfterTheCallToolSource.toolName],
            "a call is offered something a conversation is not, and the queue is the only "
                + "tool that is allowed to be"
        )
    }

    // MARK: The fail-closed guard, in its new home

    /// **The guard moved from `ToolLoop` to `CompositeToolSource` and must not
    /// have been weakened in transit.** It lands two lines from an
    /// optional-source degradation path — one `guard !source.isRequired` away
    /// from becoming a log line — and a required SAGE that publishes nothing we
    /// recognise leaves the model holding web search and no memory while
    /// looking perfectly healthy.
    func testARenamedSageCatalogueThrowsRatherThanDegrading() async {
        let renamed = NamedSource(sagePublishesToday.map { $0.replacingOccurrences(of: "sage_", with: "brain_") })

        do {
            _ = try await conversationCatalogue(sage: renamed).listTools()
            XCTFail("a renamed SAGE catalogue was accepted, leaving the model with no memory tools")
        } catch let failure as CompositeToolSource.Failure {
            guard case .curationMatchedNothing(let label, let curated, let published) = failure else {
                return XCTFail("wrong failure: \(failure)")
            }
            XCTAssertEqual(label, "SAGE memory")
            XCTAssertEqual(curated.count, BrainPrompts.sageToolCuration.count)
            XCTAssertTrue(published.contains("brain_recall"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// The other direction: SAGE growing a tool must not trip the guard, and
    /// must not smuggle that tool into the prompt either. Both halves matter —
    /// the first is why the guard checks "any" rather than "all", the second is
    /// why curation is a filter and not just a health check.
    func testASageToolAddedUpstreamIsNeitherFatalNorOffered() async throws {
        let grown = NamedSource(sagePublishesToday + ["sage_something_new"])
        let names = Set(try await conversationCatalogue(sage: grown).listTools().map(\.name))

        XCTAssertTrue(names.contains("sage_recall"))
        XCTAssertFalse(
            names.contains("sage_something_new"),
            "a tool SAGE added between releases walked into the prompt and past the tier ceiling "
                + "without anybody deciding to offer it"
        )
    }

    // MARK: The tier ceiling

    private func loop(tools: [String], isLocal: Bool = true) -> ToolLoop {
        ToolLoop(
            backend: TieredBackend(isLocal: isLocal),
            mcp: NamedSource(tools),
            configuration: ToolLoop.Configuration(allowedToolNames: [])
        )
    }

    private func names(_ count: Int) -> [String] {
        (0..<count).map { String(format: "tool_%02d", $0) }
    }

    /// **The anti-lie test.** A catalogue over the tier ceiling is refused, and
    /// what makes it a refusal rather than a policy is that nothing comes back.
    ///
    /// Truncating to fit is the defect this repository treats as worst: the
    /// model would be handed twenty schemas while the owner believes the
    /// twenty-first tool he switched on is live, and nothing anywhere would say
    /// otherwise. He would find out from a tool that never fires.
    func testACatalogueOverTheTierCeilingIsRefusedAndNotTruncated() async {
        let ceiling = BrainCapabilities.onDevice.maxRoutableTools

        do {
            let offered = try await loop(tools: names(ceiling + 1)).availableTools()
            XCTFail(
                "availableTools() returned \(offered.count) tools for a ceiling of \(ceiling) "
                    + "instead of refusing. Truncating is the failure: the owner is told "
                    + "\(ceiling + 1) tools are on and the model can only see \(offered.count)."
            )
        } catch let error as ToolLoopError {
            guard case .catalogueOverTierCeiling(let tier, let reported, let offered) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(tier, .onDevice)
            XCTAssertEqual(reported, ceiling)
            XCTAssertEqual(offered.count, ceiling + 1, "the refusal must report the real count, not the fitted one")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// Exactly at the ceiling is fine. A guard that fires one tool early would
    /// take a tool away from a catalogue that ships at exactly twenty.
    func testACatalogueExactlyAtTheCeilingIsOffered() async throws {
        let ceiling = BrainCapabilities.onDevice.maxRoutableTools
        let offered = try await loop(tools: names(ceiling)).availableTools()
        XCTAssertEqual(offered.count, ceiling)
    }

    /// The ceiling is a tier field, so the same catalogue that a local brain
    /// refuses a hosted one accepts. This is the difference the field buys, and
    /// it is what a skills loader will spend.
    func testTheSameCatalogueThatIsRefusedLocallyIsOfferedOnAHostedBrain() async throws {
        let overLocal = names(BrainCapabilities.onDevice.maxRoutableTools + 1)
        let offered = try await loop(tools: overLocal, isLocal: false).availableTools()
        XCTAssertEqual(offered.count, overLocal.count)
        XCTAssertLessThanOrEqual(offered.count, BrainCapabilities.hosted.maxRoutableTools)
    }

    /// **Every dead end needs a door.** The refusal names the tier, the count,
    /// the ceiling, which tools are over the line, and the two things the owner
    /// can actually do. A number with no next action leaves him with a broken
    /// appliance and no idea what to touch.
    func testTheCeilingRefusalNamesTheTierTheCountAndTheWayOut() {
        let ceiling = BrainCapabilities.onDevice.maxRoutableTools
        let offered = names(ceiling + 2)
        let text = ToolLoopError.catalogueOverTierCeiling(
            tier: .onDevice, ceiling: ceiling, offered: offered
        ).description

        XCTAssertTrue(text.contains("onDevice"), "the refusal does not say which tier refused: \(text)")
        XCTAssertTrue(text.contains("\(offered.count)"), "the refusal does not say how many tools there are: \(text)")
        XCTAssertTrue(text.contains("\(ceiling)"), "the refusal does not say what the ceiling is: \(text)")
        for overflowing in offered.dropFirst(ceiling) {
            XCTAssertTrue(
                text.contains(overflowing),
                "the refusal does not name \(overflowing), which is one of the tools over the line: \(text)"
            )
        }
        XCTAssertTrue(
            text.contains("Settings"),
            "the refusal does not tell the owner where to turn a tool off: \(text)"
        )
        XCTAssertTrue(
            text.contains("hosted brain"),
            "the refusal does not offer the other way out — a bigger brain allows more: \(text)"
        )
    }

    // MARK: Catching the fourth allowlist

    /// **The rule, walked, for the same reason `MynahIdentityTests` walks every
    /// `ToolLoop` construction: a rule is only as good as the next registration
    /// somebody writes.**
    ///
    /// Half of the rule is in the type — `Source.external` cannot be built
    /// without a curation, so a child process cannot be registered uncurated;
    /// `Source.inProcess` has no name parameter, so a fourth hand-maintained
    /// allowlist cannot be typed into one. Neither of those needs a test,
    /// because neither compiles.
    ///
    /// What the type cannot hold is *where* registrations live. There were
    /// three source lists once — two in `main.swift`, one in
    /// `ConversationModel` — and they had already drifted apart: each declared
    /// a different expected-tool set, one of them a hand-guessed two-name
    /// literal. A fourth surface written next month would drift the same way,
    /// compile perfectly, and be discovered from behaviour.
    func testOnlyOneFileDecidesWhichSourcesMakeUpACatalogue() throws {
        var registrars: [String: Int] = [:]

        try walkSources { file, dense in
            let count = dense.components(separatedBy: ".inProcess(label:").count - 1
                + dense.components(separatedBy: ".external(label:").count - 1
            guard count > 0 else { return }
            registrars[file.lastPathComponent, default: 0] += count
        }

        XCTAssertGreaterThan(
            registrars["ApplianceCatalogue.swift"] ?? 0, 0,
            "could not find any source registration to check — has ApplianceCatalogue moved?"
        )
        XCTAssertEqual(
            Set(registrars.keys), ["ApplianceCatalogue.swift"],
            """
            a surface builds its own list of tool sources instead of asking ApplianceCatalogue: \
            \(registrars.keys.sorted().joined(separator: ", ")). That is how the three that \
            existed before drifted — each carried its own hand-written idea of what SAGE should \
            publish, and one of them was a two-name guess agreeing with neither of the others.
            """
        )
    }

    /// **The fourth allowlist, caught by name rather than by shape.**
    ///
    /// `BrainPrompts.sageToolCuration` curates SAGE and only SAGE. The set it
    /// replaced had to union the note tools in and hand-add `web_search`,
    /// because it filtered the composed catalogue — and a comment beside that
    /// line recorded that forgetting it "was a silent no-op for web search".
    /// Anything published by a source this repository implements has no
    /// business in that literal, and a skill's tool name least of all: the day
    /// one appears there, skills are being curated by a constant in
    /// `BrainPrompts` again and the loader's whole design has been undone.
    func testTheSageCurationNamesNothingThisRepositoryImplements() async throws {
        var ours: Set<String> = []
        ours.formUnion(try await NotesToolSource(directory: scratchDirectory()).listTools().map(\.name))
        ours.formUnion(try await WebSearchToolSource(backends: []).listTools().map(\.name))
        ours.formUnion(try await AfterTheCallToolSource(
            queue: CallActionQueue(fileURL: scratchDirectory().appendingPathComponent("q.json"))
        ).listTools().map(\.name))

        XCTAssertEqual(ours.count, 6, "an in-process source changed what it publishes; check this list is complete")
        XCTAssertTrue(
            BrainPrompts.sageToolCuration.isDisjoint(with: ours),
            """
            \(BrainPrompts.sageToolCuration.intersection(ours).sorted().joined(separator: ", ")) \
            is in the SAGE curation, and this repository implements it. A tool we wrote does not \
            ask a constant in BrainPrompts for permission to be offered — it self-declares through \
            CompositeToolSource.Source.inProcess, which is why that factory has no name parameter.
            """
        )
    }

    /// Every name in the curation is one SAGE actually publishes. The
    /// composite fails closed only when *nothing* matches, so a single typo
    /// costs a tool silently rather than loudly.
    func testEveryCuratedNameIsOneSagePublishes() {
        let unpublished = BrainPrompts.sageToolCuration.subtracting(sagePublishesToday)
        XCTAssertTrue(
            unpublished.isEmpty,
            "\(unpublished.sorted().joined(separator: ", ")) is curated and SAGE publishes no such "
                + "tool, so it is a slot spent on nothing — or the node's catalogue has moved and "
                + "the stub at the top of this file is stale"
        )
    }

    private func walkSources(_ body: (URL, String) throws -> Void) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let file = files?.nextObject() as? URL {
            guard file.pathExtension == "swift" else { continue }
            // Whitespace removed before matching, for the reason
            // `MynahIdentityTests` gives: a construction wrapped across lines
            // stopped matching and silently stopped being counted, and a guard
            // a line break can switch off is worse than none because it still
            // reports success.
            try body(file, try String(contentsOf: file, encoding: .utf8).filter { !$0.isWhitespace })
        }
    }
}
