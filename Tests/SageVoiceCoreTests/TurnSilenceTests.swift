import XCTest
@testable import SageVoiceCore

/// The silence the owner reported twice as a hang.
///
/// Four separate anti-silence mechanisms cancelled each other out, and the
/// existing suite was green throughout — every one of them was unit-tested in
/// isolation and none of them was tested on the shape of turn that actually
/// happens.
///
/// The shape: ask a question, one tool round trip, answer. Model call, tool,
/// model call. On this appliance that is 80-140 seconds, and it produced exactly
/// one message at ~2.5s and then nothing.
///
///   1. The progress check sat inside the iteration body, below the
///      `guard !response.toolCalls.isEmpty else { break }` that ends a turn — so
///      the iteration producing the ANSWER exited before it could speak.
///   2. On iteration 1 it was reached, but `progressLine` bailed because nothing
///      had completed yet, even though it had correct `pending` branches.
///   3. `onToolDecision` was suppressed by `spokeOnArrival`, which the catch-all
///      opener set on essentially every request — silently making all ~25
///      per-tool lines unreachable in production.
///   4. Had it not been suppressed, `saysTheSameThing` scored it 0.5 and ate it
///      as a stutter.
final class TurnSilenceTests: XCTestCase {

    /// A backend shaped like the real failure: tools on the first call, an
    /// answer on the second, both slow.
    private final class OneRoundTripBackend: BrainBackend, @unchecked Sendable {
        let identifier = "roundtrip"
        let modelName = "roundtrip-model"
        let isLocal = true
        private let lock = NSLock()
        private var calls = 0
        private let delay: Duration

        init(delay: Duration) { self.delay = delay }

        func isAvailable() async -> Bool { true }

        func complete(_ request: BrainRequest) async throws -> BrainReply {
            try? await Task.sleep(for: delay)
            lock.lock()
            calls += 1
            let first = calls == 1
            lock.unlock()

            if first && !request.tools.isEmpty {
                return BrainReply(
                    model: modelName,
                    message: BrainMessage(
                        role: .assistant,
                        content: "",
                        toolCalls: [BrainToolCall(id: "1", name: "web_search", arguments: [:])]
                    ),
                    stopReason: .toolUse,
                    usage: BrainUsage(inputTokens: 1, outputTokens: 1)
                )
            }
            return BrainReply(
                model: modelName,
                message: .assistant("Ton Chan Ramen, Wisma Cosway."),
                stopReason: .endTurn,
                usage: BrainUsage(inputTokens: 1, outputTokens: 1)
            )
        }
    }

    private struct SlowToolSource: ToolProviding, @unchecked Sendable {
        let delay: Duration
        func listTools() async throws -> [MCPTool] {
            [MCPTool(name: "web_search", description: "s", inputSchema: .object(["type": .string("object")]))]
        }
        func call(name: String, arguments: [String: JSONValue]) async throws -> String {
            try? await Task.sleep(for: delay)
            return "1. Ton Chan Ramen\n   https://example.com/"
        }
    }

    private final class Updates: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func record(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
    }

    /// The whole point. A turn long enough to deserve updates must produce them
    /// on the second half too, not only before the first tool runs.
    func testALongOneRoundTripTurnDoesNotGoSilent() async throws {
        let updates = Updates()
        let loop = ToolLoop(
            backend: OneRoundTripBackend(delay: .milliseconds(260)),
            mcp: SlowToolSource(delay: .milliseconds(120)),
            configuration: ToolLoop.Configuration(deadlineSeconds: nil, allowedToolNames: [])
        )

        let result = try await withProgressInterval(.milliseconds(100)) {
            try await loop.run(
                transcript: "any good ramen shops near klcc",
                onProgress: { update in
                    if let line = update.line { updates.record(line) }
                }
            )
        }

        XCTAssertFalse(result.reply.isEmpty)
        XCTAssertFalse(
            updates.all.isEmpty,
            "the turn ran ~0.6s past the first update interval and said nothing"
        )
    }

    /// Failure 2, directly: with a tool chosen and nothing finished, there IS
    /// news — it is the only moment the owner can still redirect the turn.
    func testProgressSpeaksAboutWhatIsAboutToHappen() {
        XCTAssertNotNil(
            WorkingReply.progressLine(completed: [], pending: "web_search"),
            "nothing had finished yet, so the turn stayed silent through its first tool"
        )
        XCTAssertNil(
            WorkingReply.progressLine(completed: [], pending: nil),
            "with nothing done and nothing pending there is no news, and filler was the original sin"
        )
    }

    /// Failure 3. The catch-all matches essentially every request, so
    /// suppressing behind *any* opener made every per-tool line unreachable.
    func testAGenericOpenerDoesNotSuppressTheToolLine() {
        let generic = WorkingReply.opening(forRequest: "any good ramen shops near klcc", chooser: { _ in 0 })
        XCTAssertNotNil(generic)
        XCTAssertFalse(generic!.isSpecific, "the catch-all claimed to be specific, so it suppresses the tool line")

        let specific = WorkingReply.opening(forRequest: "whats on my backlog today", chooser: { _ in 0 })
        XCTAssertNotNil(specific)
        XCTAssertTrue(specific!.isSpecific, "a branch that named the backlog was treated as a catch-all")
    }

    /// Failure 4, kept as a boundary check: the pair that scored exactly 0.5 and
    /// got eaten.
    func testTheToolLineIsNotEatenAfterAGenericOpener() {
        XCTAssertTrue(
            WorkingReply.saysTheSameThing("Looking online for the rest of it.", as: "Let me have a look."),
            "premise changed — if this no longer collides, the suppression fix is doing less than it looks"
        )
        // Which is exactly why the generic opener must not be recorded as the
        // previous line for suppression purposes.
        XCTAssertFalse(
            WorkingReply.opening(forRequest: "any good ramen shops near klcc", chooser: { _ in 0 })!.isSpecific
        )
    }

    /// Runs `body` with a shortened progress interval so a test does not wait 45
    /// real seconds. Restores it however the body exits.
    private func withProgressInterval<T>(
        _ interval: Duration,
        _ body: () async throws -> T
    ) async rethrows -> T {
        let original = WorkingReply.progressAfterSeconds
        WorkingReply.progressAfterSeconds = Double(interval.components.seconds)
            + Double(interval.components.attoseconds) / 1e18
        defer { WorkingReply.progressAfterSeconds = original }
        return try await body()
    }
}
