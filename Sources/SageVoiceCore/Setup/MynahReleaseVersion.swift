import Foundation

/// A Mynah release, ordered.
///
/// **A deliberate port of `QuietTypeReleaseVersion`, not a fresh design.**
/// QuietType is the sibling app and its updater has already been through the
/// awkward cases — a tag that carries the product name, an asset filename used as
/// a fallback when the tag is unparseable, prereleases that must sort *below* the
/// stable release they lead to. Rewriting that from scratch would mean
/// rediscovering the same edge cases in a second codebase, and the two apps would
/// drift on what "newer" means.
///
/// The channel ordering is the part worth stating out loud: `1.1.0-beta.2` is
/// **older** than `1.1.0`, because a prerelease precedes the release it becomes.
/// Comparing the numbers alone would offer somebody on the stable build an
/// "update" to a beta of what they already have.
public struct MynahReleaseVersion: Comparable, Equatable, Sendable {

    public enum Channel: Int, Comparable, Sendable {
        case beta = 0
        case releaseCandidate = 1
        case stable = 2

        public static func < (lhs: Channel, rhs: Channel) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public let major: Int
    public let minor: Int
    public let patch: Int
    public let channel: Channel
    /// `0` for a stable release. Only meaningful on a prerelease.
    public let prereleaseNumber: Int

    public init(
        major: Int,
        minor: Int,
        patch: Int,
        channel: Channel = .stable,
        prereleaseNumber: Int = 0
    ) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.channel = channel
        self.prereleaseNumber = prereleaseNumber
    }

    // MARK: - Reading one

    /// Parses a tag, a version string, or a DMG filename.
    ///
    /// All three are accepted because all three occur: GitHub tags are
    /// `v1.1.0`, this repo's artifacts are `Mynah-1.1.0-macOS-arm64.dmg`, and
    /// `CFBundleShortVersionString` is bare. A parser that took only one shape
    /// would need callers to normalise first, and the caller that forgot is the
    /// one that silently stops offering updates.
    public static func parse(_ value: String) -> MynahReleaseVersion? {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("mynah-") {
            normalized.removeFirst("mynah-".count)
        }
        let artifactSuffix = "-macos-arm64.dmg"
        if normalized.hasSuffix(artifactSuffix) {
            normalized.removeLast(artifactSuffix.count)
        }
        if normalized.hasPrefix("v") {
            normalized.removeFirst()
        }

        let parts = normalized.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let versionParts = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard versionParts.count == 3,
              let major = Int(versionParts[0]), major >= 0,
              let minor = Int(versionParts[1]), minor >= 0,
              let patch = Int(versionParts[2]), patch >= 0 else {
            return nil
        }

        guard parts.count == 2 else {
            return MynahReleaseVersion(major: major, minor: minor, patch: patch)
        }

        // `beta.3` / `rc.1`. A prerelease with no number, or an unrecognised
        // channel, is refused rather than guessed — an unparseable tag that
        // silently became "stable" would outrank the release it precedes.
        let prereleaseParts = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        guard prereleaseParts.count == 2,
              let prereleaseNumber = Int(prereleaseParts[1]),
              prereleaseNumber > 0 else {
            return nil
        }
        let channel: Channel
        switch prereleaseParts[0] {
        case "beta": channel = .beta
        case "rc": channel = .releaseCandidate
        default: return nil
        }
        return MynahReleaseVersion(
            major: major,
            minor: minor,
            patch: patch,
            channel: channel,
            prereleaseNumber: prereleaseNumber
        )
    }

    /// The running build, from `CFBundleShortVersionString`.
    ///
    /// Falls back to `0.0.0` rather than crashing or returning `nil`: an
    /// unreadable bundle version should make every published release look newer,
    /// so the owner is offered the update instead of being silently stranded on a
    /// build the app cannot identify.
    public static func current(bundle: Bundle = .main) -> MynahReleaseVersion {
        let raw = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        return parse(raw) ?? MynahReleaseVersion(major: 0, minor: 0, patch: 0)
    }

    // MARK: - Showing one

    /// What the owner reads. `1.1.0`, or `1.1.0 beta 2`.
    public var displayName: String {
        let core = "\(major).\(minor).\(patch)"
        switch channel {
        case .stable: return core
        case .beta: return "\(core) beta \(prereleaseNumber)"
        case .releaseCandidate: return "\(core) rc \(prereleaseNumber)"
        }
    }

    // MARK: - Ordering

    public static func < (lhs: MynahReleaseVersion, rhs: MynahReleaseVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        // Same numbers: a prerelease precedes the stable release it leads to.
        if lhs.channel != rhs.channel { return lhs.channel < rhs.channel }
        return lhs.prereleaseNumber < rhs.prereleaseNumber
    }
}
