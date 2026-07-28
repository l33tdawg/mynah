import XCTest
@testable import SageVoiceCore

/// Upgrading must not cost the appliance its memories.
///
/// Pinning the identity was the fix for "the launch directory decides which
/// memories you have". On its own it is also a data-loss bug: pointing an
/// existing appliance at a fresh path means the node mints a new key, which is a
/// new agent id, which is an appliance that has forgotten everything — silently,
/// on upgrade, for every install except the one machine where the copy was done
/// by hand.
final class ApplianceKeyMigrationTests: XCTestCase {

    private var root: URL!
    private var home: URL!
    private var sageHome: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("appliance-migration-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        sageHome = home.appendingPathComponent(".sage", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func plantDerivedKey(
        workingDirectory: String,
        provider: String?,
        bytes: Data
    ) throws -> URL {
        let candidate = MynahIdentity.derivedKeyCandidates(
            sageHome: sageHome,
            workingDirectory: workingDirectory,
            provider: provider
        )[0]
        try FileManager.default.createDirectory(
            at: candidate.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try bytes.write(to: candidate)
        return candidate
    }

    // MARK: The derivation

    /// Ported from cmd/sage-gui/mcp.go and checked against the directory names
    /// this appliance actually accumulated. If SAGE changes its derivation, this
    /// fails and the migration is known to be blind rather than quietly wrong.
    func testTheDerivationMatchesTheNamesTheNodeReallyProduced() {
        let sage = URL(fileURLWithPath: "/Users/ableton/.sage", isDirectory: true)

        let fromHome = MynahIdentity.derivedKeyCandidates(
            sageHome: sage, workingDirectory: "/Users/ableton", provider: nil
        )[0]
        XCTAssertEqual(fromHome.deletingLastPathComponent().lastPathComponent, "ableton-agent-849d657e")

        let fromTmp = MynahIdentity.derivedKeyCandidates(
            sageHome: sage, workingDirectory: "/tmp", provider: nil
        )[0]
        XCTAssertEqual(fromTmp.deletingLastPathComponent().lastPathComponent, "tmp-agent-57aab6cb")
    }

    func testTheProviderChangesTheDerivation() {
        let sage = URL(fileURLWithPath: "/Users/ableton/.sage", isDirectory: true)
        let anonymous = MynahIdentity.derivedKeyCandidates(
            sageHome: sage, workingDirectory: "/Users/ableton", provider: nil
        )[0]
        let claude = MynahIdentity.derivedKeyCandidates(
            sageHome: sage, workingDirectory: "/Users/ableton", provider: "claude-code"
        )[0]
        XCTAssertNotEqual(anonymous, claude, "SAGE_PROVIDER was ignored, so the wrong key would be adopted")
    }

    // MARK: The migration

    func testTheExistingIdentityIsAdoptedByteForByte() throws {
        let key = Data("the-appliances-actual-ed25519-seed".utf8)
        _ = try plantDerivedKey(workingDirectory: "/Users/ableton", provider: nil, bytes: key)

        let migrated = MynahIdentity.migrateApplianceKeyIfNeeded(
            environment: ["SAGE_HOME": sageHome.path],
            homeDirectory: home,
            workingDirectory: "/Users/ableton"
        )

        XCTAssertNotNil(migrated, "the appliance's own key was not found")
        let pinned = MynahIdentity.applianceKeyURL(homeDirectory: home)
        XCTAssertEqual(
            try Data(contentsOf: pinned),
            key,
            "the bytes differ, so this is a new agent id and the memories are gone"
        )
    }

    /// Same bytes is the whole point: same key means same agent id, so nothing
    /// re-registers and there is nothing to reconcile on the node.
    func testTheMigratedKeyIsOwnerOnly() throws {
        _ = try plantDerivedKey(workingDirectory: "/Users/ableton", provider: nil, bytes: Data("k".utf8))
        MynahIdentity.migrateApplianceKeyIfNeeded(
            environment: ["SAGE_HOME": sageHome.path],
            homeDirectory: home,
            workingDirectory: "/Users/ableton"
        )
        let pinned = MynahIdentity.applianceKeyURL(homeDirectory: home)
        let mode = try FileManager.default.attributesOfItem(atPath: pinned.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode, 0o600)
    }

    /// Runs once. On every boot after the first there is nothing to do, and an
    /// unconditional copy would overwrite the live key from a stale directory.
    func testItDoesNothingOnceThePinnedKeyExists() throws {
        let original = Data("original".utf8)
        try OwnerOnlyFileSecurity.write(original, to: MynahIdentity.applianceKeyURL(homeDirectory: home))
        _ = try plantDerivedKey(workingDirectory: "/Users/ableton", provider: nil, bytes: Data("stale".utf8))

        let migrated = MynahIdentity.migrateApplianceKeyIfNeeded(
            environment: ["SAGE_HOME": sageHome.path],
            homeDirectory: home,
            workingDirectory: "/Users/ableton"
        )

        XCTAssertNil(migrated)
        XCTAssertEqual(
            try Data(contentsOf: MynahIdentity.applianceKeyURL(homeDirectory: home)),
            original,
            "a stale derived key overwrote the live identity"
        )
    }

    /// A genuinely new install has nothing to adopt, and must not adopt
    /// somebody else's key just because one exists.
    func testAFreshInstallMigratesNothing() throws {
        _ = try plantDerivedKey(
            workingDirectory: "/Users/someone/code/other-project",
            provider: "claude-code",
            bytes: Data("another agent entirely".utf8)
        )

        let migrated = MynahIdentity.migrateApplianceKeyIfNeeded(
            environment: ["SAGE_HOME": sageHome.path],
            homeDirectory: home,
            workingDirectory: "/Users/ableton"
        )

        XCTAssertNil(migrated, "adopted an unrelated project's agent identity")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: MynahIdentity.applianceKeyURL(homeDirectory: home).path)
        )
    }

    /// The launch directory is what the derivation keys on, so an upgrade that
    /// also changes it finds nothing — a fresh identity rather than a wrong one.
    func testADifferentLaunchDirectoryFindsNothingRatherThanTheWrongThing() throws {
        _ = try plantDerivedKey(workingDirectory: "/Users/ableton", provider: nil, bytes: Data("k".utf8))

        XCTAssertNil(
            MynahIdentity.migrateApplianceKeyIfNeeded(
                environment: ["SAGE_HOME": sageHome.path],
                homeDirectory: home,
                workingDirectory: "/var/root"
            )
        )
    }

    /// The migration is wired into the thing the daemon actually calls, or it
    /// never runs.
    func testTheDaemonEnvironmentTriggersIt() throws {
        let key = Data("appliance".utf8)
        _ = try plantDerivedKey(workingDirectory: FileManager.default.currentDirectoryPath, provider: nil, bytes: key)

        let environment = MynahIdentity.applianceEnvironment(
            environment: ["SAGE_HOME": sageHome.path],
            homeDirectory: home
        )

        XCTAssertEqual(
            environment[MynahIdentity.environmentVariable],
            MynahIdentity.applianceKeyURL(homeDirectory: home).path
        )
        XCTAssertEqual(
            try Data(contentsOf: MynahIdentity.applianceKeyURL(homeDirectory: home)),
            key,
            "applianceEnvironment did not run the migration"
        )
    }

    // MARK: The legacy-directory trap

    /// The severe one, found in review, reproduced from the author's own
    /// machine.
    ///
    /// The node reaches its pre-provider directory ONLY for claude-code and
    /// claude-desktop (mcp.go:246-253). The first port offered it to everyone,
    /// and the appliance runs with no provider — so a daemon launched by launchd
    /// or Finder (cwd `/`) found no provider directory, fell to the legacy one,
    /// and adopted `~/.sage/agents/--8a5edab2/agent.key`: a live Claude Code
    /// agent holding thousands of memories.
    ///
    /// Mynah would have become that agent — writing voice turns into its corpus,
    /// inheriting its grants, with `sage_forget` still in its tool allowlist.
    func testAProviderlessApplianceNeverAdoptsALegacyClaudeCodeKey() throws {
        // Exactly the reachable shape: legacy directory present, provider
        // directory absent.
        let legacyName = "--8a5edab2"
        let legacy = sageHome
            .appendingPathComponent("agents", isDirectory: true)
            .appendingPathComponent(legacyName, isDirectory: true)
            .appendingPathComponent("agent.key", isDirectory: false)
        try FileManager.default.createDirectory(
            at: legacy.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("somebody-elses-claude-code-agent".utf8).write(to: legacy)

        let migrated = MynahIdentity.migrateApplianceKeyIfNeeded(
            environment: ["SAGE_HOME": sageHome.path],
            homeDirectory: home,
            workingDirectory: "/"
        )

        XCTAssertNil(migrated, "the appliance adopted a Claude Code agent's identity")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: MynahIdentity.applianceKeyURL(homeDirectory: home).path),
            "another agent's key was copied into the appliance's identity"
        )
    }

    /// The candidate list itself, so the gate cannot be loosened without this
    /// failing rather than a migration quietly widening.
    func testTheLegacyCandidateIsOfferedOnlyToTheProvidersTheNodeOffersItTo() {
        let sage = URL(fileURLWithPath: "/Users/tester/.sage", isDirectory: true)
        func candidates(_ provider: String?) -> [URL] {
            MynahIdentity.derivedKeyCandidates(
                sageHome: sage, workingDirectory: "/Users/tester/project", provider: provider
            )
        }

        XCTAssertEqual(candidates(nil).count, 1, "a providerless caller was offered the legacy directory")
        XCTAssertEqual(candidates("").count, 1)
        XCTAssertEqual(candidates("codex").count, 1, "a non-Claude provider was offered the legacy directory")

        // mcp.go:246-253 — these two, and only these two.
        XCTAssertEqual(candidates("claude-code").count, 2)
        XCTAssertEqual(candidates("Claude-Desktop").count, 2, "the node compares case-insensitively")
    }
}
