import SageVoiceCore
import SwiftUI

// MARK: - Stage 2

/// The screen that justifies the app existing: where the owner's words go.
///
/// Drives `EnvironmentProbe` and `BrainSetupPlanner` through `SetupModel` and
/// renders whatever menu they produce. It decides nothing. `BrainSetupSelection`
/// has an internal initialiser so nothing in the module can choose a brain on the
/// owner's behalf; a screen that quietly preselected the recommendation would
/// defeat that from the outside, which is why `selectedOptionID` starts `nil` and
/// Continue stays disabled until a card is clicked.
struct BrainStage: View {
    let titles: [String]
    @Bindable var model: SetupModel

    @Environment(AppModel.self) private var app

    var body: some View {
        BrainPicker(
            titles: titles,
            choices: model.choices,
            failure: model.probeFailure,
            installPhase: model.localBrainPhase,
            selection: $model.selectedOptionID,
            canContinue: model.canContinue,
            onBack: { model.goBack() },
            onContinue: {
                // Choosing a brain that needs no key settles any key the owner
                // deferred earlier.
                //
                // "Not now" on the Connect stage files an outstanding item, and
                // only finishing that stage with a working key cleared it. So an
                // owner who skipped an Anthropic key, went back, and chose to
                // run everything on their own Mac arrived at the last screen
                // being told to finish connecting Anthropic — for a brain that
                // has no key and never asks for one. There is nothing they can
                // do with that, and "One thing left" is a poor place to be stuck
                // on a thing that is not left.
                if model.selectedOption?.keyProviderIdentifier == nil {
                    app.resolveDeferredStep(id: AppModel.DeferredStep.brainKeyID)
                }
                Task { await model.continueFromBrain() }
            },
            onLookAgain: lookAgain
        )
    }

    private func lookAgain() {
        Task { await model.probe() }
    }
}

// MARK: - Picker

/// The stage as pure presentation: a plan in, a chosen id out.
///
/// Split from `BrainStage` so the screens that matter most can actually be
/// looked at. The 8 GB machine and the machine where nothing is offerable are
/// the two states most likely to ship broken, and neither can be reproduced by
/// running the app on the developer's Mac.
private struct BrainPicker: View {
    let titles: [String]
    let choices: BrainSetupChoices?
    let failure: String?
    let installPhase: LocalBrainInstaller.Phase?
    @Binding var selection: BrainSetupOptionID?
    let canContinue: Bool
    let onBack: () -> Void
    let onContinue: () -> Void
    let onLookAgain: () -> Void

    /// One namespace across *both* privacy groups, so the accent border travels
    /// from a card in one group to a card in the other rather than blinking out
    /// and reappearing. This is why the cards are placed here instead of through
    /// `OptionCardList`, which owns a namespace of its own and renders one flat
    /// list — a flat list cannot carry the group headers this screen needs.
    @Namespace private var selectionNamespace

    var body: some View {
        StageShell(
            stageTitles: titles,
            currentIndex: SetupModel.Stage.brain.rawValue,
            title: "Where should your words go?",
            subtitle: "Mynah needs somewhere to do its thinking, and this is the one "
                + "choice that decides whether what you say ever leaves this Mac. You "
                + "can change it later."
        ) {
            content
        } actions: {
            ActionRow(quietTitle: "Back", quietAction: onBack, helper: helper) {
                MynahButton("Continue", isEnabled: canContinue, isDefault: true, action: onContinue)
            }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let choices, !choices.options.isEmpty {
            VStack(alignment: .leading, spacing: s7) {
                if choices.availableOptions.isEmpty {
                    // The cards stay on screen underneath this. Each one says in
                    // plain words what would make it work, and that is the only
                    // useful thing left to tell someone in this position.
                    InlineBanner(
                        tone: .critical,
                        headline: "Mynah has nowhere to think yet.",
                        explanation: failure ?? "None of these will work on this Mac "
                            + "right now. Each one below says what it needs.",
                        actionTitle: "Look again",
                        action: onLookAgain
                    )
                } else if let suggestion {
                    Text(suggestion)
                        .mynahFont(.callout)
                        .foregroundStyle(Palette.ink.secondary)
                        .mynahProse()
                }

                if let installPhase, installPhase != .idle {
                    VStack(alignment: .leading, spacing: s2) {
                        Text(installPhase.sentence)
                            .mynahFont(.callout)
                            .foregroundStyle(
                                installPhase.isFinished ? Palette.ink.secondary : Palette.ink.primary
                            )
                        if let fraction = installPhase.fraction, !installPhase.isFinished {
                            ProgressView(value: fraction)
                                .progressViewStyle(.linear)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }

                ForEach(groups) { group in
                    groupView(group)
                }
            }
            .frame(maxWidth: MynahWidth.stageColumn)
        } else if let failure {
            InlineBanner(
                tone: .critical,
                headline: "Mynah couldn't look at this Mac.",
                explanation: failure,
                actionTitle: "Look again",
                action: onLookAgain
            )
            .frame(maxWidth: MynahWidth.stageColumn)
        } else {
            // Normally never seen: the probe runs behind the welcome screen, so by
            // the time anyone arrives here the plan is already made.
            HStack(spacing: s4) {
                ThinkingIndicator()
                Text("Looking at what this Mac can do…")
                    .mynahFont(.body)
                    .foregroundStyle(Palette.ink.secondary)
            }
            .frame(maxWidth: MynahWidth.stageColumn, alignment: .leading)
        }
    }

    private func groupView(_ group: PrivacyGroup) -> some View {
        VStack(alignment: .leading, spacing: s4) {
            // Not `SectionHeader`: that one is tuned for settings groups, carries
            // its own fixed vertical padding, and has nowhere to put the sentence
            // that says why anyone would pick this half of the list. The tokens
            // are the same tokens.
            VStack(alignment: .leading, spacing: s2) {
                Text(group.title)
                    .mynahFont(.eyebrow)
                    .foregroundStyle(Palette.ink.secondary)
                Text(group.note)
                    .mynahFont(.callout)
                    .foregroundStyle(Palette.ink.secondary)
                    .mynahProse()
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            VStack(spacing: s4) {
                ForEach(group.options) { option in
                    OptionCard(
                        option: option,
                        isSelected: selection == option.id,
                        isRecommended: choices?.recommendation?.optionID == option.id,
                        namespace: selectionNamespace
                    ) {
                        selection = option.id
                    }
                }
            }
        }
    }

    // MARK: Grouping

    /// The privacy distinction, made structural.
    ///
    /// The planner ranks by friction, which is the right ranking for "what will
    /// work"; it is the wrong ranking for the only question this screen exists to
    /// ask. Splitting the same list into two labelled halves says the thing that
    /// matters before the owner has read a single summary, and costs no colour,
    /// no badge and no extra glyph. Order *within* each half stays exactly as the
    /// planner returned it.
    private var groups: [PrivacyGroup] {
        guard let choices else { return [] }
        let onDevice = PrivacyGroup(
            id: "on-device",
            title: "Stays on this Mac",
            note: "Mynah does the thinking here. Nothing you say is sent anywhere, and "
                + "there's nothing to pay.",
            options: choices.options.filter(\.keepsWordsOnDevice)
        )
        let away = PrivacyGroup(
            id: "leaves",
            title: "Leaves this Mac",
            note: "Faster to answer, and some are free to start — but what you say is "
                + "sent to the company you pick.",
            options: choices.options.filter { !$0.keepsWordsOnDevice }
        )

        // On-device always leads, even when this Mac cannot run it yet.
        //
        // This used to demote the local half whenever nothing in it was
        // available, on the reasoning that opening on a dead end reads as "this
        // Mac can't do it". That was a sound instinct about layout and the wrong
        // answer for this product: the owner then opens on a list of companies
        // to send their speech to, and the private option — the reason this
        // thing exists — is below the fold on the one screen that decides it.
        //
        // The ordering was never the real problem. A local option the app cannot
        // set up is the problem, and burying it hid that rather than fixing it.
        return [onDevice, away].filter { !$0.options.isEmpty }
    }

    private struct PrivacyGroup: Identifiable {
        let id: String
        let title: String
        let note: String
        let options: [BrainSetupOption]

        var hasAvailableOption: Bool { options.contains(where: \.isAvailable) }
    }

    // MARK: Guidance

    private var selectedOption: BrainSetupOption? {
        guard let selection, let choices else { return nil }
        return choices.option(withID: selection)
    }

    /// Names the recommended option in a sentence rather than explaining an icon.
    /// The sparkle on the card is an echo of this line, not a symbol the owner is
    /// expected to decode.
    private var suggestion: String? {
        guard let recommendation = choices?.recommendation,
              let option = choices?.option(withID: recommendation.optionID) else {
            return nil
        }
        return "Mynah suggests “\(option.label)”. \(recommendation.rationale)"
    }

    /// Lives in the pinned action row, which is the one part of this stage that
    /// is on screen no matter how far the owner has scrolled — so it can say what
    /// to do before a choice, and what that choice means afterwards.
    private var helper: String? {
        guard let choices, !choices.availableOptions.isEmpty else { return nil }
        guard let option = selectedOption else { return "Pick where your words go" }
        if option.keepsWordsOnDevice {
            return "Nothing you say will leave this Mac."
        }
        guard let company = MynahCopy.company(forBackend: option.backendIdentifier) else {
            return nil
        }
        return "What you say will be sent to \(company)."
    }
}

// MARK: - Previews

#Preview("Brain — 64 GB Mac") {
    BrainPreviewPair(choices: BrainPreviewPlan.mac64GB).frame(width: 1440, height: 900)
}

#Preview("Brain — 8 GB Mac") {
    BrainPreviewPair(choices: BrainPreviewPlan.mac8GB).frame(width: 1440, height: 900)
}

#Preview("Brain — nothing available") {
    BrainPreviewPair(
        choices: BrainPreviewPlan.nothingAvailable,
        failure: "This Mac can't run any of the options, and no cloud provider is reachable."
    )
    .frame(width: 1440, height: 900)
}

/// Synthetic machines, run through the real planner wherever the planner can
/// produce the state. Only the last one is hand-built, because today's catalog
/// always offers the Google sign-in and so cannot generate "nothing works" — but
/// `SetupModel` has a failure path for it, and an unreachable state that has
/// never been looked at is an unreachable state that ships broken.
private enum BrainPreviewPlan {

    static let mac64GB = BrainSetupPlanner().plan(
        for: EnvironmentProbeResult(
            localRuntime: LocalModelRuntimeReport(
                isRuntimeInstalled: true,
                runtimeExecutablePath: "/usr/local/bin/ollama",
                isDaemonReachable: true,
                installedModels: ["qwen3.5:4b", "llama3.1:8b"]
            ),
            agentCLIs: [
                AgentCLIReport(
                    kind: .claudeCode,
                    isInstalled: true,
                    executablePath: "/opt/homebrew/bin/claude",
                    version: "2.4.1",
                    credentialEvidence: ["keychain item \"Claude Code\""],
                    hasSubscriptionCredential: true
                ),
                AgentCLIReport(kind: .codex)
            ],
            hardware: HardwareReport(
                physicalMemoryBytes: 64 * 1024 * 1024 * 1024,
                freeDiskBytes: 900_000_000_000,
                modelStorageDirectory: "/Users/owner/.ollama",
                cpuBrand: "Apple M3 Max",
                physicalCoreCount: 14,
                isAppleSilicon: true
            )
        )
    )

    /// 8 GiB Apple Silicon: fully local is offered and honest about being tight,
    /// which is the case most likely to be quietly hidden by a lesser screen.
    static let mac8GB = BrainSetupPlanner().plan(
        for: EnvironmentProbeResult(
            agentCLIs: AgentCLIKind.allCases.map { AgentCLIReport(kind: $0) },
            hardware: HardwareReport(
                physicalMemoryBytes: 8 * 1024 * 1024 * 1024,
                freeDiskBytes: 180_000_000_000,
                modelStorageDirectory: "/Users/owner/.ollama",
                cpuBrand: "Apple M1",
                physicalCoreCount: 8,
                isAppleSilicon: true
            )
        )
    )

    static let nothingAvailable = BrainSetupChoices(
        options: [
            BrainSetupOption(
                id: .fullyLocal,
                label: "Fully on this Mac",
                summary: "Runs the brain on this Mac so nothing you say leaves it.",
                requirement: .download,
                keepsWordsOnDevice: true,
                availability: .unavailable(
                    reason: "Running the brain on this Mac needs Apple Silicon — on an "
                        + "Intel chip a reply takes far too long to be spoken "
                        + "conversation. This Mac reports Intel Core i5."
                ),
                tier: .fullyLocal,
                backendIdentifier: "ollama"
            ),
            BrainSetupOption(
                id: .googleSignIn,
                label: "Sign in with Google",
                summary: "Sign in with a Google account — no API key and no card. What "
                    + "you say goes to Google.",
                requirement: .signIn,
                keepsWordsOnDevice: false,
                availability: .unavailable(
                    reason: "This Mac isn't connected to the internet right now."
                ),
                tier: .zeroFrictionSignIn,
                backendIdentifier: "google"
            ),
            BrainSetupOption(
                id: .anthropicAPIKey,
                label: "Anthropic API key",
                summary: "Paste an Anthropic API key. Billed per use. What you say goes "
                    + "to Anthropic.",
                requirement: .apiKey,
                keepsWordsOnDevice: false,
                availability: .unavailable(
                    reason: "This Mac isn't connected to the internet right now."
                ),
                tier: .typedAPIKey,
                backendIdentifier: "anthropic"
            )
        ],
        recommendation: nil
    )
}

/// Both schemes, one shared selection, so the travelling accent border can be
/// checked in light and dark at the same time.
private struct BrainPreviewPair: View {
    let choices: BrainSetupChoices?
    var failure: String?

    @State private var selection: BrainSetupOptionID?

    var body: some View {
        HStack(spacing: 0) {
            pane.environment(\.colorScheme, .light)
            pane.environment(\.colorScheme, .dark)
        }
    }

    private var pane: some View {
        BrainPicker(
            titles: SetupModel.Stage.allCases.map(\.title),
            choices: choices,
            failure: failure,
            installPhase: nil,
            selection: $selection,
            canContinue: canContinue,
            onBack: {},
            onContinue: {},
            onLookAgain: {}
        )
    }

    /// The same gate `SetupModel.canContinue` applies, so a preview cannot show
    /// an enabled Continue the real screen would keep disabled.
    private var canContinue: Bool {
        guard let selection, let choices else { return false }
        return choices.option(withID: selection)?.isAvailable == true
    }
}
