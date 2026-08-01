import Foundation
import SageVoiceCore
#if canImport(KokoroEngine)
import KokoroEngine
#endif

/// Kokoro in this process, or `nil` if it cannot run yet.
///
/// **One function rather than the same `#if` at both call sites.** Voice notes
/// and calls each need this, and the two used to build their own synthesizer
/// independently — which is how the daemon ended up probing a voice backend
/// twice on every startup and reporting one answer while using another.
///
/// `nil` is an ordinary outcome, not a failure: the 325 MB model is fetched when
/// Signal is linked rather than shipped in the bundle, so on a first run it is
/// genuinely absent and the caller falls back to the system voice for that
/// session. It is also `nil` on a checkout with no `vendor/onnxruntime`, where
/// `KokoroEngine` is not compiled in at all.
func nativeKokoro(named voice: String) -> (any SpeechSynthesizing)? {
    #if canImport(KokoroEngine)
    return KokoroSpeechSynthesizer.ifReady(voice: voice)
    #else
    return nil
    #endif
}

// Smoke harness for the subsystems, one subcommand each. Not the daemon —
// the daemon (Signal transport wired to ASR -> brain -> TTS) lands on top of
// these once the setup flow can tell it which backend to build.
//
//   sage-voiced transcribe <file.wav> [--endpoint URL] [--model NAME]
//   sage-voiced brain "<transcript>" [--provider NAME] [--model NAME] [--sage PATH]
//   sage-voiced setup
//   sage-voiced verify-sage <path/to/SAGE.app>

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage:
      sage-voiced transcribe <file.wav> [--endpoint URL] [--model NAME]
      sage-voiced brain "<transcript>" [--provider NAME] [--model NAME] [--sage PATH]
      sage-voiced setup
      sage-voiced verify-sage <path/to/SAGE.app>
      sage-voiced search "<query>"
      sage-voiced key [--provider gemini] [--key <key>]   instructions, then verify
      sage-voiced google [--provision] [--sign-out]        sign in with Google
      sage-voiced daemon --allow <your-number> [--account N] [--sage PATH]
                         [--reply-prefix "MYNAH >> "] [--acknowledge]
      sage-voiced check [--sage PATH]                     one proactive check, printed

    `brain` and `daemon` take --no-web to run with SAGE tools only.
    Web search uses Brave when BRAVE_SEARCH_API_KEY is set, DuckDuckGo otherwise.

    brain providers:
      ollama (default, local)   openai     deepseek   moonshot
      anthropic                 gemini     groq       lmstudio (local)

    Cloud providers read their key from the environment: ANTHROPIC_API_KEY,
    OPENAI_API_KEY, DEEPSEEK_API_KEY, GEMINI_API_KEY, GROQ_API_KEY,
    MOONSHOT_API_KEY.

    """.utf8))
    exit(2)
}

/// Trailing `--flag value` pairs, whatever the subcommand.
func parseFlags(_ arguments: [String]) -> [String: String] {
    var flags: [String: String] = [:]
    var index = 0
    while index + 1 < arguments.count {
        if arguments[index].hasPrefix("--") {
            flags[String(arguments[index].dropFirst(2))] = arguments[index + 1]
            index += 2
        } else {
            index += 1
        }
    }
    return flags
}

/// Runs an async body from the top level and exits with its status.
func runAndExit(_ body: @escaping () async -> Int32) -> Never {
    let semaphore = DispatchSemaphore(value: 0)
    var status: Int32 = 0
    Task {
        status = await body()
        semaphore.signal()
    }
    semaphore.wait()
    exit(status)
}

/// Every line the daemon writes, stamped and unbuffered.
///
/// **`bridge.log` had no clock**, which is why every diagnosis today began by
/// correlating log lines against a file's modification date — the appliance's
/// own record could say *what* happened and never *when*. `signal.log` has
/// timestamps because signal-cli writes its own; ours had none because these
/// lines are bare text to a redirected stream.
///
/// Same format as `MynahLog` on purpose, so `appliance.log`, `mynah.log` and
/// this one read together in one `sort`.
///
/// **And it is stderr rather than `print`, which is the half that is not about
/// timestamps.** `print` goes to stdout, and stdout redirected to a file is
/// *block*-buffered rather than line-buffered — so those lines sat in a 4KB
/// buffer until it filled, arriving late and out of order beside the stderr
/// lines written straight through.
///
/// **The damage to old logs is measurable rather than estimated**, which is the
/// version worth having. In his `bridge.log`, lines 216–249 are fourteen
/// `[daemon]` turn lines and their `[signal]` neighbours with **zero `[sage]`
/// lines among them** — then `[sage]` resumes as a three-line block at 250.
/// Everywhere quieter in the same file the pattern is one three-line `[sage]`
/// group per turn. The tool sources logged through `print`; the daemon and the
/// transport did not. Two streams into one file, one buffered and one not.
///
/// So the caution for anything read out of a pre-fix `bridge.log` is not "some
/// lines may be missing" — the `[sage]` lines survived in bulk. It is that
/// **their position is unreliable**: attributing tool activity to the nearest
/// `[daemon]` turn above it reads an artifact of buffering as a fact about the
/// turn. `thread` found this and it is not repairable in the existing file.
///
/// Losing lines entirely was the other risk — launchd SIGTERMs on every
/// reconcile, and a full buffer dies with the process — but the counts that
/// matter were never exposed to it: the `[signal]` and `[daemon]` lines were
/// already on stderr, so the eight disconnect episodes are a total and not a
/// floor. stderr is unbuffered; a line written is a line on disk.
func note(_ message: String) {
    let stamp = daemonClock.string(from: Date())
    FileHandle.standardError.write(Data("\(stamp) \(message)\n".utf8))
}

private let daemonClock: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter
}()

func fail(_ message: String) -> Int32 {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    return 1
}

// MARK: - transcribe

func runTranscribe(_ arguments: [String]) -> Never {
    guard let path = arguments.first else { usage() }
    let flags = parseFlags(Array(arguments.dropFirst()))

    let fileURL = URL(fileURLWithPath: path)

    guard FileManager.default.fileExists(atPath: fileURL.path) else {
        exit(fail("no such file: \(path)"))
    }

    runAndExit {
        let transcriber: AudioFileTranscribing
        do {
            if let endpoint = flags["endpoint"].flatMap({ URL(string: $0) }) {
                transcriber = WhisperKitServerTranscriber(
                    endpoint: endpoint,
                    model: flags["model"] ?? "large-v3",
                    language: "en",
                    timeoutSeconds: WhisperKitServerTranscriber.minimumFullAudioTimeoutSeconds
                )
            } else {
                transcriber = try await LocalASRRuntime.shared.prepare()
            }
        } catch {
            return fail("local speech recognition is not ready: \(error)")
        }
        let started = Date()
        do {
            let text = try await transcriber.transcribe(
                audioFile: fileURL,
                options: AudioTranscriptionOptions()
            )
            print(String(format: "[%.2fs] %@", Date().timeIntervalSince(started), text))
            return 0
        } catch {
            return fail("transcribe failed: \(error)")
        }
    }
}

// MARK: - brain

/// Builds a backend from a provider name, reading any key from the environment.
///
/// Deliberately explicit rather than auto-detecting: this is a test harness,
/// and a harness that silently picks a different provider than the one you
/// named is worse than useless when you are trying to compare them.
struct HarnessError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func makeBackend(
    provider: String,
    model: String?,
    ollamaBaseURL: String?,
    // Supplied when the owner has just pasted a key and it is not in the
    // environment yet — validating what they typed, rather than what happens
    // to be exported, is the whole point of checking at all.
    explicitKey: String? = nil
) throws -> BrainBackend {
    func environmentKey(_ name: String) throws -> String {
        if let explicitKey, !explicitKey.isEmpty { return explicitKey }
        // Environment, then the stored key. The daemon runs for weeks and must
        // not carry a credential in its argument vector, where every local
        // process can read it out of `ps`.
        if let stored = ProviderKeyStore().key(forProvider: provider), !stored.isEmpty {
            return stored
        }
        throw HarnessError("no key for '\(provider)' — run: sage-voiced key --provider \(provider) --key <key> --save")
    }

    func openAICompat(
        _ compatProvider: OpenAICompatProvider,
        defaultModel: String,
        keyVariable: String?
    ) throws -> BrainBackend {
        let credential: BrainCredential
        if let keyVariable {
            credential = StaticAPIKeyCredential.bearer(
                try environmentKey(keyVariable),
                providerLabel: compatProvider.displayName
            )
        } else {
            // A local server that wants no auth still needs a credential object.
            credential = StaticAPIKeyCredential.bearer("local", providerLabel: compatProvider.displayName)
        }
        return OpenAICompatBackend(
            provider: compatProvider,
            modelName: model ?? defaultModel,
            credential: credential
        )
    }

    /// The model Mynah picks for a provider, from the one catalogue.
    ///
    /// Throws rather than substituting a fallback string. A guessed model name
    /// would be sent to a real provider on the owner's real key and come back as
    /// "no such model" — which from the outside is indistinguishable from the
    /// appliance being broken. Naming the gap is the whole point.
    func catalogueModel(_ identifier: String) throws -> String {
        guard let pick = CloudBrainModelCatalog.model(forProvider: identifier) else {
            throw HarnessError(
                "no model chosen for '\(identifier)' — add one to CloudBrainModelCatalog "
                + "and record why in docs/MODEL-CHOICES.md, or pass --model"
            )
        }
        return pick
    }

    switch provider {
    case "ollama":
        // `--ollama` points at a daemon over an SSH tunnel, so the appliance's
        // model can be driven from a dev machine that has not pulled it.
        let client = ollamaBaseURL.flatMap { URL(string: $0) }.map { OllamaClient(baseURL: $0) }
            ?? OllamaClient()
        return OllamaBackend(
            client: client,
            model: model ?? "qwen3.5:4b",
            managedRuntime: ollamaBaseURL == nil ? OllamaRuntimeInstaller.shared : nil
        )
    case "anthropic":
        return AnthropicBackend(
            // Speed first: this is spoken conversation, not a coding agent.
            modelName: try model ?? catalogueModel("anthropic"),
            apiKey: try environmentKey("ANTHROPIC_API_KEY")
        )
    case "openai":
        return try openAICompat(.openAI, defaultModel: try catalogueModel("openai"), keyVariable: "OPENAI_API_KEY")
    case "deepseek":
        return try openAICompat(.deepSeek, defaultModel: try catalogueModel("deepseek"), keyVariable: "DEEPSEEK_API_KEY")
    case "moonshot", "kimi":
        return try openAICompat(.moonshot, defaultModel: try catalogueModel("moonshot"), keyVariable: "MOONSHOT_API_KEY")
    case "groq":
        return try openAICompat(.groq, defaultModel: try catalogueModel("groq"), keyVariable: "GROQ_API_KEY")
    case "gemini":
        return try openAICompat(.gemini, defaultModel: try catalogueModel("gemini"), keyVariable: "GEMINI_API_KEY")
    case "lmstudio":
        return try openAICompat(.lmStudio(), defaultModel: "local-model", keyVariable: nil)

    case "openai-compat":
        // Any `/v1/chat/completions` server, named by `--base-url`.
        //
        // Worth having beyond genericity: Ollama serves this shape too, so
        // pointing it at a local daemon exercises the adapter's encoding
        // against a real server — tool schemas, JSON-string arguments, null
        // content on a tool-call turn, id matching — without a cloud key.
        guard let raw = ollamaBaseURL, let url = URL(string: raw) else {
            throw HarnessError("--provider openai-compat requires --base-url")
        }
        return try openAICompat(
            OpenAICompatProvider(
                identifier: "openai-compat",
                displayName: url.host ?? "custom",
                baseURL: url,
                isLocal: LoopbackSecurity.isLoopback(url)
            ),
            defaultModel: "qwen3.5:4b",
            keyVariable: nil
        )

    default:
        throw HarnessError("unknown provider '\(provider)'")
    }
}

/// Everything the loop can call: SAGE's governed memory, plus the open internet.
///
/// SAGE is required and web search is not, which is the whole reason these are
/// composed rather than merged. An appliance that cannot reach its own memory is
/// broken; one that cannot reach Google is just offline, and the owner should
/// still be able to ask it what is on their backlog.
///
/// `--no-web` exists for the case where that is a policy rather than a fault.
///
/// Returns the notes source alongside the catalogue because the daemon needs
/// that same instance: it is what knows which documents this turn produced, and
/// therefore what the reply should carry.
func makeToolSource(
    mcp: MCPClient,
    allowWeb: Bool
) -> (tools: ToolProviding, notes: NotesToolSource) {
    let notes = NotesToolSource(delivery: .attachedToReply, log: { note($0) })

    var sources: [CompositeToolSource.Source] = [
        .init(
            label: "SAGE MCP",
            provider: mcp,
            isRequired: true,
            expectedToolNames: BrainPrompts.voiceToolAllowlist
                .subtracting([WebSearchToolSource.toolName])
                .subtracting(NotesToolSource.toolNames)
        ),
        // Required. Unlike search, this has no network to be down and no
        // credential to expire — if it cannot list its three tools something is
        // wrong with the appliance itself, and degrading quietly would hide it.
        .init(
            label: "notes",
            provider: notes,
            isRequired: true,
            expectedToolNames: NotesToolSource.toolNames
        )
    ]
    if allowWeb {
        sources.append(
            .init(
                label: "web search",
                provider: WebSearchToolSource(
                    backends: WebSearchToolSource.defaultBackends(),
                    log: { note($0) }
                ),
                isRequired: false,
                expectedToolNames: [WebSearchToolSource.toolName]
            )
        )
    }
    return (CompositeToolSource(sources: sources, log: { note($0) }), notes)
}

func runBrain(_ arguments: [String]) -> Never {
    guard let transcript = arguments.first, !transcript.hasPrefix("--") else { usage() }
    let flags = parseFlags(Array(arguments.dropFirst()))

    let backend: BrainBackend
    do {
        backend = try makeBackend(
            provider: flags["provider"] ?? "ollama",
            model: flags["model"],
            ollamaBaseURL: flags["ollama"] ?? flags["base-url"]
        )
    } catch {
        exit(fail("\(error)"))
    }

    // The owner's node, then ours, then the conventional path.
    //
    // Normally the flag is set: the launchd job carries the path the app
    // resolved at setup. This is for a daemon started by hand, and it agrees
    // with that resolution rather than hardcoding a second answer — two places
    // deciding which SAGE to run is how one of them ends up starting a duplicate
    // beside the owner's.
    let sagePath = flags["sage"]
        ?? SageNodeChoice.resolve(vendored: SageNodeLocator.vendoredExecutableURL())?.executable.path
        ?? "/Applications/SAGE.app/Contents/MacOS/sage-gui"
    // Pinned. Without this the node derives the appliance's identity from the
    // launch working directory, so the `cd` in the launch script decides which
    // memories the owner has.
    let identityEnvironment = MynahIdentity.applianceEnvironment()
    let memoryEnvironment = backend.identifier == "ollama"
        ? MynahIdentity.localSemanticEnvironment(identityEnvironment: identityEnvironment)
        : identityEnvironment
    let mcp = MCPClient(
        executableURL: URL(fileURLWithPath: sagePath),
        arguments: ["mcp"],
        environment: memoryEnvironment
    )
    // `parseFlags` only reads `--key value` pairs, so a bare switch has to be
    // looked for in the raw arguments.
    let (tools, _) = makeToolSource(mcp: mcp, allowWeb: !arguments.contains("--no-web"))
    let style = resolveReplyStyle(arguments)
    let loop = ToolLoop(backend: backend, mcp: tools, configuration: loopConfiguration(for: style))
    note("[daemon] reply style: \(style.rawValue)")


    runAndExit {
        defer { mcp.stop() }
        do {
            print("backend: \(backend.displayDescription)")
            let info = try await mcp.start()
            print("mcp:     \(info.name) \(info.version)")

            let tools = try await loop.availableTools()
            print("tools:   \(tools.count) offered — \(tools.map(\.name).sorted().joined(separator: ", "))")
            print("---")

            let result = try await loop.run(transcript: transcript, tools: tools)
            print(result.reply)
            print("---")
            print(result.trace.summary)
            for call in result.trace.toolCalls {
                print("  \(call.summary)")
            }
            return 0
        } catch {
            let stderr = mcp.stderrLog
            return fail("brain failed: \(error)" + (stderr.isEmpty ? "" : "\n--- mcp stderr ---\n\(stderr)"))
        }
    }
}

// MARK: - setup

/// Runs the first-run environment probe and prints the menu the install screen
/// would show. Read-only: this is the same code path the settings panel will
/// re-run later to offer "move me to fully local".
func runSetup(_ arguments: [String]) -> Never {
    runAndExit {
        let probe = await EnvironmentProbe().run()
        let choices = BrainSetupPlanner().plan(for: probe)

        print("== probe ==")
        print("ollama:   \(probe.localRuntime)")
        print("hardware: \(probe.hardware)")
        print("sage:     \(probe.sage)")
        print("keys:     \(probe.ambientAPIKeys.variableNames.isEmpty ? "none set" : probe.ambientAPIKeys.variableNames.joined(separator: ", "))")
        for cli in probe.agentCLIs {
            print("cli:      \(cli)")
        }
        print()
        print("== options ==")
        for option in choices.options {
            let mark = option.availability.isAvailable ? "[ok]  " : "[--]  "
            let privacy = option.keepsWordsOnDevice ? "on-device" : "leaves machine"
            print("\(mark)\(option.label)  (\(option.requirement.rawValue), \(privacy))")
            print("        \(option.summary)")
            if let reason = option.availability.reason {
                print("        unavailable: \(reason)")
            }
        }
        if let recommendation = choices.recommendation {
            print()
            print("recommended: \(recommendation.optionID) — \(recommendation.rationale)")
            print("(a recommendation, not a selection: the owner still has to pick)")
        }
        return 0
    }
}

/// Verifies a SAGE.app bundle the way the appliance will before running it.
func runVerifySage(_ arguments: [String]) -> Never {
    guard let path = arguments.first else {
        exit(fail("usage: sage-voiced verify-sage <path/to/SAGE.app>"))
    }
    let app = URL(fileURLWithPath: path)
    switch SageNodeLocator.verifyBundle(at: app) {
    case .success(let executable):
        print("ok: \(executable.path)")
        print("version: \(SageNodeLocator.bundleVersion(at: app) ?? "unknown")")
        exit(0)
    case .failure(let error):
        exit(fail("refused: \(error)"))
    }
}

// MARK: - daemon

/// The real thing: listen on Signal, act, reply.
/// Runs one search and prints exactly what the model would be handed.
///
/// Worth a subcommand because the keyless provider is a scraper: when it breaks
/// it will break as a bad spoken answer, three layers deep, and the first
/// question will be whether search or the model was at fault. This answers that
/// in one command, with no SAGE node and no model involved.
func runSearch(_ arguments: [String]) -> Never {
    guard let query = arguments.first, !query.hasPrefix("--") else { usage() }

    let backends = WebSearchToolSource.defaultBackends()
    let source = WebSearchToolSource(backends: backends, log: { note($0) })

    runAndExit {
        print("providers: \(backends.map(\.providerName).joined(separator: " → "))")
        do {
            let output = try await source.call(
                name: WebSearchToolSource.toolName,
                arguments: ["query": .string(query)]
            )
            print("---")
            print(output)
            return 0
        } catch {
            return fail("\(error)")
        }
    }
}

/// Prints the paste-a-key instructions, and proves a key actually works.
///
/// The shipping default for cloud brains. Google sign-in loses to it on policy
/// rather than engineering: `cloud-platform` is a sensitive scope, so an
/// unverified app's refresh tokens die after 7 days — an appliance that works
/// for a week and then stops, on a machine nobody is sitting at.
func runKey(_ arguments: [String]) -> Never {
    let flags = parseFlags(arguments)
    let providerID = flags["provider"] ?? "gemini"
    guard let instructions = APIKeyOnboarding.instructions(forProvider: providerID) else {
        exit(fail("no key instructions for provider '\(providerID)'"))
    }

    guard let raw = flags["key"] ?? ProcessInfo.processInfo.environment[
        providerID == "gemini" ? "GEMINI_API_KEY"
            : providerID == "openai" ? "OPENAI_API_KEY" : "ANTHROPIC_API_KEY"
    ] else {
        print("""

        Connect \(instructions.providerName)

        \(instructions.steps.enumerated().map { "  \($0.offset + 1). \($0.element)" }.joined(separator: "\n"))

          \(instructions.keyPageURL.absoluteString)

        \(instructions.looksLikeHint)
        \(instructions.costNote ?? "")

        Then: sage-voiced key --provider \(providerID) --key <your key>

        """)
        exit(0)
    }

    let key = APIKeyOnboarding.normalise(raw)
    if let problem = APIKeyOnboarding.shapeProblem(of: key, expecting: providerID) {
        exit(fail(problem.spokenDescription))
    }

    let backend: BrainBackend
    do {
        backend = try makeBackend(provider: providerID, model: flags["model"], ollamaBaseURL: nil, explicitKey: key)
    } catch {
        exit(fail("\(error)"))
    }

    runAndExit {
        print("checking the key against \(backend.displayDescription)…")
        let verdict = await BrainKeyValidator().validate(backend)
        print(verdict.spokenDescription)
        guard verdict.isUsable else { return 1 }

        if arguments.contains("--save") {
            do {
                try ProviderKeyStore().save(key, forProvider: providerID)
                print("saved — the daemon will use it on its next start")
            } catch {
                return fail("could not save the key: \(error)")
            }
        } else {
            print("rerun with --save to keep it")
        }
        return 0
    }
}

/// Signs in to Google and, on request, provisions a Gemini key from it.
///
/// A command rather than a buried step because this is the one part of setup
/// that involves a browser, another company's consent screen and four chained
/// Google APIs — when it fails it must be runnable in isolation, with the
/// failure visible, rather than only reachable through a wizard.
func runGoogle(_ arguments: [String]) -> Never {
    let flags = parseFlags(arguments)
    guard let client = GoogleOAuthClient.fromEnvironment() else {
        exit(fail("""
        set GOOGLE_OAUTH_CLIENT_ID first (and GOOGLE_OAUTH_CLIENT_SECRET if your
        client is a "Desktop app" — Google issues one and its token endpoint
        usually wants it back, PKCE notwithstanding).
        """))
    }

    let store = GoogleTokenStore(url: GoogleTokenStore.defaultURL())
    let logger: @Sendable (String) -> Void = { print($0) }

    runAndExit {
        let credential = GoogleOAuthCredential(client: client, store: store)

        if arguments.contains("--sign-out") {
            await credential.signOut()
            print("signed out")
            return 0
        }

        if await !credential.isSignedIn {
            let session = GoogleSignInSession(client: client, store: store, log: logger)
            do {
                _ = try await session.signIn { url in
                    // The appliance is headless and the owner is elsewhere, so
                    // print the URL as well as trying to open it.
                    print("\nopen this to sign in:\n\(url.absoluteString)\n")
                    let open = Process()
                    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                    open.arguments = [url.absoluteString]
                    try? open.run()
                }
            } catch {
                return fail("\(error)")
            }
        } else {
            print("already signed in")
        }

        guard arguments.contains("--provision") else {
            // Proves the token works without changing anything.
            do {
                _ = try await credential.authorizationHeaders()
                print("token ok — rerun with --provision to mint a Gemini key")
                return 0
            } catch {
                return fail("\(error)")
            }
        }

        let provisioner = GeminiKeyProvisioner(
            transport: GoogleAuthorizedTransport(credential: credential),
            log: logger
        )
        do {
            let key = try await provisioner.provision(preferredProjectID: flags["project"])
            // Deliberately not printed in full: it is a live credential and this
            // output lands in scrollback and log files.
            print("provisioned Gemini key \(key.prefix(6))…\(key.suffix(4)) (\(key.count) chars)")
            print("export GEMINI_API_KEY=… to use it, or let setup store it for you")
            return 0
        } catch {
            return fail("\(error)")
        }
    }
}

/// The reply style both entry points run under.
///
/// Shared because they drifted: `runBrain` read the owner's preference and
/// `runDaemon` — the thing that actually answers Signal — built its loop with a
/// bare `ToolLoop(backend:mcp:)`, so the "Answer with voice notes" switch did
/// nothing on the appliance and the token ceiling stayed at the spoken value.
/// Same shape as the identity pin landing in the wrong subcommand. One function,
/// called from both.
func resolveReplyStyle(_ arguments: [String]) -> ReplyStyle {
    arguments.contains("--voice-notes") ? .spoken : ReplyPreferences().style()
}

/// The loop configuration that follows from a style.
func loopConfiguration(for style: ReplyStyle) -> ToolLoop.Configuration {
    ToolLoop.Configuration(
        systemPrompt: BrainPrompts.voiceAgentManager(style: style),
        maxGeneratedTokens: style.maximumGeneratedTokens
    )
}

/// Keeps text messaging alive when a release is missing its speech assets.
///
/// VoiceBridgeDaemon already turns a per-message transcription failure into an
/// honest reply. This placeholder lets that path run without making ASR a
/// prerequisite for starting the entire Signal appliance.
private struct UnavailableTranscriber: AudioFileTranscribing {
    let reason: String

    func transcribe(
        audioFile: URL,
        options: AudioTranscriptionOptions
    ) async throws -> String {
        throw AudioTranscriberError.allBackendsFailed([reason])
    }
}

func runDaemon(_ arguments: [String]) -> Never {
    let flags = parseFlags(arguments)

    guard let allowRaw = flags["allow"] ?? ProcessInfo.processInfo.environment["SAGE_VOICE_ALLOW"] else {
        exit(fail("""
        --allow is required: the daemon refuses to serve anyone not named.

          sage-voiced daemon --allow +6591234567 [--account +6591234567]

        Pass your OWN Signal number. By default only Note-to-Self is served, so
        you message yourself and the appliance answers in that thread.
        """))
    }

    let allowlist: SignalSenderAllowlist
    do {
        allowlist = try SignalSenderAllowlist(commaSeparated: allowRaw)
    } catch {
        exit(fail("bad --allow: \(error)"))
    }

    let backend: BrainBackend
    do {
        backend = try makeBackend(
            provider: flags["provider"] ?? "ollama",
            model: flags["model"],
            ollamaBaseURL: flags["ollama"]
        )
    } catch {
        exit(fail("\(error)"))
    }

    let signal = SignalClient(configuration: .init(
        allowlist: allowlist,
        endpoint: flags["socket"].map { SignalEndpoint.unixSocket(path: $0) } ?? .defaultUnixSocket(),
        account: flags["account"]
    ))

    // The owner's node, then ours, then the conventional path.
    //
    // Normally the flag is set: the launchd job carries the path the app
    // resolved at setup. This is for a daemon started by hand, and it agrees
    // with that resolution rather than hardcoding a second answer — two places
    // deciding which SAGE to run is how one of them ends up starting a duplicate
    // beside the owner's.
    let sagePath = flags["sage"]
        ?? SageNodeChoice.resolve(vendored: SageNodeLocator.vendoredExecutableURL())?.executable.path
        ?? "/Applications/SAGE.app/Contents/MacOS/sage-gui"
    // Pinned. Without this the node derives the appliance's identity from the
    // launch working directory, so the `cd` in the launch script decides which
    // memories the owner has.
    //
    // This was written into runBrain first by mistake, and the mistake verified
    // as a success because the check was `sage-voiced brain` — a different
    // process, and the one that had the pin. Meanwhile the daemon started from
    // /tmp and minted `tmp-agent-*`, answering the owner from an identity with
    // none of their memories. Testing the wrong process proves the wrong thing.
    let mcp = MCPClient(
        executableURL: URL(fileURLWithPath: sagePath),
        arguments: ["mcp"],
        environment: MynahIdentity.applianceEnvironment()
    )
    // `parseFlags` only reads `--key value` pairs, so a bare switch has to be
    // looked for in the raw arguments.
    let (tools, notes) = makeToolSource(mcp: mcp, allowWeb: !arguments.contains("--no-web"))
    let style = resolveReplyStyle(arguments)
    let loop = ToolLoop(backend: backend, mcp: tools, configuration: loopConfiguration(for: style))
    note("[daemon] reply style: \(style.rawValue)")
    // Which of Kokoro's 54 voices sounds like the appliance is pure taste, and
    // taste is only discoverable by hearing it on a call. A flag means trying
    // another one is a restart rather than a rebuild and a redeploy.
    // Read from the file the Settings screen writes, so the controls the owner
    // moves are the ones the daemon obeys. Flags still win, for trying a voice
    // without touching a saved preference.
    let callPreferences = CallPreferences.load()
    let callVoiceName = flags["call-voice"]
        ?? callPreferences.voice
        ?? KokoroVoices.defaultVoiceName
    let callSpeed = flags["call-speed"].flatMap(Double.init) ?? callPreferences.clampedSpeed
    // Both of these are pure taste, and taste is only discoverable by living
    // with it on a phone. Exposing them as flags means retuning is a daemon
    // restart rather than a rebuild, a repackage, a resign and a redeploy.
    // Before anything expensive, and before Signal is touched. Two appliances
    // on one Mac both read the same socket and both answer, so the owner gets
    // every reply twice.
    do {
        try SingleInstance().acquire()
    } catch {
        exit(fail("\(error.localizedDescription)"))
    }

    var daemonConfiguration = VoiceBridgeDaemon.Configuration()
    if let prefix = flags["reply-prefix"] {
        daemonConfiguration.replyPrefix = prefix
    }
    if arguments.contains("--acknowledge") {
        daemonConfiguration.sendsThinkingAcknowledgement = true
    }
    daemonConfiguration.speaksReplies = style.usesVoiceNotes

    // What this process actually resolved, published for the app to read.
    // Settings answered "where your words go" from the app's own record of what
    // the owner picked, which nothing outside MynahMac ever reads — so an
    // appliance switched to DeepSeek by hand still reported "Fully on this Mac"
    // while every voice note went to a third party.
    ApplianceStatus.publish(
        ApplianceStatus(
            provider: backend.identifier,
            model: backend.modelName,
            keepsWordsOnDevice: backend.isLocal,
            speaksReplies: style.usesVoiceNotes
        )
    )
    // Driven against the raw MCP client, not the composed catalogue: these are
    // SAGE's own boot tools, deliberately outside the model's allowlist.
    runAndExit {
        if backend.identifier == "ollama" {
            let ready = await LocalBrainInstaller(
                runtime: OllamaRuntimeInstaller.shared
            ).install()
            guard ready else {
                return fail("the local Ollama runtime, chat model, or nomic memory model is not ready")
            }
        }

        // Not fatal, and this took the appliance down to learn it.
        //
        // Preparing speech recognition eagerly is right — better to know now
        // than when the first voice note arrives. Refusing to *start* over it is
        // not: the deployed bundle has never carried an ASR helper, so the
        // daemon crash-looped under launchd and every text message went
        // unanswered because it could not transcribe audio nobody had sent.
        //
        // Text and voice are separate capabilities. Losing one must not cost the
        // other, and `handle` already replies "I couldn't read that voice note"
        // per message, which is the honest place for this failure to surface.
        let transcriber: AudioFileTranscribing
        do {
            if let endpoint = flags["endpoint"].flatMap({ URL(string: $0) }) {
                transcriber = WhisperKitServerTranscriber(
                    endpoint: endpoint,
                    model: flags["asr-model"] ?? "large-v3",
                    language: "en",
                    timeoutSeconds: WhisperKitServerTranscriber.minimumFullAudioTimeoutSeconds
                )
            } else {
                transcriber = try await LocalASRRuntime.shared.prepare()
            }
        } catch {
            // Two stamped lines rather than one block: a multi-line write puts
            // one timestamp on the first line and leaves the second looking
            // like it happened at no particular moment.
            note("[daemon] speech recognition is unavailable, so voice notes cannot be transcribed: \(error)")
            note("[daemon] text messages will still be answered")
            transcriber = UnavailableTranscriber(reason: "\(error)")
        }

        let synthesizer: SpeechSynthesizing?
        if style.usesVoiceNotes {
            _ = VoiceNote.discardStale()
            if let native = nativeKokoro(named: KokoroVoices.defaultVoiceName) {
                synthesizer = native
            } else {
                let system = SystemSpeechSynthesizer()
                synthesizer = await system.isAvailable() ? system : nil
            }
            if synthesizer == nil {
                note("[daemon] no local speech synthesizer is available; replies will be text")
            }
        } else {
            synthesizer = nil
        }

        // `sage-gui mcp` is a client, not a node. On a Mac where nothing ever
        // started `serve` — every Mac that did not already have SAGE.app — the
        // daemon would come up "ready" and answer the owner from a brain that
        // could neither read nor write, because the port it talks to had no
        // listener. Probes first and starts one only on a real connection
        // failure, so an owner's existing node never gets a second beside it.
        let nodeStanding = await ApplianceWriteReadinessCheck().checkStartingNodeIfNeeded()
        if let headline = nodeStanding.headline {
            note("[daemon] SAGE memory: \(headline)")
        }

        do {
            let info = try await mcp.start()
            let tools = try await loop.availableTools()
            print("backend: \(backend.displayDescription)")
            print("mcp:     \(info.name) \(info.version), \(tools.count) tools")
            print("allow:   \(allowlist.identities.count) identity(ies), Note-to-Self only")
            print("ready — send yourself a Signal message.")
        } catch {
            return fail("startup failed: \(error)\n\(mcp.stderrLog)")
        }
        // Calls answer through the same brain as messages, and keep their own
        // history. A call is a conversation: a caller made to repeat context
        // they gave twenty seconds ago is talking to a search box.
        //
        // Synthesis runs at 48 kHz here and 22.05 elsewhere, because Opus runs
        // at 48 and resampling in the audio path is a place a subtle error is
        // inaudible in testing and awful on a real call.
        // Kokoro if it is running, `say` if it is not.
        //
        // macOS ships two classes of voice and only the good ones require a
        // download with no command-line path — which on a headless appliance
        // means the robotic compact voices are what a caller actually hears.
        // Kokoro is Apache 2.0, runs on this machine, and measures at a
        // real-time factor near 0.3, so naturalness costs nothing in latency.
        // Qwen3-TTS sounds better still and takes nine seconds a sentence,
        // which is a dead line rather than a voice.
        //
        // The fallback matters: a call must not stop working because the model
        // has not been downloaded yet. A robotic voice is a complaint, silence
        // is a fault.
        var systemVoice = SystemSpeechSynthesizer()
        systemVoice.sampleRate = 48_000
        let nativeCallVoice = nativeKokoro(named: callVoiceName)
        let callVoice: any SpeechSynthesizing = nativeCallVoice ?? systemVoice
        note("[call] voice: \(nativeCallVoice == nil ? "say (kokoro model not installed)" : "kokoro \(callVoiceName), in process")")
        // A call is answered in the spoken style regardless of the owner's voice
        // note setting, because the medium is not a choice here — it is being
        // read aloud down a phone line. The written style is right for a screen
        // and wrong for this: it produced "Here's a snapshot of Emirates
        // Airlines as of 2025:" followed by markdown bullets, which is a list
        // nobody can hear and, until the synthesiser was fixed, a leading dash
        // that killed the answer outright.
        let callLoop = ToolLoop(
            backend: backend,
            mcp: tools,
            configuration: loopConfiguration(for: .spoken)
        )
        let callHistory = CallHistory()
        let callServer = CallTurnServer(
            configuration: CallTurnServer.Configuration(
                voice: callVoiceName,
                speed: callSpeed
            ),
            transcriber: transcriber,
            synthesizer: callVoice,
            answer: { heard in
                let result = try await callLoop.run(
                    transcript: heard,
                    history: await callHistory.recent()
                )
                await callHistory.remember(result.messages)
                return result.reply
            },
            log: { note($0) }
        )
        // Detached, so a call that fails to start never stops Signal working.
        // The socket is the only thing //call needs; everything else about the
        // appliance carries on without it.
        let callTask = Task {
            do {
                try await callServer.run()
            } catch {
                note("[call] calling is unavailable: \(error)")
            }
        }
        defer { callTask.cancel() }

        let daemon = VoiceBridgeDaemon(
            signal: signal,
            transcriber: transcriber,
            loop: loop,
            configuration: daemonConfiguration,
            // Same dictation vocabulary as the window, from the same memories
            // through the same MCP connection. One stack for both ways in —
            // two profiles that drift would mean a coinage transcribed one way
            // from a phone and another from the Mac.
            //
            // Registered, not built: the store compiles in the background and
            // `repair` never waits, so a voice note is never held up by a
            // memory query. On a node that refuses reads this stays empty and
            // the transcript passes through untouched.
            dictationVocabulary: SageMemoryVocabularySource(tools: mcp).callAsFunction,
            ritual: arguments.contains("--no-sage-ritual")
                ? nil
                : SageRitual(
                    tools: mcp,
                    displayName: SageRitual.applianceDisplayName,
                    log: { note($0) }
                ),
            notes: notes,
            conversations: ConversationStore(),
            synthesizer: synthesizer,
            // Absent on a build that did not vendor it, in which case //call
            // says so rather than pretending.
            calls: CallHost(endpointURL: callEndpointURL(sagePath: sagePath)),
            // Decided once. The backend used to be part of this and no longer
            // is — see `CallInvitation.refusal(isSetUpForCalls:)`.
            callRefusal: CallInvitation.refusal(isSetUpForCalls: CallHost.isSetUpForCalls()),
            // //call is several seconds of warning. Spent warming the model,
            // SAGE, the voice and recognition — and building the opening — so
            // the caller arrives to something ready rather than to a pause.
            onCallRequested: { await callServer.prepare() }
        )
        // After construction, because the transcript goes out through the same
        // Signal path as everything else and the daemon owns it.
        await callServer.onTranscript { [weak daemon] transcript in
            await daemon?.postCallTranscript(transcript)
        }

        // Checking on things without being asked.
        //
        // Off unless the owner switched it on, and the loop is started
        // regardless so that switching it on takes effect without a restart —
        // `ProactiveSchedule.isDue` reads the preference every minute and
        // answers false until then. A loop that only existed when the setting
        // was on would mean a control that appears to do nothing until the next
        // time somebody reboots the Mac.
        //
        // Detached like the call server: a node that will not answer must not
        // stop Signal working.
        let watchTask = Task { [weak daemon] in
            // The owner's own thread — Note to Self, which is where every other
            // reply lands. `--account` when it was given, otherwise the number
            // they allowlisted, which for this appliance is the same person by
            // definition: it refuses to serve anyone else.
            let owner = flags["account"] ?? allowlist.identities.compactMap {
                if case .phoneNumber(let number) = $0 { return number }
                return nil
            }.sorted().first
            guard let owner else { return }

            await runProactiveWatch(
                source: SageProactiveSource(tools: mcp),
                say: { message in
                    await daemon?.announce(message, to: .account(owner))
                },
                log: { note($0) }
            )
        }
        defer { watchTask.cancel() }

        await daemon.run()
        mcp.stop()
        return 0
    }
}

// MARK: - Dispatch

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "transcribe":  runTranscribe(Array(arguments.dropFirst()))
case "brain":       runBrain(Array(arguments.dropFirst()))
case "setup":       runSetup(Array(arguments.dropFirst()))
case "verify-sage": runVerifySage(Array(arguments.dropFirst()))
case "search":      runSearch(Array(arguments.dropFirst()))
case "google":      runGoogle(Array(arguments.dropFirst()))
case "key":         runKey(Array(arguments.dropFirst()))
case "daemon":      runDaemon(Array(arguments.dropFirst()))
case "check":       runCheck(Array(arguments.dropFirst()))
default:            usage()
}


// MARK: - check

/// Runs one proactive check and prints what it *would* say.
///
/// **The unit tests cover the rules; this covers the wiring.** Everything in
/// `ProactiveWatch` is a value type tested without a node, which proves the
/// decisions and proves nothing about whether this appliance's key can read its
/// own backlog, whether the node's shapes still parse, or whether the identity
/// the daemon runs under is the one holding the tasks. Those are exactly the
/// failures that would otherwise show up as an appliance that has been silent
/// for a week and nobody able to say whether that is correct.
///
/// **Deliberately does not touch the real ledger.** Running this must not
/// consume the news: whatever it finds is still new to the daemon afterwards.
func runCheck(_ arguments: [String]) -> Never {
    let flags = parseFlags(arguments)
    let sagePath = flags["sage"]
        ?? SageNodeChoice.resolve(vendored: SageNodeLocator.vendoredExecutableURL())?.executable.path
        ?? "/Applications/SAGE.app/Contents/MacOS/sage-gui"

    runAndExit {
        let mcp = MCPClient(
            executableURL: URL(fileURLWithPath: sagePath),
            arguments: ["mcp"],
            environment: MynahIdentity.applianceEnvironment()
        )
        defer { mcp.stop() }
        let source = SageProactiveSource(tools: mcp)

        // What it can see at all — and **why not**, when it cannot.
        //
        // `ProactiveWatch` swallows these on purpose: a check nobody asked for
        // must not put an error on the owner's phone. That is right for the
        // daemon and wrong here, and it showed the first time this ran: "inbox:
        // 0, tasks: 0" against a node that has both, because a failed
        // connection and an empty node are the same `?? []`. A diagnostic that
        // reports "nothing" when it means "could not ask" is worse than no
        // diagnostic.
        var reachable = true
        do {
            let waiting = try await source.waitingMessages(limit: 20)
            print("inbox: \(waiting.count) waiting")
            for item in waiting {
                print("  - from \(item.content.sender)\(item.intent.map { " (\($0))" } ?? "")")
            }
        } catch {
            reachable = false
            print("inbox: could not ask — \(error)")
        }
        do {
            let tasks = try await source.openTasks()
            print("tasks: \(tasks.count) open")
            for task in tasks {
                print("  - [\(task.status)] \(task.title)")
            }
            // An empty list has two causes and they are not the same: a node
            // with nothing assigned to this agent, and an answer this could not
            // read. The watch cannot tell them apart and must not — it stays
            // silent either way — but a person running this command needs to,
            // so the node's own words go on screen when the parse came back
            // with nothing.
            if tasks.isEmpty {
                let raw = (try? await mcp.call(name: "sage_backlog", arguments: [:])) ?? ""
                print("  node said (\(raw.count) chars), last 300:")
                print("  …\(raw.suffix(300))")
            }
        } catch {
            reachable = false
            print("tasks: could not ask — \(error)")
        }
        print("identity: \(MynahIdentity.applianceKeyURL().path)")

        let preferences = ProactivePreferences.load()
        print("")
        print("setting: \(preferences.isOn ? "on" : "off"), every \(preferences.clampedMinutes) minutes, "
            + "quiet \(preferences.quietFrom):00–\(preferences.quietUntil):00")

        // Against an empty ledger, seeded, so everything present reads as new —
        // which is what makes this useful as a rehearsal. The real ledger is
        // untouched.
        let report = await ProactiveWatch(source: source)
            .check(against: ProactiveLedger(hasSeeded: true))
        print("")
        guard reachable else {
            print("the node did not answer, so this proves nothing about what it holds.")
            return 1
        }
        if let message = report.message {
            print("it would say:")
            print("")
            print(message)
        } else {
            print("it would say nothing.")
        }
        return 0
    }
}

/// Where the call endpoint is, looking in the sensible place first.
///
/// Beside this executable, because it is Mynah's own helper and that is where
/// packaging puts it. The vendored SAGE.app is checked afterwards only because
/// that is where it was hand-installed on the appliance during development, and
/// a lookup that stops working the moment packaging is fixed would be a strange
/// thing to ship.
///
/// This mismatch would have shipped: the daemon looked only beside sage-gui,
/// packaging installs beside sage-voiced, and the appliance worked purely
/// because the binary had been copied into the SAGE bundle by hand. Every
/// packaged build would have answered //call with "the call endpoint is not
/// installed".
/// The loop behind "check on things every so often".
///
/// Sleeps a minute at a time rather than for the owner's whole interval, so
/// switching the setting on, changing it, or switching it off takes effect
/// within a minute instead of at the end of an hour nobody can see the start
/// of. The cost of a tick that decides to do nothing is one file read.
///
/// Every failure here is swallowed on purpose. This runs unattended on a Mac
/// that is expected to be up for months; a node restarting, a key rotating or
/// a network dropping is an ordinary Tuesday, and none of it is worth putting
/// an error on the owner's phone about something they did not ask for.
func runProactiveWatch(
    source: any ProactiveSource,
    say: @escaping @Sendable (String) async -> Void,
    log: @escaping @Sendable (String) -> Void
) async {
    let watch = ProactiveWatch(source: source)
    let ledgerURL = ProactiveLedger.defaultFileURL()

    while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(ProactiveSchedule.tick))
        guard !Task.isCancelled else { return }

        let preferences = ProactivePreferences.load()
        var ledger = ProactiveLedger.load(from: ledgerURL)
        guard ProactiveSchedule.isDue(
            now: Date(),
            lastChecked: ledger.lastCheckedAt,
            preferences: preferences
        ) else { continue }

        let report = await watch.check(against: ledger)
        ledger = report.ledger
        ledger.lastCheckedAt = Date()
        try? ledger.save(to: ledgerURL)

        guard let message = report.message else { continue }
        log("[watch] something changed; telling the owner")
        await say(message)
    }
}

func callEndpointURL(sagePath: String) -> URL {
    let candidates = [
        Bundle.main.executableURL?.deletingLastPathComponent(),
        URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath()
            .deletingLastPathComponent(),
        URL(fileURLWithPath: sagePath).deletingLastPathComponent()
    ].compactMap { $0 }

    for directory in candidates {
        let candidate = directory.appendingPathComponent("sage-voice-webrtc")
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
    }
    // Nothing found. Return the place it ought to be, so the error names the
    // path somebody would actually go and look at.
    return (candidates.first ?? URL(fileURLWithPath: "."))
        .appendingPathComponent("sage-voice-webrtc")
}
