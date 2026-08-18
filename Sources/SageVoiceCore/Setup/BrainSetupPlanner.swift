import Foundation

// MARK: - Option identity

/// Stable identity for a way of getting a brain.
///
/// Stable across probes and across releases: the settings panel stores the
/// owner's choice by this value, and "migrate me to fully local" has to mean the
/// same thing next month. Note there is one `fullyLocal` case rather than one
/// per install state — whether Ollama is already running is a fact about today,
/// not a different product choice.
public enum BrainSetupOptionID: String, Sendable, Codable, CaseIterable {
    case claudeCodeCLI = "cli.claude-code"
    case codexCLI = "cli.codex"
    case googleSignIn = "signin.google"
    case anthropicAPIKey = "key.anthropic"
    case openAIAPIKey = "key.openai"
    case googleAPIKey = "key.google"
    case deepSeekAPIKey = "key.deepseek"
    case moonshotAPIKey = "key.moonshot"
    case groqAPIKey = "key.groq"
    case glmAPIKey = "key.glm"
    case fullyLocal = "local.ollama"
}

// MARK: - What actually serves an option

/// The concrete backend an option would be built as.
///
/// This exists so "the planner offered it" and "the app can build it" are one
/// fact rather than two switches in two modules that drifted apart. They had:
/// the planner emitted `signin.google`, `cli.claude-code`, `cli.codex` and
/// `openai-compatible`, and the app's factory matched on `"ollama"`, `"gemini"`,
/// `"openai"` and `"anthropic"` — so four of the seven cards on the most
/// important screen in the product threw on first use, including the one the
/// app itself recommended.
///
/// `nil` from `BrainSetupOptionID.backendPlan` means *nothing in this product
/// can serve that option yet*, which is the planner's cue to mark it
/// unavailable rather than the owner's cue to discover it thirty seconds later.
public enum BrainSetupBackendPlan: Sendable, Equatable {
    case localOllama
    case anthropic
    case openAICompatible(OpenAICompatProvider)
}

public extension BrainSetupOptionID {

    /// How this option would be served, or `nil` when it cannot be yet.
    ///
    /// Exhaustive on purpose: adding a case to `BrainSetupOptionID` without
    /// deciding what serves it is a compile error here, not a runtime throw in
    /// front of the owner.
    var backendPlan: BrainSetupBackendPlan? {
        switch self {
        case .fullyLocal:      return .localOllama
        case .anthropicAPIKey: return .anthropic
        case .openAIAPIKey:    return .openAICompatible(.openAI)
        case .googleAPIKey:    return .openAICompatible(.gemini)
        case .deepSeekAPIKey:  return .openAICompatible(.deepSeek)
        case .moonshotAPIKey:  return .openAICompatible(.moonshot)
        case .groqAPIKey:      return .openAICompatible(.groq)
        case .glmAPIKey:       return .openAICompatible(.glm)
        // Both agent CLIs would have to be driven as subprocesses speaking their
        // own protocols, and consumer Google sign-in routes to Code Assist,
        // which is a different wire format from the Gemini API entirely. None of
        // those three backends exists in this product.
        case .claudeCodeCLI, .codexCLI, .googleSignIn:
            return nil
        }
    }

    /// The `APIKeyOnboarding` vocabulary for this option, or `nil` when it needs
    /// no pasted key.
    ///
    /// The single seam between an option's identity and the onboarding
    /// vocabulary. Passing `backendIdentifier` through raw is what produced the
    /// unrecoverable "Google Gemini API key" loop: the option said it needed a
    /// key, the instructions lookup said there was nothing to explain, and setup
    /// resolved the contradiction by skipping the screen.
    var keyProviderIdentifier: String? {
        switch backendPlan {
        case .anthropic: return "anthropic"
        case .openAICompatible(let provider): return provider.identifier
        case .localOllama, .none: return nil
        }
    }
}

public extension BrainSetupOption {
    /// Where this option's key is filed on disk, and which instructions explain
    /// how to get one. `nil` for anything that needs no key.
    var keyProviderIdentifier: String? { id.keyProviderIdentifier }
}

/// What the owner still has to do. Ordering of the cases is not the ranking —
/// see `BrainSetupTier` for that.
///
/// The "nothing to do" case is spelled `nothing`, not `none`: an
/// `Optional<BrainSetupRequirement>` compared against `.none` silently means
/// `nil`, and the first draft of the tests asserted exactly that by accident.
public enum BrainSetupRequirement: String, Sendable, Codable {
    /// Nothing. It would work the moment they pick it.
    case nothing
    /// One sign-in, in a browser or a CLI. No card, no key to paste.
    case signIn
    /// The owner has to obtain and paste an API key.
    case apiKey
    /// A multi-gigabyte download. See `BrainSetupOption.approximateDownloadBytes`.
    case download
}

/// Why an option cannot be offered, in words the install screen can print.
///
/// Unavailable options stay in the list. Silently hiding "fully local" from
/// someone with a 4 GB Mac tells them nothing; "Fully local needs at least
/// 8.6 GB of memory — this Mac has 4.3 GB" tells them what to buy.
public enum BrainSetupAvailability: Sendable, Equatable, Codable {
    case available
    case unavailable(reason: String)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    public var reason: String? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }
}

/// Coarse grouping that drives the order of the **fallback list** — the screen
/// an owner only reaches when this Mac cannot run a brain locally.
///
/// **This ranking is not the product default and must not be read as one.** It
/// orders by friction: how little the owner has to do to get answering. On that
/// axis fully-local genuinely is last, because it downloads several gigabytes
/// and installs a runtime, while a key already sitting in the environment costs
/// nothing at all.
///
/// The default is decided by `BrainSetupChoices.freshInstallDefault`, which
/// ignores this ordering entirely and picks local whenever the hardware allows.
/// The two disagree on purpose: least-work and least-exposure are different
/// questions, and the product answers the second one first.
///
/// The sentence here used to read *"zero-friction first, then API key, then
/// fully-local"* with nothing distinguishing an ordering rule from a product
/// intent — which is how a file that ranked privacy last sat under a README
/// promising privacy by default.
public enum BrainSetupTier: Int, Sendable, Codable, CaseIterable, Comparable {
    /// An agent CLI the owner is already signed into. Nothing to do, and it
    /// rides a flat-rate subscription they already pay for.
    case signedInSubscription = 0

    /// One sign-in, no key, no card. The Google free tier.
    case zeroFrictionSignIn = 1

    /// A provider key already sitting in this Mac's environment. Also zero
    /// input — but deliberately ranked *below* the two above, because it bills
    /// per token. Recommending a metered path over a flat-rate one the owner
    /// already pays for would be a quiet way to spend their money.
    case ambientAPIKey = 2

    /// The owner obtains a key and pastes it.
    case typedAPIKey = 3

    /// The CLI is installed but not signed in. Below the typed key because we
    /// have no evidence the owner actually has a subscription behind it — the
    /// binary being present proves nothing about entitlement.
    case installedCLINeedingSignIn = 4

    /// Fully local. Last by rank, never last in importance: it is the only
    /// option where the owner's words do not leave the machine, and it is
    /// offered whenever the hardware supports it no matter what else is here.
    case fullyLocal = 5

    public static func < (lhs: BrainSetupTier, rhs: BrainSetupTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Option

/// One offerable way to get a brain, ready to render on an install screen.
public struct BrainSetupOption: Sendable, Equatable, Codable, Identifiable {
    public var id: BrainSetupOptionID

    /// Short, for a row title.
    public var label: String

    /// One honest line. Says where the words go and what it costs, because the
    /// owner cannot be expected to infer either.
    public var summary: String

    public var requirement: BrainSetupRequirement

    /// True only when the owner's speech never leaves this machine.
    public var keepsWordsOnDevice: Bool

    /// Approximate bytes to fetch, present only when `requirement == .download`.
    public var approximateDownloadBytes: Int64?

    public var availability: BrainSetupAvailability

    public var tier: BrainSetupTier

    /// The `BrainBackend.identifier` this option would produce.
    public var backendIdentifier: String

    /// Concrete model, where the option pins one.
    public var modelName: String?

    public init(
        id: BrainSetupOptionID,
        label: String,
        summary: String,
        requirement: BrainSetupRequirement,
        keepsWordsOnDevice: Bool,
        approximateDownloadBytes: Int64? = nil,
        availability: BrainSetupAvailability,
        tier: BrainSetupTier,
        backendIdentifier: String,
        modelName: String? = nil
    ) {
        self.id = id
        self.label = label
        self.summary = summary
        self.requirement = requirement
        self.keepsWordsOnDevice = keepsWordsOnDevice
        self.approximateDownloadBytes = approximateDownloadBytes
        self.availability = availability
        self.tier = tier
        self.backendIdentifier = backendIdentifier
        self.modelName = modelName
    }

    public var isAvailable: Bool { availability.isAvailable }
}

// MARK: - Recommendation and selection

/// The planner's opinion. Deliberately *not* a selection.
///
/// This is one half of making "never auto-select" structural rather than a
/// comment: a recommendation carries an id and a reason, and there is no
/// initialiser, conversion, or overload anywhere that turns one into a
/// `BrainSetupSelection`. Code that wants a configured brain has to go back
/// through `BrainSetupChoices.select(_:)` with an id, and the only thing that
/// can supply that id is the owner.
public struct BrainSetupRecommendation: Sendable, Equatable, Codable {
    public let optionID: BrainSetupOptionID
    /// Why this one, in a sentence the UI can show under the highlighted row.
    public let rationale: String

    public init(optionID: BrainSetupOptionID, rationale: String) {
        self.optionID = optionID
        self.rationale = rationale
    }
}

/// A brain the owner actually chose.
///
/// The other half of the structural guarantee: the initialiser is internal, so
/// outside this module the *only* way to obtain one is
/// `BrainSetupChoices.select(_:)`, which requires an explicit id and refuses
/// anything unavailable. No default value, no `ExpressibleBy…`, and no way for
/// the planner to hand one back on its own.
public struct BrainSetupSelection: Sendable, Equatable {
    public let option: BrainSetupOption

    init(option: BrainSetupOption) {
        self.option = option
    }
}

// MARK: - Choices

/// The ordered menu for the install screen, plus a recommendation.
///
/// Contains no selection and no mutable state. Producing it twice from the same
/// probe produces the same value — which is what lets the settings panel re-run
/// the whole thing later to offer "move me to fully local".
public struct BrainSetupChoices: Sendable, Equatable, Codable {
    /// Every option, available ones first, each group in tier order.
    public let options: [BrainSetupOption]

    /// `nil` only if nothing at all is offerable, which the current catalog
    /// cannot produce — kept optional so a future catalog change cannot turn a
    /// missing recommendation into a crash.
    public let recommendation: BrainSetupRecommendation?

    public init(options: [BrainSetupOption], recommendation: BrainSetupRecommendation?) {
        self.options = options
        self.recommendation = recommendation
    }

    public var availableOptions: [BrainSetupOption] {
        options.filter(\.isAvailable)
    }

    public var unavailableOptions: [BrainSetupOption] {
        options.filter { !$0.isAvailable }
    }

    public func option(withID id: BrainSetupOptionID) -> BrainSetupOption? {
        options.first { $0.id == id }
    }

    /// Turn an explicit, owner-supplied id into a selection.
    ///
    /// - Returns: `nil` when the id is not in this catalog or its option is
    ///   unavailable. Refusing here rather than trusting the caller means a UI
    ///   bug surfaces as "nothing happened" instead of a daemon bound to a brain
    ///   this machine cannot run.
    public func select(_ id: BrainSetupOptionID) -> BrainSetupSelection? {
        guard let option = option(withID: id), option.isAvailable else {
            return nil
        }
        return BrainSetupSelection(option: option)
    }

    /// What a fresh install sets up without asking anybody, or `nil` when this
    /// Mac cannot run it.
    ///
    /// **This is the one auto-selection in the product, and it is deliberately
    /// the only one that can be.**
    ///
    /// Everything else here exists to stop code choosing a brain on the owner's
    /// behalf: `BrainSetupSelection`'s initialiser is internal, there is no
    /// conversion from a recommendation, and `select(_:)` demands an id only a
    /// person can supply. That guard is not about auto-selection being untidy.
    /// It is about the two things a wrong default actually does — **spend the
    /// owner's money**, and **send their words to a company** — neither of which
    /// they agreed to and both of which are hard to notice and hard to undo.
    ///
    /// `.fullyLocal` cannot do either. It has no credential to bill, and its
    /// whole definition is that speech stays on the machine. So defaulting to it
    /// is not a weaker version of the rule; it is the only choice that satisfies
    /// what the rule was protecting, which is why this property names one
    /// specific option rather than taking an id.
    ///
    /// It also makes a claim the product has been making anyway finally true.
    /// The planner already *recommended* local, the install screen already put
    /// it first, and the README said privacy by default — while the flow made
    /// every new owner pick from a menu, where the fastest path was whatever
    /// cloud key happened to be in their environment. A default nobody is given
    /// is a preference, not a default.
    ///
    /// `nil` is not a failure to handle quietly. It means this Mac genuinely
    /// cannot run a brain locally, and the owner now has to make a decision they
    /// were never going to be asked to make — so whoever reads this `nil` owes
    /// them the reason from `option(withID: .fullyLocal)?.availability`, which
    /// carries a specific obstacle and not a shrug.
    public var freshInstallDefault: BrainSetupSelection? {
        guard let option = option(withID: .fullyLocal), option.isAvailable else { return nil }
        return BrainSetupSelection(option: option)
    }

    /// Why the private default is not on offer, when it is not.
    ///
    /// Exists so a caller cannot report "you need to choose" without being able
    /// to say what happened — the reason is one accessor away from the `nil`
    /// that makes it necessary.
    public var freshInstallDefaultObstacle: String? {
        guard freshInstallDefault == nil else { return nil }
        return option(withID: .fullyLocal)?.availability.reason
    }
}

// MARK: - Planner

/// Turns a probe result into a ranked, honest menu.
///
/// Pure: no stored state, no I/O, no clock. Every input arrives in the
/// `EnvironmentProbeResult`, which is why the ranking and gating rules can be
/// tested against a synthetic 4 GB Intel Mac from a machine that is neither.
public struct BrainSetupPlanner: Sendable {
    public init() {}

    // MARK: Words that have to be true where they are printed

    /// "this Mac" is a true phrase on exactly one of the three platforms this
    /// package now builds for, and `sage-voiced setup` prints every string in
    /// this file on all of them.
    ///
    /// Taken from `HardwareReport.platform` rather than from a `#if` on the
    /// build, for two reasons. It keeps one source of truth for "what is this
    /// machine" — the probe — instead of two that can disagree; and it makes the
    /// wording testable from either host, so a Mac can prove the Linux sentence
    /// and Linux can prove the Mac one. A rule only testable on the machine it
    /// is wrong about is how the Apple Silicon refusal survived this long.
    ///
    /// On `.darwin` both helpers return the words 2.3.0 shipped, so every option
    /// summary, refusal and rationale below is byte-identical to what a Mac
    /// owner sees today.
    static func deviceNoun(_ platform: HostPlatform) -> String {
        platform == .darwin ? "this Mac" : "this machine"
    }

    /// Sentence-initial form of `deviceNoun(_:)`.
    static func deviceNounCapitalized(_ platform: HostPlatform) -> String {
        platform == .darwin ? "This Mac" : "This machine"
    }

    public func plan(for probe: EnvironmentProbeResult) -> BrainSetupChoices {
        var options: [BrainSetupOption] = []
        // The agent CLIs are deliberately absent — see `AgentCLINotOffered`.
        options.append(contentsOf: apiKeyOptions(probe.ambientAPIKeys, on: probe.hardware.platform))
        options.append(fullyLocalOption(probe))

        // Catalog position is the final tie-break, so the order is total and the
        // same probe always yields the same list.
        let catalogIndex = Dictionary(
            uniqueKeysWithValues: options.enumerated().map { ($0.element.id, $0.offset) }
        )
        let ordered = options.sorted { lhs, rhs in
            if lhs.isAvailable != rhs.isAvailable { return lhs.isAvailable }
            if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
            return (catalogIndex[lhs.id] ?? 0) < (catalogIndex[rhs.id] ?? 0)
        }

        // Privacy is the product default. The local card is already rendered
        // first structurally; recommend it too whenever this Mac can support
        // the automated install. This is guidance, never a silent selection.
        let recommended = ordered.first { $0.id == .fullyLocal && $0.isAvailable }
            ?? ordered.first(where: \.isAvailable)
        return BrainSetupChoices(
            options: ordered,
            recommendation: recommended.map { recommendation(for: $0, on: probe.hardware.platform) }
        )
    }

    // MARK: Google

    /// Google is not offered, by either route.
    ///
    /// Two cards used to carry it and neither survived contact with the owner.
    ///
    /// "Sign in with Google" was the *recommendation* on a bare Mac and had no
    /// screen behind it: `requirement` was `.signIn`, the flow has no sign-in
    /// stage, so `advance()` skipped straight past it and Ready declared "Mynah
    /// is ready" for a brain that had never been connected to anything. It was
    /// then left in the catalog permanently unavailable, on the theory that a
    /// card saying "this is coming" beats an option that silently is not there.
    /// That theory only holds while the thing is actually coming. Consumer
    /// Google sign-in routes to Code Assist, which is a different wire format
    /// from the Gemini API entirely — nothing in this product speaks it and
    /// nothing is being built to. A permanent "coming soon" is a promise, and
    /// leaving one on the first screen the owner sees is a lie with a long tail.
    ///
    /// The API-key card went for a plainer reason: the owner asked for Google
    /// out. It is the one provider here that also reads the owner's mail.
    ///
    /// What deliberately did *not* go: `BrainSetupOptionID.googleAPIKey`, its
    /// `backendPlan`, and the `"google"` alias in `APIKeyOnboarding`. An owner
    /// who chose Gemini in a shipped build has `key.google` written to disk. If
    /// the case were deleted, their stored choice would decode to `nil` on the
    /// next launch — and an unreadable choice is indistinguishable from no
    /// choice, so the appliance would quietly ask them to set it up again while
    /// a working key sat in the file. Removing an *offer* is not the same as
    /// removing an *identity*, and only the offer was asked for. Their brain
    /// keeps answering; they simply cannot pick it fresh.
    private static let providersNoLongerOffered: Set<APIKeyProvider> = [.google]

    // MARK: API keys

    /// Anthropic, OpenAI and Google are always in the catalog: they are the
    /// providers a non-technical owner has plausibly heard of and might hold a
    /// key for.
    /// Deliberately absent: an allowlist of "providers a non-technical owner has
    /// plausibly heard of".
    ///
    /// It held `[.anthropic, .openAI, .google]`, and everything else entered the
    /// catalogue only if its key was already in the environment. The reasoning
    /// was sound — do not show somebody a menu of things they may not have — and
    /// the rule it produced was **self-fulfilling**: you cannot choose a
    /// provider you are never shown, so an owner without a key already exported
    /// could never acquire one.
    ///
    /// What it actually encoded was an assumption about who the owner is, and
    /// the owner spotted it from the outside: *"there is no deepseek, kimi, glm
    /// — a bit biased towards US aren't we"*. He runs a security conference in
    /// Kuala Lumpur. He has heard of DeepSeek.
    ///
    /// The original insight survives without the exclusion: **evidence still
    /// counts, for ordering rather than for existence.** An ambient key makes a
    /// provider cheaper to pick, and `BrainSetupPlanner` already ranks on
    /// friction, so a provider whose key is already exported still rises. What
    /// no longer happens is a choice being hidden from the person deciding.
    ///
    /// The structural guard below is a different thing and must survive: an
    /// option whose key we cannot explain how to obtain is not offerable at all.

    private func apiKeyOptions(
        _ keys: AmbientAPIKeyReport,
        on platform: HostPlatform
    ) -> [BrainSetupOption] {
        APIKeyProvider.allCases.compactMap { provider in
            // Withdrawn providers never reach the menu — see `providersNoLongerOffered`
            // above for why this is a subtraction from the offer and not from the
            // vocabulary. An ambient key does not bring one back: the whole point
            // of the paragraph below is that evidence orders the menu rather than
            // populating it, and a withdrawn provider is not on the menu to order.
            guard !Self.providersNoLongerOffered.contains(provider) else { return nil }

            // Structural guard, not a filter anyone expects to fire: an option
            // that needs a key we cannot explain how to obtain must not be
            // offerable at all. "Google Gemini API key" shipped for months with
            // no instructions behind it, which meant the key screen was skipped
            // and Ready declared success for a brain with no credential.
            guard APIKeyOnboarding.instructions(forProvider: provider.backendIdentifier) != nil else {
                return nil
            }

            // The same guard, for the other half of what an option needs.
            //
            // **GLM shipped through the first one and dead-ended on this.** It
            // has instructions, so it was offered; it has no entry in
            // `CloudBrainModelCatalog`, so `BrainFactory.defaultModelName` fell
            // through to its `?? "local-model"` and asked Zhipu for a model
            // called `local-model`. The owner's reward for reading the
            // instructions, opening the Zhipu console, and putting credit on a
            // card was a refusal naming a model nobody has ever served.
            //
            // Knowing how to obtain a key is not the same as knowing what to
            // ask for once you have one, and an option missing either is not
            // offerable. The catalogue returning `nil` is a deliberate "this
            // product has not chosen" — see its type comment — and this is what
            // reading that answer honestly looks like at the menu.
            guard CloudBrainModelCatalog.model(forProvider: provider.backendIdentifier) != nil else {
                return nil
            }
            let hasAmbientKey = keys.hasKey(for: provider)
            // The niche providers enter the catalog only on evidence. Listing
            // Moonshot and Groq to an owner who has never heard of either is
            // exactly the "menu of things you may not have" the install screen
            // exists to avoid; but if their key is right there in the
            // environment, hiding it would be the wrong call too.

            return BrainSetupOption(
                id: keyOptionID(for: provider),
                label: hasAmbientKey
                    ? "\(provider.displayName) — key already set"
                    : "\(provider.displayName) API key",
                summary: hasAmbientKey
                    ? "Uses the \(provider.displayName) API key already set on "
                        + "\(Self.deviceNoun(platform)). Billed "
                        + "per use. What you say goes to \(provider.displayName)."
                    : "Paste \(Self.indefiniteArticle(for: provider.displayName)) "
                        + "\(provider.displayName) API key. Billed per use. What you say goes "
                        + "to \(provider.displayName).",
                requirement: hasAmbientKey ? .nothing : .apiKey,
                keepsWordsOnDevice: false,
                availability: .available,
                tier: hasAmbientKey ? .ambientAPIKey : .typedAPIKey,
                backendIdentifier: provider.backendIdentifier
            )
        }
    }

    private func keyOptionID(for provider: APIKeyProvider) -> BrainSetupOptionID {
        switch provider {
        case .anthropic: return .anthropicAPIKey
        case .openAI:    return .openAIAPIKey
        case .google:    return .googleAPIKey
        case .deepSeek:  return .deepSeekAPIKey
        case .moonshot:  return .moonshotAPIKey
        case .groq:      return .groqAPIKey
        case .glm:       return .glmAPIKey
        }
    }

    // MARK: Fully local

    /// Offered only when it would answer *today*.
    ///
    /// The download branches are gated rather than advertised because nothing in
    /// this product performs that download — there is no Ollama installer, no
    /// `pull`, no progress. The card used to read "Downloads qwen3.5:4b (about
    /// 3.4 GB) and runs it on this Mac", setup skipped the key stage because a
    /// `.download` requirement needs no key, Ready said "Mynah is ready", and the
    /// first question reached a daemon that was never installed and surfaced as
    /// "check this Mac is online" — sending the owner to look at their Wi-Fi for
    /// a file that was never fetched.
    ///
    /// The option stays in the catalog in every state, and the reason names the
    /// real obstacle, because this is the only choice that keeps the owner's
    /// words on the machine and hiding it would say nothing at all.
    private func fullyLocalOption(_ probe: EnvironmentProbeResult) -> BrainSetupOption {
        let hardware = probe.hardware
        let runtime = probe.localRuntime
        let capability = hardware.localModelCapability
        let platform = hardware.platform
        let label = "Fully on \(Self.deviceNoun(platform))"

        func option(
            summary: String,
            requirement: BrainSetupRequirement,
            downloadBytes: Int64?,
            availability: BrainSetupAvailability,
            model: String?
        ) -> BrainSetupOption {
            BrainSetupOption(
                id: .fullyLocal,
                label: label,
                summary: summary,
                requirement: requirement,
                keepsWordsOnDevice: true,
                approximateDownloadBytes: downloadBytes,
                availability: availability,
                tier: .fullyLocal,
                backendIdentifier: "ollama",
                modelName: model
            )
        }

        guard capability.isOfferable else {
            return option(
                summary: "Runs the brain on \(Self.deviceNoun(platform)) so nothing you say "
                    + "leaves it.",
                requirement: .download,
                downloadBytes: nil,
                availability: .unavailable(
                    reason: unsupportedHardwareReason(hardware, runtime: runtime)
                ),
                model: nil
            )
        }

        let tightNote = capability == .tight
            ? " \(Self.deviceNounCapitalized(platform)) has "
                + "\(Self.gigabytes(Int64(hardware.physicalMemoryBytes))) of memory, "
                + "which is enough but not roomy — expect it to be slower and to compete with "
                + "speech recognition."
            : ""

        // **The half of the hardware question this probe cannot answer.**
        //
        // Off Darwin `LocalModelCapability.forMachine` gates on memory alone,
        // because nothing here can see whether the box has a GPU Ollama could
        // reach — see its comment for why it offers anyway rather than refusing
        // machines nobody measured. Offering silently would be exactly the
        // over-promise that reasoning depends on not making: a CPU-only 4B
        // routing turn is tens of seconds, and an owner told nothing has no way
        // to read that as anything but broken.
        //
        // Empty on Darwin, where `isAppleSilicon` already settled the question.
        let acceleratorNote = platform.metalIsTheOnlyAccelerator
            ? ""
            : " Mynah cannot see from here whether \(Self.deviceNoun(platform)) has a GPU Ollama "
                + "can use; without one the model runs on the CPU and a reply takes far longer "
                + "than speech can wait for."

        // Already pulled and serving: no download, so no disk gate. This is the
        // branch the settings panel hits after a successful migration.
        if runtime.isReadyToServe, let model = runtime.preferredInstalledModel {
            return option(
                summary: "Runs \(model) on \(Self.deviceNoun(platform)). Nothing you say leaves "
                    + "the machine, and there's nothing to sign into or pay "
                    + "for.\(tightNote)\(acceleratorNote)",
                requirement: .nothing,
                downloadBytes: nil,
                availability: .available,
                model: model
            )
        }

        let hasEmbeddingModel = runtime.installedModels.contains {
            LocalBrainModelCatalog.normalize($0)
                == LocalBrainModelCatalog.normalize(LocalBrainModelCatalog.embeddingModel)
        }
        let downloadBytes =
            (runtime.preferredInstalledModel == nil
                ? LocalBrainModelCatalog.approximateModelDownloadBytes : 0)
            + (hasEmbeddingModel
                ? 0 : LocalBrainModelCatalog.approximateEmbeddingModelDownloadBytes)
            + (runtime.isRuntimeInstalled
                ? 0 : LocalBrainModelCatalog.approximateRuntimeDownloadBytes)
        let runtimeNote = runtime.isRuntimeInstalled
            ? ""
            : " It needs the Ollama runtime on \(Self.deviceNoun(platform)) as well."

        guard hardware.hasRoomForDownload(ofBytes: downloadBytes) else {
            return option(
                summary: "Runs \(LocalBrainModelCatalog.preferredModel) on "
                    + "\(Self.deviceNoun(platform)) so nothing you say leaves it.",
                requirement: .download,
                downloadBytes: downloadBytes,
                availability: .unavailable(reason: insufficientDiskReason(hardware, needs: downloadBytes)),
                model: LocalBrainModelCatalog.preferredModel
            )
        }

        return option(
            summary: "Runs \(LocalBrainModelCatalog.preferredModel) on "
                + "\(Self.deviceNoun(platform)). Nothing you say leaves the machine, and there's "
                + "nothing to sign into or pay for.\(runtimeNote)\(tightNote)\(acceleratorNote)",
            requirement: .download,
            downloadBytes: downloadBytes,
            availability: .available,
            model: LocalBrainModelCatalog.preferredModel
        )
    }

    /// Why fully-local is off the table, in words that are true on the machine
    /// printing them.
    ///
    /// **The Apple Silicon clause is gated on the platform, not on the flag
    /// alone.** `isAppleSilicon` is a measurement on a Mac and a hardcoded
    /// `false` everywhere else — see `HostPlatform` — so reading it bare printed
    /// *"needs Apple Silicon — on an Intel chip a reply takes far too long"* on
    /// a Threadripper with a 4090. Every clause of that sentence was false about
    /// the machine it appeared on, and the option it refused would have answered
    /// faster there than on the Mac the sentence was written for.
    ///
    /// The runtime is passed in for a related reason: this is the one screen the
    /// owner cannot get past, so it has to answer the objection they are about
    /// to make.
    private func unsupportedHardwareReason(
        _ hardware: HardwareReport,
        runtime: LocalModelRuntimeReport
    ) -> String {
        let platform = hardware.platform

        // Said out loud whenever we refuse a machine whose daemon is up with the
        // weights already pulled, because that owner is looking at a working
        // `ollama run` in another window and a refusal that ignores it reads as
        // a bug in Mynah rather than a fact about the machine.
        //
        // **It is also the answer to whether this gate should simply defer to
        // `isReadyToServe`. It must not.** `LocalModelRuntimeReport` is built
        // from `/api/version` and `/api/tags`: it says the daemon answered and
        // the weights are on disk. Neither is the claim being made here, which
        // is that 3.4 GB of weights fit in memory beside a 1.6 GB ASR model and
        // come back inside a spoken pause. On the machines this branch refuses —
        // under 8 GiB anywhere, or an Intel Mac — a pulled model is exactly the
        // state that ends in swapping or dead air. Evidence beats a guess, but
        // "the file exists" is not evidence about the thing being guessed.
        var serving = ""
        if runtime.isReadyToServe, let model = runtime.preferredInstalledModel {
            serving = " Ollama is already serving \(model) here — that proves the weights are on "
                + "disk, not that \(Self.deviceNoun(platform)) can hold and run them fast enough "
                + "for spoken conversation."
        }

        if platform.metalIsTheOnlyAccelerator, !hardware.isAppleSilicon {
            let chip = hardware.cpuBrand
                .map { " \(Self.deviceNounCapitalized(platform)) reports \($0)." } ?? ""
            return "Running the brain on \(Self.deviceNoun(platform)) needs Apple Silicon — on an "
                + "Intel chip a reply takes far too long to be spoken "
                + "conversation.\(chip)\(serving)"
        }
        return "Running the brain on \(Self.deviceNoun(platform)) needs at least "
            + "\(Self.gigabytes(Int64(LocalBrainModelCatalog.minimumMemoryBytes))) of memory — "
            + "\(Self.deviceNoun(platform)) has "
            + "\(Self.gigabytes(Int64(hardware.physicalMemoryBytes))).\(serving)"
    }

    private func insufficientDiskReason(_ hardware: HardwareReport, needs: Int64) -> String {
        let required = max(needs, LocalBrainModelCatalog.requiredFreeDiskBytes)
        let free = hardware.freeDiskBytes.map(Self.gigabytes) ?? "an unknown amount"
        return "Running the brain on \(Self.deviceNoun(hardware.platform)) needs about "
            + "\(Self.gigabytes(required)) free to download the model — this volume has "
            + "\(free) free."
    }

    // MARK: Recommendation

    private func recommendation(
        for option: BrainSetupOption,
        on platform: HostPlatform
    ) -> BrainSetupRecommendation {
        let rationale: String
        switch option.tier {
        case .signedInSubscription:
            rationale = "You're already signed in, so there's nothing to set up and no extra cost."
        case .zeroFrictionSignIn:
            rationale = "One sign-in with an account you probably already have — no API key, no card."
        case .ambientAPIKey:
            rationale = "A key for this provider is already set on \(Self.deviceNoun(platform)), "
                + "so it works right away. It bills per use."
        case .typedAPIKey:
            rationale = "Nothing zero-effort was found on \(Self.deviceNoun(platform)), so this "
                + "needs an API key you provide."
        case .installedCLINeedingSignIn:
            rationale = "This is installed already; signing in is the shortest path from here."
        case .fullyLocal:
            rationale = "It keeps everything you say on \(Self.deviceNoun(platform)), with no "
                + "account or usage bill."
        }
        return BrainSetupRecommendation(optionID: option.id, rationale: rationale)
    }

    // MARK: Formatting

    /// Decimal GB, matching how macOS reports storage to the owner. Thresholds
    /// are held in binary units internally; only the display is decimal, which
    /// is why 8 GiB prints as "8.6 GB".
    ///
    /// `String(format:)` with no locale is non-localised on purpose — these
    /// strings are compared in tests and pasted into support bundles.
    static func gigabytes(_ bytes: Int64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
    }

    /// "an Anthropic API key", not "a Anthropic API key". Crude, but every
    /// provider name in the catalog is a plain word starting with a letter, and
    /// this text is read by the owner on the first screen they ever see.
    ///
    /// Public because the app module needs it too and did not have it: the
    /// Connect screen built its own "Get a \(provider) key" by interpolation and
    /// shipped "Get a Anthropic key" on the button that is the entire point of
    /// that screen. One copy, or this happens again the next time someone writes
    /// the phrase.
    public static func indefiniteArticle(for noun: String) -> String {
        guard let first = noun.lowercased().first else { return "a" }
        return "aeiou".contains(first) ? "an" : "a"
    }
}
