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
@testable import SageVoiceCore

/// **The worst bug this screen has had, and it shipped in the shelf that was
/// meant to make it safer.**
///
/// Adding the Files shelf left `shown` as `shelf == .tasks ? tasks : memories`,
/// so `.files` fell through to *every* memory. Three things then lined up:
///
///  - `mynahOwned` filters `shown`, so it was every memory Mynah owns —
///    including the whole task list;
///  - the Forget-all control renders whenever that is non-empty, so it appeared
///    on a tab listing photos;
///  - `isFiltered` is true on any shelf but All, which **suppresses the second
///    confirmation** and switches the dialog to the scoped wording.
///
/// So: open Memories to delete one photo, press a button offering to tidy up,
/// answer a dialog reading "Forget the ones shown?" — and lose every task,
/// appointment and preference the appliance holds. One click, one confirmation,
/// and the sentence on the dialog was the opposite of what happened.
///
/// Found by the re-audit, reported independently by four of six lenses.
@MainActor
final class ForgetScopeOnFilesTests: XCTestCase {

    private func model() -> MemoriesModel {
        MemoriesModel(store: FilesShelfStore(holding: [
            Self.memory("task-1", text: "[TASK] Book the hotel"),
            Self.memory("task-2", text: "[TASK] Send the car in"),
            Self.memory("memory-1", text: "He prefers the aisle seat"),
        ]))
    }

    /// The regression, stated as the loss it would have caused.
    func testTheFilesShelfOffersNothingToForget() async {
        let model = model()
        await model.load()
        XCTAssertFalse(model.mynahOwned.isEmpty, "the fixture is empty, so this proves nothing")

        model.shelf = .files

        XCTAssertEqual(
            model.mynahOwned, [],
            """
            "Forget all Mynah's" is armed on the Files shelf and would deprecate \
            \(model.mynahOwned.count) memories — the owner's entire task list — \
            from a screen that lists photos
            """
        )
        XCTAssertEqual(model.shown, [], "the Files shelf is not a shelf of memories")
    }

    /// And the other two shelves still work, so this is not "return nothing".
    func testTheOtherShelvesStillOfferWhatTheyShow() async {
        let model = model()
        await model.load()

        XCTAssertEqual(model.mynahOwned.count, 3, "All must still offer everything Mynah owns")

        model.shelf = .tasks
        XCTAssertEqual(
            Set(model.mynahOwned.map(\.id)), ["task-1", "task-2"],
            "Tasks must still scope the clear to tasks"
        )
    }

    /// **The confirmation is the other half and must not be relied on alone.**
    ///
    /// `isFiltered` is what suppresses the second question, and it is true on
    /// Files. Pinned here so a future change that puts memories back on this
    /// shelf cannot quietly inherit the single-confirmation path.
    func testFilesStillCountsAsFilteredSoNothingRestsOnTheDialogAlone() async {
        let model = model()
        await model.load()
        model.shelf = .files

        XCTAssertTrue(model.isFiltered)
        XCTAssertFalse(
            model.clearingNeedsSecondConfirmation,
            """
            a shelf is a filter, so this is correct — which is exactly why the \
            emptiness of mynahOwned above has to be what protects the task list, \
            not the dialog
            """
        )
    }

    private static func memory(_ id: String, text: String) -> Memory {
        Memory(id: id, text: text, domain: "mynah-home", learned: Date())
    }
}

private final class FilesShelfStore: MemoryStoring, @unchecked Sendable {
    private let holding: [Memory]
    init(holding: [Memory]) { self.holding = holding }

    func recent(topic: String?, limit: Int, offset: Int) async throws -> MemoryPage {
        MemoryPage(memories: holding, total: holding.count)
    }
    func search(_ query: String, topic: String?, limit: Int) async throws -> MemoryPage {
        MemoryPage(memories: holding, total: holding.count)
    }
    func forget(id: String) async throws -> ForgetOutcome { .forgotten }
    func domainsMynahOwns() async -> [String] { ["mynah-home"] }
}
#endif  // os(macOS)
