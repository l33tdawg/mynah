import XCTest
@testable import SageVoiceCore

/// Which key Mynah signs SAGE requests with.
///
/// A federation review found the app spawning `sage-gui mcp` from two places
/// with two different identities, one of which was the node operator:
///
///   * `MemoriesView` pinned `SAGE_IDENTITY_PATH` to `$SAGE_HOME/agent.key`,
///     which is `nodeOperatorID` — so every browse signed with the highest
///     privilege on the machine.
///   * `ConversationModel` passed no environment, so the node minted a key from
///     the process's working directory, which for a GUI app is `/`.
///
/// The owner's requirement was that a co-located Mynah get a *higher* grant than
/// it has. It had the highest one already, by accident. You cannot grant a
/// permission to an identity that does not exist, and you cannot meaningfully
/// restrict one that is already the operator — so this is the prerequisite for
/// everything else.
final class MynahIdentityTests: XCTestCase {

    private let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

    private var operatorKey: String {
        "/Users/tester/.sage/agent.key"
    }

    // MARK: The bug

    /// The exact fallback that shipped.
    func testTheDefaultIdentityIsNotTheNodeOperatorKey() {
        let resolved = MynahIdentity.resolvedKeyPath(environment: [:], homeDirectory: home)
        XCTAssertNotEqual(resolved, operatorKey, "Mynah is still signing as the node operator")
        XCTAssertTrue(
            resolved.hasSuffix("SAGE Voice Bridge/agent.key"),
            "expected Mynah's own key, got \(resolved)"
        )
    }

    /// Both spawn sites have to agree, or the app has two identities again and
    /// only one of them can ever be granted anything.
    func testEverySpawnSiteGetsTheSameIdentity() {
        let environment = MynahIdentity.childEnvironment(environment: [:], homeDirectory: home)
        XCTAssertEqual(
            environment[MynahIdentity.environmentVariable],
            MynahIdentity.resolvedKeyPath(environment: [:], homeDirectory: home)
        )
        XCTAssertEqual(environment.count, 1, "the child environment gained something unreviewed")
    }

    /// An identity is only useful as a grant target if the node can tell it
    /// apart from every other agent, which means one stable path — not one
    /// derived from a working directory that differs per launch.
    func testTheIdentityDoesNotDependOnTheWorkingDirectory() {
        let first = MynahIdentity.resolvedKeyPath(environment: [:], homeDirectory: home)
        let second = MynahIdentity.resolvedKeyPath(environment: [:], homeDirectory: home)
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.hasPrefix(home.path), "the key escaped the owner's home directory")
    }

    // MARK: Refusing to be the operator

    /// The override exists so someone can drive the app as a specific agent for
    /// testing. Naming the operator is the one thing it may not do — deleting
    /// the old code is not enough if the next person can write it again in an
    /// environment variable.
    func testAnOverrideNamingTheOperatorKeyIsRefused() {
        for variable in ["SAGE_IDENTITY_PATH", "SAGE_AGENT_KEY"] {
            let resolved = MynahIdentity.resolvedKeyPath(
                environment: [variable: operatorKey],
                homeDirectory: home
            )
            XCTAssertNotEqual(resolved, operatorKey, "\(variable) was honoured into the operator key")
        }
    }

    /// The comparison has to survive the ways the same file gets written.
    func testTheRefusalSurvivesTildeAndPathNoise() {
        for spelling in [
            "~/.sage/agent.key",
            "/Users/tester/.sage/../.sage/agent.key",
            "/Users/tester/.sage//agent.key"
        ] {
            XCTAssertNotEqual(
                MynahIdentity.resolvedKeyPath(
                    environment: ["SAGE_IDENTITY_PATH": spelling],
                    homeDirectory: home
                ),
                operatorKey,
                "\"\(spelling)\" resolved to the operator key"
            )
        }
    }

    /// A non-standard install moves the operator key, and the refusal has to
    /// move with it. Resolved the same way the node resolves it.
    func testSageHomeMovesTheOperatorKeyAndTheRefusalFollows() {
        let environment = [
            "SAGE_HOME": "/opt/sage-data",
            "SAGE_IDENTITY_PATH": "/opt/sage-data/agent.key"
        ]
        XCTAssertEqual(
            MynahIdentity.nodeOperatorKeyURL(environment: environment, homeDirectory: home).path,
            "/opt/sage-data/agent.key"
        )
        XCTAssertNotEqual(
            MynahIdentity.resolvedKeyPath(environment: environment, homeDirectory: home),
            "/opt/sage-data/agent.key",
            "a relocated operator key was honoured"
        )
    }

    /// A legitimate override still works. Refusing one specific path must not
    /// become refusing all of them.
    func testAnOrdinaryOverrideIsStillHonoured() {
        XCTAssertEqual(
            MynahIdentity.resolvedKeyPath(
                environment: ["SAGE_IDENTITY_PATH": "/tmp/test-agent.key"],
                homeDirectory: home
            ),
            "/tmp/test-agent.key"
        )
        XCTAssertEqual(
            MynahIdentity.resolvedKeyPath(
                environment: ["SAGE_AGENT_KEY": "/tmp/legacy-agent.key"],
                homeDirectory: home
            ),
            "/tmp/legacy-agent.key",
            "the backward-compatible variable stopped working"
        )
    }

    /// `SAGE_IDENTITY_PATH` first, matching the node's own order
    /// (`cmd/sage-gui/mcp.go:145-148`). If these two disagree about precedence,
    /// the app signs as one identity while believing it signs as another.
    func testPrecedenceMatchesTheNode() {
        XCTAssertEqual(
            MynahIdentity.resolvedKeyPath(
                environment: [
                    "SAGE_IDENTITY_PATH": "/tmp/preferred.key",
                    "SAGE_AGENT_KEY": "/tmp/legacy.key"
                ],
                homeDirectory: home
            ),
            "/tmp/preferred.key"
        )
    }

    /// An empty variable is not an instruction.
    func testAnEmptyOverrideFallsThroughRatherThanBreaking() {
        XCTAssertEqual(
            MynahIdentity.resolvedKeyPath(
                environment: ["SAGE_IDENTITY_PATH": ""],
                homeDirectory: home
            ),
            MynahIdentity.keyURL(homeDirectory: home).path
        )
    }

    // MARK: Telling the two agents apart

    /// The operator's half of the owner's model — "operator goes into CEREBRUM
    /// and sets access levels per domain" — only works if CEREBRUM's agent list
    /// shows two distinguishable rows. The Mac app and the phone appliance are
    /// two agents with two keys; two rows both reading "SAGE Voice Bridge" makes
    /// "give this one read access" a coin flip.
    func testTheAppAndTheApplianceRegisterUnderDifferentNames() {
        XCTAssertNotEqual(SageRitual.appAgentName, SageRitual.applianceAgentName)
        XCTAssertEqual(SageRitual.applianceAgentName, "SAGE Voice Bridge")
        XCTAssertEqual(SageRitual.appAgentName, "Mynah")
    }

    /// The appliance must not be renamed by this change. It is already
    /// registered on the owner's node under this name, and a rename would make
    /// a second agent rather than move the first.
    func testTheDefaultStaysTheApplianceSoExistingRegistrationsSurvive() {
        XCTAssertEqual(SageRitual.agentName, SageRitual.applianceAgentName)
    }

    /// The registered name is what a person says out loud; the display name is
    /// what an operator reads in a list. `sage_find_agent` matches both
    /// (`internal/mcp/tools.go` matchesAgentName), so these are two views of one
    /// agent rather than a trade-off between addressable and descriptive.
    func testTheSpokenNameAndTheListedNameAreBothCovered() {
        XCTAssertEqual(SageRitual.applianceDisplayName, "MYNAH (SAGE Voice Bridge Agent)")
        XCTAssertEqual(SageRitual.appDisplayName, "MYNAH (Mac App)")
        XCTAssertTrue(SageRitual.applianceDisplayName.contains("MYNAH"))
        XCTAssertTrue(SageRitual.appDisplayName.contains("MYNAH"))
        XCTAssertNotEqual(SageRitual.applianceDisplayName, SageRitual.appDisplayName)
    }

    /// The registered name becomes `RegisteredName`, which the node makes
    /// immutable forever (internal/abci/app.go:6935). Changing this constant
    /// would not rename any existing agent — it would only make the next fresh
    /// install answer to a different name than every appliance already deployed.
    func testTheImmutableRegisteredNameIsNotQuietlyChanged() {
        XCTAssertEqual(
            SageRitual.applianceAgentName,
            "SAGE Voice Bridge",
            "every appliance already on a node registered under this; it cannot be renamed by editing it here"
        )
        XCTAssertEqual(SageRitual.appAgentName, "Mynah", "the name a person says when addressing the Mac app")
    }

    /// Both entry points must pin, and this is asserted because the first
    /// attempt patched only one of them.
    ///
    /// `runBrain` got the pin, `runDaemon` did not, and the mistake verified as
    /// a success: the check was `sage-voiced brain`, a different process, and
    /// the one that had it. The production daemon meanwhile started from /tmp
    /// and minted `tmp-agent-*`, answering the owner from an identity holding
    /// none of their memories.
    ///
    /// A source assertion rather than a behavioural one, deliberately — the two
    /// spawn sites live in an executable target the test bundle cannot import,
    /// and "someone added a third spawn site" is exactly the regression worth
    /// catching.
    func testEveryEntryPointPinsTheApplianceIdentity() throws {
        let main = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SageVoiceCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("Sources/sage-voiced/main.swift")
        let source = try String(contentsOf: main, encoding: .utf8)

        let spawns = source.components(separatedBy: "MCPClient(").count - 1
        let pinned = source.components(separatedBy: "MynahIdentity.applianceEnvironment()").count - 1
        XCTAssertGreaterThan(spawns, 0, "could not find any MCP spawn site to check")
        XCTAssertEqual(
            pinned,
            spawns,
            "\(spawns) MCP spawn site(s) but only \(pinned) pinned — an unpinned one derives its identity from the launch directory"
        )
    }
}
