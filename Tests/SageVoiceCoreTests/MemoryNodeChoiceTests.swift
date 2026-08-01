import XCTest
@testable import MynahMac
@testable import SageVoiceCore

/// Which SAGE binary the memories screen drives, and what it says when it can
/// see nothing.
///
/// Both halves are silent failures. A screen that spawns the wrong binary works
/// perfectly — same default store, same data — right up until the vendored copy
/// and the installed one are different versions operating one database. And a
/// screen that says "nothing kept yet" when writes are failing sends the owner
/// away reassured.
final class MemoryNodeChoiceTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mynah.node.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// The same fixture shape `SageNodeChoiceTests` uses: a real `.app`
    /// directory with an executable and an identifier, because the resolver
    /// checks both and a bare file would not exercise it.
    private func makeBundle(named name: String) -> URL {
        let bundle = root.appendingPathComponent(name)
        let macos = bundle.appendingPathComponent("Contents/MacOS")
        try? FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: macos.appendingPathComponent(SageNodeLocator.executableName).path,
            contents: Data("#!/bin/sh\n".utf8),
            attributes: [.posixPermissions: 0o755]
        )
        let data = try? PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": SageNodeLocator.expectedBundleIdentifier],
            format: .xml,
            options: 0
        )
        try? data?.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        return bundle
    }

    private func executable(inside bundle: URL) -> URL {
        bundle.appendingPathComponent("Contents/MacOS")
            .appendingPathComponent(SageNodeLocator.executableName)
    }

    // MARK: The rule the owner asked for

    /// "If a SAGE node is already installed, Mynah uses it and changes nothing
    /// about it. The vendored copy is a fallback, and a fallback only."
    ///
    /// The memories screen used `EnvironmentProbe.defaultSageBundleExecutables`,
    /// whose documented ordering is the exact opposite — vendored first, "the
    /// normal case, not the fallback". That is correct for the setup probe,
    /// whose job is finding a runnable node on a bare machine, and wrong as the
    /// answer to "which binary should operate the store that already holds the
    /// owner's memories".
    func testAnInstalledNodeIsPreferredToTheOneWeShipped() {
        let installed = makeBundle(named: "Installed.app")
        let vendored = makeBundle(named: "Vendored.app")

        let choice = SageNodeChoice.resolve(
            vendored: executable(inside: vendored),
            installedCandidates: [installed]
        )

        XCTAssertEqual(choice?.source, .installed, "the vendored copy won over an installed node")
        XCTAssertEqual(choice?.executable, executable(inside: installed))
    }

    /// The fallback is still a fallback — a machine with no SAGE at all is the
    /// case the vendored copy exists for, and it must still work.
    func testTheVendoredCopyIsUsedWhenTheMachineHasNoneOfItsOwn() {
        let vendored = makeBundle(named: "Vendored.app")

        let choice = SageNodeChoice.resolve(
            vendored: executable(inside: vendored),
            installedCandidates: []
        )

        XCTAssertEqual(choice?.source, .vendored)
        XCTAssertEqual(choice?.executable, executable(inside: vendored))
    }

    /// Nothing anywhere is a real state and resolves to nothing, rather than to
    /// a path that does not exist.
    func testNoNodeAnywhereResolvesToNothing() {
        XCTAssertNil(SageNodeChoice.resolve(vendored: nil, installedCandidates: []))
    }

    // MARK: Telling three silences apart

    /// A shut vault and a genuine refusal send the owner to two different
    /// places: one to their passphrase, one to quitting and reopening.
    func testALockedVaultIsReadFromTheNodesOwnWords() {
        for said in ["login_required", "vault is locked", "please unlock the node first",
                     "the vault is sealed"] {
            XCTAssertEqual(
                MemoryTrouble.reading(refusal: said),
                .locked,
                "\"\(said)\" was not recognised as a locked node"
            )
        }
    }

    /// Anything unrecognised keeps the older, vaguer sentence. Wrong in the safe
    /// direction: an owner told to quit and reopen tries one wrong fix, whereas
    /// an owner told to unlock a node that is not locked goes looking for a
    /// passphrase that does not exist.
    func testAnUnrecognisedRefusalDoesNotClaimTheNodeIsLocked() {
        for said in ["tool not found", "internal error", "", "domain access denied"] {
            XCTAssertEqual(MemoryTrouble.reading(refusal: said), .refused)
        }
        XCTAssertEqual(MemoryTrouble.reading(refusal: nil), .refused)
    }

    /// Every sentence on this screen, held to the same line as the board's: a
    /// failure may never read as "you have no memories".
    func testNoFailureSentenceClaimsTheMemoriesAreGone() {
        let all: [MemoryTrouble] = [
            .notSetUp, .unreachable, .refused, .locked, .unreadable, .tooBroad, .unknownTopic
        ]
        for trouble in all {
            XCTAssertFalse(trouble.headline.isEmpty)
            XCTAssertFalse(trouble.explanation.isEmpty)
            let said = (trouble.headline + " " + trouble.explanation).lowercased()
            for lie in ["no memories", "nothing to remember", "it has forgotten", "empty"] {
                XCTAssertFalse(said.contains(lie), "\"\(trouble.headline)\" says \"\(lie)\"")
            }
        }
    }

    // MARK: The two refusals that "quit and reopen" cannot fix

    /// **The one the owner actually hit**, in the node's own words.
    ///
    /// Measured on 31 July by driving `sage_list` over MCP signed as the
    /// appliance's own key: the plain unfiltered first page comes back
    /// `Query too broad: app-v23 authorization scan budget exceeded`. Every
    /// earlier check of this call had been made over a developer's MCP
    /// connection, which signs as an agent with more standing and returns
    /// memories happily — so the screen was verified as working by a caller it
    /// is never used by.
    ///
    /// It classified as `.refused`, and `.refused` says to quit and reopen. A
    /// relaunch asks the identical question and gets the identical refusal, so
    /// the advice could not work on any attempt.
    func testAScanBudgetRefusalIsNotSomethingRelaunchingCanFix() {
        for said in [
            "Query too broad: app-v23 authorization scan budget exceeded",
            "list memories: query too broad",
            "authorization scan budget exceeded"
        ] {
            XCTAssertEqual(
                MemoryTrouble.reading(refusal: said),
                .tooBroad,
                "\"\(said)\" was not recognised as a question that needs narrowing"
            )
        }
        let advice = MemoryTrouble.tooBroad.explanation.lowercased()
        XCTAssertFalse(advice.contains("quit"), "still telling the owner to quit and reopen")
        XCTAssertFalse(advice.contains("try again"), "the same request fails the same way")
    }

    /// A filter naming a domain the node will not resolve. Both real messages
    /// from `mynah.log`, including the one that named another agent's domain.
    func testADeadTopicFilterIsToldApartFromAFlatRefusal() {
        for said in [
            "Authorization unavailable: app-v23 record disclosure state is unavailable: "
                + "domain not found: sage-v11-development",
            "record disclosure state is unavailable: domain name contains whitespace"
        ] {
            XCTAssertEqual(
                MemoryTrouble.reading(refusal: said),
                .unknownTopic,
                "\"\(said)\" was not recognised as a filter problem"
            )
        }
    }

    /// The locked sentence has to contradict the empty state, not echo it.
    func testTheLockedSentenceSaysTheMemoriesAreStillThere() {
        let said = MemoryTrouble.locked.explanation.lowercased()
        XCTAssertTrue(said.contains("still there"))
        XCTAssertTrue(said.contains("unlock"))
    }

    // MARK: Who the screen signs as

    /// The appliance's key, and not the vestigial one beside it.
    ///
    /// This screen spent its life querying as `17641c48…` — the id `agent.key`
    /// derives to, which is not registered on the node at all — because it
    /// resolved through `MynahIdentity.resolvedKeyPath()`. The appliance is
    /// `74140c2d…`, from `appliance-agent.key`.
    ///
    /// Asserted on the *environment the store actually spawns with* rather than
    /// on a constant, because the bug was never in a constant: two functions in
    /// `MynahIdentity` return the vestigial key, both have names that sound like
    /// the right one, and between them they have now caught four surfaces
    /// including one where the fix was a move from one to the other.
    func testTheStoreSpawnsWithTheApplianceKeyAndNotTheVestigialOne() throws {
        let spawned = SageMemoryStore.identityEnvironment
        let keyPath = try XCTUnwrap(
            spawned[MynahIdentity.environmentVariable],
            "the memories store spawns without pinning an identity at all"
        )

        // Compared on the whole path, not the filename. The appliance's key is
        // now `~/.sage/agents/mynah/agent.key` and the vestigial one is
        // `Application Support/SAGE Voice Bridge/agent.key` — both called
        // `agent.key`, so a suffix check on the name cannot tell the identity
        // from the dead key any more. It used to, and that made it exactly the
        // kind of assertion that keeps passing after it stops meaning anything.
        XCTAssertEqual(
            keyPath,
            MynahIdentity.applianceKeyURL().path,
            "the memories screen does not sign as the appliance"
        )
        XCTAssertNotEqual(
            keyPath,
            MynahIdentity.keyURL().path,
            "the memories screen is back on the vestigial key"
        )
    }

    /// **The assertion that would have caught the original bug.**
    ///
    /// Every cheaper check passes with a ghost key: the child spawns, the call
    /// returns, and the list comes back empty — which is indistinguishable from
    /// a new install that genuinely has nothing. An unregistered agent is
    /// *answered*, not refused. So the property worth testing is not "the browse
    /// worked" but "the agent it signed as is one the node has heard of".
    ///
    /// Live-node only, for the same reason `thread`'s equivalent is: the roster
    /// is the only thing that can answer it.
    func testTheStoreSignsAsAnAgentTheNodeKnows() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MYNAH_LIVE_NODE_TESTS"] == "1",
            "set MYNAH_LIVE_NODE_TESTS=1 to run against the SAGE on this machine"
        )

        let keyPath = try XCTUnwrap(SageMemoryStore.identityEnvironment[MynahIdentity.environmentVariable])
        let signingAs = try XCTUnwrap(SageAgentIdentity.agentID(ofKeyAt: URL(fileURLWithPath: keyPath)))
        let roster = try await NodeAgentDirectory().roster()

        XCTAssertEqual(signingAs, SageAgentIdentity.applianceAgentID())
        XCTAssertTrue(
            roster.agents.contains { $0.id == signingAs },
            "Memories signs as \(signingAs.prefix(8))…, which is not registered on this node — "
                + "every browse will come back empty and look like a fresh install"
        )
    }
}
