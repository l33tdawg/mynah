import Foundation

/// The key Mynah signs SAGE requests with.
///
/// One key, in one place, and deliberately **not** the node operator's.
///
/// ## What this replaces
///
/// The app spawned `sage-gui mcp` from two places with two different identities:
///
///   * `MemoriesView` pinned `SAGE_IDENTITY_PATH` to `$SAGE_HOME/agent.key`,
///     which is the *node operator* key (`cmd/sage-gui/node.go:874`). Every
///     browse of the Memories screen therefore signed as the operator — the
///     highest privilege on the machine, carrying the `seeAll` read bypass,
///     ownership of every auto-registered domain, and the signature path into
///     every federation mutation.
///   * `ConversationModel` passed no environment at all, so the node fell
///     through to its per-project rule and minted a key from the process's
///     working directory. For a GUI app that directory is `/`.
///
/// So: one app, two identities, one of them the machine operator, and neither
/// of them a thing anyone could grant a permission to.
///
/// The operator fallback was not carelessness — the doc comment it replaced
/// explains it, and the reasoning was sound as far as it went. Without pinning,
/// the working-directory rule mints an identity with none of the owner's
/// memories in it, so the screen comes up empty. The operator key was reached
/// for because it was the only one that could see anything.
///
/// ## What this costs, said plainly
///
/// A dedicated identity starts with no memories and no grant, so the Memories
/// screen shows less than it did until SAGE can express "read all domains,
/// write only your own". That is the correct amount for an ungranted agent to
/// see, and getting there is the point: you cannot grant a permission to an
/// identity that does not exist, and you cannot meaningfully restrict one that
/// is already the operator.
public enum MynahIdentity {

    /// The variable the node reads first (`cmd/sage-gui/mcp.go:145`).
    public static let environmentVariable = "SAGE_IDENTITY_PATH"

    /// Where Mynah's own key lives.
    ///
    /// Beside the owner's provider keys and notes rather than in `~/.sage`,
    /// because it belongs to this app rather than to the node. The node creates
    /// the parent directory and generates the key on first use
    /// (`cmd/sage-gui/mcp.go:169-174`), so nothing here has to mint anything.
    public static func keyURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/SAGE Voice Bridge", isDirectory: true)
            .appendingPathComponent("agent.key", isDirectory: false)
    }

    /// The node operator's key — the thing this type exists to never return.
    ///
    /// Resolved the same way the node resolves it, `SAGE_HOME` included, so a
    /// non-standard install cannot slip past the comparison below.
    public static func nodeOperatorKeyURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let sageHome = environment["SAGE_HOME"].flatMap { value -> URL? in
            let expanded = NSString(string: value).expandingTildeInPath
            return expanded.isEmpty ? nil : URL(fileURLWithPath: expanded, isDirectory: true)
        } ?? homeDirectory.appendingPathComponent(".sage", isDirectory: true)
        return sageHome.appendingPathComponent("agent.key", isDirectory: false)
    }

    /// The path to sign as.
    ///
    /// An explicit `SAGE_IDENTITY_PATH` or `SAGE_AGENT_KEY` in the environment
    /// still wins — that is how someone drives the app as a specific agent for
    /// testing — with one exception, which is the whole point of this type: an
    /// override naming the node operator's key is refused rather than honoured.
    /// Making the old behaviour unrepresentable beats deleting it and trusting
    /// nobody writes it again.
    public static func resolvedKeyPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        log: (String) -> Void = { _ in }
    ) -> String {
        let ours = keyURL(homeDirectory: homeDirectory).path

        for name in [environmentVariable, "SAGE_AGENT_KEY"] {
            guard let raw = environment[name], !raw.isEmpty else { continue }
            let expanded = NSString(string: raw).expandingTildeInPath
            guard isSafeToAdopt(expanded, environment: environment, homeDirectory: homeDirectory) else {
                // Refused rather than obeyed, and said out loud. A silent refusal
                // means the app signs as a different agent than the environment
                // asked for and nobody finds out until the memories look wrong.
                log("[identity] ignoring \(name)=\(expanded): Mynah signs only as itself")
                continue
            }
            return expanded
        }
        return ours
    }

    /// Whether an override may be adopted.
    ///
    /// Two refusals, and the second is the one that took a review to see.
    ///
    /// The operator key, compared by *inode* rather than by path string.
    /// `standardizedFileURL` resolves `..` and nothing else — not symlinks, and
    /// not case, and macOS is case-insensitive by default, so `~/.SAGE/agent.key`
    /// or a symlink walked straight past a string comparison into full operator
    /// privilege.
    ///
    /// And any key belonging to *another* agent. `~/.sage/agents/<project>/` is
    /// where the node mints per-project identities — this repo's own session
    /// hooks export one — so honouring an arbitrary override lets Mynah silently
    /// become an existing agent and write, forget and rename as it. An override
    /// is for pointing Mynah at a *Mynah* key, so that is all it may point at.
    static func isSafeToAdopt(
        _ path: String,
        environment: [String: String],
        homeDirectory: URL
    ) -> Bool {
        let candidate = URL(fileURLWithPath: path).standardizedFileURL
        let operatorKey = nodeOperatorKeyURL(environment: environment, homeDirectory: homeDirectory)
        if sameFile(candidate, operatorKey) { return false }
        if candidate.path.compare(operatorKey.path, options: .caseInsensitive) == .orderedSame {
            return false
        }

        let ourDirectory = keyURL(homeDirectory: homeDirectory)
            .deletingLastPathComponent().standardizedFileURL.path
        return candidate.deletingLastPathComponent().path
            .compare(ourDirectory, options: .caseInsensitive) == .orderedSame
    }

    /// Same file on disk, whatever the two paths look like. Resolves symlinks
    /// and hard links, which a string comparison cannot.
    private static func sameFile(_ a: URL, _ b: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        guard let idA = try? a.resourceValues(forKeys: keys).fileResourceIdentifier,
              let idB = try? b.resourceValues(forKeys: keys).fileResourceIdentifier else {
            return false
        }
        return idA.isEqual(idB)
    }

    /// Environment for a spawned `sage-gui mcp`.
    ///
    /// Every spawn site must use this. Two call sites building their own
    /// environment is exactly how the app ended up with two identities.
    public static func childEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String: String] {
        [environmentVariable: resolvedKeyPath(environment: environment, homeDirectory: homeDirectory)]
    }

    /// The phone appliance's key.
    ///
    /// Separate from the app's because they are two agents with two grants —
    /// see `SageRitual.appAgentName` — and separate from the node operator's
    /// for the same reason everything else here is.
    ///
    /// This exists because the daemon had no pinned identity at all: it spawned
    /// `sage-gui mcp` with no environment, so the node fell through to its
    /// per-directory rule and minted a key from the launch working directory.
    /// The appliance had accumulated three of them —
    /// `~/.sage/agents/ableton-agent-*`, `sage-voice-bridge-agent-*`,
    /// `svbtest-agent-*` — one per place it had ever been started from, each
    /// with its own memories. The `cd` in the launch script was load-bearing and
    /// nothing said so; starting the daemon from anywhere else silently gave the
    /// owner an appliance that had forgotten everything.
    public static func applianceKeyURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/SAGE Voice Bridge", isDirectory: true)
            .appendingPathComponent("appliance-agent.key", isDirectory: false)
    }

    /// Environment for the daemon's `sage-gui mcp`.
    ///
    /// Migration matters more than the pin here. Pointing an existing appliance
    /// at a fresh path would orphan every memory it has ever stored, so the
    /// installer copies the key it was already deriving into this path. Same
    /// key bytes means the same agent ID means the same memories — the identity
    /// stops moving without ever having changed.
    public static func applianceEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String: String] {
        let operatorKey = nodeOperatorKeyURL(environment: environment, homeDirectory: homeDirectory)
            .standardizedFileURL.path
        for name in [environmentVariable, "SAGE_AGENT_KEY"] {
            guard let raw = environment[name], !raw.isEmpty else { continue }
            let expanded = NSString(string: raw).expandingTildeInPath
            guard URL(fileURLWithPath: expanded).standardizedFileURL.path != operatorKey else { continue }
            return [environmentVariable: expanded]
        }
        return [environmentVariable: applianceKeyURL(homeDirectory: homeDirectory).path]
    }
}
