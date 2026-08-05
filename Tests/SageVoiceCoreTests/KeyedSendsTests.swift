import XCTest
@testable import SageVoiceCore

private final class SendSpy: ToolProviding, @unchecked Sendable {
    var calls: [(name: String, arguments: [String: JSONValue])] = []
    var fail = false

    func listTools() async throws -> [MCPTool] { [] }

    func call(name: String, arguments: [String: JSONValue]) async throws -> String {
        calls.append((name, arguments))
        if fail { throw BrainBackendError.unreachable("the node did not answer") }
        return #"{"message_id":"msg-1","status":"queued"}"#
    }
}

/// **`sage_message_send` requires an `idempotency_key` and nothing supplied
/// one** on the path the model actually uses.
///
/// `SageAgentMessaging.send` does it properly and has no production call sites —
/// only `.inbox` is reached — so `AgentSendJournal` and its whole argument were
/// unreachable code, and every real send came from the model calling the tool
/// straight out of its catalogue.
///
/// Which left a 4B inventing a uniqueness token, and the two failure modes are
/// not symmetric. Omitting it hard-errors in front of the owner. Reusing one —
/// and a small model that has settled on `"1"` will reuse it — makes the second
/// message *silently become the first*, because SAGE's own contract is that a
/// repeated key "makes a retry return the original message_id instead of
/// creating a duplicate". The node answers success and nothing arrives.
final class KeyedSendsTests: XCTestCase {

    private var directory: URL!
    private var journalFile: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("keyed-sends-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        journalFile = directory.appendingPathComponent("agent-sends.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func keyed(_ spy: SendSpy) -> KeyedSends {
        KeyedSends(wrapping: spy, journal: AgentSendJournal(fileURL: journalFile))
    }

    private func sendArguments() -> [String: JSONValue] {
        ["to": .string("agent-74140c2d"), "payload": .string("Could you check the ferry times?")]
    }

    func testAModelThatOmitsTheKeyStillSends() async throws {
        let spy = SendSpy()

        _ = try await keyed(spy).call(name: "sage_message_send", arguments: sendArguments())

        guard case .string(let key)? = spy.calls.first?.arguments["idempotency_key"] else {
            return XCTFail("the send went out with no idempotency_key, which the node rejects")
        }
        XCTAssertFalse(key.isEmpty)
    }

    /// **The failure that reports success.** Two deliberate sends are two
    /// messages; if they share a key the second returns the first's id and
    /// nothing new is delivered.
    func testTwoSendsOfTheSameSentenceGetDifferentKeys() async throws {
        let spy = SendSpy()
        let tools = keyed(spy)

        _ = try await tools.call(name: "sage_message_send", arguments: sendArguments())
        _ = try await tools.call(name: "sage_message_send", arguments: sendArguments())

        let keys = spy.calls.compactMap { $0.arguments["idempotency_key"]?.stringValue }
        XCTAssertEqual(keys.count, 2)
        XCTAssertNotEqual(
            keys[0], keys[1],
            "the same key twice makes the second message silently become the first"
        )
    }

    /// A key the model *did* supply is a statement about intent — "this is a
    /// retry of that" — and overriding it would turn a deliberate retry into a
    /// duplicate. The same failure from the other side.
    func testAKeyTheModelSuppliedIsObeyed() async throws {
        let spy = SendSpy()
        var arguments = sendArguments()
        arguments["idempotency_key"] = .string("the-model-meant-this")

        _ = try await keyed(spy).call(name: "sage_message_send", arguments: arguments)

        XCTAssertEqual(
            spy.calls.first?.arguments["idempotency_key"]?.stringValue,
            "the-model-meant-this"
        )
    }

    /// Everything else passes through untouched, including the other messaging
    /// tools — this is one wire requirement, not a policy about sending.
    func testNothingElseIsRewritten() async throws {
        let spy = SendSpy()
        let tools = keyed(spy)

        _ = try await tools.call(name: "sage_recall", arguments: ["query": .string("ferries")])
        _ = try await tools.call(name: "sage_message_reply", arguments: ["payload": .string("ok")])

        for call in spy.calls {
            XCTAssertNil(
                call.arguments["idempotency_key"],
                "\(call.name) had a key added to it, which is not this decorator's business"
            )
        }
    }

    /// **A send whose outcome was never learned leaves its entry behind**, which
    /// is the entire diagnostic `AgentSendJournal` exists for: the process died
    /// or the node never answered, and an entry outliving the process says so.
    /// An answered send clears.
    func testTheJournalRecordsOnlyWhatWasNeverConfirmed() async throws {
        let spy = SendSpy()
        let tools = keyed(spy)
        let journal = AgentSendJournal(fileURL: journalFile)

        _ = try await tools.call(name: "sage_message_send", arguments: sendArguments())
        XCTAssertTrue(journal.entries().isEmpty, "a confirmed send is not a stranded one")

        spy.fail = true
        do {
            _ = try await tools.call(name: "sage_message_send", arguments: sendArguments())
            XCTFail("a failed send must be reported to the caller, not swallowed")
        } catch {}

        let stranded = journal.entries()
        XCTAssertEqual(stranded.count, 1, "a send whose outcome we never learned left no record")
        XCTAssertEqual(stranded.first?.to, "agent-74140c2d")
        XCTAssertTrue(stranded.first?.excerpt.contains("ferry") ?? false)
    }

    /// **The wiring, because everything above is true of a type nobody calls.**
    ///
    /// That is not hypothetical here: `SageAgentMessaging.send` is a correct,
    /// journalled, fully-tested implementation of this exact requirement with no
    /// production call sites, which is why the defect existed at all. A test
    /// that only exercised the decorator would repeat the mistake precisely.
    func testBothSurfacesActuallyWrapTheirToolSource() throws {
        for path in [
            "Sources/sage-voiced/main.swift",
            "Sources/MynahMac/Main/ConversationModel.swift"
        ] {
            let scan = SwiftSourceScan(try String(
                contentsOf: URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent(path),
                encoding: .utf8
            ))
            XCTAssertTrue(
                scan.contains("KeyedSends(wrapping:"),
                "\(path) builds its tool source without KeyedSends, so the model still has to "
                    + "invent an idempotency_key on that surface"
            )
        }
    }
}
