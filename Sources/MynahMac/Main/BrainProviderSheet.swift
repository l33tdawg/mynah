import SageVoiceCore
import SwiftUI

/// Changing *where the owner's words go*, without walking setup again.
///
/// ## The shape this screen is, and why
///
/// One question first — **does this stay on the Mac, or go to a company** — and
/// only then the details of whichever they picked. The owner asked for exactly
/// that: *"it should be a clear switch - local model (qwen only) or you can
/// change manually if you downloaded your own via ollama, cloud (choose
/// provider, provide key)"*.
///
/// It used to be one flat list mixing both, which buried the only distinction on
/// the screen that has consequences. Every cloud row spends the owner's money
/// and sends their words off the machine; the local row does neither. Sorting by
/// "tier" put those side by side as though the difference were a preference.
///
/// ## The key is on this screen
///
/// Picking a cloud provider used to hand back to the caller with
/// `needsAKeyFirst`, which closed this sheet, saved a brain that could not
/// answer, and opened a second sheet to collect the key. The owner's report was
/// blunt — *"there's no where to set the api keys for cloud providers"* — and he
/// was right in the way that matters: a thing you can only reach by first
/// choosing something broken is not somewhere you can set it.
///
/// So the field is here, under the provider it belongs to, and nothing is saved
/// until the key it was given actually answers a question.
///
/// ## Models are the ones you have
///
/// The local side lists what Ollama has actually pulled. Not a text field —
/// *"yes models you have pulled bro - wtf free text!? thats fucking dumb"* — and
/// he is right: a name typed by hand is a typo that becomes a failure two
/// screens later, and the machine already knows the answer.
struct BrainProviderSheet: View {

    let choices: BrainSetupChoices
    /// What he is on now, so the sheet can show it and refuse a no-op.
    let current: BrainSetupOption?
    /// Model names the local runtime has actually pulled.
    let installedLocalModels: [String]
    let onClose: (Outcome) -> Void

    enum Outcome: Equatable {
        case cancelled
        /// Verified, with its model name and key already settled.
        case chose(BrainSetupOption)
    }

    typealias Destination = BrainProviderChoice.Destination

    /// Every decision on this sheet, in a value the tests can reach.
    @State private var choice: BrainProviderChoice
    @State private var refusal: String?
    @State private var isChecking = false

    init(
        choices: BrainSetupChoices,
        current: BrainSetupOption?,
        installedLocalModels: [String],
        onClose: @escaping (Outcome) -> Void
    ) {
        self.choices = choices
        self.current = current
        self.installedLocalModels = installedLocalModels
        self.onClose = onClose

        _choice = State(initialValue: BrainProviderChoice(
            current: current, installedLocalModels: installedLocalModels
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            switcher.padding(.bottom, s4)

            // Scrolls only when there is something to scroll. A `ScrollView` is
            // greedy — it takes every point offered — so wrapping a four-row
            // list in one is what pinned this sheet open at its maximum height
            // with a scroller that never moved.
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch choice.destination {
                    case .thisMac: localSide
                    case .cloud: cloudSide
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .fixedSize(horizontal: false, vertical: choice.destination == .thisMac)

            resultLine.padding(.top, s4)

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
        // Width fixed, height from the content: *"the box could be sized
        // automatically to fit the vertical content so you don't have the
        // scroll"*. A flat 620 meant the local side — four short rows — opened
        // with half a panel of blank and a scroller it never needed, while the
        // cloud side scrolled anyway. The cap is the only fixed number left, so
        // a machine with a long provider list still cannot open a sheet taller
        // than the screen.
        .frame(width: 620)
        .frame(maxHeight: 760)
        .background(Palette.surface.overlay)
        .mynahAnimation(Motion.snap, value: refusal)
        .mynahAnimation(Motion.snap, value: choice.destination)
        .onExitCommand { onClose(.cancelled) }
    }

    // MARK: - Header and switch

    private var header: some View {
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
    }

    private var switcher: some View {
        VStack(alignment: .leading, spacing: s2) {
            // **Drawn from `Palette`, not `.segmented`.**
            //
            // A system segmented control brings the owner's System Settings
            // accent with it, which is the one blue thing on a panel whose other
            // controls are all ink — *"the on this mac / cloud thing i think
            // could be improved to look more like the rest of the controls"*.
            // The same capsule the top bar's destinations use, at the same
            // radius as the buttons underneath it.
            HStack(spacing: s2) {
                ForEach(Destination.allCases) { destination in
                    destinationTab(destination)
                }
            }
            .padding(s1)
            .background(Palette.surface.well, in: RoundedRectangle.mynah(r.control))
            .onChange(of: choice.destination) { _, new in
                refusal = nil
                choice.moved(
                    to: new,
                    localOption: localOption,
                    cloudOptions: cloudOptions,
                    current: current,
                    installedLocalModels: installedLocalModels,
                    hasSavedKey: { KeyStorage.key(forProvider: $0) != nil }
                )
            }

            Text(choice.destination.explanation)
                .mynahFont(.label)
                .foregroundStyle(Palette.ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func destinationTab(_ destination: Destination) -> some View {
        let isSelected = choice.destination == destination
        return Button { choice.destination = destination } label: {
            Text(destination.title)
                .mynahFont(.bodyEmphasis)
                .foregroundStyle(isSelected ? Palette.accent.onFill : Palette.ink.secondary)
                .padding(.horizontal, s5)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(
                    isSelected ? Palette.accent.fill : .clear,
                    in: RoundedRectangle.mynah(r.chip)
                )
                .contentShape(RoundedRectangle.mynah(r.chip))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - On this Mac

    var localOption: BrainSetupOption? { choices.localOption }

    @ViewBuilder
    private var localSide: some View {
        if let option = localOption, option.isAvailable {
            if installedLocalModels.isEmpty {
                // Not a text field. There is nothing to choose between yet, and
                // inviting him to type a model name he has not downloaded is
                // inviting a failure two screens later.
                InlineBanner(
                    headline: "No local model has finished downloading.",
                    explanation: option.summary
                )
                .padding(.top, s2)
            } else {
                VStack(alignment: .leading, spacing: s3) {
                    ForEach(orderedLocalModels, id: \.self) { name in
                        modelRow(name, option: option)
                    }
                }
            }
        } else if let option = localOption {
            // The hardware reason, in the words the planner already wrote.
            InlineBanner(
                headline: "This Mac can't run a brain on its own.",
                explanation: option.availability.reason ?? option.summary
            )
            .padding(.top, s2)
        }
    }

    /// The one in use first, then the rest as the machine reports them.
    ///
    /// *"last used / selected model should be... at the top of the list so you
    /// don't have to go hunt for it."* A machine with eight models pulled — and
    /// this one has eight, including two embedding models and a translator —
    /// puts the answer to "which am I on" somewhere in the middle of an
    /// alphabetical list, behind a scroll.
    ///
    /// Only the selected one is lifted. Sorting by anything else would move rows
    /// under the pointer between visits, and a list that reorders itself is
    /// worse to hunt through than one that does not.
    private var orderedLocalModels: [String] {
        guard let selected = choice.localModel,
              installedLocalModels.contains(selected) else { return installedLocalModels }
        return [selected] + installedLocalModels.filter { $0 != selected }
    }

    private func modelRow(_ name: String, option: BrainSetupOption) -> some View {
        Button {
            choice.localModel = name
            choice.selected = option
            refusal = nil
        } label: {
            HStack(alignment: .top, spacing: s4) {
                StatusDot(choice.localModel == name ? .good : .neutral)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: s1) {
                    HStack(spacing: s3) {
                        Text(name)
                            .mynahFont(.body)
                            .foregroundStyle(Palette.ink.primary)
                        if name == current?.modelName, current?.id == option.id {
                            StatusPill("Now", tone: .neutral)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(s5)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The same green card the API-key sheet uses for the picked model,
            // asked for by name: a dot on one of eight rows is not an answer to
            // "which am I on".
            .background(
                choice.localModel == name ? Palette.state.goodWash : Palette.surface.raised,
                in: RoundedRectangle.mynah(r.card)
            )
            .mynahBorder(
                r.card,
                choice.localModel == name ? Palette.state.good.opacity(0.55) : Palette.line.hairline
            )
            .contentShape(RoundedRectangle.mynah(r.card))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    // MARK: - Cloud

    var cloudOptions: [BrainSetupOption] { choices.cloudOptions }

    @ViewBuilder
    private var cloudSide: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(cloudOptions.enumerated()), id: \.element.id) { index, option in
                if index > 0 { MynahDivider() }
                cloudRow(option)
            }
        }
    }

    private func cloudRow(_ option: BrainSetupOption) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                choice.selected = option
                choice.typedKey = ""
                refusal = nil
            } label: {
                HStack(alignment: .top, spacing: s4) {
                    StatusDot(option.id == choice.selected?.id ? .accent : .neutral)
                        .padding(.top, 5)
                    VStack(alignment: .leading, spacing: s1) {
                        HStack(spacing: s3) {
                            Text(option.label)
                                .mynahFont(.body)
                                .foregroundStyle(Palette.ink.primary)
                            if option.id == current?.id {
                                StatusPill("Now", tone: .neutral)
                            }
                            if hasSavedKey(option) {
                                StatusPill("Key saved", tone: .good)
                            }
                            Spacer(minLength: 0)
                        }
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

            // **Inline, under the provider it belongs to.** The owner's ruling:
            // *"in line is best - less clicking"*.
            if option.id == choice.selected?.id {
                keyField(for: option).padding(.bottom, s4)
            }
        }
    }

    @ViewBuilder
    private func keyField(for option: BrainSetupOption) -> some View {
        let instructions = option.keyProviderIdentifier
            .flatMap(APIKeyOnboarding.instructions(forProvider:))

        VStack(alignment: .leading, spacing: s2) {
            SecureField(
                hasSavedKey(option) ? "Paste a new key to replace the saved one" : "Paste your key",
                text: $choice.typedKey
            )
            .textFieldStyle(.roundedBorder)
            .mynahFont(.body)
            .onSubmit { if canCommit { commit() } }

            HStack(spacing: s3) {
                if let instructions {
                    Text(instructions.looksLikeHint)
                        .mynahFont(.label)
                        .foregroundStyle(Palette.ink.secondary)
                    Spacer(minLength: 0)
                    Link("Get a key", destination: instructions.keyPageURL)
                        .mynahFont(.label)
                        .pointingHandCursor()
                } else {
                    Spacer(minLength: 0)
                }
            }

            if let note = instructions?.costNote {
                Text(note)
                    .mynahFont(.label)
                    .foregroundStyle(Palette.ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, s7)
    }

    private func hasSavedKey(_ option: BrainSetupOption) -> Bool {
        guard let provider = option.keyProviderIdentifier else { return false }
        return KeyStorage.key(forProvider: provider) != nil
    }

    // MARK: - Result

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
            // Nothing is broken and nothing changed — the old brain is still
            // answering, because this saves nothing until it passes.
            InlineBanner(
                headline: "That one didn't answer.",
                explanation: refusal
                    + " Nothing has changed — Mynah is still using what it was."
            )
        }
    }

    // MARK: - Committing

    private var canCommit: Bool {
        guard !isChecking else { return false }
        return choice.canCommit(current: current) { KeyStorage.key(forProvider: $0) != nil }
    }

    private func commit() {
        guard let option = choice.resolved() else { return }
        let key = choice.typedKey.trimmingCharacters(in: .whitespacesAndNewlines)

        isChecking = true
        Task {
            defer { isChecking = false }

            // Saved before the check, because the check is what proves it works
            // and it has to be readable by the thing being checked. A key that
            // fails is replaced by the next attempt; one that is never written
            // cannot be tested at all.
            if let provider = option.keyProviderIdentifier, !key.isEmpty {
                do {
                    try KeyStorage.save(key, forProvider: provider)
                } catch {
                    refusal = "Mynah couldn't save that key to this Mac."
                    return
                }
            }

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
