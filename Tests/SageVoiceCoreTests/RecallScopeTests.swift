import XCTest
@testable import SageVoiceCore

/// Recording double: remembers every call, answers from a table keyed by the
/// `domain` argument so a test can make one domain hold something and the rest
/// hold nothing.
private final class RecallSpy: ToolProviding, @unchecked Sendable {
    var calls: [(name: String, domain: String?)] = []
    var repliesByDomain: [String: String] = [:]
    var unscopedReply = #"{"memories":[],"total_count":0}"#
    var failingDomains: Set<String> = []

    func listTools() async throws -> [MCPTool] { [] }

    func call(name: String, arguments: [String: JSONValue]) async throws -> String {
        var domain: String?
        if case .string(let value)? = arguments["domain"] { domain = value }
        calls.append((name, domain))
        if let domain, failingDomains.contains(domain) {
            throw BrainBackendError.unreachable("agent does not have read access")
        }
        guard let domain else { return unscopedReply }
        return repliesByDomain[domain] ?? #"{"memories":[],"total_count":0}"#
    }
}

private let full = #"{"memories":[{"content":"the chiro is Wednesday"}],"total_count":1}"#
private let empty = #"{"memories":[],"total_count":0}"#

/// **11.16.4 stopped answering recall that names no domain**, and the model
/// leaves it out most of the time — so "what do you remember about X" became a
/// refusal rather than an answer. Tested on the owner's own node by Mynah:
/// *"An unscoped broad query fails with 'Recall query too broad: too many
/// candidates require authorization' … With a domain scoped, recall works
/// fine."*
final class ScopedRecallTests: XCTestCase {

    private var directory = URL(fileURLWithPath: NSTemporaryDirectory())
    private var domainsFile: URL { directory.appendingPathComponent("domains.json") }

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("recall-scope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func writeDomains(_ domains: [String]) {
        ReadableDomains(domains: domains, checkedAt: Date()).save(to: domainsFile)
    }

    private func recall(_ spy: RecallSpy, query: String = "the chiro") async throws -> String {
        try await ScopedRecall(wrapping: spy, domainsFile: domainsFile)
            .call(name: "sage_recall", arguments: ["query": .string(query)])
    }

    func testAnUnscopedRecallIsGivenTheDomainTheModelLeftOut() async throws {
        writeDomains(["mynah-home"])
        let spy = RecallSpy()
        spy.repliesByDomain["mynah-home"] = full

        let reply = try await recall(spy)

        XCTAssertEqual(spy.calls.map(\.domain), ["mynah-home"])
        XCTAssertEqual(reply, full)
    }

    /// The owner's rule: *"scope it to what it writes to and needs read from"*.
    /// Home holds its own work; the domain it files what it is told into is a
    /// different one, and an answer in either is an answer.
    func testItSearchesOnPastAHomeDomainThatHoldsNothing() async throws {
        writeDomains(["mynah-home", "voice-interface"])
        let spy = RecallSpy()
        spy.repliesByDomain["mynah-home"] = empty
        spy.repliesByDomain["voice-interface"] = full

        let reply = try await recall(spy)

        XCTAssertEqual(spy.calls.map(\.domain), ["mynah-home", "voice-interface"])
        XCTAssertEqual(reply, full)
    }

    /// A domain that refuses is not a domain that is empty, and neither is the
    /// end of the search.
    func testARefusedDomainDoesNotStopTheRest() async throws {
        writeDomains(["shared-team", "mynah-home"])
        let spy = RecallSpy()
        spy.failingDomains = ["shared-team"]
        spy.repliesByDomain["mynah-home"] = full

        let reply = try await recall(spy)

        XCTAssertEqual(reply, full)
    }

    /// Nothing anywhere is a real answer and must reach the model as the node's
    /// own words, not as an error. "I have nothing on that" and "I could not
    /// look" are different sentences for the owner.
    func testNothingAnywhereComesBackAsAnEmptyResultRatherThanAFailure() async throws {
        writeDomains(["mynah-home", "voice-interface"])
        let spy = RecallSpy()

        let reply = try await recall(spy)

        XCTAssertEqual(reply, empty)
        XCTAssertEqual(spy.calls.count, 2)
    }

    /// A model that named a domain has said something precise. Overriding it
    /// would answer a question nobody asked — including when the honest answer
    /// is that this particular domain holds nothing.
    func testADomainTheModelChoseIsLeftAlone() async throws {
        writeDomains(["mynah-home"])
        let spy = RecallSpy()
        spy.repliesByDomain["mynah-home"] = full

        let reply = try await ScopedRecall(wrapping: spy, domainsFile: domainsFile).call(
            name: "sage_recall",
            arguments: ["query": .string("x"), "domain": .string("voice-interface")]
        )

        XCTAssertEqual(spy.calls.map(\.domain), ["voice-interface"])
        XCTAssertEqual(reply, empty)
    }

    /// Before the first discovery there is nothing to scope to, and inventing a
    /// domain would be worse than passing the call through: on a node that
    /// still answers unscoped recall this is simply correct, and on one that
    /// does not, the owner gets the node's refusal rather than our guess.
    func testWithNothingDiscoveredTheCallGoesThroughUntouched() async throws {
        let spy = RecallSpy()
        spy.unscopedReply = full

        let reply = try await recall(spy)

        XCTAssertEqual(spy.calls.map(\.domain), [nil])
        XCTAssertEqual(reply, full)
    }

    func testEveryOtherToolIsUntouched() async throws {
        writeDomains(["mynah-home"])
        let spy = RecallSpy()

        _ = try await ScopedRecall(wrapping: spy, domainsFile: domainsFile)
            .call(name: "sage_remember", arguments: ["content": .string("x")])

        XCTAssertEqual(spy.calls.map(\.name), ["sage_remember"])
        XCTAssertEqual(spy.calls.map(\.domain), [nil])
    }
}

/// What the node says this agent may search, rather than what we assume.
///
/// `MemoriesView` already carries the warning: the appliance's home on the
/// owner's node is `mynah-home`, a name nothing in this codebase would have
/// derived. `sage_status` returns it without being asked, so a constant here
/// would be a fourth place obliged to agree with the node — and a silent
/// mismatch is the exact bug this project keeps paying for.
final class ReadableDomainsTests: XCTestCase {

    private let status = """
    {"home_domain":"mynah-home","by_domain":{"mynah-home":12,"shared-team":3},"can_read":true}
    """

    func testTheHomeDomainLeadsAndTheWriteDomainFollows() {
        let discovered = ReadableDomains.fromStatus(status, writesTo: "voice-interface")

        XCTAssertEqual(discovered?.domains, ["mynah-home", "voice-interface", "shared-team"])
    }

    /// A domain with nothing in it yet is still where the next `sage_remember`
    /// lands, so it is searched whether or not the node's counts mention it.
    func testTheWriteDomainIsIncludedEvenWhenTheNodeDidNotListIt() {
        let discovered = ReadableDomains.fromStatus(
            #"{"home_domain":"mynah-home","by_domain":{"mynah-home":1}}"#,
            writesTo: "voice-interface"
        )

        XCTAssertEqual(discovered?.domains, ["mynah-home", "voice-interface"])
    }

    /// The node appends prose after its JSON often enough that this project has
    /// already shipped a bug for it once — `sage_backlog` reporting zero tasks
    /// against a full board. `SageReply` is the fix and this is it applied.
    func testTrailingNodeProseDoesNotDefeatIt() {
        let noisy = status + "\n\n[SAGE] Reminder: call sage_turn with the current topic."

        XCTAssertEqual(ReadableDomains.fromStatus(noisy, writesTo: "voice-interface")?.domains.first, "mynah-home")
    }

    func testAnUnreadableReplyDiscoversNothingRatherThanGuessing() {
        XCTAssertNil(ReadableDomains.fromStatus("node is starting up", writesTo: "voice-interface"))
    }

    /// Rediscovered daily, not per launch. The answer changes when a person
    /// grants this agent something in CEREBRUM — rare, deliberate, and not
    /// worth a round trip at every start-up. The owner: *"maybe not every
    /// single conversation start, but you know what i mean"*.
    func testADayOldRecordIsAskedAgain() {
        let day = ReadableDomains.freshFor
        let record = ReadableDomains(domains: ["mynah-home"], checkedAt: Date())

        XCTAssertTrue(record.isFresh(now: Date().addingTimeInterval(day - 60)))
        XCTAssertFalse(record.isFresh(now: Date().addingTimeInterval(day + 60)))
    }

    func testAnEmptyRecordIsNeverFresh() {
        XCTAssertFalse(ReadableDomains(domains: [], checkedAt: Date()).isFresh())
    }
}
