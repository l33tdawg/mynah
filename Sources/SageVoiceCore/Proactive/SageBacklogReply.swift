import Foundation

/// What one read of `sage_backlog` says about whether it is the whole list.
///
/// **The node changed under this appliance and nothing here re-reads a tool
/// description.** SAGE 11.23.x rewrote `sage_backlog`'s, and it now says the
/// listing is *paged*: *"one call is never the whole board. Read `total_open`,
/// `returned`, `has_more` and `next_offset`, and page with `offset` until
/// has_more is false before claiming you have seen every task. `scan_capped`
/// means the node stopped scanning at its bound."* That sentence was read on 22
/// September 2026, during the 11.19.22 → 11.23.7 vendor bump, by diffing the two
/// brains' published schemas — not by anybody noticing a symptom.
///
/// Two readers depend on this reply and neither had ever been told it could be a
/// page:
///
///   * the **proactive watch**, whose `sawTasks` nil-versus-empty distinction is
///     what stops a node that cannot be read from emptying the owner's calendar
///     (6 August 2026, eleven events deleted and re-created thirty-two minutes
///     later), and
///   * the **board** in the window, which draws whatever it is handed as the
///     plate.
///
/// A page read as the whole list is that same calendar failure arriving from the
/// other side: every task past the first page reads as having *just been
/// completed*. So the envelope gets its own type, in the module both readers can
/// see, and the rule is the one the rest of this appliance runs on: **a read
/// that cannot be shown to be complete is not a read.**
///
/// **11.23.7 pages, and this was nearly a bug report to the node's authors
/// instead of a fix here.** A call with no arguments answers
/// `limit: 25, offset: 0, returned: 5, total_open: 5, has_more: false` — so any
/// reader that takes `tasks_by_domain` alone is looking at at most twenty-five
/// tasks and being told by two separate fields that it is a page. The brain the
/// previous release shipped was the one that ignored all of this: 11.19.22
/// answers with everything it holds and no paging fields at all, and the first
/// version of this note recorded a probe of *that* binary as though it were the
/// new one. The A/B that settled it is worth keeping: mount a 2.7.1 DMG, run the
/// same call against the brain inside it, and watch the fields change.
public struct SageBacklogReply: Equatable, Sendable {

    /// Rows the reply actually carried, counted across its domains.
    public let returned: Int
    /// What the node says it holds in total, when it says.
    public let totalOpen: Int?
    /// The node's own "there is more".
    public let hasMore: Bool
    /// The node's own "I stopped scanning before I was finished".
    public let scanCapped: Bool
    /// Where the next page starts, when the node named one.
    public let nextOffset: Int?

    /// What to do after this page, given how many rows the caller has now read
    /// **including it**.
    ///
    /// **Cumulative, and that is the whole subtlety.** `total_open` counts the
    /// list, not the page: the second page of three legitimately carries one row
    /// beside `total_open: 3`, and a reader that compared the count with *one
    /// page's* rows would call that incomplete and drop it. Written the other way
    /// first, and this test caught it.
    public enum Continuation: Equatable, Sendable {
        /// The node's own answer says the caller has now read everything.
        case complete
        /// Ask again, with these arguments.
        case more([String: JSONValue])
        /// The node says it is holding more and paging cannot reach it: it
        /// stopped scanning at its own bound, or it named a count and never
        /// reached it. The caller must refuse rather than present a page.
        case unreachable
    }

    /// Three ways to be incomplete and one to be sure. **`total_open` is checked
    /// as well as the flags** because it is the field every version of this tool
    /// has carried: a node that pages without saying `has_more` still says how
    /// many there are, and a reader that trusted only the flags would take the
    /// page. Absent `total_open`, the flags are all there is to go on, and the
    /// default is to believe the node — inventing doubt about a well-formed
    /// answer would put this appliance permanently out of step with a node it can
    /// read perfectly, which is the shape 11.23.7 actually answers in.
    ///
    /// The `offset` falls back to the number of rows read so far, which is where
    /// the node's own documented order — `created_at DESC, then memory_id` — puts
    /// the next one.
    public func continuation(afterReading rowsRead: Int) -> Continuation {
        let readSoFar = rowsRead
        // The node stopped scanning rather than stopped listing; the rest is not
        // reachable by asking again. Its own advice is to narrow by domain, which
        // this appliance does not do — so it refuses, which changes nothing.
        guard !scanCapped else { return .unreachable }
        if hasMore || (totalOpen.map { $0 > readSoFar } ?? false) {
            return .more([
                "limit": .int(Self.pageSize),
                "offset": .int(nextOffset ?? readSoFar)
            ])
        }
        return .complete
    }

    /// How many rows one page may carry, and how many pages this appliance will
    /// read before it stops trying.
    ///
    /// 100 is the node's own maximum. Eight pages is 800 open tasks, which is
    /// far past what anybody's plate holds — and the behaviour past it is a
    /// refusal rather than a truncated list, so the bound costs a large backlog
    /// nothing but a log line.
    public static let pageSize = 100
    public static let mostPages = 8

    /// Reads the envelope out of a reply, or `nil` when the reply is not a
    /// backlog at all.
    ///
    /// **`nil` is not "empty"** — that distinction is the whole reason
    /// `tasks(inBacklog:)` throws rather than manufacturing a list, and this
    /// keeps it: a reply that is not a backlog has no envelope, and a reply that
    /// is a backlog has one even when it holds nothing.
    public static func read(_ reply: String) -> SageBacklogReply? {
        guard let payload = SageReply.value(in: reply) else { return nil }
        return read(payload)
    }

    public static func read(_ payload: JSONValue) -> SageBacklogReply? {
        let domains = payload["tasks_by_domain"]?.objectValue
        let totalOpen = payload["total_open"]?.intValue
        // A backlog is a dictionary carrying one of the two keys the tool is
        // documented to answer with — the listing, or the count with nothing in
        // it. Anything else is somebody else's reply.
        guard domains != nil || totalOpen != nil else { return nil }
        let rows = (domains ?? [:]).values.reduce(0) { $0 + ($1.arrayValue?.count ?? 0) }
        return SageBacklogReply(
            returned: rows,
            totalOpen: totalOpen,
            hasMore: payload["has_more"]?.boolValue ?? false,
            scanCapped: payload["scan_capped"]?.boolValue ?? false,
            nextOffset: payload["next_offset"]?.intValue
        )
    }

    /// The first arguments in the chain: ask for a page, so a node that pages
    /// has something to page from rather than a default this appliance cannot
    /// see.
    public static var firstPageArguments: [String: JSONValue] {
        ["limit": .int(pageSize)]
    }
}
