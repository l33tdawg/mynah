import XCTest
@testable import MynahMac
@testable import SageVoiceCore

/// **What "clear" clears, and when it asks twice.**
///
/// The owner: *"the filter is already there, we should add a logic then when its
/// filtered, and i click clear all, it clears the ones filtered ONLY and not
/// everything -- if the user is on the main memories without filter, clicks
/// clear memories, we should warn first to get double confirmation they know the
/// impact is it will wipe all tasks etc"*.
///
/// The scoping half was already true and completely invisible: the bulk clear
/// walks the loaded list, and the loaded list is whatever the filter fetched.
/// Nothing on screen said so. A destructive button whose blast radius has to be
/// inferred from the implementation is one nobody should press, so these assert
/// the rule rather than leaving it as an accident of how paging happens to work.
@MainActor
final class MemoryClearScopeTests: XCTestCase {

    private func model() -> MemoriesModel {
        MemoriesModel(store: StubMemoryStore())
    }

    // MARK: When it asks twice

    /// Nothing narrowed: clearing takes the task list with it, so it is asked
    /// twice.
    func testClearingEverythingNeedsASecondQuestion() {
        let model = model()

        XCTAssertFalse(model.isFiltered)
        XCTAssertTrue(model.clearingNeedsSecondConfirmation)
    }

    /// A search narrows it, and clearing a search result is an ordinary act.
    func testASearchMakesItASingleQuestion() {
        let model = model()
        model.searchText = "ferry"

        XCTAssertTrue(model.isFiltered)
        XCTAssertFalse(model.clearingNeedsSecondConfirmation)
    }

    /// So does a subject.
    func testASubjectMakesItASingleQuestion() {
        let model = model()
        model.topic = "release-updater-safety"

        XCTAssertTrue(model.isFiltered)
        XCTAssertFalse(model.clearingNeedsSecondConfirmation)
    }

    /// Whitespace is not a filter. " " in the search box narrows nothing, and
    /// treating it as a filter would skip the second question over a full list.
    func testWhitespaceIsNotAFilter() {
        let model = model()
        model.searchText = "   "

        XCTAssertFalse(model.isFiltered, "a blank search must not downgrade the warning")
        XCTAssertTrue(model.clearingNeedsSecondConfirmation)
    }

    /// Clearing the search restores the second question. The dangerous state is
    /// reachable by *removing* a filter, which is the direction nobody tests.
    func testRemovingTheFilterRestoresTheSecondQuestion() {
        let model = model()
        model.searchText = "ferry"
        XCTAssertFalse(model.clearingNeedsSecondConfirmation)

        model.searchText = ""
        XCTAssertTrue(model.clearingNeedsSecondConfirmation)

        model.topic = "release-updater-safety"
        XCTAssertFalse(model.clearingNeedsSecondConfirmation)

        model.topic = nil
        XCTAssertTrue(model.clearingNeedsSecondConfirmation)
    }

    // MARK: What counts as Mynah's

    /// **A third owned domain.** The list and the search were scoped by asking
    /// `sage_domains`; `isMynahs` — which decides whether a card gets a Forget
    /// cross, and what "forget everything Mynah owns" walks — kept comparing
    /// against a hardcoded pair.
    ///
    /// So a domain the node says this appliance owns would be fetched, listed and
    /// displayed, and then have no Forget control on it, and be skipped by the
    /// bulk clear. The owner would be looking at Mynah's own memory with no way
    /// to remove it and no reason given.
    ///
    /// Driven through a node that names three, because two is the number the
    /// constant already had: a stub owning only the known pair would pass against
    /// the bug.
    func testADomainTheNodeNamesIsMynahsEvenThoughItWasNeverHardcoded() async {
        let store = StubMemoryStore(
            owns: ["voice-interface", "mynah-home", "mynah-invoices"],
            holding: [
                Self.memory("mine-new", domain: "mynah-invoices"),
                Self.memory("mine-known", domain: "voice-interface"),
                Self.memory("theirs", domain: "sage-team-notes"),
            ]
        )
        let model = MemoriesModel(store: store)
        await model.load()

        XCTAssertEqual(
            Set(model.mynahOwned.map(\.id)), ["mine-new", "mine-known"],
            """
            the owned set is not the node's. Everything Mynah owns must be \
            offered, and nothing else may be: \(model.mynahOwned.map(\.id))
            """
        )
    }

    /// And a node that says nothing leaves Mynah's own home working, rather than
    /// stripping every Forget control off the screen.
    ///
    /// **The fixture used to put "mine" in `voice-interface`, and that was the
    /// bug.** That subject belongs to the developer's own agent — readable by
    /// this appliance, absent from its `writable_domains` — and the fallback
    /// list named it, so on a node that would not answer the Memories page
    /// offered the owner a Forget cross on another agent's memories. Precisely
    /// the harm `MynahOwnedDomains` says in its own comment that it exists to
    /// prevent. The owner, 5 August: *"voice-interface is YOUR DOMAIN - we will
    /// transfer it back to you"*.
    func testANodeThatWillNotAnswerStillLeavesItsOwnHomeForgettable() async {
        let store = StubMemoryStore(
            owns: [],
            holding: [
                Self.memory("mine", domain: "mynah-home"),
                Self.memory("theirs", domain: "sage-team-notes"),
                Self.memory("the developers", domain: "voice-interface"),
            ]
        )
        let model = MemoriesModel(store: store)
        await model.load()

        XCTAssertEqual(
            Set(model.mynahOwned.map(\.id)), ["mine"],
            "a node that could not answer took the Forget control away from Mynah's own memories"
        )
        XCTAssertFalse(
            model.mynahOwned.map(\.id).contains("the developers"),
            "a fallback must never offer a Forget cross on a subject belonging to another agent"
        )
    }

    // MARK: The shelf

    /// **Tasks only shows tasks.** The owner, with a screenshot: *"we should
    /// have a filter on this page -> all / tasks only"*.
    func testTheTasksShelfShowsOnlyTasks() async {
        let model = MemoriesModel(store: StubMemoryStore(
            owns: ["mynah-home"],
            holding: [
                Self.memory("a-task", domain: "mynah-home", text: "[TASK] Book the hotel"),
                Self.memory("a-memory", domain: "mynah-home", text: "He prefers the aisle seat"),
            ]
        ))
        await model.load()

        XCTAssertEqual(Set(model.shown.map(\.id)), ["a-task", "a-memory"], "All is not showing everything")

        model.shelf = .tasks
        XCTAssertEqual(
            model.shown.map(\.id), ["a-task"],
            "the Tasks shelf is showing things that are not tasks: \(model.shown.map(\.id))"
        )
        XCTAssertEqual(model.visibleCount, 1, "the count still describes the unfiltered list")
    }

    /// And narrowing to Tasks scopes the bulk clear, exactly as a subject does.
    ///
    /// The owner's rule for this page, stated when the subject filter arrived:
    /// *"when its filtered, and i click clear all, it clears the ones filtered
    /// ONLY and not everything"*. A shelf is a filter.
    func testForgetAllOnTheTasksShelfLeavesPlainMemoriesAlone() async {
        let model = MemoriesModel(store: StubMemoryStore(
            owns: ["mynah-home"],
            holding: [
                Self.memory("a-task", domain: "mynah-home", text: "[TASK] Book the hotel"),
                Self.memory("a-memory", domain: "mynah-home", text: "He prefers the aisle seat"),
            ]
        ))
        await model.load()
        model.shelf = .tasks

        XCTAssertTrue(model.isFiltered, "a shelf that narrows the list did not count as filtered")
        XCTAssertFalse(
            model.clearingNeedsSecondConfirmation,
            "narrowing to tasks and clearing is a scoped act, not the everything-goes one"
        )
        XCTAssertEqual(
            model.mynahOwned.map(\.id), ["a-task"],
            """
            Forget all on the Tasks shelf would have taken plain memories with \
            it: \(model.mynahOwned.map(\.id))
            """
        )
    }

    private static func memory(
        _ id: String,
        domain: String,
        text: String = "something"
    ) -> Memory {
        Memory(id: id, text: "\(text) (\(id))", domain: domain, learned: Date())
    }
}

/// A store that answers without a node, so the model can be built at all.
///
/// `owns` is what `sage_domains` would say. Empty means the node would not
/// answer, which is a case with its own test above — the fallback has to keep
/// the screen usable rather than blanking every control on it.
private final class StubMemoryStore: MemoryStoring, @unchecked Sendable {
    private let owns: [String]
    private let holding: [Memory]

    init(owns: [String] = [], holding: [Memory] = []) {
        self.owns = owns
        self.holding = holding
    }

    func recent(topic: String?, limit: Int, offset: Int) async throws -> MemoryPage {
        MemoryPage(memories: holding, total: holding.count)
    }

    func search(_ query: String, topic: String?, limit: Int) async throws -> MemoryPage {
        MemoryPage(memories: holding, total: holding.count)
    }

    func forget(id: String) async throws -> ForgetOutcome { .forgotten }

    func domainsMynahOwns() async -> [String] { owns }
}
