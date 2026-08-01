import XCTest
@testable import SageVoiceCore

/// The appliance must not interfere with a SAGE the owner already runs.
///
/// This is the guarantee the owner asked for in as many words — "the app must
/// NEVER fuck around with the SAGE once it's installed" — and it is the one
/// promise where being wrong is unrecoverable: their node holds their memories,
/// their agents and their keys.
final class SageNodeChoiceTests: XCTestCase {

    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sage-choice-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    /// Builds something shaped like an app bundle.
    private func makeBundle(named name: String, identifier: String?) -> URL {
        let bundle = root.appendingPathComponent(name)
        let macos = bundle.appendingPathComponent("Contents/MacOS")
        try? FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)

        let executable = macos.appendingPathComponent(SageNodeLocator.executableName)
        FileManager.default.createFile(
            atPath: executable.path,
            contents: Data("#!/bin/sh\n".utf8),
            attributes: [.posixPermissions: 0o755]
        )
        if let identifier {
            let plist = bundle.appendingPathComponent("Contents/Info.plist")
            let data = try? PropertyListSerialization.data(
                fromPropertyList: ["CFBundleIdentifier": identifier],
                format: .xml,
                options: 0
            )
            try? data?.write(to: plist)
        }
        return bundle
    }

    private func vendored() -> URL {
        makeBundle(named: "Vendored.app", identifier: SageNodeLocator.expectedBundleIdentifier)
            .appendingPathComponent("Contents/MacOS")
            .appendingPathComponent(SageNodeLocator.executableName)
    }

    // MARK: The promise

    /// A SAGE the owner installed is the one that gets used.
    ///
    /// Using the vendored copy instead starts a second node beside theirs. The
    /// two do not share memories, so the appliance appears to have forgotten
    /// everything it was ever told through the other one.
    func testAnInstalledNodeIsPreferredOverTheVendoredOne() {
        let installed = makeBundle(
            named: "SAGE.app",
            identifier: SageNodeLocator.expectedBundleIdentifier
        )
        let choice = SageNodeChoice.resolve(
            vendored: vendored(),
            installedCandidates: [installed]
        )

        XCTAssertEqual(choice?.source, .installed, "the owner's own node was not chosen")
        XCTAssertTrue(choice?.executable.path.contains("SAGE.app") == true)
        XCTAssertFalse(
            choice?.executable.path.contains("Vendored.app") == true,
            "a second node would be started beside the owner's"
        )
    }

    /// And Mynah may not manage it.
    func testTheOwnersNodeIsNeverMynahsToManage() {
        let installed = makeBundle(
            named: "SAGE.app",
            identifier: SageNodeLocator.expectedBundleIdentifier
        )
        let choice = SageNodeChoice.resolve(
            vendored: vendored(),
            installedCandidates: [installed]
        )

        XCTAssertTrue(choice?.isTheOwners == true)
        XCTAssertFalse(
            choice?.mayBeManagedByMynah == true,
            "Mynah believes it may upgrade or replace a node the owner installed"
        )
    }

    /// The fallback still works: a Mac with no SAGE gets the bundled one.
    func testAMacWithNoSageUsesTheVendoredCopy() {
        let choice = SageNodeChoice.resolve(
            vendored: vendored(),
            installedCandidates: [root.appendingPathComponent("Nothing.app")]
        )

        XCTAssertEqual(choice?.source, .vendored)
        XCTAssertTrue(choice?.mayBeManagedByMynah == true, "Mynah must own its own copy")
    }

    /// The name is not the check.
    ///
    /// A directory called SAGE.app that is not SAGE must not be executed, and
    /// must not stop the vendored copy being used either.
    func testADirectoryNamedLikeSageIsNotTreatedAsSage() {
        let impostor = makeBundle(named: "SAGE.app", identifier: "com.example.not-sage")
        let choice = SageNodeChoice.resolve(
            vendored: vendored(),
            installedCandidates: [impostor]
        )

        XCTAssertEqual(
            choice?.source, .vendored,
            "something merely named SAGE.app was accepted as the owner's node"
        )
    }

    /// An unverifiable node is still the owner's.
    ///
    /// Verification fails for ordinary reasons on the machine of anyone who
    /// works on SAGE — a local build, their own certificate, a bundle they
    /// moved. Refusing to use it would leave Mynah starting a second node beside
    /// it, which is the exact outcome this exists to prevent. Whether it can be
    /// trusted to run is a different question from whether Mynah may replace it.
    func testANodeWithoutASignatureIsStillTheOwners() {
        let unsigned = makeBundle(
            named: "SAGE.app",
            identifier: SageNodeLocator.expectedBundleIdentifier
        )
        let choice = SageNodeChoice.resolve(
            vendored: vendored(),
            installedCandidates: [unsigned]
        )

        XCTAssertEqual(choice?.source, .installed)
        XCTAssertFalse(choice?.mayBeManagedByMynah == true)
    }

    /// Only the two places macOS puts applications are searched.
    ///
    /// A wider search eventually finds a build directory or a Downloads folder
    /// and treats a half-finished copy as the owner's node.
    func testOnlyTheApplicationsFoldersAreSearched() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let searched = SageNodeChoice.installedCandidates(homeDirectory: home).map(\.path)

        XCTAssertEqual(searched, [
            "/Applications/SAGE.app",
            "/Users/someone/Applications/SAGE.app"
        ], "the search for an installed node has widened: \(searched)")
    }

    // MARK: Nothing may hardcode the vendored path again

    /// The service configuration must go through the resolver.
    ///
    /// It pointed straight at Contents/Resources/SAGE.app for as long as this
    /// app has existed, which was invisible until it ran on a Mac that already
    /// had SAGE — and by then it had started a second node beside the owner's.
    /// A source check, because the alternative is standing up launchd services
    /// in a test.
    func testTheServiceConfigurationDoesNotHardcodeTheVendoredNode() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/MynahMac/SignalBackgroundServices.swift"),
            encoding: .utf8
        )
        let dense = source.filter { !$0.isWhitespace }

        XCTAssertTrue(
            dense.contains("SageNodeChoice.resolve"),
            "the daemon's SAGE path no longer goes through the resolver, so a Mac "
                + "with SAGE already installed will get a second node"
        )
        // The vendored path may still appear — as the fallback handed to
        // resolve() — but never as the value assigned to `sage:`.
        XCTAssertFalse(
            dense.contains("sage:contents.appendingPathComponent(\"Resources/SAGE.app"),
            "the vendored node is being used directly again"
        )
    }

    // MARK: Exactly one thing of Mynah's is written inside SAGE

    /// Mynah writes one file into `~/.sage`, and it is its own key.
    ///
    /// This test used to assert the opposite — that nothing of Mynah's went into
    /// `~/.sage` at all — on the reasoning that an appliance must not write into
    /// somebody else's node state. **That reasoning was about ownership and it
    /// answered the wrong question.** CEREBRUM discovers agent keys in
    /// `~/.sage/agents/`, so a key kept anywhere else is one the owner cannot
    /// see, approve, or grant a domain to through the interface built for
    /// exactly that. Ownership is not what discovery keys on; location is.
    ///
    /// The concern the old assertion was protecting has not gone away, so it is
    /// asserted here in the form that still holds: one file, in a directory that
    /// is Mynah's alone, and nothing else. Not the operator key, not `~/.sage`
    /// itself, and not another agent's directory.
    func testMynahWritesNothingInsideSageExceptItsOwnKey() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let key = MynahIdentity.applianceKeyURL(environment: [:], homeDirectory: home)
        let agents = home.appendingPathComponent(".sage/agents", isDirectory: true).path

        XCTAssertTrue(
            key.path.hasPrefix(agents + "/"),
            "Mynah's key is not where CEREBRUM looks for agent keys: \(key.path)"
        )
        XCTAssertEqual(
            key.deletingLastPathComponent().lastPathComponent,
            MynahIdentity.applianceDirectoryName,
            "Mynah's key is loose in the agents directory rather than in its own"
        )
        XCTAssertNotEqual(
            key.path,
            MynahIdentity.nodeOperatorKeyURL(environment: [:], homeDirectory: home).path
        )
    }

    /// Retired keys stay out of it.
    ///
    /// The agents directory should hold exactly the one key this appliance
    /// currently signs with. A pile of superseded identities beside it is how a
    /// console ends up offering the owner a choice between four Mynahs, three of
    /// which are dead.
    func testRetiredKeysAreNotLeftInTheAgentsDirectory() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("retired-keys-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let live = Data(repeating: 4, count: 32)
        try OwnerOnlyFileSecurity.write(
            live,
            to: MynahIdentity.applianceKeyURL(environment: [:], homeDirectory: home)
        )

        let backup = MynahIdentity.backUpApplianceKeyIfPresent(environment: [:], homeDirectory: home)

        XCTAssertNotNil(backup)
        XCTAssertFalse(
            backup!.path.hasPrefix(home.appendingPathComponent(".sage").path),
            "a retired identity was left inside SAGE's own directory: \(backup!.path)"
        )
    }

    /// And the operator's key is never what Mynah signs as.
    ///
    /// Adopting it would make the appliance indistinguishable from the owner on
    /// their own node — able to write, forget and rename as them.
    func testTheOperatorKeyIsNotMynahsIdentity() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let operatorKey = MynahIdentity.nodeOperatorKeyURL(
            environment: [:],
            homeDirectory: home
        ).path
        let mynahKey = MynahIdentity.applianceKeyURL(homeDirectory: home).path

        XCTAssertNotEqual(operatorKey, mynahKey)
        XCTAssertTrue(operatorKey.hasSuffix(".sage/agent.key"), operatorKey)
    }
}
