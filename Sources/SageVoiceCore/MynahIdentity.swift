import CryptoKit
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

    /// The node's own directory, resolved the way the node resolves it —
    /// `SAGE_HOME` included, so a non-standard install cannot slip past the
    /// comparisons below or leave the key somewhere CEREBRUM is not looking.
    public static func sageHomeURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        environment["SAGE_HOME"].flatMap { value -> URL? in
            let expanded = NSString(string: value).expandingTildeInPath
            return expanded.isEmpty ? nil : URL(fileURLWithPath: expanded, isDirectory: true)
        } ?? homeDirectory.appendingPathComponent(".sage", isDirectory: true)
    }

    /// The node operator's key — the thing this type exists to never return.
    public static func nodeOperatorKeyURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        sageHomeURL(environment: environment, homeDirectory: homeDirectory)
            .appendingPathComponent("agent.key", isDirectory: false)
    }

    // MARK: - Deliberately absent: resolvedKeyPath() and childEnvironment()
    //
    // They returned `keyURL()` — `agent.key`, the app window's identity from
    // before "One appliance is one agent". Nothing registers that key any more,
    // so anything signing with it signs as an agent the node has never heard
    // of.
    //
    // **The node answers that emptily rather than refusing**, and that is the
    // whole reason it survived four times. An unknown agent is not an error to
    // a caller-filtered query — it is an agent with nothing, which is exactly
    // what a new install looks like. So every cheap check passes: the request
    // is signed, the node replies 200, the JSON parses, the array is empty, the
    // screen renders its empty state. Nothing anywhere throws.
    //
    // The general shape, which has now cost this codebase four surfaces here
    // and three more in the vendored/installed pair below: **two functions that
    // answer different questions, where the wrong answer is indistinguishable
    // from a true one, and where the name you reach for by instinct is the
    // wrong one.** `applianceEnvironment()` is the only correct way to build a
    // child's identity; see `SageNodeChoice.resolve` for the other pair.
    //
    // Four surfaces were caught by these two functions in a single session —
    // the Memories screen, the appliance row on the Agents screen, the
    // federation scan, and the agents connection. That is a trap, not four
    // mistakes, and the trap was the names:
    //
    //   * `childEnvironment()` is precisely what you reach for when wiring a
    //     child process. It is right by its name and wrong in fact.
    //   * It was literally `[environmentVariable: resolvedKeyPath(...)]`, so
    //     "fixing" a call from one to the other reads like a correction,
    //     compiles, and changes nothing. That move was made, with a comment
    //     claiming it pinned the appliance key, by someone who had diagnosed
    //     this exact trap an hour earlier.
    //
    // So they are gone rather than renamed. A correctly named function that
    // nobody calls is still something the next person can pick out of
    // autocomplete. `applianceEnvironment()` is the only way to build a child's
    // identity now, and it is what every call site already uses.
    //
    // The override-safety logic below was the good part and is kept — it now
    // guards `applianceEnvironment()`, which previously had a weaker check of
    // its own. See `isSafeToAdopt`.

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
    ///
    /// This used to guard only the deleted `resolvedKeyPath()`, while
    /// `applianceEnvironment()` — the function everything actually calls — did
    /// its own weaker check: a plain string comparison against the operator
    /// key's path, with no symlink resolution, no case folding, and no
    /// restriction to Mynah's own directory. So the careful version guarded the
    /// path nobody took. It guards the real one now.
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

        // Mynah's own directories, and only those. Two of them now that the key
        // lives in `~/.sage/agents/mynah/`: the current one and the Application
        // Support directory it moved out of, which still holds an upgrading
        // appliance's identity.
        //
        // The allowlist matters more than it used to. Mynah's key now sits
        // *inside* `~/.sage/agents/`, which is the directory full of other
        // agents' identities — so "is this under the agents directory" would
        // admit every one of them. Naming the two acceptable directories keeps
        // the refusal exactly as narrow as it was when Mynah's key lived
        // somewhere else entirely.
        let ourDirectories = [
            applianceKeyURL(environment: environment, homeDirectory: homeDirectory),
            legacyApplianceKeyURL(homeDirectory: homeDirectory)
        ].map { $0.deletingLastPathComponent().standardizedFileURL.path }

        let candidateDirectory = candidate.deletingLastPathComponent().path
        return ourDirectories.contains {
            candidateDirectory.compare($0, options: .caseInsensitive) == .orderedSame
        }
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

    /// Makes a spawned SAGE node use the local semantic model that Mynah has
    /// already pulled and probed. SAGE defaults to deterministic hash vectors;
    /// merely downloading `nomic-embed-text` would otherwise leave federation
    /// and recall working but silently non-semantic.
    public static func localSemanticEnvironment(
        identityEnvironment: [String: String]
    ) -> [String: String] {
        identityEnvironment.merging([
            "SAGE_EMBEDDING_PROVIDER": "ollama",
            "SAGE_EMBEDDING_BASE_URL": "http://127.0.0.1:11434",
            "SAGE_EMBEDDING_MODEL": LocalBrainModelCatalog.embeddingModel,
            "SAGE_EMBEDDING_DIMENSION": "\(LocalBrainModelCatalog.embeddingDimensions)"
        ]) { identity, _ in identity }
    }

    /// Mynah's directory inside `~/.sage/agents/`.
    ///
    /// A fixed name, and it is fixed for a safety reason rather than a tidiness
    /// one: every directory the node derives is `<base>-<provider>-<8 hex>`, so
    /// a name carrying no hash suffix is **unreachable by derivation**. No
    /// project, whatever it is called and wherever it is launched from, can ever
    /// be handed this directory and become Mynah.
    public static let applianceDirectoryName = "mynah"

    /// The appliance's key — the identity every part of this product signs as.
    ///
    /// Separate from the node operator's for the reason everything else here is:
    /// Mynah is an agent that can be granted and restricted, and the operator is
    /// neither.
    ///
    /// ## Why it lives in `~/.sage/agents/` and not in this app's own directory
    ///
    /// It used to live beside the owner's provider keys and notes, in
    /// `~/Library/Application Support/SAGE Voice Bridge/appliance-agent.key`, on
    /// the reasoning that the key belongs to this app rather than to the node.
    /// That reasoning was about ownership and it answered the wrong question.
    ///
    /// **CEREBRUM looks for agent keys in `~/.sage/agents/`.** A key held
    /// anywhere else is one the owner cannot see, approve, or grant a domain to
    /// through the interface built for exactly that — so the appliance shows up
    /// as an agent id with no key behind it, and the operator has nothing to act
    /// on. Ownership is not what discovery keys on; location is.
    ///
    /// Nothing about the previous reasoning becomes false: Mynah still owns this
    /// key, still mints it, still refuses to sign as anyone else. Storing it
    /// where the node's own tooling looks borrows no authority and forges none —
    /// the file is 32 bytes of Ed25519 seed either way, and standing still comes
    /// from the chain. It is the same key, in the place the owner's console can
    /// find it. Confirmed with the SAGE team, who are keeping node-side work
    /// separate from this migration.
    ///
    /// The old path is still read — see `legacyApplianceKeyURL` — because an
    /// upgrading appliance's identity is sitting in it, and pointing at a fresh
    /// path without adopting first is the data loss `migrateApplianceKeyIfNeeded`
    /// exists to prevent.
    public static func applianceKeyURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        sageHomeURL(environment: environment, homeDirectory: homeDirectory)
            .appendingPathComponent("agents", isDirectory: true)
            .appendingPathComponent(applianceDirectoryName, isDirectory: true)
            .appendingPathComponent("agent.key", isDirectory: false)
    }

    /// Where the appliance's key lived before it moved into `~/.sage/agents/`.
    ///
    /// Read, never written. Every installed appliance in the world has its
    /// identity here and nowhere else, so this is the first thing the migration
    /// looks at — ahead of the derived candidates, because it is the key the app
    /// has actually been signing with rather than one it might once have.
    ///
    /// The bytes are deliberately left in place after adoption rather than moved
    /// or deleted. They are the same key, so a stale copy cannot become a second
    /// identity, and a downgrade to an older build finds its identity exactly
    /// where it expects to.
    ///
    /// This exists because the daemon once had no pinned identity at all: it
    /// spawned `sage-gui mcp` with no environment, so the node fell through to
    /// its per-directory rule and minted a key from the launch working
    /// directory. The appliance accumulated three of them —
    /// `~/.sage/agents/ableton-agent-*`, `sage-voice-bridge-agent-*`,
    /// `svbtest-agent-*` — one per place it had ever been started from, each
    /// with its own memories. The `cd` in the launch script was load-bearing and
    /// nothing said so.
    public static func legacyApplianceKeyURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/SAGE Voice Bridge", isDirectory: true)
            .appendingPathComponent("appliance-agent.key", isDirectory: false)
    }

    // MARK: - Migration

    /// Reproduces the node's per-project key derivation.
    ///
    /// Ported from `cmd/sage-gui/mcp.go` — `providerProjectAgentDir` at :206 and
    /// `legacyProjectAgentPath` at :224 — and verified against the directories
    /// this appliance actually accumulated: `sha256("agent\0/Users/ableton")`
    /// gives `849d657e` and `sha256("agent\0/tmp")` gives `57aab6cb`, which are
    /// the two real names on disk.
    ///
    /// Computed rather than guessed on purpose. Scanning `~/.sage/agents/*` and
    /// taking whatever is there would happily adopt a Claude Code project agent
    /// that has nothing to do with this appliance.
    static func derivedKeyCandidates(
        sageHome: URL,
        workingDirectory: String,
        provider: String?
    ) -> [URL] {
        let absolute = URL(fileURLWithPath: workingDirectory).standardizedFileURL.path
        let base = sanitizedDirName(URL(fileURLWithPath: absolute).lastPathComponent)
        let agents = sageHome.appendingPathComponent("agents", isDirectory: true)

        // Empty SAGE_PROVIDER becomes "agent", matching mcp.go:212-214.
        let resolvedProvider = {
            let trimmed = (provider ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            return trimmed.isEmpty ? "agent" : trimmed
        }()

        func shortHash(_ input: String) -> String {
            SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8).description
        }

        var directories = ["\(base)-\(sanitizedDirName(resolvedProvider))-\(shortHash(resolvedProvider + "\u{0}" + absolute))"]

        // The pre-provider directory is reachable ONLY for claude-code and
        // claude-desktop (mcp.go:246-253); every other provider — including the
        // empty one the appliance runs with — goes straight to the
        // provider-specific path at :254.
        //
        // Offering it unconditionally was a severe bug, and a reachable one. On
        // the author's own machine the provider directory for cwd `/` does not
        // exist while the legacy one does, so a daemon launched by launchd or
        // Finder (cwd `/`) skipped the correct candidate and adopted
        // `~/.sage/agents/--8a5edab2/agent.key` — a live Claude Code agent
        // holding thousands of memories. Mynah would have become that agent,
        // inherited its domain grants, written voice turns into its corpus, and
        // kept `sage_forget` in its tool allowlist.
        //
        // The commit that introduced this claimed the computed approach avoided
        // exactly that, which is why the gate is mirrored from the node line for
        // line rather than approximated.
        let trimmedProvider = (provider ?? "").trimmingCharacters(in: .whitespaces)
        if trimmedProvider.caseInsensitiveCompare("claude-code") == .orderedSame
            || trimmedProvider.caseInsensitiveCompare("claude-desktop") == .orderedSame {
            directories.append("\(base)-\(shortHash(absolute))")
        }

        return directories.map {
            agents.appendingPathComponent($0, isDirectory: true)
                .appendingPathComponent("agent.key", isDirectory: false)
        }
    }

    /// `[^a-zA-Z0-9._-]` → `-`, matching `sanitizeDirName` at mcp.go:266.
    static func sanitizedDirName(_ name: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let mapped = String(name.trimmingCharacters(in: .whitespaces).unicodeScalars.map {
            allowed.contains($0) ? Character($0) : "-"
        })
        return (mapped.isEmpty || mapped == "." || mapped == "..") ? "unknown" : mapped
    }

    /// Adopts the identity this appliance was already using, once.
    ///
    /// Without it the pin is a data-loss bug wearing a fix's clothing: pointing
    /// an existing appliance at a fresh path means the node mints a new key,
    /// which is a new agent id, which is an appliance that has forgotten
    /// everything it ever stored — silently, on upgrade, for every install that
    /// is not the one machine where this was done by hand.
    ///
    /// Copying the bytes is what makes it a migration rather than a new
    /// identity: same key, same agent id, same memories, nothing re-registered
    /// and nothing to reconcile on the node.
    ///
    /// Runs only when the pinned key is absent, so it is a no-op on every boot
    /// after the first and on a genuinely fresh install.
    ///
    /// ## Why it looks in two directories, not one
    ///
    /// **This missed on the author's machine and minted a stranger.** The pinned
    /// file was created 2026-07-28 holding a brand-new key, `74140c2d…`, while
    /// the appliance's real identity — `1ab7aa10…`, the node's *active*
    /// `agent/sage-voice-bridge` — sat unread in
    /// `~/.sage/agents/sage-voice-bridge-agent-ad07f79c`. Every SAGE call for
    /// three days auto-registered the stranger, got `pending_review`, and was
    /// refused with "active ordinary agent identity required".
    ///
    /// The cause is that **the cwd at migration time is never the cwd that
    /// minted the key.** The key is minted by whichever process first ran
    /// `sage-gui mcp`; the migration runs later, in a different process, under a
    /// launcher that sets its own directory. Concretely:
    ///
    ///   * the daemon runs under this repo's own plist, which sets
    ///     `WorkingDirectory` to `$HOME` (`scripts/install-daemon.sh:84`,
    ///     `SignalBackgroundServices.swift:480`);
    ///   * the app is launched from Finder, whose cwd is `/`;
    ///   * the key on the author's machine was minted from the repository
    ///     directory, by a launch script that no longer exists.
    ///
    /// So passing only `FileManager.default.currentDirectoryPath` asks about a
    /// directory the key was, by construction, unlikely to come from.
    ///
    /// `$HOME` is added because it is a **fact this repository writes**, not a
    /// guess: it is the `WorkingDirectory` in the plists above, so it is exactly
    /// where a customer's pre-pin daemon minted its key. Without it the general
    /// upgrade path loses memories too, and worse, silently races: the app (cwd
    /// `/`) and the daemon (cwd `$HOME`) derive *different* candidates, so
    /// whichever boots first decides the appliance's identity forever. App-first
    /// means a fresh mint, and the daemon then finds the pinned file already
    /// present and adopts the stranger.
    ///
    /// It is still not exhaustive and cannot be: an arbitrary historical launch
    /// directory is unrecoverable, and scanning `~/.sage/agents/*` for something
    /// plausible would adopt another agent's identity — the failure this whole
    /// type exists to prevent. When nothing matches, that is said out loud
    /// rather than passed over, because silence is what made the original cost
    /// three days and a round trip with the SAGE team.
    @discardableResult
    public static func migrateApplianceKeyIfNeeded(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        workingDirectory: String = FileManager.default.currentDirectoryPath,
        fileManager: FileManager = .default,
        log: (String) -> Void = { _ in }
    ) -> URL? {
        let destination = applianceKeyURL(environment: environment, homeDirectory: homeDirectory)
        guard !fileManager.fileExists(atPath: destination.path) else { return nil }

        let sageHome = sageHomeURL(environment: environment, homeDirectory: homeDirectory)

        // Application Support first, and it is not one candidate among several.
        // Every appliance installed before the key moved into `~/.sage/agents/`
        // has its identity in exactly this file — no derivation, no guessing,
        // no dependence on where anything was launched from. The derived
        // candidates below only matter for an appliance old enough to predate
        // the pin as well, which is a smaller and shrinking set.
        var candidates: [URL] = [legacyApplianceKeyURL(homeDirectory: homeDirectory)]

        // Then the live cwd — right when the migrating process happens to be the
        // one that minted the key — and then the launcher's directory.
        for directory in [workingDirectory, homeDirectory.path] {
            for candidate in derivedKeyCandidates(
                sageHome: sageHome,
                workingDirectory: directory,
                provider: environment["SAGE_PROVIDER"]
            ) where !candidates.contains(candidate) {
                candidates.append(candidate)
            }
        }

        guard let source = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) else {
            // The node is about to mint a new key at the pinned path, which is a
            // new agent id, which is an appliance with no memories and no grant
            // that every SAGE call will be refused for until an operator
            // approves it. That is worth a line even on a genuinely fresh
            // install, where it is the correct and expected outcome.
            log("""
            [identity] no existing appliance key found; SAGE will mint a new one at \
            \(destination.path). If this appliance had memories, they belong to a key \
            under \(sageHome.appendingPathComponent("agents").path) that this machine's \
            launch directories do not derive — searched \
            \(candidates.map(\.path).joined(separator: ", "))
            """)
            return nil
        }

        do {
            let key = try Data(contentsOf: source)
            try OwnerOnlyFileSecurity.write(key, to: destination, fileManager: fileManager)
            log("[identity] adopted the appliance's existing key from \(source.path)")
            return destination
        } catch {
            // Better a new identity than no appliance. The owner loses recall,
            // which is visible and recoverable; a daemon that refuses to boot
            // over a key copy is not.
            log("[identity] could not adopt \(source.path): \(error)")
            return nil
        }
    }

    /// Creates Mynah's key, if it does not have one yet.
    ///
    /// ## "Mint" means a keypair, and never authority
    ///
    /// Thirty-two random bytes — the same thing `sage-gui mcp` does for itself
    /// at `mcp.go:169-174`, moved earlier and nothing more. **It grants nothing.**
    /// A keypair with no registration behind it is an agent the chain has never
    /// heard of, which is why the failure this fixes looked the way it did.
    ///
    /// Standing comes from the chain, and Mynah cannot award itself any:
    ///
    ///   * **Root is not reachable from here.** It is the node operator key,
    ///     `~/.sage/agent.key`, held by the CEREBRUM attached to SAGE at install.
    ///     `isSafeToAdopt` refuses any override naming it, genesis refuses to let
    ///     Root and companion be the same file, and `nodeOperatorKeyURL` exists
    ///     precisely so this type can recognise and reject it.
    ///   * **Even companion standing is capped.** The most this key can be given
    ///     is Member/Companion at clearance 2, and SAGE fixes the profile and
    ///     capability mask regardless of what is passed — see
    ///     `SageNodeSupervisor.vendoredBootstrapEnvironment`.
    ///   * **And only when Mynah installed SAGE.** `SageNodeChoice.resolve`
    ///     prefers an installed bundle, so `mayBeManagedByMynah` — and with it
    ///     the bootstrap that writes genesis — is false whenever the owner
    ///     already has a SAGE. Against an existing node this key is registered
    ///     like any other agent's and waits in `pending_review` for the owner to
    ///     approve it in CEREBRUM, which is the design and not a fault.
    ///
    /// ## Why the appliance mints its own instead of letting the node do it
    ///
    /// It used to say, a few lines up, that "the node creates the parent
    /// directory and generates the key on first use, so nothing here has to
    /// mint anything". True, and it put the key on disk at the **wrong moment**.
    ///
    /// A fresh install runs in this order:
    ///
    ///   1. `SageNodeSupervisor.startIfNeeded` starts the vendored node with
    ///      `SAGE_VENDORED_AGENT_KEY_FILE` pointing at `applianceKeyURL()`;
    ///   2. the node writes genesis, which is where an app-v23 companion agent
    ///      is granted Member standing and its home domain;
    ///   3. much later, the first `sage-gui mcp` call lazily generates the key.
    ///
    /// So the file named in step 1 does not exist until step 3. Genesis is
    /// handed a path to nothing, and the identity Mynah eventually signs with is
    /// one the chain has never seen — it self-registers, lands in
    /// `pending_review`, and every call is refused with "active ordinary agent
    /// identity required".
    ///
    /// **And that is not repairable afterwards.** `vendoredBootstrapEnvironment`
    /// says why: SAGE declines to retrofit companion standing onto an existing
    /// chain by design. Miss the genesis window and the only remedy is an
    /// administrator in CEREBRUM, which a new owner does not have and cannot be
    /// asked to find.
    ///
    /// Minting here closes the window: after this returns, the key exists, so
    /// step 2 has a real public key to embed and Mynah is an active Member from
    /// the node's first block.
    ///
    /// Ordering against the migration matters and is not arbitrary. Adoption
    /// runs first and always: an upgrading appliance must keep the identity that
    /// holds its memories, and minting over it would be the data loss the
    /// migration exists to prevent. This only ever fires when there was nothing
    /// to adopt, which is what a genuinely new install looks like.
    ///
    /// - Returns: the key's path when this call created it, `nil` when one was
    ///   already there.
    @discardableResult
    public static func mintApplianceKeyIfNeeded(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        log: (String) -> Void = { _ in }
    ) -> URL? {
        let destination = applianceKeyURL(environment: environment, homeDirectory: homeDirectory)
        guard !fileManager.fileExists(atPath: destination.path) else { return nil }

        // 32 raw bytes — the Ed25519 seed, which is the shape SAGE writes for a
        // per-project key and the shape `SageAgentIdentity` derives an agent id
        // from. Not the 64-byte seed+public form: that is what `~/.sage/agent.key`
        // uses, and both are accepted, but writing the same shape the node writes
        // keeps one fewer difference between a minted key and an adopted one.
        let seed = Curve25519.Signing.PrivateKey().rawRepresentation
        do {
            try OwnerOnlyFileSecurity.write(seed, to: destination, fileManager: fileManager)
        } catch {
            // Non-fatal, and deliberately so. The node still mints lazily on
            // first use, which is the old behaviour — a worse identity, not no
            // appliance. Refusing to boot over a key file would strand the owner
            // completely.
            log("[identity] could not mint an appliance key at \(destination.path): \(error)")
            return nil
        }
        log("[identity] minted this appliance's key: \(SageAgentIdentity.agentID(ofKeyBytes: seed) ?? "unreadable")")
        return destination
    }

    /// Copies the current key aside before anything is allowed to touch it.
    ///
    /// **An install must never be the reason an appliance forgets.** Upgrading
    /// is the moment the key is most at risk: the installer replaces the app,
    /// a bootstrap may write genesis, and any of it could land on
    /// `appliance-agent.key`. Losing those 32 bytes is not an inconvenience —
    /// it is a different agent id, which is every memory the owner ever gave
    /// Mynah, unreachable, with no way back.
    ///
    /// Named by agent id rather than by a timestamp, which makes it idempotent:
    /// backing the same key up on every boot writes the same file instead of
    /// growing a pile of dated copies nobody can tell apart. When the identity
    /// really does change, the old one is still sitting there under its own
    /// name, which is exactly when somebody needs to find it.
    ///
    /// No clock is involved for the same reason — a name that depends on when
    /// it was written cannot be recognised later as "the key that was here
    /// before".
    ///
    /// Backups stay in this app's own directory rather than following the key
    /// into `~/.sage/agents/`. A retired identity is Mynah's business and not
    /// the node's, and the one thing the agents directory should contain for
    /// this appliance is the single key it currently signs with.
    @discardableResult
    public static func backUpApplianceKeyIfPresent(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        log: (String) -> Void = { _ in }
    ) -> URL? {
        // Whichever key is live. During the move into `~/.sage/agents/` the
        // appliance's only identity is still the Application Support one, and
        // that is precisely the boot where a lost key would cost the most.
        let candidates = [
            applianceKeyURL(environment: environment, homeDirectory: homeDirectory),
            legacyApplianceKeyURL(homeDirectory: homeDirectory)
        ]
        guard let key = candidates.lazy.compactMap({ try? Data(contentsOf: $0) }).first else { return nil }

        let stamp = SageAgentIdentity.agentID(ofKeyBytes: key).map { String($0.prefix(8)) } ?? "unreadable"
        let destination = legacyApplianceKeyURL(homeDirectory: homeDirectory)
            .deletingLastPathComponent()
            .appendingPathComponent("retired", isDirectory: true)
            .appendingPathComponent("appliance-agent.\(stamp).key", isDirectory: false)
        guard !fileManager.fileExists(atPath: destination.path) else { return destination }

        do {
            try OwnerOnlyFileSecurity.write(key, to: destination, fileManager: fileManager)
            log("[identity] backed up this appliance's key as \(destination.lastPathComponent)")
            return destination
        } catch {
            // Said, not thrown. A failed backup is a risk worth reporting and a
            // terrible reason to stop an owner installing an update.
            log("[identity] could not back up this appliance's key to \(destination.path): \(error)")
            return nil
        }
    }

    /// Key check first, then install. The whole order, in one place.
    ///
    /// Every caller that is about to do something consequential — spawn an MCP
    /// server, bootstrap a node, start the daemon — needs the same three things
    /// to have happened, in the same order, and getting the order wrong fails
    /// silently in a different way each time:
    ///
    ///   1. **Back up** whatever key is already there. Nothing below can run
    ///      until the existing identity is safe, because steps 2 and 3 are the
    ///      ones that would replace it.
    ///   2. **Adopt** the identity an upgrading appliance was already using, so
    ///      it keeps its memories. Runs only when there is no key yet.
    ///   3. **Mint** one, so a genuinely new install has a real public key
    ///      *before* genesis is written rather than hours after it.
    ///
    /// Adoption before minting is the part that must not be reordered: minting
    /// first would hand every upgrading appliance a brand-new identity and
    /// orphan everything it had stored, which is the exact data loss the
    /// migration exists to prevent.
    ///
    /// - Returns: the path to Mynah's key, which after this call exists unless
    ///   the disk refused every attempt.
    @discardableResult
    public static func prepareApplianceKey(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        workingDirectory: String = FileManager.default.currentDirectoryPath,
        fileManager: FileManager = .default,
        log: @escaping (String) -> Void = { _ in }
    ) -> URL {
        backUpApplianceKeyIfPresent(
            environment: environment,
            homeDirectory: homeDirectory,
            fileManager: fileManager,
            log: log
        )
        migrateApplianceKeyIfNeeded(
            environment: environment,
            homeDirectory: homeDirectory,
            workingDirectory: workingDirectory,
            fileManager: fileManager,
            log: log
        )
        mintApplianceKeyIfNeeded(
            environment: environment,
            homeDirectory: homeDirectory,
            fileManager: fileManager,
            log: log
        )
        return applianceKeyURL(environment: environment, homeDirectory: homeDirectory)
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
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        log: @escaping (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    ) -> [String: String] {
        for name in [environmentVariable, "SAGE_AGENT_KEY"] {
            guard let raw = environment[name], !raw.isEmpty else { continue }
            let expanded = NSString(string: raw).expandingTildeInPath
            // Was a bare string comparison against the operator key's path,
            // which a symlink or a differently-cased `~/.SAGE/agent.key` walked
            // straight past on a case-insensitive volume — and which permitted
            // an override naming any *other* agent's key outright.
            guard isSafeToAdopt(expanded, environment: environment, homeDirectory: homeDirectory) else {
                // Refused rather than obeyed, and said out loud. A silent
                // refusal means the appliance signs as a different agent than
                // the environment asked for, and nobody finds out until the
                // memories look wrong.
                log("[identity] ignoring \(name)=\(expanded): Mynah signs only as itself")
                continue
            }
            return [environmentVariable: expanded] .merging(wakeChannelOff) { current, _ in current }
        }
        // Back up, adopt, mint — in that order, and never just the middle one.
        // This used to call `migrateApplianceKeyIfNeeded` alone, so on a fresh
        // install it returned a path to a file that did not exist and left the
        // node to fill it in whenever it got around to it.
        return [environmentVariable: prepareApplianceKey(
            environment: environment,
            homeDirectory: homeDirectory,
            log: log
        ).path].merging(wakeChannelOff) { current, _ in current }
    }

    /// Keeps the node's own MCP wake adapter out of Mynah's wake lease.
    ///
    /// SAGE 11.18.13 wires an opt-in "Claude channel" in `sage-gui mcp` to the
    /// same signed `GET /v1/messages/wake` route `MessageWakeBus` holds open. It
    /// is default-off and gated on `SAGE_CLAUDE_CHANNEL`, and Mynah does not set
    /// it — but `MCPClient` merges these over the *parent* environment so the
    /// child inherits whatever the daemon was launched with, and an operator who
    /// armed it in their own shell would arm it here too.
    ///
    /// That is not a harmless duplicate. The node grants **one wake lease per
    /// agent**: two consumers signing as `74140c2d` means whichever loses is
    /// refused with a 409 for up to five minutes at a time, and the one that
    /// loses is as likely to be the daemon — the only one of the two that can
    /// actually tell the owner anything.
    ///
    /// Set explicitly rather than removed, because the merge is over an
    /// inherited environment and deleting a key from this dictionary would not
    /// delete it from the child's.
    static let wakeChannelOff = ["SAGE_CLAUDE_CHANNEL": "0"]
}
