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

/// **That the word on a chip is never mistaken for a name the node knows.**
///
/// The owner's report was "the what mynah remembers page — it loads for a long
/// time then errors", and the log had three different node messages behind it:
///
///     Query too broad: app-v23 authorization scan budget exceeded
///     domain name contains whitespace
///     domain not found: sage-v11-development
///
/// The last two share one cause. `Memory.topic` invented "General" for a memory
/// the node had filed under no domain, that invented word went into the filter
/// menu beside the real ones, and picking it sent `domain: "General"` to a node
/// with no such domain. The third message is the same mistake with a real name
/// in it — a domain belonging to a *different* agent on this Mac, offered as
/// one of Mynah's own topics.
///
/// So the fix is not a better sanitiser. It is that a label and a query key are
/// two different things, and this suite is what stops them becoming one string
/// again.
@MainActor
final class MemoryTopicFilterTests: XCTestCase {

    /// Answers whatever it is told to, and records every filter it was asked
    /// for — the filters are the point, so they are what it keeps.
    ///
    /// Every field is behind a lock, and that is a crash rather than a
    /// principle. `MemoriesModel` is `@MainActor`, but a store call is `async`
    /// and hops straight off it — so two loads overlap here whenever one is
    /// started before the other has finished, which is exactly what cancelling
    /// and replacing a load does. Cancellation does not unwind a request already
    /// in flight; it only means the answer is discarded when it arrives.
    ///
    /// This was `@unchecked Sendable` with plain `var`s, which is a promise it
    /// was not keeping. Two `askedLimits.append` calls landing together
    /// reallocated the same buffer twice and the process took a SIGSEGV inside
    /// `_swift_release_dealloc` — a segfault in the test double, reported
    /// against whichever test happened to be running.
    private final class Stub: MemoryStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var state = State()

        private struct State {
            var pages: [Int: MemoryPage] = [:]
            var tooBroadBelow: Int = 0
            var refuseFilters = false
            var askedFilters: [String?] = []
            var askedLimits: [Int] = []
        }

        var tooBroadBelow: Int {
            get { lock.withLock { state.tooBroadBelow } }
            set { lock.withLock { state.tooBroadBelow = newValue } }
        }

        /// Whatever filter is passed, the node will not resolve it.
        var refuseFilters: Bool {
            get { lock.withLock { state.refuseFilters } }
            set { lock.withLock { state.refuseFilters = newValue } }
        }

        var askedFilters: [String?] { lock.withLock { state.askedFilters } }
        var askedLimits: [Int] { lock.withLock { state.askedLimits } }

        init(_ memories: [Memory] = []) {
            state.pages[0] = MemoryPage(memories: memories, total: memories.count)
        }

        func recent(topic: String?, limit: Int, offset: Int) async throws -> MemoryPage {
            let answer: Result<MemoryPage, MemoryTrouble> = lock.withLock {
                state.askedFilters.append(topic)
                state.askedLimits.append(limit)
                if state.refuseFilters, topic != nil { return .failure(.unknownTopic) }
                if limit >= state.tooBroadBelow, state.tooBroadBelow > 0 { return .failure(.tooBroad) }
                return .success(state.pages[offset] ?? .empty)
            }
            return try answer.get()
        }

        func search(_ query: String, topic: String?, limit: Int) async throws -> MemoryPage {
            lock.withLock {
                state.askedFilters.append(topic)
                return state.pages[0] ?? .empty
            }
        }

        func forget(id: String) async throws -> ForgetOutcome { .forgotten }
    }

    private func memory(_ id: String, domain: String?) -> Memory {
        Memory(id: id, text: "something worth keeping", domain: domain,
               learned: .distantPast)
    }

    // MARK: The invented word

    /// A memory with no domain still needs a word in the column headed by what
    /// it is about. That word is a label and nothing else.
    func testAMemoryWithNoDomainStillReadsAsSomething() {
        XCTAssertEqual(memory("1", domain: nil).topic, "General")
        XCTAssertNil(memory("1", domain: nil).domain)
    }

    /// **The bug, as a test.** The invented word must not reach the filter menu,
    /// because everything in that menu goes back to the node as a domain.
    func testTheInventedWordIsNeverOfferedAsAFilter() async {
        let store = Stub([memory("1", domain: nil), memory("2", domain: "voice-interface")])
        let model = MemoriesModel(store: store)

        await model.load()

        XCTAssertEqual(model.topics, ["voice-interface"])
        XCTAssertFalse(model.topics.contains("General"), "the label got into the filter menu")
    }

    /// The node's own name goes through untouched — this must narrow the menu
    /// to real domains, not empty it.
    func testRealDomainsAreStillOffered() async {
        let store = Stub([
            memory("1", domain: "voice-interface"),
            memory("2", domain: "household"),
            memory("3", domain: "voice-interface")
        ])
        let model = MemoriesModel(store: store)

        await model.load()

        XCTAssertEqual(model.topics, ["household", "voice-interface"])
    }

    /// A domain that arrives padded goes back out padded, and the node rejects
    /// its own name with "domain name contains whitespace".
    func testAPaddedDomainIsTrimmedBeforeItCanBeSentBack() {
        let parsed = SageMemoryStore.memory(from: .object([
            "memory_id": .string("1"),
            "content": .string("something"),
            "domain": .string("  voice-interface  ")
        ]))
        XCTAssertEqual(parsed?.domain, "voice-interface")
    }

    /// A domain of nothing but whitespace is no domain, not a domain named "".
    func testAWhitespaceOnlyDomainIsNoDomainAtAll() {
        let parsed = SageMemoryStore.memory(from: .object([
            "memory_id": .string("1"),
            "content": .string("something"),
            "domain": .string("   ")
        ]))
        XCTAssertNil(parsed?.domain)
        XCTAssertEqual(parsed?.topic, "General")
    }

    // MARK: Narrowing rather than reporting

    /// The first page is asked for again, smaller, before the owner is told
    /// anything. Sixty is the size that fails on the owner's Mac.
    func testATooBroadFirstPageIsAskedForAgainSmaller() async {
        let store = Stub([memory("1", domain: "voice-interface")])
        store.tooBroadBelow = 60
        let model = MemoriesModel(store: store)

        await model.load()

        XCTAssertEqual(model.phase, .ready, "gave up instead of asking for fewer")
        XCTAssertEqual(store.askedLimits.first, 60)
        XCTAssertGreaterThan(store.askedLimits.count, 1, "only asked once")
        XCTAssertEqual(model.memories.count, 1)
    }

    /// When every size is refused the owner is told — and told to narrow it,
    /// which by then is advice this code has already taken three times.
    func testTheOwnerIsOnlyToldOnceEverySizeHasBeenRefused() async {
        let store = Stub()
        store.tooBroadBelow = 1
        let model = MemoriesModel(store: store)

        await model.load()

        XCTAssertEqual(model.phase, .failed(.tooBroad))
        XCTAssertEqual(store.askedLimits, [60, 20, 8])
    }

    // MARK: The filter that stopped resolving

    /// A dead filter is cleared rather than reported. The owner's only move was
    /// a click this code can perform itself, and the chip that caused it goes
    /// too — leaving it invites them to pick it and watch the same thing happen.
    func testADeadTopicFilterClearsItselfAndTakesTheChipWithIt() async {
        let store = Stub([memory("1", domain: "voice-interface")])
        let model = MemoriesModel(store: store)
        await model.load()
        XCTAssertEqual(model.topics, ["voice-interface"])

        // The node stops resolving that domain while it is the selected filter.
        store.refuseFilters = true
        model.topic = "voice-interface"
        await model.load()

        XCTAssertNil(model.topic, "the owner was left holding a filter that cannot succeed")
        XCTAssertFalse(
            model.topics.contains("voice-interface"),
            "the chip that caused it is still in the menu"
        )
        // And it must not come back. The memories still report that domain, so
        // the next successful load merges the name straight back in unless
        // something remembers the node's refusal — this assertion is why
        // `unresolvableTopics` exists, and it caught the flicker in a full run
        // after passing on its own.
        await settle(model)
        XCTAssertFalse(
            model.topics.contains("voice-interface"),
            "the dead chip came back with the next successful load"
        )
        // Settled rather than sampled. Assigning `topic` starts a load of its
        // own through the property's `didSet`, so the instant this line is
        // reached there may legitimately be one in flight — asserting on that
        // instant tests the scheduler, not the repair.
        await settle(model)
        XCTAssertEqual(model.phase, .ready, "an error screen for a problem with a one-click fix")
    }

    /// Waits for the screen to stop loading. Bounded, so a model that never
    /// settles fails the assertion that follows instead of hanging the suite.
    private func settle(_ model: MemoriesModel) async {
        for _ in 0..<500 {
            if model.phase != .loading { return }
            await Task.yield()
        }
    }
}
#endif  // os(macOS)
