import XCTest
@testable import SageVoiceCore

/// Tests for how the appliance obtains its SAGE node.
///
/// The security-relevant claim here is that nothing gets executed as the
/// owner's agent without being identified first, and that a download is
/// verified when the release gives us something to verify against.
final class SageNodeProvisioningTests: XCTestCase {

    // MARK: - Bundle verification

    /// Directory of the right name, wrong identity. Refusing is the whole point:
    /// this executable is about to be run as the owner's agent.
    func testABundleWithTheWrongIdentifierIsRefused() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let app = try makeFakeSageApp(in: root, bundleIdentifier: "com.attacker.notsage")

        let result = SageNodeLocator.verifyBundle(at: app)
        guard case .failure(.unexpectedBundleIdentifier(let found, let expected)) = result else {
            return XCTFail("expected identifier rejection, got \(result)")
        }
        XCTAssertEqual(found, "com.attacker.notsage")
        XCTAssertEqual(expected, "com.sage.brain")
    }

    func testAGenuineBundleVerifiesAndYieldsItsExecutable() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let app = try makeFakeSageApp(in: root, bundleIdentifier: "com.sage.brain", version: "11.13.9")

        guard case .success(let executable) = SageNodeLocator.verifyBundle(at: app) else {
            return XCTFail("a well-formed bundle must verify")
        }
        XCTAssertEqual(executable.lastPathComponent, "sage-gui")
        XCTAssertEqual(SageNodeLocator.bundleVersion(at: app), "11.13.9")
    }

    /// A bundle whose executable bit was lost — a real outcome of copying an app
    /// through a zip that does not preserve permissions.
    func testABundleWithoutARunnableExecutableIsRefused() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let app = try makeFakeSageApp(in: root, bundleIdentifier: "com.sage.brain")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: app.appendingPathComponent("Contents/MacOS/sage-gui").path
        )

        guard case .failure(.notRunnable) = SageNodeLocator.verifyBundle(at: app) else {
            return XCTFail("a non-executable binary must be refused")
        }
    }

    func testAppBundleIsRecoveredFromAnExecutablePath() {
        let executable = URL(fileURLWithPath: "/Applications/SAGE.app/Contents/MacOS/sage-gui")
        XCTAssertEqual(
            SageNodeLocator.appBundle(containing: executable)?.path,
            "/Applications/SAGE.app"
        )
        // A bare binary on PATH is not in a bundle and must not be mistaken for one.
        XCTAssertNil(
            SageNodeLocator.appBundle(containing: URL(fileURLWithPath: "/usr/local/bin/sage-gui"))
        )
    }

    // MARK: - Release asset selection

    /// Picking the wrong asset means downloading a Linux tarball and reporting
    /// success. This product is Apple-Silicon only, so an x86 image is the wrong
    /// answer rather than a fallback.
    func testAssetSelectionPrefersTheAppleSiliconDiskImage() {
        let release = GitHubRelease(
            tagName: "v11.13.9",
            body: nil,
            assets: [
                asset("sage-linux-amd64.tar.gz"),
                asset("sage-v11.13.9-macos-x86_64.dmg"),
                asset("sage-v11.13.9-macos-arm64.dmg"),
                asset("checksums.txt")
            ]
        )
        XCTAssertEqual(
            SageNodeInstaller.selectMacOSAsset(from: release)?.name,
            "sage-v11.13.9-macos-arm64.dmg"
        )
    }

    func testAssetSelectionReturnsNilRatherThanAnUnrelatedArtifact() {
        let release = GitHubRelease(
            tagName: "v1",
            body: nil,
            assets: [asset("sage-linux-amd64.tar.gz"), asset("SOURCE.tar.gz")]
        )
        XCTAssertNil(
            SageNodeInstaller.selectMacOSAsset(from: release),
            "a Linux tarball must never be selected as the macOS node"
        )
    }

    // MARK: - Published checksum

    /// GitHub does not expose asset digests through the API, so the convention
    /// is a line in the release body. Both shasum output and Markdown tables
    /// occur in the wild.
    func testPublishedChecksumIsFoundInEitherCommonLayout() {
        let digest = String(repeating: "a1b2c3d4", count: 8)  // 64 hex chars
        XCTAssertEqual(digest.count, 64)

        let shasumStyle = "\(digest)  sage-v11.13.9-macos-arm64.dmg"
        XCTAssertEqual(
            SageNodeInstaller.publishedChecksum(for: "sage-v11.13.9-macos-arm64.dmg", in: shasumStyle),
            digest
        )

        let tableStyle = "| `sage-v11.13.9-macos-arm64.dmg` | `\(digest)` |"
        XCTAssertEqual(
            SageNodeInstaller.publishedChecksum(for: "sage-v11.13.9-macos-arm64.dmg", in: tableStyle),
            digest
        )
    }

    /// A digest published for a *different* asset must not be adopted — that
    /// would verify the wrong file and pass.
    func testChecksumForAnotherAssetIsNotAdopted() {
        let body = "\(String(repeating: "f", count: 64))  sage-linux-amd64.tar.gz"
        XCTAssertNil(
            SageNodeInstaller.publishedChecksum(for: "sage-macos-arm64.dmg", in: body)
        )
    }

    func testAReleaseWithNoChecksumLineIsNotAFailure() {
        XCTAssertNil(SageNodeInstaller.publishedChecksum(for: "sage.dmg", in: "Release notes.\nBug fixes."))
    }

    // MARK: - File digest

    func testFileDigestMatchesAKnownSHA256() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("payload.bin")
        try Data("abc".utf8).write(to: file)

        // Well-known SHA-256 of "abc".
        XCTAssertEqual(
            try FileDigest.sha256Hex(ofFileAt: file),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    /// The digest is streamed in 1 MiB chunks; a payload spanning several of
    /// them must produce the same answer as hashing it whole.
    func testFileDigestIsCorrectAcrossChunkBoundaries() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("large.bin")
        let payload = Data((0..<(FileDigest.chunkByteCount * 2 + 12_345)).map { UInt8($0 % 251) })
        try payload.write(to: file)

        var reference = ""
        // Recompute with a single-shot hash of the same bytes.
        reference = FileDigest.sha256Hex(of: payload)

        XCTAssertEqual(try FileDigest.sha256Hex(ofFileAt: file), reference)
    }

    func testMissingFileIsReportedNotCrashed() {
        XCTAssertThrowsError(
            try FileDigest.sha256Hex(ofFileAt: URL(fileURLWithPath: "/nonexistent/payload.bin"))
        ) { error in
            guard case SageNodeError.notFound = error else {
                return XCTFail("expected .notFound, got \(error)")
            }
        }
    }

    // MARK: - Provisioning

    /// The common case: SAGE is already here (vendored or installed), so there
    /// is nothing to download and nothing for the owner to do.
    func testAnAlreadyPresentVerifiedNodeNeedsNoDownload() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let app = try makeFakeSageApp(in: root, bundleIdentifier: "com.sage.brain", version: "11.13.9")
        let probe = EnvironmentProbeResult(
            sage: SageInstallReport(
                executablePath: app.appendingPathComponent("Contents/MacOS/sage-gui").path,
                stateDirectory: root.path,
                hasStateDirectory: true,
                hasConfiguration: true
            )
        )

        let outcome = await SageNodeInstaller().provision(given: probe)

        guard case .alreadyPresent(_, let version) = outcome else {
            return XCTFail("expected .alreadyPresent, got \(outcome)")
        }
        XCTAssertEqual(version, "11.13.9")
        XCTAssertTrue(outcome.isReady)
    }

    // MARK: - Helpers

    private func asset(_ name: String) -> GitHubReleaseAsset {
        GitHubReleaseAsset(
            name: name,
            browserDownloadURL: URL(string: "https://example.invalid/\(name)")!
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sage-node-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeFakeSageApp(
        in root: URL,
        bundleIdentifier: String,
        version: String = "1.0.0"
    ) throws -> URL {
        let app = root.appendingPathComponent("SAGE.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)

        let executable = macOS.appendingPathComponent("sage-gui")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let info: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleShortVersionString": version,
            "CFBundleExecutable": "sage-gui"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app
    }
}
