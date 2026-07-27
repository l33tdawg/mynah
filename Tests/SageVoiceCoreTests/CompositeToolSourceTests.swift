import XCTest
@testable import SageVoiceCore

// MARK: - Stubs

private final class FakeSource: ToolProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let tools: [MCPTool]
    private let listError: Error?
    private(set) var calls: [String] = []

    init(toolNames: [String], listError: Error? = nil) {
        self.tools = toolNames.map {
            MCPTool(name: $0, description: "stub \($0)", inputSchema: .object(["type": .string("object")]))
        }
        self.listError = listError
    }

    func listTools() async throws -> [MCPTool] {
        if let listError { throw listError }
        return tools
    }

    func call(name: String, arguments: [String: JSONValue]) async throws -> String {
        record(name)
        return "answered by stub: \(name)"
    }

    var recordedCalls: [String] { withLock { calls } }

    private func record(_ name: String) { withLock { calls.append(name) } }

    /// `NSLock` is `noasync`; a non-async body makes it impossible to suspend
    /// while holding it.
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private struct StubError: Error, CustomStringConvertible {
    let description: String
}

// MARK: - Tests

final class CompositeToolSourceTests: XCTestCase {

    private func makeSage(_ names: [String] = ["sage_recall", "sage_remember"]) -> FakeSource {
        FakeSource(toolNames: names)
    }

    func testCataloguesFromEverySourceAreMerged() async throws {
        let sage = makeSage()
        let web = FakeSource(toolNames: ["web_search"])
        let composite = CompositeToolSource(sources: [
            .init(label: "sage", provider: sage, isRequired: true),
            .init(label: "web", provider: web, isRequired: false)
        ])

        let names = try await composite.listTools().map(\.name)
        XCTAssertEqual(names, ["sage_recall", "sage_remember", "web_search"])
    }

    func testCallsAreRoutedToTheSourceThatPublishedTheTool() async throws {
        let sage = makeSage()
        let web = FakeSource(toolNames: ["web_search"])
        let composite = CompositeToolSource(sources: [
            .init(label: "sage", provider: sage, isRequired: true),
            .init(label: "web", provider: web, isRequired: false)
        ])
        _ = try await composite.listTools()

        _ = try await composite.call(name: "web_search", arguments: ["query": .string("hi")])
        _ = try await composite.call(name: "sage_recall", arguments: [:])

        XCTAssertEqual(web.recordedCalls, ["web_search"])
        XCTAssertEqual(sage.recordedCalls, ["sage_recall"])
    }

    /// The loop may call before anything has listed — the routing table must
    /// build itself rather than reporting the tool as unknown.
    func testACallBeforeAnyListStillRoutes() async throws {
        let web = FakeSource(toolNames: ["web_search"])
        let composite = CompositeToolSource(sources: [
            .init(label: "web", provider: web, isRequired: false)
        ])

        let result = try await composite.call(name: "web_search", arguments: [:])
        XCTAssertEqual(result, "answered by stub: web_search")
    }

    func testAnInventedToolNameIsRejected() async throws {
        let composite = CompositeToolSource(sources: [
            .init(label: "sage", provider: makeSage(), isRequired: true)
        ])
        _ = try await composite.listTools()

        do {
            _ = try await composite.call(name: "rm_rf", arguments: [:])
            XCTFail("expected an unknown-tool failure")
        } catch let failure as CompositeToolSource.Failure {
            XCTAssertEqual(failure, .unknownTool("rm_rf"))
        }
    }

    // MARK: Degradation

    /// The point of the whole arrangement: no internet must not mean no brain.
    func testAnOptionalSourceFailingLeavesTheRequiredOneWorking() async throws {
        let sage = makeSage()
        let web = FakeSource(toolNames: ["web_search"], listError: StubError(description: "offline"))
        let composite = CompositeToolSource(sources: [
            .init(label: "sage", provider: sage, isRequired: true),
            .init(label: "web", provider: web, isRequired: false)
        ])

        let names = try await composite.listTools().map(\.name)
        XCTAssertEqual(names, ["sage_recall", "sage_remember"])
        XCTAssertFalse(names.contains("web_search"))
    }

    func testARequiredSourceFailingFailsTheCatalogue() async {
        let sage = FakeSource(toolNames: [], listError: StubError(description: "sage node down"))
        let composite = CompositeToolSource(sources: [
            .init(label: "sage", provider: sage, isRequired: true),
            .init(label: "web", provider: FakeSource(toolNames: ["web_search"]), isRequired: false)
        ])

        do {
            _ = try await composite.listTools()
            XCTFail("expected the required source's failure to propagate")
        } catch let error as StubError {
            XCTAssertEqual(error.description, "sage node down")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: Shadowing

    func testTheFirstSourceToPublishANameKeepsIt() async throws {
        let sage = makeSage(["sage_recall", "web_search"])
        let web = FakeSource(toolNames: ["web_search"])
        let composite = CompositeToolSource(sources: [
            .init(label: "sage", provider: sage, isRequired: true),
            .init(label: "web", provider: web, isRequired: false)
        ])
        _ = try await composite.listTools()

        _ = try await composite.call(name: "web_search", arguments: [:])

        XCTAssertEqual(sage.recordedCalls, ["web_search"], "SAGE's own tool should win over the bolted-on one")
        XCTAssertTrue(web.recordedCalls.isEmpty)
    }

    func testAShadowedToolIsPublishedOnlyOnce() async throws {
        let composite = CompositeToolSource(sources: [
            .init(label: "sage", provider: makeSage(["web_search"]), isRequired: true),
            .init(label: "web", provider: FakeSource(toolNames: ["web_search"]), isRequired: false)
        ])

        let names = try await composite.listTools().map(\.name)
        XCTAssertEqual(names, ["web_search"], "a duplicate name must not reach the model twice")
    }

    // MARK: The silent-partial-catalogue guard

    /// Regression test for a hole that opened when the catalogue stopped coming
    /// from one place. `ToolLoop`'s allowlist fails closed only when *nothing*
    /// matches — and web search always matches — so a SAGE that renamed every
    /// tool would leave the model with one tool, no memory, and no error.
    func testARequiredSourcePublishingNoRecognisedToolIsFatal() async {
        let renamedSage = FakeSource(toolNames: ["brain_recall", "brain_remember"])
        let composite = CompositeToolSource(sources: [
            .init(
                label: "SAGE MCP",
                provider: renamedSage,
                isRequired: true,
                expectedToolNames: ["sage_recall", "sage_remember"]
            ),
            .init(
                label: "web search",
                provider: FakeSource(toolNames: ["web_search"]),
                isRequired: false,
                expectedToolNames: ["web_search"]
            )
        ])

        do {
            _ = try await composite.listTools()
            XCTFail("expected a partial catalogue to be refused")
        } catch let failure as CompositeToolSource.Failure {
            guard case .sourceContributedNothing(let label, _, let published) = failure else {
                return XCTFail("wrong failure: \(failure)")
            }
            XCTAssertEqual(label, "SAGE MCP")
            XCTAssertEqual(published.sorted(), ["brain_recall", "brain_remember"])
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testOneRecognisedToolIsEnoughToPassTheGuard() async throws {
        let composite = CompositeToolSource(sources: [
            .init(
                label: "SAGE MCP",
                provider: FakeSource(toolNames: ["sage_recall", "sage_something_new"]),
                isRequired: true,
                expectedToolNames: ["sage_recall", "sage_remember"]
            )
        ])

        let names = try await composite.listTools().map(\.name)
        XCTAssertEqual(names, ["sage_recall", "sage_something_new"], "SAGE growing a tool must not trip the guard")
    }

    func testAnOptionalSourceFailingTheGuardIsDroppedNotFatal() async throws {
        let composite = CompositeToolSource(sources: [
            .init(label: "SAGE MCP", provider: makeSage(), isRequired: true, expectedToolNames: ["sage_recall"]),
            .init(
                label: "web search",
                provider: FakeSource(toolNames: ["something_else"]),
                isRequired: false,
                expectedToolNames: ["web_search"]
            )
        ])

        let names = try await composite.listTools().map(\.name)
        XCTAssertEqual(names, ["sage_recall", "sage_remember"])
    }

    /// The wiring the CLI actually uses. If web search is not in the allowlist
    /// the model never sees it, and the feature is a silent no-op.
    func testTheVoiceAllowlistIncludesWebSearch() {
        XCTAssertTrue(BrainPrompts.voiceToolAllowlist.contains(WebSearchToolSource.toolName))
    }
}
