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
            // The nice voice, fetched here rather than only when a phone is
            // linked.
            //
            // **It failed silently for the owner and the silence was
            // structural, not a bug in the download.** The only trigger lived
            // inside the Signal link flow, chosen deliberately — *"the signal
            // part //call only comes in once you link signal - download it
            // then"* — which is a good trigger and the wrong *only* trigger.
            // Anybody who linked their phone before that code existed never ran
            // it, gets no assets, and `CallVoiceLibrary.load()` answers
            // `.missing`, so `//call` falls back to the macOS built-in voice.
            // He heard a robot and reasonably assumed it was the model's doing:
            // *"i am reaching 'robot voice' instead of the nice sounding one
            // and i am already on deepseekv4 api"*.
            //
            // Every launch, because that is what makes it self-healing: the
            // installer no-ops in microseconds when the files are already there
            // and verified, so the cost of asking again is nothing and the cost
            // of never asking is a robot.
            Task { await app.installCallVoiceIfNeeded() }
            // Who Mynah can reach, asked once, here.
            //
            // The owner's ruling: *"let mynah get it from mcp or we do it at
            // app boot"*. It used to be read on every appearance of the Agents
            // page, unsigned — an app asking a question as nobody, repeatedly.
            // At boot it is a startup fact instead, and opening that page a
            // dozen times asks the node once. See `ApplianceRoster`.
            Task { await ApplianceRoster.shared.loadOnce() }
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
        .task {
            // Started on the *first* screen, and the timing is the whole point.
            //
            // A fresh vendored node cannot remember anything until governed
            // app-v24 activates, which is roughly thirteen minutes of block
            // production after genesis. Starting it on the Ready screen — where
            // this used to live — put all thirteen of those minutes *after* the
            // owner had been told setup was finished, so the first thing a new
            // appliance did was forget everything said to it.
            //
            // Here, the wait runs underneath choosing a brain, pulling a model
            // and pasting a key, and is usually over before anyone reaches the
            // end. Nothing on the way to Ready depends on it: the brain stages
            // choose an LLM provider, which is a separate question from the
            // memory node.
            //
            // Safe to call early for the same reasons it was safe to call late
            // — the supervisor is lazy about an already-running node, refuses a
            // vendored copy below the floor, and holds a cooldown against spawn
            // loops. On a Mac that already runs SAGE this is a no-op.
            await model.startSageNodeEarly()
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

    /// What the node says about the appliance's own key, or nothing yet.
    ///
    /// `nil` until the first check answers, and the screen says nothing while it
    /// is `nil` — a warning that flickers on half a second after the owner has
    /// read "Mynah is ready" is worse than one that arrives with the screen.
    @State private var writeReadiness: ApplianceWriteReadiness?

    /// How far a brand-new node is from being able to remember, or `nil` when
    /// there is nothing to say — no node answered, or it answered and is ready.
    ///
    /// Separate from `writeReadiness` because the two describe different
    /// problems that happen to share a symptom. A restricted mask needs a person
    /// to act and stays wrong until they do; this one needs nothing and fixes
    /// itself on a schedule. Telling them apart is the difference between "ask
    /// your administrator" and "give it a few minutes".
    @State private var activation: SageActivationState?

    private var unfinished: [AppModel.DeferredStep] { app.deferredSetupSteps }

    /// Read from `voice`'s type and never re-derived.
    ///
    /// The condition is subtler than it looks: the Companion profile an
    /// administrator assigns *keeps* all three write denials, so anything keyed
    /// on "is it restricted" would warn forever at an owner who had done
    /// everything right. `needsTheOwner` is true for exactly one mask — the
    /// untouched self-registration default. Asking that question here rather
    /// than answering it again is the whole point of the property existing.
    ///
    /// **Known limitation, and it is narrow: this can be wrong for a
    /// half-applied remedy.** The mask and subject ownership are two separate
    /// transactions, so an administrator who assigns Mynah a subject but never
    /// assigns it the Companion profile leaves an agent still on the default
    /// mask that *can* write — bit 8 only denies writing a subject the agent
    /// does **not** own. That agent has saved things and this screen would still
    /// say it cannot. It is precisely the state produced by following our own
    /// remedy and stopping one step early. `voice` found it; narrowing the
    /// condition is theirs, and the constraint on any narrowing is that it must
    /// not be able to make the warning go *silent* rather than wrong — an
    /// administrator taking a subject back leaves the same mask on an appliance
    /// that is mute again, and a false silence is the failure nobody ever
    /// reports. The observed signal, `SageRitual.writeDenial`, is what covers
    /// that case, and this screen should render it beside this one once it is
    /// exposed.
    private var cannotRemember: Bool { writeReadiness?.needsTheOwner == true }

    /// A node that is up, is fine, and simply is not finished being born.
    ///
    /// False while `activation` is nil, which covers both "no node answered"
    /// and "not asked yet". Saying nothing is right for both: an owner who has
    /// their own SAGE never sees this, and one whose node is genuinely missing
    /// has a different problem that this sentence would misdescribe.
    private var memoryStillActivating: Bool { activation.map { !$0.isActivated } ?? false }

    var body: some View {
        StageShell(
            stageTitles: titles,
            currentIndex: SetupModel.Stage.ready.rawValue,
            glyph: markName,
            title: title,
            subtitle: subtitle
        ) {
            VStack(alignment: .leading, spacing: s4) {
                writeWarning
                activationNotice
                MynahCard(density: .hero) {
                    VStack(spacing: 0) {
                        StatusLine(
                            "Where your words go",
                            value: destination,
                            // A destination is not a fault — see `Palette.state`.
                            tone: model.selectedOption?.keepsWordsOnDevice == true ? .good : .neutral
                        )
                        MynahDivider()
                        StatusLine(
                            "Answering with this window closed",
                            value: app.keepsAnsweringWhenClosed ? "On" : "Off",
                            tone: app.keepsAnsweringWhenClosed ? .good : .neutral
                        )
                        // A pause the owner set before this build, or before
                        // this install. The marker lives in Application Support
                        // and survives both, so somebody who paused Mynah weeks
                        // ago reaches the end of setup with an appliance that
                        // will not answer — and every other line on this card
                        // says everything is fine. Stated here because this is
                        // the card that summarises what is true.
                        if app.isPaused {
                            MynahDivider()
                            StatusLine("Answering", value: "Paused", tone: .neutral)
                        }
                        ForEach(unfinished) { step in
                            MynahDivider()
                            StatusLine(step.title, value: "Not done", tone: .neutral)
                        }
                    }
                }
                backgroundHelperNote
                resumeOffer
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
        // Asked here rather than trusted from earlier in the flow: the mask is
        // stamped by consensus when the key registers, which may only just have
        // happened. Unauthenticated and on loopback, so it costs nothing and
        // works before any identity has been established.
        // Starts a node if nothing is listening, because on a Mac that never had
        // SAGE nothing ever did: Mynah only spawns `sage-gui mcp`, which is a
        // client. Lazy, so a Mac already running SAGE is untouched.
        .task { writeReadiness = await ApplianceWriteReadinessCheck().checkStartingNodeIfNeeded() }
        // Polled rather than read once, because this is the one number on the
        // screen that is *expected* to change while somebody watches it. Five
        // seconds is slower than a block and fast enough that the remaining
        // minutes never look stuck.
        //
        // Ends the moment consensus reports app-v24, and ends for good: the
        // loop returns rather than idling, because activation does not come
        // back once it has happened.
        .task {
            while !Task.isCancelled {
                let state = await SageActivationProbe().read()
                activation = state
                if state?.isActivated != false { return }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    // MARK: The promise this screen makes

    /// **The one thing this screen must not do is say "ready" when it isn't.**
    ///
    /// Ready is where trust is established: it is the moment an owner is told
    /// the thing is set up and works. On a node where the appliance still
    /// carries the untouched self-registration mask, "Mynah is ready." is a
    /// promise it cannot keep — it will answer them warmly and remember nothing,
    /// and they will find out a week later, if ever. That is the same
    /// false-confidence failure that was in the memories empty state and the
    /// task board, arriving at the highest-stakes moment in the product.
    /// Ordered worst first, and the order is the argument.
    ///
    /// Not remembering outranks being paused: a pause is visible, deliberate and
    /// one click from undone, while an appliance that answers and stores nothing
    /// looks exactly like a working one. When both are true the graver claim
    /// takes the title and the pause is stated on the card below it, so neither
    /// is lost.
    private var title: String {
        if !unfinished.isEmpty { return "One thing left." }
        // Both at once, and it is the state the owner's own machine is in:
        // capability mask 30 *and* a pause marker left over from a previous
        // install. Handled first because neither single-condition sentence
        // survives the other — "can answer" is false while paused, and "ready"
        // is false while it cannot save. Ordering by which is graver settles
        // which fact leads; it does not licence a title to assert the thing the
        // other condition contradicts.
        if app.isPaused && cannotRemember { return "Mynah is paused, and can't remember yet." }
        // Not a softened "almost ready". It can answer — that part is true and
        // worth saying — and it cannot remember, which is the fact the banner
        // below then explains.
        //
        // A node still waiting on app-v24 reaches the same sentence by a
        // different road, and it has to: for the minutes it lasts the appliance
        // really will answer and really will not remember, and an owner who is
        // told "ready" and then finds it forgot the conversation has been
        // misled just as surely as by a bad capability mask. What differs is the
        // explanation underneath, not the claim up here.
        if cannotRemember || memoryStillActivating { return "Mynah can answer, but not remember yet." }
        // The pause marker outlives the app that set it. Somebody who paused
        // Mynah weeks ago, or in a previous install, finishes setup with an
        // appliance that will not answer — and "Mynah is ready." would be the
        // last thing they read before a silent phone.
        if app.isPaused { return "Mynah is ready, but paused." }
        return "Mynah is ready."
    }

    /// The drawing is the end of the setup story — a machine settled and
    /// listening — and it is only true when there is nothing left to do.
    ///
    /// The unfinished branch used to draw `iphone.gen3`, which was right when
    /// the only step anyone could defer was linking a phone. Linking came off
    /// the gate, so the one deferrable step left is the API key — and the flow
    /// already has a drawing of a key held inside the machine that keeps it.
    /// A phone here would now illustrate the wrong problem entirely.
    ///
    /// The paused branch exists for the same reason the title has one: the ready
    /// drawing is *a machine settled and listening, with a small light on it*,
    /// and rendering it above a headline that says "paused" is a picture
    /// contradicting the sentence beside it. `moon` is not a new invention —
    /// `AppModel.Presence.sleeping` and `TalkView`'s empty state already draw a
    /// paused appliance that way, and one state should not acquire two pictures.
    private var markName: String {
        if !unfinished.isEmpty { return StageIllustration.mark(.connect) }
        if app.isPaused { return "moon" }
        // Points where the sentence points.
        if cannotRemember { return "person.2" }
        // Not `person.2`: nobody needs to be found, and not the ready drawing
        // either, which would leave the picture saying "done" over a title that
        // says "not yet". Waiting is the honest subject.
        if memoryStillActivating { return "hourglass" }
        return StageIllustration.mark(.ready)
    }

    /// `voice`'s sentence, rendered rather than rewritten.
    ///
    /// `shortRemedy` and not `remedy`: this is a moment when somebody is waiting
    /// to press a button, not reading a settings page, and the full mechanism
    /// lives on the one page they go to when they want it. There is exactly one
    /// remedy in the product and a test asserting the surfaces agree — a third
    /// phrasing invented here would quietly undo that.
    ///
    /// No reinstall, and not because I remembered: the string comes from
    /// `SageVoiceCore` and cannot acquire one here. The identity survives
    /// deleting the app and comes back with the same mask, so a reinstall is
    /// the instinctive fix that provably cannot work.
    @ViewBuilder
    private var writeWarning: some View {
        if let readiness = writeReadiness,
           let headline = readiness.headline,
           let remedy = readiness.shortRemedy {
            InlineBanner(headline: headline, explanation: remedy)
                .frame(maxWidth: MynahWidth.stageColumn)
        }
    }

    /// The countdown, shown only when there is nothing for the owner to do.
    ///
    /// Suppressed while `writeWarning` has something to say, and that ordering
    /// is deliberate: a restricted mask needs a person and does not go away on
    /// its own, so telling somebody to wait a few minutes for a problem that
    /// will still be there afterwards is worse than saying nothing. One thing
    /// to read, and it is the one that needs acting on.
    ///
    /// No remedy line, because there is no remedy and inventing one would
    /// manufacture work. It says what is happening and roughly how long.
    @ViewBuilder
    private var activationNotice: some View {
        if !cannotRemember, let activation, !activation.isActivated {
            InlineBanner(
                headline: activation.ownerDescription,
                explanation: "Your SAGE brain is finishing its first-time setup. "
                    + "You can carry on — anything you say before it's done just won't be remembered."
            )
            .frame(maxWidth: MynahWidth.stageColumn)
        }
    }

    /// Said here because macOS is about to say it first, and less kindly.
    ///
    /// Turning answering on writes a LaunchAgent, and on this OS that produces a
    /// system notification — *"Mynah added items that can run in the
    /// background"* — plus an entry in System Settings under Login Items. An
    /// owner who has just finished setting up a private voice appliance and is
    /// then told by their Mac that it added background items, with no warning
    /// from the app, has every reason to wonder what else it did quietly.
    ///
    /// So: what it is, why it exists, and what switching it off costs. The last
    /// part is the one nothing anywhere said — the helper is how the phone gets
    /// answered, and turning it off in Login Items stops that silently.
    ///
    /// Only when answering is actually on. A note about a helper that is not
    /// being installed would be a warning about nothing.
    @ViewBuilder
    private var backgroundHelperNote: some View {
        if app.keepsAnsweringWhenClosed {
            InlineBanner(
                headline: "Your Mac will say Mynah added a background item.",
                explanation: "That is this: a small helper that answers your phone while the "
                    + "window is closed. It appears in System Settings under General → Login "
                    + "Items & Extensions, and switching it off there stops Mynah answering."
            )
        }
    }

    /// The one click that undoes it, on the screen that says it is true.
    ///
    /// The alternative was to state the pause and let the owner find Resume on
    /// the next screen. That is a worse trade than it sounds: the marker
    /// survives reinstalling, so the person most likely to meet this is someone
    /// who paused Mynah long enough ago to have forgotten, arriving at the end
    /// of setup to be told their brand-new install will not answer. Being told
    /// and being able to fix it in the same breath is the difference between
    /// "it is broken again" and "it noticed".
    ///
    /// Shown in the same card shape as the phone offer, and never at the same
    /// time as anything else competing for the eye — a pause is rare, and when
    /// it is there it is the most actionable thing on the screen.
    @ViewBuilder
    private var resumeOffer: some View {
        if app.isPaused {
            MynahCard {
                HStack(alignment: .top, spacing: s5) {
                    VStack(alignment: .leading, spacing: s2) {
                        Text("Mynah is paused")
                            .mynahFont(.title3)
                            .foregroundStyle(Palette.ink.primary)
                        // Says where it came from. Somebody who has just
                        // installed a fresh copy and is told it is paused will
                        // otherwise reasonably conclude the app arrived broken.
                        Text("You paused it at some point — the setting outlives the app, so a "
                             + "new copy finds it again. Start it and it answers straight away.")
                            .mynahFont(.callout)
                            .foregroundStyle(Palette.ink.secondary)
                            .mynahProse()
                    }
                    Spacer(minLength: s4)
                    MynahButton("Start answering", kind: .secondary) { app.isPaused = false }
                }
            }
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

    private var subtitle: String? {
        guard unfinished.isEmpty else {
            // The fourth case, and the same shape as the title's: "Mynah will
            // answer as soon as you finish it" is a promise about what happens
            // after the deferred step, and it is false while a pause marker is
            // on disk — finishing the step changes nothing until the appliance
            // is started again. The title above stays "One thing left.", which
            // is understated rather than untrue; this sentence was the one that
            // actually made a claim it could not keep.
            if app.isPaused {
                return "Finish it and start Mynah answering — both are waiting in Settings "
                    + "whenever you're ready."
            }
            return "Mynah will answer as soon as you finish it — and it's waiting in Settings "
                + "whenever you're ready."
        }
        // Nothing, when the banner below is about to say the thing that matters.
        // A cheerful line about first-answer latency sitting above a warning
        // that nothing will be remembered is the screen talking over itself, and
        // any sentence written here would be a second remedy in different words.
        guard !cannotRemember else { return nil }
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
    case memories
    /// Not a section of Settings, and the distinction is the point: there is
    /// nothing here to change. Settings answers "how is this set up"; this
    /// answers "what does it tell anyone", which is the question this product
    /// exists to have a good answer to. Placed before Settings for the same
    /// reason — it is an argument, not an appendix.
    case privacy
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .memories: return "Memories"
        case .privacy: return "Privacy"
        case .settings: return "Settings"
        }
    }

    /// `person.2` for agents rather than a network or a node graph. The owner's
    /// own words for this are "ask Perplexity to look it up"; they are asking
    /// somebody, and a topology diagram is the operator's picture, not theirs.
    var glyph: String {
        switch self {
        case .home: return "waveform"
        case .memories: return "text.append"
        // The glyph this app already uses for "sends your words off this Mac",
        // on the brain-choice cards. Not a lock and not a shield: `OptionCard`
        // settled that — a padlock for "private" is security theatre, and this
        // page's whole claim is that it states facts rather than performing
        // safety.
        case .privacy: return "arrow.up.forward.app"
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
        // Not "Who Mynah can ask", which was the previous line and carried the
        // exact false promise the owner objected to on the page itself: "ask"
        // says Mynah can query these agents' memories, and it cannot — reading
        // another agent's subjects needs a grant, and none has been given.
        // Sending, which it *can* do, is not asking.
        //
        // This claims presence and nothing about capability, which leaves the
        // asymmetry to be stated once above the roster where there is room to
        // state both halves of it. Deliberately not "Others on your network":
        // the page has a section by almost that name for a genuinely different
        // set — other machines — and the roster underneath is the local half.
        // `thread`'s call, and their reasoning: it undersells the post-scan
        // case, and underselling is recoverable where overclaiming is what put
        // us here.
        case .memories: return "What Mynah remembers"
        case .privacy: return "What leaves this Mac"
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
        case .memories: MemoriesView()
        case .privacy: PrivacyView(onOpenSection: { selection = $0 })
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
            // `.well` is the largest glyph size the scale has short of `.hero`,
            // which is the single 30pt mark on an empty state and would be a
            // cartoon in a list. This was `.card` at 18pt, which is a card
            // header's size — a step up from a default sidebar label and not
            // what "big icons" meant. The owner asked twice.
            Image(systemName: section.glyph)
                .mynahIcon(.well)
                // A fixed column so four glyphs of different widths still leave
                // their titles on one vertical line.
                .frame(width: 30, alignment: .center)
            VStack(alignment: .leading, spacing: 1) {
                // `.title2`, the card-title size, rather than `.title3`, the
                // list-row size. This is the app's primary navigation and it
                // should not be set at the density of a settings list.
                Text(section.title).mynahFont(.title2)
                Text(section.summary)
                    .mynahFont(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        // Four destinations in a window this wide can afford the air. The rows
        // land near 56pt, which is roughly twice a stock sidebar row — the
        // point of the change rather than a side effect of it.
        .padding(.vertical, s4)
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
            // Baseline-aligned so the version sits *on* the wordmark's line
            // rather than centred against its cap height, which reads as a
            // second word rather than a footnote to the first.
            HStack(alignment: .firstTextBaseline, spacing: s2) {
                Text("Mynah")
                    .mynahWordmark()
                    .foregroundStyle(Palette.ink.primary)
                // **Which build am I looking at**, answered without opening
                // Settings. Asked for after an afternoon of installing four of
                // these: the DMG in the Dock, the app in /Applications and the
                // daemon answering the phone were repeatedly three different
                // builds, and nothing on screen said so.
                //
                // Tertiary and mono: present when looked for, and quiet enough
                // that the column still reads as a wordmark rather than a
                // version banner.
                Text(MynahReleaseVersion.currentBuildLabel())
                    .mynahFont(.mono)
                    .foregroundStyle(Palette.ink.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, s5)
        .padding(.bottom, s5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Mynah, version \(MynahReleaseVersion.currentBuildLabel())")
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
