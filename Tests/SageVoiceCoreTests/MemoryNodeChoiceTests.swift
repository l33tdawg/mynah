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
        let all: [MemoryTrouble] = [.notSetUp, .unreachable, .refused, .locked, .unreadable]
        for trouble in all {
            XCTAssertFalse(trouble.headline.isEmpty)
            XCTAssertFalse(trouble.explanation.isEmpty)
            let said = (trouble.headline + " " + trouble.explanation).lowercased()
            for lie in ["no memories", "nothing to remember", "it has forgotten", "empty"] {
                XCTAssertFalse(said.contains(lie), "\"\(trouble.headline)\" says \"\(lie)\"")
            }
        }
    }

    /// The locked sentence has to contradict the empty state, not echo it.
    func testTheLockedSentenceSaysTheMemoriesAreStillThere() {
        let said = MemoryTrouble.locked.explanation.lowercased()
        XCTAssertTrue(said.contains("still there"))
        XCTAssertTrue(said.contains("unlock"))
    }
}
