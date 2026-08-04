import SageVoiceCore
import SwiftUI

// MARK: - Talk

/// Where the owner spends their time.
///
/// Four regions and nothing else: one line of health, the board, the
/// conversation, and the place to say something. No metric tiles, no session
/// counters, no chart of how many memories exist.
///
/// The board is the top of this screen because the question somebody walks over
/// to the Mac to answer is "what is happening with my things" — Mynah is an
/// agent manager first and an assistant second. A transcript answers a different
/// question ("what did I say"), which is why the conversation now sits
/// underneath it: it is how work gets *made* and asked about, not the thing to
/// stare at.
///
/// The conversation shown is this window's own, kept by `WindowConversation`.
///
/// It used to be the phone's — the Signal thread mirrored out of the daemon's
/// file — so that walking from the phone to the Mac showed one continuous
/// conversation. That worked in one direction only, because the other direction
/// means this app writing into somebody's Signal history, and the owner chose
/// two whole conversations over one half-merged one. `WindowConversation` has
/// the full reasoning and what carries continuity between them instead.
///
/// Nothing on this screen can reach the phone, in either direction now.
/// Clearing empties this window's record and leaves every Signal message where
/// it is, which is what the line beside the button says.
@MainActor
struct TalkView: View {

    /// The transcript column.
    ///
    /// Wider than the 460pt prose cap because the layout alternates sides: a
    /// question hugs the right edge and an answer the left, so both margins are
    /// used and neither line ever runs the full width.
    private static let column: CGFloat = 640
    /// How much of the column a card on either side may never occupy.
    ///
    /// One number for both sides, so the two margins are equal and the column
    /// reads as one conversation rather than two lists that happen to be
    /// adjacent. It also guarantees the asymmetry survives a one-word message,
    /// which is what stops the transcript collapsing into a single ragged left
    /// margin.
    private static let cardInset: CGFloat = 120
    /// The failure banner is not a card in the exchange — it is a notice about
    /// one — so it takes the width the answer card would have had rather than
    /// shrinking to its sentence.
    private static let answerWidth: CGFloat = column - cardInset

    /// How much of the window the conversation keeps once the board is above it.
    ///
    /// A fixed height rather than a draggable split. A split view would be the
    /// richer answer and it is the one to reach for later; today nobody can see
    /// this screen running, and a divider whose behaviour cannot be checked is
    /// exactly the kind of thing that ships subtly broken. 280pt holds an
    /// exchange and the start of the next on every window this app opens at.
    private static let conversationHeight: CGFloat = 280

    /// The board column: about a third, never narrower than its own headings.
    ///
    /// "1/3" is the intent and a bare fraction is the wrong mechanism — at 900pt
    /// a third is 300, which is fine, and at 600pt it is 200, which is two task
    /// columns of ragged two-word lines. The floor is what the board needs; the
    /// ceiling stops it eating a wide window where the conversation is the thing
    /// being read.
    private static let boardMinimum: CGFloat = 260
    private static let boardIdeal: CGFloat = 320
    private static let boardMaximum: CGFloat = 420

    let model: ConversationModel
    /// The conversation as it happened on the phone. Read-only, and re-read
    /// while this pane is on screen.
    let record: WindowConversation
    /// What is on the owner's plate. Read-only — see `SageTaskSource`.
    let board: TaskBoardModel
    /// Supplied by the shell so the recovery banner can jump straight to
    /// Settings. Absent is fine — the explanation names the action in words, so
    /// nothing here is ever a button that does nothing.
    let onOpenSettings: (() -> Void)?

    @Environment(AppModel.self) private var app
    @FocusState private var isComposerFocused: Bool
    /// Whether the owner is reading the newest messages or has scrolled back
    /// through them. A message arriving from the phone follows them down only in
    /// the first case; in the second, taking the page away mid-sentence is the
    /// rudest thing a live transcript can do.
    @State private var isAtBottom = true

    /// `nil` means the one shared conversation. Defaulted in the body rather
    /// than in the signature: a default argument is evaluated in the caller's
    /// context, so naming a main-actor value there is an isolation error.
    init(
        model: ConversationModel? = nil,
        record: WindowConversation? = nil,
        board: TaskBoardModel? = nil,
        onOpenSettings: (() -> Void)? = nil
    ) {
        self.model = model ?? .shared
        self.record = record ?? .shared
        self.board = board ?? .shared
        self.onOpenSettings = onOpenSettings
    }

    var body: some View {
        // **Beside the conversation, not above it.**
        //
        // The board used to sit on top and take a fixed 280pt off the
        // transcript, which is why it had a collapse control at all: it competed
        // with the thing underneath it for vertical room, so the owner folded it
        // away, and a board nobody can see is not doing its job.
        //
        // *"the middle section we can have a left 1/3rd section for open /
        // ongoing / done tasks (collapsible), and to the right of that 2/3 is
        // the chat window."*
        //
        // Side by side it stays visible while they type, which is the whole
        // point of a board, and the width it takes is width the window had
        // spare — the sidebar it replaces was wider than this column.
        HStack(spacing: 0) {
            if app.homeSplit.showsBoard {
                TaskBoardView(model: board)
                    // A third, with a floor. A fraction alone squeezes the
                    // columns to unreadable on a narrow window, and a fixed
                    // width alone wastes half a wide one.
                    .frame(minWidth: Self.boardMinimum, idealWidth: Self.boardIdeal)
                    .frame(maxWidth: Self.boardMaximum, maxHeight: .infinity)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                MynahDivider(.vertical)
            }
            VStack(spacing: 0) {
                healthLine
                MynahDivider()
                conversation.frame(maxHeight: .infinity)
                // Always. Collapsing the board folds away what is planned, not
                // the ability to say something.
                composer
            }
            .frame(maxWidth: .infinity)
        }
        .mynahAnimation(Motion.snap, value: app.homeSplit)
        .background(Palette.surface.canvas)
        .task {
            // **Before `connect()`, so the very first question in the window
            // already knows what was said here yesterday.**
            //
            // This is the seam the two records were missing. The record draws
            // the earlier conversation above the composer and the engine used to
            // answer from an array that had never seen it — one screen, two
            // memories, and the owner catching it by asking for the steps of a
            // recipe printed directly above the question.
            //
            // Read through a closure rather than copied here: this window keeps
            // adding to the record while it is open, so a snapshot taken now
            // would be stale by the second turn. Evaluated per turn, this is
            // simply "whatever is on screen".
            model.priorContext = { [record] in record.priorMessages }
            // And the other direction, so what is said here survives a relaunch.
            // Nothing else writes this file, which is the whole reason the
            // digests and the overlap matcher could go.
            model.recordTurn = { [record] question, answer, askedAt, answeredAt, files in
                record.record(
                    question: question,
                    answer: answer,
                    askedAt: askedAt,
                    answeredAt: answeredAt,
                    files: files
                )
            }
            // And the same for a reply that arrives with no question in front
            // of it, or the window shows the owner something it cannot itself
            // remember a minute later.
            model.recordArrival = { [record] text, at in
                record.recordArrival(text, at: at)
            }
            await model.connect()
            app.presence = presence
        }
        // Its own task, so the read starts while the engine is still connecting
        // — the record is on disk already and has nothing to wait for.
        .task { await record.restore() }
        // And its own again, so a node that is slow to answer cannot hold up the
        // conversation underneath it.
        .task { await board.follow() }
        .onChange(of: model.isBusy) { _, _ in app.presence = presence }
        .onChange(of: model.readiness) { _, _ in app.presence = presence }
    }

    // MARK: Health

    /// One line. A grid of status cards is a control panel, and the owner did
    /// not buy a control panel.
    private var healthLine: some View {
        let health = app.isPaused ? Self.pausedHealth : model.health
        // **The board control on the left, beside the column it opens.**
        //
        // It sat on the right, at the far end of the line from the thing it
        // acts on, which is what made "what is this chevron for" a question at
        // all. A control belongs next to what it moves.
        //
        // State goes to the right in exchange: readiness and the brain are
        // things you glance at, not things you press.
        return HStack(spacing: s3) {
            boardToggle
            Spacer(minLength: s5)
            StatusDot(health.tone)
            Text(health.title)
                .mynahFont(.body)
                .foregroundStyle(Palette.ink.primary)
            if let detail = health.detail {
                Text("·")
                    .mynahFont(.body)
                    .foregroundStyle(Palette.ink.quaternary)
                Text(detail)
                    .mynahFont(.body)
                    .foregroundStyle(Palette.ink.secondary)
            }
            // Two pills rather than "your words go to DeepSeek": the company
            // and the model it answers as. The sentence never named the model
            // at all, and a sentence is read while a pill is scanned.
            if let provider = health.provider {
                StatusPill(provider, tone: health.staysOnDevice ? .good : .caution)
            }
            if let model = health.model, !model.isEmpty {
                StatusPill(model, tone: health.staysOnDevice ? .good : .caution)
            }
        }
        .padding(.horizontal, s8)
        .padding(.vertical, s5)
        .mynahAnimation(Motion.fade, value: health)
    }

    /// Folds the board column away, and brings it back.
    ///
    /// **This went missing and the loss was not recoverable from the
    /// interface.** The board used to sit above the conversation and
    /// `splitControl` folded it with up/down chevrons. Moving it beside the
    /// conversation left that control orphaned — defined, compiled, referenced
    /// by nothing — so there was no way to collapse the board and, worse, no way
    /// to bring it back: `homeSplit` is persisted, so anyone whose last session
    /// ended on `.conversationOnly` opened Home to a missing column and no
    /// control to restore it. Which is what happened.
    ///
    /// Left/right rather than up/down, because the fold is now horizontal and a
    /// chevron that points the wrong way is a control you have to think about.
    /// `.boardOnly` is deliberately not reachable from here: a column of tasks
    /// with the conversation gone made sense stacked and does not side by side,
    /// where the composer is the other two thirds of the window.
    private var boardToggle: some View {
        let shown = app.homeSplit.showsBoard
        return HStack(spacing: s3) {
            // What is behind the fold, so collapsing the board does not also
            // hide the fact that there is anything on it. Only when folded —
            // beside the open board it would be saying twice what the columns
            // already say.
            if !shown {
                // The same pill the open board heads itself with. It was a plain
                // line of text, and the owner spotted that the folded view was
                // the undesigned one: *"when you expand there's a nice pill -
                // when you collapse its plain - use the pill for both views"*.
                //
                // The sentence it used to be — which says *why* a list will not
                // open, or that nothing is on it — moves to the tooltip rather
                // than being lost.
                TaskPill(title: "Tasks", count: foldedCount, tone: foldedTone)
                    .help(boardSummary)
            }
            boardChevron(shown: shown)
        }
    }

    private func boardChevron(shown: Bool) -> some View {
        Button {
            app.homeSplit = shown ? .conversationOnly : .both
        } label: {
            Image(systemName: shown ? "chevron.left" : "chevron.right")
                .mynahIcon(.inline)
                .foregroundStyle(Palette.ink.secondary)
                .frame(width: 22, height: 18)
                .contentShape(RoundedRectangle.mynah(r.chip))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help(shown ? "Hide what's on its plate" : "Show what's on its plate")
        .accessibilityLabel(shown ? "Hide the task board" : "Show the task board")
    }


    /// What the folded pill counts, or `nil` when the list has not been read —
    /// which is not zero, and the fold is not the place to invent an answer.
    private var foldedCount: Int? { board.board?.planned.count }

    /// A list that will not open says so in its colour as well as its tooltip.
    private var foldedTone: MynahTone { board.trouble == nil ? .neutral : .critical }

    private var boardSummary: String {
        guard let plate = board.board else {
            // Never "no tasks". Nothing has been read, and the fold is not the
            // place to invent an answer.
            //
            // The trouble half said "something needs a look", which has no
            // subject either — it was the sentence beside the amber dot the
            // owner read as the appliance having stopped, and it did nothing to
            // correct him. It names the list now, so the worst a glance can
            // conclude is true.
            return board.trouble == nil ? "Tasks" : "Tasks — this list won't open"
        }
        // **One number, because there was only ever one.**
        //
        // This read "6 planned · 0 in progress · 0 done" for the life of the
        // board, and the two zeroes were not a quiet period — nothing ever sets
        // a task to anything else. The owner's ruling: *"thus task list can be
        // only 'planned'"*, and his reasoning is that these are errands a person
        // does — *"buy eggs, call so and so, chiro appointment next week"* —
        // not work with a lifecycle. Delegated work is chased by asking Mynah
        // to message the agent holding it, which needs no column at all.
        //
        // A counter that has only ever shown zero is worse than absent: it
        // implies a state the owner is failing to reach.
        let count = plate.planned.count
        guard count > 0 else { return "Tasks — nothing on your list" }
        return count == 1 ? "Tasks — 1" : "Tasks — \(count)"
    }


    private var canClear: Bool { !model.exchanges.isEmpty || !record.messages.isEmpty }

    /// The button, and the one thing the owner needs to know before pressing it.
    ///
    /// **It used to sit in the health line at the top of the window, above the
    /// board, and say "Clear this window".** Both halves were wrong once the
    /// board arrived. From up there it read as the control for the board
    /// underneath it — the owner said so — and "this window" named the one thing
    /// on screen it does not touch. It now sits on the conversation it clears,
    /// and says which of the two things it is.
    ///
    /// The reassurance stays. What is on screen looks exactly like their phone's
    /// conversation, so "clear" invites precisely the fear it should answer —
    /// and an app that could delete a person's chat history because they tidied
    /// a window would deserve it. This one cannot: it empties its own record and
    /// never writes to the messages.
    ///
    /// The sentence is dropped, not truncated, when the window is too narrow for
    /// it. Half a promise is worse than none, and the hint below keeps it for
    /// VoiceOver either way.
    private var clearControl: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: s4) {
                clearNote
                clearButton
            }
            clearButton
        }
    }

    private var clearNote: some View {
        Text("Clearing here changes nothing on your phone.")
            .mynahFont(.label)
            .foregroundStyle(Palette.ink.secondary)
            .lineLimit(1)
    }

    /// Names the thing it clears. "This window" was ambiguous the moment the
    /// window held two things.
    private var clearButton: some View {
        MynahButton("Clear the conversation", kind: .quiet) { clearWindow() }
            .accessibilityHint("Clears the conversation shown here. "
                + "Your phone keeps it, and your tasks are untouched.")
    }

    /// Both halves of what is on screen: the turns typed here, and the window's
    /// own record of the conversation. Neither reaches the phone.
    private func clearWindow() {
        model.clear()
        record.clear()
    }

    private static let pausedHealth = ConversationModel.Health(
        tone: .neutral,
        title: "Sleeping",
        detail: "it won't answer until you start it again"
    )

    private var presence: AppModel.Presence {
        if model.isBusy { return .answering }
        if case .ready = model.readiness { return .listening }
        if case .blocked = model.readiness { return .needsOwner }
        return .sleeping
    }

    // MARK: Conversation

    @ViewBuilder
    private var conversation: some View {
        // Nothing said on the phone *and* nothing asked here. A fresh install
        // has no saved conversation at all, which is not a failure and must not
        // be drawn as one — see `emptyMessage`.
        if record.messages.isEmpty && model.exchanges.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                // The conversation's own heading, and the home of its Clear.
                // Two things share this window now, and the only way an owner
                // can tell which control belongs to which is for the control to
                // sit on it and say its name.
                HStack(spacing: s3) {
                    Text("Conversation")
                        .mynahFont(.title3)
                        .foregroundStyle(Palette.ink.primary)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: s5)
                    if canClear { clearControl }
                }
                .padding(.horizontal, s8)
                .padding(.top, s4)
                .padding(.bottom, s2)
                transcript
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            EmptyState(glyph: emptyGlyph, title: emptyTitle, message: emptyMessage)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, s8)
    }

    private var emptyGlyph: String { app.isPaused ? "moon" : "waveform" }

    private var emptyTitle: String {
        if app.isPaused { return "Mynah is sleeping" }
        return model.trouble == nil ? "Say something to Mynah" : "Almost there"
    }

    /// An empty state must never promise something the screen below it is
    /// currently blocking, so the copy follows readiness rather than assuming it.
    private var emptyMessage: String {
        if app.isPaused {
            return "It won't answer your phone, or this window, until you start it again."
        }
        if model.trouble != nil {
            return "Finish the one step below and Mynah will be ready to answer."
        }
        // Teaching, not greeting.
        //
        // "Say something to Mynah" told the owner nothing they did not already
        // know from the box below it, and the twenty seconds it promised was
        // measured against a local model on other hardware. This is the one
        // screen every owner sees and nobody reads twice, so it says the two
        // things that are not obvious: the phone is the real way in, and it
        // remembers.
        return "Send it a voice note from your phone — that is what it is for, and its "
            + "answer appears here too. It remembers what you tell it, so you can pick up "
            + "where you left off."
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: s8) {
                    ForEach(timeline) { entry in
                        if let label = entry.label {
                            ConversationSourceLabel(text: label)
                        }
                        switch entry.item {
                        case .earlier(let exchange):
                            TranscriptExchangeView(exchange: exchange, inset: Self.cardInset)
                        case .here(let exchange):
                            ExchangeView(
                                exchange: exchange,
                                inset: Self.cardInset,
                                answerWidth: Self.answerWidth,
                                showsFirstTurnHint: !model.hasEverAnswered,
                                onStop: { model.stop() },
                                onRetry: { model.retry(exchange.id) }
                            )
                            .id(exchange.id)
                        case .arrived(let arrival):
                            AgentArrivalCard(
                                arrival: arrival,
                                inset: Self.cardInset,
                                onDismiss: { model.dismissArrival(arrival.id) }
                            )
                        }
                    }
                    // Typed while it was thinking, not yet asked.
                    //
                    // Drawn as real cards rather than a "3 queued" counter,
                    // because the owner needs to see *which* sentences are
                    // waiting — that is the difference between trusting the
                    // queue and retyping into it. Dimmed, and with one caption
                    // for the group, so a stack of them cannot be mistaken for
                    // questions already answered.
                    if !model.queued.isEmpty {
                        VStack(alignment: .trailing, spacing: s4) {
                            ForEach(Array(model.queued.enumerated()), id: \.offset) { _, text in
                                AskedCard(text: text, at: nil, inset: Self.cardInset)
                            }
                            HStack(spacing: 0) {
                                Spacer(minLength: Self.cardInset)
                                Text(
                                    model.queued.count == 1
                                        ? "Waiting — goes when this answer lands."
                                        : "Waiting — these \(model.queued.count) go together when this answer lands."
                                )
                                .mynahFont(.label)
                                .foregroundStyle(Palette.ink.tertiary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .opacity(0.6)
                    }

                    // A zero-height anchor rather than scrolling to the last
                    // exchange: an answer that is still growing would otherwise
                    // pin its own top edge and scroll the owner backwards.
                    //
                    // It doubles as the "are they at the bottom?" sensor. In a
                    // lazy stack a row that is off screen is not built, so the
                    // anchor appearing and disappearing is exactly the question
                    // being asked — and it costs no measurement code.
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchor)
                        .onAppear { isAtBottom = true }
                        .onDisappear { isAtBottom = false }
                }
                .frame(maxWidth: Self.column, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, s8)
                .padding(.vertical, s7)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                // No animation on first appear. Returning to the pane should
                // look as though it was never left.
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
            .onChange(of: model.exchanges) { _, _ in
                // The owner did this themselves a moment ago, so following it
                // down is what they are expecting.
                withAnimation(Motion.snap) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
            .onChange(of: record.messages) { _, _ in
                // Nobody asked this window for this message — it arrived from
                // the phone while the owner may well have been reading
                // something further up. Follow it only if they were already at
                // the bottom, where new messages are what they are watching for.
                guard isAtBottom else { return }
                withAnimation(Motion.snap) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
        }
    }

    // MARK: One conversation, in the order it happened

    /// Something said, from either side, with the time it was said.
    ///
    /// **The two halves used to be two blocks and that is the bug the owner
    /// found.** The phone's messages were drawn as one run and the window's as
    /// another, and a heuristic decided which run went on top — so a `//call`
    /// from 19:01 sat underneath an answer from 19:11, and the next question at
    /// 19:12 underneath that. Every message on that screen was in the wrong
    /// place relative to half the others.
    ///
    /// It was invisible until the messages carried times, which is the useful
    /// part: the timestamps he asked for so he could measure the model's speed
    /// exposed an ordering fault nobody could see. The block layout was always
    /// wrong; it was only ever *arguably* wrong while the evidence was missing.
    enum TranscriptItem: Identifiable {
        case earlier(TranscriptExchange)
        case here(Exchange)
        /// A reply from another agent, which belongs to nobody's question.
        case arrived(ConversationModel.AgentArrival)

        var id: String {
            switch self {
            case .earlier(let exchange): return "earlier-\(exchange.id)"
            case .here(let exchange): return "here-\(exchange.id)"
            case .arrived(let arrival): return "arrived-\(arrival.id)"
            }
        }

        /// When this exchange started, when that is known.
        ///
        /// The *earliest* time in a restored exchange rather than the latest: an
        /// exchange is placed by when it began, so a long answer cannot push its
        /// own question below something said while it was still being written.
        var at: Date? {
            switch self {
            case .here(let exchange):
                return exchange.askedAt
            case .earlier(let exchange):
                return (exchange.asked + exchange.answered).compactMap(\.at).min()
            case .arrived(let arrival):
                return arrival.at
            }
        }
    }

    /// A transcript entry: the thing to draw, and the label above it when the
    /// conversation changes hands.
    struct TranscriptEntry: Identifiable {
        let item: TranscriptItem
        /// Set only where the source changes, so a conversation that moves
        /// between the phone and the window says so at each handover instead of
        /// once at a seam that no longer exists.
        let label: String?
        var id: String { item.id }
    }

    /// Both sides merged into the order they actually happened.
    ///
    /// **Messages with no time go first, and that is not a fallback.** A missing
    /// stamp means the message was written before the store recorded them — see
    /// `ConversationStore.StoredTurn.at` — so it is genuinely older than
    /// everything that has one. Sorting them to the top is the true answer
    /// rather than the convenient one.
    ///
    /// Sorted on `(time, original position)` rather than time alone, because
    /// Swift's sort is not stable: two things said in the same second would
    /// otherwise be free to swap on every redraw, and a transcript that
    /// reshuffles while it is being read is worse than one in the wrong order.
    var timeline: [TranscriptEntry] {
        var items: [TranscriptItem] = TranscriptExchange.group(record.messages).map { .earlier($0) }
        items.append(contentsOf: model.exchanges.map { .here($0) })
        // Placed by when they arrived, like everything else, so a reply that
        // came back during a long answer sits where it happened rather than at
        // the end.
        items.append(contentsOf: model.arrivals.map { .arrived($0) })

        let ordered = items.enumerated()
            .sorted { first, second in
                switch (first.element.at, second.element.at) {
                case let (lhs?, rhs?):
                    return lhs == rhs ? first.offset < second.offset : lhs < rhs
                // Undated is older than dated; two undated keep their order.
                case (nil, _?): return true
                case (_?, nil): return false
                case (nil, nil): return first.offset < second.offset
                }
            }
            .map(\.element)

        // No labels any more, and the reason is the point of the change: these
        // used to be two conversations on one screen — the phone's and this
        // window's — and the owner could not tell them apart without being
        // told. There is one conversation here now. `.earlier` and `.here`
        // differ only in whether a turn was read off disk at launch or happened
        // while the window has been open, which is not a distinction anybody
        // needs a divider for.
        return ordered.map { TranscriptEntry(item: $0, label: nil) }
    }

    private static let bottomAnchor = "mynah.transcript.bottom"

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: 0) {
            MynahDivider()
            composerContent
                .frame(maxWidth: Self.column)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, s8)
                .padding(.vertical, s6)
        }
        .background(Palette.surface.canvas)
    }

    @ViewBuilder
    private var composerContent: some View {
        if app.isPaused {
            HStack(spacing: s5) {
                Text("Mynah is paused, so it isn't answering anything.")
                    .mynahFont(.body)
                    .foregroundStyle(Palette.ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: s5)
                MynahButton("Start answering", kind: .secondary) { app.isPaused = false }
            }
        } else {
            VStack(alignment: .leading, spacing: s3) {
                // Above the composer, never instead of it.
                //
                // This branch used to REPLACE the field, so a blocked brain left
                // the owner with no field, no Send and no retry — only "Quit
                // Mynah and open it again". And `memoryUnreachable` carries no
                // action title, so `InlineBanner` drew no button either: a dead
                // end with instructions to restart the app.
                //
                // It also became far more reachable when `prepare()` started
                // running a multi-gigabyte local install, which throws
                // `unreachable` on any failure. Taking the composer away is the
                // one response that guarantees the owner cannot try again.
                if let trouble = model.trouble {
                    InlineBanner(
                        tone: trouble.isSevere ? .critical : .info,
                        headline: trouble.headline,
                        explanation: trouble.explanation,
                        actionTitle: troubleActionTitle(trouble),
                        action: troubleAction(trouble)
                    )
                }
                field
                if !model.canHoldToTalk {
                    Text("You can also send Mynah a voice note from your phone — the answer "
                        + "appears here too.")
                        .mynahFont(.callout)
                        .foregroundStyle(Palette.ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// What the banner's button says, honouring `canRetry`.
    ///
    /// `Trouble` has carried `canRetry` since it was written and no view ever
    /// read it, so a recoverable failure offered the same "open Settings" as an
    /// unrecoverable one — or, when there was no settings action either, no
    /// button at all.
    private func troubleActionTitle(_ trouble: Exchange.Failure) -> String? {
        if trouble.canRetry { return "Try again" }
        return onOpenSettings == nil ? nil : trouble.settingsActionTitle
    }

    private func troubleAction(_ trouble: Exchange.Failure) -> (() -> Void)? {
        if trouble.canRetry {
            // `reconnect()` already exists and already does the right thing; it
            // simply had no caller from here.
            return { Task { await model.reconnect() } }
        }
        return onOpenSettings
    }

    private var field: some View {
        @Bindable var model = model
        return HStack(alignment: .center, spacing: s4) {
            if model.isRecording {
                Waveform(level: model.micLevel, isActive: true)
                Spacer(minLength: s4)
                Text("Release to send")
                    .mynahFont(.callout)
                    .foregroundStyle(Palette.ink.secondary)
            } else {
                TextField("Ask Mynah something…", text: $model.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .mynahFont(.body)
                    .foregroundStyle(Palette.ink.primary)
                    .lineLimit(1...6)
                    .focused($isComposerFocused)
                    // Return sends, Shift-Return starts a new line. A growing
                    // field needs this intercept: with a vertical axis the field
                    // swallows Return as a newline, so the one key everybody
                    // presses to send would silently do nothing else.
                    .onKeyPress(keys: [.return], phases: .down) { press in
                        guard press.modifiers.isEmpty else { return .ignored }
                        send()
                        return .handled
                    }
                // Typing stays open during a turn — only sending waits. Locking
                // the field for twenty seconds would make the app feel seized.
                //
                // "Waking up…" during start-up rather than a silent dead Send:
                // a cold start runs an environment probe and a handshake, and a
                // turn queued into a half-built engine used to come back as
                // "Mynah couldn't finish that" on the owner's very first
                // question.
                // Mic to the left of Send, which is the owner's instruction and
                // the arrangement every messaging app on his phone uses. It
                // used to sit *outside* the composer well entirely, to the
                // right of it, which put the least familiar control in the most
                // prominent position and left Send looking like a label.
                //
                // Still absent rather than disabled when nothing can
                // transcribe — `voice` built that deliberately and an icon
                // makes greying-out tempting. A control that cannot lead
                // anywhere does not ship.
                if model.canHoldToTalk {
                    HoldToTalkButton(
                        isRecording: model.isRecording,
                        onBegin: { model.beginRecording() },
                        onEnd: { model.endRecording() }
                    )
                }
                MynahButton(
                    model.isWakingUp ? "Waking up…" : "Send",
                    kind: .primary,
                    isEnabled: model.canSend,
                    action: send
                )
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        // **`.center`, not `.bottom`, and this is the "text starts a line down"
        // the owner reported.**
        //
        // The row is bottom-aligned so the buttons sit on the last line of a
        // grown draft. But `minHeight: 28` is taller than one line of `.body`,
        // so with a single line — which is almost always — the text was pushed
        // to the *bottom* of the box and all the slack appeared above it. It
        // read as a blank first line, because that is exactly what it looked
        // like.
        //
        // Centring costs the multi-line case a little: at six lines the buttons
        // sit at the middle rather than the last line. That is the rarer state
        // and the smaller wrong, and it is the trade a Mac text field makes
        // too.
        .frame(minHeight: 28)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Palette.surface.sunken, in: RoundedRectangle.mynah(r.card))
        .mynahBorder(r.card, borderColor)
        .overlay {
            // The focus ring. Nothing signals "this was finished" more cheaply
            // than tabbing into a field and watching focus land.
            //
            // **`Color.accentColor`, not `Palette.accent`, and the owner
            // decided it**: *"the yellow box doesn't tell us anything"*. He is
            // right, and it is the amber audit again in the control he uses
            // most. MYNAH's yellow means *a property of the product that needs
            // you* — the readiness banner, the restricted key, the paused
            // switch. A cursor resting in a field is the least eventful state a
            // control has, and giving it the loudest colour on the screen is
            // the over-signalling that had him reading a caution dot as a
            // stopped appliance.
            //
            // The system accent is what every other Mac app rings a focused
            // field with, and it is the colour *he* chose in System Settings.
            // See the note on `MynahApp`'s root: platform chrome keeps the
            // platform's accent; MYNAH's is for surfaces MYNAH draws itself.
            if isComposerFocused && !model.isRecording {
                RoundedRectangle.mynah(r.card + 3)
                    .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 3)
                    .padding(-3)
            }
        }
        .mynahAnimation(Motion.fade, value: isComposerFocused)
        .mynahAnimation(Motion.fade, value: model.isRecording)
        .onTapGesture { isComposerFocused = true }
    }

    /// Recording is the only state here that earns MYNAH's accent.
    ///
    /// These used to be two opacities of one colour — focused at 0.65, recording
    /// at 1.0 — which made a cursor resting in a field and a live microphone the
    /// same event at different volumes. They are not the same kind of thing at
    /// all: one is where you are typing, the other is the appliance listening to
    /// the room. Focus now takes the system's own ring and leaves the border
    /// alone.
    private var borderColor: Color {
        if model.isRecording { return Palette.accent.fill }
        return Palette.line.hairline
    }

    private func send() {
        model.send()
        isComposerFocused = true
    }
}

// MARK: - One exchange

/// A question and whatever came back, as one block.
///
/// The same shapes the phone's exchanges are drawn with, and the same spacing
/// inside them, because a question typed here and one sent from a phone are the
/// same act. What this one has that a mirrored exchange cannot is the middle of
/// the turn: the waiting, what the appliance did while it waited, and a failure
/// with a way out of it. None of that is recorded on the phone's side, so none
/// of it is faked there.
private struct ExchangeView: View {
    let exchange: Exchange
    let inset: CGFloat
    let answerWidth: CGFloat
    let showsFirstTurnHint: Bool
    let onStop: () -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: s4) {
            AskedCard(text: exchange.question, at: exchange.askedAt, inset: inset)
            outcome
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .mynahAnimation(Motion.snap, value: exchange.outcome)
    }

    @ViewBuilder
    private var outcome: some View {
        switch exchange.outcome {
        case .thinking:
            // In the answer's own card rather than a row of its own, so the
            // answer arrives *where the owner is already looking* instead of
            // replacing a differently shaped thing somewhere else.
            AnsweredCard(inset: inset) {
                ThinkingRow(
                    startedAt: exchange.askedAt,
                    showsFirstTurnHint: showsFirstTurnHint,
                    onStop: onStop
                )
            }
        case .answered(let answer):
            AnsweredCard(inset: inset) {
                AnsweredText(text: answer.text)
                // Between the words and the provenance line, because it is part
                // of the answer rather than a note about it: Mynah said it made
                // a document, and this is the document.
                DocumentChips(files: answer.files)
                // Unconditional now. It used to appear only when there was a
                // duration or a tool to name, so a fast answer with no tool call
                // — the ones the owner most wants to see the clock on — was the
                // one that showed nothing.
                ProvenanceRow(
                    answer: answer,
                    answeredAt: exchange.askedAt.addingTimeInterval(answer.seconds)
                )
            }
        case .failed(let failure):
            // Not in the answer card: this is a notice *about* the exchange
            // rather than something Mynah said, and dressing it as a reply would
            // put words in its mouth. `InlineBanner` carries its own tone.
            //
            // Only ever "Ask again" here — a fix that lives in Settings is named
            // in the explanation, because a button in the middle of a transcript
            // that navigates away from it would lose the owner's place.
            InlineBanner(
                tone: failure.isSevere ? .critical : .info,
                headline: failure.headline,
                explanation: failure.explanation,
                actionTitle: failure.canRetry ? "Ask again" : nil,
                action: failure.canRetry ? onRetry : nil
            )
            .frame(maxWidth: answerWidth)
        }
    }
}

// MARK: - What it did to answer

/// How long it took and what it did, quietly, at the foot of the answer it
/// belongs to.
///
/// This is the one place the window shows the appliance working rather than
/// describing it — "Looked through what it remembers" under an answer is worth
/// more than any sentence about memory. It is inside the card because it is part
/// of that answer's provenance, and it exists only for turns run here: nothing
/// about tools survives into the daemon's record, so an exchange from the phone
/// gets no such line rather than a guessed one.
private struct ProvenanceRow: View {
    let answer: Exchange.Answer
    /// When the answer landed — `askedAt` plus the turn's own measured length,
    /// so the two stamps around an exchange are exactly `seconds` apart and the
    /// owner can read the appliance's speed off the column without arithmetic.
    let answeredAt: Date

    var body: some View {
        // Baseline rather than centre: the duration is `.mono` at 12pt and the
        // phrases are `.label` at 11, so centring them would leave the row
        // visibly askew.
        HStack(alignment: .firstTextBaseline, spacing: s3) {
            Text(answeredAt.formatted(date: .omitted, time: .shortened))
                .mynahFont(.label)
                .monospacedDigit()
                .foregroundStyle(Palette.ink.tertiary)
            Text("·")
                .mynahFont(.label)
                .foregroundStyle(Palette.ink.quaternary)
            Text(MynahCopy.duration(answer.seconds))
                .mynahFont(.mono)
                .monospacedDigit()
                .foregroundStyle(Palette.ink.secondary)
            ForEach(answer.activity, id: \.self) { phrase in
                Text("·")
                    .mynahFont(.label)
                    .foregroundStyle(Palette.ink.quaternary)
                Text(phrase)
                    .mynahFont(.label)
                    .foregroundStyle(Palette.ink.secondary)
            }
        }
    }
}

// MARK: - Waiting

/// The 18–29 second wait, told honestly.
///
/// No progress bar, no percentage, no ETA and no spinner: there is nothing
/// determinate to report and a bar that crawls to 90% and stops is a lie the
/// owner only has to catch once.
private struct ThinkingRow: View {
    let startedAt: Date
    let showsFirstTurnHint: Bool
    let onStop: () -> Void

    /// Long enough that the first-turn promise ("about twenty seconds") has been
    /// given its chance before the count takes over.
    private static let hintSeconds: TimeInterval = 12

    var body: some View {
        // No greedy spacer before Stop any more. This row now sits inside the
        // card the answer will land in, and a spacer would hold that card at its
        // full width while it waits — a wide empty box, and a visible snap
        // narrower the moment a short answer arrived. Stop sits beside the words
        // it belongs to instead, which is also where the hand already is.
        HStack(alignment: .top, spacing: s5) {
            // Outside the `TimelineView` so its repeating animation is never
            // restarted by the once-a-second text update.
            ThinkingIndicator()
                .padding(.top, 6)
            TimelineView(.periodic(from: startedAt, by: 1)) { timeline in
                let elapsed = max(0, timeline.date.timeIntervalSince(startedAt))
                VStack(alignment: .leading, spacing: s2) {
                    Text(MynahCopy.thinkingLine(elapsed: elapsed))
                        .mynahFont(.body)
                        .foregroundStyle(Palette.ink.secondary)
                        // A cross-fade, never a slide: "Thinking…" becoming
                        // "Still thinking…" is reassurance, not an event.
                        .contentTransition(.opacity)
                        .mynahAnimation(Motion.fade, value: MynahCopy.thinkingLine(elapsed: elapsed))
                    Text(secondLine(elapsed))
                        .mynahFont(.callout)
                        .monospacedDigit()
                        .foregroundStyle(Palette.ink.secondary)
                        .contentTransition(.opacity)
                        .mynahAnimation(Motion.fade, value: secondLine(elapsed))
                }
            }
            // **A bordered control, not bare words.** `.quiet` is the kind used
            // for "Not now" and "Learn more" — text that leads somewhere, drawn
            // with no chrome. Here it sat alone at the right edge of a card,
            // where a word with no edge to it reads as a stray label rather than
            // the one thing on this row you can press: *"the stop button looks
            // weird"*.
            //
            // Stopping a turn in progress is also the most consequential control
            // on the screen while it is on the screen, and the only one. It can
            // afford an outline.
            MynahButton("Stop", kind: .secondary, action: onStop)
                .help("Stop this answer")
        }
    }

    /// Always present, so nothing below it moves mid-turn. Elapsed lives here in
    /// `.callout` rather than as a numeral — a big ticking readout is a stopwatch
    /// the owner is failing.
    private func secondLine(_ elapsed: TimeInterval) -> String {
        if showsFirstTurnHint, elapsed < Self.hintSeconds {
            return MynahCopy.firstTurnExpectation
        }
        let whole = Int(elapsed)
        return whole == 1 ? "1 second" : "\(whole) seconds"
    }
}

// MARK: - Hold to talk

/// Press and hold to speak, release to put the words in the field.
///
/// **A microphone glyph, on the owner's instruction**: *"make it like the mic
/// icon bro — people are used to that kind of iconography."* He is right, and
/// the previous reasoning here was wrong in a specific way worth keeping: it
/// argued that the live level meter says "listening" better than an icon of a
/// microphone. True — but that is about the *recording* state, and it decided
/// the *resting* state. At rest there is no meter, and "Hold to talk" as a
/// block of text is a control nobody has seen before sitting where every
/// messaging app on his phone puts a mic.
///
/// The meter still does the work it was right about. It appears the moment
/// recording starts, in the field, where it always did.
///
/// Hold-to-talk is a held gesture and he chose it over a toggle, so an icon has
/// to make "hold me" discoverable: hence the tooltip, and a recording state
/// that changes the glyph itself rather than only its colour.
private struct HoldToTalkButton: View {
    let isRecording: Bool
    let onBegin: () -> Void
    let onEnd: () -> Void

    @State private var isHovering = false

    var body: some View {
        // `mic.fill` while recording rather than only a colour change: the
        // filled glyph reads as "live" at a glance and survives being looked at
        // by somebody who cannot distinguish the two states by hue.
        Image(systemName: isRecording ? "mic.fill" : "mic")
            .mynahIcon(.well)
            .foregroundStyle(isRecording ? Palette.accent.ink : Palette.ink.secondary)
            // Square, and sized to the Send button beside it rather than to the
            // composer well — it lives *inside* the well now.
            .frame(width: 30, height: 30)
            .background(
                isRecording ? Palette.accent.wash : Color.clear,
                in: RoundedRectangle.mynah(r.chip)
            )
            .mynahBorder(r.chip, border)
            .mynahTooltip(
                isRecording
                    ? "Let go and Mynah types what you said."
                    : "Hold to talk. Keep holding while you speak, then let go."
            )
            .contentShape(RoundedRectangle.mynah(r.control))
            .contentShape(.focusEffect, RoundedRectangle.mynah(r.control))
            // A drag with no minimum distance is the only gesture that reports
            // both edges of a press; `onLongPressGesture` fires after a delay the
            // owner would hear as the first half-second of their sentence.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !isRecording { onBegin() } }
                    .onEnded { _ in if isRecording { onEnd() } }
            )
            .onHover { isHovering = $0 }
            .pointingHandCursor()
            .mynahAnimation(Motion.fade, value: isRecording)
            .mynahAnimation(Motion.fade, value: isHovering)
            .accessibilityLabel(isRecording ? "Release to send what you said" : "Hold to talk")
    }

    /// No border at rest. A glyph inside a field does not need a box around it,
    /// and drawing one would put a second rectangle inside the composer's own.
    private var border: Color {
        if isRecording { return Palette.accent.fill }
        return isHovering ? Palette.line.hairline : .clear
    }
}

// MARK: - Previews

/// Home as an owner with work on actually meets it: the plate first, the
/// conversation underneath.
#Preview("Home — the plate") {
    TalkPreview(
        model: TalkPreviewFixtures.empty(),
        record: TalkPreviewFixtures.earlierConversation(),
        board: TalkPreviewFixtures.plate()
    )
}

/// Nothing on the plate — which must read as "nothing to do", not as a screen
/// that failed to load. Note the Done column, which says something different
/// again: it cannot see finished work at all.
#Preview("Home — nothing on the plate") {
    TalkPreview(
        model: TalkPreviewFixtures.empty(),
        board: TaskBoardModel(board: TaskBoard())
    )
}

/// The distinction this screen exists to keep. The owner may well have twelve
/// tasks; the node is not answering, so the board says that instead of showing
/// three empty columns.
#Preview("Home — node unreachable") {
    TalkPreview(
        model: TalkPreviewFixtures.empty(),
        board: TaskBoardModel(board: nil, trouble: TaskBoardTrouble.cannotReach)
    )
}

#Preview("Talk — empty") {
    TalkPreview(model: TalkPreviewFixtures.empty())
}

#Preview("Talk — mid-turn") {
    TalkPreview(model: TalkPreviewFixtures.midTurn())
}

#Preview("Talk — long conversation") {
    TalkPreview(model: TalkPreviewFixtures.longConversation())
}

#Preview("Talk — error") {
    TalkPreview(model: TalkPreviewFixtures.error())
}

/// The screen as most owners will actually meet it: everything on it was said
/// on the phone, and nothing was typed here.
#Preview("Talk — the phone's conversation") {
    TalkPreview(
        model: TalkPreviewFixtures.empty(),
        record: TalkPreviewFixtures.earlierConversation()
    )
}

/// Both at once, which is the layout that has to prove the labels earn their
/// place: a voice note answered on the phone, then a question typed here.
#Preview("Talk — phone and window") {
    TalkPreview(
        model: TalkPreviewFixtures.midTurn(),
        record: TalkPreviewFixtures.earlierConversation()
    )
}

/// Light and dark side by side, because half of the donor app's colour bugs are
/// invisible until you look at both at once.
private struct TalkPreview: View {
    let model: ConversationModel
    /// Empty by default, and never `.shared`: a preview must not open the
    /// developer's own saved conversation and draw it in a screenshot.
    var record: WindowConversation = WindowConversation(messages: [])
    /// Likewise never `.shared` — that one would go and start a node.
    var board: TaskBoardModel = TaskBoardModel(board: TaskBoard())

    var body: some View {
        HStack(spacing: 0) {
            pane.environment(\.colorScheme, .light)
            pane.environment(\.colorScheme, .dark)
        }
        .frame(width: 1180, height: 760)
    }

    private var pane: some View {
        TalkView(model: model, record: record, board: board)
            .environment(AppModel(defaults: TalkPreviewFixtures.defaults()))
    }
}

@MainActor
private enum TalkPreviewFixtures {

    /// A throwaway suite so opening a preview never rewrites the real app's
    /// settings on this machine.
    static func defaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "mynah.talk.preview.\(UUID().uuidString)") ?? .standard
        defaults.set(true, forKey: "mynah.setupComplete")
        return defaults
    }

    static func empty() -> ConversationModel {
        ConversationModel(
            engine: SlowPreviewEngine(),
            voice: PreviewVoiceCapture(),
            readiness: .ready(destination: "Google", model: "gemini-3.6-flash", staysOnDevice: false)
        )
    }

    static func midTurn() -> ConversationModel {
        ConversationModel(
            engine: SlowPreviewEngine(),
            voice: PreviewVoiceCapture(),
            exchanges: [
                Exchange(
                    question: "What did I say I'd do about the roof?",
                    askedAt: Date(timeIntervalSinceNow: -180),
                    outcome: .answered(
                        Exchange.Answer(
                            text: "You said you'd call the roofer back after the weekend and get a "
                                + "written quote before agreeing to anything.",
                            seconds: 21,
                            activity: ["Looked through what it remembers"]
                        )
                    )
                ),
                Exchange(
                    question: "Has anything changed with the planning application?",
                    askedAt: Date(timeIntervalSinceNow: -24)
                )
            ],
            readiness: .ready(destination: "this Mac", model: "qwen3.5:4b", staysOnDevice: true)
        )
    }

    static func longConversation() -> ConversationModel {
        ConversationModel(
            engine: SlowPreviewEngine(),
            exchanges: [
                answered(
                    "Remind me what we agreed about Thursday.",
                    "Dinner at seven, and you said you'd bring the wine rather than let them buy it again.",
                    seconds: 19,
                    activity: ["Looked through what it remembers"],
                    ago: 3_600
                ),
                answered(
                    "Is that place still open on a Monday?",
                    "It is — Monday to Saturday, twelve until late. They stopped doing Sunday lunch in "
                        + "the spring.",
                    seconds: 26,
                    activity: ["Searched the web"],
                    ago: 3_200
                ),
                answered(
                    "Write that down so I don't forget the wine.",
                    "Done. I'll remind you if Thursday comes up again.",
                    seconds: 17,
                    activity: ["Wrote that down"],
                    ago: 2_900
                ),
                answered(
                    "What else is on my list for this week?",
                    "Three things: the roofer's quote, the car service on Friday morning, and calling "
                        + "your sister back about the weekend.",
                    seconds: 74,
                    activity: ["Checked your list", "Looked through what it remembers"],
                    ago: 900
                ),
                answered(
                    "Which of those can wait?",
                    "The car service is booked, so that one runs itself. The roofer and your sister "
                        + "are both waiting on you.",
                    seconds: 22,
                    activity: [],
                    ago: 120
                )
            ],
            readiness: .ready(destination: "this Mac", model: "qwen3.5:4b", staysOnDevice: true)
        )
    }

    static func error() -> ConversationModel {
        ConversationModel(
            engine: SlowPreviewEngine(),
            exchanges: [
                answered(
                    "What time did I say the car was booked in?",
                    "Friday morning at half eight, and they asked you to drop it the night before if "
                        + "you can.",
                    seconds: 20,
                    activity: ["Looked through what it remembers"],
                    ago: 600
                ),
                Exchange(
                    question: "Book me a table for four on Thursday.",
                    askedAt: Date(timeIntervalSinceNow: -40),
                    outcome: .failed(
                        ConversationModel.explain(BrainBackendErrorStub.rateLimited)
                    )
                )
            ],
            readiness: .ready(destination: "Google", model: "gemini-3.6-flash", staysOnDevice: false)
        )
    }

    /// A plate with real shapes on it: work waiting, work under way, one task
    /// another agent has picked up. No due dates and no priorities, because the
    /// node publishes neither and a preview that shows them is how they end up
    /// in the product.
    static func plate() -> TaskBoardModel {
        TaskBoardModel(
            board: TaskBoard(
                planned: [
                    BoardTask(
                        id: "1",
                        title: "Get a written quote from the roofer before agreeing anything",
                        progress: .planned,
                        domain: "house",
                        createdAt: Date(timeIntervalSinceNow: -7_200)
                    ),
                    BoardTask(
                        id: "2",
                        title: "Call your sister back about the weekend",
                        progress: .planned,
                        domain: "general",
                        createdAt: Date(timeIntervalSinceNow: -86_400)
                    )
                ],
                inProgress: [
                    BoardTask(
                        id: "3",
                        title: "Find three plumbers who work Saturdays and compare their call-out fees",
                        progress: .inProgress,
                        domain: "house",
                        carrier: .pickedUpBy("kimi-cli/errands"),
                        author: "claude-code",
                        createdAt: Date(timeIntervalSinceNow: -3_600)
                    )
                ],
                // Finished and abandoned work, both inside the seven-day window
                // so the preview shows the board an owner actually has rather
                // than the one that survives the cut.
                done: [
                    BoardTask(
                        id: "4",
                        title: "Book the car in for its service",
                        progress: .done,
                        domain: "house",
                        carrier: .completedBy("claude-code/sage"),
                        createdAt: Date(timeIntervalSinceNow: -400_000),
                        statusChangedAt: Date(timeIntervalSinceNow: -172_800)
                    )
                ],
                dropped: [
                    BoardTask(
                        id: "5",
                        title: "Look into moving the broadband to the other provider",
                        progress: .dropped,
                        domain: "house",
                        carrier: .droppedBy("claude-code/sage"),
                        createdAt: Date(timeIntervalSinceNow: -500_000),
                        statusChangedAt: Date(timeIntervalSinceNow: -259_200)
                    )
                ]
            )
        )
    }

    /// An earlier conversation restored from disk. No durations and no tool
    /// phrases, because the record keeps neither — the preview has to show the
    /// owner exactly what the screen can show.
    static func earlierConversation() -> WindowConversation {
        WindowConversation(
            messages: [
                TranscriptMessage(id: 0, speaker: .owner, text: "remind me what the roofer said"),
                TranscriptMessage(
                    id: 1,
                    speaker: .mynah,
                    text: "He quoted two and a half thousand for the whole roof and said he could "
                        + "start the week after next. You told him you wanted it in writing first."
                ),
                TranscriptMessage(id: 2, speaker: .owner, text: "did I ever send that email"),
                // Two in a row, because people do that — and because it is the
                // case that proves the grouping: both belong to the one answer
                // below them, and the spacing has to show it.
                TranscriptMessage(id: 3, speaker: .owner, text: "the one about the quote I mean"),
                TranscriptMessage(
                    id: 4,
                    speaker: .mynah,
                    text: "Not that I know of. You asked me to remind you on Monday and it's "
                        + "Thursday, so it's probably still sitting in your drafts."
                )
            ]
        )
    }

    private static func answered(
        _ question: String,
        _ reply: String,
        seconds: TimeInterval,
        activity: [String],
        ago: TimeInterval
    ) -> Exchange {
        Exchange(
            question: question,
            askedAt: Date(timeIntervalSinceNow: -ago),
            outcome: .answered(Exchange.Answer(text: reply, seconds: seconds, activity: activity))
        )
    }
}

/// Real failure translation in the preview rather than hand-written copy, so a
/// change to `explain(_:)` shows up here instead of silently drifting.
private enum BrainBackendErrorStub {
    static let rateLimited = SageVoiceCore.BrainBackendError.rateLimited(
        provider: "Google",
        retryAfterSeconds: nil
    )
}

/// Answers after a realistic wait, so the preview exercises the same waiting
/// state the owner sees rather than a mock of it.
private struct SlowPreviewEngine: TurnEngine {
    func prepare() async throws {}

    func run(transcript: String, history: [BrainMessage]) async throws -> TurnResult {
        try await Task.sleep(nanoseconds: 21_000_000_000)
        return TurnResult(
            reply: "That would normally be a real answer, put together from what Mynah remembers "
                + "about you.",
            toolNames: ["sage_recall", "web_search"],
            seconds: 21,
            messages: [.user(transcript), .assistant("…")]
        )
    }
}

/// Enough of a capture to see the hold-to-talk control work end to end.
@MainActor
private final class PreviewVoiceCapture: VoiceCapture {
    private var startedAt: Date?

    var level: Double {
        guard let startedAt else { return 0 }
        let phase = Date().timeIntervalSince(startedAt) * 3
        return 0.35 + (sin(phase) + 1) / 2 * 0.5
    }

    func begin() async throws { startedAt = Date() }

    func finish() async throws -> String {
        startedAt = nil
        return "what did I say about the roof"
    }

    func cancel() { startedAt = nil }
}
