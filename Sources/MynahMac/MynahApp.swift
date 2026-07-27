import AppKit
import Observation
import SwiftUI

// MARK: - App-wide state

/// What the whole app agrees is true right now.
///
/// Deliberately tiny: presence, the two settings that change behaviour outside
/// the window, and whether setup is done. Anything that belongs to one screen
/// lives on that screen. This is the type the menu bar, the sidebar footer and
/// the floating HUD all read, so growing it grows the blast radius of every
/// change.
@MainActor
@Observable
final class AppModel {

    /// What MYNAH is doing, in verbs the owner would use.
    enum Presence: Sendable {
        case answering
        case listening
        case sleeping
        case needsOwner

        /// One word for the sidebar footer and the menu bar.
        var verb: String {
            switch self {
            case .answering: return "Answering"
            case .listening: return "Listening"
            case .sleeping: return "Sleeping"
            case .needsOwner: return "Needs you"
            }
        }

        var tone: MynahTone {
            switch self {
            case .answering, .listening: return .good
            case .sleeping: return .neutral
            case .needsOwner: return .caution
            }
        }

        /// The status-item lamp. Menu-bar icons are template-rendered, so the
        /// shape has to carry the meaning on its own.
        var menuBarSymbol: String {
            switch self {
            case .answering, .listening: return "waveform"
            case .sleeping: return "moon"
            case .needsOwner: return "exclamationmark.circle"
            }
        }
    }

    private enum Key {
        static let setupComplete = "mynah.setupComplete"
        static let paused = "mynah.paused"
        static let keepAnswering = "mynah.keepAnsweringWhenClosed"
        static let textSize = "mynah.textSize"
        static let deferredSteps = "mynah.deferredSetupSteps"
    }

    /// Live state, owned by whatever is driving turns. Not persisted — a
    /// restarted app has not started answering anything yet.
    var presence: Presence = .sleeping

    var isPaused: Bool {
        didSet { defaults.set(isPaused, forKey: Key.paused) }
    }

    /// The daemon keeps running with the window closed. This is the owner's
    /// switch for that, phrased in the settings pane as "Keep answering when
    /// this window is closed".
    var keepsAnsweringWhenClosed: Bool {
        didSet { defaults.set(keepsAnsweringWhenClosed, forKey: Key.keepAnswering) }
    }

    var textSize: MynahTextSize {
        didSet { defaults.set(textSize.rawValue, forKey: Key.textSize) }
    }

    private(set) var hasCompletedSetup: Bool

    /// Changes every time setup is started over.
    ///
    /// `RootView` uses it as the onboarding view's identity, which is what makes
    /// "Change where your words go" build a *new* `SetupModel`. Without it the
    /// finished state machine survives, and the owner who asked to change their
    /// brain is put back on the last screen of a flow that is already over —
    /// pressing a button that appears to do nothing.
    private(set) var setupRunID = UUID()

    /// Capabilities the owner said "Not now" to. Every skipped step has to land
    /// somewhere the owner can find it again — a "Later" that leads nowhere is
    /// the single worst thing in the donor app.
    ///
    /// Persisted, because the skip it records outlives the launch that made it:
    /// an unlinked phone is still unlinked tomorrow, and an "Unfinished" list
    /// that empties itself overnight is the same broken promise in slower motion.
    private(set) var deferredSetupSteps: [DeferredStep] = [] {
        didSet { persistDeferredSteps() }
    }

    struct DeferredStep: Identifiable, Hashable, Sendable, Codable {
        let id: String
        /// Named as a thing to do: "Link your phone", not "Phone linking".
        let title: String
        let detail: String

        // The ids the app defers and resolves under. Constants, not literals,
        // because the screen that defers a step and the code that clears it are
        // the same screen on a different run — and now that the list survives
        // relaunches, a typo is a row the owner can never get rid of: the
        // "Later" that leads nowhere, arriving by another route.
        //
        // Flat statics rather than a nested `ID` enum: `Identifiable` already
        // claims that name for its associated type.
        static let brainKeyID = "brain.key"
        static let phoneLinkID = "phone.link"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.hasCompletedSetup = defaults.bool(forKey: Key.setupComplete)
        self.isPaused = defaults.bool(forKey: Key.paused)
        // Absent means "not yet asked", and the appliance is useless if it stops
        // when the window closes, so the default is on.
        self.keepsAnsweringWhenClosed = defaults.object(forKey: Key.keepAnswering) as? Bool ?? true
        self.textSize = (defaults.string(forKey: Key.textSize).flatMap(MynahTextSize.init(rawValue:))) ?? .standard
        // Decode failures leave the list empty rather than throwing: a step the
        // owner deferred is a reminder, and a reminder is never worth refusing
        // to launch over.
        if let data = defaults.data(forKey: Key.deferredSteps),
           let steps = try? JSONDecoder().decode([DeferredStep].self, from: data) {
            self.deferredSetupSteps = steps
        }
    }

    private func persistDeferredSteps() {
        guard let data = try? JSONEncoder().encode(deferredSetupSteps) else { return }
        defaults.set(data, forKey: Key.deferredSteps)
    }

    /// Whatever the turn engine last reported, overridden by the owner's pause.
    var effectivePresence: Presence {
        isPaused ? .sleeping : presence
    }

    func completeSetup() {
        hasCompletedSetup = true
        defaults.set(true, forKey: Key.setupComplete)
    }

    /// Used by "Change where your words go" in Settings, and by the previews.
    func restartSetup() {
        hasCompletedSetup = false
        defaults.set(false, forKey: Key.setupComplete)
        // A new run, so a new state machine. See `setupRunID`.
        setupRunID = UUID()
    }

    /// Whether a restart can be backed out of.
    ///
    /// True only when the app was already set up once — there is a recorded
    /// brain to fall back to. On a genuine first run it is false, so the very
    /// first launch keeps exactly one way forward.
    var canCancelSetupRestart: Bool {
        !hasCompletedSetup && BrainSelectionStore.current(defaults) != nil
    }

    /// Backs out of a restart the owner started by curiosity.
    ///
    /// "Change" in Settings replaced the whole app with onboarding and the only
    /// thing that could undo it was walking all five stages again — the same
    /// class of trap as a "Later" that leads nowhere, arriving from the opposite
    /// direction. Refuses when there is nothing to go back to.
    func cancelSetupRestart() {
        guard canCancelSetupRestart else { return }
        hasCompletedSetup = true
        defaults.set(true, forKey: Key.setupComplete)
    }

    func deferSetupStep(_ step: DeferredStep) {
        guard !deferredSetupSteps.contains(where: { $0.id == step.id }) else { return }
        deferredSetupSteps.append(step)
    }

    func resolveDeferredStep(id: String) {
        deferredSetupSteps.removeAll { $0.id == id }
    }
}

// MARK: - App delegate

/// The appliance half of the app.
///
/// MYNAH answers the owner's phone whether or not a window is open, so closing
/// the last window must not terminate the process, and clicking the Dock icon
/// afterwards must bring the window back. Without both halves the owner has a
/// program that quits when they tidy their desktop.
final class MynahAppDelegate: NSObject, NSApplicationDelegate {

    /// Set by `RootView` once the scene exists, because `openWindow` is a
    /// SwiftUI environment action and there is no AppKit equivalent for a
    /// `WindowGroup`.
    var openMainWindow: (() -> Void)?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        // `false` means "handled, do not also do the default thing". Returning
        // `true` here after opening a window ourselves produces two windows —
        // observed, twice — and MYNAH is one appliance with one window.
        if MainWindowPresenter.presentExisting() { return false }
        guard let openMainWindow else { return true }
        openMainWindow()
        return false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}

// MARK: - Window identity

enum MynahWindowID {
    static let main = "mynah.main"
}

/// Brings the one window forward, or asks SwiftUI for it if it is gone.
///
/// `openWindow(id:)` on a `WindowGroup` *always* creates a new window, so
/// calling it to "focus" the app spawns a second copy of the whole UI. Every
/// path that shows MYNAH — the Dock icon, the menu bar, a notification — goes
/// through here.
enum MainWindowPresenter {

    /// - Returns: `true` when an existing window was brought forward.
    @discardableResult
    static func presentExisting() -> Bool {
        // `canBecomeMain` excludes the status-item and panel windows AppKit keeps
        // around; without it this matches the menu bar's own window and "Open
        // Mynah" silently does nothing.
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) }) else {
            return false
        }
        window.makeKeyAndOrderFront(nil)
        return true
    }

    static func present(using openWindow: OpenWindowAction) {
        NSApp.activate(ignoringOtherApps: true)
        if presentExisting() { return }
        openWindow(id: MynahWindowID.main)
    }
}

// MARK: - App

@main
struct MynahApp: App {
    @NSApplicationDelegateAdaptor(MynahAppDelegate.self) private var appDelegate
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup(id: MynahWindowID.main) {
            // No root `.tint`, and that is a decision rather than an omission.
            //
            // Platform chrome — the sidebar's selection capsule, pop-up buttons,
            // the default button in a confirmation dialog — keeps the accent the
            // owner chose in System Settings, because that is what every other
            // Mac app on their machine does. Tinting the root yellow would put a
            // white sidebar label on `accent.fill`, which fails to read at all.
            // MYNAH's accent is for the surfaces MYNAH draws itself: the
            // selected option card, the recommendation sparkle, focus rings,
            // switches, and the spinners inside our own fields. See
            // `Palette.accent`.
            RootView(appDelegate: appDelegate)
                .environment(app)
                .mynahTextSize(app.textSize)
        }
        .defaultSize(width: 1180, height: 820)
        // `.contentMinSize` rather than `.contentSize`: the owner can make the
        // window as large as they like, but never small enough to clip the
        // action row off a stage.
        .windowResizability(.contentMinSize)
        .commands {
            // There is one MYNAH. A second window would show the same appliance
            // twice and give the owner two places to look for one answer.
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(app)
        } label: {
            Image(systemName: app.effectivePresence.menuBarSymbol)
                .accessibilityLabel("Mynah — \(app.effectivePresence.verb)")
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Four verbs and one state line. A menu-bar menu is not a control panel; if a
/// setting needs explaining it belongs in Settings, where there is room for the
/// sentence that explains it.
private struct MenuBarContent: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("Mynah — \(app.effectivePresence.verb)")

        Divider()

        Button("Open Mynah") {
            MainWindowPresenter.present(using: openWindow)
        }

        Button(app.isPaused ? "Resume answering" : "Pause answering") {
            app.isPaused.toggle()
        }

        Divider()

        Button("Quit Mynah") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
