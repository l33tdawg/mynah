import XCTest
@testable import SageVoiceCore

/// **A log is a diagnostic, not a second copy of the mail.**
///
/// `noteResults` polls the outbox on a cadence the owner sets — five minutes on
/// his appliance — and the outbox is RETAINED rather than drained, so every poll
/// sees the whole set again. It logged that set with
/// `String(describing: results).prefix(300)`, which meant two things nobody
/// intended.
///
/// Measured in his `bridge.log` on 20 Aug 2026: **1,492 copies of that line,
/// 512 KB of a 1,557 KB file — a third of the entire log was one sentence,
/// repeated.** The count climbed 3, 5, 6 … 42 and every value was rewritten
/// every five minutes for as long as the daemon ran, unbounded, growing with
/// the outbox.
///
/// And what it wrote was the raw items: message bodies and counterparty agent
/// ids, put on disk over and over, for messages the owner had already been told
/// about. `sage_message_history(folder: "outbox")` fetches bodies for anyone who
/// needs them; the log needs to say how many and which.
///
/// These tests are that distinction, pinned.
final class TheOutboxIsNotLoggedTwiceTests: XCTestCase {

    private var directory = URL(fileURLWithPath: NSTemporaryDirectory())
    private var said = URL(fileURLWithPath: NSTemporaryDirectory())

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("outbox-log-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        said = directory.appendingPathComponent("said-replies.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private static let secret = "the ferry leaves at six and the code is 4417"

    private func outbox() -> String {
        """
        {"folder": "outbox", "count": 1, "items": [
          {"message_id": "msg-aaa", "counterparty": "codex/sage",
           "completed_at": "2026-08-20T10:00:00Z", "result": "\(Self.secret)"}
        ]}
        """
    }

    private func ritual(_ lines: LoggedLines) -> SageRitual {
        SageRitual(
            tools: SilentTools(),
            readinessCheck: {
                ApplianceWriteReadiness(agentID: nil, standing: .unknown("not asked in tests"))
            },
            alreadySaidFile: said,
            readableDomainsFile: directory.appendingPathComponent("domains.json"),
            log: { lines.append($0) }
        )
    }

    /// The unbounded half. An outbox that has not changed is not news the second
    /// time, or the three-hundredth.
    func testAnUnchangedOutboxIsReportedOnceRatherThanEveryPoll() async {
        let lines = LoggedLines()
        let ritual = ritual(lines)

        await ritual.noteResults(in: outbox())
        let afterFirst = lines.matching("answered send(s) in the outbox").count
        await ritual.noteResults(in: outbox())
        await ritual.noteResults(in: outbox())
        let afterThree = lines.matching("answered send(s) in the outbox").count

        XCTAssertEqual(afterFirst, 1, "the first look should say what it found")
        XCTAssertEqual(
            afterThree, 1,
            """
            The outbox was re-reported on a poll where nothing changed. On the \
            owner's appliance that is every five minutes, forever, growing with \
            the outbox — it reached a third of his whole log. What the lines say:
                \(lines.values.joined(separator: "\\n    "))
            """
        )
    }

    /// The privacy half, and the one that matters more.
    func testTheMessageBodyNeverReachesTheLog() async {
        let lines = LoggedLines()
        let ritual = ritual(lines)

        await ritual.noteResults(in: outbox())

        let reported = lines.matching("answered send(s) in the outbox").first
        XCTAssertNotNil(reported, "the outbox was not reported at all")
        XCTAssertFalse(
            lines.values.joined().contains(Self.secret),
            """
            An agent's message body was written to bridge.log. The outbox is \
            polled on a cadence and retained, so this is not one copy — it is a \
            copy every poll, for as long as the daemon runs.
            """
        )
        XCTAssertTrue(
            reported?.contains("msg-aaa") ?? false,
            "the id is what a diagnosis needs and it is missing: \(reported ?? "nil")"
        )
    }

    /// Thread-safe collector; `SageRitual`'s log closure is `@Sendable`.
    final class LoggedLines: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []

        func append(_ line: String) {
            lock.lock(); lines.append(line); lock.unlock()
        }

        var values: [String] {
            lock.lock(); defer { lock.unlock() }
            return lines
        }

        func matching(_ needle: String) -> [String] {
            values.filter { $0.contains(needle) }
        }
    }

    private struct SilentTools: ToolProviding {
        func listTools() async throws -> [MCPTool] { [] }
        func call(name: String, arguments: [String: JSONValue]) async throws -> String { "ok" }
    }
}
