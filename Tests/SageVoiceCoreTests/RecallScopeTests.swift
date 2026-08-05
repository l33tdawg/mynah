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

    /// **Recall has to work while `sage_status` does not.**
    ///
    /// Discovery calls `sage_status`, and on 11.16.4 that does not return for
    /// this appliance — it spends the client's full 90-second timeout. Passing
    /// the call through unscoped would look like the cautious choice and would
    /// mean the owner's memory is unreachable for as long as that bug lives,
    /// because the unscoped form is exactly what the node refuses.
    ///
    /// So an undiscovered scope falls back to the two domains this appliance is
    /// known to use. Discovery adds to them; it does not establish them.
    func testWithNothingDiscoveredItFallsBackToTheDomainsItIsKnownToUse() async throws {
        let spy = RecallSpy()
        spy.repliesByDomain["mynah-home"] = full

        let reply = try await recall(spy)

        XCTAssertEqual(spy.calls.map(\.domain), ReadableDomains.wellKnown)
        XCTAssertEqual(reply, full)
        XCTAssertTrue(ReadableDomains.wellKnown.contains(SageRitual.memoryDomain))
        XCTAssertTrue(ReadableDomains.wellKnown.contains("mynah-home"))
    }

    /// A failed discovery still counts as having asked.
    ///
    /// It did not, for one build: `isFresh` required a non-empty result, so an
    /// appliance whose node never answers would pay a 90-second timeout at
    /// every single launch, forever, to learn the same nothing.
    func testAFailedDiscoveryStillBacksOffForADay() {
        let attemptedAndFailed = ReadableDomains(domains: [], checkedAt: Date())

        XCTAssertTrue(attemptedAndFailed.isFresh())
        XCTAssertEqual(attemptedAndFailed.searchOrder, ReadableDomains.wellKnown)
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

    /// A real `sage_status` reply, signed as the appliance's own key against the
    /// owner's live node — SAGE 11.17.9, app-v26 — with only the agent id
    /// redacted.
    ///
    /// **The fixture this replaces was invented, and it encoded a shape the node
    /// had stopped sending.** It was `{"home_domain":…,"by_domain":{…}}`, and
    /// `by_domain` does not exist in an app-v26 caller-scoped status; SAGE's own
    /// route-security test asserts it is forbidden there. Both this test and the
    /// production code read it, so both agreed with each other and neither
    /// agreed with the node — and the suite stayed green while recall quietly
    /// collapsed from every readable subject to two.
    ///
    /// Captured rather than written, for that reason and no other.
    private func capturedStatus() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/sage_status-11.17.9-appv26-appliance.json")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The search order is what this agent OWNS, home first.
    ///
    /// The owner's ruling on being shown that recall covered two of seventeen
    /// readable subjects: *"that is correct - that means the rbac is working as
    /// intended"*. Readable is everything policy lets it see — most of his
    /// working life, across every project on the node. Owned is the three
    /// subjects this appliance is responsible for.
    func testTheSearchOrderIsWhatTheAgentOwnsWithHomeFirst() throws {
        let discovered = ReadableDomains.fromStatus(try capturedStatus())

        XCTAssertEqual(
            discovered?.domains,
            ["mynah-home", "sage-v3.6.0-audit", "user-interaction"]
        )
    }

    /// **The seventeen readable subjects are right there and must stay out.**
    ///
    /// This is the test that would have caught the widening. `readable_domains`
    /// is in the same reply, it is longer, and reading it would look like an
    /// improvement — the previous behaviour did exactly that through
    /// `by_domain`, and on 3 August the appliance logged a search order roughly
    /// seven hundred subjects long covering other people's projects.
    func testTheSeventeenReadableSubjectsAreNotSearched() throws {
        let status = try capturedStatus()
        XCTAssertTrue(status.contains("dhillon-music"), "the fixture must still carry the readable set")

        let discovered = try XCTUnwrap(ReadableDomains.fromStatus(status))

        XCTAssertFalse(discovered.domains.contains("dhillon-music"))
        XCTAssertFalse(discovered.domains.contains("voice-interface"))
        XCTAssertEqual(discovered.domains.count, 3, "owned, not readable")
    }

    /// Where a write belongs, asked rather than assumed.
    ///
    /// `SageRitual.memoryDomain` used to be `voice-interface` — a subject this
    /// appliance can read, does not own, and which belongs to the developer's
    /// own agent. Every episodic turn went there. The owner, 5 August: *"we
    /// should make it default to its own home domain bro - voice-interface is
    /// YOUR DOMAIN - we will transfer it back to you"*.
    func testTheHomeDomainIsReadFromTheNode() throws {
        XCTAssertEqual(ReadableDomains.homeDomain(inStatus: try capturedStatus()), "mynah-home")
        XCTAssertNil(ReadableDomains.homeDomain(inStatus: "node is starting up"))
        XCTAssertNil(
            ReadableDomains.homeDomain(inStatus: #"{"home_domain":""}"#),
            "an empty name is not an answer"
        )
    }

    /// The node appends prose after its JSON often enough that this project has
    /// already shipped a bug for it once — `sage_backlog` reporting zero tasks
    /// against a full board. `SageReply` is the fix and this is it applied.
    func testTrailingNodeProseDoesNotDefeatIt() throws {
        let noisy = try capturedStatus() + "\n\n[SAGE] Reminder: call sage_turn with the current topic."

        XCTAssertEqual(ReadableDomains.fromStatus(noisy)?.domains.first, "mynah-home")
    }

    func testAnUnreadableReplyDiscoversNothingRatherThanGuessing() {
        XCTAssertNil(ReadableDomains.fromStatus("node is starting up"))
    }

    /// A node that names a home but no owned set still gets a search order.
    ///
    /// Not a hypothetical: `owned_domains` is absent from the legacy
    /// pre-app-v23 branch of `toolStatus`, and an appliance that discovered
    /// nothing would fall back to `wellKnown` and search a constant.
    func testAHomeWithNoOwnedListIsStillASearchOrder() {
        XCTAssertEqual(
            ReadableDomains.fromStatus(#"{"home_domain":"mynah-home","can_read":true}"#)?.domains,
            ["mynah-home"]
        )
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

    func testARecordThatWasNeverAskedIsNotFresh() {
        XCTAssertFalse(ReadableDomains(domains: ["mynah-home"], checkedAt: nil).isFresh())
    }
}
