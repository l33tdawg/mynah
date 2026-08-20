import Foundation

/// Adds the owner's phrasing to SAGE's tool descriptions, for the two tools a
/// small model measurably confused.
///
/// ## The defect, measured rather than suspected
///
/// SAGE writes its tool descriptions for a capable agent, and writes them
/// precisely. `sage_timeline` is *"Get memories in a time range, grouped by time
/// buckets. Use this to see memory activity over time."* `sage_backlog` is
/// *"View open tasks explicitly assigned to this agent ID… see what's been
/// discussed but not yet done."*
///
/// Asked **"what have I been working on this week?"** a 4B routed to
/// `sage_backlog` every time. It is not being stupid: the owner's words are
/// about work, `sage_backlog` says "discussed but not yet done", and
/// `sage_timeline` never says "what you did" — it says "memory activity".
///
/// `scripts/measure-tool-routing.py` on 20 Aug 2026, qwen3.5:4b, with the real
/// 8,300-character voice prompt: the shipped catalogue scored 9/12, and the same
/// three utterances missed at every composed catalogue size from 20 to 27. **So
/// this is not a catalogue-size problem and curation cannot reach it** — the
/// miss is identical at fifteen SAGE tools and at twenty-two. Appending the two
/// sentences below took it to 10/12 at every one of those sizes.
///
/// ## Why appended and not replaced
///
/// SAGE's prose is more precise than ours and is maintained by the people who
/// own the tools; `sage_directory`'s description carries federation semantics
/// this repository has no business restating. Replacing it would trade a
/// routing win for a correctness loss on the capable models that read it
/// properly. These are additions, and a test asserts they are.
///
/// ## Why two hints and not four
///
/// Two more were written, measured, and deleted, and the reason is recorded in
/// `Tests/Fixtures/spoken-tool-hints.json` so nobody spends an afternoon
/// rediscovering it:
///
/// - **`sage_forget` is not reachable in one call.** Its schema *requires*
///   `memory_id`, and "forget what I told you about the old relay address"
///   carries no id. Reaching for `sage_recall` first is the only route to one,
///   so the model is right and the expectation was wrong. What that case should
///   guard is that the TURN ends with the thing forgotten, which is a tool-loop
///   question and is not answered here.
/// - **`sage_directory` does not answer the question asked.** It takes `scope`
///   and `peer_cursor` and lists recipients this caller may address; "which
///   agent is handling the Chrome work" is about who is doing what, which no
///   tool in the catalogue reports.
///
/// Both had trigger wording appended and both measured exactly zero. Wording
/// that reads plausible and moves no number is worse than nothing: it is a
/// claim the next reader has to disprove.
///
/// ## Applied to every tier, deliberately
///
/// A hosted brain does not need these and is not harmed by them — the sentences
/// are true statements about which tool answers which question, and they cost
/// about 500 bytes of schema against a context measured in hundreds of
/// thousands. Making them local-only would add a second tier-dependent
/// behaviour to reason about in exchange for nothing measurable.
public struct SpokenToolHints: ToolProviding {

    /// The wording, and it must stay identical to
    /// `Tests/Fixtures/spoken-tool-hints.json` — `SpokenToolHintsTests` fails if
    /// it does not.
    ///
    /// Two copies exist because the harness is Python and the appliance is
    /// Swift, and the harness has to measure the sentences the appliance
    /// actually ships. Two copies under a comment claiming they agree is
    /// precisely how that same script's tool list silently stopped describing
    /// this appliance for months, so this pair is pinned by an assertion
    /// instead.
    public static let hints: [String: String] = [
        "sage_timeline": """
        Use this when the owner asks what they HAVE BEEN DOING over a stretch of \
        time: "what have I been working on this week", "what did I get done \
        yesterday". It answers about a period that has passed. It is not \
        sage_backlog, which answers about work still outstanding.
        """,
        "sage_backlog": """
        Answers what is STILL OUTSTANDING. If the owner is asking what they have \
        already been doing over a period, that is sage_timeline.
        """
    ]

    private let wrapped: ToolProviding

    public init(wrapping wrapped: ToolProviding) {
        self.wrapped = wrapped
    }

    public func listTools() async throws -> [MCPTool] {
        try await wrapped.listTools().map { tool in
            guard let hint = Self.hints[tool.name] else { return tool }
            var hinted = tool
            // Appended with a single space, never replacing, and never touching
            // `inputSchema`. This changes what the model is TOLD about a tool
            // and nothing about how it is called.
            hinted.description = tool.description.trimmingCharacters(
                in: .whitespacesAndNewlines
            ) + " " + hint.trimmingCharacters(in: .whitespacesAndNewlines)
            return hinted
        }
    }

    /// Untouched. A description is for choosing a tool; this decorator has no
    /// opinion about running one.
    public func call(name: String, arguments: [String: JSONValue]) async throws -> String {
        try await wrapped.call(name: name, arguments: arguments)
    }
}
