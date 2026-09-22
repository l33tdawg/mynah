import XCTest
@testable import SageVoiceCore

/// **A listing is not a list, and SAGE 11.23.x says so in the tool's own
/// description.** *"This listing is PAGED: one call is never the whole board…
/// page with `offset` until has_more is false before claiming you have seen
/// every task. `scan_capped` means the node stopped scanning at its bound."*
///
/// Nothing in this appliance re-reads a tool description, so the sentence was
/// found by diffing the vendored brain's published schemas against the newer
/// one during the 11.19.22 → 11.23.7 bump. Two readers were taking whatever came
/// back as everything, and for one of them that is the 6 August calendar
/// failure with the sign flipped: every task past the first page reads as having
/// just been completed, and the mirror deletes their events.
///
/// What is asserted here is the rule that replaces it: **a read that cannot be
/// shown to be complete is not a read.**
final class SageBacklogPagesTests: XCTestCase {

    /// One page of a backlog, in the node's own shape.
    private func page(
        ids: [String],
        total: Int,
        hasMore: Bool = false,
        nextOffset: Int? = nil,
        scanCapped: Bool = false
    ) -> String {
        let rows = ids.map {
            #"{"memory_id":"\#($0)","content":"[TASK] \#($0)","task_status":"planned"}"#
        }.joined(separator: ",")
        var members = [
            #""tasks_by_domain":{"mynah-home":[\#(rows)]}"#,
            #""total_open":\#(total)"#
        ]
        if hasMore { members.append(#""has_more":true"#) }
        if let nextOffset { members.append(#""next_offset":\#(nextOffset)"#) }
        if scanCapped { members.append(#""scan_capped":true"#) }
        return "{\(members.joined(separator: ","))}"
    }

    // MARK: The envelope

    /// What 11.23.7 actually answers on this Mac: everything, a count, and no
    /// paging fields at all. It has to read as complete, or this appliance would
    /// go quiet about a node it can read perfectly.
    func testTheShapeTheNodeAnswersTodayIsComplete() throws {
        let reading = try XCTUnwrap(SageBacklogReply.read(page(ids: ["a1", "a2"], total: 2)))

        XCTAssertEqual(reading.continuation(afterReading: reading.returned), .complete)
    }

    func testAStatementThatThereIsMoreIsBelieved() throws {
        let reading = try XCTUnwrap(
            SageBacklogReply.read(page(ids: ["a1"], total: 4, hasMore: true, nextOffset: 1))
        )

        XCTAssertEqual(
            reading.continuation(afterReading: reading.returned),
            .more(["limit": .int(SageBacklogReply.pageSize), "offset": .int(1)])
        )
    }

    /// **The field every version of this tool has carried, and the one that
    /// catches a node that pages without saying so.** Four open, one returned:
    /// this is a page whatever the flags say.
    func testACountBiggerThanTheRowsIsAPageEvenWithoutTheFlags() throws {
        let reading = try XCTUnwrap(SageBacklogReply.read(page(ids: ["a1"], total: 4)))

        XCTAssertEqual(
            reading.continuation(afterReading: reading.returned),
            .more(["limit": .int(SageBacklogReply.pageSize), "offset": .int(1)]),
            "the next page starts after what this one carried"
        )
    }

    func testAScanCapIsAnAdmissionThatTheNodeStoppedEarly() throws {
        let reading = try XCTUnwrap(
            SageBacklogReply.read(page(ids: ["a1", "a2"], total: 2, scanCapped: true))
        )
        XCTAssertEqual(reading.continuation(afterReading: reading.returned), .unreachable)
    }

    /// **A page that is legitimately smaller than the total is not incomplete.**
    /// `total_open` counts the list: the second page of three carries one row
    /// beside a total of three, and the count is compared against everything read
    /// so far rather than against this page. Written the other way first, and
    /// this is the test that caught it.
    func testTheSecondPageOfThreeIsStillTheEndOfTheList() throws {
        let second = try XCTUnwrap(SageBacklogReply.read(page(ids: ["a3"], total: 3)))
        XCTAssertEqual(second.continuation(afterReading: 3), .complete)
    }

    func testSomethingThatIsNotABacklogHasNoEnvelope() {
        XCTAssertNil(SageBacklogReply.read(#"{"message":"You have 3 assigned open tasks"}"#))
        XCTAssertNil(SageBacklogReply.read("sage-gui is restarting"))
        // And an empty backlog is a backlog.
        XCTAssertNotNil(SageBacklogReply.read(#"{"tasks_by_domain":{},"total_open":0}"#))
    }

    // MARK: Reading the whole list

    /// A node that pages, answered properly: the union, in one stable order.
    func testAPagingNodeIsReadToTheEnd() async throws {
        let source = SageProactiveSource(tools: ScriptedBacklog(pages: [
            page(ids: ["a1", "a2"], total: 3, hasMore: true, nextOffset: 2),
            page(ids: ["a3"], total: 3)
        ]))

        let tasks = try await source.openTasks()

        XCTAssertEqual(tasks.map(\.id), ["a1", "a2", "a3"])
    }

    /// **The case that has to be a refusal.** The node says it is holding more
    /// than it returned and answering again changes nothing — so there is no
    /// read here, and the caller must not be handed a page.
    func testANodeThatWillNotPageIsARefusalRatherThanAPage() async {
        let source = SageProactiveSource(tools: ScriptedBacklog(pages: [
            page(ids: ["a1"], total: 9, hasMore: true, nextOffset: 1)
        ]))

        do {
            let tasks = try await source.openTasks()
            XCTFail("a page was handed over as the whole list: \(tasks.map(\.id))")
        } catch {
            XCTAssertEqual(
                error as? SageProactiveSource.Trouble,
                .incompleteBacklog("more than \(SageBacklogReply.mostPages * SageBacklogReply.pageSize) open tasks")
            )
        }
    }

    /// And a page that never ends is bounded rather than a loop that asks a node
    /// forever.
    func testPagesThatKeepComingAreBounded() async {
        let source = SageProactiveSource(tools: AlwaysMorePages())

        do {
            _ = try await source.openTasks()
            XCTFail("it read pages forever")
        } catch {
            XCTAssertNotNil(error as? SageProactiveSource.Trouble)
        }
    }

    /// **The safety property, stated at the layer that deletes calendar
    /// events.** A node holding more than this appliance could read produces
    /// `sawTasks == nil`, and `CalendarSync` treats nil as "could not ask" —
    /// which changes nothing. Empty would have meant "every dated task is
    /// finished", which deletes them.
    func testAPageNeverReachesTheCalendarAsAnEmptyList() async {
        let source = SageProactiveSource(tools: ScriptedBacklog(pages: [
            page(ids: ["a1"], total: 9, hasMore: true, nextOffset: 1)
        ]))
        let report = await ProactiveWatch(source: source)
            .check(against: ProactiveLedger(hasSeeded: true))

        XCTAssertNil(report.sawTasks, "a page was reported to the calendar as a complete reading")
    }

    // MARK: Doubles

    /// Answers with the pages it was given, then repeats the last one — which is
    /// how a node that does not page answers a second identical request.
    ///
    /// An instance, not a `static`, because a counter shared between tests is
    /// how a suite starts passing in one order and failing in another.
    private final class ScriptedBacklog: ToolProviding, @unchecked Sendable {
        private let pages: [String]
        private let lock = NSLock()
        private var index = 0

        init(pages: [String]) { self.pages = pages }

        func listTools() async throws -> [MCPTool] { [] }

        func call(name: String, arguments: [String: JSONValue]) async throws -> String {
            lock.lock()
            defer { lock.unlock() }
            let page = pages[min(index, pages.count - 1)]
            index += 1
            return page
        }
    }

    /// A node that always says there is one more page and always sends the next
    /// one — the bound is the only thing that stops it.
    private final class AlwaysMorePages: ToolProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var index = 0

        func listTools() async throws -> [MCPTool] { [] }

        func call(name: String, arguments: [String: JSONValue]) async throws -> String {
            lock.lock()
            defer { lock.unlock() }
            index += 1
            let offset = index
            return #"{"tasks_by_domain":{"d":[{"memory_id":"a\#(offset)","content":"[TASK] a\#(offset)","task_status":"planned"}]},"total_open":99,"has_more":true,"next_offset":\#(offset)}"#
        }
    }
}
