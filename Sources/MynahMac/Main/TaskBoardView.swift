import SageVoiceCore
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
                footnotes(board)
                    .padding(.horizontal, s6)
                    .padding(.bottom, s5)
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

    /// Four columns, matching the four the node publishes and CEREBRUM draws.
    ///
    /// Each header is a glyph, a name and a count, and the glyph is where the
    /// colour lives: `circle` for work not started, a filled ring for the thing
    /// happening now, a tick for finished, a cross for abandoned. Colour is on
    /// the mark rather than behind the column because a board is mostly cards,
    /// and four tinted panels behind them would leave nowhere quiet to read.
    ///
    /// Only In progress takes the accent. `Palette.accent` reserves it for "the
    /// one live thing", which on a board is exactly this column, and it is what
    /// makes the eye land there rather than on finished work.
    private func columns(_ board: TaskBoard) -> some View {
        HStack(alignment: .top, spacing: 0) {
            BoardColumnView(
                title: "Planned",
                tone: .neutral,
                count: board.planned.count,
                tasks: board.planned,
                emptyLine: "Nothing planned."
            )
            columnRule
            BoardColumnView(
                title: "In progress",
                tone: .accent,
                count: board.inProgress.count,
                tasks: board.inProgress,
                emptyLine: "Nothing under way."
            )
            // **Absent, not empty.** `sage_backlog` answers with open work only,
            // so finished and abandoned tasks are not in its reply at all. A
            // Done column fed from it would read "Nothing finished yet." for
            // ever, over work the owner knows they completed — and a column that
            // is permanently and confidently wrong costs more trust than a
            // column that is not drawn.
            if board.coversFinishedWork {
                columnRule
                BoardColumnView(
                    title: "Done",
                    tone: .good,
                    count: board.done.count,
                    tasks: board.recent(board.done, showingAll: model.showsOlderFinished),
                    emptyLine: "Nothing finished yet.",
                    isHistory: true
                )
                columnRule
                BoardColumnView(
                    title: "Dropped",
                    // A cross, not a warning triangle. Abandoning a task is a
                    // decision the owner made, not a fault, and this column should
                    // read as closed rather than as something needing attention —
                    // which is why it is `neutral` and not `critical`.
                    tone: .neutral,
                    count: board.dropped.count,
                    tasks: board.recent(board.dropped, showingAll: model.showsOlderFinished),
                    emptyLine: "Nothing dropped.",
                    isHistory: true
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The two lines under the board, and both are conditional.
    ///
    /// Finished and abandoned cards leave the board seven days after they stop
    /// moving, which is what CEREBRUM does with the same timestamp. That is a
    /// quiet, automatic thing, and it only needs saying at the moment it has
    /// actually hidden something.
    @ViewBuilder
    private func footnotes(_ board: TaskBoard) -> some View {
        let hidden = board.olderThanWindow()
        if hidden > 0 || model.showsOlderFinished {
            HStack(spacing: s4) {
                MynahButton(
                    model.showsOlderFinished ? "Show the last week only" : "Show all finished work",
                    kind: .quiet
                ) {
                    model.showsOlderFinished.toggle()
                }
                if !model.showsOlderFinished {
                    Text(hidden == 1
                         ? "1 finished card is older than a week."
                         : "\(hidden) finished cards are older than a week.")
                        .mynahFont(.label)
                        .foregroundStyle(Palette.ink.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        if !board.unclassified.isEmpty {
            // The node hands these over unlabelled on purpose — it will not
            // guess whether old work is planned or finished, and neither will
            // this. Naming the count is everything Mynah honestly can do; the
            // deciding happens where the operator is.
            Text(board.unclassified.count == 1
                 ? "1 older task has no status recorded, so it isn't in a column. CEREBRUM can set it."
                 : "\(board.unclassified.count) older tasks have no status recorded, so they aren't "
                    + "in a column. CEREBRUM can set them.")
                .mynahFont(.label)
                .foregroundStyle(Palette.ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if !board.coversFinishedWork {
            // Said once, quietly, rather than implied four times by a pair of
            // columns that never fill. The owner should not have to work out
            // from two permanently empty headings that this screen is showing
            // them a different question than they thought.
            Text("This is the work assigned to Mynah. Finished tasks and other agents' "
                 + "work aren't part of what it can ask for — those live in CEREBRUM.")
                .mynahFont(.label)
                .foregroundStyle(Palette.ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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
                // Not caution ink, and the owner is the reason.
                //
                // He saw amber on the task area and reported "signal crashed
                // again — see it's yellow now (paused mode colour)". Signal had
                // not crashed; both processes were up and both plists intact.
                // He had spent the day learning that amber on this product
                // means *Mynah is not doing what you think* — the readiness
                // banner, the restricted dot, the paused switch — so amber
                // anywhere near the appliance reads as a state of the
                // appliance.
                //
                // This is a property of a **list**, not of the product: the
                // tasks are stale and the words say so. Nothing is wrong with
                // Mynah. Secondary ink says "here is a fact" where amber said
                // "something is broken", and the sentence carries the rest.
                .foregroundStyle(Palette.ink.secondary)
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
    /// The column's mark, and the only coloured thing in its header.
    /// What this column means, in the app's existing state vocabulary.
    var tone: MynahTone = .neutral
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

    /// A label, not a control.
    ///
    /// **The glyphs read as radio buttons.** `circle` and `circle.inset.filled`
    /// are exactly what an unselected and a selected option look like on this
    /// platform, sitting side by side at the tops of adjacent columns — so the
    /// two headings looked like a choice with one option taken, over a board
    /// where there is nothing to choose. The colour carried meaning and the
    /// shape carried a lie.
    ///
    /// A pill instead: the same tone, no shape that suggests it can be pressed,
    /// and the count inside it where it belongs — the column's name and how much
    /// is in it are one fact, not two things that happen to be adjacent.
    private var header: some View {
        HStack(spacing: s3) {
            HStack(spacing: s3) {
                Text(title.uppercased())
                    .mynahFont(.label)
                    .tracking(0.6)
                    .foregroundStyle(tone.ink)
                if let count {
                    Text("\(count)")
                        .mynahFont(.mono)
                        .monospacedDigit()
                        .foregroundStyle(tone.ink.opacity(0.7))
                }
            }
            .padding(.horizontal, s4)
            .padding(.vertical, s2)
            .background(tone.wash, in: Capsule())
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(count.map { "\(title), \($0)" } ?? title)
        .accessibilityAddTraits(.isHeader)
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

    private var hasFootnote: Bool {
        task.domain != nil || task.carrier != nil || task.author != nil || task.shownAt != nil
    }

    /// The tag, then who and when.
    ///
    /// **The domain tag is deliberately not colour-coded**, which is the one
    /// place this board departs from CEREBRUM. In this app colour carries
    /// meaning — `Palette.accent` is "the one live thing", `state.good` is "your
    /// words stay here" — and a dozen domains each claiming a hue would leave
    /// those two signals indistinguishable from filing. The tag earns its
    /// separation from the shape it sits in instead.
    private var footnote: some View {
        VStack(alignment: .leading, spacing: s2) {
            HStack(spacing: s3) {
                if let domain = task.domain {
                    // Through `MemorySubjectName`, because the node names an
                    // agent's home domain after its own public key and the raw
                    // form filled this chip with truncated hex beside "Book
                    // hotel for Wednesday 19th".
                    Text(MemorySubjectName.display(
                        domain,
                        applianceAgentID: SageAgentIdentity.applianceAgentID()
                    ))
                        .mynahFont(.label)
                        .foregroundStyle(Palette.ink.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, s3)
                        .padding(.vertical, 1)
                        .background(Palette.surface.well, in: RoundedRectangle.mynah(r.chip))
                }
                Spacer(minLength: 0)
                if let when = task.shownAt {
                    Text(when.formatted(.relative(presentation: .named)))
                        .mynahFont(.label)
                        .foregroundStyle(Palette.ink.secondary)
                        .lineLimit(1)
                }
            }
            if let line = attribution {
                HStack(spacing: s2) {
                    Image(systemName: "person.crop.circle")
                        .mynahIcon(.inline)
                        .foregroundStyle(Palette.ink.tertiary)
                    // The agent's own id, unprettified. There is no display-name
                    // mapping to be had from here, and a made-up friendly name
                    // for another agent would be worse than the true one.
                    Text(line)
                        .mynahFont(.label)
                        .foregroundStyle(Palette.ink.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    /// Who is holding this, or — on a finished card — who finished it.
    ///
    /// Falls back to the author, because a card nobody was assigned still came
    /// from somewhere. A card with neither says nothing: an empty author is how
    /// the node reports a task the owner wrote themselves, and "created by you"
    /// on every one of their own tasks is noise.
    private var attribution: String? {
        if let carrier = task.carrier { return carrierLine(carrier) }
        return task.author.map { "From \($0)" }
    }

    private func carrierLine(_ carrier: BoardTask.Carrier) -> String {
        switch carrier {
        case .pickedUpBy(let agent): return "Picked up by \(agent)"
        case .assignedTo(let agent): return "Assigned to \(agent)"
        // The node's own words for terminal attribution. It keeps the assignee
        // on a finished task precisely so this can be said, and says it
        // read-only — nobody is still working on this one.
        case .completedBy(let agent): return "Completed by \(agent)"
        case .droppedBy(let agent): return "Dropped by \(agent)"
        }
    }

    private var spokenLabel: String {
        var parts = [task.title]
        if let domain = task.domain { parts.append(domain) }
        if let line = attribution { parts.append(line) }
        return parts.joined(separator: ". ")
    }
}
