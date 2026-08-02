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
}

/// A store that answers without a node, so the model can be built at all.
private final class StubMemoryStore: MemoryStoring, @unchecked Sendable {
    func recent(topic: String?, limit: Int, offset: Int) async throws -> MemoryPage {
        MemoryPage(memories: [], total: 0)
    }

    func search(_ query: String, topic: String?, limit: Int) async throws -> MemoryPage {
        MemoryPage(memories: [], total: 0)
    }

    func forget(id: String) async throws -> ForgetOutcome { .forgotten }
}
