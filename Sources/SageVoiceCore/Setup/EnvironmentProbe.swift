import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Injection points

/// The slice of `OllamaClient` the probe needs.
///
/// Exists so setup tests never open a socket. `OllamaClient` conforms as-is —
/// nothing here reimplements HTTP.
public protocol OllamaProbing: Sendable {
    func isReachable(timeoutSeconds: TimeInterval) async -> Bool
    func listModels() async throws -> [String]
}

extension OllamaClient: OllamaProbing {}

/// Machine capacity, injectable so the gating tests can describe an 8 GB Intel
/// Mac without owning one.
public protocol HardwareProbing: Sendable {
    func report(modelStorageDirectory: URL) -> HardwareReport
}

// MARK: - Probe

/// First-run environment probe.
///
/// Runs silently in the background at install time and again, unchanged, from
/// the settings panel when the owner wants to move to a fully-local brain. It is
/// therefore built to two rules:
///
///  - **No side effects.** It creates nothing, writes nothing, authenticates
///    nothing, and never launches a binary in a way that could prompt the owner
///    or spend their money. `--version` and a `security` attribute lookup are the
///    only executions, both non-interactive and both on a deadline.
///  - **No throwing.** A missing CLI is not an error, it is the answer. `run()`
///    returns a result no matter what fails, so the install screen always has
///    something to render.
///
/// The four detection groups are independent and run concurrently; total wall
/// clock is the slowest group, not the sum.
public struct EnvironmentProbe {
    private let environment: [String: String]
    private let fileManager: FileManager
    private let homeDirectory: URL
    private let commandRunner: ProbeCommandRunning
    private let ollama: OllamaProbing
    private let hardwareProbe: HardwareProbing
    private let systemBinaryDirectories: [URL]
    private let sageBundleExecutables: [URL]

    /// Reachability budget. The daemon is on loopback; if it has not answered
    /// `/api/version` in two seconds it is not going to serve a voice turn
    /// either.
    private static let daemonReachabilityTimeoutSeconds: TimeInterval = 2

    /// Kept short deliberately: `OllamaClient`'s own default is 180s, which is
    /// right for generation and absurd for an install screen.
    private static let daemonListTimeoutSeconds: TimeInterval = 5

    /// Machine-wide install locations searched after `PATH` and the
    /// home-relative ones. Homebrew on both architectures, plus the Ollama app
    /// bundle, which ships its CLI inside `Resources` and never lands on `PATH`
    /// for a GUI-launched daemon.
    public static let defaultSystemBinaryDirectories: [URL] = [
        URL(fileURLWithPath: "/opt/homebrew/bin"),
        URL(fileURLWithPath: "/usr/local/bin"),
        URL(fileURLWithPath: "/Applications/Ollama.app/Contents/Resources")
    ]

    /// Machine-wide app-bundle locations for the SAGE node.
    ///
    /// SAGE ships as a macOS app bundle and the binary inside one is
    /// deliberately not on `PATH`, so searching `PATH` alone reported "no SAGE
    /// installed" on a machine that was running it. The bundle is the *primary*
    /// location for this product, which vendors SAGE the same way QuietType
    /// vendors SAGE.app today.
    ///
    /// Injectable for the same reason `systemBinaryDirectories` is: a test has
    /// to be able to describe a machine without SAGE while running on a host
    /// that has it in /Applications.
    /// Ordered: the copy we vendored inside our own bundle comes first.
    ///
    /// That one is the normal case, not the fallback. A vendored SAGE.app is
    /// codesigned as part of this app's bundle and inherits its notarization,
    /// so it runs without Gatekeeper prompts and without the owner installing
    /// anything. QuietType has shipped this arrangement for a while and it is
    /// why its SAGE detection effectively never fails.
    public static let defaultSageBundleExecutables: [URL] = {
        var candidates: [URL] = []
        if let vendored = SageNodeLocator.vendoredExecutableURL() {
            candidates.append(vendored)
        }
        candidates.append(contentsOf: [
            URL(fileURLWithPath: "/Applications/SAGE.app/Contents/MacOS/sage-gui"),
            URL(fileURLWithPath: NSHomeDirectory() + "/Applications/SAGE.app/Contents/MacOS/sage-gui")
        ])
        return candidates
    }()

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        commandRunner: ProbeCommandRunning = ProbeCommandRunner(),
        ollama: OllamaProbing? = nil,
        hardwareProbe: HardwareProbing = SystemHardwareProbe(),
        // Injectable so a test can describe a machine with nothing installed
        // even when the host running it has Ollama and both CLIs in /usr/local.
        systemBinaryDirectories: [URL] = EnvironmentProbe.defaultSystemBinaryDirectories,
        sageBundleExecutables: [URL] = EnvironmentProbe.defaultSageBundleExecutables
    ) {
        self.environment = environment
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
        self.commandRunner = commandRunner
        self.hardwareProbe = hardwareProbe
        self.systemBinaryDirectories = systemBinaryDirectories
        self.sageBundleExecutables = sageBundleExecutables
        self.ollama = ollama ?? OllamaClient(
            baseURL: Self.ollamaBaseURL(environment: environment),
            timeoutSeconds: Self.daemonListTimeoutSeconds
        )
    }

    /// `PATH`, then the home-relative install locations, then the machine-wide
    /// ones. One helper so every binary this probe hunts for is looked up the
    /// same way.
    private func locate(
        _ names: [String],
        homeRelativePaths: [String],
        absolutePaths: [String] = []
    ) -> URL? {
        var candidates = homeRelativePaths.map(homeDirectory.appendingPathComponent)
        candidates.append(contentsOf: absolutePaths.map { URL(fileURLWithPath: $0) })
        for directory in systemBinaryDirectories {
            candidates.append(contentsOf: names.map(directory.appendingPathComponent))
        }
        return ExecutableLookup.find(
            names: names,
            extraCandidates: candidates,
            environment: environment,
            fileManager: fileManager
        )
    }

    /// Probe everything. Never throws, never blocks indefinitely.
    public func run() async -> EnvironmentProbeResult {
        async let localRuntime = probeLocalRuntime()
        async let agentCLIs = probeAgentCLIs()
        async let hardware = probeHardware()
        async let sage = probeSage()

        return await EnvironmentProbeResult(
            localRuntime: localRuntime,
            agentCLIs: agentCLIs,
            ambientAPIKeys: AmbientAPIKeyReport.detect(in: environment),
            hardware: hardware,
            sage: sage
        )
    }

    // MARK: Local model runtime

    /// `OLLAMA_HOST` accepts bare `host:port` as well as a URL; both are common
    /// in the wild. Anything unparseable falls back to the documented default
    /// rather than failing the whole probe.
    static func ollamaBaseURL(environment: [String: String]) -> URL {
        guard let raw = environment["OLLAMA_HOST"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return OllamaClient.defaultBaseURL
        }
        if let url = URL(string: raw), url.scheme != nil, url.host != nil {
            return url
        }
        if let url = URL(string: "http://\(raw)"), url.host != nil {
            return url
        }
        return OllamaClient.defaultBaseURL
    }

    private func probeLocalRuntime() async -> LocalModelRuntimeReport {
        let managedRoot = "Library/Application Support/SAGE Voice Bridge/Runtime/"
            + "ollama-\(OllamaRuntimeInstaller.release)"
        let executable = locate(
            ["ollama"],
            homeRelativePaths: [
                ".local/bin/ollama",
                "\(managedRoot)/ollama",
                "\(managedRoot)/bin/ollama",
                "\(managedRoot)/ollama/ollama"
            ]
        )

        let baseURL = Self.ollamaBaseURL(environment: environment)
        var report = LocalModelRuntimeReport(
            isRuntimeInstalled: executable != nil,
            runtimeExecutablePath: executable?.path,
            baseURL: baseURL.absoluteString
        )

        guard await ollama.isReachable(timeoutSeconds: Self.daemonReachabilityTimeoutSeconds) else {
            return report
        }
        report.isDaemonReachable = true

        do {
            report.installedModels = try await ollama.listModels()
        } catch {
            // A reachable daemon whose /api/tags failed must not be reported as
            // "you have no models" — that would push the owner into a 3.4 GB
            // download they may not need.
            report.modelListingFailure = String(describing: error)
        }
        return report
    }

    // MARK: Agent CLIs

    private func probeAgentCLIs() async -> [AgentCLIReport] {
        await withTaskGroup(of: AgentCLIReport.self) { group in
            for kind in AgentCLIKind.allCases {
                group.addTask { await probeAgentCLI(kind) }
            }
            var reports: [AgentCLIReport] = []
            for await report in group {
                reports.append(report)
            }
            // Task-group completion order is nondeterministic; the result must
            // not be, or two runs of a side-effect-free probe would differ.
            return reports.sorted { lhs, rhs in
                guard let l = AgentCLIKind.allCases.firstIndex(of: lhs.kind),
                      let r = AgentCLIKind.allCases.firstIndex(of: rhs.kind) else {
                    return lhs.kind.rawValue < rhs.kind.rawValue
                }
                return l < r
            }
        }
    }

    private func probeAgentCLI(_ kind: AgentCLIKind) async -> AgentCLIReport {
        var report = AgentCLIReport(kind: kind)

        guard let executable = locate(
            kind.executableNames,
            homeRelativePaths: homeRelativeInstallPaths(for: kind)
        ) else {
            // Not installed. Credential state is irrelevant and asking for it
            // would only produce a confusing "signed in but missing" report.
            return report
        }

        report.isInstalled = true
        report.executablePath = executable.path
        report.version = await version(of: executable)

        let credentials = await credentialEvidence(for: kind)
        report.credentialEvidence = credentials.evidence
        report.hasSubscriptionCredential = credentials.hasStore
        report.hasAmbientAPIKey = ambientKeyExists(for: kind)
        return report
    }

    /// Where each CLI's installer actually puts it, beyond `PATH`. A GUI-launched
    /// daemon inherits a minimal `PATH`, so these matter more here than they
    /// would in a shell.
    private func homeRelativeInstallPaths(for kind: AgentCLIKind) -> [String] {
        switch kind {
        case .claudeCode:
            return [
                ".local/bin/claude",
                ".claude/local/claude",
                ".bun/bin/claude",
                ".npm-global/bin/claude"
            ]
        case .codex:
            return [
                ".local/bin/codex",
                ".codex/bin/codex",
                ".cargo/bin/codex",
                ".bun/bin/codex",
                ".npm-global/bin/codex"
            ]
        }
    }

    /// `--version` only. It makes no network call and cannot start a login flow,
    /// and the runner gives it `/dev/null` on stdin plus a deadline, so even a
    /// CLI that ignores the flag and drops into a prompt is capped.
    private func version(of executable: URL) async -> String? {
        guard let result = await commandRunner.run(
            executable: executable,
            arguments: ["--version"],
            timeout: 4
        ), result.succeeded else {
            return nil
        }
        return result.firstOutputLine
    }

    // MARK: Credential stores

    private struct CredentialEvidence {
        var evidence: [String]
        var hasStore: Bool
    }

    /// Presence-only. We never read a credential file's contents and never run
    /// the CLI to ask; both would be a way to leak or to spend.
    private func credentialEvidence(for kind: AgentCLIKind) async -> CredentialEvidence {
        var evidence: [String] = []

        for path in credentialFileCandidates(for: kind)
        where fileManager.fileExists(atPath: path.path) {
            evidence.append(path.path)
        }

        let keychain = KeychainPresenceProbe(commandRunner: commandRunner, fileManager: fileManager)
        for service in keychainServices(for: kind) where await keychain.itemExists(service: service) {
            evidence.append("keychain item \"\(service)\"")
        }

        return CredentialEvidence(evidence: evidence, hasStore: !evidence.isEmpty)
    }

    private func credentialFileCandidates(for kind: AgentCLIKind) -> [URL] {
        switch kind {
        case .claudeCode:
            var candidates = [
                homeDirectory.appendingPathComponent(".claude/.credentials.json"),
                homeDirectory.appendingPathComponent(".config/claude/.credentials.json")
            ]
            if let configDirectory = nonEmptyEnvironmentValue("CLAUDE_CONFIG_DIR") {
                candidates.insert(
                    URL(fileURLWithPath: configDirectory).appendingPathComponent(".credentials.json"),
                    at: 0
                )
            }
            return candidates
        case .codex:
            var candidates = [homeDirectory.appendingPathComponent(".codex/auth.json")]
            if let codexHome = nonEmptyEnvironmentValue("CODEX_HOME") {
                candidates.insert(
                    URL(fileURLWithPath: codexHome).appendingPathComponent("auth.json"),
                    at: 0
                )
            }
            return candidates
        }
    }

    /// Generic-password service names each CLI is known to use on macOS.
    private func keychainServices(for kind: AgentCLIKind) -> [String] {
        switch kind {
        case .claudeCode: return ["Claude Code-credentials"]
        // Codex stores its tokens in ~/.codex/auth.json; there is no documented
        // keychain service to look for, and guessing one would produce false
        // negatives that read as facts.
        case .codex: return []
        }
    }

    private func ambientKeyExists(for kind: AgentCLIKind) -> Bool {
        let report = AmbientAPIKeyReport.detect(in: environment)
        switch kind {
        case .claudeCode: return report.hasKey(for: .anthropic)
        case .codex:      return report.hasKey(for: .openAI)
        }
    }

    // MARK: Hardware

    private func probeHardware() async -> HardwareReport {
        hardwareProbe.report(modelStorageDirectory: modelStorageDirectory)
    }

    /// Where a `ollama pull` would land, honouring `OLLAMA_MODELS`. This is the
    /// volume whose free space actually matters — on a Mac with an external
    /// models drive, the boot volume's figure would be the wrong answer.
    private var modelStorageDirectory: URL {
        if let override = nonEmptyEnvironmentValue("OLLAMA_MODELS") {
            return URL(fileURLWithPath: override)
        }
        return homeDirectory.appendingPathComponent(
            "Library/Application Support/SAGE Voice Bridge/Ollama/Models",
            isDirectory: true
        )
    }

    // MARK: SAGE

    private func probeSage() async -> SageInstallReport {
        let executable = locate(
            ["sage", "sage-gui", "sagectl", "saged"],
            homeRelativePaths: [
                ".sage/bin/sage",
                ".sage/bin/sage-gui",
                "go/bin/sage",
                ".local/bin/sage",
                "Applications/SAGE.app/Contents/MacOS/sage-gui"
            ],
            absolutePaths: sageBundleExecutables.map(\.path)
        )

        let stateDirectory: URL
        if let override = nonEmptyEnvironmentValue("SAGE_HOME") {
            stateDirectory = URL(fileURLWithPath: override)
        } else {
            stateDirectory = homeDirectory.appendingPathComponent(".sage")
        }

        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: stateDirectory.path, isDirectory: &isDirectory)
            && isDirectory.boolValue

        let hasConfiguration = exists && ["config.yaml", "config.yml", "config.json"].contains {
            fileManager.fileExists(atPath: stateDirectory.appendingPathComponent($0).path)
        }

        return SageInstallReport(
            executablePath: executable?.path,
            stateDirectory: stateDirectory.path,
            hasStateDirectory: exists,
            hasConfiguration: hasConfiguration
        )
    }

    // MARK: Helpers

    private func nonEmptyEnvironmentValue(_ name: String) -> String? {
        guard let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}

// MARK: - Keychain presence

/// Presence check for a macOS generic-password item, via `/usr/bin/security`.
///
/// `security find-generic-password -s <service>` **without `-w`** prints
/// attributes only — never the secret. That is the whole point: we want to know
/// the item exists, and asking for the value would both prompt for keychain
/// access and put a credential in our address space.
///
/// Shelling out rather than linking Security.framework keeps this target on
/// Foundation, as the rest of the package is. A locked login keychain can make
/// `security` raise a GUI prompt; the runner's deadline kills it, and the answer
/// becomes a correct "no evidence" rather than a hung install screen.
struct KeychainPresenceProbe {
    let commandRunner: ProbeCommandRunning
    let fileManager: FileManager

    /// Short: this is a local keychain lookup, not a network call. If it has not
    /// answered in three seconds it is blocked on an unlock prompt.
    static let timeoutSeconds: TimeInterval = 3

    private static let securityBinary = URL(fileURLWithPath: "/usr/bin/security")

    func itemExists(service: String) async -> Bool {
        guard fileManager.isExecutableFile(atPath: Self.securityBinary.path) else {
            return false
        }
        let result = await commandRunner.run(
            executable: Self.securityBinary,
            arguments: ["find-generic-password", "-s", service],
            timeout: Self.timeoutSeconds
        )
        // Exit 44 is "item not found". Any non-zero, and any timeout, means we
        // have no evidence — which is the honest answer, not "not signed in".
        return result?.succeeded ?? false
    }
}

// MARK: - Hardware probe

/// Reads capacity out of `sysctl` and the filesystem.
///
/// `sysctl` rather than `uname` or `#if arch(arm64)`: both of those describe the
/// *process*, and a translated x86_64 process on an M-series Mac reports
/// `x86_64` while `hw.optional.arm64` still reports the truth. Verified on the
/// development machine, where `uname -m` says `x86_64` and
/// `sysctl hw.optional.arm64` says `1`.
public struct SystemHardwareProbe: HardwareProbing {
    public init() {}

    public func report(modelStorageDirectory: URL) -> HardwareReport {
        let cpuBrand = Self.sysctlString("machdep.cpu.brand_string")
        let arm64Flag = Self.sysctlInteger("hw.optional.arm64") ?? 0
        let isAppleSilicon = arm64Flag == 1 || (cpuBrand?.hasPrefix("Apple") ?? false)

        return HardwareReport(
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            freeDiskBytes: Self.freeBytes(near: modelStorageDirectory),
            modelStorageDirectory: modelStorageDirectory.path,
            cpuBrand: cpuBrand,
            physicalCoreCount: Int(Self.sysctlInteger("hw.physicalcpu")
                ?? Int64(ProcessInfo.processInfo.processorCount)),
            isAppleSilicon: isAppleSilicon
        )
    }

    /// Free space on the volume that *would* hold the models. The directory
    /// usually does not exist yet on a fresh machine, so walk up to the nearest
    /// ancestor that does — the volume is the same either way.
    static func freeBytes(near directory: URL, fileManager: FileManager = .default) -> Int64? {
        var candidate = directory.standardizedFileURL
        for _ in 0..<16 {
            if fileManager.fileExists(atPath: candidate.path) {
                let values = try? candidate.resourceValues(
                    forKeys: [.volumeAvailableCapacityForImportantUsageKey]
                )
                if let available = values?.volumeAvailableCapacityForImportantUsage {
                    return available
                }
                return nil
            }
            let parent = candidate.deletingLastPathComponent().standardizedFileURL
            if parent.path == candidate.path { break }
            candidate = parent
        }
        return nil
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }
        let value = String(decoding: bytes, as: UTF8.self)
        return value.isEmpty ? nil : value
    }

    /// Reads an integer sysctl of unknown width. `hw.optional.arm64` is 4 bytes
    /// and `hw.memsize` is 8; assuming either one wrong gives silently bogus
    /// answers, so ask for the width first. Little-endian is assumed, which is
    /// true of every Mac this can run on.
    static func sysctlInteger(_ name: String) -> Int64? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0, size <= 8 else { return nil }
        var raw = [UInt8](repeating: 0, count: 8)
        var length = size
        guard sysctlbyname(name, &raw, &length, nil, 0) == 0 else { return nil }
        var value: Int64 = 0
        for index in 0..<min(length, 8) {
            value |= Int64(raw[index]) << (8 * index)
        }
        return value
    }
}
