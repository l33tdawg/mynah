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


    /// The path the appliance signs as, for a given environment.
    ///
    /// These tests used to call `MynahIdentity.resolvedKeyPath`, which is gone:
    /// it returned the window's vestigial `agent.key` and so signed as an agent
    /// the node has never heard of, silently, on four separate surfaces.
    ///
    /// The override-safety rules the tests below cover did NOT go with it. They
    /// moved onto `applianceEnvironment`, which is now the only way to build a
    /// child's identity — and which previously had a weaker check of its own,
    /// so these cases were guarding a path nobody took.
    private func identityPath(
        environment: [String: String],
        homeDirectory: URL,
        log: @escaping (String) -> Void = { _ in }
    ) -> String {
        MynahIdentity.applianceEnvironment(
            environment: environment,
            homeDirectory: homeDirectory,
            log: log
        )[MynahIdentity.environmentVariable] ?? ""
    }

    // MARK: The bug

    /// The exact fallback that shipped.
    func testTheDefaultIdentityIsNotTheNodeOperatorKey() {
        let resolved = identityPath(environment: [:], homeDirectory: home)
        XCTAssertNotEqual(resolved, operatorKey, "Mynah is still signing as the node operator")
        XCTAssertTrue(
            resolved.hasSuffix("SAGE Voice Bridge/appliance-agent.key"),
            "expected the appliance's own key, got \(resolved)"
        )
    }

    /// Every spawn site has to agree, or the app has two identities again and
    /// only one of them can ever be granted anything.
    ///
    /// There is now exactly one builder to agree on. `childEnvironment()` was
    /// the other one, and it was the trap: named for precisely what a caller
    /// wants when wiring a child process, and returning the wrong key.
    func testThereIsOneWayToBuildAChildIdentity() {
        let environment = MynahIdentity.applianceEnvironment(
            environment: [:],
            homeDirectory: home,
            log: { _ in }
        )
        XCTAssertEqual(environment.count, 1, "the child environment gained something unreviewed")
        XCTAssertEqual(
            environment[MynahIdentity.environmentVariable],
            identityPath(environment: [:], homeDirectory: home)
        )
    }

    /// An identity is only useful as a grant target if the node can tell it
    /// apart from every other agent, which means one stable path — not one
    /// derived from a working directory that differs per launch.
    func testTheIdentityDoesNotDependOnTheWorkingDirectory() {
        let first = identityPath(environment: [:], homeDirectory: home)
        let second = identityPath(environment: [:], homeDirectory: home)
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
            let resolved = identityPath(
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
                identityPath(
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
            identityPath(environment: environment, homeDirectory: home),
            "/opt/sage-data/agent.key",
            "a relocated operator key was honoured"
        )
    }

    /// An override may point Mynah at a *Mynah* key, and nothing else.
    ///
    /// This used to honour any path that was not the operator's, which a review
    /// showed was too generous: `~/.sage/agents/<project>/agent.key` is where the
    /// node mints per-project identities — this repo's own session hooks export
    /// one — so an arbitrary override let Mynah silently become an existing agent
    /// and write, forget and rename as it.
    func testAnOverrideMayOnlyNameAMynahKey() {
        let ours = MynahIdentity.keyURL(homeDirectory: home)
            .deletingLastPathComponent()
            .appendingPathComponent("test-agent.key").path
        XCTAssertEqual(
            identityPath(environment: ["SAGE_IDENTITY_PATH": ours], homeDirectory: home),
            ours,
            "a key in Mynah's own directory was refused"
        )
        XCTAssertEqual(
            identityPath(environment: ["SAGE_AGENT_KEY": ours], homeDirectory: home),
            ours,
            "the backward-compatible variable stopped working"
        )

        for foreign in [
            "/Users/tester/.sage/agents/sage-4e219acf/agent.key",
            "/tmp/somebody-elses.key"
        ] {
            XCTAssertNotEqual(
                identityPath(
                    environment: ["SAGE_IDENTITY_PATH": foreign],
                    homeDirectory: home
                ),
                foreign,
                "Mynah adopted another agent's identity from the environment"
            )
        }
    }

    /// macOS is case-insensitive by default and `standardizedFileURL` resolves
    /// `..` and nothing else — not case, not symlinks. A string compare against
    /// the operator path was therefore bypassable by changing its spelling.
    func testTheOperatorRefusalIsNotACaseSensitiveStringCompare() {
        for spelling in [
            "/Users/tester/.SAGE/agent.key",
            "/Users/tester/.Sage/Agent.key"
        ] {
            XCTAssertNotEqual(
                identityPath(
                    environment: ["SAGE_IDENTITY_PATH": spelling],
                    homeDirectory: home
                ),
                spelling,
                "\"\(spelling)\" reached the operator key by changing its case"
            )
        }
    }

    /// A refusal that says nothing means the app signs as a different agent than
    /// the environment asked for and nobody finds out until the memories look
    /// wrong.
    func testARefusedOverrideIsReported() {
        var lines: [String] = []
        _ = identityPath(
            environment: ["SAGE_IDENTITY_PATH": operatorKey],
            homeDirectory: home,
            log: { lines.append($0) }
        )
        XCTAssertTrue(
            lines.contains { $0.contains("SAGE_IDENTITY_PATH") },
            "the refusal was silent"
        )
    }

    /// `SAGE_IDENTITY_PATH` first, matching the node's own order
    /// (`cmd/sage-gui/mcp.go:145-148`). If these two disagree about precedence,
    /// the app signs as one identity while believing it signs as another.
    func testPrecedenceMatchesTheNode() {
        let directory = MynahIdentity.keyURL(homeDirectory: home).deletingLastPathComponent()
        let preferred = directory.appendingPathComponent("preferred.key").path
        let legacy = directory.appendingPathComponent("legacy.key").path
        XCTAssertEqual(
            identityPath(
                environment: [
                    "SAGE_IDENTITY_PATH": preferred,
                    "SAGE_AGENT_KEY": legacy
                ],
                homeDirectory: home
            ),
            preferred
        )
    }

    /// An empty variable is not an instruction.
    ///
    /// The fallback is the *appliance* key now, not `keyURL()`. That is the
    /// whole point of the change: `keyURL()` is the window's old identity,
    /// which nothing registers, so falling back to it meant falling back to an
    /// agent the node has never heard of.
    func testAnEmptyOverrideFallsThroughRatherThanBreaking() {
        XCTAssertEqual(
            identityPath(
                environment: ["SAGE_IDENTITY_PATH": ""],
                homeDirectory: home
            ),
            MynahIdentity.applianceKeyURL(homeDirectory: home).path
        )
    }

    // MARK: One appliance, one agent

    /// The window and the daemon must sign as the same agent.
    ///
    /// They did not. The app resolved agent.key and the daemon
    /// appliance-agent.key, and a different key is a different agent — so the
    /// node showed "MYNAH (Mac App)" beside "MYNAH (SAGE Voice Bridge Agent)",
    /// both with zero memories, because nothing said through one was visible to
    /// the other. The owner would also have had to grant every domain twice.
    ///
    /// Asserted through the environment each side actually spawns with, because
    /// that is what decides it. Names are cosmetic; the key is the identity.
    func testTheWindowAndTheDaemonSignAsTheSameAgent() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let daemon = MynahIdentity.applianceEnvironment(environment: [:], homeDirectory: home)
        XCTAssertEqual(
            daemon[MynahIdentity.environmentVariable],
            MynahIdentity.applianceKeyURL(homeDirectory: home).path,
            "the daemon no longer signs with the appliance key"
        )
    }

    /// And there is no second name to register one with.
    ///
    /// The constants that made a separate Mac-app agent possible are gone. This
    /// fails to compile if they come back, which is the point — the split was
    /// reintroduced easily precisely because both names looked reasonable.
    func testThereIsOnlyOneAgentName() {
        XCTAssertEqual(SageRitual.applianceAgentName, "SAGE Voice Bridge")
        XCTAssertEqual(SageRitual.agentName, SageRitual.applianceAgentName)
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
        XCTAssertEqual(SageRitual.applianceDisplayName, "Mynah - Sage Voice Bridge")
        // The registered name is immutable on the node and is NOT renamed with
        // the display name — doing so would not move the existing agent, it
        // would leave the next fresh install answering to a name none of the
        // deployed ones do.
        XCTAssertEqual(SageRitual.applianceAgentName, "SAGE Voice Bridge")
        XCTAssertTrue(SageRitual.applianceDisplayName.localizedCaseInsensitiveContains("mynah"))
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

    /// The same class of bug, one feature over: the reply style was read in
    /// `runBrain` and not in `runDaemon`, so the owner's "Answer with voice
    /// notes" switch did nothing on the appliance and the token ceiling stayed at
    /// the spoken value. Both entry points now go through one resolver.
    func testEveryEntryPointResolvesTheReplyStyle() throws {
        let main = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/sage-voiced/main.swift")
        let source = try String(contentsOf: main, encoding: .utf8)

        // Whitespace removed before counting, because the guard was checking
        // formatting as much as intent: a construction wrapped across lines did
        // not match `= ToolLoop(backend:` and silently stopped being counted.
        // A guard that a line break can switch off is worse than none, because
        // it still reports success.
        let dense = source.filter { !$0.isWhitespace }

        // `=ToolLoop(backend:` rather than a bare mention, so a doc comment that
        // names the type is not counted as a construction site.
        let loops = dense.components(separatedBy: "=ToolLoop(backend:").count - 1
        let configured = dense.components(separatedBy: "loopConfiguration(for:").count - 1
        XCTAssertGreaterThan(loops, 0, "could not find any ToolLoop construction to check")
        XCTAssertEqual(
            configured,
            loops,
            "\(loops) ToolLoop(s) but only \(configured) configured — an unconfigured one ignores the owner's reply-style setting"
        )
    }

    func testLocalBrainTurnsOnSAGESemanticMemory() {
        let environment = MynahIdentity.localSemanticEnvironment(
            identityEnvironment: ["SAGE_IDENTITY_PATH": "/private/mynah.key"]
        )

        XCTAssertEqual(environment["SAGE_IDENTITY_PATH"], "/private/mynah.key")
        XCTAssertEqual(environment["SAGE_EMBEDDING_PROVIDER"], "ollama")
        XCTAssertEqual(environment["SAGE_EMBEDDING_MODEL"], "nomic-embed-text")
        XCTAssertEqual(environment["SAGE_EMBEDDING_DIMENSION"], "768")
        XCTAssertEqual(environment["SAGE_EMBEDDING_BASE_URL"], "http://127.0.0.1:11434")
    }
}
