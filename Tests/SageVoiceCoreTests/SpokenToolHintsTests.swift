import XCTest
@testable import SageVoiceCore

/// **The hints the appliance ships must be the hints that were measured.**
///
/// The wording in `SpokenToolHints.hints` earned its place by moving a number:
/// 9/12 to 10/12 on qwen3.5:4b, at every composed catalogue size from 20 to 27,
/// measured 20 Aug 2026 with the real voice prompt. That measurement was taken
/// by `scripts/measure-tool-routing.py` reading
/// `Tests/Fixtures/spoken-tool-hints.json`.
///
/// So there are two copies of the sentences — one Python reads, one Swift ships
/// — and if they drift the measurement stops describing the appliance. That is
/// not a hypothetical: the same script's tool list drifted out of this codebase
/// and went unnoticed for months, under a comment stating that letting it drift
/// "is exactly the decoupling that ends the numbers' meaning". Nothing pinned
/// it. This pins its successor.
final class SpokenToolHintsTests: XCTestCase {

    private func fixtureHints() throws -> [String: String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/spoken-tool-hints.json")
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try XCTUnwrap(json?["hints"] as? [String: String], "the fixture has no hints map")
    }

    /// The pin. Reword one copy and this fails until the other follows — and
    /// the right response is to rerun the measurement, because a reworded hint
    /// is an unmeasured hint.
    func testTheShippedWordingIsTheMeasuredWording() throws {
        let fixture = try fixtureHints()

        XCTAssertEqual(
            Set(SpokenToolHints.hints.keys), Set(fixture.keys),
            "Swift and the measurement harness disagree about WHICH tools are hinted"
        )
        for (name, shipped) in SpokenToolHints.hints {
            XCTAssertEqual(
                normalised(shipped), normalised(fixture[name] ?? ""),
                """
                The hint for \(name) that ships is not the one that was measured. \
                Rerun scripts/measure-tool-routing.py with MYNAH_TOOL_HINTS=1 and \
                move both copies together, or the number in the comments stops \
                describing this appliance.
                """
            )
        }
    }

    /// Swift's `"""` literals wrap with backslash-continuations and the JSON is
    /// one line; comparing raw would fail on whitespace that no model can see.
    private func normalised(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: What the decorator may and may not do

    /// **Appended, never replaced.** SAGE's prose is more precise than ours and
    /// is maintained by the people who own the tools. Losing it would trade a
    /// routing win on a 4B for a correctness loss on every brain that reads the
    /// description properly.
    func testTheOriginalDescriptionSurvivesInFull() async throws {
        let source = SpokenToolHints(wrapping: StubTools([
            ("sage_timeline", "Get memories in a time range, grouped by time buckets.")
        ]))

        let tools = try await source.listTools()
        let tool = try XCTUnwrap(tools.first)

        XCTAssertTrue(
            tool.description.hasPrefix("Get memories in a time range, grouped by time buckets."),
            "SAGE's own description was replaced rather than added to: \(tool.description)"
        )
        XCTAssertTrue(
            tool.description.contains("HAVE BEEN DOING"),
            "the hint never reached the model"
        )
    }

    /// A tool nobody wrote a hint for must come through untouched, byte for
    /// byte. Every extra byte of schema is paid on every turn.
    func testAnUnhintedToolIsNotAlteredAtAll() async throws {
        let original = "Search memories by semantic similarity."
        let source = SpokenToolHints(wrapping: StubTools([("sage_recall", original)]))

        let tools = try await source.listTools()
        let tool = try XCTUnwrap(tools.first)

        XCTAssertEqual(tool.description, original)
    }

    /// **The schema is not this decorator's business.** It changes what the
    /// model is told about choosing a tool and nothing about calling one — a
    /// hint that altered `inputSchema` would be a wire-protocol change wearing
    /// a documentation change's clothes.
    func testTheInputSchemaIsUntouched() async throws {
        let schema = JSONValue.object([
            "type": .string("object"),
            "required": .array([.string("from")])
        ])
        let source = SpokenToolHints(wrapping: StubTools([("sage_timeline", "d")], schema: schema))

        let tools = try await source.listTools()
        let tool = try XCTUnwrap(tools.first)

        XCTAssertEqual(tool.inputSchema, schema)
    }

    /// Calls pass straight through. Stated as a test because a decorator that
    /// silently rewrote arguments is exactly what `KeyedSends` and `ScopedRecall`
    /// are, and this one deliberately is not.
    func testCallsAreForwardedUnchanged() async throws {
        let stub = StubTools([("sage_timeline", "d")])
        let source = SpokenToolHints(wrapping: stub)

        let reply = try await source.call(name: "sage_timeline", arguments: ["from": .string("x")])

        XCTAssertEqual(reply, "ran sage_timeline")
        XCTAssertEqual(stub.lastArguments?["from"]?.stringValue, "x")
    }

    // MARK: Stub

    private final class StubTools: ToolProviding, @unchecked Sendable {
        private let tools: [(String, String)]
        private let schema: JSONValue
        private let lock = NSLock()
        private var recorded: [String: JSONValue]?

        init(_ tools: [(String, String)], schema: JSONValue = .object(["type": .string("object")])) {
            self.tools = tools
            self.schema = schema
        }

        var lastArguments: [String: JSONValue]? {
            lock.lock(); defer { lock.unlock() }
            return recorded
        }

        func listTools() async throws -> [MCPTool] {
            tools.map { MCPTool(name: $0.0, description: $0.1, inputSchema: schema) }
        }

        func call(name: String, arguments: [String: JSONValue]) async throws -> String {
            lock.lock(); recorded = arguments; lock.unlock()
            return "ran \(name)"
        }
    }
}
