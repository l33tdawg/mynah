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
    /// ## The pair, and which question each answers
    ///
    /// **This is installed-wins. `EnvironmentProbe.defaultSageBundleExecutables`
    /// is vendored-first.** Both return a path to a `sage-gui`, both look
    /// correct at the call site, and picking the wrong one produces an empty
    /// screen rather than an error.
    ///
    /// - *This* answers **"which node holds the owner's memories?"** Use it for
    ///   anything that reads, writes or shows the owner's data.
    /// - The probe list answers **"what can this app run?"** Use it during
    ///   setup, when the question really is about capability.
    ///
    /// The failure is silent because a vendored node is a perfectly valid node
    /// — it simply has none of the owner's memories in it. So the wrong choice
    /// starts a second, empty brain beside theirs and every cheap check passes.
    /// The Memories screen, the task board and About have each shipped that
    /// way.
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

    // MARK: - Why setup does not provision Mynah's permissions
    //
    // DELIBERATELY ABSENT, and this note exists so nobody rebuilds the dead end.
    //
    // On a `.vendored` node — one Mynah created — a first run lands with the
    // appliance agent carrying capability mask **0**: no restrictions at all.
    // That reads like an oversight. It is not, and the obvious fixes do not
    // work. Measured and verified against a real chain, 2026-07-29.
    //
    // ## Why it happens
    //
    // A fresh node starts at app_version 1 and climbs to 22 through sixteen
    // governance forks, each needing ~200 blocks to activate — **60 to 90
    // minutes**, not the 30 seconds the watchdog's tick suggests. The
    // fail-closed mask (`DefaultSelfRegisteredAgentCapabilities`, 30) is only
    // stamped on keys registering *after* app-v22 activates, and
    // `processAgentRegister` preserves an existing agent's capabilities
    // forever. So every realistic setup — an API key in minutes, a local brain
    // in tens of minutes — registers long before the restriction exists and is
    // grandfathered unrestricted. The mute case needs somebody to abandon setup
    // for over an hour.
    //
    // ## Why "setup promotes Mynah to admin" cannot be built
    //
    // There is no transaction that promotes an existing agent to global admin:
    //
    //   * `AgentSetPermission` — behind `PUT /v1/agent/{id}/permission` —
    //     carries Clearance, DomainAccess, VisibleAgents, OrgID, DeptID and
    //     Capabilities. **No Role field.**
    //   * `processAgentRegister` silently downgrades a wire-supplied
    //     `role=admin` to `member` (app-v9).
    //   * `bootstrapAdminFromSQL` is disabled post-app-v11.
    //   * Genesis seeding is the only route, and it happens at chain creation.
    //
    // Role would not have been enough anyway: the capability mask is enforced
    // in `processMemorySubmit` with **no admin exemption** — an agent that is
    // nominally root and carries mask 30 still cannot write a word.
    //
    // ## What the intended mechanism is
    //
    // SAGE has already built it. `genesisAppStateForVendoredAgent` in
    // `cmd/sage-gui/node.go` writes an app-v23 genesis manifest for exactly
    // this case — its own comment says it lets "a bundled application consume
    // the same stable identity without any manual CEREBRUM ceremony". Both the
    // root key and the agent key sign a chain-bound manifest carrying:
    //
    //     Profile:      Companion
    //     Capabilities: ReadAllDomains | DenySharedDomainWrite
    //                 | DenyDomainClaim | DenyForeignDomainWrite   (= 15)
    //     HomeDomain:   <configured>        ← `SageRitual.memoryDomain`
    //     AgentID:      <the bundled app's key>  ← `applianceKeyURL()`
    //
    // That is Companion plus an owned home subject **from block 1** — no race,
    // no ordering window, and no interim state where Mynah can claim arbitrary
    // subjects. It also refuses to let the root and agent keys be the same
    // file, which is `MynahIdentity`'s own rule enforced at genesis.
    //
    // ## Why it is not wired up yet
    //
    // The bundled SAGE is **11.14.1 with `max_app_version = 22`**. app-v23 is
    // present in consensus but dormant (`appV23AppliedHeight == 0`), the
    // auto-advance ladder will not climb to it, and no REST route exposes
    // `LocalAgentApprove` or `AgentRoleChange`.
    //
    // So the work is **a re-vendor plus a config**, not a feature: run
    // `scripts/vendor-sage.sh` for a SAGE with app-v23 active, then pass
    // `VendoredAgentBootstrapConfig{AgentKeyFile:, HomeDomain:, Clearance:}` at
    // node creation. Until then the gap is covered honestly by
    // `ApplianceWriteReadiness`, which is what it is for.
    //
    // One thing to design for when it ships: `LocalAgentApprove` requires the
    // **target** key to sign its own approval, so on an `.installed` node the
    // owner cannot approve Mynah alone — Mynah has to produce a signature and
    // hand it to CEREBRUM. That is a real flow with a UI consequence.

    private static func identifier(ofBundleAt url: URL, fileManager: FileManager) -> String? {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard let data = fileManager.contents(atPath: plist.path),
              let root = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
              ) as? [String: Any] else { return nil }
        return root["CFBundleIdentifier"] as? String
    }
}
