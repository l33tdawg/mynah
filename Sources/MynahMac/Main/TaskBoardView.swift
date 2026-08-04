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
    /// One column, two groups, each scrolling on its own.
    ///
    /// **Four columns became two stacked groups, and the reason is what the node
    /// can answer.** `sage_backlog` returns *open* tasks assigned to this agent;
    /// finished and abandoned work is never in the reply, and `sage_list`
    /// reports a memory's status rather than a board's. CEREBRUM shows Done and
    /// Dropped because it is the operator UI talking to the node's dashboard
    /// API, which this appliance has no authority for. Those two columns could
    /// only ever have held what was dragged into them in this session and would
    /// empty on the next refresh — permanently and confidently wrong.
    ///
    /// Side by side, two columns also gave each half the width of a narrow pane
    /// and left the taller one scrolling while the other sat empty. Stacked,
    /// each group takes the height it needs and scrolls within itself, so a long
    /// backlog never buries what is under way.
    private func columns(_ board: TaskBoard) -> some View {
        VStack(spacing: 0) {
            BoardColumnView(
                // **One list, because there was only ever one.**
                //
                // "In progress" held nothing for the life of this board and
                // could not hold anything: nothing moves a task out of
                // `planned`. The owner ruled on it — *"thus task list can be
                // only 'planned'"* — and gave the reason: these are errands a
                // person does, *"buy eggs, call so and so, chiro appointment
                // next week"*, not work with a lifecycle to track. Work handed
                // to another agent is chased by asking Mynah to message them,
                // which needs no column at all.
                //
                // Still labelled rather than left as a bare stack of cards —
                // his note, and he is right: an unheaded list beneath a
                // conversation reads as part of the conversation.
                title: "Tasks",
                tone: .neutral,
                count: board.planned.count,
                tasks: board.planned,
                emptyLine: "Nothing on your list.",
                accepts: .planned,
                onDrop: move,
                onRemove: remove
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // On the board itself: SwiftUI then moves the card between the two
        // groups rather than deleting it from one and inserting it into the
        // other. A card that vanishes and reappears is a repaint; a card that
        // travels is a move, and the difference is the whole reason the gesture
        // feels like picking something up.
        .mynahAnimation(Motion.snap, value: board)
    }

    /// Carries a dropped card to its new group.
    ///
    /// `TaskBoardModel.move` updates the board before the write lands and puts
    /// it back if the node refuses, so the gesture never waits on consensus and
    /// never lies about the outcome.
    private func move(_ taskID: String, to status: BoardTask.Progress) {
        guard let task = model.board?.task(withID: taskID) else { return }
        Task { await model.move(task, to: status) }
    }

    /// Takes a card off the board.
    ///
    /// Marks it `done` rather than `dropped`. The glyph is a cross because it is
    /// a *remove* affordance on a card — but the meaning has to be the common
    /// one, and taking something off your plate by hand almost always means you
    /// did it. The tooltip says which, so nobody has to infer it from an icon.
    private func remove(_ taskID: String) {
        move(taskID, to: .done)
    }

    /// The two lines under the board, and both are conditional.    /// The two lines under the board, and both are conditional.
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
    /// Which status a card dropped here becomes, and who to tell.
    var accepts: BoardTask.Progress?
    var onDrop: ((String, BoardTask.Progress) -> Void)?
    var onRemove: ((String) -> Void)?

    /// A card is over this column right now.
    @State private var isTargeted = false

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
                        // History is a pile, not a plan. Day headings — and
                        // especially "Friday is free" — answer "when can this
                        // go?", which is not a question anybody asks of work
                        // that is already finished.
                        ForEach(isHistory
                            ? TaskBoard.clustered(tasks).map { TaskRow.cluster($0) }
                            : TaskBoard.rows(tasks)) { row in
                            switch row {
                            case .day(let day):
                                DayHeading(day: day)
                            case .cluster(let cluster):
                                if cluster.isShared, !isHistory {
                                    SharedTimeBox(
                                        cluster: cluster,
                                        onRemove: onRemove
                                    )
                                } else {
                                    // History never boxes: two haircuts that
                                    // happened at the same time is not a thing
                                    // anyone needs pointed out afterwards.
                                    ForEach(cluster.tasks) { task in
                                        draggableCard(task)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.bottom, s5)
                }
                .scrollBounceBehavior(.basedOnSize)
                // **The scroller gets the column's right margin to itself.**
                //
                // This list is inset by `s6` on both sides by the padding at
                // the bottom of this view, so the scroll view ended exactly
                // where the cards did and macOS drew the scroller on top of
                // them — over the right border of a card, and over the edge of
                // the "at the same time" box, which has a visible outline it
                // was cutting through.
                //
                // Widening the scroll view into that margin and then insetting
                // its *content* by the same amount leaves every card where it
                // already was and moves only the scroller, out into the gap
                // that was always there. Content margins rather than padding
                // on the stack: padding would move the indicator with the
                // content, which is the thing being fixed.
                .padding(.trailing, -s6)
                .contentMargins(.trailing, s6, for: .scrollContent)
            }
        }
        // The whole column is the target, not the list — dropping into the gap
        // below the last card is the same gesture and has to mean the same
        // thing.
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { ids, _ in
            guard let accepts, let id = ids.first else { return false }
            onDrop?(id, accepts)
            return true
        } isTargeted: { targeted in
            // Animated on the way in *and* out. A highlight that appears
            // instantly and vanishes instantly reads as a flicker rather than as
            // the column saying "here".
            withAnimation(Motion.snap) { isTargeted = targeted }
        }
        .background(
            RoundedRectangle.mynah(r.card)
                .fill(isTargeted ? tone.wash : .clear)
                .padding(.horizontal, s3)
        )
        .overlay(
            RoundedRectangle.mynah(r.card)
                .strokeBorder(isTargeted ? tone.ink.opacity(0.5) : .clear, lineWidth: 1.5)
                .padding(.horizontal, s3)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, s6)
        .padding(.vertical, s6)
    }

    /// One card, wired for drag.
    ///
    /// Extracted because it is now built in two places — loose in the column,
    /// and inside a shared-time box — and a card that could be dragged in one
    /// place and not the other would be a difference nobody could explain.
    private func draggableCard(_ task: BoardTask) -> some View {
        TaskCard(
            task: task,
            isHistory: isHistory,
            onRemove: onRemove.map { remove in { remove(task.id) } }
        )
        // The card itself is the payload: its id is the memory id, which is
        // all `sage_task` needs.
        .draggable(task.id) {
            // What follows the cursor. Narrower than the card and slightly
            // transparent, so the column underneath stays readable while
            // deciding where to put it.
            TaskCard(task: task, isHistory: isHistory)
                .frame(width: 240)
                .opacity(0.9)
        }
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
/// Several tasks that happen at the same moment, in one bounding box.
///
/// The owner, looking at a dentist appointment and a Google Meet both written
/// for Tuesday at 1pm and drawn as two unrelated cards four rows apart: *"if
/// there's a clash, can we put them like into 1 bounding box - so its clear it
/// happens at the same time"*, then the shape: *"we still need them to show as
/// separate items but within the blue or red box, make it 1 bounding box"*.
///
/// So the cards keep their own surface and hairline — they are still separate
/// things, still individually draggable and removable — and only the *coloured*
/// border moves outward, from each card to the box around them. One nearness
/// mark for one moment, which is what it was always describing.
///
/// **It states a fact and asks for nothing.** His own example of a clash is two
/// errands that share a slot perfectly well: *"some things can be done
/// simultaneously; like send car to car wash and get groceries"*. Nothing here
/// says conflict, nothing warns, nothing offers to move anything.
/// A day's name over the cards belonging to it, or on its own when it has none.
///
/// Same eyebrow as `SharedTimeBox`'s "At the same time · 11am", because it is the
/// same kind of thing: a small true statement about the cards under it, in the
/// vocabulary the column already speaks.
///
/// **A free day is quieter, not louder.** It carries no cards, so nothing anchors
/// it, and drawn at the same weight as a day with three appointments it would
/// read as the busiest row on the board.
private struct DayHeading: View {
    let day: TaskDay

    var body: some View {
        HStack(spacing: s2) {
            Text(day.title)
                .mynahFont(.eyebrow)
                .foregroundStyle(day.isFree ? Palette.ink.tertiary : Palette.ink.secondary)
            if day.isFree {
                Text("· Free")
                    .mynahFont(.eyebrow)
                    .foregroundStyle(Palette.ink.tertiary)
            }
        }
        .padding(.horizontal, s2)
        .padding(.top, day.isFree ? 0 : s2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(day.isFree ? "\(day.title), nothing on" : day.title)
    }
}

private struct SharedTimeBox: View {
    let cluster: TaskCluster
    var onRemove: ((String) -> Void)?

    /// The box's own nearness, taken from its members — who by construction all
    /// happen at the same instant, so they cannot disagree about it.
    private var nearness: TaskNearness? {
        cluster.tasks.lazy.compactMap { TaskNearness.of($0) }.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: s4) {
            if let sharedTime = cluster.sharedTime {
                // Said in words, because two cards whose titles both end "1pm"
                // are only obviously simultaneous to somebody already reading
                // for it — and because a border is invisible to VoiceOver and to
                // anyone who cannot separate blue from orange.
                Text("At the same time · \(sharedTime)")
                    .mynahFont(.eyebrow)
                    .foregroundStyle(Palette.ink.secondary)
                    .padding(.horizontal, s2)
            }
            ForEach(cluster.tasks) { task in
                TaskCard(
                    task: task,
                    isHistory: false,
                    // The box draws it once for all of them.
                    showsNearness: false,
                    onRemove: onRemove.map { remove in { remove(task.id) } }
                )
                .draggable(task.id) {
                    TaskCard(task: task, isHistory: false)
                        .frame(width: 240)
                        .opacity(0.9)
                }
            }
        }
        .padding(s4)
        .overlay {
            RoundedRectangle.mynah(r.card)
                .strokeBorder(
                    nearness == .today ? Palette.state.dueToday : Palette.state.dueTomorrow,
                    lineWidth: 2
                )
                // A box holding a task neither today nor tomorrow still groups
                // it — the grouping is a fact about the clock, not about how
                // soon it is — but there is no colour to say so with.
                .opacity(nearness == nil ? 0 : 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "\(cluster.tasks.count) at the same time\(cluster.sharedTime.map { ", \($0)" } ?? "")"
        )
    }
}

private struct TaskCard: View {
    let task: BoardTask
    let isHistory: Bool
    /// Whether this card draws its own due-soon border.
    ///
    /// `false` inside a `SharedTimeBox`, which draws one for the whole group —
    /// otherwise a box of two would carry three concentric coloured rectangles
    /// saying the same thing.
    var showsNearness = true
    /// Takes this card off the board. Absent on a card that cannot be removed.
    var onRemove: (() -> Void)?

    /// The pointer is over this card, so the remove control is visible.
    @State private var isHovering = false

    /// Recomputed on each render rather than stored, so a board left open
    /// overnight does not still call yesterday "today".
    private var nearness: TaskNearness? { TaskNearness.of(task) }

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
                // Room for the remove control, kept whether or not it is
                // showing.
                //
                // It is an overlay, so it sits *on top* of whatever is under it
                // — and a two-line title filling the card ran straight under the
                // cross. Reserving the space unconditionally rather than only
                // while hovering also stops the text reflowing under the
                // pointer, which is its own small horror.
                .padding(.trailing, onRemove == nil ? 0 : 24)
            if hasFootnote { footnote }
        }
        .mynahCard(density: .compact)
        // Drawn over the card's own hairline rather than replacing it, so a
        // near task keeps the same shape as every other card and differs only
        // in colour and weight. History is never marked: a haircut that already
        // happened is not happening soon.
        .overlay {
            if showsNearness, !isHistory, let nearness {
                RoundedRectangle.mynah(r.card)
                    .strokeBorder(
                        nearness == .today ? Palette.state.dueToday : Palette.state.dueTomorrow,
                        lineWidth: 2
                    )
            }
        }
        // Said in words as well as colour. Somebody who cannot separate blue
        // from orange gets the same fact, and VoiceOver reads it aloud — a
        // border is invisible to both.
        .accessibilityHint(nearness == .today ? "Due today" : nearness == .tomorrow ? "Due tomorrow" : "")
        // On hover, not always.
        //
        // A cross on every card, permanently, turns a list of work into a list
        // of things to dismiss — and on a board the owner is reading rather than
        // editing, that is the wrong invitation. It appears under the pointer,
        // where the intent to act on *this* card already exists.
        .overlay(alignment: .topTrailing) {
            if let onRemove, isHovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Palette.ink.secondary)
                        .frame(width: 18, height: 18)
                        .background(Palette.surface.sunken, in: Circle())
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                // The glyph is a cross because it removes the card; the meaning
                // has to be said in words, because taking something off your
                // plate by hand almost always means you did it, and an icon
                // cannot carry that on its own.
                .help("Done — take it off the board")
                .accessibilityLabel("Mark done and remove from the board")
                .padding(s3)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .onHover { hovering in
            withAnimation(Motion.fade) { isHovering = hovering }
        }
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
