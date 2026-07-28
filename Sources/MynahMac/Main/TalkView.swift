import SageVoiceCore
import SwiftUI

// MARK: - Talk

/// Where the owner spends their time.
///
/// Three regions and nothing else: one line of health, the conversation, and the
/// place to say something. No metric tiles, no session counters, no chart of how
/// many memories exist — this is a conversation, and every pixel that is not the
/// conversation is competing with it.
///
/// The conversation shown is the *real* one — the Signal thread the appliance
/// answers, accumulated from the daemon's own record by `ConversationMirror`. It
/// used to be this window's private chat, which made the screen a second source
/// of truth that knew nothing about the voice note the owner sent ten minutes
/// ago and had answered on their phone. Typing here still works and its turns
/// are appended below, labelled, so the two are never mistaken for one another.
///
/// Nothing on this screen can reach the phone. Clearing empties the window's own
/// record and leaves every message where it is, which is what the line beside
/// the button says — and the reverse holds too: a thread cleared on the phone,
/// or expired by the appliance, does not take this screen's copy with it.
@MainActor
struct TalkView: View {

    /// The transcript column.
    ///
    /// Wider than the 460pt prose cap because the layout alternates sides: a
    /// question hugs the right edge and an answer the left, so both margins are
    /// used and neither line ever runs the full width.
    private static let column: CGFloat = 640
    private static let answerWidth: CGFloat = 520
    /// How much of the column a question may never occupy. Guarantees the
    /// asymmetry survives even a one-word question, which is what stops the
    /// transcript reading as a single ragged left margin.
    private static let questionInset: CGFloat = 120

    let model: ConversationModel
    /// The conversation as it happened on the phone. Read-only, and re-read
    /// while this pane is on screen.
    let mirror: ConversationMirror
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
        mirror: ConversationMirror? = nil,
        onOpenSettings: (() -> Void)? = nil
    ) {
        self.model = model ?? .shared
        self.mirror = mirror ?? .shared
        self.onOpenSettings = onOpenSettings
    }

    var body: some View {
        VStack(spacing: 0) {
            healthLine
            MynahDivider()
            conversation
            composer
        }
        .background(Palette.surface.canvas)
        .task {
            await model.connect()
            app.presence = presence
        }
        // Its own task, so the poll starts while the engine is still connecting
        // — the phone's conversation is on disk already and has nothing to wait
        // for. Cancelled with the pane, so nothing polls from Settings.
        .task { await mirror.follow() }
        .onChange(of: model.isBusy) { _, _ in app.presence = presence }
        .onChange(of: model.readiness) { _, _ in app.presence = presence }
    }

    // MARK: Health

    /// One line. A grid of status cards is a control panel, and the owner did
    /// not buy a control panel.
    private var healthLine: some View {
        let health = app.isPaused ? Self.pausedHealth : model.health
        return HStack(spacing: s3) {
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
            Spacer(minLength: s5)
            if canClear { clearControl }
        }
        .padding(.horizontal, s8)
        .padding(.vertical, s5)
        .mynahAnimation(Motion.fade, value: health)
    }

    private var canClear: Bool { !model.exchanges.isEmpty || !mirror.messages.isEmpty }

    /// The button, and the one thing the owner needs to know before pressing it.
    ///
    /// Said here rather than in a confirmation sheet. What is on screen looks
    /// exactly like their phone's conversation, so "clear" invites precisely the
    /// fear it should answer — and an app that could delete a person's chat
    /// history because they tidied a window would deserve it. This one cannot:
    /// it empties its own record and never writes to the messages.
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

    private var clearButton: some View {
        MynahButton("Clear this window", kind: .quiet) { clearWindow() }
            .accessibilityHint("Clears this window only. Your phone keeps the conversation.")
    }

    /// Both halves of what is on screen: the turns typed here, and the window's
    /// own record of the conversation. Neither reaches the phone.
    private func clearWindow() {
        model.clear()
        mirror.clear()
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
        if mirror.messages.isEmpty && model.exchanges.isEmpty {
            emptyState
        } else {
            transcript
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
                    if phoneComesFirst {
                        phoneConversation
                        typedHere
                    } else {
                        typedHere
                        phoneConversation
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
            .onChange(of: mirror.messages) { _, _ in
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

    /// The Signal thread, oldest message at the top.
    ///
    /// Labelled whenever there is anything to show, because "this came off your
    /// phone" is the fact that makes the screen make sense — it is the reason an
    /// answer the owner has never seen in this window is sitting in it.
    @ViewBuilder
    private var phoneConversation: some View {
        if !mirror.messages.isEmpty {
            ConversationSourceLabel(text: "From your phone")
            ForEach(mirror.messages) { message in
                switch message.speaker {
                case .owner:
                    OwnerMessage(text: message.text, inset: Self.questionInset)
                case .mynah:
                    MynahMessage(text: message.text, maxWidth: Self.answerWidth)
                }
            }
        }
    }

    /// What the owner has asked in this window, with the waiting and failure
    /// states the phone's record cannot carry.
    ///
    /// Labelled only when the phone's conversation is also on screen. On its own
    /// it needs no explanation — the composer is directly underneath it.
    @ViewBuilder
    private var typedHere: some View {
        if !model.exchanges.isEmpty {
            if !mirror.messages.isEmpty {
                ConversationSourceLabel(text: "In this window")
            }
            ForEach(model.exchanges) { exchange in
                ExchangeView(
                    exchange: exchange,
                    questionInset: Self.questionInset,
                    answerWidth: Self.answerWidth,
                    showsFirstTurnHint: !model.hasEverAnswered,
                    onStop: { model.stop() },
                    onRetry: { model.retry(exchange.id) }
                )
                .id(exchange.id)
            }
        }
    }

    /// Which block sits at the bottom, decided on the only two times that are
    /// real: when the saved conversation was last spoken in, and when the owner
    /// last asked something here.
    ///
    /// Newest at the bottom is what every messaging app does and what the eye
    /// expects. Pinning the phone above the window permanently would have been
    /// simpler and would put a message from a moment ago above one from an hour
    /// before it, which is the one thing a transcript may not do.
    private var phoneComesFirst: Bool {
        guard let lastAskedHere = model.exchanges.last?.askedAt,
              let lastSpokenOnPhone = mirror.lastActivity else { return true }
        return lastSpokenOnPhone <= lastAskedHere
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
                        tone: trouble.isSevere ? .critical : .caution,
                        headline: trouble.headline,
                        explanation: trouble.explanation,
                        actionTitle: troubleActionTitle(trouble),
                        action: troubleAction(trouble)
                    )
                }
                HStack(alignment: .bottom, spacing: s4) {
                    field
                    if model.canHoldToTalk {
                        HoldToTalkButton(
                            isRecording: model.isRecording,
                            onBegin: { model.beginRecording() },
                            onEnd: { model.endRecording() }
                        )
                    }
                }
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
        return HStack(alignment: .bottom, spacing: s4) {
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
                MynahButton(
                    model.isWakingUp ? "Waking up…" : "Send",
                    kind: .quiet,
                    isEnabled: model.canSend,
                    action: send
                )
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        // Both states are the same height, so starting to speak never nudges the
        // transcript above it.
        .frame(minHeight: 28)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Palette.surface.sunken, in: RoundedRectangle.mynah(r.card))
        .mynahBorder(r.card, borderColor)
        .overlay {
            // The focus ring. Nothing signals "this was finished" more cheaply
            // than tabbing into a field and watching focus land.
            if isComposerFocused && !model.isRecording {
                RoundedRectangle.mynah(r.card + 3)
                    .strokeBorder(Palette.accent.fill.opacity(0.30), lineWidth: 3)
                    .padding(-3)
            }
        }
        .mynahAnimation(Motion.fade, value: isComposerFocused)
        .mynahAnimation(Motion.fade, value: model.isRecording)
        .onTapGesture { isComposerFocused = true }
    }

    private var borderColor: Color {
        if model.isRecording { return Palette.accent.fill }
        return isComposerFocused ? Palette.accent.fill.opacity(0.65) : Palette.line.hairline
    }

    private func send() {
        model.send()
        isComposerFocused = true
    }
}

// MARK: - One exchange

/// A question and whatever came back, as one block.
private struct ExchangeView: View {
    let exchange: Exchange
    let questionInset: CGFloat
    let answerWidth: CGFloat
    let showsFirstTurnHint: Bool
    let onStop: () -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: s5) {
            // The same bubble the mirrored thread draws, deliberately: a
            // question typed here and one sent from the phone are the same act,
            // and two hand-written copies of one shape drift the first time
            // either is touched.
            OwnerMessage(text: exchange.question, inset: questionInset)
            outcome
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .mynahAnimation(Motion.snap, value: exchange.outcome)
    }

    @ViewBuilder
    private var outcome: some View {
        switch exchange.outcome {
        case .thinking:
            ThinkingRow(
                startedAt: exchange.askedAt,
                showsFirstTurnHint: showsFirstTurnHint,
                onStop: onStop
            )
        case .answered(let answer):
            AnswerBlock(answer: answer, maxWidth: answerWidth)
        case .failed(let failure):
            // Only ever "Ask again" here: a fix that lives in Settings is named
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

// MARK: - Answer

private struct AnswerBlock: View {
    let answer: Exchange.Answer
    let maxWidth: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: s3) {
            MynahMessage(text: answer.text, maxWidth: maxWidth)
            provenance
        }
    }

    /// How long it took and what it did, quietly. The owner learns what normal
    /// looks like without ever being shown a tool name.
    private var provenance: some View {
        // Baseline rather than centre: the duration is `.mono` at 12pt and the
        // phrases are `.label` at 11, so centring them would leave the row
        // visibly askew.
        HStack(alignment: .firstTextBaseline, spacing: s3) {
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
        HStack(alignment: .top, spacing: s4) {
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
            Spacer(minLength: s5)
            MynahButton("Stop", kind: .quiet, action: onStop)
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
/// Not round: `Circle()` in MYNAH is reserved for the hero glyph and status
/// dots. Not carrying a microphone glyph either — the live level meter beside it
/// says "listening" far better than an icon of a microphone does.
private struct HoldToTalkButton: View {
    let isRecording: Bool
    let onBegin: () -> Void
    let onEnd: () -> Void

    @State private var isHovering = false

    var body: some View {
        Text(isRecording ? "Release" : "Hold to talk")
            .mynahFont(.title3)
            .foregroundStyle(isRecording ? Palette.accent.ink : Palette.ink.primary)
            .padding(.horizontal, s6)
            // Matches the composer well exactly, so the two sit on one line.
            .frame(height: 46)
            .background(
                isRecording ? Palette.accent.wash : Palette.surface.raised,
                in: RoundedRectangle.mynah(r.control)
            )
            .mynahBorder(r.control, border)
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

    private var border: Color {
        if isRecording { return Palette.accent.fill }
        return isHovering ? Palette.line.strong : Palette.line.hairline
    }
}

// MARK: - Previews

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
        mirror: TalkPreviewFixtures.phoneConversation()
    )
}

/// Both at once, which is the layout that has to prove the labels earn their
/// place: a voice note answered on the phone, then a question typed here.
#Preview("Talk — phone and window") {
    TalkPreview(
        model: TalkPreviewFixtures.midTurn(),
        mirror: TalkPreviewFixtures.phoneConversation()
    )
}

/// Light and dark side by side, because half of the donor app's colour bugs are
/// invisible until you look at both at once.
private struct TalkPreview: View {
    let model: ConversationModel
    /// Empty by default, and never `.shared`: a preview must not open the
    /// developer's own saved conversation and draw it in a screenshot.
    var mirror: ConversationMirror = ConversationMirror(messages: [])

    var body: some View {
        HStack(spacing: 0) {
            pane.environment(\.colorScheme, .light)
            pane.environment(\.colorScheme, .dark)
        }
        .frame(width: 1180, height: 760)
    }

    private var pane: some View {
        TalkView(model: model, mirror: mirror)
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
            readiness: .ready(destination: "Google", staysOnDevice: false)
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
            readiness: .ready(destination: "this Mac", staysOnDevice: true)
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
            readiness: .ready(destination: "this Mac", staysOnDevice: true)
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
            readiness: .ready(destination: "Google", staysOnDevice: false)
        )
    }

    /// A voice note and its answer, as the daemon would have saved them. No
    /// durations and no tool phrases, because the file records neither — the
    /// preview has to show the owner exactly what the screen can show.
    static func phoneConversation() -> ConversationMirror {
        ConversationMirror(
            messages: [
                MirroredMessage(id: 0, speaker: .owner, text: "remind me what the roofer said"),
                MirroredMessage(
                    id: 1,
                    speaker: .mynah,
                    text: "He quoted two and a half thousand for the whole roof and said he could "
                        + "start the week after next. You told him you wanted it in writing first."
                ),
                MirroredMessage(id: 2, speaker: .owner, text: "did I ever send that email"),
                MirroredMessage(
                    id: 3,
                    speaker: .mynah,
                    text: "Not that I know of. You asked me to remind you on Monday and it's "
                        + "Thursday, so it's probably still sitting in your drafts."
                )
            ],
            lastActivity: Date(timeIntervalSinceNow: -600)
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
