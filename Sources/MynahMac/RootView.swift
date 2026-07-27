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
        case .phone:
            SignalLinkStage(
                titles: stageTitles,
                currentIndex: SetupModel.Stage.phone.rawValue,
                app: app,
                onBack: { model.goBack() },
                onFinished: { model.advance() }
            )
        case .ready:
            ReadyStage(titles: stageTitles, model: model, app: app, onFinished: onFinished)
        }
    }
}

// Stages 1 to 4 live in `Setup/WelcomeView.swift`, `Setup/BrainPickerView.swift`,
// `Setup/ConnectKeyView.swift` and `Setup/SignalLinkView.swift`. They keep the
// initialiser shapes this file switches on — `init(titles:model:)`, and
// `init(titles:model:app:)` where a stage has something to hand back to Settings
// — and nothing else about them is this file's business.

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

    private var unfinished: [AppModel.DeferredStep] { app.deferredSetupSteps }

    var body: some View {
        StageShell(
            stageTitles: titles,
            currentIndex: SetupModel.Stage.ready.rawValue,
            glyph: unfinished.isEmpty ? "checkmark" : "iphone.gen3",
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
    }

    private var subtitle: String {
        guard unfinished.isEmpty else {
            return "Mynah will answer as soon as you finish it — and it's waiting in Settings "
                + "whenever you're ready."
        }
        return "Send it a voice note and it will answer out loud. The first answer takes "
            + "about twenty seconds."
    }

    private var destination: String {
        guard let option = model.selectedOption else { return "Not chosen yet" }
        if option.keepsWordsOnDevice { return "This Mac" }
        return MynahCopy.company(forBackend: option.backendIdentifier) ?? "A company"
    }
}

// MARK: - Main shell

/// The sections in the sidebar. Order is the order they appear.
enum MainSection: String, CaseIterable, Identifiable, Hashable {
    case home
    case memories
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .memories: return "Memories"
        case .settings: return "Settings"
        }
    }

    /// A sidebar row is the one place in this app where `Label(_:systemImage:)`
    /// is correct — macOS sidebars use it, so removing it would look wrong.
    var glyph: String {
        switch self {
        case .home: return "waveform"
        case .memories: return "text.append"
        case .settings: return "gearshape"
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

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: $selection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
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
                    }
                }
        }
        .navigationTitle("")
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .home {
        case .home: HomePane(onOpenSettings: { selection = .settings })
        case .memories: MemoriesView()
        case .settings: SettingsView(onOpenSection: { selection = $0 })
        }
    }
}

/// Wordmark, sections, and one status row at the bottom.
///
/// No version number under the wordmark — that is a developer's instinct.
/// Version belongs in Settings → About.
struct Sidebar: View {
    @Binding var selection: MainSection?
    @Environment(AppModel.self) private var app

    var body: some View {
        // The `List` is the column's root, with the wordmark and status row
        // attached as safe-area insets.
        //
        // Wrapping the list in a `VStack` to stack them looks equivalent and is
        // not: measured here, the whole sidebar laid out at screen y = -5 with a
        // height of 1356pt inside an 820pt window, so every row rendered outside
        // the window and the column appeared empty while the accessibility tree
        // still listed all three sections.
        List(selection: $selection) {
            ForEach(MainSection.allCases) { section in
                // The one place `Label(_:systemImage:)` is correct in this app —
                // macOS sidebars use it, and removing it would look wrong.
                Label(section.title, systemImage: section.glyph)
                    .tag(section)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            Text("Mynah")
                .mynahWordmark()
                .foregroundStyle(Palette.ink.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, s5)
                .padding(.bottom, s4)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider().foregroundStyle(Palette.line.divider)
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
                    .contentShape(Rectangle())
                    .padding(.horizontal, s5)
                    .padding(.vertical, s4)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .accessibilityLabel("Mynah is \(app.effectivePresence.verb). Open settings.")
            }
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
