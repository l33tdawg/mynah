import XCTest
@testable import MynahMac
@testable import SageVoiceCore

/// The agents pane, and the claims it must never get wrong.
///
/// This screen answers three questions the owner asked: who is on this Mac's
/// SAGE, what is Mynah itself allowed to do, and what is out there on the
/// network. Each fails silently in a different way. A roster that cannot tell
/// "your node is locked" from "you have no agents" tells an owner with twenty
/// agents that they have none — which is what the product did when he asked and
/// got "zero connected agents". A permissions section that says "no grants" on
/// the strength of a call that was refused invents the most consequential fact
/// on the screen.
///
/// **The fixtures are the real payloads.** The roster ones are shaped from
/// `GET /v1/agents` on the owner's own node, including the detail the whole
/// screen turns on: a row with no memories omits `memory_count` entirely.
final class AgentRosterReadingTests: XCTestCase {

    /// Four rows from the live node, trimmed to the fields this screen reads.
    /// The appliance's row keeps its shape exactly — note the absent
    /// `memory_count`.
    private let payload = """
    {"agents":[
      {"agent_id":"74140c2d","name":"Mynah - Sage Voice Bridge","registered_name":"agent-74140c2d",
       "role":"member","status":"active","clearance":1,"last_seen":"2026-07-28T23:55:58.92Z",
       "on_chain_height":22271,"capabilities":30},
      {"agent_id":"9e618211","name":"claude-code/l33tdawg","registered_name":"claude-code/l33tdawg",
       "role":"member","status":"active","clearance":1,"memory_count":4068},
      {"agent_id":"4a6edaa7","name":"codex-sage","registered_name":"codex-sage",
       "role":"member","status":"active","clearance":2,"memory_count":1558},
      {"agent_id":"b036b562","name":"macmini","registered_name":"macmini","role":"admin",
       "status":"inactive","clearance":3,"memory_count":105}
    ]}
    """

    /// The appliance's own id, as the derivation from its key file produces it.
    /// Passed in rather than read from disk so this suite says nothing about the
    /// machine it runs on.
    private let ourID = "74140c2d"

    private func roster() throws -> AgentRoster {
        try XCTUnwrap(AgentRosterReading.roster(fromToolText: payload, applianceID: ourID))
    }

    // MARK: What the node actually says

    func testEveryRegisteredAgentIsListed() throws {
        XCTAssertEqual(try roster().agents.count, 4)
    }

    /// The RBAC facts the owner asked to see, in the node's own vocabulary, so a
    /// row here matches the same agent in CEREBRUM.
    func testAnAgentCarriesItsRoleAndClearance() throws {
        let macmini = try XCTUnwrap(roster().agents.first { $0.name == "macmini" })

        XCTAssertEqual(macmini.role, "admin")
        XCTAssertEqual(macmini.clearance, 3)
        XCTAssertEqual(macmini.standingLine, "admin · clearance 3")
    }

    /// **The one the whole screen turns on.** The node omits `memory_count`
    /// rather than sending zero, and the appliance's own row is the one that
    /// omits it. Reading absent as "unknown" would hide the fact that Mynah has
    /// never managed to save anything.
    func testAnAbsentMemoryCountMeansNoneRatherThanUnknown() throws {
        let appliance = try XCTUnwrap(roster().appliance)

        XCTAssertEqual(appliance.memoryCount, 0)
        XCTAssertEqual(appliance.memoryLine, "nothing stored yet")
    }

    func testMemoryCountsAreCarriedThrough() throws {
        let claude = try XCTUnwrap(roster().agents.first { $0.name == "claude-code/l33tdawg" })

        XCTAssertEqual(claude.memoryCount, 4068)
        // The digit grouping is the reader's locale's business; the noun is ours.
        XCTAssertTrue(claude.memoryLine.hasSuffix("memories"))
    }

    func testOneMemoryIsNotPluralised() {
        let agent = NodeAgent(
            id: "x", name: "x", role: "member", clearance: 1, memoryCount: 1,
            isActive: true, lastSeen: nil, capabilities: 0, isThisAppliance: false
        )
        XCTAssertEqual(agent.memoryLine, "1 memory")
    }

    func testADeactivatedAgentIsStillListed() throws {
        let macmini = try XCTUnwrap(roster().agents.first { $0.name == "macmini" })
        XCTAssertFalse(macmini.isActive)
    }

    // MARK: Which row is Mynah

    /// Matched on the agent id derived from the appliance's own key.
    func testTheApplianceRecognisesItsOwnRow() throws {
        let roster = try roster()

        XCTAssertEqual(roster.appliance?.name, SageRitual.applianceDisplayName)
        XCTAssertEqual(roster.others.count, 3)
        XCTAssertFalse(roster.others.contains { $0.isThisAppliance })
    }

    func testAnUnregisteredApplianceIsAnAbsentRowRatherThanAWrongOne() throws {
        let roster = try XCTUnwrap(AgentRosterReading.roster(
            fromToolText: """
            {"agents":[{"agent_id":"1","name":"claude-code/sage","role":"member","clearance":1}]}
            """,
            applianceID: ourID
        ))

        XCTAssertNil(roster.appliance, "the screen picked somebody else's row as Mynah's")
        XCTAssertEqual(roster.others.count, 1)
    }

    /// Busiest first: the agents the owner actually runs, rather than whatever
    /// auto-registered first.
    func testOtherAgentsAreOrderedByHowMuchTheyHaveStored() throws {
        XCTAssertEqual(
            try roster().others.map(\.name),
            ["claude-code/l33tdawg", "codex-sage", "macmini"]
        )
    }

    // MARK: Robustness

    /// A row with no display name still exists and still holds memories.
    func testARowWithNoDisplayNameFallsBackToItsRegisteredName() throws {
        let roster = try XCTUnwrap(AgentRosterReading.roster(
            fromToolText: #"{"agents":[{"agent_id":"1","name":"","registered_name":"agent-1"}]}"#,
            applianceID: ourID
        ))

        XCTAssertEqual(roster.agents.first?.name, "agent-1")
    }

    func testARowWithNoIdIsNotAnAgent() throws {
        let roster = try XCTUnwrap(AgentRosterReading.roster(
            fromToolText: #"{"agents":[{"name":"ghost"},{"agent_id":"1","name":"real"}]}"#,
            applianceID: ourID
        ))

        XCTAssertEqual(roster.agents.map(\.name), ["real"])
    }

    /// Anything that is not the documented shape reads as "could not be read",
    /// never as an empty node. That difference is the whole point of the screen.
    func testAReplyWithoutAnAgentsArrayIsUnreadableRatherThanEmpty() {
        XCTAssertNil(AgentRosterReading.roster(fromToolText: #"{"error":"unauthorized"}"#))
        XCTAssertNil(AgentRosterReading.roster(fromToolText: "not json at all"))
        XCTAssertNil(AgentRosterReading.roster(fromToolText: ""))
    }

    /// A node with nobody on it is a readable answer, and a different thing from
    /// a broken one.
    func testAnEmptyAgentsArrayIsAReadableEmptyNode() throws {
        let roster = try XCTUnwrap(AgentRosterReading.roster(fromToolText: #"{"agents":[]}"#, applianceID: ourID))
        XCTAssertTrue(roster.agents.isEmpty)
    }

    // MARK: Where it reads from

    /// The roster is fetched from the one endpoint an encrypted node still
    /// answers unsigned. Checked against the owner's node: `/v1/agents` returns
    /// 200 while `/v1/dashboard/*` and `/v1/access/grants/*` return 401.
    func testTheRosterIsReadFromThePublicAgentsEndpoint() {
        XCTAssertEqual(
            NodeAgentDirectory.defaultEndpoint(environment: [:]).absoluteString,
            "http://127.0.0.1:8080/v1/agents"
        )
    }

    /// A roster fetched from a stranger's node would be somebody else's agents
    /// rendered as the owner's.
    func testANodeAddressOffThisMachineIsIgnored() {
        XCTAssertEqual(
            NodeAgentDirectory.defaultEndpoint(environment: ["SAGE_API_URL": "http://10.0.0.9:8080"]),
            NodeAgentDirectory.defaultEndpoint(environment: [:])
        )
        XCTAssertEqual(
            NodeAgentDirectory.defaultEndpoint(environment: ["SAGE_API_URL": "http://127.0.0.1:9999"])
                .absoluteString,
            "http://127.0.0.1:9999/v1/agents"
        )
    }
}

// MARK: - Looking for other SAGEs

/// The owner's "look for agents on the network" button.
final class FederationReadingTests: XCTestCase {

    /// What `sage_federation` returned on the owner's node today, banner and
    /// all. Note what is *not* in it: with no peers, the domain and agent keys
    /// are absent rather than empty.
    private let liveEmptyReply = """
    [SAGE Auto-Connect] Your persistent memory is online.

    Several paragraphs of boot instructions addressed to an AI agent.

    ---

    {
      "connections": [],
      "message": "Use sage_recall with scope=auto and one of these exact domains.",
      "total": 0
    }
    """

    func testTheLiveEmptyReplyReadsAsNoPeersRatherThanAFailure() throws {
        let report = try XCTUnwrap(FederationReading.report(fromToolText: liveEmptyReply))

        XCTAssertTrue(report.foundNothing)
        XCTAssertTrue(report.connections.isEmpty)
        XCTAssertTrue(report.readableDomains.isEmpty)
    }

    /// The populated shape, from `mcp-tools.md`. This one could not be checked
    /// against a live peer — this Mac has none — so the decoder is written to
    /// the documented keys and tolerates every one of them being absent.
    func testAPeerIsReadWithItsDomainsAndAgents() throws {
        let report = try XCTUnwrap(FederationReading.report(fromToolText: """
        {"connections":[{"remote_chain_id":"sage-ana-9f2c1d7e","network_name":"Ana's SAGE",
                         "capabilities":["recall"]}],
         "shared_read_domains":["household","travel-plans"],
         "copy_offered_domains":["recipes"],
         "remote_agents":[{"agent_id":"r1","name":"Perplexity","network_name":"Ana's SAGE"}],
         "total":1}
        """))

        XCTAssertEqual(report.connections.map(\.title), ["Ana's SAGE"])
        XCTAssertEqual(report.readableDomains, ["household", "travel-plans"])
        XCTAssertEqual(report.copyOfferedDomains, ["recipes"])
        XCTAssertEqual(report.remoteAgents.map(\.name), ["Perplexity"])
        XCTAssertFalse(report.foundNothing)
    }

    /// A peer that publishes no network name is "a SAGE on your network", not a
    /// machine name this app made up.
    func testAnUnnamedPeerIsNotGivenAName() throws {
        let report = try XCTUnwrap(FederationReading.report(fromToolText: """
        {"connections":[{"remote_chain_id":"abc123"}]}
        """))

        XCTAssertEqual(report.connections.first?.title, "A SAGE on your network")
    }

    /// A reply that is not a federation reply must not read as "no peers" —
    /// that would turn a broken call into a reassuring sentence.
    func testAReplyWithoutConnectionsIsUnreadableRatherThanReassuring() {
        XCTAssertNil(FederationReading.report(fromToolText: #"{"error":"tool failed"}"#))
        XCTAssertNil(FederationReading.report(fromToolText: "the node fell over"))
    }
}

// MARK: - What the screen says when it cannot see

@MainActor
final class AgentsModelTests: XCTestCase {

    private func model(
        roster: AgentRoster? = nil,
        trouble: AgentTrouble? = nil,
        scan: PreviewFederationScan = PreviewFederationScan()
    ) -> AgentsModel {
        AgentsModel(
            source: PreviewAgentDirectory(fixture: roster ?? .empty, trouble: trouble),
            federation: scan
        )
    }

    /// An empty node is a result, not a failure. If either could produce the
    /// other's state, the two would render the same.
    func testANodeWithNobodyOnItIsAResultAndNotAFailure() async {
        let model = model(roster: .empty)
        await model.load()

        XCTAssertEqual(model.phase, .ready)
        XCTAssertTrue(model.roster.agents.isEmpty)
    }

    /// The failure the whole screen exists to prevent: twenty agents on the
    /// node, a caller that cannot sign, and a screen that says "you have none".
    func testALockedNodeNeverReadsAsHavingNoAgents() async {
        let model = model(trouble: .locked)
        await model.load()

        XCTAssertEqual(model.phase, .failed(.locked))
    }

    /// Every failure sentence has to leave the agents' existence alone. An owner
    /// reading "you have no agents" because their node is starting up goes and
    /// re-registers agents that were never lost.
    func testNoFailureClaimsTheAgentsAreGone() {
        for trouble in [AgentTrouble.notSetUp, .unreachable, .locked, .refused, .unreadable] {
            let sentence = (trouble.headline + " " + trouble.explanation).lowercased()
            XCTAssertFalse(sentence.contains("no agents"), "\(trouble) claimed the agents are gone")
            XCTAssertFalse(sentence.contains("nobody"), "\(trouble) claimed the agents are gone")
        }
    }

    /// A "Try again" that cannot succeed teaches the owner their buttons are
    /// decorative. A locked node is unlocked in CEREBRUM, not by retrying.
    func testOnlyFailuresARetryCouldFixOfferOne() {
        XCTAssertFalse(AgentTrouble.locked.isWorthRetrying)
        XCTAssertFalse(AgentTrouble.notSetUp.isWorthRetrying)
        XCTAssertTrue(AgentTrouble.unreachable.isWorthRetrying)
        XCTAssertTrue(AgentTrouble.unreadable.isWorthRetrying)
    }

    // MARK: The scan

    func testTheScanStartsIdleAndOnlyRunsWhenAsked() async {
        let model = model(roster: .empty)
        await model.load()

        XCTAssertEqual(model.scan, .idle, "the network was scanned without the owner asking")
    }

    func testAScanReportsWhatItFound() async {
        let model = model(scan: PreviewFederationScan(report: PreviewFederationScan.peer))
        await model.lookForAgents()

        XCTAssertEqual(model.scan, .found(PreviewFederationScan.peer))
    }

    /// A network question that fails must not take the local roster down with
    /// it. They are different questions with different answers.
    func testAFailedScanLeavesTheRosterAlone() async {
        let model = model(
            roster: PreviewAgentDirectory.realistic,
            scan: PreviewFederationScan(trouble: .unreachable)
        )
        await model.load()
        await model.lookForAgents()

        XCTAssertEqual(model.scan, .failed(.unreachable))
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.roster.agents.count, 4, "a failed network scan emptied the local list")
    }
}

// MARK: - What an agent can actually do

/// SAGE's app-v22 capability mask, read as answers.
///
/// The masks here are the real ones: `30` is what a key that self-registers
/// after app-v22 receives, and it is what the owner's appliance carries while
/// nineteen other agents on the same node carry none. `15` is SAGE's named
/// companion preset for this product.
final class AgentPermissionsTests: XCTestCase {

    private let selfRegistered = AgentPermissions(mask: 30)
    private let companion = AgentPermissions(mask: 15)
    private let unrestricted = AgentPermissions(mask: 0)

    /// The state the owner hit: an agent that looks like every other member and
    /// cannot save a thing.
    func testTheSelfRegisteredMaskClosesEveryRouteToSaving() {
        XCTAssertTrue(selfRegistered.isRestricted)
        XCTAssertTrue(selfRegistered.writesAreRestricted)
        XCTAssertTrue(selfRegistered.needsASubjectAssigned)
        XCTAssertEqual(
            selfRegistered.writingLine,
            "Can't save anything until it's given a subject of its own."
        )
    }

    func testTheSelfRegisteredMaskAlsoClosesOtherSages() {
        XCTAssertFalse(selfRegistered.canReachOtherSages)
        XCTAssertFalse(selfRegistered.readsAcrossSubjects)
    }

    /// The companion preset is not simply "fewer denials": it *adds* reading
    /// across subjects and reopens federated routing, and the screen should say
    /// what it grants rather than describing it purely as refusals.
    func testTheCompanionPresetReadsWidelyAndReachesOtherSages() {
        XCTAssertTrue(companion.readsAcrossSubjects)
        XCTAssertTrue(companion.canReachOtherSages)
        XCTAssertFalse(companion.additions.isEmpty)
    }

    /// And it still cannot claim a subject — which is why ownership has to be
    /// assigned rather than granted, and why the preset alone is only half the
    /// remedy.
    func testTheCompanionPresetStillNeedsASubjectAssignedToIt() {
        XCTAssertTrue(companion.needsASubjectAssigned)
        XCTAssertTrue(companion.writesAreRestricted)
    }

    /// Nineteen of twenty agents on the owner's node. No mask, no restrictions,
    /// no marks on the row.
    func testNoMaskMeansNoRestrictions() {
        XCTAssertFalse(unrestricted.isRestricted)
        XCTAssertFalse(unrestricted.writesAreRestricted)
        XCTAssertTrue(unrestricted.reasons.isEmpty)
        XCTAssertEqual(unrestricted.writingLine, "Can save what you tell it.")
    }

    /// The direction SAGE's own team asked for: the effective result and the
    /// reason, in plain words. A bit number in a sentence is a fact about a
    /// codebase the owner will never read.
    func testNoReasonEverShowsABitNumberOrAConstantName() {
        for mask in [UInt32(30), 15, 2, 4, 8, 16, 1, 31] {
            for line in AgentPermissions(mask: mask).reasons + AgentPermissions(mask: mask).additions {
                XCTAssertFalse(line.contains("bit "), "a reason exposed a bit: \(line)")
                XCTAssertFalse(line.contains("Deny"), "a reason exposed a constant name: \(line)")
                XCTAssertFalse(line.contains("mask"), "a reason exposed the mask: \(line)")
            }
        }
    }

    /// Each denial names the thing that cannot happen, and the foreign-write one
    /// carries the fact that makes the obvious fix useless.
    func testEachRestrictionIsExplainedAsSomethingItCannotDo() {
        let reasons = selfRegistered.reasons.joined(separator: " ")

        XCTAssertTrue(reasons.contains("shared subjects"))
        XCTAssertTrue(reasons.contains("can't claim a subject of its own"))
        XCTAssertTrue(reasons.contains("Being granted access"))
        XCTAssertTrue(reasons.contains("other SAGEs"))
    }

    /// A mask carrying only the read capability restricts nothing about writing,
    /// and the screen must not describe it as a problem.
    func testACapabilityOnlyMaskIsNotAWriteProblem() {
        let readAll = AgentPermissions(mask: 1)

        XCTAssertTrue(readAll.isRestricted, "the mask is not zero, so the row is not ordinary")
        XCTAssertFalse(readAll.writesAreRestricted)
        XCTAssertEqual(readAll.writingLine, "Can save what you tell it.")
        XCTAssertTrue(readAll.reasons.isEmpty)
    }

    /// The mask is read off the public roster — no signature, no unlock.
    func testTheMaskIsReadFromThePublicRoster() throws {
        let roster = try XCTUnwrap(AgentRosterReading.roster(
            fromToolText: """
            {"agents":[
              {"agent_id":"1","name":"Mynah - Sage Voice Bridge","role":"member","clearance":1,
               "capabilities":30},
              {"agent_id":"2","name":"Claude Code","role":"member","clearance":1,"memory_count":4068}
            ]}
            """,
            applianceID: "1"
        ))

        XCTAssertEqual(roster.appliance?.capabilities, 30)
        XCTAssertTrue(roster.appliance?.permissions.isRestricted == true)
        // The nineteen others: the field is absent, and absent is unrestricted.
        XCTAssertEqual(roster.others.first?.capabilities, 0)
        XCTAssertFalse(roster.others.first?.permissions.isRestricted == true)
    }
}

// MARK: - Against the real node

/// The end-to-end path, run against whatever SAGE is on this machine.
///
/// Skipped unless `MYNAH_LIVE_NODE_TESTS=1`, because a test suite that fails on
/// a laptop with no node running is a test suite people learn to ignore. It is
/// kept because the fixtures above can only prove the decoder matches a payload
/// somebody typed — these prove the payload is what the node really sends, which
/// is the half that rots silently when SAGE ships a new version.
final class LiveNodeAgentsTests: XCTestCase {

    private func requireLiveNode() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MYNAH_LIVE_NODE_TESTS"] == "1",
            "set MYNAH_LIVE_NODE_TESTS=1 to run against the SAGE on this machine"
        )
    }

    func testTheRealNodeAnswersTheRosterUnsigned() async throws {
        try requireLiveNode()

        let roster = try await NodeAgentDirectory().roster()

        XCTAssertFalse(roster.agents.isEmpty, "the public agents endpoint returned nothing")
        // Every row the screen draws needs these two, and a node that stops
        // sending them would leave a list of blank rows rather than an error.
        XCTAssertTrue(roster.agents.allSatisfy { !$0.name.isEmpty })
        XCTAssertTrue(roster.agents.allSatisfy { !$0.role.isEmpty })
    }

    /// **The assertion that would have caught two bugs.**
    ///
    /// The scan signs as whatever key its spawn environment names, and an
    /// unregistered key is answered — emptily — rather than refused. So the
    /// property worth testing is not "the scan worked" but "the agent it signed
    /// as is one the node has actually heard of". Both previous versions of that
    /// line would fail here, and both passed everything else.
    func testTheScanSignsAsAnAgentTheNodeKnows() async throws {
        try requireLiveNode()

        let keyPath = try XCTUnwrap(SageFederationScan.spawnEnvironment()[MynahIdentity.environmentVariable])
        let signingAs = try XCTUnwrap(SageAgentIdentity.agentID(ofKeyAt: URL(fileURLWithPath: keyPath)))
        let roster = try await NodeAgentDirectory().roster()

        XCTAssertEqual(signingAs, SageAgentIdentity.applianceAgentID())
        XCTAssertTrue(
            roster.agents.contains { $0.id == signingAs },
            "the scan signs as \(signingAs.prefix(8))…, which is not registered on this node"
        )
        XCTAssertTrue(roster.agents.contains { $0.isThisAppliance }, "the appliance's own row was not found")
    }

    /// The scan the owner's button runs. Read-only by the tool's own contract —
    /// "pairing, sharing, subscriptions, and other mutations remain
    /// operator-only" — so running it here changes nothing about their
    /// federation.
    func testTheRealNodeAnswersAFederationScan() async throws {
        try requireLiveNode()

        let report = try await SageFederationScan.shared.scan()

        // No assertion about *what* it found: a machine with no peers is the
        // ordinary case, and this is checking that the call, the banner-stripping
        // and the decode all survive contact with the real node.
        XCTAssertEqual(report.connections.count, report.connections.count)
    }
}

// MARK: - What the owner is told about permissions

/// The copy on this screen explains somebody else's security model to somebody
/// who did not ask to learn one. The failure mode is not a typo — it is an owner
/// who grants more than they meant to, or who never finds out why nothing is
/// being saved.
final class FederationHelpTests: XCTestCase {

    /// The remedy the owner reads is `SageVoiceCore`'s, not a second copy
    /// written here. The boot check and this page render the same string, so an
    /// owner who meets the restriction twice does not meet two explanations.
    func testTheRemedyIsTheSharedOneAndNamesTheCompanionProfile() {
        let readiness = ApplianceWriteReadiness(
            agentID: "abc",
            standing: .registered(mask: ApplianceWriteReadiness.Capability.pendingReview)
        )
        let remedy = try? XCTUnwrap(readiness.remedy)

        // Case-insensitive on purpose. The string lives in another module and
        // another teammate owns its typography; a test that pins capitalisation
        // across that boundary fails for a reason nobody cares about, which is
        // exactly what it did — `voice` writes it lowercase, this asserted a
        // capital C, and the suite went red over a letter.
        XCTAssertTrue(remedy?.lowercased().contains("companion profile") == true)
        XCTAssertTrue(remedy?.lowercased().contains("cerebrum") == true)
        // It has to name the subject to assign, or the owner assigns the wrong
        // one. `voice` interpolates the constant, so this cannot drift.
        XCTAssertTrue(remedy?.contains(SageRitual.memoryDomain) == true)
        // The wrong remedy, which SAGE's own MCP docs still suggest.
        XCTAssertFalse(remedy?.lowercased().contains("level 2") == true)
        XCTAssertFalse(remedy?.lowercased().contains("level-2") == true)
    }

    /// The screen adds context a boot line has no room for, and none of it
    /// re-states the remedy in different words.
    func testThePageOnlyAddsWhatABootLineCannotSay() {
        XCTAssertTrue(FederationHelp.cannotFixItself.contains("can't lift this itself"))
        XCTAssertTrue(FederationHelp.looksOrdinaryButIsMuted.contains("limit is on the key itself"))
        XCTAssertTrue(FederationHelp.companionPresetDetail.contains("mask 15"))
    }

    /// The claim that Mynah is the administrator of a sole install is gone, and
    /// what replaced it says why rank is beside the point.
    func testTheAdminClaimIsRetractedRatherThanSoftened() {
        XCTAssertFalse(FederationHelp.admin.contains("is the administrator"))
        XCTAssertTrue(FederationHelp.admin.contains("wouldn't help if it were"))
    }

    /// Granting and restricting are two different mechanisms, and the levels
    /// section must not read as the fix for a restricted key.
    func testTheLevelsSectionSaysGrantsDoNotLiftRestrictions() {
        XCTAssertTrue(FederationHelp.grantsDoNotLiftRestrictions.contains("no amount of granting"))
    }

    /// The one warning that must survive any rewording: sharing a node does not
    /// confer write access. An owner wrong about this loses data.
    func testTheWriteLevelSaysThatSharingANodeIsNotEnough() {
        let write = FederationHelp.levels.first { $0.name == "Write" }

        XCTAssertNotNil(write)
        XCTAssertTrue(write?.meaning.contains("not enough") == true)
    }

    /// Read must never sound harmless *and* able to add things; Modify has to
    /// say it includes the other two, because that is what the owner is
    /// agreeing to.
    func testEachLevelSaysWhatItActuallyGrants() {
        let levels = Dictionary(
            uniqueKeysWithValues: FederationHelp.levels.map { ($0.name, $0.meaning) }
        )

        XCTAssertEqual(FederationHelp.levels.map(\.name), ["Read", "Write", "Modify"])
        XCTAssertTrue(levels["Read"]?.contains("cannot add") == true)
        XCTAssertTrue(levels["Modify"]?.contains("Read and Write") == true)
    }

    /// The grid in CEREBRUM is a consensus transaction, not a preference.
    func testTheCandourLineSaysGrantsAreNotASetting() {
        XCTAssertTrue(FederationHelp.grantsAreReal.contains("not a setting"))
    }

    /// This screen cannot read the grant list — `/v1/access/grants/{id}` refuses
    /// an unsigned caller. Saying "no grants" on the strength of a refused call
    /// would be inventing the most consequential fact here.
    func testTheScreenSaysItCannotReadGrantsRatherThanThatThereAreNone() {
        let sentence = FederationHelp.grantsAreNotReadableHere.lowercased()

        XCTAssertTrue(sentence.contains("can't read"))
        XCTAssertFalse(sentence.contains("no grants"))
        XCTAssertTrue(sentence.contains("cerebrum"))
    }

    /// The steps name CEREBRUM and stop.
    func testTheStepsNameTheDestination() {
        XCTAssertTrue(FederationHelp.steps.joined(separator: " ").contains("CEREBRUM"))
    }

    /// **Restored after I deleted it, which I should not have done.**
    ///
    /// `chrome` wrote this as a tripwire against their own ignorance of
    /// CEREBRUM's interface, and I dropped it when I rewrote this file — on the
    /// unexamined assumption that my own copy was careful enough. It is not a
    /// design rule and it is not permanent: the day somebody has actually opened
    /// CEREBRUM and followed the path, this test is wrong and should be deleted
    /// with a note saying who verified it. Until then it stands, because I have
    /// not seen that interface either, and an invented click-path shipping
    /// beside verified RBAC facts would read exactly as confident as they do.
    ///
    /// It covers the shared remedy too, not only this screen's own words: that
    /// string is rendered here, so a route invented in `SageVoiceCore` would
    /// arrive on this page wearing this page's authority.
    func testNothingDescribesARouteThroughCerebrumsInterface() {
        let banned = [
            "click", "tap ", "the sidebar", "menu", "toolbar", "top right", "top-right",
            "checkbox", "check box", "press the", "scroll to", "the tab", "drop-down",
            "dropdown", "access controls", "settings page", "left-hand", "right-hand"
        ]
        let readiness = ApplianceWriteReadiness(
            agentID: "abc",
            standing: .registered(mask: ApplianceWriteReadiness.Capability.pendingReview)
        )
        let everythingTheOwnerReads = FederationHelp.steps + [
            FederationHelp.admin,
            FederationHelp.grantsAreReal,
            FederationHelp.grantsDoNotLiftRestrictions,
            FederationHelp.grantsAreNotReadableHere,
            FederationHelp.cannotFixItself,
            FederationHelp.looksOrdinaryButIsMuted,
            FederationHelp.companionPresetDetail,
            readiness.remedy ?? "",
            readiness.headline ?? ""
        ] + FederationHelp.levels.map(\.meaning) + readiness.reasons

        for sentence in everythingTheOwnerReads {
            for phrase in banned {
                XCTAssertFalse(
                    sentence.lowercased().contains(phrase),
                    "\"\(phrase)\" describes a route through an interface nobody here has seen: \(sentence)"
                )
            }
        }
    }
}
