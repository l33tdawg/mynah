import XCTest
@testable import MynahMac
@testable import SageVoiceCore

/// The subject pills, and the seam they sit behind.
///
/// The owner designed this half of the page and the node cannot answer it yet —
/// listing another agent's grants needs an endpoint arriving in SAGE 11.15.0.
/// So the whole design is what happens *before* it lands, and these tests pin
/// that rather than the pills themselves.
@MainActor
final class AgentSubjectTests: XCTestCase {

    /// The rule, and the reason it is a rule.
    ///
    /// A node that cannot answer must produce no pill — not "unknown", not a
    /// dash, not a spinner. Each of those draws a fact the app does not have,
    /// and this screen has now shipped that mistake twice: a roster reading
    /// "zero connected agents" over twenty agents, and a memories page showing
    /// its empty state because it signed as an agent that did not exist. Both
    /// times an absence was rendered as an answer.
    func testANodeThatCannotAnswerLeavesNothingBehind() async {
        let model = AgentsModel(
            source: StubDirectory(),
            federation: StubScan(),
            subjectSource: UnaskableSubjects()
        )

        await model.loadSubjects(forAgent: "any-agent")

        XCTAssertTrue(
            model.subjects.isEmpty,
            "an unanswerable question left something on screen to draw"
        )
    }

    /// `nil` and `[]` are different answers and must stay different.
    ///
    /// `[]` is a node that answered and said "none" — a fact about the agent,
    /// and worth drawing. `nil` is a node that could not be asked, which is not
    /// a fact about the agent at all. Collapsing them turns "we cannot see"
    /// into "there are none", which is exactly the substitution that made an
    /// empty memories page look like an empty brain.
    func testAnsweringNoneIsNotTheSameAsBeingUnaskable() async {
        let answered = AgentsModel(
            source: StubDirectory(), federation: StubScan(),
            subjectSource: FixedSubjects(["quiet-agent": []])
        )
        await answered.loadSubjects(forAgent: "quiet-agent")
        XCTAssertEqual(
            answered.subjects["quiet-agent"], [],
            "a node that said 'none' was recorded as never having been asked"
        )

        let unaskable = AgentsModel(
            source: StubDirectory(), federation: StubScan(),
            subjectSource: UnaskableSubjects()
        )
        await unaskable.loadSubjects(forAgent: "quiet-agent")
        XCTAssertNil(unaskable.subjects["quiet-agent"])
    }

    /// When the endpoint does land, the view must not need touching.
    func testSubjectsAreKeptPerAgentWhenTheNodeCanAnswer() async {
        let model = AgentsModel(
            source: StubDirectory(), federation: StubScan(),
            subjectSource: FixedSubjects([
                "a": ["native-shell-ci", "go-debugging"],
                "b": ["quantum-physics"]
            ])
        )

        await model.loadSubjects(forAgent: "a")
        await model.loadSubjects(forAgent: "b")

        XCTAssertEqual(model.subjects["a"], ["native-shell-ci", "go-debugging"])
        XCTAssertEqual(model.subjects["b"], ["quantum-physics"])
    }

    /// Selecting the same row twice must not re-ask. Cheap today because the
    /// answer is nothing; not cheap once it is a request per selection.
    func testAnAgentIsOnlyAskedAboutOnce() async {
        let source = CountingSubjects()
        let model = AgentsModel(
            source: StubDirectory(), federation: StubScan(), subjectSource: source
        )

        await model.loadSubjects(forAgent: "a")
        await model.loadSubjects(forAgent: "a")

        let calls = await source.calls
        XCTAssertEqual(calls, 1, "the same agent was asked about twice")
    }
}

/// The line above the roster, which replaced filtering the roster.
final class RosterFramingTests: XCTestCase {

    /// Both halves, in the order that makes it a description rather than an
    /// apology. The owner's objection was that the list promised more than it
    /// meant; the finding was that the list was correct and the verb was wrong,
    /// so what changed is what the page *says*, not which rows it shows.
    func testTheLineCarriesBothHalvesOfTheAsymmetry() {
        let line = FederationHelp.whatMynahMayDoWithTheseAgents

        XCTAssertTrue(line.contains("send"), "the half Mynah can do went missing")
        XCTAssertTrue(line.contains("can't read"), "the half it cannot do went missing")
        XCTAssertTrue(
            line.range(of: "send")!.lowerBound < line.range(of: "can't read")!.lowerBound,
            "the line leads with the restriction, which reads as an apology"
        )
    }

    /// "subject", never "domain" — the owner-facing word for this everywhere in
    /// the product.
    func testItUsesTheOwnersWordForASubject() {
        let line = FederationHelp.whatMynahMayDoWithTheseAgents
        XCTAssertTrue(line.contains("subjects"))
        XCTAssertFalse(line.lowercased().contains("domain"))
    }

    /// The sidebar must not promise Mynah can query these agents. "Ask" is the
    /// exact word the owner objected to on the page, and leaving it in the
    /// sidebar would have kept the false promise one click earlier.
    func testTheSidebarClaimsPresenceRatherThanCapability() {
        let summary = MainSection.agents.summary
        XCTAssertFalse(
            summary.lowercased().contains("ask"),
            "the sidebar still says Mynah can ask these agents things"
        )
        XCTAssertFalse(summary.lowercased().contains("read"))
    }
}

// MARK: - Doubles

private struct FixedSubjects: AgentSubjectSource {
    let answers: [String: [String]]
    init(_ answers: [String: [String]]) { self.answers = answers }
    func subjects(forAgent id: String) async -> [String]? { answers[id] }
}

private actor CountingSubjects: AgentSubjectSource {
    private(set) var calls = 0
    func subjects(forAgent id: String) async -> [String]? {
        calls += 1
        return []
    }
}

private struct StubDirectory: AgentDirectorySource {
    func roster() async throws -> AgentRoster { .empty }
}

private struct StubScan: FederationScanning {
    func scan() async throws -> FederationReport { FederationReport() }
}
