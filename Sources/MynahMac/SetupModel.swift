import Foundation
import Observation
import OSLog
import SageVoiceCore

/// The onboarding state machine, and the only place the app talks to the core.
///
/// `@Observable` rather than `ObservableObject` because every value it exposes
/// comes from `SageVoiceCore`'s `Codable` value types — probe results, setup
/// choices, verdicts. Nothing here needs a bridging layer; the actor boundary
/// is crossed once, at `await`, and what comes back is already `Sendable`.
@MainActor
@Observable
final class SetupModel {

    /// Fixed order, never derived from what happens to be installed.
    ///
    /// QuietType computes its first-run stage from the first unmet condition,
    /// so a brand-new user's opening screen is a demand to install a consensus
    /// node. Readiness here only decides whether a stage can be skipped, never
    /// which stage comes first.
    ///
    /// **There is no phone stage, and its removal is the point.** Linking a
    /// phone was the fourth of five screens, which made an optional add-on look
    /// like a step of installing the product — and it is the step most likely to
    /// fail, because it needs a second device, a working camera and a QR code
    /// that expires. Gating a Mac app that has a working conversation, a board
    /// and a memory on a phone scan is asking someone to prove they own a phone
    /// before they may use their computer. It is offered on the Ready screen and
    /// lives in Settings, where anything optional belongs.
    enum Stage: Int, CaseIterable {
        case welcome
        case brain
        case key
        case ready

        var title: String {
            switch self {
            case .welcome: return "Welcome"
            case .brain: return "Brain"
            case .key: return "Connect"
            case .ready: return "Ready"
            }
        }
    }

    enum KeyState: Equatable {
        case notNeeded
        case waiting
        case checking
        case rejected(String)
        case accepted(String)

        var isBlocking: Bool {
            switch self {
            case .notNeeded, .accepted: return false
            case .waiting, .checking, .rejected: return true
            }
        }
    }

    private(set) var stage: Stage = .welcome
    private(set) var choices: BrainSetupChoices?
    private(set) var isProbing = false
    private(set) var probeFailure: String?
    private(set) var localBrainPhase: LocalBrainInstaller.Phase?

    var selectedOptionID: BrainSetupOptionID?
    var pastedKey: String = ""
    private(set) var keyState: KeyState = .waiting

    /// What the provider actually said, kept beside `keyState`.
    ///
    /// `keyState` carries a finished sentence for the owner. The connect screen
    /// needs the *kind* of failure as well, because each one earns a different
    /// offer: "Get a key" for a refusal, "Try again" for a Mac that is offline,
    /// "Choose a different brain" for a model that cannot drive the assistant.
    /// Recovering that by looking for words inside the sentence would be
    /// re-parsing copy this app wrote — which stops working the day someone
    /// rewords it, silently and in the owner's favour never.
    private(set) var lastVerdict: BrainKeyValidator.Verdict?
    private let localBrainInstaller: LocalBrainInstaller

    init(
        localBrainInstaller: LocalBrainInstaller = LocalBrainInstaller(),
        initialChoices: BrainSetupChoices? = nil
    ) {
        self.localBrainInstaller = localBrainInstaller
        self.choices = initialChoices
    }

    var selectedOption: BrainSetupOption? {
        guard let selectedOptionID, let choices else { return nil }
        return choices.option(withID: selectedOptionID)
    }

    /// Instructions for the chosen option, when it needs a key at all.
    ///
    /// Goes through `keyProviderIdentifier`, which is the one seam between an
    /// option's identity and the onboarding vocabulary. Passing
    /// `backendIdentifier` through raw is what produced the unrecoverable Google
    /// loop: the option's requirement said `.apiKey`, this lookup returned nil,
    /// and `advance()` read that as "needs no key" and skipped the only screen
    /// that could have satisfied the requirement.
    var keyInstructions: APIKeyOnboarding.Instructions? {
        guard let provider = keyProvider else { return nil }
        return APIKeyOnboarding.instructions(forProvider: provider)
    }

    /// The provider a pasted key belongs to — for the instructions, the shape
    /// check, and the file it is saved under. All three must agree.
    var keyProvider: String? {
        guard let option = selectedOption, option.requirement == .apiKey else { return nil }
        return option.keyProviderIdentifier
    }

    /// Whether the flow has a screen that can satisfy what the chosen option
    /// asks for.
    ///
    /// Fail-closed by design. A requirement with no stage behind it used to be
    /// resolved by skipping the stage — a `.apiKey` option with no instructions,
    /// or a `.signIn` option in a flow with no sign-in screen, walked straight to
    /// "Mynah is ready" for a brain that had never been connected to anything.
    var selectionIsSatisfiable: Bool {
        guard let option = selectedOption else { return false }
        guard option.id.backendPlan != nil else { return false }
        switch option.requirement {
        case .nothing:
            return true
        case .apiKey:
            return keyInstructions != nil
        case .download:
            return option.id == .fullyLocal
        case .signIn:
            return false
        }
    }

    // MARK: Probing

    func probe() async {
        isProbing = true
        probeFailure = nil
        defer { isProbing = false }

        let result = await EnvironmentProbe().run()
        let planned = BrainSetupPlanner().plan(for: result)
        choices = planned

        // The recommendation is shown, never applied. `BrainSetupSelection`'s
        // initialiser is internal precisely so nothing can auto-select a brain
        // on the owner's behalf — where their words go is their decision, and a
        // default that quietly sends speech to a cloud provider is the exact
        // failure this product exists to avoid.
        if planned.availableOptions.isEmpty {
            probeFailure = "This Mac can't run any of the options, and no cloud provider is reachable."
        }
    }

    // MARK: Navigation

    var canContinue: Bool {
        switch stage {
        case .welcome:
            return true
        case .brain:
            // Available *and* reachable. Availability is the planner's judgement
            // about this Mac; satisfiability is this flow's judgement about
            // whether it owns a screen that can finish the job.
            return selectedOption?.isAvailable == true
                && selectionIsSatisfiable
                && localBrainPhase?.isFinished != false
        case .key:
            return !keyState.isBlocking
        case .ready:
            return false
        }
    }

    func advance() {
        guard canContinue else { return }
        switch stage {
        case .welcome:
            stage = .brain
        case .brain:
            guard let option = selectedOption else { return }
            // A key requirement may only be skipped when there is genuinely
            // nothing to paste. Reading "no instructions" as "no key needed" is
            // a fail-open, and it shipped: the Google option asked for a key,
            // had nothing to explain, and setup answered by removing the screen
            // the requirement existed to demand.
            if option.requirement == .apiKey {
                guard keyInstructions != nil else { return }
                keyState = .waiting
                stage = .key
                return
            }
            // Anything else must need nothing at all. `canContinue` already
            // refuses a `.signIn` or `.download` selection, because this flow has
            // no screen that could satisfy either.
            guard option.requirement == .nothing else { return }
            keyState = .notNeeded
            stage = .ready
        case .key:
            stage = .ready
        case .ready:
            break
        }
    }

    /// Continues from the brain picker, provisioning the private option first
    /// when needed. The setup flow cannot reach Ready until real chat and
    /// embedding probes have passed.
    func continueFromBrain() async {
        guard stage == .brain, let option = selectedOption else { return }
        guard option.requirement == .download else {
            advance()
            return
        }
        guard option.id == .fullyLocal else { return }

        localBrainPhase = .idle
        let installed = await localBrainInstaller.install { [weak self] phase in
            Task { @MainActor in self?.localBrainPhase = phase }
        }
        guard installed else { return }

        // Re-run the source-of-truth probe so the persisted option records the
        // model that actually answered, not merely the one we requested.
        let selectedID = selectedOptionID
        await probe()
        selectedOptionID = selectedID
        guard selectedOption?.requirement == .nothing else {
            localBrainPhase = .failed("The local brain answered, but setup could not confirm it.")
            return
        }
        advance()
    }

    func goBack() {
        guard let previous = Stage(rawValue: stage.rawValue - 1) else { return }
        // Going forward skips `.key` for a brain that needs no key; going back
        // has to skip it too, or "Back" from the phone stage lands the owner on
        // a screen with nothing on it and a Continue button.
        if previous == .key, keyInstructions == nil {
            stage = .brain
            return
        }
        stage = previous
    }

    /// Deferring a key is an explicit navigation action, not a successful key
    /// check. `advance()` correctly blocks an unverified key, so the old skip
    /// button called it and did nothing.
    func skipKey() {
        guard stage == .key else { return }
        stage = .ready
    }

    // MARK: Key

    /// Checks the pasted key by doing what a real turn does.
    func verifyKey() async {
        guard let option = selectedOption, let provider = keyProvider else { return }

        let key = APIKeyOnboarding.normalise(pastedKey)
        lastVerdict = nil
        if let problem = APIKeyOnboarding.shapeProblem(of: key, expecting: provider) {
            keyState = .rejected(problem.spokenDescription)
            return
        }

        keyState = .checking
        do {
            let backend = try BrainFactory.makeBackend(for: option, apiKey: key)
            let verdict = await BrainKeyValidator().validate(backend)
            lastVerdict = verdict
            switch verdict {
            case .works:
                try KeyStorage.save(key, forProvider: provider)
                keyState = .accepted(verdict.spokenDescription)
            case .rejected, .unusable, .unreachable:
                keyState = .rejected(verdict.spokenDescription)
            }
        } catch {
            // Only two things reach here, and neither is the owner's doing: a
            // provider the planner offered but `BrainFactory` cannot build, or a
            // key file that would not write. Interpolating the error would put
            // "no backend for 'groq'" — or a POSIX errno — on the screen of
            // someone who pasted exactly what they were asked for. The detail
            // goes to the log; they get a sentence with a verb in it.
            Self.log.error("key verification failed for \(provider, privacy: .public): \(error)")
            keyState = .rejected(
                "Mynah couldn't set that up. Go back and pick a different brain, then try again."
            )
        }
    }

    /// Owner-facing text never carries an error; the error comes here instead.
    private static let log = Logger(subsystem: "local.sage.voicebridge", category: "setup")
}
