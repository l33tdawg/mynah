import Foundation

/// Keeps `sage_timeline` inside the range the node will actually answer.
///
/// **The node advertises an example it refuses.** `sage_timeline`'s own schema
/// offers `from: 2024-01-01T00:00:00Z` and `to: 2024-12-31T23:59:59Z` — a full
/// year — while an app-v23 node caps a timeline at 31 days per request and
/// answers anything wider with:
///
///     Timeline range too large: App-v23 governed timelines are limited to
///     31 days per request; choose a narrower range.
///
/// So a model that copies the shape it was shown is refused every time, and
/// there is nothing in the tool description that would tell it otherwise.
///
/// Measured on the owner's Mac, 15 August 2026. He asked *"what about sage
/// updates"*; the turn ran 43 seconds, called `sage_timeline` twice, was
/// refused twice, and then answered him out of four `web_search` calls — the
/// appliance went to the internet for something its own memory knew, because
/// the tool that knew it would not answer. That is the whole cost: not an
/// error the owner sees, a slower and worse answer he cannot tell from a good
/// one.
///
/// ## Why a decorator, and why not a sentence in the prompt
///
/// The same reason `ScopedRecall` and `DatedTaskWrites` are decorators, in the
/// words already at their call site: *"a rule in the prompt is followed most of
/// the time, and 'most of the time' fails silently"*. A 4B model that has been
/// shown a year-wide example in the tool schema will keep producing year-wide
/// ranges whatever the system prompt says, and every one of those is a wasted
/// round trip the owner waits through.
///
/// It comes off the same way too: this is a property of *this node version*,
/// not of tool-calling. If SAGE lifts the cap — or fixes its example — the
/// wrapper is deleted and nothing else moves.
///
/// ## Narrowing is disclosed, never silent
///
/// The window is anchored at `to` and reaches back 31 days, because a model
/// asking for a year of activity is asking what has been happening and the
/// recent end is the part that answers that. But a narrowed answer that looked
/// like a complete one would let the model tell the owner "nothing happened in
/// the last year" having been shown one month — a confident false statement
/// produced by us, which is worse than the refusal this replaces. So the reply
/// carries a line saying what was actually covered.
public struct BoundedTimeline: ToolProviding {

    public static let timeline = "sage_timeline"

    /// 31 days, from `appV23TimelineMaxRange` in the node's own
    /// `api/rest/memory_handler.go`.
    ///
    /// A day under would be the cautious choice and is not taken: the node's
    /// comparison is `to.Sub(from) > max`, so exactly 31 days is accepted, and
    /// asking for 30 to be safe would quietly cost the owner a day of history
    /// on every call for no reason.
    public static let widestSpan: TimeInterval = 31 * 24 * 60 * 60

    private let wrapped: ToolProviding
    private let now: @Sendable () -> Date

    public init(wrapping wrapped: ToolProviding, now: @escaping @Sendable () -> Date = { Date() }) {
        self.wrapped = wrapped
        self.now = now
    }

    public func listTools() async throws -> [MCPTool] {
        try await wrapped.listTools()
    }

    public func call(name: String, arguments: [String: JSONValue]) async throws -> String {
        guard name == Self.timeline else {
            return try await wrapped.call(name: name, arguments: arguments)
        }
        guard let narrowed = Self.narrow(arguments: arguments, now: now()) else {
            // Already inside the cap, or a range this cannot read. Both are the
            // node's to answer: an unparseable timestamp gets its own precise
            // refusal from SAGE, and inventing a range here would replace a
            // clear message with a wrong answer.
            return try await wrapped.call(name: name, arguments: arguments)
        }
        let reply = try await wrapped.call(name: name, arguments: narrowed.arguments)
        return reply + "\n\n" + narrowed.disclosure
    }

    /// What to send instead, or nil to send what the model asked for.
    static func narrow(
        arguments: [String: JSONValue],
        now: Date
    ) -> (arguments: [String: JSONValue], disclosure: String)? {
        let askedFrom = arguments["from"]?.stringValue.flatMap(rfc3339)
        let askedTo = arguments["to"]?.stringValue.flatMap(rfc3339)

        // Neither given: the node's own default is the last 24 hours, which is
        // well inside the cap. Nothing to do, and supplying a range here would
        // override a default the node is entitled to change.
        if askedFrom == nil && askedTo == nil { return nil }

        // `to` alone is under the cap by construction — the node pairs it with
        // a `from` 24 hours earlier — so only a stated `from` can be too far
        // back.
        guard let from = askedFrom else { return nil }
        let to = askedTo ?? now

        // Backwards. The node says "from must be earlier than or equal to to",
        // which is exact and actionable; swapping them would be guessing at an
        // intent the model did not express.
        guard to >= from else { return nil }
        guard to.timeIntervalSince(from) > widestSpan else { return nil }

        let narrowedFrom = to.addingTimeInterval(-widestSpan)
        var narrowed = arguments
        narrowed["from"] = .string(rfc3339(narrowedFrom))
        narrowed["to"] = .string(rfc3339(to))
        return (narrowed, disclosure(asked: from, from: narrowedFrom, to: to))
    }

    /// Written for the model to repeat to the owner, not for a log.
    static func disclosure(asked: Date, from: Date, to: Date) -> String {
        "Note: this node answers at most 31 days of timeline per request, so the range asked for "
            + "(from \(rfc3339(asked))) was narrowed. What follows covers \(rfc3339(from)) to "
            + "\(rfc3339(to)) only — say so rather than describing it as the whole period, and ask "
            + "for an earlier window if the rest matters."
    }

    // MARK: - RFC3339

    /// Both shapes the node emits and accepts. Fractional seconds appear in
    /// SAGE's own `created_at` values, so a model echoing one back must not be
    /// treated as having sent nonsense.
    static func rfc3339(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }

    static func rfc3339(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
