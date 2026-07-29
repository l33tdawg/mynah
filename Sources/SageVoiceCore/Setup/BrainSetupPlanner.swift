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

/// Coarse grouping that drives the order of the list.
///
/// Priority intent, in the product's terms: zero-friction first, then API key,
/// then fully-local — with fully-local always present when the hardware allows.
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
}

// MARK: - Planner

/// Turns a probe result into a ranked, honest menu.
///
/// Pure: no stored state, no I/O, no clock. Every input arrives in the
/// `EnvironmentProbeResult`, which is why the ranking and gating rules can be
/// tested against a synthetic 4 GB Intel Mac from a machine that is neither.
public struct BrainSetupPlanner: Sendable {
    public init() {}

    public func plan(for probe: EnvironmentProbeResult) -> BrainSetupChoices {
        var options: [BrainSetupOption] = []
        options.append(contentsOf: AgentCLIKind.allCases.map { cliOption(probe.cli($0)) })
        options.append(googleSignInOption())
        options.append(contentsOf: apiKeyOptions(probe.ambientAPIKeys))
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
            recommendation: recommended.map(recommendation(for:))
        )
    }

    // MARK: Agent CLIs

    /// Why an agent CLI is never offerable today, in words a card can print.
    ///
    /// Driving `claude` or `codex` means owning a subprocess that speaks its own
    /// protocol, and no such backend exists here — `BrainSetupOptionID.backendPlan`
    /// says so in one place and this sentence is what the owner reads. Shipping
    /// it as available is what produced the dead end a reviewer walked into:
    /// pick the app's own sparkle-marked recommendation, finish setup, and the
    /// first question answers "Mynah can't use that brain any more", with the
    /// only offer being a wizard that recommends it again.
    /// Leads with the detection, because the owner concluded the opposite.
    ///
    /// He read the greyed row as *"this Mac does not have it"* and said so:
    /// *"we have codex and claude installed clearly; i'm using you right — yet
    /// it thinks we don't"*. Detection was working the whole time; the sentence
    /// naming the real reason was losing to the visual state, because grey means
    /// "not found here" to everybody. So the first clause is now the fact he
    /// doubted.
    ///
    /// **"yet" is gone, and that is deliberate.** It promised a backend that is
    /// not coming in this shape. `claude -p` is not a model endpoint — it is an
    /// agent with its own system prompt, its own tools and its own
    /// `--mcp-config`, so it does not emit tool calls for `ToolLoop` to run, it
    /// runs its own. Measured on the owner's Mac: 4.4 s and ~26,000 tokens of
    /// context to answer "ok". Driving it would nest an agent inside an agent
    /// and bypass the allowlist, the reply style and the turn budget that make
    /// this an appliance.
    ///
    /// Handing whole conversations to it is a real and possibly good idea. It is
    /// a different product decision, not this option, and saying "yet" would go
    /// on quietly promising the version that cannot work.
    private func cliUnsupportedReason(_ kind: AgentCLIKind) -> String {
        "Mynah can see \(kind.displayName) on this Mac, and can't think through it. "
            + "\(kind.displayName) is an assistant in its own right rather than a model "
            + "Mynah can drive — it brings its own tools and its own memory. Pick another "
            + "way for now."
    }

    private func cliOption(_ report: AgentCLIReport) -> BrainSetupOption {
        let kind = report.kind
        let id: BrainSetupOptionID = kind == .claudeCode ? .claudeCodeCLI : .codexCLI
        let backend = kind == .claudeCode ? "claude-code-cli" : "codex-cli"

        guard report.isInstalled else {
            return BrainSetupOption(
                id: id,
                label: kind.displayName,
                summary: "Use the \(kind.displayName) subscription you already pay for.",
                // Moot while unavailable; recorded so the shape is consistent.
                requirement: .signIn,
                keepsWordsOnDevice: false,
                availability: .unavailable(
                    reason: "\(kind.displayName) isn't installed on this Mac."
                ),
                tier: .signedInSubscription,
                backendIdentifier: backend
            )
        }

        if report.hasSubscriptionCredential {
            return BrainSetupOption(
                id: id,
                label: "\(kind.displayName) — already signed in",
                summary: "Uses the \(kind.displayName) sign-in already on this Mac, so there's "
                    + "nothing to set up and nothing extra to pay. What you say goes to "
                    + "\(kind.vendorName).",
                requirement: .nothing,
                keepsWordsOnDevice: false,
                availability: .unavailable(reason: cliUnsupportedReason(kind)),
                tier: .signedInSubscription,
                backendIdentifier: backend
            )
        }

        if report.hasAmbientAPIKey {
            return BrainSetupOption(
                id: id,
                label: "\(kind.displayName) — using the key in your environment",
                summary: "\(kind.displayName) is installed and would run on the "
                    + "\(kind.vendorName) API key already set on this Mac. That's billed per "
                    + "use, not covered by a subscription. What you say goes to "
                    + "\(kind.vendorName).",
                requirement: .nothing,
                keepsWordsOnDevice: false,
                availability: .unavailable(reason: cliUnsupportedReason(kind)),
                tier: .ambientAPIKey,
                backendIdentifier: backend
            )
        }

        return BrainSetupOption(
            id: id,
            label: "\(kind.displayName) — needs sign-in",
            summary: "\(kind.displayName) is installed but not signed in. Sign in with your "
                + "\(kind.vendorName) account to use it. What you say goes to "
                + "\(kind.vendorName).",
            requirement: .signIn,
            keepsWordsOnDevice: false,
            availability: .unavailable(reason: cliUnsupportedReason(kind)),
            tier: .installedCLINeedingSignIn,
            backendIdentifier: backend
        )
    }

    // MARK: Google sign-in

    /// Always listed, never yet offerable.
    ///
    /// This was the recommendation on a bare Mac, and it had no screen behind it:
    /// `requirement` is `.signIn`, the flow has no sign-in stage, so `advance()`
    /// skipped straight past it and Ready declared "Mynah is ready" for a brain
    /// that had never been connected to anything. `GoogleSignInSession` and
    /// `GeminiKeyProvisioner` exist, but only the CLI drives them, and consumer
    /// sign-in routes to Code Assist rather than the Gemini API — a different
    /// wire format, so there is no backend either (`backendPlan` is `nil`).
    ///
    /// It stays in the catalog rather than being hidden: the card says in plain
    /// words that this is coming, which is more useful than an option that
    /// silently is not there.
    private func googleSignInOption() -> BrainSetupOption {
        BrainSetupOption(
            id: .googleSignIn,
            label: "Sign in with Google",
            summary: "Sign in with a Google account — no API key and no card. What you say goes "
                + "to Google.",
            requirement: .signIn,
            keepsWordsOnDevice: false,
            availability: .unavailable(
                reason: "Signing in with Google isn't ready yet. Pick another way for now — "
                    + "you can switch to this later. If you already have a Google key, "
                    + "“Google Gemini API key” below works today."
            ),
            tier: .zeroFrictionSignIn,
            backendIdentifier: "gemini"
        )
    }

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

    private func apiKeyOptions(_ keys: AmbientAPIKeyReport) -> [BrainSetupOption] {
        APIKeyProvider.allCases.compactMap { provider in
            // Structural guard, not a filter anyone expects to fire: an option
            // that needs a key we cannot explain how to obtain must not be
            // offerable at all. "Google Gemini API key" shipped for months with
            // no instructions behind it, which meant the key screen was skipped
            // and Ready declared success for a brain with no credential.
            guard APIKeyOnboarding.instructions(forProvider: provider.backendIdentifier) != nil else {
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
                    ? "Uses the \(provider.displayName) API key already set on this Mac. Billed "
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
        let label = "Fully on this Mac"

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
                summary: "Runs the brain on this Mac so nothing you say leaves it.",
                requirement: .download,
                downloadBytes: nil,
                availability: .unavailable(reason: unsupportedHardwareReason(hardware)),
                model: nil
            )
        }

        let tightNote = capability == .tight
            ? " This Mac has \(Self.gigabytes(Int64(hardware.physicalMemoryBytes))) of memory, "
                + "which is enough but not roomy — expect it to be slower and to compete with "
                + "speech recognition."
            : ""

        // Already pulled and serving: no download, so no disk gate. This is the
        // branch the settings panel hits after a successful migration.
        if runtime.isReadyToServe, let model = runtime.preferredInstalledModel {
            return option(
                summary: "Runs \(model) on this Mac. Nothing you say leaves the machine, and "
                    + "there's nothing to sign into or pay for.\(tightNote)",
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
            : " It needs the Ollama runtime on this Mac as well."

        guard hardware.hasRoomForDownload(ofBytes: downloadBytes) else {
            return option(
                summary: "Runs \(LocalBrainModelCatalog.preferredModel) on this Mac so nothing "
                    + "you say leaves it.",
                requirement: .download,
                downloadBytes: downloadBytes,
                availability: .unavailable(reason: insufficientDiskReason(hardware, needs: downloadBytes)),
                model: LocalBrainModelCatalog.preferredModel
            )
        }

        return option(
            summary: "Runs \(LocalBrainModelCatalog.preferredModel) on this Mac. Nothing you "
                + "say leaves the machine, and there's nothing to sign into or pay "
                + "for.\(runtimeNote)\(tightNote)",
            requirement: .download,
            downloadBytes: downloadBytes,
            availability: .available,
            model: LocalBrainModelCatalog.preferredModel
        )
    }

    private func unsupportedHardwareReason(_ hardware: HardwareReport) -> String {
        if !hardware.isAppleSilicon {
            let chip = hardware.cpuBrand.map { " This Mac reports \($0)." } ?? ""
            return "Running the brain on this Mac needs Apple Silicon — on an Intel chip a reply "
                + "takes far too long to be spoken conversation.\(chip)"
        }
        return "Running the brain on this Mac needs at least "
            + "\(Self.gigabytes(Int64(LocalBrainModelCatalog.minimumMemoryBytes))) of memory — "
            + "this Mac has \(Self.gigabytes(Int64(hardware.physicalMemoryBytes)))."
    }

    private func insufficientDiskReason(_ hardware: HardwareReport, needs: Int64) -> String {
        let required = max(needs, LocalBrainModelCatalog.requiredFreeDiskBytes)
        let free = hardware.freeDiskBytes.map(Self.gigabytes) ?? "an unknown amount"
        return "Running the brain on this Mac needs about \(Self.gigabytes(required)) free to "
            + "download the model — this volume has \(free) free."
    }

    // MARK: Recommendation

    private func recommendation(for option: BrainSetupOption) -> BrainSetupRecommendation {
        let rationale: String
        switch option.tier {
        case .signedInSubscription:
            rationale = "You're already signed in, so there's nothing to set up and no extra cost."
        case .zeroFrictionSignIn:
            rationale = "One sign-in with an account you probably already have — no API key, no card."
        case .ambientAPIKey:
            rationale = "A key for this provider is already set on this Mac, so it works right "
                + "away. It bills per use."
        case .typedAPIKey:
            rationale = "Nothing zero-effort was found on this Mac, so this needs an API key you "
                + "provide."
        case .installedCLINeedingSignIn:
            rationale = "This is installed already; signing in is the shortest path from here."
        case .fullyLocal:
            rationale = "It keeps everything you say on this Mac, with no account or usage bill."
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
