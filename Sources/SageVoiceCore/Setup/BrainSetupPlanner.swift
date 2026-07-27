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
    case fullyLocal = "local.ollama"
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

        return BrainSetupChoices(
            options: ordered,
            recommendation: ordered.first(where: \.isAvailable).map(recommendation(for:))
        )
    }

    // MARK: Agent CLIs

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
                availability: .available,
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
                availability: .available,
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
            availability: .available,
            tier: .installedCLINeedingSignIn,
            backendIdentifier: backend
        )
    }

    // MARK: Google sign-in

    /// Always offered, and always available: it depends on the owner having a
    /// Google account, which no probe of this machine can settle. This is the
    /// path for the owner with no API key and no CLI — the majority case the
    /// product is aimed at.
    private func googleSignInOption() -> BrainSetupOption {
        BrainSetupOption(
            id: .googleSignIn,
            label: "Sign in with Google",
            summary: "Sign in with a Google account — no API key and no card. What you say goes "
                + "to Google.",
            requirement: .signIn,
            keepsWordsOnDevice: false,
            availability: .available,
            tier: .zeroFrictionSignIn,
            backendIdentifier: "google"
        )
    }

    // MARK: API keys

    /// Anthropic, OpenAI and Google are always in the catalog: they are the
    /// providers a non-technical owner has plausibly heard of and might hold a
    /// key for.
    private static let alwaysOfferedKeyProviders: [APIKeyProvider] = [.anthropic, .openAI, .google]

    private func apiKeyOptions(_ keys: AmbientAPIKeyReport) -> [BrainSetupOption] {
        APIKeyProvider.allCases.compactMap { provider in
            let hasAmbientKey = keys.hasKey(for: provider)
            // The niche providers enter the catalog only on evidence. Listing
            // Moonshot and Groq to an owner who has never heard of either is
            // exactly the "menu of things you may not have" the install screen
            // exists to avoid; but if their key is right there in the
            // environment, hiding it would be the wrong call too.
            guard hasAmbientKey || Self.alwaysOfferedKeyProviders.contains(provider) else {
                return nil
            }
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
        }
    }

    // MARK: Fully local

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

        let downloadBytes = LocalBrainModelCatalog.approximateModelDownloadBytes
            + (runtime.isRuntimeInstalled ? 0 : LocalBrainModelCatalog.approximateRuntimeDownloadBytes)
        let runtimeNote = runtime.isRuntimeInstalled
            ? ""
            : " Installs the Ollama runtime as well."

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
            summary: "Downloads \(LocalBrainModelCatalog.preferredModel) "
                + "(about \(Self.gigabytes(downloadBytes))) and runs it on this Mac. Nothing you "
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
            rationale = "Nothing else was found on this Mac, and this one keeps everything you "
                + "say on the machine."
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
    static func indefiniteArticle(for noun: String) -> String {
        guard let first = noun.lowercased().first else { return "a" }
        return "aeiou".contains(first) ? "an" : "a"
    }
}
