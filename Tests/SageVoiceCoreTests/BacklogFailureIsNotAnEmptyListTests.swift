import XCTest
@testable import SageVoiceCore

/// **"that is damn weird bro; seems like our app problem not a sage problem".**
///
/// The owner, 6 August 2026, on his calendar emptying itself. He was right.
///
///     18:10       he restarted sage-gui
///     18:16:35 [calendar] removed "Follow-up with Credence …"      (x11)
///     18:16:36 [calendar] mirroring 0 dated task(s)
///     18:16:36 [watch] something changed; telling the owner
///     18:48:36 [calendar] added …                                  (x11)
///
/// Thirty-two minutes with none of his dated tasks in his calendar, every event
/// re-created with a new identifier, and a Signal message announcing all eleven
/// as having come off the list.
///
/// **Every guard for this was already in place and one layer defeated them.**
/// `CalendarSync.run(tasks:)` takes `[WatchedTask]?` and its doc comment calls
/// the nil-versus-empty distinction "the whole safety property".
/// `ProactiveWatch` reads `try? await source.openTasks()`, which turns a throw
/// into `nil` correctly. And `ProactiveWatch.check` guards every ledger
/// mutation behind `if let tasks`, with a comment about a refusal that "used to
/// be coalesced to an empty list, which is not 'nothing is there' — it is 'I
/// could not look', and the two are opposite".
///
/// `SageProactiveSource.tasks(inBacklog:)` then manufactured exactly that empty
/// list out of any reply it could not parse. Its justification was written when
/// the digest was the only consumer — *"indistinguishable from an empty one for
/// the purpose of 'has anything changed'"* — and nothing revisited the sentence
/// when the calendar started reading the same value.
final class BacklogFailureIsNotAnEmptyListTests: XCTestCase {

    /// A node that answers, but not with a backlog: a restart, a rebuild, a
    /// refusal, a shape change. The reply is a success at the transport layer,
    /// which is what makes this dangerous — nothing throws.
    private struct AnswersWithoutABacklog: ToolProviding {
        let reply: String
        func listTools() async throws -> [MCPTool] { [] }
        func call(name: String, arguments: [String: JSONValue]) async throws -> String { reply }
    }

    private struct AnswersWithABacklog: ToolProviding {
        func listTools() async throws -> [MCPTool] { [] }
        func call(name: String, arguments: [String: JSONValue]) async throws -> String {
            #"""
            {"tasks_by_domain":{"mynah-home":[
              {"memory_id":"a1","content":"[TASK] Dentist on Tuesday 4 August 2026 at 1pm",
               "task_status":"planned"}]},"total_open":1}
            """#
        }
    }

    // MARK: - The read itself

    /// **The whole fix in one assertion.** Not a crash, not an empty list — a
    /// throw, so `try?` upstream produces the `nil` that every guard below it is
    /// already written for.
    func testANodeAnsweringSomethingElseIsAFailureAndNotAnEmptyBacklog() async {
        for reply in [
            "Error: not authorised",
            #"{"error":"node is starting up"}"#,
            "",
            "{}",
            "You have 0 assigned open tasks."
        ] {
            let source = SageProactiveSource(tools: AnswersWithoutABacklog(reply: reply))
            do {
                let tasks = try await source.openTasks()
                XCTFail("“\(reply)” came back as \(tasks.count) tasks instead of throwing")
            } catch {
                // The point. Anything at all, as long as it is not success.
            }
        }
    }

    /// And the ordinary case still works, or the fix has simply broken the
    /// feature in the other direction.
    func testARealBacklogStillReads() async throws {
        let source = SageProactiveSource(tools: AnswersWithABacklog())
        let tasks = try await source.openTasks()

        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.title, "Dentist on Tuesday 4 August 2026 at 1pm")
    }

    /// **An owner who finishes everything is not a fault.** Reading a genuine
    /// empty backlog as unreadable would leave stale events in his calendar for
    /// ever — the opposite failure, and just as wrong.
    func testAGenuinelyEmptyBacklogIsStillEmpty() async throws {
        let source = SageProactiveSource(
            tools: AnswersWithoutABacklog(reply: #"{"tasks_by_domain":{},"total_open":0}"#)
        )
        let tasks = try await source.openTasks()

        XCTAssertEqual(tasks, [])
    }

    // MARK: - What it costs downstream, which is the reason any of this matters

    /// **The end-to-end property, stated where somebody changing either layer
    /// will see it.** A failed look must reach the calendar as `nil`, and `nil`
    /// must change nothing.
    func testAFailedLookLeavesTheCalendarAlone() async {
        let ledger = CalendarLedger(
            events: ["a1": "e1", "a2": "e2"],
            written: ["a1": "f1", "a2": "f2"]
        )
        let calendar = CountingCalendar()
        let sync = CalendarSync(calendar: calendar)

        let source = SageProactiveSource(
            tools: AnswersWithoutABacklog(reply: #"{"error":"node is starting up"}"#)
        )
        // Exactly what ProactiveWatch does with it.
        let sawTasks = try? await source.openTasks()
        XCTAssertNil(sawTasks, "the read has to fail, or the rest of this proves nothing")

        let outcome = await sync.run(
            tasks: sawTasks,
            ledger: ledger,
            preferences: CalendarPreferences(isOn: true)
        )

        let removals = await calendar.removals
        XCTAssertEqual(removals, 0, "\(removals) event(s) deleted on a look that failed")
        XCTAssertEqual(outcome.ledger.events.count, 2, "the ledger forgot events it still holds")
    }

    /// The counterfactual, so the test above cannot pass for the wrong reason:
    /// hand the same sync an *actually* empty list and it does delete, which is
    /// correct and is what made the bug invisible.
    func testAnEmptyListGenuinelyDoesClearTheCalendar() async {
        let ledger = CalendarLedger(events: ["a1": "e1"], written: ["a1": "f1"])
        let calendar = CountingCalendar()
        let sync = CalendarSync(calendar: calendar)

        _ = await sync.run(
            tasks: [],
            ledger: ledger,
            preferences: CalendarPreferences(isOn: true)
        )

        let removals = await calendar.removals
        XCTAssertEqual(
            removals, 1,
            "an empty list must still mean 'he finished everything' — that is why the "
                + "manufactured empty was so dangerous"
        )
    }

    // MARK: - The log line that was missing

    /// The 18:16 tick said only "mirroring 0 dated task(s)", which is true about
    /// the plan and silent about why. The next occurrence should be five minutes
    /// of reading rather than an evening of inference, so the reply goes in the
    /// log verbatim — bounded, because a JSON blob across forty lines buries
    /// whatever came after it.
    func testTheUnreadableReplyIsLogged() async {
        let said = Recorder()
        let source = SageProactiveSource(
            tools: AnswersWithoutABacklog(reply: #"{"error":"node is starting up"}"#),
            log: { await1(said, $0) }
        )
        _ = try? await source.openTasks()

        let lines = said.lines
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("sage_backlog"), lines[0])
        XCTAssertTrue(lines[0].contains("node is starting up"), lines[0])
        XCTAssertTrue(lines[0].contains("changed nothing"), lines[0])
    }

    func testALongReplyIsCutDownBeforeItReachesTheLog() {
        let long = String(repeating: "x", count: 5_000)
        let head = SageProactiveSource.head(of: long)

        XCTAssertLessThan(head.count, 400)
        XCTAssertTrue(head.hasSuffix("…"))
    }

    func testTheLoggedReplyIsOneLine() {
        let messy = "{\n  \"error\":\n    \"node is starting up\"\n}"
        XCTAssertFalse(SageProactiveSource.head(of: messy).contains("\n"))
    }
}

// MARK: - Stubs

/// Sendable line collector for a `@Sendable` log closure.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [String] = []

    var lines: [String] {
        lock.lock(); defer { lock.unlock() }
        return collected
    }

    func add(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        collected.append(line)
    }
}

private func await1(_ recorder: Recorder, _ line: String) {
    recorder.add(line)
}

private actor CountingCalendar: CalendarWriting {
    private(set) var removals = 0
    private(set) var additions = 0

    func prepare() async -> Bool { true }

    func add(_ entry: CalendarEntry) async throws -> String {
        additions += 1
        return "e-new"
    }

    func update(_ entry: CalendarEntry, eventID: String) async throws -> String { eventID }

    func remove(eventID: String) async throws {
        removals += 1
    }
}
