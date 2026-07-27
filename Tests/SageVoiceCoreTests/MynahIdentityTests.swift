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
}
