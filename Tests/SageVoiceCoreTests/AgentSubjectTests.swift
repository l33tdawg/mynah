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
    func testTheLineSeparatesSeeingFromReading() throws {
        let line = FederationHelp.whatMynahMayDoWithTheseAgents.lowercased()

        // The distinction that took four attempts to get right, and the one
        // that will be lost first if anybody shortens this.
        //
        // Mynah *sees* every subject — `sage_status` returns ~700 names and
        // their sizes to any signed caller and reads no content at all. It
        // *reads* only the ones nobody owns. Collapsing the two is exactly what
        // happened when it recited a directory to the owner and three of us
        // concluded it had read the contents.
        let sees = try XCTUnwrap(line.range(of: "see"), "the line no longer says what it can see")
        let reads = try XCTUnwrap(line.range(of: "read"), "the line no longer says what it can read")
        XCTAssertTrue(
            sees.lowerBound < reads.lowerBound,
            "seeing has to come first, or reading is what the sentence appears to widen"
        )

        // The closed half, in whatever words. Without it the line reads as
        // "Mynah reads this Mac", which is the version we shipped and had to
        // take back.
        XCTAssertTrue(
            line.contains("closed") || line.contains("can't") || line.contains("cannot"),
            "the line no longer says anything is closed to it"
        )
    }

    /// The ageing clause, which is the property every failed version lacked.
    ///
    /// A grant landing must make this sentence **stale, not false**: it should
    /// understate what Mynah can do rather than misdescribe it. "Unless that
    /// agent shares it" does that — the day something is shared, the sentence
    /// already covered it. Three versions today were true on a Tuesday and
    /// false on a Wednesday, which is the failure mode this pins.
    func testTheLineStaysTrueAfterAGrantIsMade() {
        let line = FederationHelp.whatMynahMayDoWithTheseAgents.lowercased()

        XCTAssertTrue(
            line.contains("unless"),
            "the line describes today's grants as permanent, so a new one makes it false"
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

/// The roster, fetched once at boot.
///
/// The owner's ruling — *"you only see the agents you can actually talk to"* —
/// after he caught the page showing twenty cards beside a Mynah that told him
/// over Signal it could see nobody.
@MainActor
final class ApplianceRosterTests: XCTestCase {

    /// **The distinction the whole type exists for.**
    ///
    /// A boot fetch that failed means the app does not know who is out there.
    /// An empty roster means it asked and there is nobody. Collapsing them is
    /// the substitution this codebase has spent a day removing, and the one the
    /// owner has caught himself twice.
    func testAFailedFetchIsUnavailableRatherThanEmpty() async {
        let store = ApplianceRoster(source: FailingDirectory())

        await store.loadOnce()

        guard case .unavailable = store.phase else {
            return XCTFail("a roster nobody could fetch is being reported as a fact")
        }
        XCTAssertNotEqual(store.phase, .ready(.empty), "unavailable collapsed into empty")
    }

    /// And a node with nobody on it is a real answer, distinct from the above.
    func testAnEmptyNodeIsAnAnswerAndNotAFailure() async {
        let store = ApplianceRoster(source: FixedDirectory(.empty))

        await store.loadOnce()

        XCTAssertEqual(store.phase, .ready(.empty))
    }

    /// Before boot has run the store says nothing at all. A screen that has not
    /// asked must not answer.
    func testNothingIsClaimedBeforeBootHasRun() {
        XCTAssertEqual(ApplianceRoster(source: FailingDirectory()).phase, .notAsked)
    }

    /// **Not a per-view read.** Opening the page a dozen times asks the node
    /// once — the whole point of moving this to boot.
    func testASuccessfulFetchIsNeverRepeated() async {
        let source = CountingDirectory()
        let store = ApplianceRoster(source: source)

        await store.loadOnce()
        await store.loadOnce()
        await store.loadOnce()

        let asks = await source.calls
        XCTAssertEqual(asks, 1, "the roster is being re-fetched, which is what boot-time replaced")
    }

    /// A boot that failed *is* retryable, though — the node may still have been
    /// starting up, and a slow launch must not cost the owner the roster for
    /// the whole session.
    func testAFailedFetchCanBeAskedAgain() async {
        let source = CountingDirectory(failing: true)
        let store = ApplianceRoster(source: source)

        await store.loadOnce()
        await store.loadOnce()

        let asks = await source.calls
        XCTAssertEqual(asks, 2, "a failed boot left the owner with no way to try again")
    }
}

private struct FailingDirectory: AgentDirectorySource {
    func roster() async throws -> AgentRoster { throw AgentTrouble.unreachable }
}

private struct FixedDirectory: AgentDirectorySource {
    let value: AgentRoster
    init(_ value: AgentRoster) { self.value = value }
    func roster() async throws -> AgentRoster { value }
}

private actor CountingDirectory: AgentDirectorySource {
    private(set) var calls = 0
    private let failing: Bool
    init(failing: Bool = false) { self.failing = failing }
    func roster() async throws -> AgentRoster {
        calls += 1
        if failing { throw AgentTrouble.unreachable }
        return .empty
    }
}

/// What an empty screen is allowed to claim.
///
/// `thread`'s rule, from the measurements: **a result set that has been
/// silently narrowed must never be presented as a complete answer to the
/// question that was asked.**
///
/// Three shapes were measured as the appliance. Naming a subject it cannot read
/// gives a clean refusal — loud and fine. Naming one another agent owns gives
/// `0 of 0`, so closed presents as empty. Naming nothing silently filters to
/// what it may read, with no signal that anything was excluded.
@MainActor
final class EmptyStateHonestyTests: XCTestCase {

    /// A search that found nothing must not blame the owner's wording, because
    /// rephrasing cannot reach a subject the search was never allowed into.
    func testAnEmptySearchSaysItOnlyCoveredWhatMynahCanRead() {
        XCTAssertTrue(
            MemoriesEmpty.searchMessage.contains("however you word it"),
            "the owner is being sent to rephrase a query that could not have worked"
        )
        XCTAssertTrue(MemoriesEmpty.searchTitle.contains("can read"))
    }

    /// A subject with nothing in it and a subject somebody else owns are the
    /// same picture, and the screen must not pick the reassuring one.
    func testAnEmptySubjectDoesNotClaimNothingIsThere() {
        XCTAssertTrue(
            MemoriesEmpty.subjectMessage.contains("cannot tell which"),
            "the screen claims to know which of the two situations it is in"
        )
        XCTAssertFalse(MemoriesEmpty.subjectMessage.contains("hasn't learned anything"))
    }

    /// **No invented precision.** How much a query was narrowed by is a number
    /// SAGE does not return and an open request to that team. A count we cannot
    /// obtain must not appear, even softened.
    func testNoEmptyStateImpliesACountItCannotObtain() {
        for message in [MemoriesEmpty.searchMessage, MemoriesEmpty.subjectMessage] {
            for invented in ["subjects were excluded", "of your subjects", "some subjects are hidden"] {
                XCTAssertFalse(
                    message.contains(invented),
                    "a filtered count the API never gives us: \(invented)"
                )
            }
        }
    }

    /// **This suite used to grep the source, and one of its checks was watching
    /// nothing.** The sentence it looked for is three string segments in the
    /// file and never appears contiguously, so the assertion could only ever
    /// have failed for the wrong reason. Values now, per team-lead's rule: a
    /// test that greps source is testing the wrong thing, and its failure mode
    /// is silence rather than red.
    func testTheseAreValuesRatherThanSourceGreps() {
        XCTAssertFalse(MemoriesEmpty.searchMessage.isEmpty)
        XCTAssertFalse(MemoriesEmpty.subjectMessage.isEmpty)
    }
}
