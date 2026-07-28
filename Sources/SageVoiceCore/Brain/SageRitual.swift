import Foundation

/// SAGE's boot and per-turn discipline, performed by the appliance itself.
///
/// SAGE's operating contract is three calls: `sage_inception` before anything
/// else in a session, `sage_turn` every turn, and `sage_reflect` after
/// significant work. The appliance was doing none of them, and that was not a
/// missed nicety — it was two live faults.
///
/// **The appliance had amnesia.** Conversation history lives in memory keyed by
/// thread, so every restart — crash, reboot, deploy — silently dropped it. The
/// owner saw this directly: after a restart, "done?" got an answer about their
/// backlog, because the question it referred to no longer existed anywhere. The
/// layer designed to survive exactly this was installed, running, and unused.
///
/// **The appliance was about to be blocked.** SAGE enforces turn discipline
/// server-side: non-SAGE tool calls are refused after 7 of them without a
/// `sage_turn`, or after 5 minutes once 2 have accumulated. `web_search` is a
/// non-SAGE call, so the more the owner used the feature, the sooner their
/// agent's tools would start failing — and the symptom would have surfaced as
/// "web search broke", days from the cause.
///
/// These calls are made by the daemon, not the model. The model is told never
/// to call bootstrap tools, a 4B model would forget three turns in, and this
/// discipline must not compete with the owner's request for the loop's five
/// iterations. It is the appliance's own housekeeping, so the appliance does it.
public actor SageRitual {

    /// SAGE's own tool names. Not in the voice allowlist on purpose: the model
    /// must never reach these, because *it* calling them is the failure mode
    /// this type exists to replace.
    public enum Tool {
        public static let inception = "sage_inception"
        public static let turn = "sage_turn"
        public static let reflect = "sage_reflect"
        public static let register = "sage_register"
        public static let rename = "sage_rename"
    }

    /// What the phone appliance registers as.
    ///
    /// Unchanged, and it must stay unchanged: at registration the node copies
    /// this into `RegisteredName`, which is immutable forever
    /// (`internal/abci/app.go:6935`). Every appliance already on a node carries
    /// it, and `sage_find_agent` matches against it — so renaming this constant
    /// would not rename anything, it would make the next fresh install
    /// unreachable by the name the existing ones answer to.
    public static let applianceAgentName = "SAGE Voice Bridge"

    /// Deliberately absent: a separate name for the Mac app.
    ///
    /// There was one, and it registered a second agent. The window and the
    /// daemon are one appliance — they answer the same owner, from the same
    /// Mac, about the same things — but they signed with different keys and so
    /// became "MYNAH (Mac App)" and "MYNAH (SAGE Voice Bridge Agent)" on the
    /// node, each holding memories the other could not see, each needing its own
    /// grant from the operator.
    ///
    /// The argument for the split was that "Mynah" is what a person says out
    /// loud. That is a good argument for what the ONE agent should be called,
    /// not for having two.

    /// What CEREBRUM shows for the appliance.
    ///
    /// Changed from "MYNAH (SAGE Voice Bridge Agent)", which read like a
    /// component in a system diagram rather than the name of the thing the
    /// owner installed. The registered name above is deliberately NOT changed
    /// with it — it is immutable on the node, every appliance already carries
    /// it, and renaming the constant would only make the next fresh install
    /// unreachable by the name the existing ones answer to.
    ///
    /// The operator grants domain access per agent, so the row has to say which
    /// agent it is. `Name` is mutable (`sage_rename` → AgentUpdate) while
    /// `RegisteredName` is not, and `sage_find_agent` matches both — so the
    /// descriptive name here and the spoken name above are two views of one
    /// agent rather than a trade-off.
    public static let applianceDisplayName = "Mynah - Sage Voice Bridge"


    /// Back-compatible alias. New code should name which one it means.
    public static let agentName = SageRitual.applianceAgentName

    /// How much of `sage_inception`'s reply to carry into the system prompt.
    ///
    /// Inception returns boot instructions plus recalled memories and can run to
    /// several KB. That text joins the ~3,000-token system prompt and tool
    /// catalogue in front of *every* request for the life of the process, so it
    /// is the most expensive string in the system — and this appliance has
    /// already been over the context ceiling once.
    public static let maximumBootContextCharacters = 1200

    /// Turns between `sage_reflect` calls.
    ///
    /// Reflection is for significant work, not every "what's the weather". Too
    /// often and the ledger fills with noise that dilutes real recall.
    public static let reflectEveryTurns = 10

    private let tools: ToolProviding
    private let log: @Sendable (String) -> Void

    private var turnsSinceReflect = 0
    private var turnCount = 0
    /// What `sage_inception` returned, trimmed. Nil until boot, and nil forever
    /// if boot failed — the appliance still works, it just starts cold.
    public private(set) var bootContext: String?

    /// - Parameter agentName: what this process registers as. Defaults to the
    ///   appliance so existing call sites keep their identity.
    /// - Parameters:
    ///   - agentName: the immutable name to register under.
    ///   - displayName: the mutable name CEREBRUM shows, or `nil` to leave it
    ///     alone. Applied after registration via `sage_rename`.
    ///   - displayName: the mutable name CEREBRUM shows, or `nil` to leave it
    ///     alone. Defaults to `nil`: renaming is a consensus write, so it
    ///     happens only where a call site has asked for it by name.
    ///   - displayNameMarker: where the applied name is recorded, so the rename
    ///     happens once rather than on every boot.
    public init(
        tools: ToolProviding,
        agentName: String = SageRitual.applianceAgentName,
        displayName: String? = nil,
        displayNameMarker: URL? = SageRitual.defaultDisplayNameMarker(),
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.tools = tools
        self.agentName = agentName
        self.displayName = displayName
        self.displayNameMarker = displayNameMarker
        self.log = log
    }

    public static func defaultDisplayNameMarker(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/SAGE Voice Bridge", isDirectory: true)
            .appendingPathComponent("display-name", isDirectory: false)
    }

    private let agentName: String
    private let displayName: String?
    private let displayNameMarker: URL?

    // MARK: - Boot

    /// Runs `sage_inception` and keeps its reply as session context.
    ///
    /// Must complete *before* the prompt-cache warm-up. The warm-up's whole
    /// value is that the cached prefix matches the real requests byte for byte,
    /// and this changes the prefix — warming first would throw away the 5×
    /// prefill saving on the owner's first sentence.
    @discardableResult
    public func boot() async -> String? {
        await register()
        do {
            let reply = try await tools.call(name: Tool.inception, arguments: [:])
            let trimmed = Self.condense(reply, to: Self.maximumBootContextCharacters)
            bootContext = trimmed.isEmpty ? nil : trimmed
            log("[sage] inception ok, \(trimmed.count) chars of session context")
            return bootContext
        } catch {
            // Non-fatal by design. An appliance that refuses to answer because
            // it could not read its own history is worse than one that starts
            // cold — the owner is on a phone and cannot fix a SAGE node.
            log("[sage] inception failed, starting without prior context: \(error)")
            return nil
        }
    }

    /// Claims an on-chain identity for the appliance.
    ///
    /// Not cosmetic. SAGE gates its task surface on identity — `sage_backlog`
    /// answers "only to signed agents or an authenticated CEREBRUM session"
    /// (`web/handler.go:2046`), so an unregistered appliance gets HTTP 401 on
    /// every task question while memory recall works fine. The owner saw this
    /// as the agent insisting it could not check its backlog, and reasonably
    /// read it as a missing tool — but the tool was there and the identity
    /// behind it was not.
    ///
    /// Idempotent server-side, so this runs every boot and returns the existing
    /// record when there is one. Registration is a property of the appliance,
    /// not a thing the owner should ever have to ask for by voice, which is why
    /// it happens here rather than in the model's catalogue.
    private func register() async {
        do {
            _ = try await tools.call(
                name: Tool.register,
                arguments: ["name": .string(agentName)]
            )
            log("[sage] registered as \(agentName)")
            await adoptDisplayName()
        } catch {
            // Non-fatal: memory still works unregistered, and an appliance that
            // refuses to answer anything because it could not claim an identity
            // is strictly worse than one that cannot read its backlog.
            log("[sage] registration failed, task tools may return 401: \(error)")
        }
    }

    /// Sets the name CEREBRUM shows, if it is not already set.
    ///
    /// Registration cannot do this. `processAgentRegister` is idempotent and
    /// copies `Name` straight off the existing record
    /// (`internal/abci/app.go:6876`), so re-registering under a new name renames
    /// nothing and silently succeeds — which is why the appliance kept showing
    /// its original name no matter what was passed. Renaming is a separate
    /// self-only AgentUpdate transaction.
    ///
    /// Guarded on the current name because that transaction goes through
    /// consensus. An unguarded rename on every boot would put a write on the
    /// chain each time the owner restarts the appliance, to change nothing.
    private func adoptDisplayName() async {
        guard let desired = displayName, let marker = displayNameMarker else { return }
        // Once, ever. Recorded locally rather than read back from the node
        // because no MCP tool returns the agent's current display name —
        // `sage_status` describes the node, not the caller — so a read-back
        // guard would never match and this would put a consensus write on the
        // chain every time the owner restarted the appliance, to change nothing.
        //
        // The happier consequence: if the operator renames this agent in
        // CEREBRUM, their choice stands. The app names itself once and then
        // stops having an opinion.
        guard (try? String(contentsOf: marker, encoding: .utf8)) != desired else { return }
        do {
            _ = try await tools.call(name: Tool.rename, arguments: ["name": .string(desired)])
            try? OwnerOnlyFileSecurity.prepareDirectory(marker.deletingLastPathComponent())
            try? Data(desired.utf8).write(to: marker, options: .atomic)
            log("[sage] display name set to \(desired)")
        } catch {
            // Cosmetic. The agent works under whatever name it has, and failing
            // a boot because a label would not update would be absurd.
            log("[sage] could not set display name: \(error)")
        }
    }

    /// The session context folded into a system prompt.
    public func systemPrompt(base: String) -> String {
        guard let bootContext else { return base }
        return """
        \(base)

        WHAT YOU WERE DOING BEFORE
        This is your own memory from previous sessions, recalled at start-up. \
        Use it to pick up where you left off. Do not read it aloud unless asked.
        \(bootContext)
        """
    }

    // MARK: - Per turn

    /// Records the turn and recalls anything relevant to it.
    ///
    /// Called after the reply is sent, not before: the owner waits ~40s for a
    /// turn already, and this is housekeeping they should never pay latency for.
    /// The recall half of `sage_turn` therefore lands in SAGE for *next* time
    /// rather than this time, which is the right trade for an appliance whose
    /// dominant cost is the model.
    public func recordTurn(transcript: String, reply: String, usedTools: [String]) async {
        turnCount += 1
        turnsSinceReflect += 1

        let topic = Self.topic(from: transcript)
        let observation = Self.observation(transcript: transcript, reply: reply, usedTools: usedTools)

        do {
            _ = try await tools.call(
                name: Tool.turn,
                arguments: [
                    "topic": .string(topic),
                    "observation": .string(observation),
                    // A dedicated domain, so the appliance's episodic chatter
                    // does not dilute recall in the domains real work uses.
                    "domain": .string("voice-appliance")
                ]
            )
        } catch {
            log("[sage] turn failed: \(error)")
        }

        if turnsSinceReflect >= Self.reflectEveryTurns {
            turnsSinceReflect = 0
            await reflect()
        }
    }

    private func reflect() async {
        do {
            _ = try await tools.call(
                name: Tool.reflect,
                arguments: [
                    "task_summary": .string(
                        "Voice appliance handled \(turnCount) spoken turns for the owner over Signal."
                    ),
                    "domain": .string("voice-appliance")
                ]
            )
            log("[sage] reflected after \(turnCount) turns")
        } catch {
            log("[sage] reflect failed: \(error)")
        }
    }

    // MARK: - Shaping

    /// A short topic string for contextual recall.
    ///
    /// Derived rather than asked for. Asking the model would cost another turn
    /// — 20+ seconds on this hardware — to produce a phrase used only as a
    /// recall key, where the first few words of what the owner actually said
    /// are already a good one.
    static func topic(from transcript: String) -> String {
        let cleaned = transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        guard !cleaned.isEmpty else { return "voice turn" }
        let words = cleaned.split(separator: " ").prefix(12)
        return words.joined(separator: " ")
    }

    /// SAGE silently drops observations under 30 characters as low-value, so
    /// this always carries both sides of the exchange.
    static func observation(transcript: String, reply: String, usedTools: [String]) -> String {
        let asked = condense(transcript, to: 300)
        let answered = condense(reply, to: 400)
        let via = usedTools.isEmpty ? "no tools" : usedTools.joined(separator: ", ")
        return "Owner asked over Signal: \(asked) — appliance answered using \(via): \(answered)"
    }

    /// Collapses whitespace and truncates at a word boundary.
    static func condense(_ text: String, to limit: Int) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > limit else { return collapsed }
        let clipped = collapsed.prefix(limit)
        guard let lastSpace = clipped.lastIndex(of: " ") else { return String(clipped) + "…" }
        return String(clipped[..<lastSpace]) + "…"
    }
}
