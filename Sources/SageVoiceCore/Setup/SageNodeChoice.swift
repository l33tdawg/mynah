import Foundation

/// Which SAGE this appliance talks to, and whether it belongs to somebody else.
///
/// Mynah ships a copy of SAGE so that a Mac with none can still run it. On a Mac
/// that already has one — which is every machine belonging to someone already
/// using SAGE, the people most likely to be handed this — the owner's node is
/// the one that matters. It holds their memories, their agents and their keys,
/// and it was there first.
///
/// ## The rule
///
/// **If a SAGE node is already installed, Mynah uses it and changes nothing
/// about it.** It does not start a second one, does not upgrade it, does not
/// download a replacement, and does not write to its state. Mynah becomes
/// another agent on a node the owner already runs, which is the whole point —
/// duplicating it would give them two brains that cannot see each other's
/// memories, and the appliance would appear to have forgotten everything it was
/// told through the other one.
///
/// The vendored copy is a fallback, and a fallback only. Once a local node is
/// found, the bundled one is not a candidate for anything.
public struct SageNodeChoice: Sendable, Equatable {

    public enum Source: Sendable, Equatable {
        /// A SAGE the owner installed. Off limits: used, never managed.
        case installed
        /// The copy inside Mynah's own bundle, because this Mac had none.
        case vendored
    }

    public let executable: URL
    public let source: Source

    public var isTheOwners: Bool { source == .installed }

    /// Whether Mynah may install, upgrade or replace this node.
    ///
    /// Only ever true for its own vendored copy. A node the owner installed is
    /// theirs, and an appliance that quietly upgrades somebody else's memory
    /// store because it preferred a different version is doing something nobody
    /// asked for.
    public var mayBeManagedByMynah: Bool { source == .vendored }

    /// Where an installed SAGE is looked for, in order.
    ///
    /// Both of the places macOS puts an application, and nowhere else. A search
    /// that ranged wider would eventually find a build directory or a Downloads
    /// folder and treat a half-finished copy as the owner's node.
    public static func installedCandidates(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        [
            URL(fileURLWithPath: "/Applications/SAGE.app"),
            homeDirectory.appendingPathComponent("Applications/SAGE.app")
        ]
    }

    /// Decides which node to use.
    ///
    /// An installed bundle wins whenever one is present and carries SAGE's
    /// bundle identifier. Deliberately NOT conditional on it verifying: a node
    /// the owner built themselves, or signed with their own certificate, is
    /// still theirs, and refusing to use it would leave Mynah starting a second
    /// node beside it — the exact outcome this exists to prevent. Whether it can
    /// be trusted to *run* is a separate question from whether Mynah is entitled
    /// to replace it.
    public static func resolve(
        vendored: URL?,
        installedCandidates: [URL] = SageNodeChoice.installedCandidates(),
        fileManager: FileManager = .default
    ) -> SageNodeChoice? {
        for bundle in installedCandidates {
            let executable = bundle
                .appendingPathComponent("Contents/MacOS")
                .appendingPathComponent(SageNodeLocator.executableName)
            guard fileManager.isExecutableFile(atPath: executable.path) else { continue }
            guard identifier(ofBundleAt: bundle, fileManager: fileManager)
                    == SageNodeLocator.expectedBundleIdentifier else {
                // A directory called SAGE.app that is not SAGE. Skipped rather
                // than run: the name is not the check.
                continue
            }
            return SageNodeChoice(executable: executable, source: .installed)
        }

        guard let vendored, fileManager.isExecutableFile(atPath: vendored.path) else { return nil }
        return SageNodeChoice(executable: vendored, source: .vendored)
    }

    private static func identifier(ofBundleAt url: URL, fileManager: FileManager) -> String? {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard let data = fileManager.contents(atPath: plist.path),
              let root = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
              ) as? [String: Any] else { return nil }
        return root["CFBundleIdentifier"] as? String
    }
}
