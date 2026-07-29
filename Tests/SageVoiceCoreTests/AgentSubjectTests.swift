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

    /// **This test asserted the false claim, and that is the finding.**
    ///
    /// The first version required the line to contain "can't read", because the
    /// briefing said reading needed a grant. It does not: mask 30 is four write
    /// and pipe denials, and an ordinary signed agent reads the whole node —
    /// 13,372 memories across some 700 subjects, checked by running it.
    ///
    /// So a test written to protect a sentence pinned it in place instead, and
    /// would have failed anybody who corrected it. **A test is only as true as
    /// the fact it encodes**, and one that asserts a *specific wrong sentence*
    /// is worse than no test — it turns a mistake into a rule.
    ///
    /// It now asserts the shape rather than the wording: both halves present,
    /// capability before restriction so the line reads as a description rather
    /// than an apology, and the restriction is about *writing*. `thread` owns
    /// the words and can change all of them without touching this.
    func testTheLineCarriesBothHalvesOfTheAsymmetry() throws {
        let line = FederationHelp.whatMynahMayDoWithTheseAgents

        // The restriction is found by "can't" rather than by a verb. `thread`
        // writes "save", not "write", because that is the owner's word for it —
        // and pinning a verb they chose is how the last version of this test
        // ended up defending a sentence instead of a fact.
        let reads = try XCTUnwrap(line.range(of: "can read"), "the half Mynah can do went missing")
        let cannot = try XCTUnwrap(line.range(of: "can't"), "the half it cannot do went missing")
        XCTAssertTrue(
            reads.lowerBound < cannot.lowerBound,
            "the line leads with what Mynah cannot do, which reads as an apology"
        )
    }

    /// **Two tests stood here and both defended a false claim. I wrote them an
    /// hour after warning, in this file, about exactly this.**
    ///
    /// One forbade every phrasing of "Mynah can't read". The other — added at
    /// team-lead's request, and a good request — *required* the page to say
    /// Mynah **can** read, so a later tidy-up could not quietly drop that half.
    /// Together they made the false version the only version that compiled.
    ///
    /// The claim was wrong. Reads are gated per domain: `sage_list` against
    /// this agent's own subject returns 60 memories with content; against
    /// `exploit-patterns` or `general` it returns "Access denied". `sage_status`
    /// looked like proof and is not — it returns subject *names* and counts,
    /// needs no read access at all, and is what Mynah recited to the owner. A
    /// table of contents, read as proof it had read the book.
    ///
    /// I had already written here that *"a test that asserts a specific wrong
    /// sentence is worse than no test — it turns a mistake into a rule."* Then
    /// I did it, in the same file, on the same subject, twice. So the lesson
    /// that generalises is narrower and less comfortable: **a test can only pin
    /// a fact somebody has verified, and "we all agreed" is not verification.**
    /// Three of us agreed on this one, and two of us had run the same
    /// non-evidence to confirm it.
    ///
    /// Nothing replaces them. The property worth holding — both halves present,
    /// capability before restriction — is already covered above, and it is the
    /// one that survived being wrong in both directions.

    /// "subject", never "domain" — the owner-facing word for this everywhere in
    /// the product.
    func testItUsesTheOwnersWordForASubject() {
        XCTAssertFalse(
            FederationHelp.whatMynahMayDoWithTheseAgents.lowercased().contains("domain")
        )
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
