import AppKit
import Observation
import OSLog
import SwiftUI

// MARK: - Logging

/// Where the panel's plumbing goes: a rejected saved position, a missing screen,
/// a window that could not be found. None of it is owner-facing, and none of it
/// reaches a `Text`.
private let hudLog = Logger(subsystem: "com.sage.mynah", category: "hud")

// MARK: - The panel

/// A floating, non-activating panel.
///
/// `.nonactivatingPanel` is the whole point: the owner closes MYNAH's window to
/// get on with something else, so a status surface that pulls their app out of
/// focus when it appears has taken more than it gave. The panel can still take
/// keys when it is clicked — `canBecomeKey` says so — which is what makes Escape
/// and Return work, but it never becomes *main* and never activates the app.
///
/// Not `.hudWindow`: that style mask requires `.titled` and brings AppKit's own
/// dark HUD chrome, which would sit behind `MynahGlassBackground` fighting it.
/// The glass is the chrome here, so the window has none.
final class MynahHUDPanel: NSPanel {

    /// Escape. Routed out rather than handled here so the one place that owns
    /// "is the panel on screen" is the controller.
    var onCancel: (() -> Void)?

    /// Borderless windows return `false` by default, which would make the panel
    /// permanently unfocusable — no Escape, no default action, and buttons that
    /// respond to the mouse but never to the keyboard. `.nonactivatingPanel` is
    /// what keeps saying yes here from stealing the frontmost app's focus.
    override var canBecomeKey: Bool { true }

    /// Never main. `MainWindowPresenter` finds MYNAH's window by looking for one
    /// that `canBecomeMain`, and a panel that answered `true` would be handed
    /// every "Open Mynah" the menu bar and the Dock icon produce.
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    /// Escape, belt and braces.
    ///
    /// `cancelOperation(_:)` is the idiomatic route and it also catches Cmd-.,
    /// but it only arrives if something in the responder chain called
    /// `interpretKeyEvents(_:)` — which the hosting view does only when a
    /// SwiftUI control has taken focus. With focus nowhere, which is the panel's
    /// normal state, the raw key event bubbles up to here instead and the
    /// idiomatic route never fires. A HUD you cannot dismiss from the keyboard
    /// is one the owner has to go hunting in the menu bar for.
    override func keyDown(with event: NSEvent) {
        // 53 is Escape. `NSEvent` has no symbolic constant for it, and matching
        // on the character would break under any keyboard layout that maps the
        // escape character elsewhere.
        guard event.keyCode == 53 else {
            super.keyDown(with: event)
            return
        }
        onCancel?()
    }
}

// MARK: - Presentation

/// Owns the one floating panel: when it exists, where it sits, and who asked.
///
/// The visibility rules are the interesting part, and they exist because two
/// different people can ask for the same panel. Closing the window is the *app*
/// asking, and that request is withdrawn when a window comes back. Picking it
/// from the menu bar is the *owner* asking, and that request outlives everything
/// until they ask the opposite. Collapsing those into one boolean gives you a
/// panel that vanishes the moment the owner opens the window they were looking
/// something up in.
@MainActor
@Observable
final class FloatingHUDController {

    static let shared = FloatingHUDController()

    /// Read by the menu bar so its one item can name the thing it will do.
    private(set) var isVisible = false

    /// 340pt across, ~250 tall depending on state.
    ///
    /// Height is left to the content: `NSHostingController` republishes its
    /// fitting size and AppKit resizes the window, so the panel is exactly as
    /// tall as it needs to be with no reply on screen and grows when there is
    /// one. The width is fixed because a status panel that reflowed as sentences
    /// changed length would be a different shape every twenty seconds.
    private static let width: CGFloat = 340

    /// Only the origin is persisted, never the size: the size belongs to
    /// whatever MYNAH is doing and to the owner's text-size setting, so a
    /// restored height would be wrong the first time either changed.
    private static let originKey = "mynah.hud.origin"

    @ObservationIgnored private var panel: MynahHUDPanel?
    @ObservationIgnored private var app: AppModel?
    @ObservationIgnored private let defaults: UserDefaults

    /// The owner picked the panel from the menu bar. Survives the window opening
    /// and closing; only the owner clears it.
    @ObservationIgnored private var isPinnedByOwner = false

    /// The owner sent the panel away. Suppresses the automatic appearance on the
    /// *next* window close too — otherwise dismissing it is a thing they have to
    /// do again every time they tidy their desktop, which is the same broken
    /// promise as a "Later" that leads nowhere.
    @ObservationIgnored private var wasDismissedByOwner = false

    /// Quitting closes every window, and `willClose` on the way out must not be
    /// read as "the owner tidied up" and answered with a panel appearing over
    /// the desktop for the last half-second of the process's life.
    @ObservationIgnored private var isTerminating = false

    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: Wiring

    /// Hands the controller the app's live state and starts watching windows.
    ///
    /// Called from `RootView.onAppear` for the same reason `openMainWindow` is:
    /// `AppModel` is created by the scene, the delegate outlives every scene, and
    /// this object is reachable from both. Safe to call twice — a second scene
    /// would otherwise register a second set of observers and show the panel
    /// twice on one window close.
    func attach(app: AppModel) {
        self.app = app
        guard observers.isEmpty else { return }

        // `willClose` rather than `applicationShouldTerminateAfterLastWindowClosed`:
        // that method is the app's answer to "may I quit", it is consulted before
        // the window is gone, and MYNAH already answers `false` to it forever.
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                // `assumeIsolated` rather than a `Task`: the notification is
                // delivered on the main queue by contract, and hopping would let
                // a window close and the app quit before the hop ran.
                MainActor.assumeIsolated {
                    self?.windowWillClose(notification.object as? NSWindow)
                }
            }
        )

        // Not `RootView.onAppear`: bringing an existing window back with
        // `makeKeyAndOrderFront` — which is every "Open Mynah" and every Dock
        // click — does not re-run a SwiftUI appearance. The key notification is
        // the only signal that fires on all of those paths.
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    self?.windowDidBecomeKey(notification.object as? NSWindow)
                }
            }
        )
    }

    func applicationWillTerminate() {
        isTerminating = true
    }

    // MARK: Owner-driven

    /// The menu bar's one item. Showing this way pins the panel; hiding this way
    /// is the owner saying they do not want it, and is remembered.
    func toggleFromMenuBar() {
        if isVisible {
            dismissByOwner()
        } else {
            isPinnedByOwner = true
            wasDismissedByOwner = false
            show()
        }
    }

    /// Escape, and the panel's own Hide button.
    func dismissByOwner() {
        isPinnedByOwner = false
        wasDismissedByOwner = true
        hide()
    }

    // MARK: Window-driven

    private func windowWillClose(_ window: NSWindow?) {
        guard let window, Self.isMainWindow(window), !isTerminating else { return }
        // The closing window is still in `NSApp.windows` while `willClose` is
        // being delivered, so "is this the last one?" cannot be answered yet.
        // One runloop hop later it can.
        DispatchQueue.main.async { [weak self] in
            self?.showIfNoMainWindowRemains()
        }
    }

    private func showIfNoMainWindowRemains() {
        guard !isTerminating,
              let app,
              // Nothing to report before there is a brain to report on. Closing
              // the window mid-onboarding would otherwise raise a panel stuck on
              // "It's getting ready" for the rest of the session, because nothing
              // has ever asked the conversation to connect.
              app.hasCompletedSetup,
              app.keepsAnsweringWhenClosed,
              !wasDismissedByOwner,
              !NSApp.windows.contains(where: { Self.isMainWindow($0) && $0.isVisible })
        else { return }
        show()
    }

    private func windowDidBecomeKey(_ window: NSWindow?) {
        guard let window, Self.isMainWindow(window) else { return }
        // The window is back, so the app's reason for showing the panel is gone.
        // The owner's reason, if they had one, is not.
        guard !isPinnedByOwner else { return }
        // Not a dismissal: the owner never asked for this one, so closing the
        // window again should bring the panel back.
        hide()
    }

    /// The one window MYNAH has. Matches `MainWindowPresenter`'s predicate — the
    /// status item and this panel both own `NSWindow`s and neither is it.
    private static func isMainWindow(_ window: NSWindow) -> Bool {
        window.canBecomeMain && !(window is NSPanel)
    }

    // MARK: Showing

    private func show() {
        guard let app else {
            hudLog.error("show requested before the scene handed over the app model")
            return
        }
        let panel = self.panel ?? makePanel(app: app)
        self.panel = panel
        // `orderFrontRegardless`, never `makeKeyAndOrderFront`: the second one
        // activates MYNAH, which is precisely the interruption a panel that
        // appears when you close a window must not cause.
        panel.orderFrontRegardless()
        isVisible = true
    }

    private func hide() {
        panel?.orderOut(nil)
        isVisible = false
    }

    private func makePanel(app: AppModel) -> MynahHUDPanel {
        // The height here is a placeholder — `setContentSize` below replaces it
        // with what the content actually asked for, before the panel is ever
        // ordered in.
        let panel = MynahHUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 240),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // Above ordinary windows, so it is still readable over the app the owner
        // went back to. That is the entire reason it exists.
        panel.level = .statusBar
        // `.canJoinAllSpaces` because the owner switching desktops has not
        // stopped waiting for an answer; `.fullScreenAuxiliary` so it survives a
        // full-screen app; `.ignoresCycle` so Cmd-` between MYNAH's windows does
        // not land on a panel with nothing to type into.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // AppKit derives this from the rendered alpha channel, so it traces the
        // glass's 22pt continuous corners rather than the window rectangle, and
        // the window server moves it with the panel. See the note in
        // `MynahTheme.swift` for why the design system's own `.float` shadow is
        // the wrong tool for a real window.
        panel.hasShadow = true
        // NSPanel defaults this to `true`, which would hide the panel every time
        // MYNAH stopped being the frontmost app — i.e. always, and exactly when
        // it is needed.
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        // Nothing here is worth restoring, and a restored panel would reappear
        // over a desktop the owner had cleared. The main window makes the same
        // call in `RootView` for the same reason.
        panel.isRestorable = false
        panel.animationBehavior = .utilityWindow
        // Borderless, so this is never drawn — it is what VoiceOver announces.
        panel.title = "Mynah"
        panel.onCancel = { [weak self] in self?.dismissByOwner() }

        let content = MynahHUDView(
            app: app,
            conversation: .shared,
            onOpenMynah: { MainWindowPresenter.presentFromAppKit() },
            onHide: { [weak self] in self?.dismissByOwner() }
        )
        .frame(width: Self.width)

        let host = NSHostingController(rootView: content)
        // Stated rather than left to the default, because this is the line that
        // makes the panel grow when an answer arrives and shrink again when the
        // conversation is cleared. Without it the window keeps whatever height it
        // was created at and a two-line reply is simply clipped off the bottom.
        host.sizingOptions = [.preferredContentSize]
        panel.contentViewController = host
        panel.setContentSize(host.view.fittingSize)

        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification,
                object: panel,
                queue: .main
            ) { [weak self] notification in
                guard let resized = notification.object as? NSWindow else { return }
                MainActor.assumeIsolated { self?.keepOnScreen(resized) }
                // The shadow is cut from the content's alpha at the size the
                // window last drew at, so a panel that grew to fit an answer
                // keeps the shorter panel's shadow until this is called.
                resized.invalidateShadow()
            }
        )

        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.didMoveNotification,
                object: panel,
                queue: .main
            ) { [weak self] notification in
                guard let moved = notification.object as? NSWindow else { return }
                MainActor.assumeIsolated {
                    self?.saveOrigin(moved.frame.origin)
                }
            }
        )

        panel.setFrameOrigin(restoredOrigin(for: panel.frame.size))
        return panel
    }

    // MARK: Position

    private func saveOrigin(_ origin: NSPoint) {
        defaults.set(NSStringFromPoint(origin), forKey: Self.originKey)
    }

    /// Nudges a panel that just changed height back inside its screen.
    ///
    /// `setContentSize` pins the window's *top-left*, so a panel grows downward
    /// — and it grows exactly when an answer arrives, which is the one moment
    /// the owner is looking at it. Resting in the default bottom-right corner
    /// 20pt off the edge, the two-line reply state is ~60pt taller than the
    /// resting state, which puts the footer and its Hide button under the Dock.
    /// The correction is a few points and invisible; hunting for a control that
    /// has slid off the screen is not.
    private func keepOnScreen(_ window: NSWindow) {
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let frame = window.frame
        let lowest = visible.minY + s6
        // `max(lowest, …)` on the ceiling too: on a screen shorter than the
        // panel the two bounds cross, and clamping to an inverted range would
        // pin the panel somewhere off the top instead.
        let highest = max(lowest, visible.maxY - frame.height - s6)
        let leftmost = visible.minX + s6
        let rightmost = max(leftmost, visible.maxX - frame.width - s6)
        let corrected = NSPoint(
            x: min(max(frame.minX, leftmost), rightmost),
            y: min(max(frame.minY, lowest), highest)
        )
        // `setFrameOrigin` posts `didMove`, which saves the corrected position.
        // It does not post `didResize`, so this cannot re-enter.
        guard corrected != frame.origin else { return }
        window.setFrameOrigin(corrected)
    }

    private func restoredOrigin(for size: NSSize) -> NSPoint {
        guard let stored = defaults.string(forKey: Self.originKey) else {
            return Self.defaultOrigin(for: size)
        }
        let origin = NSPointFromString(stored)
        guard Self.isReachable(NSRect(origin: origin, size: size)) else {
            // The owner dragged it onto a second display and then unplugged the
            // display. Silently reappearing in the corner is right; leaving it
            // where it was is a panel the owner is told about and cannot see.
            hudLog.info("saved panel position is off every attached screen, using the default corner")
            return Self.defaultOrigin(for: size)
        }
        return origin
    }

    /// Half the panel must land on one screen, not one pixel of it.
    ///
    /// A bare `intersects` passes for a panel showing four points of its corner,
    /// which is both unreadable and — since the whole surface is the drag handle
    /// — almost impossible to grab back.
    private static func isReachable(_ frame: NSRect) -> Bool {
        let required = frame.width * frame.height * 0.5
        return NSScreen.screens.contains { screen in
            let shared = screen.visibleFrame.intersection(frame)
            return shared.width * shared.height >= required
        }
    }

    /// Bottom-right, inset by one spacing step. Out of the way of the menu bar
    /// and of most apps' main working area, and on the side of the screen the
    /// Dock is least often on.
    private static func defaultOrigin(for size: NSSize) -> NSPoint {
        guard let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else {
            return .zero
        }
        return NSPoint(x: visible.maxX - size.width - s6, y: visible.minY + s6)
    }
}

// MARK: - The panel's contents

/// What MYNAH is doing, and what it last said.
///
/// Reads `ConversationModel` directly rather than mirroring it: the window and
/// the panel are two views of one conversation, and a panel with its own copy of
/// the turn state is a panel that can disagree with the window about whether
/// MYNAH is busy.
///
/// Every sentence in here is `ink.primary`, and the content is inset by `s8`
/// from the top. Both are contrast requirements of the glass rather than taste —
/// see the measured note above `MynahVisualEffect` in `MynahTheme.swift`.
@MainActor
struct MynahHUDView: View {

    let app: AppModel
    let conversation: ConversationModel
    let onOpenMynah: () -> Void
    let onHide: () -> Void

    /// 340pt of panel less two `s6` margins.
    private static let content: CGFloat = 300

    var body: some View {
        VStack(alignment: .leading, spacing: s5) {
            VStack(alignment: .leading, spacing: s3) {
                stateRow
                detail
            }
            if let recap { recapBlock(recap) }
            footer
        }
        .frame(width: Self.content, alignment: .leading)
        .padding(.horizontal, s6)
        // `s8`, not `s6`. The glass's top sheen peaks at 0.48 white and a
        // dark-mode backdrop under it composites to ~2.2:1 even for
        // `ink.primary`; by 32pt down the sheen is spent and the floor is back
        // to 5.1:1. The band is left empty on purpose.
        .padding(.top, s8)
        .padding(.bottom, s6)
        .background(MynahGlassBackground(vibrancyState: .active, castsShadow: false))
        .mynahTextSize(app.textSize)
        .mynahAnimation(Motion.fade, value: state.title)
        .accessibilityElement(children: .contain)
    }

    // MARK: State

    /// One verb, one sentence, and — while a turn is running — the moment it
    /// started, so the sentence can advance with the wait.
    private struct Line {
        var tone: MynahTone
        var title: String
        var detail: String?
        var startedAt: Date?
    }

    /// Priority order, and it matters. A paused MYNAH is sleeping whatever else
    /// is true; something the owner has to fix outranks anything it is doing;
    /// and only then does the turn state get a say.
    private var state: Line {
        if app.isPaused {
            return Line(tone: .neutral, title: "Sleeping", detail: MynahCopy.floatingPanelSleeping)
        }
        if let trouble = conversation.trouble {
            // `headline` is authored copy with a verb in it — never an error
            // object, a status code or a tool name. See `Exchange.Failure`.
            return Line(tone: .caution, title: "Needs you", detail: trouble.headline)
        }
        // Unreachable until something implements `VoiceCapture` — `canHoldToTalk`
        // is false today and the composer's own recording UI is gated the same
        // way. Handled anyway, because the alternative is a panel that says "on
        // and waiting" while the owner is mid-sentence on the day voice lands.
        if conversation.isRecording {
            return Line(tone: .good, title: "Online", detail: MynahCopy.floatingPanelListening)
        }
        if conversation.isBusy, let waiting = conversation.exchanges.last(where: { $0.isThinking }) {
            // Deliberately no detail: the thinking line is time-driven, so it is
            // built inside a `TimelineView` rather than sampled once here.
            return Line(tone: .good, title: "Answering", detail: nil, startedAt: waiting.askedAt)
        }
        switch conversation.readiness {
        case .connecting:
            return Line(tone: .neutral, title: "Waking up", detail: MynahCopy.floatingPanelWaking)
        case .ready(let destination, let staysOnDevice):
            return Line(
                tone: .good,
                title: "Online",
                detail: MynahCopy.floatingPanelResting(
                    destination: destination,
                    staysOnDevice: staysOnDevice
                )
            )
        case .blocked:
            // Unreachable — `trouble` is exactly this case and is handled above.
            // Kept exhaustive so a new readiness state is a compile error here
            // rather than a panel that silently says nothing.
            return Line(tone: .caution, title: "Needs you", detail: nil)
        }
    }

    private var stateRow: some View {
        let line = state
        return HStack(spacing: s3) {
            // 8pt rather than the default 6: on vibrancy a 6pt dot in
            // `state.good` measures about 2.9:1 against the worst backdrop, so
            // it is enlarged and it never carries meaning the word beside it
            // does not already carry.
            StatusDot(line.tone, size: 8)
            Text(line.title)
                .mynahFont(.title3)
                .foregroundStyle(Palette.ink.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Mynah is \(line.title.lowercased())")
    }

    @ViewBuilder
    private var detail: some View {
        let line = state
        if let startedAt = line.startedAt {
            // The same four sentences the transcript uses, on the same timer.
            // The panel is a second window onto one wait, so it must not invent
            // a fifth way of describing it.
            TimelineView(.periodic(from: startedAt, by: 1)) { timeline in
                let elapsed = max(0, timeline.date.timeIntervalSince(startedAt))
                sentence(MynahCopy.thinkingLine(elapsed: elapsed))
                    .contentTransition(.opacity)
                    .mynahAnimation(Motion.fade, value: MynahCopy.thinkingLine(elapsed: elapsed))
            }
        } else if let text = line.detail {
            sentence(text)
        }
    }

    /// Every reading line in the panel goes through here, so `ink.primary` is
    /// one decision rather than six call sites that each have to remember the
    /// glass cannot carry `ink.secondary`.
    private func sentence(_ text: String) -> some View {
        Text(text)
            .mynahFont(.body)
            .foregroundStyle(Palette.ink.primary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: What it last said

    private enum Recap {
        case answered(Exchange.Answer)
        case failed(String)
    }

    /// The last thing that finished. Suppressed while a turn is running — the
    /// state line is already describing that — and while something is blocked,
    /// where it would repeat the sentence directly above it.
    private var recap: Recap? {
        guard !conversation.isBusy,
              conversation.trouble == nil,
              let last = conversation.exchanges.last
        else { return nil }
        switch last.outcome {
        case .answered(let answer): return .answered(answer)
        case .failed(let failure): return .failed(failure.headline)
        case .thinking: return nil
        }
    }

    @ViewBuilder
    private func recapBlock(_ recap: Recap) -> some View {
        switch recap {
        case .answered(let answer):
            VStack(alignment: .leading, spacing: s2) {
                Text(answer.text)
                    .mynahFont(.body)
                    .foregroundStyle(Palette.ink.primary)
                    // Two lines, then truncation. A panel that grew to hold a
                    // paragraph would cover the work the owner went back to,
                    // and the whole answer is one click away in the window.
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(provenance(answer))
                    .mynahFont(.label)
                    // One `Text`, so the `·` separators take the same ink as the
                    // words. The transcript dims them to `quaternary` because it
                    // sits on an opaque card; on glass that is 1.5:1 and the
                    // line reads as though it has holes in it.
                    .foregroundStyle(Palette.ink.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .failed(let headline):
            sentence(headline)
        }
    }

    /// "21s · Looked through what it remembers". The phrases are already the
    /// owner's words — `ToolActivity` drops any tool it has no phrase for — so
    /// no tool name can reach the panel.
    private func provenance(_ answer: Exchange.Answer) -> String {
        ([MynahCopy.duration(answer.seconds)] + answer.activity).joined(separator: " · ")
    }

    // MARK: Actions

    /// Both buttons are `.secondary` rather than `.quiet`, and that is a contrast
    /// decision. A quiet button's label is `ink.secondary`, which measures 3.7:1
    /// on the glass at its worst; a secondary button brings its own opaque
    /// `surface.raised` fill, so its label is a known 14.3:1 dark / 14.9:1 light
    /// wherever the panel happens to be sitting.
    private var footer: some View {
        HStack(spacing: s4) {
            MynahButton("Open Mynah", kind: .secondary, isDefault: true, action: onOpenMynah)
            MynahButton("Hide", kind: .secondary, action: onHide)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Previews

#Preview("Floating panel") {
    FloatingHUDPreview()
}

/// The panel over both schemes, in the four states worth looking at.
///
/// Vibrancy has nothing to blur inside a preview, so the glass renders flatter
/// here than it does on the desktop — the layout, the ink and the line lengths
/// are what this is for.
private struct FloatingHUDPreview: View {
    var body: some View {
        HStack(spacing: 0) {
            pane.environment(\.colorScheme, .light)
            pane.environment(\.colorScheme, .dark)
        }
        .frame(width: 860, height: 900)
    }

    private var pane: some View {
        ScrollView {
            VStack(spacing: s6) {
                panel(HUDPreviewFixtures.resting())
                panel(HUDPreviewFixtures.midTurn())
                panel(HUDPreviewFixtures.answered())
                panel(HUDPreviewFixtures.blocked())
            }
            .padding(s7)
        }
        .background(Palette.surface.canvas)
    }

    private func panel(_ conversation: ConversationModel) -> some View {
        MynahHUDView(
            app: AppModel(defaults: HUDPreviewFixtures.defaults()),
            conversation: conversation,
            onOpenMynah: {},
            onHide: {}
        )
        .frame(width: 340)
    }
}

@MainActor
private enum HUDPreviewFixtures {

    /// A throwaway suite, so opening a preview never rewrites the real app's
    /// settings on this machine.
    static func defaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "mynah.hud.preview.\(UUID().uuidString)") ?? .standard
        defaults.set(true, forKey: "mynah.setupComplete")
        return defaults
    }

    static func resting() -> ConversationModel {
        ConversationModel(readiness: .ready(destination: "this Mac", staysOnDevice: true))
    }

    static func midTurn() -> ConversationModel {
        ConversationModel(
            exchanges: [
                Exchange(
                    question: "Has anything changed with the planning application?",
                    askedAt: Date(timeIntervalSinceNow: -26)
                )
            ],
            readiness: .ready(destination: "Google", staysOnDevice: false)
        )
    }

    static func answered() -> ConversationModel {
        ConversationModel(
            exchanges: [
                Exchange(
                    question: "What did I say I'd do about the roof?",
                    askedAt: Date(timeIntervalSinceNow: -200),
                    outcome: .answered(
                        Exchange.Answer(
                            text: "You said you'd call the roofer back after the weekend and get a "
                                + "written quote before agreeing to anything.",
                            seconds: 21,
                            activity: ["Looked through what it remembers"]
                        )
                    )
                )
            ],
            readiness: .ready(destination: "this Mac", staysOnDevice: true)
        )
    }

    static func blocked() -> ConversationModel {
        ConversationModel(
            readiness: .blocked(
                Exchange.Failure(
                    headline: "Mynah still needs your Google key.",
                    explanation: "Open Settings and paste the key you were given.",
                    settingsActionTitle: "Open settings"
                )
            )
        )
    }
}
