import Foundation

// MARK: - Local model catalog

/// What "fully local" concretely means for this product, and the numbers that
/// decide whether it is honest to offer.
///
/// Everything the probe and the picker need to agree on lives here so the two
/// cannot drift: the picker gates on the same constants the probe measures
/// against, and the tests assert on these rather than on magic numbers.
public enum LocalBrainModelCatalog {

    /// The measured-good local brain for this product: 92% tool-routing accuracy
    /// over SAGE's MCP tool set, 3.4 GB on disk. Everything else in
    /// `toolCapableModels` is a plausible substitute, not an equal.
    public static let preferredModel = "qwen3.5:4b"

    /// SAGE's semantic-memory model. Keeping this beside the chat model is
    /// load-bearing: a local brain without it can answer, but memory silently
    /// falls back to lexical search and the appliance feels forgetful.
    public static let embeddingModel = "nomic-embed-text"
    public static let embeddingDimensions = 768

    /// Models known to emit usable `tool_calls` against SAGE's schemas, in the
    /// order we would rather have them.
    ///
    /// Ordering rationale, in the absence of measurements for the substitutes:
    /// the measured model first; then its own family (a 3.5 sibling shares the
    /// tool template that produced the 92%); then the older qwen3 generation;
    /// then the two non-qwen models, which are known to call tools but have not
    /// been measured here at all. This ordering is a preference, not a ranking of
    /// quality — do not read it as data.
    public static let toolCapableModels: [String] = [
        "qwen3.5:4b",
        "qwen3.5:8b",
        "qwen3:8b",
        "qwen3:4b",
        "llama3.1:8b",
        "mistral-nemo"
    ]

    /// Weights for `preferredModel`. Stated in the product brief; not measured
    /// by this code.
    public static let approximateModelDownloadBytes: Int64 = 3_400_000_000

    /// Ollama's current nomic embedding weights are roughly 274 MB.
    public static let approximateEmbeddingModelDownloadBytes: Int64 = 274_000_000

    /// Order-of-magnitude estimate for the Ollama macOS app itself, needed only
    /// when no runtime is present. Not measured here — it exists so an install
    /// screen can say "about 4.4 GB in total" instead of "about 3.4 GB" and then
    /// surprise the owner.
    /// Exact compressed byte count of the pinned v0.31.1 macOS archive.
    public static let approximateRuntimeDownloadBytes: Int64 = 129_037_451

    // MARK: Hardware thresholds

    /// 16 GiB — the line above which fully-local is *comfortable*.
    ///
    /// Why 16 and not 8: this appliance does not run the brain alone. Resident at
    /// the same time are the 4B model at Q4_K_M (~3.4 GB of weights plus a KV
    /// cache sized for a routing prompt that carries ~14 MCP tool schemas, so
    /// call it 5–6 GB for the Ollama process), a Whisper large-v3-turbo ASR model
    /// (~1.6 GB), a TTS process, and macOS itself on a box that is never
    /// rebooted. On the reference machine — a 16 GB M2 mini — that fits with
    /// headroom, which is the empirical basis for the number. It is a floor for
    /// *comfort*, not for possibility.
    public static let comfortableMemoryBytes: UInt64 = 16 * 1024 * 1024 * 1024

    /// 8 GiB — the line below which we stop offering fully-local at all.
    ///
    /// Between 8 and 16 GiB the model loads and answers, but it is competing with
    /// ASR for wired memory and the machine will swap during a voice turn. We
    /// call that `.tight` and still offer it, because the owner is allowed to
    /// choose privacy over latency. Below 8 GiB the honest answer is no.
    public static let minimumMemoryBytes: UInt64 = 8 * 1024 * 1024 * 1024

    /// 8 GiB free — required only when a download is actually needed.
    ///
    /// 3.4 GB of weights, up to ~1 GB more if the Ollama runtime must be
    /// installed too, and the rest is deliberate slack. Driving the boot volume
    /// of an always-on appliance to zero is a far worse outcome than declining
    /// the option: the owner may not be in the same building as the machine.
    public static let requiredFreeDiskBytes: Int64 = 8 * 1024 * 1024 * 1024

    // MARK: Model-name matching

    /// Ollama reports `qwen3.5:4b`, but a model pulled without an explicit tag
    /// comes back as `name:latest`. Normalise both to the same key so a probe
    /// does not report "not pulled" for a model that is sitting right there.
    public static func normalize(_ modelName: String) -> String {
        let lowered = modelName.lowercased()
        if lowered.hasSuffix(":latest") {
            return String(lowered.dropLast(":latest".count))
        }
        return lowered
    }

    /// Which of the installed models we consider tool-capable, in catalog order.
    public static func toolCapableModels(installed: [String]) -> [String] {
        let installedKeys = Set(installed.map(normalize))
        return toolCapableModels.filter { installedKeys.contains(normalize($0)) }
    }

    /// The best tool-capable model already on the machine, or `nil`.
    public static func preferredInstalledModel(installed: [String]) -> String? {
        toolCapableModels(installed: installed).first
    }
}

// MARK: - Local model runtime

/// What Ollama looks like on this machine.
public struct LocalModelRuntimeReport: Sendable, Equatable, Codable {

    /// The `ollama` binary was found on disk. A binary without a daemon means
    /// "installed but not running", which is a very different sentence to the
    /// owner than "not installed".
    public var isRuntimeInstalled: Bool

    /// Where the binary was found, for the UI to show and for logs.
    public var runtimeExecutablePath: String?

    /// The daemon answered `/api/version`.
    public var isDaemonReachable: Bool

    /// Base URL we probed, honouring `OLLAMA_HOST`.
    public var baseURL: String

    /// Every model name the daemon reports, verbatim.
    public var installedModels: [String]

    /// Why `installedModels` is empty, when the reason was not "no models".
    /// Kept because "the daemon is up but `/api/tags` failed" must not be
    /// presented to the owner as "you have no models".
    public var modelListingFailure: String?

    public init(
        isRuntimeInstalled: Bool = false,
        runtimeExecutablePath: String? = nil,
        isDaemonReachable: Bool = false,
        baseURL: String = OllamaClient.defaultBaseURL.absoluteString,
        installedModels: [String] = [],
        modelListingFailure: String? = nil
    ) {
        self.isRuntimeInstalled = isRuntimeInstalled
        self.runtimeExecutablePath = runtimeExecutablePath
        self.isDaemonReachable = isDaemonReachable
        self.baseURL = baseURL
        self.installedModels = installedModels
        self.modelListingFailure = modelListingFailure
    }

    /// Tool-capable models already pulled, best first.
    public var toolCapableModels: [String] {
        LocalBrainModelCatalog.toolCapableModels(installed: installedModels)
    }

    /// The model a fully-local setup would bind to right now, if any.
    public var preferredInstalledModel: String? {
        LocalBrainModelCatalog.preferredInstalledModel(installed: installedModels)
    }

    /// True only when a voice turn could be served *today*: daemon up and a
    /// tool-capable model already on disk. Reachability alone is not enough —
    /// a daemon without the model fails on the first real request, which on a
    /// voice turn means dead air.
    public var isReadyToServe: Bool {
        isDaemonReachable
            && preferredInstalledModel != nil
            && installedModels.contains {
                LocalBrainModelCatalog.normalize($0)
                    == LocalBrainModelCatalog.normalize(LocalBrainModelCatalog.embeddingModel)
            }
    }
}

// MARK: - Agent CLIs

public enum AgentCLIKind: String, Sendable, Codable, CaseIterable {
    case claudeCode
    case codex

    /// Executable names to look for on `PATH`, in order.
    public var executableNames: [String] {
        switch self {
        case .claudeCode: return ["claude"]
        case .codex:      return ["codex"]
        }
    }

    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex:      return "Codex"
        }
    }

    /// The vendor the owner's words would reach through this CLI.
    public var vendorName: String {
        switch self {
        case .claudeCode: return "Anthropic"
        case .codex:      return "OpenAI"
        }
    }
}

/// Whether an already-installed agent CLI can be pressed into service as the
/// brain, and on what basis we think so.
///
/// Authentication is inferred from the *presence* of a credential store, never
/// by running the binary. Running `claude` or `codex` to ask "are you logged
/// in?" risks two unacceptable outcomes on an install screen: an interactive
/// login prompt that blocks the probe, and a billable API call made before the
/// owner has agreed to anything.
public struct AgentCLIReport: Sendable, Equatable, Codable {
    public var kind: AgentCLIKind
    public var isInstalled: Bool
    public var executablePath: String?

    /// Whatever `--version` printed. `--version` is safe: no network, no login,
    /// and it is bounded by the runner's deadline like every other shell-out.
    public var version: String?

    /// Human-readable list of what we found, e.g. `keychain item "Codex"`, or a
    /// path. Never a credential value — these strings can end up in a log.
    public var credentialEvidence: [String]

    /// A credential store belonging to the CLI itself exists: the owner has
    /// signed in, and the flat-rate subscription they already pay for applies.
    public var hasSubscriptionCredential: Bool

    /// The CLI would run headless off an API key sitting in the environment.
    /// Works, but bills per token — a materially different offer, so it is kept
    /// distinct rather than folded into "authenticated".
    public var hasAmbientAPIKey: Bool

    public init(
        kind: AgentCLIKind,
        isInstalled: Bool = false,
        executablePath: String? = nil,
        version: String? = nil,
        credentialEvidence: [String] = [],
        hasSubscriptionCredential: Bool = false,
        hasAmbientAPIKey: Bool = false
    ) {
        self.kind = kind
        self.isInstalled = isInstalled
        self.executablePath = executablePath
        self.version = version
        self.credentialEvidence = credentialEvidence
        self.hasSubscriptionCredential = hasSubscriptionCredential
        self.hasAmbientAPIKey = hasAmbientAPIKey
    }

    /// Installed *and* something to authenticate with. Either basis counts —
    /// the difference shows up in the option's description, not in whether we
    /// offer it.
    public var isUsableWithoutFurtherInput: Bool {
        isInstalled && (hasSubscriptionCredential || hasAmbientAPIKey)
    }
}

// MARK: - Ambient API keys

public enum APIKeyProvider: String, Sendable, Codable, CaseIterable, Comparable {
    case anthropic
    case openAI
    case google
    case deepSeek
    case moonshot
    case groq
    case glm

    /// Environment variables that would let this provider be used without the
    /// owner typing anything.
    public var environmentVariableNames: [String] {
        switch self {
        case .anthropic: return ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"]
        case .openAI:    return ["OPENAI_API_KEY"]
        case .google:    return ["GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_GENERATIVE_AI_API_KEY"]
        case .deepSeek:  return ["DEEPSEEK_API_KEY"]
        case .moonshot:  return ["MOONSHOT_API_KEY", "KIMI_API_KEY"]
        case .groq:      return ["GROQ_API_KEY"]
        case .glm:       return ["GLM_API_KEY", "ZHIPU_API_KEY", "ZHIPUAI_API_KEY"]
        }
    }

    public var displayName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openAI:    return "OpenAI"
        case .google:    return "Google Gemini"
        case .deepSeek:  return "DeepSeek"
        case .moonshot:  return "Moonshot (Kimi)"
        case .groq:      return "Groq"
        case .glm:       return "GLM (Zhipu)"
        }
    }

    /// `BrainBackend.identifier` this provider would be served by.
    ///
    /// These are the *adapter's own* identifiers — `OpenAICompatBackend.identifier`
    /// returns `provider.identifier`, so Gemini reports `"gemini"` and Kimi
    /// reports `"moonshot"`. An earlier version answered `"google"` here and
    /// folded DeepSeek, Kimi and Groq into a single `"openai-compatible"`, and
    /// both were live bugs rather than cosmetic ones: `APIKeyOnboarding` keys its
    /// instructions on the adapter's vocabulary, so `"google"` matched nothing and
    /// the owner was offered a "Google Gemini API key" option whose key screen
    /// could never be reached, while three vendors sharing one string meant three
    /// keys collapsing into one slot on disk.
    public var backendIdentifier: String {
        switch self {
        case .anthropic: return "anthropic"
        case .openAI:    return "openai"
        case .google:    return "gemini"
        case .deepSeek:  return "deepseek"
        case .moonshot:  return "moonshot"
        case .glm:       return "glm"
        case .groq:      return "groq"
        }
    }

    public static func < (lhs: APIKeyProvider, rhs: APIKeyProvider) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Which providers already have a usable credential in the process environment.
///
/// **This type records names and never values.** A probe result is designed to
/// be pastable into a support bundle, and a key prefix is still a key fragment.
/// There is deliberately no field that could hold one, so a future edit cannot
/// leak one by accident.
public struct AmbientAPIKeyReport: Sendable, Equatable, Codable {
    /// Providers with at least one non-empty variable set, sorted for stability.
    public var providers: [APIKeyProvider]

    /// The variable *names* that were set. Names, not values.
    public var variableNames: [String]

    public init(providers: [APIKeyProvider] = [], variableNames: [String] = []) {
        self.providers = providers.sorted()
        self.variableNames = variableNames.sorted()
    }

    public func hasKey(for provider: APIKeyProvider) -> Bool {
        providers.contains(provider)
    }

    /// Pure: takes an environment dictionary rather than reading the process's,
    /// so the leak-proofing can be tested with a synthetic secret.
    public static func detect(in environment: [String: String]) -> AmbientAPIKeyReport {
        var providers: [APIKeyProvider] = []
        var names: [String] = []
        for provider in APIKeyProvider.allCases {
            var found = false
            for name in provider.environmentVariableNames {
                // An exported-but-empty variable is a very common leftover in a
                // shell profile and means the opposite of "configured".
                guard let value = environment[name],
                      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continue
                }
                found = true
                names.append(name)
            }
            if found {
                providers.append(provider)
            }
        }
        return AmbientAPIKeyReport(providers: providers, variableNames: names)
    }
}

// MARK: - Hardware

/// Which operating system a `HardwareReport` describes.
///
/// Recorded rather than inferred, because the judgement below reads the *same*
/// stored fact — `isAppleSilicon == false` — in two opposite ways, and nothing
/// else in the report tells them apart.
///
/// On a Mac that flag is a measurement: `hw.optional.arm64` said no, so this is
/// an Intel Mac, and an Intel Mac has no accelerator to fall back to. Off Darwin
/// it is not a measurement at all — `SystemHardwareProbe` hardcodes it to
/// `false` there, deliberately, because the question the flag asks is "is Metal
/// available" and Metal is a Darwin framework. Judging a Linux tower by that
/// constant is how a Threadripper with a 4090 was told it "needs Apple Silicon
/// — on an Intel chip a reply takes far too long", a sentence in which every
/// clause was false about the machine printing it.
public enum HostPlatform: String, Sendable, Codable, CaseIterable {
    case darwin
    case linux
    /// Nothing reports this any more — the Windows port was dropped. The case
    /// stays because this is a `Codable` with a string raw value, and a support
    /// bundle recorded while the port existed still says `"windows"`; removing
    /// it would turn reading that bundle back into a decode failure.
    case windows
    case unknown

    /// The platform of the process that is looking.
    ///
    /// Safe as the default for `HardwareReport.platform` precisely because a
    /// default argument is evaluated at the *call site*: `SystemHardwareProbe`
    /// writes down the machine it probed, not the machine that later reads the
    /// report out of a support bundle.
    public static var current: HostPlatform {
        #if canImport(Darwin)
        return .darwin
        #elseif os(Linux)
        return .linux
        #else
        return .unknown
        #endif
    }

    /// True where "no Metal" is the whole story about acceleration.
    ///
    /// Darwin only. macOS has had no CUDA for years and llama.cpp ships no ROCm
    /// for it, so a Mac that is not Apple Silicon genuinely has nothing else to
    /// run on. Every other platform has several candidates and this probe cannot
    /// yet see any of them — which is a reason to stop asking about Metal there,
    /// not a reason to answer no on its behalf.
    public var metalIsTheOnlyAccelerator: Bool { self == .darwin }
}

/// How well this machine could host a 4B local brain.
public enum LocalModelCapability: String, Sendable, Codable {
    /// Runs the 4B brain alongside ASR and TTS with headroom. A 16 GB M2 mini,
    /// the reference machine, lands here.
    case comfortable

    /// Runs, but competes with the ASR model for memory and will swap during a
    /// voice turn. Still offered — privacy is the product's first principle and
    /// a slow private brain is a legitimate choice.
    case tight

    /// Not honest to offer: below the 8 GiB floor on any platform, or — on a Mac
    /// and only on a Mac — not Apple Silicon, where a 4B model answers a routing
    /// turn far too slowly for speech (the budget is already ~10s on an M2) and
    /// there is no other accelerator on the machine to reach for.
    case unsupported

    public var isOfferable: Bool { self != .unsupported }

    /// Pure decision function, exposed so the thresholds can be tested without a
    /// machine that has the relevant amount of RAM — and, because `platform` is
    /// an argument rather than a `#if`, so the Mac verdicts can be checked from
    /// Linux and the Linux verdicts from a Mac. A rule that can only be tested
    /// on the machine it is wrong about is how this one stayed wrong.
    ///
    /// **Memory is the only refusal off Darwin, and the asymmetry is deliberate.**
    /// The floor is measured: `SystemHardwareProbe` reads `MemTotal` out of
    /// `/proc/meminfo`, 3.4 GB of weights beside a 1.6 GB ASR model is
    /// arithmetic, and a box under 8 GiB swaps through every reply. What the
    /// probe cannot see off Darwin is the accelerator — there is no `/proc/gpu`
    /// — so the choice is between refusing machines nobody measured and offering
    /// with the uncertainty stated. It offers, because the two errors are not
    /// symmetrical: an owner refused by a screen cannot argue with it and has no
    /// next action, while an owner offered a CPU-only local brain gets something
    /// slow that *says* it may be slow, and can switch in one click.
    /// `BrainSetupPlanner` prints that caveat off Darwin, and it is load-bearing
    /// rather than decoration — without it this function is over-promising.
    public static func forMachine(
        memoryBytes: UInt64,
        isAppleSilicon: Bool,
        platform: HostPlatform = .current
    ) -> LocalModelCapability {
        if platform.metalIsTheOnlyAccelerator, !isAppleSilicon { return .unsupported }
        if memoryBytes >= LocalBrainModelCatalog.comfortableMemoryBytes { return .comfortable }
        if memoryBytes >= LocalBrainModelCatalog.minimumMemoryBytes { return .tight }
        return .unsupported
    }
}

public struct HardwareReport: Sendable, Equatable, Codable {
    public var physicalMemoryBytes: UInt64

    /// Free space on the volume that would hold the models. `nil` when the
    /// volume could not be interrogated — treated as unknown, never as zero.
    public var freeDiskBytes: Int64?

    /// The directory the free-space figure refers to, so an error message can
    /// name the right volume.
    public var modelStorageDirectory: String

    public var cpuBrand: String?
    public var physicalCoreCount: Int

    /// Metal is available. Read from `hw.optional.arm64` on Darwin and hardcoded
    /// `false` everywhere else — which is why it must never be read without
    /// `platform` beside it. See `HostPlatform`.
    public var isAppleSilicon: Bool

    /// The platform this report describes.
    ///
    /// Defaulted to `.current` so `SystemHardwareProbe` records the machine it
    /// probed without having to say so, and so no caller can forget. Written
    /// down rather than recomputed at judgement time because a report is a
    /// support-bundle payload: it can be read on a different machine than the
    /// one it describes, and "which platform is this?" then has exactly one
    /// right answer, the one from the probe.
    public var platform: HostPlatform

    public init(
        physicalMemoryBytes: UInt64 = 0,
        freeDiskBytes: Int64? = nil,
        modelStorageDirectory: String = "",
        cpuBrand: String? = nil,
        physicalCoreCount: Int = 0,
        isAppleSilicon: Bool = false,
        platform: HostPlatform = .current
    ) {
        self.physicalMemoryBytes = physicalMemoryBytes
        self.freeDiskBytes = freeDiskBytes
        self.modelStorageDirectory = modelStorageDirectory
        self.cpuBrand = cpuBrand
        self.physicalCoreCount = physicalCoreCount
        self.isAppleSilicon = isAppleSilicon
        self.platform = platform
    }

    /// Hand-written so that `platform` — added after 2.3.0 shipped — is optional
    /// on the wire. A support bundle written by an older build has no such key,
    /// and synthesized `Decodable` would throw on it: a tool that reads those
    /// bundles would fail on exactly the archived reports someone is most likely
    /// to go looking for. Absent means "written before this fact was recorded",
    /// and the only platform a reader can honestly assume is its own.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        physicalMemoryBytes = try container.decode(UInt64.self, forKey: .physicalMemoryBytes)
        freeDiskBytes = try container.decodeIfPresent(Int64.self, forKey: .freeDiskBytes)
        modelStorageDirectory = try container.decode(String.self, forKey: .modelStorageDirectory)
        cpuBrand = try container.decodeIfPresent(String.self, forKey: .cpuBrand)
        physicalCoreCount = try container.decode(Int.self, forKey: .physicalCoreCount)
        isAppleSilicon = try container.decode(Bool.self, forKey: .isAppleSilicon)
        platform = try container.decodeIfPresent(HostPlatform.self, forKey: .platform) ?? .current
    }

    public var localModelCapability: LocalModelCapability {
        LocalModelCapability.forMachine(
            memoryBytes: physicalMemoryBytes,
            isAppleSilicon: isAppleSilicon,
            platform: platform
        )
    }

    /// The headline judgement the install screen needs.
    public var canComfortablyRunLocalFourBillionModel: Bool {
        localModelCapability == .comfortable
    }

    /// Whether a multi-GB pull would fit with the slack we insist on.
    /// Unknown free space is treated as "enough": refusing on the basis of a
    /// measurement we failed to take would hide a working option.
    public func hasRoomForDownload(ofBytes bytes: Int64) -> Bool {
        guard let freeDiskBytes else { return true }
        return freeDiskBytes >= max(bytes, LocalBrainModelCatalog.requiredFreeDiskBytes)
    }
}

// MARK: - SAGE install

/// Whether SAGE itself is already on this machine.
///
/// Not a brain option — it decides whether setup needs to stand a node up, or
/// can point the daemon at one that exists.
public struct SageInstallReport: Sendable, Equatable, Codable {
    public var executablePath: String?
    public var stateDirectory: String?
    public var hasStateDirectory: Bool
    /// A config file inside the state directory: the difference between "the
    /// directory exists" and "a node has actually run here".
    public var hasConfiguration: Bool

    public init(
        executablePath: String? = nil,
        stateDirectory: String? = nil,
        hasStateDirectory: Bool = false,
        hasConfiguration: Bool = false
    ) {
        self.executablePath = executablePath
        self.stateDirectory = stateDirectory
        self.hasStateDirectory = hasStateDirectory
        self.hasConfiguration = hasConfiguration
    }

    public var isInstalled: Bool { executablePath != nil }
}

// MARK: - Aggregate

/// Everything the install screen learned about this machine, in one value.
///
/// `Codable` on purpose: this is the payload of a support bundle. That is also
/// why no member of this tree can hold a credential — see `AmbientAPIKeyReport`.
public struct EnvironmentProbeResult: Sendable, Equatable, Codable {
    public var localRuntime: LocalModelRuntimeReport
    public var agentCLIs: [AgentCLIReport]
    public var ambientAPIKeys: AmbientAPIKeyReport
    public var hardware: HardwareReport
    public var sage: SageInstallReport

    public init(
        localRuntime: LocalModelRuntimeReport = LocalModelRuntimeReport(),
        agentCLIs: [AgentCLIReport] = [],
        ambientAPIKeys: AmbientAPIKeyReport = AmbientAPIKeyReport(),
        hardware: HardwareReport = HardwareReport(),
        sage: SageInstallReport = SageInstallReport()
    ) {
        self.localRuntime = localRuntime
        self.agentCLIs = agentCLIs
        self.ambientAPIKeys = ambientAPIKeys
        self.hardware = hardware
        self.sage = sage
    }

    public func cli(_ kind: AgentCLIKind) -> AgentCLIReport {
        agentCLIs.first { $0.kind == kind } ?? AgentCLIReport(kind: kind)
    }

    /// A machine on which nothing was found. The baseline for tests, and the
    /// shape a probe returns when every detection fails.
    public static var nothingDetected: EnvironmentProbeResult {
        EnvironmentProbeResult(
            agentCLIs: AgentCLIKind.allCases.map { AgentCLIReport(kind: $0) }
        )
    }
}
