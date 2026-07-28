import SwiftUI

// MARK: - The board

/// What is on the owner's plate, which is the reason to open this window.
///
/// Mynah is an agent manager first and an assistant second: the question someone
/// walks over to the Mac to answer is "what is happening with my things", not
/// "what did I say". A transcript answers the second. This answers the first,
/// and the conversation moves underneath it as the way to *create* work rather
/// than the thing to stare at.
///
/// Three columns, and they are the node's own workflow statuses rather than a
/// shape chosen to look like a board. Nothing here is drawn that the node did
/// not say — including the gap where finished work should be, which is stated
/// rather than papered over with an empty column.
@MainActor
struct TaskBoardView: View {

    let model: TaskBoardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let board = model.board {
                if let trouble = model.trouble { staleNote(trouble) }
                columns(board)
            } else if let trouble = model.trouble {
                // No board *and* a failure: the only state where the owner is
                // told nothing about their tasks, so it has to say why rather
                // than show three empty columns they would read as "none".
                failure(trouble)
            } else {
                // Nothing read yet and nothing wrong yet: the first call is
                // still in flight. A read always ends in a board or a trouble,
                // so this state does not outlive the first answer.
                looking
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Columns

    private func columns(_ board: TaskBoard) -> some View {
        HStack(alignment: .top, spacing: 0) {
            BoardColumnView(
                title: "Planned",
                count: board.planned.count,
                tasks: board.planned,
                emptyLine: "Nothing planned."
            )
            columnRule
            BoardColumnView(
                title: "In progress",
                count: board.inProgress.count,
                tasks: board.inProgress,
                emptyLine: "Nothing under way."
            )
            columnRule
            BoardColumnView(
                title: "Done",
                // No count when nothing can be counted. A "0" here would be the
                // single most misleading character on the screen.
                count: board.done?.count,
                tasks: board.done ?? [],
                emptyLine: doneLine(board),
                isHistory: true
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The two sentences this column has to keep apart. "Mynah cannot see them"
    /// and "you have finished none" are different facts and only one of them is
    /// true today.
    private func doneLine(_ board: TaskBoard) -> String {
        board.done == nil
            ? "Mynah can't see finished tasks yet — it is only told about open ones."
            : "Nothing finished yet."
    }

    private var columnRule: some View {
        Rectangle()
            .fill(Palette.line.divider)
            .frame(width: 1)
            .frame(maxHeight: .infinity)
    }

    // MARK: The states that are not a board

    /// Shown while the very first read is in flight, and never again — a board
    /// that blinks "looking" every thirty seconds would be a board flickering at
    /// somebody trying to read it.
    private var looking: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Text("Looking at your list…")
                .mynahFont(.body)
                .foregroundStyle(Palette.ink.secondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failure(_ trouble: Exchange.Failure) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            EmptyState(
                glyph: "checklist",
                title: trouble.headline,
                message: trouble.explanation,
                actionTitle: trouble.canRetry ? "Try again" : nil,
                action: trouble.canRetry ? { Task { await model.refresh() } } : nil
            )
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, s8)
    }

    /// A board that is on screen but out of date says so, quietly, and keeps the
    /// tasks. Blanking them would tell an owner with twelve things on their
    /// plate that they have none, which is the one thing this screen must never
    /// do.
    private func staleNote(_ trouble: Exchange.Failure) -> some View {
        HStack(spacing: s4) {
            Text("Showing what it last saw — it can't reach your list right now.")
                .mynahFont(.label)
                .foregroundStyle(Palette.state.caution)
                .lineLimit(1)
            Spacer(minLength: s4)
            MynahButton("Try again", kind: .quiet) { Task { await model.refresh() } }
        }
        .padding(.horizontal, s8)
        .padding(.top, s5)
    }
}

// MARK: - One column

private struct BoardColumnView: View {
    let title: String
    /// `nil` when the column cannot be counted, which is not zero.
    let count: Int?
    let tasks: [BoardTask]
    let emptyLine: String
    /// Finished work is history: it stays legible and stops competing with the
    /// two columns that still need something from the owner.
    var isHistory = false

    var body: some View {
        VStack(alignment: .leading, spacing: s5) {
            header
            if tasks.isEmpty {
                Text(emptyLine)
                    // `secondary`, never `tertiary`: this is a sentence that
                    // tells the owner what is true, not a decorative mark.
                    .mynahFont(.callout)
                    .foregroundStyle(Palette.ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: s4) {
                        ForEach(tasks) { task in
                            TaskCard(task: task, isHistory: isHistory)
                        }
                    }
                    .padding(.bottom, s5)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, s6)
        .padding(.vertical, s6)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: s3) {
            Text(title)
                .mynahFont(.eyebrow)
                .foregroundStyle(Palette.ink.secondary)
                .accessibilityAddTraits(.isHeader)
            if let count {
                Text("\(count)")
                    .mynahFont(.mono)
                    .monospacedDigit()
                    .foregroundStyle(Palette.ink.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - One task

/// A task, with nothing on it that the node did not say.
///
/// No priority flag, no due date, no drag handle. The first two do not exist in
/// the task model; the third would promise a status change this board
/// deliberately cannot make — moving a card writes into consensus on the owner's
/// own node, and that is not something to discover by mis-clicking.
private struct TaskCard: View {
    let task: BoardTask
    let isHistory: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: s3) {
            Text(task.title)
                .mynahFont(.body)
                .foregroundStyle(isHistory ? Palette.ink.secondary : Palette.ink.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                // Long enough for a real sentence, short enough that one
                // rambling task cannot own the column.
                .lineLimit(5)
            if hasFootnote { footnote }
        }
        .mynahCard(density: .compact)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenLabel)
    }

    private var hasFootnote: Bool { task.domain != nil || task.carrier != nil }

    private var footnote: some View {
        HStack(alignment: .firstTextBaseline, spacing: s3) {
            if let domain = task.domain {
                Text(domain)
                    .mynahFont(.label)
                    .foregroundStyle(Palette.ink.secondary)
            }
            if let carrier = task.carrier {
                if task.domain != nil {
                    Text("·")
                        .mynahFont(.label)
                        .foregroundStyle(Palette.ink.quaternary)
                }
                // The agent's own id, unprettified. There is no display-name
                // mapping to be had from here, and a made-up friendly name for
                // another agent would be worse than the true one.
                Text(carrierLine(carrier))
                    .mynahFont(.label)
                    .foregroundStyle(Palette.ink.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func carrierLine(_ carrier: BoardTask.Carrier) -> String {
        switch carrier {
        case .pickedUpBy(let agent): return "Picked up by \(agent)"
        case .assignedTo(let agent): return "Assigned to \(agent)"
        }
    }

    private var spokenLabel: String {
        var parts = [task.title]
        if let domain = task.domain { parts.append(domain) }
        if let carrier = task.carrier { parts.append(carrierLine(carrier)) }
        return parts.joined(separator: ". ")
    }
}
