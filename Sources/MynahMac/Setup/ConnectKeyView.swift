import AppKit
import SageVoiceCore
import SwiftUI

// MARK: - Phase

/// What the connect screen is currently saying.
///
/// Seven cases rather than a handful of booleans, because each one earns a
/// different sentence *and* a different offer, and a `isChecking && !isValid`
/// lattice cannot express "the key is fine, this Mac is offline".
///
/// The kind of failure is carried here as a case; it is never recovered by
/// looking for words inside the message. QuietType drives its whole update UI by
/// lowercasing a status string and searching it for `"installing"` and `"verif"`,
/// which means rewording a sentence changes which screen appears.
enum ConnectKeyPhase: Equatable {
    /// Nothing pasted, or something pasted that has not been checked yet. The
    /// field says the same thing either way — only the button changes, and that
    /// is driven by the text, not by this.
    case untested
    /// Caught before the network is involved: a pasted web address, a whole
    /// `export GEMINI_API_KEY=…` line, the wrong provider's key.
    case shapeProblem(String)
    case checking
    /// The provider answered, and refused the key.
    case refused(String)
    /// The key works. The model behind it cannot drive the assistant, so
    /// sending the owner back for another key would be the wrong errand.
    case unusable(String)
    /// Nothing is wrong with the key — this Mac could not reach the provider.
    case unreachable(String)
    /// Accepted, and the message names the model that answered.
    case accepted(String)
}

// MARK: - Stage

/// Stage 3. Getting a working API key out of someone who has never seen one.
///
/// Only reached when the brain the owner picked actually needs a key —
/// `SetupModel.advance()` goes straight to Ready for anything that runs on this
/// Mac, rather than padding the flow to a fixed length with a screen that says
/// "press Continue".
///
/// A thin adapter: it maps `SetupModel` onto `ConnectKeyScreen` and does nothing
/// else, so every state below can be put on screen in a preview without a
/// network, a provider account, or a key.
struct ConnectKeyView: View {
    let titles: [String]
    @Bindable var model: SetupModel
    let app: AppModel

    /// Set synchronously in the button action. `model.keyState` only becomes
    /// `.checking` after the offline shape check, so two clicks landing in the
    /// same runloop turn would both see `.waiting` and both hit the provider.
    @State private var isVerifying = false

    init(titles: [String], model: SetupModel, app: AppModel) {
        self.titles = titles
        self._model = Bindable(wrappedValue: model)
        self.app = app
    }

    var body: some View {
        if let instructions = model.keyInstructions {
            ConnectKeyScreen(
                titles: titles,
                currentIndex: SetupModel.Stage.key.rawValue,
                instructions: instructions,
                phase: phase,
                key: $model.pastedKey,
                onVerify: verify,
                onContinue: advanceWithAWorkingKey,
                onBack: { model.goBack() },
                onSkip: skip,
                onChooseAnotherBrain: { model.goBack() }
            )
        } else {
            // Unreachable through the flow, and rendered anyway. A stage that can
            // only be entered by mistake still has to say something true when it
            // is — a blank screen with a Continue button is how an owner decides
            // the app is broken.
            nothingToConnect
        }
    }

    // MARK: Model → phase

    private var phase: ConnectKeyPhase {
        switch model.keyState {
        case .checking:
            return .checking

        case .accepted(let sentence):
            return .accepted(sentence)

        case .rejected(let sentence):
            // The sentence is for the owner; the verdict decides what to offer.
            switch model.lastVerdict {
            case .unreachable: return .unreachable(sentence)
            case .unusable: return .unusable(sentence)
            // `nil` is the offline shape check, which already produced its own
            // sentence and never reached a provider.
            case .rejected, .works, .none: return .refused(sentence)
            }

        case .notNeeded, .waiting:
            let typed = APIKeyOnboarding.normalise(model.pastedKey)
            guard !typed.isEmpty else { return .untested }
            // The same vocabulary `verifyKey` uses. Passing `backendIdentifier`
            // here meant the Google field never ran a provider-specific shape
            // check at all, so an OpenAI key pasted into it sailed through to
            // the network.
            let provider = model.keyProvider ?? ""
            if let problem = APIKeyOnboarding.shapeProblem(of: typed, expecting: provider) {
                return .shapeProblem(problem.spokenDescription)
            }
            return .untested
        }
    }

    // MARK: Actions

    private func verify() {
        guard !isVerifying else { return }
        isVerifying = true
        Task {
            await model.verifyKey()
            isVerifying = false
        }
    }

    /// "Not now" advances the flow and the skipped step turns into a row in
    /// Settings the owner can find again. An escape hatch that leads nowhere is
    /// worse than none, because the owner believes they did something.
    private func skip() {
        let provider = model.keyInstructions?.providerName ?? "your brain"
        app.deferSetupStep(
            AppModel.DeferredStep(
                id: AppModel.DeferredStep.brainKeyID,
                title: "Finish connecting \(provider)",
                detail: "Mynah can't answer until it has a \(provider) key."
            )
        )
        model.advance()
    }

    /// Leaving this stage with a key that verified is the one thing that makes
    /// an earlier "Not now" untrue, so it is also the one place that clears it.
    /// Continue is only offered once `keyState` is `.accepted`.
    private func advanceWithAWorkingKey() {
        app.resolveDeferredStep(id: AppModel.DeferredStep.brainKeyID)
        model.advance()
    }

    private var nothingToConnect: some View {
        StageShell(
            stageTitles: titles,
            currentIndex: SetupModel.Stage.key.rawValue,
            glyph: "laptopcomputer",
            title: "Nothing to connect.",
            subtitle: "The brain you picked runs on this Mac, so there is no key to paste "
                + "and no account to make."
        ) {
            EmptyView()
        } actions: {
            ActionRow(quietTitle: "Back", quietAction: { model.goBack() }) {
                MynahButton("Continue", isDefault: true) { model.advance() }
            }
        }
    }
}

// MARK: - Screen

/// The connect stage with nothing behind it: instructions in, a phase in, calls
/// out. Every state it can show is reachable from a preview.
struct ConnectKeyScreen: View {
    let titles: [String]
    let currentIndex: Int
    let instructions: APIKeyOnboarding.Instructions
    let phase: ConnectKeyPhase
    @Binding var key: String
    var onVerify: () -> Void
    var onContinue: () -> Void
    var onBack: (() -> Void)?
    /// Absent means there is nowhere to defer to, so the button does not ship.
    var onSkip: (() -> Void)?
    var onChooseAnotherBrain: () -> Void

    private var provider: String { instructions.providerName }

    var body: some View {
        StageShell(
            stageTitles: titles,
            currentIndex: currentIndex,
            title: "Paste your \(provider) key.",
            subtitle: "It takes two clicks on \(provider)'s own site. Mynah keeps the key on "
                + "this Mac and never shows it again."
        ) {
            VStack(alignment: .leading, spacing: s6) {
                stepsCard
                if let costNote = instructions.costNote {
                    Text(costNote)
                        .mynahFont(.callout)
                        .foregroundStyle(Palette.ink.secondary)
                        .mynahProse()
                }
                KeyField(
                    label: "\(provider) key",
                    text: $key,
                    state: fieldState,
                    fixTitle: fixTitle,
                    fix: fixAction,
                    onSubmit: onVerify
                )
                // The one state where the field is not the problem, so the field
                // is not marked and the note carries the fix instead.
                if case .unreachable = phase {
                    InlineBanner(
                        tone: .caution,
                        headline: "Mynah couldn't reach \(provider).",
                        explanation: "Nothing is wrong with your key. Check this Mac's internet "
                            + "connection, then check the key again.",
                        actionTitle: "Try again",
                        action: onVerify
                    )
                    .frame(maxWidth: MynahWidth.stageColumn)
                }
            }
            .mynahAnimation(Motion.snap, value: phase)
        } actions: {
            ActionRow(quietTitle: skipTitle, quietAction: onSkip, helper: helper) {
                HStack(spacing: s4) {
                    if let onBack {
                        MynahButton("Back", kind: .secondary, action: onBack)
                    }
                    MynahButton(
                        primaryTitle,
                        isEnabled: primaryIsEnabled,
                        isDefault: true,
                        action: primaryAction
                    )
                }
            }
        }
    }

    // MARK: Steps

    private var stepsCard: some View {
        MynahCard {
            VStack(alignment: .leading, spacing: s6) {
                NumberedStepList(steps: instructions.steps)
                // The button performs step one, so it sits where step one ends
                // rather than in the stage's action row, where it would compete
                // with the single commitment on the screen.
                MynahButton("Get \(BrainSetupPlanner.indefiniteArticle(for: provider)) \(provider) key", kind: .secondary) {
                    NSWorkspace.shared.open(instructions.keyPageURL)
                }
            }
        }
        .frame(maxWidth: MynahWidth.stageColumn)
    }

    // MARK: Field

    private var fieldState: KeyFieldState {
        switch phase {
        case .untested:
            return .idle(helper: instructions.looksLikeHint)
        case .shapeProblem(let sentence):
            return .shapeProblem(sentence)
        case .checking:
            return .checking("Checking this key with \(provider)…")
        case .refused(let sentence), .unusable(let sentence):
            return .rejected(sentence)
        case .unreachable:
            // Neutral on purpose: marking the field red would tell the owner to
            // go and replace a key that is very probably fine.
            return .idle(helper: instructions.looksLikeHint)
        case .accepted(let sentence):
            return .accepted(sentence)
        }
    }

    /// The offer under the field, and it differs by failure. A refusal wants a
    /// new key; a model that cannot run the assistant wants a different brain,
    /// and sending that owner back to the key page would waste their afternoon.
    private var fixTitle: String? {
        switch phase {
        case .refused: return "Get \(BrainSetupPlanner.indefiniteArticle(for: provider)) \(provider) key"
        case .unusable: return "Choose a different brain"
        case .untested, .shapeProblem, .checking, .unreachable, .accepted: return nil
        }
    }

    private var fixAction: (() -> Void)? {
        switch phase {
        case .refused: return { NSWorkspace.shared.open(instructions.keyPageURL) }
        case .unusable: return onChooseAnotherBrain
        case .untested, .shapeProblem, .checking, .unreachable, .accepted: return nil
        }
    }

    // MARK: Actions

    /// Once the key works there is nothing left to postpone, so the escape hatch
    /// goes away rather than sitting there inviting a mis-click.
    private var skipTitle: String? {
        guard onSkip != nil else { return nil }
        if case .accepted = phase { return nil }
        return "Not now"
    }

    private var primaryTitle: String {
        if case .accepted = phase { return "Continue" }
        // Deliberately fixed while checking. A button that relabels itself to
        // "Checking…" mid-press moves under the pointer; the field already shows
        // a spinner and says who is being asked.
        return "Check this key"
    }

    private var primaryIsEnabled: Bool {
        switch phase {
        case .accepted: return true
        case .checking, .shapeProblem: return false
        case .untested, .refused, .unusable, .unreachable:
            return !APIKeyOnboarding.normalise(key).isEmpty
        }
    }

    private func primaryAction() {
        if case .accepted = phase {
            onContinue()
        } else {
            onVerify()
        }
    }

    /// Only ever explains a disabled button. A greyed control with no reason
    /// beside it is a dead end the owner has to guess their way out of.
    private var helper: String? {
        guard case .untested = phase else { return nil }
        return APIKeyOnboarding.normalise(key).isEmpty ? "Paste the key to check it" : nil
    }
}

// MARK: - Numbered steps

/// Instructions the owner follows on someone else's website.
///
/// Plain numerals in a fixed-width gutter, not chips and not glyph wells: a
/// numbered list is the one place a number *is* the icon, and MYNAH's rule that
/// body paragraphs carry no icons holds here too. Shared by the two setup
/// screens that walk the owner through something outside the app.
struct NumberedStepList: View {
    let steps: [String]

    init(steps: [String]) {
        self.steps = steps
    }

    var body: some View {
        VStack(alignment: .leading, spacing: s4) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: s4) {
                    Text("\(index + 1)")
                        .mynahFont(.label)
                        .foregroundStyle(Palette.ink.secondary)
                        .monospacedDigit()
                        .frame(width: 14, alignment: .trailing)
                    Text(step)
                        .mynahFont(.body)
                        .foregroundStyle(Palette.ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Step \(index + 1). \(step)")
            }
        }
    }
}

// MARK: - Previews

#Preview("Connect — empty") {
    ConnectKeyPreview(phase: .untested, key: "")
}

#Preview("Connect — ready to check") {
    ConnectKeyPreview(phase: .untested, key: "AIzaSyB-notarealkey-000000000000000000")
}

#Preview("Connect — wrong shape") {
    ConnectKeyPreview(
        phase: .shapeProblem(APIKeyOnboarding.ShapeProblem.looksLikeAURL.spokenDescription),
        key: "https://aistudio.google.com/apikey"
    )
}

#Preview("Connect — checking") {
    ConnectKeyPreview(phase: .checking, key: "AIzaSyB-notarealkey-000000000000000000")
}

#Preview("Connect — refused") {
    ConnectKeyPreview(
        phase: .refused(
            BrainKeyValidator.Verdict
                .rejected("Check you copied the whole thing, and that it hasn't been deleted.")
                .spokenDescription
        ),
        key: "AIzaSyB-notarealkey-000000000000000000"
    )
}

#Preview("Connect — model can't drive it") {
    ConnectKeyPreview(
        phase: .unusable(
            BrainKeyValidator.Verdict
                .unusable("It replied but ignored the tool it was given.")
                .spokenDescription
        ),
        key: "AIzaSyB-notarealkey-000000000000000000"
    )
}

#Preview("Connect — offline") {
    ConnectKeyPreview(
        phase: .unreachable(BrainKeyValidator.Verdict.unreachable("").spokenDescription),
        key: "AIzaSyB-notarealkey-000000000000000000"
    )
}

#Preview("Connect — accepted") {
    ConnectKeyPreview(
        phase: .accepted(BrainKeyValidator.Verdict.works(modelName: "gemini-3.6-flash").spokenDescription),
        key: "AIzaSyB-notarealkey-000000000000000000"
    )
}

#Preview("Connect — pays per use") {
    ConnectKeyPreview(
        instructions: APIKeyOnboarding.anthropic,
        phase: .untested,
        key: ""
    )
}

/// Both schemes side by side, driving the real screen rather than a mock of it.
/// Every sentence a preview shows comes from `APIKeyOnboarding` or
/// `BrainKeyValidator`, so a reworded verdict shows up here before it ships.
private struct ConnectKeyPreview: View {
    var instructions: APIKeyOnboarding.Instructions = APIKeyOnboarding.gemini
    let phase: ConnectKeyPhase
    @State private var key: String

    init(
        instructions: APIKeyOnboarding.Instructions = APIKeyOnboarding.gemini,
        phase: ConnectKeyPhase,
        key: String
    ) {
        self.instructions = instructions
        self.phase = phase
        self._key = State(initialValue: key)
    }

    var body: some View {
        HStack(spacing: 0) {
            pane.environment(\.colorScheme, .light)
            pane.environment(\.colorScheme, .dark)
        }
        .frame(width: 1400, height: 880)
    }

    private var pane: some View {
        ConnectKeyScreen(
            titles: SetupModel.Stage.allCases.map(\.title),
            currentIndex: SetupModel.Stage.key.rawValue,
            instructions: instructions,
            phase: phase,
            key: $key,
            onVerify: {},
            onContinue: {},
            onBack: {},
            onSkip: {},
            onChooseAnotherBrain: {}
        )
    }
}
