import XCTest
@testable import MynahMac

/// **That leaving Memories and coming back costs nothing visible.**
///
/// *"we should also cache the memory page so we don't fucking refresh each and
/// every time — or only the new ones are added / old ones removed when the user
/// moves into that memories panel."*
///
/// `RootView` builds `MemoriesView` fresh out of a `switch`, so a model owned by
/// the view was destroyed on the way out and rebuilt empty on the way in: a node
/// round trip, a blank screen and every card redrawn, per visit. Nothing was
/// wrong with the loading code — it was being asked to start from nothing each
/// time.
@MainActor
final class MemoryCachingTests: XCTestCase {

    /// Serves whatever page it is currently holding, and counts how often it was
    /// asked. The count is the point: this suite is about work *not* done.
    private final class Stub: MemoryStoring, @unchecked Sendable {
        var page: MemoryPage
        var failNext = false
        private(set) var recentCalls = 0

        init(_ memories: [Memory]) {
            page = MemoryPage(memories: memories, total: memories.count)
        }

        func serve(_ memories: [Memory]) {
            page = MemoryPage(memories: memories, total: memories.count)
        }

        func recent(topic: String?, limit: Int, offset: Int) async throws -> MemoryPage {
            recentCalls += 1
            if failNext {
                failNext = false
                throw MemoryTrouble.unreachable
            }
            // Only the first page is modelled; "Show more" is exercised by
            // handing the model a longer list up front.
            return offset == 0 ? page : .empty
        }

        func search(_ query: String, topic: String?, limit: Int) async throws -> MemoryPage {
            page
        }

        func forget(id: String) async throws -> ForgetOutcome { .forgotten }
    }

    private func memory(_ id: String) -> Memory {
        Memory(id: id, text: "kept: \(id)", domain: nil,
               learned: .distantPast, certainty: .certain)
    }

    private func settle(_ model: MemoriesModel) async {
        for _ in 0..<500 {
            if model.phase != .loading { return }
            await Task.yield()
        }
    }

    /// Re-entering does not empty the screen. This is the whole complaint: the
    /// list must never go back to `.loading` once it has content.
    func testComingBackDoesNotBlankTheList() async {
        let store = Stub([memory("a"), memory("b")])
        let model = MemoriesModel(store: store)

        await model.loadIfNeeded()
        await settle(model)
        XCTAssertEqual(model.memories.count, 2)

        // Second visit.
        await model.loadIfNeeded()
        XCTAssertEqual(model.phase, .ready, "the screen emptied itself on the way back in")
        XCTAssertEqual(model.memories.count, 2, "and rebuilt the list from nothing")
    }

    /// Nothing changed at the node, so nothing changes here — not even an
    /// identical reassignment, which still invalidates the view and redraws
    /// every card. That redraw *is* the flicker being removed.
    func testAnUnchangedRefreshLeavesTheArrayAlone() async {
        let store = Stub([memory("a"), memory("b")])
        let model = MemoriesModel(store: store)
        await model.loadIfNeeded()
        await settle(model)

        let before = model.memories
        await model.loadIfNeeded()

        XCTAssertEqual(model.memories, before, "the rows changed when nothing had")
    }

    /// The other half of what was asked for: a quiet cache is a stale one, so
    /// re-entry still notices.
    func testANewMemoryArrivesOnTheNextVisit() async {
        let store = Stub([memory("a")])
        let model = MemoriesModel(store: store)
        await model.loadIfNeeded()
        await settle(model)

        store.serve([memory("b"), memory("a")])
        await model.loadIfNeeded()

        XCTAssertEqual(model.memories.map(\.id), ["b", "a"], "a new memory never showed up")
    }

    func testAForgottenMemoryIsGoneOnTheNextVisit() async {
        let store = Stub([memory("a"), memory("b")])
        let model = MemoriesModel(store: store)
        await model.loadIfNeeded()
        await settle(model)

        store.serve([memory("b")])
        await model.loadIfNeeded()

        XCTAssertEqual(model.memories.map(\.id), ["b"], "a forgotten memory is still on screen")
    }

    /// **A refresh must never delete the bottom of the list.**
    ///
    /// After "Show more" the owner holds rows the first page was never asked
    /// about. Treating that page as the whole truth would drop everything below
    /// it on every visit — a cache fix that eats the thing being cached.
    func testAFirstPageRefreshDoesNotTruncateRowsPagedInBelowIt() async {
        // More than one page's worth, so the additive branch is the one taken.
        let held = (0..<80).map { memory("m\($0)") }
        let store = Stub(held)
        let model = MemoriesModel(store: store)
        await model.loadIfNeeded()
        await settle(model)
        XCTAssertGreaterThan(model.memories.count, 60, "the fixture did not exceed one page")

        // The node answers with a short first page carrying one new memory.
        store.serve([memory("brand-new"), memory("m0")])
        await model.loadIfNeeded()

        XCTAssertEqual(model.memories.first?.id, "brand-new", "the new memory did not arrive")
        XCTAssertEqual(
            model.memories.count, held.count + 1,
            "the refresh threw away rows the owner had paged in"
        )
    }

    /// A background refresh the owner never asked for must not turn a working
    /// screen into an error screen.
    func testAFailedRefreshKeepsWhatIsOnScreen() async {
        let store = Stub([memory("a"), memory("b")])
        let model = MemoriesModel(store: store)
        await model.loadIfNeeded()
        await settle(model)

        store.failNext = true
        await model.loadIfNeeded()

        XCTAssertEqual(model.phase, .ready, "a background failure was reported as the owner's problem")
        XCTAssertEqual(model.memories.count, 2, "and took the rows with it")
    }

    /// The first visit still does a real load — the cache must not swallow it.
    func testTheFirstVisitStillLoads() async {
        let store = Stub([memory("a")])
        let model = MemoriesModel(store: store)

        await model.loadIfNeeded()
        await settle(model)

        XCTAssertEqual(store.recentCalls, 1)
        XCTAssertEqual(model.memories.count, 1)
    }
}
