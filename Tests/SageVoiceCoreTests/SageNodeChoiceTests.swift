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
}
