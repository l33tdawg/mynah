import Foundation

/// What happened when we tried to obtain a SAGE node.
public enum SageNodeProvisioning: Equatable, Sendable {
    /// Already present — the vendored copy, or one the owner installed. The
    /// overwhelmingly common outcome, and the one that needs no interaction.
    case alreadyPresent(executablePath: String, version: String?)

    /// The installer was downloaded and handed to the owner to complete.
    ///
    /// Deliberately not "installed": see `SageNodeInstaller.provision`.
    case downloadedAwaitingUser(diskImagePath: String, guidance: String)

    /// Could not be obtained automatically; the releases page is the fallback.
    case unavailable(reason: String, releasesPage: URL)

    /// A node the owner installed that could not be verified.
    ///
    /// Distinct from `unavailable` because the answer is the opposite: something
    /// IS there, it belongs to the owner, and Mynah must leave it alone. The
    /// previous behaviour was to download a replacement, which on a machine
    /// belonging to anyone who works on SAGE — a local build, their own signing
    /// certificate — meant overwriting the store holding their memories, agents
    /// and keys because a signature check did not recognise it.
    case unusable(executablePath: String, reason: String)

    /// Whether the caller can proceed without the owner doing anything.
    public var isReady: Bool {
        if case .alreadyPresent = self { return true }
        return false
    }
}

/// Obtains a SAGE node when this build did not ship one.
///
/// ## Why this downloads but does not install
///
/// The normal path is that SAGE is vendored into `Contents/Resources/SAGE.app`
/// at build time and codesigned as part of this app, so there is nothing to
/// obtain. This type only runs when that did not happen — an unbundled dev
/// build, or a stripped-down download.
///
/// When it does run, it fetches the official DMG and hands it to the owner
/// rather than silently placing an app on their disk. That is not timidity, and
/// it is what QuietType does too:
///
///  - Writing to `/Applications` needs privileges this process does not have
///    and should not ask for.
///  - An app downloaded by a background process carries `com.apple.quarantine`.
///    Copying it into place ourselves produces a bundle that Gatekeeper may
///    refuse on first launch, with an error that looks like corruption.
///  - "A program silently installed another program" is a shape users are
///    right to be suspicious of, and we would be teaching them to ignore it.
///
/// Every download is verified — SHA-256 when the release publishes one, and the
/// bundle identity before anything is executed — because the failure mode of
/// getting this wrong is running an attacker's binary as the owner's agent.
public final class SageNodeInstaller: @unchecked Sendable {
    public static let repository = "l33tdawg/sage"

    public static let releasesPageURL =
        URL(string: "https://github.com/\(SageNodeInstaller.repository)/releases/latest")!

    private static let latestReleaseAPI =
        URL(string: "https://api.github.com/repos/\(SageNodeInstaller.repository)/releases/latest")!

    private let session: URLSession
    private let fileManager: FileManager
    private let userAgent = "SAGEVoiceBridge-Installer"

    public init(session: URLSession = .shared, fileManager: FileManager = .default) {
        self.session = session
        self.fileManager = fileManager
    }

    /// Finds a usable node, or obtains one.
    ///
    /// - Parameter probe: a completed environment probe, so this does not
    ///   duplicate detection the setup flow has already done.
    public func provision(given probe: EnvironmentProbeResult) async -> SageNodeProvisioning {
        if let path = probe.sage.executablePath {
            let executable = URL(fileURLWithPath: path)
            // A bare binary on PATH has no bundle to verify; trust the probe's
            // executability check for that case.
            guard let appBundle = SageNodeLocator.appBundle(containing: executable) else {
                return .alreadyPresent(executablePath: path, version: nil)
            }
            switch SageNodeLocator.verifyBundle(at: appBundle, fileManager: fileManager) {
            case .success(let verified):
                return .alreadyPresent(
                    executablePath: verified.path,
                    version: SageNodeLocator.bundleVersion(at: appBundle)
                )
            case .failure(let error):
                // Present but not verifiable. Reported, never replaced.
                //
                // Downloading "a known-good copy" over somebody's own node is
                // the one thing this must never do. Verification fails for
                // ordinary reasons on a machine belonging to someone who works
                // on SAGE — a local build, their own signing certificate, a
                // bundle they moved — and none of those mean the appliance is
                // entitled to overwrite the store holding their memories, their
                // agents and their keys.
                //
                // The owner is told and decides. An appliance that silently
                // replaces the thing it was asked to attach to has done
                // something nobody asked for and cannot be undone.
                return .unusable(
                    executablePath: path,
                    reason: "the SAGE already installed on this Mac could not be verified "
                        + "(\(error)). Mynah will not replace it — reinstall SAGE yourself "
                        + "if you want it repaired."
                )
            }
        }
        return await download(becauseOf: "no SAGE node is installed on this Mac")
    }

    // MARK: Download

    private func download(becauseOf reason: String) async -> SageNodeProvisioning {
        do {
            let release = try await fetchLatestRelease()
            guard let asset = Self.selectMacOSAsset(from: release) else {
                return .unavailable(
                    reason: "\(reason), and the latest release publishes no macOS disk image.",
                    releasesPage: Self.releasesPageURL
                )
            }
            let destination = try await downloadAsset(asset)
            try verifyChecksumIfPublished(of: destination, asset: asset, release: release)

            return .downloadedAwaitingUser(
                diskImagePath: destination.path,
                guidance: """
                Downloaded \(asset.name). Open it, drag SAGE into Applications, \
                launch it once to finish its setup, then re-run setup here.
                """
            )
        } catch {
            return .unavailable(
                reason: "\(reason), and it could not be downloaded automatically: \(error).",
                releasesPage: Self.releasesPageURL
            )
        }
    }

    /// Picks the macOS arm64 disk image, preferring an explicitly-named one.
    ///
    /// Exposed for testing against captured release JSON: picking the wrong
    /// asset means downloading a Linux tarball and reporting success.
    public static func selectMacOSAsset(from release: GitHubRelease) -> GitHubReleaseAsset? {
        func isMacOS(_ name: String) -> Bool {
            name.contains("macos") || name.contains("darwin") || name.hasSuffix(".dmg")
        }
        func isARM64(_ name: String) -> Bool {
            name.contains("arm64") || name.contains("aarch64")
        }

        let named = release.assets.map { ($0, $0.name.lowercased()) }
        // This product is Apple-Silicon only (WhisperKit runs on the Neural
        // Engine), so an x86 image would be the wrong answer, not a fallback.
        if let exact = named.first(where: { $0.1.hasSuffix(".dmg") && $0.1.contains("sage") && isARM64($0.1) }) {
            return exact.0
        }
        if let anyARM = named.first(where: { $0.1.hasSuffix(".dmg") && isARM64($0.1) }) {
            return anyARM.0
        }
        if let anyDMG = named.first(where: { $0.1.hasSuffix(".dmg") && isMacOS($0.1) }) {
            return anyDMG.0
        }
        return nil
    }

    private func fetchLatestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: Self.latestReleaseAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw SageNodeError.launchFailed("GitHub returned HTTP \(status) for the latest release")
        }
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    private func downloadAsset(_ asset: GitHubReleaseAsset) async throws -> URL {
        let directory = try downloadDirectory()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(asset.name)

        var request = URLRequest(url: asset.browserDownloadURL)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 600

        let (temporary, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw SageNodeError.launchFailed("download returned HTTP \(status)")
        }
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: temporary, to: destination)
        return destination
    }

    /// Verifies the SHA-256 the release notes publish, when they publish one.
    ///
    /// GitHub does not expose asset digests through the API, so the convention
    /// is a `name  sha256` line in the release body. Absent one this is a no-op:
    /// TLS to github.com is what we are relying on either way, and refusing to
    /// proceed would strand every owner on a release that forgot the line.
    private func verifyChecksumIfPublished(
        of file: URL,
        asset: GitHubReleaseAsset,
        release: GitHubRelease
    ) throws {
        guard let expected = Self.publishedChecksum(for: asset.name, in: release.body ?? "") else {
            return
        }
        let actual = try FileDigest.sha256Hex(ofFileAt: file, fileManager: fileManager)
        guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
            try? fileManager.removeItem(at: file)
            throw SageNodeError.malformedBundle(
                "checksum mismatch for \(asset.name): expected \(expected), got \(actual)"
            )
        }
    }

    /// Finds `<64 hex chars>` on the same line as the asset name, in either
    /// order — both `shasum` output and Markdown tables occur in the wild.
    public static func publishedChecksum(for assetName: String, in body: String) -> String? {
        for line in body.split(whereSeparator: \.isNewline) {
            guard line.contains(assetName) else { continue }
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "|" || $0 == "`" })
            if let digest = tokens.first(where: { token in
                token.count == 64 && token.allSatisfy(\.isHexDigit)
            }) {
                return String(digest)
            }
        }
        return nil
    }

    private func downloadDirectory() throws -> URL {
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw SageNodeError.launchFailed("could not locate Application Support")
        }
        return support
            .appendingPathComponent("SAGE Voice Bridge", isDirectory: true)
            .appendingPathComponent("Downloads", isDirectory: true)
    }
}

// MARK: - GitHub release shapes

public struct GitHubRelease: Decodable, Sendable {
    public let tagName: String?
    public let body: String?
    public let assets: [GitHubReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case body
        case assets
    }

    public init(tagName: String?, body: String?, assets: [GitHubReleaseAsset]) {
        self.tagName = tagName
        self.body = body
        self.assets = assets
    }
}

public struct GitHubReleaseAsset: Decodable, Sendable {
    public let name: String
    public let browserDownloadURL: URL

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }

    public init(name: String, browserDownloadURL: URL) {
        self.name = name
        self.browserDownloadURL = browserDownloadURL
    }
}
