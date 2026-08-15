import XCTest
@testable import SageVoiceCore

/// `sage_timeline` against a node that caps a timeline at 31 days.
///
/// The defect this covers was found in `bridge.log` rather than by reading
/// code. On 15 August 2026 the owner asked *"what about sage updates"*; the
/// turn took 43 seconds, called `sage_timeline` twice, was refused both times
/// with *"Timeline range too large"*, and answered him from four `web_search`
/// calls instead — the appliance went to the internet for something its own
/// memory held.
///
/// The model is not at fault, which is why this is fixed in code rather than in
/// the prompt: SAGE's own tool schema offers `2024-01-01` to `2024-12-31` as
/// the example range, and that example is twelve times wider than the node will
/// answer.
final class BoundedTimelineTests: XCTestCase {

    /// Records what actually reached the node, and answers like one.
    private final class Records: ToolProviding, @unchecked Sendable {
        var seen: [String: JSONValue]?
        var name: String?
        let reply: String
        init(reply: String = #"{"buckets":[]}"#) { self.reply = reply }
        func listTools() async throws -> [MCPTool] { [] }
        func call(name: String, arguments: [String: JSONValue]) async throws -> String {
            self.name = name
            self.seen = arguments
            return reply
        }
    }

    /// 2026-08-15T12:00:00Z, so every expectation below is a fixed string.
    private let now = Date(timeIntervalSince1970: 1_786_795_200)

    private func date(_ text: String) -> Date {
        BoundedTimeline.rfc3339(text)!
    }

    // MARK: - What gets narrowed

    /// The schema's own example, which the node refuses.
    func testTheSchemasOwnExampleIsNarrowedToTheLastThirtyOneDays() {
        let narrowed = BoundedTimeline.narrow(
            arguments: [
                "from": .string("2024-01-01T00:00:00Z"),
                "to": .string("2024-12-31T23:59:59Z")
            ],
            now: now
        )
        XCTAssertEqual(narrowed?.arguments["to"]?.stringValue, "2024-12-31T23:59:59Z")
        XCTAssertEqual(narrowed?.arguments["from"]?.stringValue, "2024-11-30T23:59:59Z")
    }

    /// Anchored at `to`, not at `from`: a model asking for a year of activity is
    /// asking what has been happening, and the recent end answers that.
    func testTheWindowKeepsTheRecentEnd() {
        let narrowed = BoundedTimeline.narrow(
            arguments: [
                "from": .string("2026-01-01T00:00:00Z"),
                "to": .string("2026-08-15T00:00:00Z")
            ],
            now: now
        )
        let from = try! XCTUnwrap(narrowed?.arguments["from"]?.stringValue)
        XCTAssertEqual(from, "2026-07-15T00:00:00Z")
        XCTAssertEqual(
            date("2026-08-15T00:00:00Z").timeIntervalSince(date(from)),
            BoundedTimeline.widestSpan
        )
    }

    /// `from` with no `to`: the node would pair it with now, so the clock here
    /// decides the window.
    func testAnOpenEndedRangeIsClosedAtNow() {
        let narrowed = BoundedTimeline.narrow(
            arguments: ["from": .string("2025-01-01T00:00:00Z")],
            now: now
        )
        XCTAssertEqual(narrowed?.arguments["from"]?.stringValue, "2026-07-15T12:00:00Z")
        XCTAssertEqual(narrowed?.arguments["to"]?.stringValue, "2026-08-15T12:00:00Z")
    }

    /// Everything else the model said is its own; only the range moves.
    func testOtherArgumentsSurviveNarrowing() {
        let narrowed = BoundedTimeline.narrow(
            arguments: [
                "from": .string("2020-01-01T00:00:00Z"),
                "to": .string("2026-08-15T00:00:00Z"),
                "domain": .string("mynah-home")
            ],
            now: now
        )
        XCTAssertEqual(narrowed?.arguments["domain"]?.stringValue, "mynah-home")
    }

    // MARK: - What is left alone

    /// **Exactly 31 days is accepted by the node** — its test is
    /// `to.Sub(from) > max`. Narrowing here would cost the owner a day of
    /// history on every call to buy nothing.
    func testExactlyThirtyOneDaysIsUntouched() {
        XCTAssertNil(
            BoundedTimeline.narrow(
                arguments: [
                    "from": .string("2026-07-15T12:00:00Z"),
                    "to": .string("2026-08-15T12:00:00Z")
                ],
                now: now
            )
        )
    }

    func testANarrowRangeIsUntouched() {
        XCTAssertNil(
            BoundedTimeline.narrow(
                arguments: [
                    "from": .string("2026-08-01T00:00:00Z"),
                    "to": .string("2026-08-15T00:00:00Z")
                ],
                now: now
            )
        )
    }

    /// No range at all is the node's own 24-hour default, which is well inside
    /// the cap. Supplying one here would override a default SAGE is entitled to
    /// change.
    func testNoRangeIsLeftToTheNodesDefault() {
        XCTAssertNil(BoundedTimeline.narrow(arguments: [:], now: now))
        XCTAssertNil(BoundedTimeline.narrow(arguments: ["domain": .string("mynah-home")], now: now))
    }

    /// `to` alone is under the cap by construction — the node pairs it with a
    /// `from` 24 hours earlier.
    func testAnEndWithNoStartIsUntouched() {
        XCTAssertNil(
            BoundedTimeline.narrow(arguments: ["to": .string("2020-01-01T00:00:00Z")], now: now)
        )
    }

    /// Backwards. The node answers "from must be earlier than or equal to to",
    /// which is exact and actionable; swapping them would be guessing at an
    /// intent the model did not express, and would silently answer a question
    /// nobody asked.
    func testABackwardsRangeIsLeftForTheNodeToRefuse() {
        XCTAssertNil(
            BoundedTimeline.narrow(
                arguments: [
                    "from": .string("2026-08-15T00:00:00Z"),
                    "to": .string("2020-01-01T00:00:00Z")
                ],
                now: now
            )
        )
    }

    /// An unreadable timestamp gets SAGE's own precise refusal. Inventing a
    /// range here would replace a clear message with a wrong answer.
    func testAnUnreadableTimestampIsLeftForTheNodeToRefuse() {
        XCTAssertNil(
            BoundedTimeline.narrow(
                arguments: ["from": .string("last Tuesday"), "to": .string("2026-08-15T00:00:00Z")],
                now: now
            )
        )
    }

    /// SAGE's own `created_at` values carry fractional seconds, so a model
    /// echoing one back must not read as nonsense.
    func testFractionalSecondsParse() {
        XCTAssertNotNil(BoundedTimeline.rfc3339("2026-08-15T03:07:03.299922Z"))
        XCTAssertNotNil(BoundedTimeline.rfc3339("2026-08-15T03:07:03Z"))
        XCTAssertNil(BoundedTimeline.rfc3339("2026-08-15"))
    }

    // MARK: - Through the decorator

    func testAWideRangeReachesTheNodeNarrowed() async throws {
        let node = Records()
        let tools = BoundedTimeline(wrapping: node, now: { self.now })
        _ = try await tools.call(
            name: "sage_timeline",
            arguments: [
                "from": .string("2024-01-01T00:00:00Z"),
                "to": .string("2024-12-31T00:00:00Z")
            ]
        )
        XCTAssertEqual(node.seen?["from"]?.stringValue, "2024-11-30T00:00:00Z")
    }

    /// **The narrowing is disclosed.** A narrowed answer that looked complete
    /// would let the model tell the owner "nothing happened all year" having
    /// been shown one month — a confident false statement produced by us, which
    /// is worse than the refusal this replaces.
    func testANarrowedAnswerSaysWhatItActuallyCovers() async throws {
        let node = Records()
        let tools = BoundedTimeline(wrapping: node, now: { self.now })
        let reply = try await tools.call(
            name: "sage_timeline",
            arguments: [
                "from": .string("2024-01-01T00:00:00Z"),
                "to": .string("2024-12-31T00:00:00Z")
            ]
        )
        XCTAssertTrue(reply.contains(#"{"buckets":[]}"#))
        XCTAssertTrue(reply.contains("31 days"))
        XCTAssertTrue(reply.contains("2024-11-30T00:00:00Z"))
        XCTAssertTrue(reply.contains("narrowed"))
    }

    /// An answer that was not narrowed must not carry a caveat about narrowing.
    func testAnUntouchedAnswerCarriesNoCaveat() async throws {
        let node = Records()
        let tools = BoundedTimeline(wrapping: node, now: { self.now })
        let reply = try await tools.call(
            name: "sage_timeline",
            arguments: [
                "from": .string("2026-08-01T00:00:00Z"),
                "to": .string("2026-08-15T00:00:00Z")
            ]
        )
        XCTAssertEqual(reply, #"{"buckets":[]}"#)
        XCTAssertEqual(node.seen?["from"]?.stringValue, "2026-08-01T00:00:00Z")
    }

    /// Every other tool passes through untouched, arguments and reply alike.
    func testOtherToolsArePassedThrough() async throws {
        let node = Records(reply: "recalled")
        let tools = BoundedTimeline(wrapping: node, now: { self.now })
        let reply = try await tools.call(
            name: "sage_recall",
            arguments: ["query": .string("sage updates"), "from": .string("2020-01-01T00:00:00Z")]
        )
        XCTAssertEqual(reply, "recalled")
        XCTAssertEqual(node.name, "sage_recall")
        XCTAssertEqual(node.seen?["from"]?.stringValue, "2020-01-01T00:00:00Z")
    }

    /// The daemon has to actually install it, and `main.swift` is an executable
    /// target that cannot be imported — the scan precedent `AfterTheCallTests`
    /// set. Without this the wrapper can be perfect and never reached.
    func testTheDaemonWrapsItsToolSource() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let main = try String(
            contentsOf: root.appendingPathComponent("Sources/sage-voiced/main.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            main.contains("BoundedTimeline("),
            "the daemon's tool source no longer bounds sage_timeline, so a wide range is refused again"
        )
    }
}
