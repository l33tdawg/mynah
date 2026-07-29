import AppKit
import SageVoiceCore
import SwiftUI

// MARK: - Root

/// The window's whole content: onboarding, or the app.
///
/// Owns `SetupModel`, which is the only object that talks to `SageVoiceCore`
/// during first run. Nothing below here decides *which* screen to show — that
/// is `SetupModel.stage`, and `SetupModel.stage` advances only when the owner
/// presses something.
struct RootView: View {
    let appDelegate: MynahAppDelegate

    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ZStack {
            if app.hasCompletedSetup {
                MainShell()
            } else {
                OnboardingHost { setup in
                    // The one moment the owner's brain choice becomes permanent.
                    // Persisted here rather than when the card is clicked, so a
                    // selection the owner backed out of never becomes the thing
                    // that answers their phone.
                    if let option = setup.selectedOption {
                        BrainSelectionStore.save(option)
                    }
                    app.completeSetup()
                }
                // Identity, not decoration: a restart mints a new run ID, which
                // makes SwiftUI discard the finished `SetupModel` below and build
                // a fresh one. Without it, "Change where your words go" reopens
                // the flow on its own last screen.
                .id(app.setupRunID)
            }
        }
        .frame(minWidth: 980, minHeight: 640)
        .background(Palette.surface.canvas)
        .mynahAnimation(Motion.snap, value: app.hasCompletedSetup)
        .configureWindow { window in
            window.backgroundColor = Palette.surface.canvasNSColor
            // The sidebar carries the app's identity; a repeated title in the
            // titlebar is a second, worse wordmark. Both the flag and the string
            // are cleared: SwiftUI re-applies the scene's title when its toolbar
            // changes, which puts "Mynah" back beside the traffic lights on the
            // first stage advance if only `titleVisibility` is set.
            window.titleVisibility = .hidden
            window.title = ""
            // Verified on this machine: quitting with the window closed makes
            // macOS restore "no windows", and because MYNAH does not terminate
            // when its last window closes, the next launch produces a running
            // app with nothing on screen. There is no per-window state here
            // worth restoring, so restoration is simply off.
            window.isRestorable = false
            // A stage screen under a titlebar strip looks like a wizard; the
            // canvas running to the top edge with the traffic lights floating on
            // it looks like an app introducing itself. Post-setup the strip comes
            // back, because that is where the toolbar lives.
            window.titlebarAppearsTransparent = true

            // Set once and never cleared. Toggling `.fullSizeContentView` off
            // again preserves the *content* size and therefore grows the window
            // frame by the titlebar height every time — measured here as 820 →
            // 872 → 904 across two transitions. Leaving it on is also the right
            // look on both sides: the stage canvas reaches the top edge, and
            // afterwards the sidebar runs under the toolbar the way Mail's and
            // Notes' do.
            if !window.styleMask.contains(.fullSizeContentView) {
                window.styleMask.insert(.fullSizeContentView)
            }

            // Dragging a memory list must not drag the window; dragging an empty
            // stage should.
            window.isMovableByWindowBackground = !app.hasCompletedSetup
        }
        .onAppear {
            // `openWindow` only exists inside a scene, and the delegate outlives
            // every scene, so the reopen path is wired from here.
            appDelegate.openMainWindow = { openWindow(id: MynahWindowID.main) }
            // Same seam, same reason: the floating panel outlives this window
            // and has to read the live `AppModel`, which the scene owns. It is
            // this call that makes "keeps answering when this window is closed"
            // something the owner can watch rather than only read about.
            FloatingHUDController.shared.attach(app: app)
            // Relaunch is reconciliation, not a special case. If the owner
            // linked Signal on the previous run, the two LaunchAgents are
            // restored here without another button or QR scan.
            Task { await app.reconcileAnsweringService() }
        }
    }
}

// MARK: - Onboarding

/// Owns exactly one *run* of setup.
///
/// The state machine lives here rather than in `RootView` so that its lifetime
/// is the run's lifetime. `RootView` gives this view an identity that changes on
/// every restart, and SwiftUI does the rest.
private struct OnboardingHost: View {
    /// Handed the model that just finished, because what the owner chose is only
    /// worth persisting at the moment they commit to it.
    let onFinished: (SetupModel) -> Void

    @State private var setup = SetupModel()

    var body: some View {
        OnboardingFlow(model: setup) { onFinished(setup) }
    }
}

/// The five stages, in the order `SetupModel.Stage.allCases` declares and no
/// other. What happens to be installed on this Mac may disable a Continue
/// button; it may never choose the screen.
struct OnboardingFlow: View {
    @Bindable var model: SetupModel
    let onFinished: () -> Void

    @Environment(AppModel.self) private var app

    private var stageTitles: [String] {
        SetupModel.Stage.allCases.map(\.title)
    }

    var body: some View {
        ZStack {
            stage
                .id(model.stage)
                .mynahStageTransition()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.surface.canvas)
        // The canvas has to reach the top edge of the window, not stop at the
        // titlebar's safe area, or the stage sits under a white strip and reads
        // as a wizard sheet. Both halves are needed: hiding the toolbar backdrop
        // and giving up the inset it reserves.
        .toolbarBackground(.hidden, for: .windowToolbar)
        .ignoresSafeArea(.container, edges: .top)
        // Declarative, and therefore re-applied on every stage advance. Setting
        // `NSWindow.titleVisibility` from `RootView` is not enough on its own:
        // `RootView` does not observe `model.stage`, so it never re-renders, and
        // SwiftUI puts the title back when the stage's toolbar changes.
        .navigationTitle("")
        .mynahAnimation(Motion.snap, value: model.stage)
        .task {
            // Runs behind the welcome screen so the brain stage is never a
            // spinner the owner sits and watches.
            if model.choices == nil { await model.probe() }
        }
    }

    @ViewBuilder
    private var stage: some View {
        switch model.stage {
        case .welcome:
            WelcomeStage(titles: stageTitles, model: model)
        case .brain:
            BrainStage(titles: stageTitles, model: model)
        case .key:
            ConnectKeyView(titles: stageTitles, model: model, app: app)
        case .ready:
            ReadyStage(titles: stageTitles, model: model, app: app, onFinished: onFinished)
        }
    }
}

// Stages 1 to 3 live in `Setup/WelcomeView.swift`, `Setup/BrainPickerView.swift`
// and `Setup/ConnectKeyView.swift`. They keep the initialiser shapes this file
// switches on — `init(titles:model:)`, and `init(titles:model:app:)` where a
// stage has something to hand back to Settings — and nothing else about them is
// this file's business.
//
// `Setup/SignalLinkView.swift` is no longer among them. `SignalLinkStage` still
// exists and is unchanged; it is simply not on the way in any more. The Ready
// screen offers it, and Settings keeps it — see `SetupModel.Stage` for why an
// optional add-on stopped being the fourth of five screens.

/// Stage 5. Restates what the owner just decided, in their words, and hands over.
///
/// It reads `AppModel.deferredSetupSteps` rather than assuming success. Saying
/// "Mynah is ready" to someone who pressed "Not now" on the key screen thirty
/// seconds earlier is a promise the very next screen breaks — and the value
/// beside "Answering with this window closed" is read from the setting rather
/// than hardcoded, for the same reason.
struct ReadyStage: View {
    let titles: [String]
    @Bindable var model: SetupModel
    let app: AppModel
    let onFinished: () -> Void

    @State private var isLinkingPhone = false

    private var unfinished: [AppModel.DeferredStep] { app.deferredSetupSteps }

    var body: some View {
        StageShell(
            stageTitles: titles,
            currentIndex: SetupModel.Stage.ready.rawValue,
            // The drawing is the end of the setup story — a machine settled and
            // listening — and it is only true when there is nothing left to do.
            // The unfinished branch keeps a plain glyph because "one thing left"
            // is not that ending.
            glyph: unfinished.isEmpty ? StageIllustration.mark(.ready) : "iphone.gen3",
            title: unfinished.isEmpty ? "Mynah is ready." : "One thing left.",
            subtitle: subtitle
        ) {
            VStack(alignment: .leading, spacing: s4) {
                MynahCard(density: .hero) {
                    VStack(spacing: 0) {
                        StatusLine(
                            "Where your words go",
                            value: destination,
                            tone: model.selectedOption?.keepsWordsOnDevice == true ? .good : .caution
                        )
                        MynahDivider()
                        StatusLine(
                            "Answering with this window closed",
                            value: app.keepsAnsweringWhenClosed ? "On" : "Off",
                            tone: app.keepsAnsweringWhenClosed ? .good : .neutral
                        )
                        ForEach(unfinished) { step in
                            MynahDivider()
                            StatusLine(step.title, value: "Not done", tone: .caution)
                        }
                    }
                }
                phoneOffer
            }
            .frame(maxWidth: MynahWidth.stageColumn)
        } actions: {
            if unfinished.isEmpty {
                ActionRow(quietTitle: "Back", quietAction: { model.goBack() }) {
                    MynahButton("Start using Mynah", isDefault: true, action: onFinished)
                }
            } else {
                // The escape hatch is the quiet one and the commitment is
                // finishing the job — the opposite way round from every other
                // stage, because here the owner has already said "later" once.
                ActionRow(quietTitle: "I'll do it later", quietAction: onFinished) {
                    MynahButton("Finish it now", isDefault: true) { model.goBack() }
                }
            }
        }
        .sheet(isPresented: $isLinkingPhone) {
            // The same flow, in the same sheet Settings uses. Nothing about
            // linking changed — only when it is asked for.
            ReadyPhoneLinkSheet { isLinkingPhone = false }
        }
    }

    /// The phone, offered rather than demanded.
    ///
    /// This used to be the fourth of five screens, and an owner who could not
    /// scan a QR code could not finish setting up a Mac app. It is an add-on:
    /// Mynah has a conversation, a board and a memory in this window without it.
    /// So it is a card at the end that says what it would add and lets the owner
    /// take it or leave it — and the primary button beside it is still "Start
    /// using Mynah", because that is what they came to do.
    @ViewBuilder
    private var phoneOffer: some View {
        if unfinished.isEmpty {
            MynahCard {
                HStack(alignment: .top, spacing: s5) {
                    VStack(alignment: .leading, spacing: s2) {
                        Text("Talk to it from your phone as well")
                            .mynahFont(.title3)
                            .foregroundStyle(Palette.ink.primary)
                        Text("Link Signal and you can send Mynah a voice note from anywhere and "
                             + "it answers out loud. You don't need it to use Mynah here, and "
                             + "it's in Settings whenever you want it.")
                            .mynahFont(.callout)
                            .foregroundStyle(Palette.ink.secondary)
                            .mynahProse()
                    }
                    Spacer(minLength: s4)
                    MynahButton("Link my phone", kind: .secondary) { isLinkingPhone = true }
                }
            }
        }
    }

    private var subtitle: String {
        guard unfinished.isEmpty else {
            return "Mynah will answer as soon as you finish it — and it's waiting in Settings "
                + "whenever you're ready."
        }
        // Names the window first, because the window is what the owner has in
        // front of them and what they can use the moment they press the button.
        // It used to open with "send it a voice note", which described a phone
        // they had just been made to link — and once linking became optional
        // that sentence was instructions for a thing most people will not have
        // set up yet.
        return "Ask it something in the window and it will answer. The first answer takes "
            + "a moment longer than the rest."
    }

    private var destination: String {
        guard let option = model.selectedOption else { return "Not chosen yet" }
        if option.keepsWordsOnDevice { return "This Mac" }
        return MynahCopy.company(forBackend: option.backendIdentifier) ?? "A company"
    }
}

/// `SignalLinkView` in a sheet, for the offer on the Ready screen.
///
/// Deliberately a near-twin of `PhoneLinkSheet` in Settings rather than a shared
/// type: that one resolves a deferred step and reconciles the answering service
/// on the way out, and this one is on a screen where setup has not finished and
/// neither of those exists yet. Merging them would mean one sheet carrying two
/// sets of conditional side effects.
private struct ReadyPhoneLinkSheet: View {
    let onClose: () -> Void

    @State private var model = SignalLinkModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Link your phone")
                .mynahFont(.title1)
                .foregroundStyle(Palette.ink.primary)
                .accessibilityAddTraits(.isHeader)

            ScrollView {
                SignalLinkView(model: model)
                    .padding(.vertical, s6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)

            ActionRow {
                MynahButton(model.phase.isLinked ? "Done" : "Close", isDefault: true) {
                    model.stop()
                    onClose()
                }
            }
            .padding(.top, s5)
        }
        .padding(s8)
        .frame(width: 620, height: 700)
        .background(Palette.surface.overlay)
        .task { model.refresh() }
        .onDisappear { model.stop() }
        // Escape closes it. A modal with no keyboard way out is a trap, and
        // this one has nothing to confirm.
        .onExitCommand {
            model.stop()
            onClose()
        }
    }
}

// MARK: - Main shell

/// The sections in the sidebar. Order is the order they appear.
enum MainSection: String, CaseIterable, Identifiable, Hashable {
    case home
    case agents
    case memories
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .agents: return "Agents"
        case .memories: return "Memories"
        case .settings: return "Settings"
        }
    }

    /// `person.2` for agents rather than a network or a node graph. The owner's
    /// own words for this are "ask Perplexity to look it up"; they are asking
    /// somebody, and a topology diagram is the operator's picture, not theirs.
    var glyph: String {
        switch self {
        case .home: return "waveform"
        case .agents: return "person.2"
        case .memories: return "text.append"
        case .settings: return "gearshape"
        }
    }

    /// One line saying what the destination is for.
    ///
    /// Four rows of bare nouns make the owner click each one to find out what it
    /// is, and then remember. A window this wide can afford to answer the
    /// question in the place it is asked — which is the only reason this text
    /// exists. Each line is a plain statement of the pane's subject, in the same
    /// words the pane itself uses when it has a heading.
    var summary: String {
        switch self {
        case .home: return "What's on your plate"
        case .agents: return "Who Mynah can ask"
        case .memories: return "What Mynah remembers"
        case .settings: return "How Mynah is set up"
        }
    }
}

/// The app proper.
///
/// `NavigationSplitView` rather than a hand-built `HStack { sidebar; Divider();
/// content }`: it is what buys real sidebar vibrancy, the unified toolbar, the
/// sidebar toggle, the collapse animation and full-screen behaviour. The donor
/// app hand-rolls all of it and gets none of them.
struct MainShell: View {
    @Environment(AppModel.self) private var app
    @State private var selection: MainSection? = .home

    /// Held rather than left to SwiftUI, and seeded to `.all`.
    ///
    /// Left alone, the split view restores whatever state it was last in, and a
    /// window that opens with the sidebar collapsed makes every destination two
    /// clicks away — reveal the sidebar, then pick. Owning the value means the
    /// window always opens showing where you can go, and the toggle still slides
    /// it away for anyone who wants the width back.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            Sidebar(selection: $selection)
                // Primary navigation, not a settings list. Four destinations,
                // each naming itself and saying what it is for, need the width
                // to do that on two lines without wrapping mid-phrase.
                .navigationSplitViewColumnWidth(min: 248, ideal: 284, max: 340)
        } detail: {
            // The `GeometryReader` is a clamp, not a measurement.
            //
            // A detail pane sized by its own content feeds that height back into
            // the split view, and past a certain point the *sidebar* column is
            // laid out outside the window and renders blank — measured here at
            // screen y = -5, height 1356 inside an 820pt window, with the
            // accessibility tree still perfectly intact, so it looks like a
            // rendering bug rather than a layout one. The error grew with the
            // detail content's height, which is what gave it away.
            //
            // `GeometryReader` always accepts the size it is proposed and never
            // reports its content's ideal upward, so the pane can never push the
            // split view around again. It also hands every pane a definite size
            // to centre inside.
            GeometryReader { proxy in
                detail.frame(width: proxy.size.width, height: proxy.size.height)
            }
                .background(Palette.surface.canvas)
                // Exactly one toolbar control, and it is the one verb the owner
                // might want without opening a pane.
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button(app.isPaused ? "Resume" : "Pause") { app.isPaused.toggle() }
                            // A one-word toolbar button is where a Mac owner
                            // expects to hover for the sentence. Without it,
                            // "Pause" is a verb with no object — pause what?
                            .help(app.isPaused
                                  ? "Start answering your phone again"
                                  : "Stop answering until you resume")
                    }
                }
        }
        .navigationTitle("")
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .home {
        case .home: HomePane(onOpenSettings: { selection = .settings })
        case .agents: AgentsView()
        case .memories: MemoriesView()
        case .settings: SettingsView(onOpenSection: { selection = $0 })
        }
    }
}

/// The app's mark, the three sections, and one live status row at the bottom.
///
/// No version number under the wordmark — that is a developer's instinct.
/// Version belongs in Settings → About.
struct Sidebar: View {
    @Binding var selection: MainSection?
    @Environment(AppModel.self) private var app

    @State private var isHoveringStatus = false

    var body: some View {
        // The `List` is the column's root, with the identity block and status
        // row attached as safe-area insets.
        //
        // Wrapping the list in a `VStack` to stack them looks equivalent and is
        // not: measured here, the whole sidebar laid out at screen y = -5 with a
        // height of 1356pt inside an 820pt window, so every row rendered outside
        // the window and the column appeared empty while the accessibility tree
        // still listed all three sections.
        List(selection: $selection) {
            ForEach(MainSection.allCases) { section in
                row(section).tag(section)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) { identity }
        .safeAreaInset(edge: .bottom, spacing: 0) { status }
    }

    /// A destination: glyph, name, and what it is for.
    ///
    /// **Nothing here sets a text colour, and that is load-bearing.** A selected
    /// sidebar row is filled with the accent the owner chose in System Settings,
    /// and macOS inverts the row's labels to stay legible on it — but only for
    /// labels it is allowed to style. Pinning `Palette.ink.primary` on the title
    /// would survive review and then render dark-on-dark for anyone whose accent
    /// is not blue. The system's own `.secondary` is used for the second line for
    /// the same reason: `Palette.ink.secondary` is fixed and would not invert.
    /// This is the platform-chrome exception `Palette.accent` describes.
    private func row(_ section: MainSection) -> some View {
        HStack(alignment: .top, spacing: s4) {
            Image(systemName: section.glyph)
                .mynahIcon(.card)
                // A fixed column so four glyphs of different widths still leave
                // their titles on one vertical line.
                .frame(width: 24, alignment: .center)
            VStack(alignment: .leading, spacing: 1) {
                Text(section.title).mynahFont(.title3)
                Text(section.summary)
                    .mynahFont(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, s3)
        // Two `Text`s and a glyph read as three stops in VoiceOver, which turns
        // four destinations into twelve. One stop, one sentence.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(section.title). \(section.summary)")
    }

    /// The mark and the wordmark, where every recent Mac app that has an
    /// identity to state puts it.
    ///
    /// The window has no title — `RootView` clears it, because a title beside
    /// the traffic lights would be a second and worse wordmark — so this is the
    /// only place the app says its own name. A word on its own did that job
    /// and looked like a heading somebody forgot to style; the mark beside it is
    /// what makes the column read as belonging to a product.
    private var identity: some View {
        HStack(spacing: s4) {
            MynahMark(side: 26)
            Text("Mynah")
                .mynahWordmark()
                .foregroundStyle(Palette.ink.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, s5)
        .padding(.bottom, s5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Mynah")
        .accessibilityAddTraits(.isHeader)
    }

    /// What MYNAH is doing, and a way to the screen that changes it.
    ///
    /// Insets and a rounded hover fill rather than a full-bleed press target:
    /// the row now sits on the same rails as the selection capsules above it,
    /// which is what stops the bottom of the column looking like a different
    /// piece of software from the top of it.
    private var status: some View {
        VStack(spacing: 0) {
            // `MynahDivider`, not `Divider`. `Divider().foregroundStyle(_:)`
            // does not colour a divider — it was a no-op, and the separator
            // here was the system's grey rather than the app's.
            MynahDivider()
            Button {
                selection = .settings
            } label: {
                HStack(spacing: s3) {
                    StatusDot(app.effectivePresence.tone)
                    Text(app.effectivePresence.verb)
                        .mynahFont(.label)
                        .foregroundStyle(Palette.ink.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, s3)
                .padding(.vertical, s3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(RoundedRectangle.mynah(r.control))
                .background(
                    isHoveringStatus ? Palette.surface.well : .clear,
                    in: RoundedRectangle.mynah(r.control)
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, s3)
            .padding(.vertical, s3)
            .onHover { isHoveringStatus = $0 }
            .pointingHandCursor()
            .mynahAnimation(Motion.fade, value: isHoveringStatus)
            .accessibilityLabel("Mynah is \(app.effectivePresence.verb). Open settings.")
        }
    }
}

// MARK: - Panes
//
// The shell owns no screens of its own. `Memories` and `Settings` are reached
// directly (`Main/MemoriesView.swift`, `Main/SettingsView.swift`); `Home` keeps a
// thin wrapper only because the conversation surface takes an argument the
// sidebar has to supply. What none of them may do is reintroduce a titlebar, a
// second wordmark, or an accent colour beyond the one live thing on the screen.

/// The turn surface: what MYNAH is doing right now, and what it just said.
struct HomePane: View {
    /// Lets the recovery banner in the composer jump straight to Settings.
    /// Optional so `HomePane()` still compiles wherever it is already written.
    var onOpenSettings: (() -> Void)?

    var body: some View {
        // The pane owns no chrome of its own: `TalkView` carries the health
        // line, the transcript and the composer, and it holds the conversation
        // across a trip to Settings and back.
        TalkView(onOpenSettings: onOpenSettings)
    }
}

// MARK: - Previews

#Preview("Onboarding — welcome") {
    OnboardingPreview(stage: .welcome).frame(width: 1180, height: 820)
}

#Preview("Onboarding — brain") {
    OnboardingPreview(stage: .brain).frame(width: 1180, height: 820)
}

#Preview("Main shell") {
    MainShell()
        .environment(AppModel(defaults: PreviewDefaults.make(setupComplete: true)))
        .frame(width: 1180, height: 820)
}

/// Drives a real `SetupModel` to the requested stage so the previews show the
/// same code path the owner walks, not a mock of it.
private struct OnboardingPreview: View {
    let stage: SetupModel.Stage
    @State private var model = SetupModel()

    var body: some View {
        HStack(spacing: 0) {
            pane.environment(\.colorScheme, .light)
            pane.environment(\.colorScheme, .dark)
        }
    }

    private var pane: some View {
        OnboardingFlow(model: model, onFinished: {})
            .environment(AppModel(defaults: PreviewDefaults.make(setupComplete: false)))
            .task {
                await model.probe()
                // `advance()` is gated on `canContinue`, so previews past the
                // brain stage need a real selection — the same one the owner
                // would have had to make.
                while model.stage.rawValue < stage.rawValue {
                    if model.stage == .brain, model.selectedOptionID == nil {
                        model.selectedOptionID = model.choices?.availableOptions.first?.id
                    }
                    let before = model.stage
                    model.advance()
                    if model.stage == before { break }
                }
            }
    }
}

private enum PreviewDefaults {
    /// A throwaway suite, so opening a preview never rewrites the real app's
    /// settings on this machine.
    static func make(setupComplete: Bool) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "mynah.preview.\(UUID().uuidString)") ?? .standard
        defaults.set(setupComplete, forKey: "mynah.setupComplete")
        return defaults
    }
}
