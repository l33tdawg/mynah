import AppKit
import Observation
import OSLog
import SageVoiceCore
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
            case .listening: return "Online"
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

    /// Which half of Home is on screen.
    ///
    /// Two modes rather than a draggable split, which is what the owner asked
    /// for after talking himself out of dragging in the same sentence: "you
    /// don't always want chat to be so big but at the same time you don't always
    /// need to see all tasks list thing". A drag gives somebody a fiddly control
    /// and a position they then have to maintain; this is reading, or talking,
    /// and both is the default.
    enum HomeSplit: String, CaseIterable, Sendable {
        case both
        /// The board, with the transcript folded away. The composer stays —
        /// collapsing the conversation must not take away the ability to ask for
        /// something, or the board becomes a thing you can only read.
        case boardOnly
        /// The conversation, with the board folded away.
        case conversationOnly

        var showsBoard: Bool { self != .conversationOnly }
        var showsConversation: Bool { self != .boardOnly }
    }

    private enum Key {
        static let setupComplete = "mynah.setupComplete"
        // Deliberately absent: `paused`.
        //
        // It was a `UserDefaults` mirror of the `paused` marker file, and the
        // two disagreeing is the bug documented on `isPaused`. The marker is
        // the store the daemon obeys and the one that survives a reinstall, so
        // there is nothing a defaults copy can be right about that it is not.
        // A stale key left behind by an older build is harmless — nothing reads
        // it now.
        static let keepAnswering = "mynah.keepAnsweringWhenClosed"
        static let textSize = "mynah.textSize"
        static let deferredSteps = "mynah.deferredSetupSteps"
        static let homeSplit = "mynah.homeSplit"
        static let tooltips = "mynah.showsTooltips"
    }

    /// Live state, owned by whatever is driving turns. Not persisted — a
    /// restarted app has not started answering anything yet.
    var presence: Presence = .sleeping

    /// Whether the appliance is answering.
    ///
    /// **One store, and it is the file.** This used to be written to both
    /// `UserDefaults` and `PauseState`, and the two could disagree — which they
    /// did, on the owner's machine, twice in an hour, each time swallowing a
    /// message he was waiting on. `bridge.log`:
    ///
    ///     [daemon] paused — ignoring: are you online ??
    ///
    /// The window said Online throughout. Two mechanisms produced that:
    ///
    /// 1. `didSet` does not fire for an assignment in an initializer, so the
    ///    launch path wrote `UserDefaults` into this property and never wrote
    ///    the file. The two could differ from the first frame.
    /// 2. `UserDefaults` lives in the app container and the `paused` marker
    ///    lives in Application Support, which **survives a reinstall**. So a
    ///    fresh build came up believing it was running while a stale marker
    ///    from a previous install was still on disk telling the daemon to
    ///    ignore everything. Toggling Pause and Resume fired `didSet` twice and
    ///    rewrote the file, which is the ritual the owner discovered for
    ///    himself and reported as "I need to click pause and resume".
    ///
    /// So the file is the only store now. It is the one the daemon actually
    /// obeys, it is the one that survives, and a second copy that is
    /// authoritative-except-when-it-is-not is what produced the bug. Do not
    /// reintroduce a `UserDefaults` mirror; there is nothing for it to be right
    /// about that the file is not already right about.
    var isPaused: Bool {
        didSet {
            // A no-op assignment must stay a no-op. Rewriting the marker with
            // the same value would move its modification date, and that date is
            // what `PauseState.pausedAt()` reports as "paused since 14:32".
            guard oldValue != isPaused else { return }
            // Set while adopting the file's own state — the file is already
            // correct and writing it back would be the same mtime bug.
            guard !isAdoptingPauseStateFromDisk else { return }
            do {
                try pauseState.setPaused(isPaused)
            } catch {
                // Surfaced rather than swallowed: a Pause that silently failed
                // to take is the exact bug being fixed.
                Self.log.error("could not record pause state: \(String(describing: error), privacy: .public)")
            }
            Task { await reconcileAnsweringService() }
        }
    }

    /// The pause marker this app reads and writes.
    ///
    /// Injected so a test can point at a temporary file. Without that, every
    /// test constructing an `AppModel` would read the *developer's own*
    /// `~/Library/Application Support/SAGE Voice Bridge/paused` and pass or
    /// fail depending on whether they happened to have Mynah paused — which is
    /// precisely the class of hidden shared state this whole change is about.
    private let pauseState: PauseState

    /// Suppresses the `didSet` writer while state is being adopted *from* the
    /// file rather than written *to* it.
    private var isAdoptingPauseStateFromDisk = false

    /// Re-reads the marker and adopts it.
    ///
    /// The window caches this state to drive its own UI, and the daemon reads
    /// the file per message — so the window is the half that can go stale. It
    /// goes stale for real reasons, not theoretical ones: the marker is
    /// process-shared state like `CallPreferences`, so a second window, the
    /// daemon, a future `//pause` command, or the owner deleting the file by
    /// hand all change it underneath a running app.
    ///
    /// Called on launch and whenever the app becomes active, which covers every
    /// way the owner can see the window again after something else moved it.
    func refreshPauseState() {
        guard adoptPauseStateFromDisk() else { return }
        Task { await reconcileAnsweringService() }
    }

    /// - Returns: whether the window's copy actually changed.
    @discardableResult
    private func adoptPauseStateFromDisk() -> Bool {
        let onDisk = pauseState.isPaused()
        guard onDisk != isPaused else { return false }
        isAdoptingPauseStateFromDisk = true
        isPaused = onDisk
        isAdoptingPauseStateFromDisk = false
        Self.log.info("adopted pause state from disk: \(onDisk ? "paused" : "answering", privacy: .public)")
        return true
    }

    /// Everything worth re-checking when the owner comes back to the window.
    ///
    /// Two questions, and the second one had nobody asking it. The first is
    /// what the pause marker says, which another process may have changed. The
    /// second is whether launchd is actually running what this app believes it
    /// installed — and until now the app only ever *wrote* its intentions and
    /// never read back what happened to them.
    ///
    /// That gap is not theoretical. On 29 July both LaunchAgents were deleted
    /// out from under a running app, and it then spent half an hour with setup
    /// complete, answering switched on and no pause marker — believing it was
    /// answering the owner's phone while nothing at all was installed. Nothing
    /// noticed, because reconciliation only ever happened on launch and on
    /// change, and neither had happened since. Only quitting and relaunching
    /// brought it back.
    ///
    /// Asking on every activation is only affordable because `enable` now
    /// leaves an already-correct system alone; before that this would have been
    /// a teardown every time the owner looked at their window. The two changes
    /// are a pair and it would be a mistake to keep this one without the other.
    func catchUpWithTheMachine() async {
        adoptPauseStateFromDisk()
        await reconcileAnsweringService()
    }

    private static let log = Logger(subsystem: "local.sage.voicebridge", category: "pause")

    /// The daemon keeps running with the window closed. This is the owner's
    /// switch for the phone bridge, phrased in Settings as "Keep answering
    /// from my phone".
    var keepsAnsweringWhenClosed: Bool {
        didSet {
            defaults.set(keepsAnsweringWhenClosed, forKey: Key.keepAnswering)
            Task { await reconcileAnsweringService() }
        }
    }

    var textSize: MynahTextSize {
        didSet { defaults.set(textSize.rawValue, forKey: Key.textSize) }
    }

    /// Persisted, because a collapse that resets overnight is worse than none —
    /// the owner would fold the same half away every morning.
    var homeSplit: HomeSplit {
        didSet { defaults.set(homeSplit.rawValue, forKey: Key.homeSplit) }
    }

    /// Whether hover explanations appear.
    ///
    /// On until turned off: somebody meeting this app needs the explanations,
    /// and the owner switching them off is a choice they make once they do not.
    /// Nothing load-bearing is behind them — see `MynahTooltip`.
    var showsTooltips: Bool {
        didSet { defaults.set(showsTooltips, forKey: Key.tooltips) }
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
    private let backgroundServices: any SignalBackgroundServicing
    private let serviceConfiguration: () -> SignalServiceConfiguration?
    private(set) var answeringServiceError: String?

    /// - Parameter backgroundServices: **inject this from a test, whatever the
    ///   test is about.** The default is the shared manager, and the shared
    ///   manager is aimed at the real home directory — so a test that omits it
    ///   is holding the live appliance of the machine it is running on.
    ///
    ///   That is not theoretical. On 29 July tests about the *pause marker*
    ///   deleted both LaunchAgent plists out of `~/Library/LaunchAgents`, and
    ///   the owner's phone went unanswered for an hour while the window carried
    ///   on working. No test failed and nothing logged, which is why it read as
    ///   a product regression and was looked for in entirely the wrong place.
    ///
    ///   The manager now refuses to touch launchd when a test reaches the real
    ///   home, so forgetting cannot destroy anything. Inject anyway: only three
    ///   members reach `reconcileAnsweringService` today — `isPaused`,
    ///   `keepsAnsweringWhenClosed` and `refreshPauseState()` — and the day
    ///   somebody adds a fourth, every un-injected site arms itself at once and
    ///   says nothing. `Tests/SageVoiceCoreTests/InertAppliance.swift`.
    init(
        defaults: UserDefaults = .standard,
        backgroundServices: any SignalBackgroundServicing = SignalBackgroundServiceManager.shared,
        serviceConfiguration: (() -> SignalServiceConfiguration?)? = nil,
        pauseState: PauseState = PauseState()
    ) {
        self.defaults = defaults
        self.backgroundServices = backgroundServices
        self.serviceConfiguration = serviceConfiguration
            ?? { SignalServiceConfiguration.current(defaults: defaults) }
        self.hasCompletedSetup = defaults.bool(forKey: Key.setupComplete)
        self.pauseState = pauseState
        // The file, not `UserDefaults`. An assignment in an initializer does
        // not fire `didSet`, so whatever is read here is simply believed — and
        // believing the wrong store is what let the window say Online while the
        // daemon dropped the owner's messages. Reading the file means the
        // belief and the fact are the same thing at launch.
        self.isPaused = pauseState.isPaused()
        // Absent means "not yet asked", and the appliance is useless if it stops
        // when the window closes, so the default is on.
        self.keepsAnsweringWhenClosed = defaults.object(forKey: Key.keepAnswering) as? Bool ?? true
        self.textSize = (defaults.string(forKey: Key.textSize).flatMap(MynahTextSize.init(rawValue:))) ?? .standard
        // Absent means "never collapsed anything", and seeing both halves is the
        // right first impression of a window that holds two things.
        self.homeSplit = (defaults.string(forKey: Key.homeSplit).flatMap(HomeSplit.init(rawValue:))) ?? .both
        // Absent means never asked, and the answer for a first run is yes.
        self.showsTooltips = defaults.object(forKey: Key.tooltips) as? Bool ?? true
        // Decode failures leave the list empty rather than throwing: a step the
        // owner deferred is a reminder, and a reminder is never worth refusing
        // to launch over.
        if let data = defaults.data(forKey: Key.deferredSteps),
           let steps = try? JSONDecoder().decode([DeferredStep].self, from: data) {
            self.deferredSetupSteps = steps
        }
        // `didSet` does not fire during init, so without this an app that
        // launches already paused would leave the daemon answering — the owner
        // paused yesterday, quit, came back, and the switch reads Paused while
        // the phone is being answered. The owner's saved preference is the
        // intent; the file is how the other process hears about it.
        try? PauseState().setPaused(self.isPaused)
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
        Task { await reconcileAnsweringService() }
    }

    /// What the app can honestly conclude the appliance should be doing.
    ///
    /// **Three answers, not two**, and the third is the whole point. This used
    /// to be one `guard` with four conditions falling through to `disable()`,
    /// which meant "the owner turned answering off" and "I could not work out
    /// what to run" took the same branch — and that branch does not stop the
    /// appliance, it *removes* it: `disable()` deletes both LaunchAgent plists
    /// so they cannot come back at the next login.
    ///
    /// So any momentary failure to read a file uninstalled the owner's phone
    /// bridge permanently. It happened: on 29 July the plists were deleted at
    /// 11:40 and Signal stopped answering for half an hour while the window
    /// carried on working, because the window does not go through the bridge.
    /// Nothing recorded why, which is the other half of the fix.
    ///
    /// The rule, and it is worth keeping: **uncertainty must never destroy.**
    /// A decision the owner made is acted on. A question the app failed to
    /// answer changes nothing and says so.
    ///
    /// **The general form, which this codebase found four times in one day:
    /// when an action is irreversible, prove the precondition — never infer it
    /// from an absence.** A configuration that could not be built became "he
    /// turned it off". A closed port became "the process is gone". A key the
    /// node did not recognise returned no memories, which read as "there are
    /// none". A write that was refused returned success. Every one of them is a
    /// branch whose real condition is *not knowing something*, dressed as a
    /// confident negative.
    ///
    /// So the corollary, and the reason this type has three cases rather than a
    /// `Bool`: **"I could not tell" deserves its own branch, and that branch
    /// does nothing.** If you are ever tempted to collapse `cannotTell` into
    /// `stop` because both mean "not running right now" — they do not. One is
    /// what the owner asked for and the other is what the app failed to find
    /// out, and only one of them justifies deleting their phone bridge.
    enum AnsweringIntent: Sendable, Equatable {
        /// The owner wants it answering, and everything it needs resolved.
        case run(SignalServiceConfiguration)
        /// The owner wants it off. A decision, so it is carried out.
        case stop(reason: String)
        /// Something could not be read. Not a decision, so nothing happens.
        case cannotTell(reason: String)
    }

    /// Internal rather than private so a test can assert the third case exists
    /// and is reached — the branch is invisible from the outside precisely
    /// because its correct behaviour is to do nothing.
    func answeringIntent() -> AnsweringIntent {
        guard hasCompletedSetup else {
            return .stop(reason: "setup has not finished")
        }
        guard keepsAnsweringWhenClosed else {
            return .stop(reason: "the owner turned off answering from the phone")
        }
        guard !isPaused else {
            return .stop(reason: "the owner paused answering")
        }
        guard let configuration = serviceConfiguration() else {
            // The three inputs are the linked Signal account, the signal-cli
            // binary and the stored brain choice. Each is a file read, and a
            // file read can fail for reasons that have nothing to do with what
            // the owner wants.
            return .cannotTell(reason: "the appliance configuration could not be read")
        }
        return .run(configuration)
    }

    /// Makes the persisted owner choices and the two launchd jobs agree.
    ///
    /// Called after setup, after a QR link in Settings, on app launch, and by
    /// both answering switches. Safe to call repeatedly: the manager compares
    /// what it would write against what is already loaded and does nothing when
    /// they match, so an unnecessary call no longer costs the owner a restart
    /// of signal-cli.
    func reconcileAnsweringService() async {
        switch answeringIntent() {
        case .run(let configuration):
            do {
                try await backgroundServices.enable(configuration)
                answeringServiceError = nil
            } catch {
                answeringServiceError = error.localizedDescription
                presence = .needsOwner
            }
        case .stop(let reason):
            // The reason travels *into* the removal rather than being logged
            // beside it, so the destructive line says what it did and why in
            // one sentence. Two adjacent lines is what we had, and correlating
            // them by timestamp is work somebody does at the wrong moment.
            await backgroundServices.disable(because: reason)
            answeringServiceError = nil
        case .cannotTell(let reason):
            // At error level on purpose. `.info` and `.debug` are not persisted
            // unless something opts the subsystem in, so the one line that
            // explains a dead phone bridge would be gone by the time anybody
            // went looking — which is exactly what happened on 29 July, and
            // cost an afternoon of eliminating four possibilities by hand.
            Self.appliance.error(
                "leaving the phone bridge as it is: \(reason, privacy: .public)"
            )
            // `answeringServiceError` is deliberately untouched. This is
            // neither a success nor a failure of what the owner asked for, and
            // clearing a real error here would hide a fault behind a shrug.
        }
    }

    private static let appliance = Logger(
        subsystem: "local.sage.voicebridge",
        category: "appliance"
    )

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
        // Backing out has to put the appliance back.
        //
        // `hasCompletedSetup` being false is a `stop` intent, so any reconcile
        // during a restart removes both LaunchAgents. Restoring the flag
        // without reconciling left an owner who opened "Change where your words
        // go" out of curiosity, then cancelled, with a window that says it is
        // answering and a phone that is not — recoverable only by quitting and
        // relaunching, because nothing else reconciles.
        Task { await reconcileAnsweringService() }
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

    /// Quitting closes every window, and the floating panel appears when windows
    /// close. Without this the last thing the owner sees on the way out is a
    /// panel arriving over their desktop for the length of one runloop hop.
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            FloatingHUDController.shared.applicationWillTerminate()
        }
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

    /// The same errand from a surface that has no SwiftUI environment to read
    /// `openWindow` out of — today, the floating panel.
    ///
    /// Goes through the delegate's stored action rather than duplicating the
    /// scene lookup, so there is still exactly one place that knows a
    /// `WindowGroup` cannot be focused and must be *opened*.
    static func presentFromAppKit() {
        NSApp.activate(ignoringOtherApps: true)
        if presentExisting() { return }
        (NSApp.delegate as? MynahAppDelegate)?.openMainWindow?()
    }
}

// MARK: - App

/// The app itself. `@main` lives in the thin `Mynah` executable target, because
/// nothing can import an executable and this target needs to be testable — see
/// `Sources/Mynah/main.swift` for what that omission cost.
public struct MynahApp: App {
    @NSApplicationDelegateAdaptor(MynahAppDelegate.self) private var appDelegate
    @State private var app = AppModel()

    public init() {}

    public var body: some Scene {
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
                // Set once at the root, like the text size, so no row has to be
                // handed the preference to know whether to offer an explanation.
                .environment(\.mynahShowsTooltips, app.showsTooltips)
                // Coming forward is when the owner is about to trust what this
                // window says, so it is when the window should stop trusting
                // its own memory. Two things get re-read: the pause marker,
                // which is shared with the daemon and survives a reinstall, and
                // launchd itself, which can have lost the appliance for reasons
                // this app never saw.
                //
                // Not a timer. Nothing here has to be live between glances —
                // the daemon reads the marker on every message, and the only
                // moment a stale window costs anything is the moment somebody
                // is reading it.
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: NSApplication.didBecomeActiveNotification
                    )
                ) { _ in
                    Task { await app.catchUpWithTheMachine() }
                }
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

/// Five verbs and one state line. A menu-bar menu is not a control panel; if a
/// setting needs explaining it belongs in Settings, where there is room for the
/// sentence that explains it.
private struct MenuBarContent: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Read inside `body` rather than held as a stored property: `body` is
        // already main-actor isolated, and reading `isVisible` here is what
        // makes the item below rename itself when the panel comes and goes.
        let hud = FloatingHUDController.shared

        Text("Mynah — \(app.effectivePresence.verb)")

        Divider()

        Button("Open Mynah") {
            MainWindowPresenter.present(using: openWindow)
        }

        // The only way back once the panel has been sent away, which is why it
        // sits beside "Open Mynah" rather than under a submenu. "Panel" is a
        // word an owner uses; it is not a class name leaking into the menu.
        //
        // Absent during onboarding rather than present and disabled: the panel
        // reports on a conversation that does not exist until setup finishes, so
        // the item would be a verb that leads nowhere — which is the one thing
        // every escape hatch in this app is written not to be.
        if app.hasCompletedSetup {
            Button(hud.isVisible ? "Hide the panel" : "Show the panel") {
                hud.toggleFromMenuBar()
            }
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
