import SageVoiceCore
import SwiftUI

/// Changing *where the owner's words go*, without walking setup again.
///
/// **The owner's report:** *"changing the model shouldn't redo the whole
/// setup."* He is right, and the shape of the mistake is one this screen has
/// already made once. "Change where your words go" called `restartSetup()`,
/// which drops `hasCompletedSetup` and puts the whole app back to Welcome →
/// Brain → Connect → Ready — on a Mac that was set up hours ago.
///
/// That is the same failure as the Calls row telling him to change model and
/// sending him to onboarding to do it: **a small, reversible change routed
/// through the largest, least reversible flow in the product.**
///
/// It also has teeth beyond the annoyance. `hasCompletedSetup == false` is a
/// `stop` intent, so entering that flow **removes both LaunchAgents** and his
/// phone stops being answered until he finishes or backs out. Opening it out of
/// curiosity costs him the appliance.
///
/// ## What this keeps from the flow it replaces
///
/// Two things, both deliberate rather than inherited:
///
/// 1. **Nothing is saved until it answers.** The chosen brain is built for
///    real and asked a real question, exactly as `BrainModelSheet` does — a
///    provider that will not serve is caught here rather than mid-answer on his
///    phone.
/// 2. **A provider that needs a key does not pretend otherwise.** It hands back
///    to the caller to run the key flow first, because a brain saved without one
///    is a brain that fails on the next question.
struct BrainProviderSheet: View {

    let choices: BrainSetupChoices
    /// What he is on now, so the sheet can show it and refuse a no-op.
    let current: BrainSetupOption?
    /// The chosen option, or `nil` if he backed out. A second value says the
    /// caller must run the key flow before this can be saved.
    let onClose: (Outcome) -> Void

    enum Outcome: Equatable {
        case cancelled
        case chose(BrainSetupOption)
        /// Verified as far as it can be without a key, which is not very far.
        case needsAKeyFirst(BrainSetupOption)
    }

    @State private var selected: BrainSetupOption?
    /// The sentence a failed check produced, rather than the verdict itself.
    ///
    /// `BrainKeyValidator.Verdict` has no public initialiser — deliberately, so
    /// nothing outside can mint a passing one — and the failure path here needs
    /// to report a build error that never reached the validator at all. Holding
    /// the sentence keeps that honest: this state means "the last attempt did
    /// not work, and here is why", not "the validator said so".
    @State private var refusal: String?
    @State private var isChecking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: s2) {
                Text("Where your words go")
                    .mynahFont(.title2)
                    .foregroundStyle(Palette.ink.primary)
                Text("Mynah asks whichever you pick a real question before keeping it, so a "
                    + "brain that will not answer is caught here rather than on your phone.")
                    .mynahFont(.callout)
                    .foregroundStyle(Palette.ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, s5)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(choices.availableOptions.enumerated()), id: \.element.id) { index, option in
                        if index > 0 { MynahDivider() }
                        row(option)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)

            resultLine
                .padding(.top, s5)

            ActionRow(quietTitle: "Cancel", quietAction: { onClose(.cancelled) }) {
                MynahButton(
                    "Use this brain",
                    isEnabled: canCommit,
                    isDefault: true,
                    action: commit
                )
            }
            .padding(.top, s5)
        }
        .padding(s8)
        .frame(width: 620, height: 580)
        .background(Palette.surface.overlay)
        .mynahAnimation(Motion.snap, value: refusal)
        // Escape is Cancel. Nothing is saved until it verifies — the same
        // promise `BrainModelSheet` makes, and the reason neither sheet needs
        // an "are you sure".
        .onExitCommand { onClose(.cancelled) }
    }

    private func row(_ option: BrainSetupOption) -> some View {
        Button {
            selected = option
            refusal = nil
        } label: {
            HStack(alignment: .top, spacing: s4) {
                StatusDot(option.id == selected?.id ? .accent : .neutral)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: s1) {
                    HStack(spacing: s3) {
                        Text(option.label)
                            .mynahFont(.body)
                            .foregroundStyle(Palette.ink.primary)
                        if option.id == current?.id {
                            StatusPill("Now", tone: .neutral)
                        }
                        Spacer(minLength: 0)
                    }
                    // The summary already says where the words go — it is the
                    // sentence the brain picker uses in setup, and it is the
                    // one thing on this sheet he is actually choosing between.
                    Text(option.summary)
                        .mynahFont(.label)
                        .foregroundStyle(Palette.ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(.vertical, s4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    @ViewBuilder
    private var resultLine: some View {
        if isChecking {
            HStack(spacing: s3) {
                ProgressView().controlSize(.small)
                Text("Asking it a question…")
                    .mynahFont(.label)
                    .foregroundStyle(Palette.ink.secondary)
            }
        } else if let refusal {
            // Caution, not critical: nothing is broken and nothing changed —
            // the old brain is still the one answering, because this saves
            // nothing until it passes.
            InlineBanner(
                tone: .caution,
                headline: "That one didn't answer.",
                explanation: refusal
                    + " Nothing has changed — Mynah is still using what it was."
            )
        }
    }

    private var canCommit: Bool {
        guard let selected, !isChecking else { return false }
        return selected.id != current?.id
    }

    private func commit() {
        guard let option = selected else { return }

        // A provider that needs a key it has not got cannot be verified, and
        // saving it unverified would hand him a brain that fails on his next
        // question. Handed back rather than half-done.
        if let provider = option.keyProviderIdentifier,
           KeyStorage.key(forProvider: provider) == nil {
            onClose(.needsAKeyFirst(option))
            return
        }

        isChecking = true
        Task {
            defer { isChecking = false }
            do {
                let backend = try BrainFactory.makeBackend(
                    for: option,
                    apiKey: option.keyProviderIdentifier.flatMap(KeyStorage.key(forProvider:))
                )
                let answer = await BrainKeyValidator().validate(backend)
                if answer.isUsable {
                    onClose(.chose(option))
                } else {
                    refusal = answer.spokenDescription
                }
            } catch {
                refusal = "Mynah couldn't set that one up."
            }
        }
    }
}

/// Shown when the environment probe has not answered, so there is no catalogue
/// to choose from.
///
/// A sheet rather than a silently dead button: a control that does nothing when
/// pressed is the dead end this product keeps removing, and "not yet" is a
/// state the owner can act on by waiting a moment.
struct ProbeUnavailableSheet: View {
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: s5) {
            Text("Mynah is still looking at this Mac")
                .mynahFont(.title2)
                .foregroundStyle(Palette.ink.primary)
            Text("It works out what is installed before it can offer you anywhere to switch to. "
                + "Give it a moment and try again.")
                .mynahFont(.callout)
                .foregroundStyle(Palette.ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            ActionRow(quietTitle: "Close", quietAction: onClose) { EmptyView() }
        }
        .padding(s8)
        .frame(width: 460, height: 240)
        .background(Palette.surface.overlay)
        .onExitCommand(perform: onClose)
    }
}
