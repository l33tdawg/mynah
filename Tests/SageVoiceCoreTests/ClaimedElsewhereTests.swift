import XCTest
@testable import SageVoiceCore

/// What `sage_inbox` says about work another session is holding, and why every
/// one of these assertions is about a number that must not be invented.
///
/// **17 August 2026.** Another Mynah on a federated node sent this appliance a
/// message. The wake bus stayed healthy all day — `pending: true` every five
/// minutes — and the owner was never told. The message existed; it was held
/// under a claim taken by another session, so this appliance could not take it,
/// and the node said so in `claimed_elsewhere_count`. Mynah parsed the reply
/// and dropped the field, so the only sentence the log could form was "nothing
/// waiting", which was false.
///
/// The node's own contract, verbatim from the live 11.18.18 tool description:
/// *"claimed_elsewhere_count is an exact payload-free scalar for unfinished
/// work held by another session; an unavailable probe is explicit and never
/// presented as zero."* That last clause is the specification for most of what
/// follows.
final class ClaimedElsewhereTests: XCTestCase {

    // MARK: - The fact reaches a caller at all

    /// The count survives the parse and comes out of the read.
    func testAnExactCountIsCarriedOutOfTheRead() async throws {
        let tools = ClaimTools(reply: #"{"items":[],"claimed_elsewhere_count":2}"#)
        let read = try await SageAgentMessaging(tools: tools).inboxRead(limit: 20)
        XCTAssertEqual(read.claimedElsewhere, .exactly(2))
        XCTAssertEqual(read.claimedElsewhere.forLog, "2 held by another session")
    }

    /// The incident's exact shape: nothing claimable *and* something held. Both
    /// halves have to arrive, or the log line is a half-truth again.
    func testAnEmptyItemsListWithWorkHeldElsewhereReportsBoth() async throws {
        let tools = ClaimTools(reply: #"""
            {"count":0,"items":[],"message_count":0,"task_assignment_count":0,
             "claimed_elsewhere_count":1,
             "coordination_schema":"sage.inbox.v2"}
            """#)
        let read = try await SageAgentMessaging(tools: tools).inboxRead(limit: 20)
        XCTAssertTrue(read.items.isEmpty)
        XCTAssertEqual(read.claimedElsewhere, .exactly(1))
    }

    /// And an ordinary message still parses beside it, or the test above would
    /// pass just as well against a reader that returns nothing.
    func testItemsAndTheScalarDoNotInterfere() async throws {
        let tools = ClaimTools(reply: #"""
            {"count":1,"items":[{"message_id":"m-1","from":"Cerebrum","payload":"hello",
             "trust":"agent_untrusted","requires_reply":true}],
             "claimed_elsewhere_count":3}
            """#)
        let read = try await SageAgentMessaging(tools: tools).inboxRead(limit: 20)
        XCTAssertEqual(read.items.map(\.id), ["m-1"])
        XCTAssertEqual(read.claimedElsewhere, .exactly(3))
    }

    // MARK: - An unavailable probe is not a zero

    /// **The guard.** A node that could not answer sends its state *and* a
    /// count field, and the count beside a failed probe is not an answer.
    /// Reading it would print "none held by another session" over the top of
    /// "I could not look" — the substitution the node's own description forbids
    /// in so many words.
    func testAnUnavailableProbeIsNeverReportedAsZero() async throws {
        let tools = ClaimTools(reply: #"""
            {"items":[],"claimed_elsewhere_count":0,
             "claimed_elsewhere_state":"temporarily_unavailable"}
            """#)
        let read = try await SageAgentMessaging(tools: tools).inboxRead(limit: 20)
        XCTAssertEqual(read.claimedElsewhere, .probeUnavailable(state: "temporarily_unavailable"))

        let line = try XCTUnwrap(read.claimedElsewhere.forLog)
        XCTAssertTrue(line.contains("could not say"), line)
        XCTAssertFalse(line.contains("none"), "an unreadable probe was worded as an empty one: \(line)")
        XCTAssertFalse(line.contains("0 held"), "an unreadable probe was worded as a count: \(line)")
    }

    /// The node's own word is carried verbatim, because "unavailable" is a
    /// family rather than a literal and the log has to name which one it was.
    func testTheNodesStateWordSurvivesIntoTheLogLine() {
        for state in ["temporarily_unavailable", "claim_confirmation_error", "probe_failed"] {
            let claimed = SageAgentMessaging.claimedElsewhere(in: ["claimed_elsewhere_state": state])
            XCTAssertEqual(claimed, .probeUnavailable(state: state))
            XCTAssertTrue(claimed.forLog?.contains(state) == true, state)
        }
    }

    /// A state with no number at all is still not zero.
    func testAStateWithoutACountIsUnavailableAndNotEmpty() {
        let claimed = SageAgentMessaging.claimedElsewhere(in: [
            "claimed_elsewhere_state": "temporarily_unavailable"
        ])
        XCTAssertEqual(claimed, .probeUnavailable(state: "temporarily_unavailable"))
    }

    // MARK: - Silence is not zero either

    /// A node that never mentions the field — an older one, or a shape that
    /// changed — reports `notReported`. **Not `.exactly(0)`.** The vendored
    /// 11.18.14 and the installed 11.18.18 do not agree about every key in this
    /// envelope, and "this node does not say" has to stay distinguishable from
    /// "this node says nobody is holding anything".
    func testANodeThatDoesNotReportItIsNotAZero() async throws {
        let tools = ClaimTools(reply: #"{"count":0,"items":[],"message_count":0}"#)
        let read = try await SageAgentMessaging(tools: tools).inboxRead(limit: 20)
        XCTAssertEqual(read.claimedElsewhere, .notReported)
        XCTAssertNil(read.claimedElsewhere.forLog, "a fact the node never stated got a log line")
    }

    /// Whitespace is not a state. It would otherwise print an empty pair of
    /// brackets in the log and read as a node fault.
    func testAWhitespaceStateIsTreatedAsAbsent() {
        XCTAssertEqual(
            SageAgentMessaging.claimedElsewhere(in: ["claimed_elsewhere_state": "   "]),
            .notReported
        )
    }

    // MARK: - A real zero is still a real zero

    /// The opposite failure, and it is the one that would make this field
    /// useless: if every zero were treated as suspect, a healthy node holding
    /// nothing would look like a broken probe on every check.
    func testAnHonestZeroIsReportedAsAZero() {
        let claimed = SageAgentMessaging.claimedElsewhere(in: ["claimed_elsewhere_count": 0])
        XCTAssertEqual(claimed, .exactly(0))
        XCTAssertEqual(claimed.forLog, "none held by another session")
    }

    /// A healthy state word must not trip the trouble check. `available`
    /// contains `avail` and must pass; `unavailable` contains `unavail` and
    /// must not.
    func testAHealthyStateWordDoesNotSuppressTheCount() {
        for state in ["available", "exact", "ok"] {
            XCTAssertEqual(
                SageAgentMessaging.claimedElsewhere(in: [
                    "claimed_elsewhere_state": state, "claimed_elsewhere_count": 1
                ]),
                .exactly(1),
                state
            )
        }
    }

    // MARK: - Reading the scalar costs nothing

    /// **One `sage_inbox` call, and this test is the reason the field is read
    /// off the reply that was already fetched rather than by asking again.**
    /// Every `sage_inbox` call atomically claims the rows it returns, under a
    /// durable receipt with no expiry — so a second read to "just get the
    /// counters" is how a diagnostic strands the owner's message under a dead
    /// session. Both entry points are pinned.
    func testTheReadAsksTheNodeExactlyOnce() async throws {
        let read = ClaimTools(reply: #"{"items":[],"claimed_elsewhere_count":1}"#)
        _ = try await SageAgentMessaging(tools: read).inboxRead(limit: 20)
        let readCalls = await read.callCount("sage_inbox")
        XCTAssertEqual(readCalls, 1, "inboxRead claimed the inbox \(readCalls) times")

        let plain = ClaimTools(reply: #"{"items":[],"claimed_elsewhere_count":1}"#)
        _ = try await SageAgentMessaging(tools: plain).inbox(limit: 20)
        let plainCalls = await plain.callCount("sage_inbox")
        XCTAssertEqual(plainCalls, 1, "inbox claimed the inbox \(plainCalls) times")
    }

    /// The plain read is the same read minus the scalar — it must not have
    /// grown a second behaviour while this was added.
    func testThePlainInboxStillReturnsTheItems() async throws {
        let tools = ClaimTools(reply: #"""
            {"items":[{"message_id":"m-9","from":"codex","payload":"ping"}],
             "claimed_elsewhere_count":4}
            """#)
        let items = try await SageAgentMessaging(tools: tools).inbox(limit: 20)
        XCTAssertEqual(items.map(\.id), ["m-9"])
    }

    /// An unreadable reply is still a failure rather than a read reporting
    /// `notReported` — the new field must not have given the parser a way to
    /// call a broken answer a successful one.
    func testAnUnreadableReplyStillThrowsRatherThanReportingNothingHeld() async {
        let tools = ClaimTools(reply: "not json at all")
        do {
            let read = try await SageAgentMessaging(tools: tools).inboxRead(limit: 20)
            XCTFail("an unreadable reply came back as \(read.claimedElsewhere)")
        } catch {
            // The point.
        }
    }
}

// MARK: - A node that says one thing and counts how often it was asked

private actor ClaimTools: ToolProviding {
    private let reply: String
    private var calls: [String] = []

    init(reply: String) { self.reply = reply }

    func listTools() async throws -> [MCPTool] { [] }

    func call(name: String, arguments: [String: JSONValue]) async throws -> String {
        calls.append(name)
        return reply
    }

    func callCount(_ name: String) -> Int { calls.filter { $0 == name }.count }
}
