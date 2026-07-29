import Foundation
import SageVoiceCore

/// Mynah's own plate, asked through MCP as Mynah.
///
/// ## The third source, and why the first two were both wrong
///
/// This board has been built twice and has never once opened.
///
/// It began on `sage_backlog` and showed nothing, because nothing was assigned
/// to this appliance. That was read as the tool being too narrow, so it moved to
/// an **unsigned** `GET /v1/dashboard/tasks?all=true` — the feed CEREBRUM reads,
/// which returns everyone's work. On this owner's node that endpoint answers
/// `401 {"error":"unauthorized","login_required":true}`, verified again on
/// 2026-07-29, which becomes `TaskSourceFailure.locked` and renders as *"Tasks —
/// this list won't open"*. It has said that in every screenshot since.
///
/// So the first source was empty and the second was forbidden, and the move
/// between them was a diagnosis of the wrong problem: an empty plate had been
/// mistaken for a broken reader.
///
/// ## Why it goes back to the narrow tool
///
/// Because the narrow answer is the correct one. The owner's ruling:
/// *"sage_backlog should only return this agents task - other agents you ask
/// them for their backlog via pipe message - and they can reply if they want -
/// we cannot read other peoples todo list bro."*
///
/// That reframes the original "failure" entirely. `sage_backlog` returning only
/// Mynah's work was never the bug — it is the design, and the CEREBRUM feed's
/// whole-node view is the thing that should not have been on this screen. The
/// same ruling the Agents page got: *"we already said only use mcp tools"*.
///
/// ## What this deliberately cannot show
///
/// `sage_backlog` returns **open** tasks. Finished and abandoned work is not in
/// its answer at all — not empty, absent. A board that drew a Done column from
/// this source would print "Nothing finished yet." forever over work that exists
/// and was completed, which is a more expensive lie than a missing column. So
/// the reading marks the board as not covering terminal work and the view leaves
/// those columns out entirely.
actor MCPTaskSource: TaskSource {

    static let shared = MCPTaskSource()

    private let call: @Sendable () async throws -> JSONValue

    /// Defaults to the long-lived MCP connection `SageMemoryStore` already
    /// holds — the same appliance identity the Memories page and the agent
    /// roster sign as. No second node process and no second key.
    init(
        call: @escaping @Sendable () async throws -> JSONValue = {
            try await SageMemoryStore.shared.callTool("sage_backlog")
        }
    ) {
        self.call = call
    }

    func board() async throws -> TaskBoard {
        let payload: JSONValue
        do {
            payload = try await call()
        } catch let error as MCPClientError {
            throw Self.failure(for: error)
        } catch {
            throw TaskSourceFailure.unreachable
        }
        guard let board = TaskBacklogReading.board(from: payload) else {
            throw TaskSourceFailure.unreadable
        }
        return board
    }

    /// MCP failures, mapped the way the rest of the app maps them — one for a
    /// node that is not there and a different one for a node that is there and
    /// did not answer, because they send somebody to two different places.
    static func failure(for error: MCPClientError) -> TaskSourceFailure {
        switch error {
        case .missingExecutable: return .notInstalled
        case .toolFailed, .rpcError: return .refused
        case .malformedResponse: return .unreadable
        case .launchFailed, .notStarted, .serverExited, .timedOut: return .unreachable
        }
    }
}

/// Turning `sage_backlog`'s reply into columns.
///
/// Its own type, like `TaskBoardReading` beside it, so the seam where a change
/// at the node becomes a wrong board can be tested against real payloads without
/// a node.
enum TaskBacklogReading {

    /// The prefix the store writes onto every task's content. Shown to the owner
    /// it is noise on every single row — they know they are looking at tasks.
    static let storedPrefix = "[TASK] "

    static func board(from payload: JSONValue) -> TaskBoard? {
        // The shape is `{"tasks_by_domain": {"<domain>": [task, …]}, …}`. A
        // *missing* key is an unreadable answer; an **empty dictionary** is a
        // perfectly good answer meaning the plate is clear, and conflating the
        // two is the exact mistake that sent this board to REST in the first
        // place.
        guard let domains = payload["tasks_by_domain"]?.objectValue else {
            // An explicit `total_open: 0` with no dictionary is still a real
            // answer from a node with nothing to say.
            if payload["total_open"]?.intValue != nil {
                return TaskBoard(coversFinishedWork: false)
            }
            return nil
        }

        var rows: [BoardTask] = []
        // Sorted so a board read twice in a row is the same board. Dictionary
        // order is not stable, and `@Observable` announces on assignment rather
        // than comparing — an unstable order would repaint the screen every
        // thirty seconds.
        for domain in domains.keys.sorted() {
            guard let tasks = domains[domain]?.arrayValue else { continue }
            rows.append(contentsOf: tasks.compactMap { task(from: $0, domain: domain) })
        }

        var board = TaskBoard.from(rows: rows)
        board.coversFinishedWork = false
        return board
    }

    static func task(from value: JSONValue, domain: String) -> BoardTask? {
        // The id is the one field with no sensible default. A card that cannot
        // be identified cannot be diffed or refreshed, so it is dropped rather
        // than given a synthetic one.
        guard let id = value["memory_id"]?.stringValue, !id.isEmpty else { return nil }

        let content = value["content"]?.stringValue ?? ""
        let title = content.hasPrefix(storedPrefix)
            ? String(content.dropFirst(storedPrefix.count))
            : content

        return BoardTask(
            id: id,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            progress: (value["task_status"]?.stringValue).flatMap(BoardTask.Progress.init(nodeStatus:)),
            domain: domain,
            carrier: carrier(from: value),
            author: nil,
            createdAt: date(from: value["created_at"]),
            statusChangedAt: date(from: value["task_picked_up_at"])
        )
    }

    /// Another agent's hands on this task — and only another agent's.
    ///
    /// The node reports a pickup even when the agent that picked it up is the
    /// one it is assigned to, which is the ordinary case for Mynah's own work.
    /// Drawing "Picked up by …" on every self-assigned card would put a line on
    /// each row that carries no information.
    static func carrier(from value: JSONValue) -> BoardTask.Carrier? {
        guard let holder = value["task_picked_up_by"]?.stringValue, !holder.isEmpty else {
            return nil
        }
        let assignee = value["assignee"]?.stringValue ?? ""
        guard holder != assignee else { return nil }
        return .pickedUpBy(holder)
    }

    /// The node writes **empty strings** rather than nulls for timestamps it has
    /// no value for — `task_picked_up_at: ""` on every task nobody has started.
    /// A parser that treats that as a malformed date rather than an absent one
    /// would reject most of a healthy board.
    static func date(from value: JSONValue?) -> Date? {
        guard let text = value?.stringValue, !text.isEmpty else { return nil }
        return isoWithFraction.date(from: text) ?? iso.date(from: text)
    }

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// `sage_backlog` returns whole seconds, but `sage_turn` and the memory
    /// endpoints return fractional ones for the same field. Both are parsed so a
    /// future caller does not rediscover this through blank timestamps.
    private static let isoWithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
