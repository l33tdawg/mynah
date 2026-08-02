import Foundation

/// Makes a task carry a real date before it is stored.
///
/// **The bug this fixes, verbatim from the node.** Asked on the morning of 3
/// August to be reminded to call somebody at ten, Mynah wrote:
///
///     Call Amy — reminder set for today at 10:00
///
/// Which is fine to read and useless to a machine. `SpokenDate.writtenDate`
/// refuses it — correctly, because "today" is only meaningful next to the moment
/// it was written and a stored task outlives that moment by design. So the task
/// had *no date*: it sorted with the undated ones at the bottom of the board,
/// and the reminder ladder never looked at it. The owner watched an empty
/// ledger and a task sitting in the wrong place, and both had the same single
/// cause.
///
/// ## Why this is not a prompt fix
///
/// The prompt already says to write the full date down. It said so when this was
/// written anyway. A rule the model follows most of the time produces a task
/// list that is *usually* sorted and reminders that *usually* fire, and the
/// failures are silent — nothing arrives, and nothing arriving looks exactly
/// like nothing being due.
///
/// So the expansion happens here instead, in code, on the way to the node.
/// `SpokenDate` already resolves "today", "tomorrow", "next Wednesday" and the
/// rest deterministically; the only thing it was missing was somewhere to put
/// the answer.
///
/// ## What it does not touch
///
/// A title that already carries a readable date is passed through untouched, and
/// so is one with nothing date-shaped in it at all. "buy eggs" is not a task
/// with a hidden deadline, and stamping today's date on it would invent a
/// reminder for something that cannot be late.
public struct DatedTaskWrites: ToolProviding {

    public static let task = "sage_task"

    /// The argument `sage_task` puts the title in.
    static let content = "content"

    private let wrapped: ToolProviding
    private let now: @Sendable () -> Date
    private let calendar: Calendar

    public init(
        wrapping wrapped: ToolProviding,
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.wrapped = wrapped
        self.calendar = calendar
        self.now = now
    }

    public func listTools() async throws -> [MCPTool] {
        try await wrapped.listTools()
    }

    public func call(name: String, arguments: [String: JSONValue]) async throws -> String {
        guard name == Self.task, case .string(let title)? = arguments[Self.content] else {
            return try await wrapped.call(name: name, arguments: arguments)
        }
        var stamped = arguments
        stamped[Self.content] = .string(
            Self.dated(title, now: now(), calendar: calendar)
        )
        return try await wrapped.call(name: name, arguments: stamped)
    }

    // MARK: The rewrite

    /// A title with its relative date spelled out, or the title unchanged.
    ///
    /// Pure and total, so the interesting cases are assertable without a node.
    public static func dated(_ title: String, now: Date, calendar: Calendar = .current) -> String {
        // Already readable. Leave it exactly as the model wrote it — the owner
        // sees this text, and rewriting a sentence that already works is how
        // "Chiro Wednesday 5 August 2026 Wednesday 5 August 2026" happens.
        guard SpokenDate.writtenDate(in: title, calendar: calendar) == nil else { return title }

        // Two days named in one sentence is `.ambiguous`, and it stays that way.
        // Picking one silently is how the wrong appointment gets the reminder,
        // and the owner can still fix an undated task.
        guard case .one(let date) = SpokenDate.resolve(in: title, now: now, calendar: calendar) else {
            return title
        }

        return "\(title.trimmedTrailingPunctuation()) (\(spell(date, calendar: calendar)))"
    }

    /// "Monday 3 August 2026, 10:00am" — the shape `SpokenDate.writtenDate`
    /// reads back, which is the whole point of writing it.
    ///
    /// The year is always present. A date without one is read as the current
    /// year, which is right until the last week of December and then wrong for
    /// a fortnight in the direction that matters.
    static func spell(_ date: OwnerDate, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = date.granularity == .minute
            ? "EEEE d MMMM yyyy, h:mma"
            : "EEEE d MMMM yyyy"
        return formatter.string(from: date.at)
            .replacingOccurrences(of: "AM", with: "am")
            .replacingOccurrences(of: "PM", with: "pm")
    }
}

private extension String {
    /// So "…set for today at 10:00." does not become "….  (Monday …)".
    func trimmedTrailingPunctuation() -> String {
        var trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = trimmed.last, ".,;:—- ".contains(last) {
            trimmed.removeLast()
        }
        return trimmed
    }
}
