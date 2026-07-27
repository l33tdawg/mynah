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
    }

    /// Name the phone appliance registers under.
    public static let applianceAgentName = "SAGE Voice Bridge"

    /// Name the Mac app registers under.
    ///
    /// Deliberately different from the appliance's. They are two agents with two
    /// keys, and the whole point of the operator granting access per agent in
    /// CEREBRUM is that the operator can tell them apart in the list. Two rows
    /// both reading "SAGE Voice Bridge" makes "give this one read access" a
    /// coin flip.
    public static let appAgentName = "Mynah"

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
    public init(
        tools: ToolProviding,
        agentName: String = SageRitual.applianceAgentName,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.tools = tools
        self.agentName = agentName
        self.log = log
    }

    private let agentName: String

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
        } catch {
            // Non-fatal: memory still works unregistered, and an appliance that
            // refuses to answer anything because it could not claim an identity
            // is strictly worse than one that cannot read its backlog.
            log("[sage] registration failed, task tools may return 401: \(error)")
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
