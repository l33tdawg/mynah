import XCTest
@testable import SageVoiceCore

/// Tests for what the probe *decides*, and for the two properties it must never
/// lose: it never leaks a credential, and it never hangs.
///
/// The probe is driven entirely through injected fakes and a temporary home
/// directory, so nothing here depends on what happens to be installed on the
/// machine running the suite.
final class EnvironmentProbeTests: XCTestCase {

    // MARK: - Model matching

    /// The measured-good model wins even when bigger, newer-looking ones are
    /// present — 92% tool-routing accuracy is data, "8b > 4b" is a guess.
    func testPreferredInstalledModelPrefersTheMeasuredGoodModel() {
        let installed = ["llama3.1:8b", "qwen3:8b", "qwen3.5:4b", "gemma4:26b"]

        XCTAssertEqual(
            LocalBrainModelCatalog.preferredInstalledModel(installed: installed),
            "qwen3.5:4b"
        )
    }

    func testPreferredInstalledModelFallsBackThroughTheCatalogOrder() {
        XCTAssertEqual(
            LocalBrainModelCatalog.preferredInstalledModel(installed: ["mistral-nemo", "qwen3:8b"]),
            "qwen3:8b"
        )
        XCTAssertNil(
            LocalBrainModelCatalog.preferredInstalledModel(installed: ["gemma4:26b", "embeddinggemma:300m"]),
            "A model with no measured tool support must not be silently adopted as the brain"
        )
    }

    /// A model pulled without an explicit tag comes back as `name:latest`.
    /// Reporting that as "not pulled" would push the owner into a needless
    /// 3.4 GB download.
    func testModelMatchingToleratesTheLatestTag() {
        XCTAssertEqual(
            LocalBrainModelCatalog.preferredInstalledModel(installed: ["QWEN3.5:4B:latest"]),
            "qwen3.5:4b"
        )
        XCTAssertEqual(
            LocalBrainModelCatalog.toolCapableModels(installed: ["mistral-nemo:latest"]),
            ["mistral-nemo"]
        )
    }

    /// Reachable is not ready. A daemon with no tool-capable model fails on the
    /// first real request, which during a voice turn is dead air.
    func testDaemonWithoutAToolCapableModelIsNotReadyToServe() {
        let runtime = LocalModelRuntimeReport(
            isRuntimeInstalled: true,
            isDaemonReachable: true,
            installedModels: ["gemma4:26b"]
        )
        XCTAssertFalse(runtime.isReadyToServe)

        let unreachable = LocalModelRuntimeReport(isDaemonReachable: false, installedModels: ["qwen3.5:4b"])
        XCTAssertFalse(unreachable.isReadyToServe)
    }

    // MARK: - Credentials never leak

    /// A probe result is designed to be pasted into a support bundle. If any key
    /// value — or a prefix of one — could reach the encoded form, this test
    /// fails.
    func testProbeResultNeverCarriesAKeyValueNotEvenAPrefix() throws {
        let secret = "sk-ant-SUPERSECRETVALUE-do-not-log-0123456789"
        let report = AmbientAPIKeyReport.detect(in: [
            "ANTHROPIC_API_KEY": secret,
            "OPENAI_API_KEY": "sk-openai-\(secret)"
        ])

        XCTAssertEqual(report.providers, [.anthropic, .openAI])
        XCTAssertEqual(report.variableNames, ["ANTHROPIC_API_KEY", "OPENAI_API_KEY"])

        let encoded = try JSONEncoder().encode(EnvironmentProbeResult(ambientAPIKeys: report))
        let json = String(decoding: encoded, as: UTF8.self)

        XCTAssertFalse(json.contains(secret), "The whole key reached the encoded probe result")
        XCTAssertFalse(json.contains("SUPERSECRET"), "A fragment of the key reached the encoded result")
        XCTAssertFalse(json.contains("sk-ant"), "Even a key prefix must not survive encoding")
        XCTAssertTrue(json.contains("ANTHROPIC_API_KEY"), "Variable names are not secret and are useful")
    }

    /// An exported-but-empty variable is a stale shell-profile leftover and
    /// means the opposite of "configured".
    func testEmptyOrWhitespaceVariablesAreNotTreatedAsConfigured() {
        let report = AmbientAPIKeyReport.detect(in: [
            "ANTHROPIC_API_KEY": "",
            "OPENAI_API_KEY": "   \n",
            "GROQ_API_KEY": "gsk-real"
        ])

        XCTAssertEqual(report.providers, [.groq])
        XCTAssertFalse(report.hasKey(for: .anthropic))
        XCTAssertFalse(report.hasKey(for: .openAI))
    }

    func testAnyOneOfAProvidersVariablesIsEnough() {
        XCTAssertTrue(
            AmbientAPIKeyReport.detect(in: ["ANTHROPIC_AUTH_TOKEN": "tok"]).hasKey(for: .anthropic)
        )
        XCTAssertTrue(
            AmbientAPIKeyReport.detect(in: ["GOOGLE_GENERATIVE_AI_API_KEY": "k"]).hasKey(for: .google)
        )
    }

    // MARK: - OLLAMA_HOST

    func testOllamaBaseURLHonoursTheEnvironmentAndFallsBackSafely() {
        XCTAssertEqual(
            EnvironmentProbe.ollamaBaseURL(environment: [:]),
            OllamaClient.defaultBaseURL
        )
        XCTAssertEqual(
            EnvironmentProbe.ollamaBaseURL(environment: ["OLLAMA_HOST": "http://10.0.0.4:11434"]).absoluteString,
            "http://10.0.0.4:11434"
        )
        // Bare host:port is what the Ollama docs actually tell people to set.
        XCTAssertEqual(
            EnvironmentProbe.ollamaBaseURL(environment: ["OLLAMA_HOST": "10.0.0.4:11434"]).absoluteString,
            "http://10.0.0.4:11434"
        )
        // Unparseable input must not fail the whole probe.
        XCTAssertEqual(
            EnvironmentProbe.ollamaBaseURL(environment: ["OLLAMA_HOST": "   "]),
            OllamaClient.defaultBaseURL
        )
    }

    // MARK: - Detection failures are ordinary

    /// Nothing installed anywhere. Every group must report absence rather than
    /// throwing or hanging, and the result must still be plannable.
    func testAnEmptyMachineReportsAbsenceRatherThanFailing() async throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let probe = EnvironmentProbe(
            environment: ["PATH": "/nonexistent/probe/bin"],
            homeDirectory: home,
            commandRunner: StubCommandRunner(),
            ollama: StubOllama(isReachable: false),
            hardwareProbe: StubHardware(fixed: .appleSilicon16GB),
            systemBinaryDirectories: [],
            sageBundleExecutables: []
        )
        let result = await probe.run()

        XCTAssertFalse(result.localRuntime.isRuntimeInstalled)
        XCTAssertFalse(result.localRuntime.isDaemonReachable)
        XCTAssertFalse(result.localRuntime.isReadyToServe)
        XCTAssertNil(result.localRuntime.modelListingFailure, "Unreachable is not a listing failure")

        XCTAssertEqual(result.agentCLIs.count, AgentCLIKind.allCases.count)
        for cli in result.agentCLIs {
            XCTAssertFalse(cli.isInstalled)
            XCTAssertFalse(cli.isUsableWithoutFurtherInput)
            XCTAssertTrue(cli.credentialEvidence.isEmpty)
        }

        XCTAssertFalse(result.sage.isInstalled)
        XCTAssertFalse(result.sage.hasStateDirectory)

        XCTAssertNotNil(BrainSetupPlanner().plan(for: result).recommendation)
    }

    /// The CLI is on disk with its credential file beside it. Authentication is
    /// inferred from that file's *presence* — the binary is never run to ask.
    func testInstalledCLIWithACredentialFileReadsAsSignedIn() async throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try installFakeExecutable(at: home.appendingPathComponent(".local/bin/claude"))
        try write(to: home.appendingPathComponent(".claude/.credentials.json"), contents: "{}")

        let runner = StubCommandRunner(resultsByExecutableName: [
            "claude": ProbeCommandResult(exitCode: 0, standardOutput: "1.2.3 (Claude Code)\n", standardError: "")
        ])
        let probe = EnvironmentProbe(
            environment: ["PATH": "/nonexistent/probe/bin"],
            homeDirectory: home,
            commandRunner: runner,
            ollama: StubOllama(isReachable: false),
            hardwareProbe: StubHardware(fixed: .appleSilicon16GB),
            systemBinaryDirectories: [],
            sageBundleExecutables: []
        )
        let result = await probe.run()
        let claude = result.cli(.claudeCode)

        XCTAssertTrue(claude.isInstalled)
        XCTAssertTrue(claude.hasSubscriptionCredential)
        XCTAssertFalse(claude.hasAmbientAPIKey)
        XCTAssertTrue(claude.isUsableWithoutFurtherInput)
        XCTAssertEqual(claude.version, "1.2.3 (Claude Code)")

        // The only commands run were `--version` and the attribute-only keychain
        // lookup. Nothing that could log in or spend.
        XCTAssertTrue(
            runner.invocations.allSatisfy { $0.arguments == ["--version"] || $0.arguments.first == "find-generic-password" },
            "The probe ran something that could prompt or bill: \(runner.invocations)"
        )
        XCTAssertFalse(
            runner.invocations.contains { $0.arguments.contains("-w") },
            "A keychain lookup must never ask for the secret value"
        )
    }

    /// An installed CLI with no credential store but a key in the environment is
    /// usable — and the two bases are kept apart, because one is flat-rate and
    /// the other bills per token.
    func testAmbientKeyIsRecordedSeparatelyFromASubscriptionCredential() async throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try installFakeExecutable(at: home.appendingPathComponent(".codex/bin/codex"))

        let probe = EnvironmentProbe(
            environment: ["PATH": "/nonexistent/probe/bin", "OPENAI_API_KEY": "sk-test"],
            homeDirectory: home,
            commandRunner: StubCommandRunner(),
            ollama: StubOllama(isReachable: false),
            hardwareProbe: StubHardware(fixed: .appleSilicon16GB),
            systemBinaryDirectories: [],
            sageBundleExecutables: []
        )
        let codex = await probe.run().cli(.codex)

        XCTAssertTrue(codex.isInstalled)
        XCTAssertFalse(codex.hasSubscriptionCredential)
        XCTAssertTrue(codex.hasAmbientAPIKey)
        XCTAssertTrue(codex.isUsableWithoutFurtherInput)
    }

    /// A daemon that is up but whose `/api/tags` failed must not be reported as
    /// "you have no models" — that would push a needless download.
    func testAFailedModelListingIsRecordedNotSwallowed() async throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let probe = EnvironmentProbe(
            environment: ["PATH": "/nonexistent/probe/bin"],
            homeDirectory: home,
            commandRunner: StubCommandRunner(),
            ollama: StubOllama(isReachable: true, listFailure: "connection reset"),
            hardwareProbe: StubHardware(fixed: .appleSilicon16GB),
            systemBinaryDirectories: [],
            sageBundleExecutables: []
        )
        let runtime = await probe.run().localRuntime

        XCTAssertTrue(runtime.isDaemonReachable)
        XCTAssertTrue(runtime.installedModels.isEmpty)
        XCTAssertNotNil(runtime.modelListingFailure)
        XCTAssertFalse(runtime.isReadyToServe)
    }

    func testSageStateDirectoryIsDetectedAndHonoursSageHome() async throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let stateDirectory = home.appendingPathComponent("custom-sage")
        try write(to: stateDirectory.appendingPathComponent("config.yaml"), contents: "node: {}\n")

        let probe = EnvironmentProbe(
            environment: ["PATH": "/nonexistent/probe/bin", "SAGE_HOME": stateDirectory.path],
            homeDirectory: home,
            commandRunner: StubCommandRunner(),
            ollama: StubOllama(isReachable: false),
            hardwareProbe: StubHardware(fixed: .appleSilicon16GB),
            systemBinaryDirectories: [],
            sageBundleExecutables: []
        )
        let sage = await probe.run().sage

        XCTAssertEqual(sage.stateDirectory, stateDirectory.path)
        XCTAssertTrue(sage.hasStateDirectory)
        XCTAssertTrue(sage.hasConfiguration)
        XCTAssertFalse(sage.isInstalled, "No binary was placed on PATH")
    }

    /// SAGE ships as a macOS app bundle, and the binary inside one is
    /// deliberately not on PATH. Searching PATH alone reported "no SAGE
    /// installed" on a machine that was running it — and the bundle is the
    /// primary location for this product, which vendors SAGE the same way
    /// QuietType vendors SAGE.app today.
    func testSageIsFoundInsideAnAppBundleNotOnPATH() async throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let binary = home
            .appendingPathComponent("Applications/SAGE.app/Contents/MacOS/sage-gui")
        try write(to: binary, contents: "#!/bin/sh\nexit 0\n")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: binary.path
        )

        let probe = EnvironmentProbe(
            environment: ["PATH": "/nonexistent/probe/bin"],
            homeDirectory: home,
            commandRunner: StubCommandRunner(),
            ollama: StubOllama(isReachable: false),
            hardwareProbe: StubHardware(fixed: .appleSilicon16GB),
            systemBinaryDirectories: [],
            sageBundleExecutables: []
        )
        let sage = await probe.run().sage

        XCTAssertTrue(sage.isInstalled, "the bundled binary was not found")
        XCTAssertEqual(sage.executablePath, binary.path)
    }

    /// Task-group completion order is nondeterministic; the probe's output must
    /// not be, or a side-effect-free probe would disagree with itself.
    func testProbeOutputIsStableAcrossRuns() async throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let probe = EnvironmentProbe(
            environment: ["PATH": "/nonexistent/probe/bin"],
            homeDirectory: home,
            commandRunner: StubCommandRunner(),
            ollama: StubOllama(isReachable: true, models: ["qwen3.5:4b"]),
            hardwareProbe: StubHardware(fixed: .appleSilicon16GB),
            systemBinaryDirectories: [],
            sageBundleExecutables: []
        )
        let first = await probe.run()
        let second = await probe.run()

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.agentCLIs.map(\.kind), AgentCLIKind.allCases)
    }

    // MARK: - The runner cannot hang

    func testRunnerReturnsNilRatherThanThrowingForAMissingBinary() async {
        let result = await ProbeCommandRunner().run(
            executable: URL(fileURLWithPath: "/nonexistent/definitely/not/here"),
            arguments: ["--version"],
            timeout: 2
        )
        XCTAssertNil(result, "A missing binary is an answer, not an error")
    }

    /// The headline guarantee: a wedged CLI cannot stall an install screen.
    func testRunnerKillsAProcessThatOutlivesItsDeadline() async {
        let started = Date()
        let result = await ProbeCommandRunner().run(
            executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            timeout: 1
        )
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(result?.timedOut, true)
        XCTAssertLessThan(elapsed, 8, "A 1s deadline took \(elapsed)s — the escalation did not work")
    }

    /// `/bin/cat` with no arguments reads stdin forever on a terminal. It
    /// returns promptly here only because the runner hands every child
    /// `/dev/null`, which is the defence against a CLI that decides to ask the
    /// owner a question mid-probe.
    func testRunnerGivesChildrenNullStdinSoTheyCannotBlockOnInput() async {
        let started = Date()
        let result = await ProbeCommandRunner().run(
            executable: URL(fileURLWithPath: "/bin/cat"),
            arguments: [],
            timeout: 5
        )
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(result?.timedOut, false, "cat blocked on stdin instead of getting EOF")
        XCTAssertEqual(result?.exitCode, 0)
        XCTAssertLessThan(elapsed, 5)
    }

    func testRunnerCapturesOutputAndReportsFailure() async throws {
        let echoed = await ProbeCommandRunner().run(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["  hello  "],
            timeout: 5
        )
        let ok = try XCTUnwrap(echoed)
        XCTAssertTrue(ok.succeeded)
        XCTAssertEqual(ok.firstOutputLine, "hello")

        let ran = await ProbeCommandRunner().run(
            executable: URL(fileURLWithPath: "/usr/bin/false"),
            arguments: [],
            timeout: 5
        )
        let failed = try XCTUnwrap(ran)
        XCTAssertFalse(failed.succeeded)
        XCTAssertFalse(failed.timedOut)
    }

    // MARK: - PATH lookup

    func testExecutableLookupPrefersPathOverWellKnownLocations() throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let onPath = home.appendingPathComponent("bin/tool")
        let wellKnown = home.appendingPathComponent(".local/bin/tool")
        try installFakeExecutable(at: onPath)
        try installFakeExecutable(at: wellKnown)

        let found = ExecutableLookup.find(
            names: ["tool"],
            extraCandidates: [wellKnown],
            environment: ["PATH": home.appendingPathComponent("bin").path]
        )
        XCTAssertEqual(found?.path, onPath.path, "The copy the owner can type must win")
    }

    func testExecutableLookupIgnoresNonExecutableFiles() throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let notExecutable = home.appendingPathComponent("bin/tool")
        try write(to: notExecutable, contents: "not a binary")

        XCTAssertNil(ExecutableLookup.find(
            names: ["tool"],
            extraCandidates: [notExecutable],
            environment: ["PATH": home.appendingPathComponent("bin").path]
        ))
    }

    // MARK: - Fixtures

    private func makeTemporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sage-voice-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(to url: URL, contents: String) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// A file the lookup will accept as an executable. It is never actually run:
    /// `StubCommandRunner` intercepts every launch.
    private func installFakeExecutable(at url: URL) throws {
        try write(to: url, contents: "#!/bin/sh\nexit 0\n")
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: url.path
        )
    }
}

// MARK: - Stubs

private struct StubOllama: OllamaProbing {
    var isReachable: Bool
    var models: [String] = []
    /// Message to throw from `listModels()`, if any.
    var listFailure: String?

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    func isReachable(timeoutSeconds: TimeInterval) async -> Bool { isReachable }

    func listModels() async throws -> [String] {
        if let listFailure { throw Failure(description: listFailure) }
        return models
    }
}

private struct StubHardware: HardwareProbing {
    var fixed: HardwareReport
    func report(modelStorageDirectory: URL) -> HardwareReport { fixed }
}

/// Records every launch so a test can assert the probe never ran anything that
/// could log in or bill.
private final class StubCommandRunner: ProbeCommandRunning, @unchecked Sendable {
    struct Invocation: Equatable {
        var executableName: String
        var arguments: [String]
    }

    private let lock = NSLock()
    private var recorded: [Invocation] = []
    private let resultsByExecutableName: [String: ProbeCommandResult]

    init(resultsByExecutableName: [String: ProbeCommandResult] = [:]) {
        self.resultsByExecutableName = resultsByExecutableName
    }

    var invocations: [Invocation] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func run(executable: URL, arguments: [String], timeout: TimeInterval) async -> ProbeCommandResult? {
        let name = executable.lastPathComponent
        record(Invocation(executableName: name, arguments: arguments))
        return resultsByExecutableName[name]
    }

    /// Synchronous on purpose: taking an `NSLock` directly in an `async` context
    /// is a hard error under the Swift 6 language mode.
    private func record(_ invocation: Invocation) {
        lock.lock()
        recorded.append(invocation)
        lock.unlock()
    }
}
