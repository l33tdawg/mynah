// **Mac-only, because it tests `MynahMac`.**
//
// `MynahMac` is the AppKit/SwiftUI half of this package, and Package.swift does
// not declare that target off Darwin — so the import below resolves on a Mac
// and nowhere else. The guard wraps the whole file rather than just the import,
// because every test in here drives a Mac type: a file that compiled down to an
// empty test class would let Linux report a green suite that ran nothing, which
// is the exact failure this branch exists to stop. See `coreTestDependencies`
// in Package.swift.
#if os(macOS)
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
               learned: .distantPast)
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

/// **That the subject colours stay colours and never become verdicts.**
///
/// The owner asked for colour on the subject chips, and colour in this app has
/// so far meant exactly one thing per hue: green is "stays on this Mac", amber
/// is "words leave this Mac", red is "this failed". A subject tint means
/// identity — "these two rows are filed in the same place" — which is a
/// different axis, and the two must not be confusable on a screen where both
/// appear.
@MainActor
final class SubjectTintTests: XCTestCase {

    /// **The one that matters.** Swift seeds `Hashable` per process, so a naive
    /// implementation gives a subject one colour today and another after a
    /// relaunch — worse than no colour, because the owner would have learned
    /// something that then stopped being true.
    func testASubjectKeepsItsColourBetweenLaunches() {
        // Precomputed FNV-1a. If the algorithm changes, every chip changes
        // colour, so this is pinned rather than recomputed from the code.
        XCTAssertEqual(SubjectTint.stableHash(""), 0xcbf2_9ce4_8422_2325)
        XCTAssertEqual(SubjectTint.stableHash("a"), 0xaf63_dc4c_8601_ec8c)

        // And the property that actually reaches the screen.
        let subjects = ["voice-interface", "Mynah's own", "Home", "Travel", "General"]
        for subject in subjects {
            XCTAssertEqual(
                SubjectTint.hueDegrees(for: subject),
                SubjectTint.hueDegrees(for: subject),
                "\(subject) does not resolve to a stable hue"
            )
        }
    }

    /// No tint may land in a band that already means something. A subject drawn
    /// in amber is a warning on a row that is fine; one drawn in green is the
    /// "stays on this Mac" promise being made about a filing cabinet.
    func testNoSubjectTintCanBeMistakenForAVerdict() {
        for hue in SubjectTint.hues {
            XCTAssertFalse(
                (0...60).contains(hue),
                "\(hue)° is in the red/amber band, where colour already means trouble"
            )
            XCTAssertFalse(
                (95...165).contains(hue),
                "\(hue)° is in the green band, where colour already means it stays on this Mac"
            )
        }
    }

    /// Adjacent entries must be tellable apart, or the palette is decoration
    /// rather than information.
    func testTheHuesAreFarEnoughApartToTellApart() {
        for (index, hue) in SubjectTint.hues.enumerated() {
            let next = SubjectTint.hues[(index + 1) % SubjectTint.hues.count]
            let apart = min(abs(hue - next), 360 - abs(hue - next))
            XCTAssertGreaterThanOrEqual(
                apart, 20,
                "\(hue)° and \(next)° are neighbours in the table and look the same"
            )
        }
    }

    /// The node's own marker is read once, here, rather than by the owner on
    /// every row — and the sentence they read no longer carries it.
    func testATaskIsRecognisedAndItsMarkerStripped() {
        let task = Memory(
            id: "1", text: "[TASK] Book hotel for Wednesday",
            domain: nil, learned: .distantPast
        )
        XCTAssertEqual(task.kind, .task)
        XCTAssertEqual(task.displayText, "Book hotel for Wednesday")

        let remembered = Memory(
            id: "2", text: "Prefers the 6am departure",
            domain: nil, learned: .distantPast
        )
        XCTAssertEqual(remembered.kind, .remembered)
        XCTAssertEqual(remembered.displayText, "Prefers the 6am departure",
                       "a plain memory had its own words trimmed")
    }
}
#endif  // os(macOS)
